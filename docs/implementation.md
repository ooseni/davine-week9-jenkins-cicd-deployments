# Implementation | how the week was built, step by step

**Davine Technologies Internship Project, DevOps internship week 9.** The short implementation summary the brief asks for, followed by every step to run it again and the decisions behind it.

## Summary

I rebuilt week 7's web app from source and wrote a Jenkins pipeline for it as code. Jenkins itself is defined as code too. On every new commit, Jenkins:

1. checks the code out from GitHub;
2. builds it;
3. runs the unit tests and static checks in parallel;
4. builds and smoke-tests a Docker image;
5. pushes the image to Amazon ECR;
6. rolls it out to Kubernetes by digest;
7. verifies that the new version is the one answering;
8. rolls back on its own if the release does not become ready or fails verification.

Blue-green deployment is a parameter away. The AWS side is in Terraform: an ECR repository and an IAM role that can push to that one repository. Jenkins gets a 12-hour token from that role, never an access key. The deploy, verify and rollback logic is in scripts, so GitHub Actions tests it end to end on a real cluster on every push.

## Before starting

- Docker Engine, k3d 5.9, kubectl 1.36, Terraform 1.10 or newer, AWS CLI v2, curl and jq. I used WSL2 (Ubuntu 26.04) with 4 CPUs and 6 GB of memory.
- An AWS session, never an access key: `aws sso login --profile <admin-profile>`, then `export AWS_PROFILE=<admin-profile>`.
- Cost: an ECR repository holding a few images of about 50 MB is a fraction of a cent a day; IAM is free; Jenkins and the cluster run locally. Run the teardown the same day anyway.

## Step 1: the registry and the push role (Terraform)

```bash
cd terraform && terraform init && terraform apply && cd ..
```

Four resources: the repository `davine-wk9-webapp` (immutable tags, scan on push, KMS encryption), its lifecycle policy (untagged images expire after a day, the newest 10 are kept), the role `davine-wk9-jenkins-ecr-push`, and its policy. The role's trust policy allows only the IAM Identity Center role of whoever ran `apply`; its policy allows `ecr:GetAuthorizationToken` and the seven push and pull actions on this one repository.

## Step 2: the cluster

```bash
scripts/cluster_up.sh
```

A one-node k3s cluster in Docker (k3d), with NodePorts 30080 to 30082 on `127.0.0.1`. As cluster admin, the script applies [`k8s/cluster`](../k8s/cluster):

- the namespace `davine-space`, enforcing the restricted Pod Security Standard;
- the `jenkins-deployer` account and its Role;
- a default-deny NetworkPolicy that lets the app accept port 8080 only;
- an empty `ecr-pull` secret.

It then writes two kubeconfigs holding a 12-hour token for `jenkins-deployer`, and checks 12 permissions: 5 it must have and 7 it must not.

## Step 3: Jenkins

```bash
scripts/jenkins_up.sh
```

1. Assumes the push role, asks ECR for a token as that role, and keeps only the token, in a private file.
2. Builds the controller image (Jenkins 2.580.2 LTS, 69 pinned plugins, Configuration as Code) and the agent image (Docker CLI, kubectl).
3. Starts both on the cluster's Docker network. The controller reads the token, the kubeconfig and a random admin password as Docker secrets.
4. Reads the agent's secret from the controller and starts the agent, which connects over WebSocket.

Open `http://localhost:8080` and sign in as `admin`, with the password in `.live/jenkins-admin-password`. The job `davine-webapp` already exists, pointing at this repository's `Jenkinsfile`.

## Step 4: releases

```bash
scripts/jenkins_build.sh                      # first build, rolling, with defaults
# commit and push a change; Jenkins picks it up within two minutes
scripts/jenkins_build.sh rolling true          # rehearse a bad release: watch the Rollback stage
scripts/jenkins_build.sh blue-green false      # a blue-green release
scripts/jenkins_build.sh blue-green true       # a bad blue-green release, never switched to
```

`jenkins_build.sh` starts a build through Jenkins' API, streams its console and saves it. Pushing a commit starts one too, through polling. The app answers on `http://localhost:30080` (rolling) and `http://localhost:30081` (blue-green).

## Step 5: verify, record, remove

```bash
scripts/verify_live.sh | tee .live/verify-live.txt
scripts/teardown.sh | tee .live/teardown.txt
```

`verify_live.sh` records the repository settings, the images and their scan results, an attempt to move an existing tag (it must be refused), what the push role can and cannot do, what is running in the cluster, and the Jenkins build history. `teardown.sh` removes Jenkins and its volume, the cluster, and the AWS resources. It then searches by name and by tag for anything left behind, and deletes the local secret files.

## Without AWS

`scripts/cluster_up.sh --registry` adds a local registry on `localhost:5050`. With it, `scripts/jenkins_up.sh --local` runs the same pipeline with no AWS account at all, and `tests/e2e.sh` runs the deployment tests that CI runs.

## Decisions

- **Jenkins polls GitHub instead of receiving a webhook.** A webhook needs Jenkins reachable from the internet; week 5 opened an ngrok tunnel for it. Polling every two minutes costs up to two minutes of delay and exposes nothing.
- **Builds run on an agent, never on the controller.** The controller has 0 executors. The agent uses the host's Docker engine through its socket, which is root-equivalent on this machine: acceptable for a lab agent, not for production (see the README's Lab vs production table).
- **The tests run inside the image's own test stage.** The Python and libraries the tests use are exactly the ones that ship, and the agent needs no Python of its own.
- **One tag per build, deployment by digest.** Tags are immutable in ECR, so each build gets its own tag (`version-commit-bN`), and the cluster is given the digest, which cannot change.
- **A rolled-back release is a failed build.** The Rollback stage succeeds, but the build is marked FAILURE, because the release did not ship.
- **Configuration rolls back with the code.** The ConfigMap's name carries a hash of its content, so every change of settings is a new revision of the Deployment.
- **Blue-green is declarative too.** Each blue-green release applies an overlay that contains only the idle slot, so the live slot cannot be changed by mistake. The switch is the only imperative step.
- **The app refuses a bad setting at start-up.** That is what turns a configuration typo into a pod that never becomes ready, which both strategies then contain.

Decisions the live run forced (each is a commit in the history, released by the pipeline itself):

- **A generous deadline, and fail fast on a crash.** Kubernetes counts the image download against `progressDeadlineSeconds`; a first pull from ECR took 1 min 39 s and beat a 60 s deadline. The deadline is 180 s, and the deploy script stops as soon as a new pod crash-loops or cannot get its image.
- **An error budget, not zero tolerance.** One request timed out on the busy machine before a deployment changed anything, and a zero-tolerance gate rolled back a good release. More than 1% failed requests now fails the deploy.
- **The polling trigger lives in the job definition too.** Configuration as Code regenerates the job at each start and dropped the trigger only the Jenkinsfile had set.
- **The agent runs under an init.** Without one, Java as process 1 left orphaned build processes as zombies (101 in the live run).
- **The runtime image applies Debian's security updates.** That cut ECR's HIGH findings from 3 to 2; the remaining glibc findings have no fixed version yet.
