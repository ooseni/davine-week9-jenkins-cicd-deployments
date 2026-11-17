# Week 9 report | Advanced CI/CD and deployment strategies

**Davine Technologies Internship Project, DevOps internship week 9.** A short report on the week's topics, each explained with the pipeline in this repository as the worked example. The live results are in [section 12](#12-what-the-live-run-showed).

## 1. How a commit becomes a running release

A CI/CD pipeline turns a commit into a running release without a person copying files or typing deploy commands. Each stage exists to catch one kind of problem as early, and as cheaply, as possible:

| Stage | What it does here | What it catches |
|---|---|---|
| Checkout | fetches the exact commit from GitHub | builds from the wrong code |
| Build | installs hash-pinned dependencies and compiles the app in a Docker build stage | a broken dependency or syntax error |
| Test | pytest (38 tests, 100% coverage) in parallel with ruff, hadolint and kubeconform | wrong behaviour, unsafe code, invalid manifests |
| Package | builds the runtime image and smoke-tests it as a container | an image that does not start, or runs as root |
| Push | pushes to Amazon ECR, then deploys by the image's digest | "works on my machine": the cluster runs exactly the bytes that were tested |
| Deploy | rolling update or blue-green switch on Kubernetes | a release that cannot become ready |
| Verify | asks the running app its version, reads `/metrics`, checks every pod's image | a release that started but is not the one intended |
| Rollback | runs only if Deploy or Verify failed, and verifies the previous release again | a bad release staying live |

## 2. CI/CD pipeline optimisation

A fast pipeline gets used; a slow one gets bypassed. What this pipeline does to stay fast and safe:

- **Parallel stages.** Unit tests and static checks do not depend on each other, so they run at the same time (`parallel` in the Jenkinsfile).
- **Layer caching.** The Dockerfile copies the dependency list before the code, so a code change reuses the cached dependency layer. The version is set after the slow layers for the same reason.
- **Fail fast.** Cheap checks (lint, unit tests) run before the expensive ones (image build, push, deploy).
- **Build once, deploy by digest.** The image is built and tested once; Deploy refers to it by `sha256` digest, so no later step can pick up different bytes.
- **Guard rails.** `timeout(30 min)` stops a hung build, `disableConcurrentBuilds()` stops two deploys racing on the cluster, and `buildDiscarder` keeps 30 builds of history.
- **A thin Jenkinsfile.** The deploy, verify and rollback logic lives in shell scripts, so it can be tested outside Jenkins (in GitHub Actions, on a real cluster) and reused by any CI tool.

## 3. Jenkins: advanced concepts

- **Controller and agents.** The controller schedules and stores builds; agents run them. Here the controller has **0 executors**, so no build can run on it, and builds run on a separate agent container. Week 5 ran builds on the controller with `agent any`.
- **Configuration as Code (JCasC).** The security realm, the agent, the credentials, the global variables and the job itself are in [`jenkins.yaml`](../jenkins/controller/casc/jenkins.yaml). The controller can be thrown away and rebuilt identical, with no clicks in the UI.
- **Pinned plugins.** All 69 plugins are pinned to exact versions in [`plugins.txt`](../jenkins/controller/plugins.txt), so an image built next month is the same as today's.
- **Credentials.** Jenkins stores the registry token and the kubeconfig as credentials and injects them only into the steps that need them (`withCredentials`). It masks their values in the console log.
- **Triggers.** A webhook needs Jenkins to be reachable from the internet; week 5 used an ngrok tunnel for that. This week Jenkins **polls** GitHub every two minutes (`pollSCM`), so nothing on the machine is exposed. The cost is up to two minutes of delay.
- **Agents over WebSocket.** The agent connects to the controller over the web port, so the separate TCP agent port stays closed.

## 4. Pipeline as code and the Jenkinsfile

A Jenkinsfile in the repository means the pipeline is versioned, reviewed and rolled back like any other code. The declarative syntax used here:

| Block | Used for |
|---|---|
| `agent { label 'docker' }` | where builds run |
| `parameters` | `STRATEGY` (rolling or blue-green) and `SIMULATE_BAD_RELEASE` |
| `triggers` | `pollSCM('H/2 * * * *')`; `H` spreads jobs so they do not all poll at the same second |
| `options` | timestamps, timeout, no concurrent builds, build history |
| `environment` | names and values every stage shares |
| `stages`, `parallel` | the stages and the parallel test branch |
| `when` | Verify runs only after a good Deploy; Rollback runs only after a failure |
| `catchError` | a failed Deploy marks the build failed but lets Rollback run |
| `post` | archives logs and removes local images whatever the result |

## 5. Build automation and environment variables

Environment variables carry everything a stage needs without hard-coding it:

- **Pipeline variables** in the `environment` block: `APP_NAME`, `NAMESPACE`, `ENV_MODE`, the deploy strategy.
- **Computed per build** in Checkout: `APP_VERSION` (from the `VERSION` file), `GIT_SHORT` and `IMAGE_TAG` (`1.1.0-<commit>-b<build number>`).
- **Global variables** from Configuration as Code: `ECR_REPOSITORY_URL` and `DAVINE_NODE_HOST`. The repository URL contains the AWS account ID, so it lives in Jenkins' configuration, set at start-up from Terraform's output, and never in git.
- **Secrets** never go in variables in the Jenkinsfile; they come from credentials at run time.

## 6. Automated testing

| Layer | Where | What |
|---|---|---|
| Unit | Test stage and CI | 38 pytest tests: settings checks, every endpoint, security headers, metrics format |
| Static | Test stage and CI | ruff (Python), hadolint (Dockerfiles), kubeconform (Kubernetes 1.36 schemas), ShellCheck, Checkov, Trivy |
| Container smoke test | Package stage | the built image starts, turns healthy, runs as user 10001, reports its version, and refuses a bad setting |
| Post-deploy verification | Verify stage | the live Service answers with the new version, and every pod runs the pushed digest |
| End to end | CI, on a k3d cluster | rolling update under traffic, bad release and rollback, blue-green switch and switch back, network policy |
| Infrastructure | CI | 13 Terraform tests against a mocked AWS provider |
| Jenkins itself | CI | Configuration as Code loads, security settings hold, Jenkins' linter accepts the Jenkinsfile |

## 7. Docker image build and push

- **Multi-stage build.** `build` installs dependencies, `test` adds pytest and ruff, `runtime` starts again from a clean slim image and copies only the app and its virtualenv. The tests run on the same Python and libraries that ship.
- **Non-root and read-only.** The image runs as UID 10001; Kubernetes adds a read-only root filesystem and drops every Linux capability.
- **Tags and digests.** A tag is a name that can move; a digest is the hash of the content and cannot. Amazon ECR is set to **immutable tags**, so a tag can never be pointed at different bytes. The pipeline still deploys by digest.
- **Registry authentication.** ECR issues 12-hour tokens. Here a token is minted through an IAM role that can push and pull this one repository only, so Jenkins never holds an AWS access key.
- **Scan on push.** ECR scans every pushed image for known vulnerabilities, at no charge.

## 8. Deployment automation

The Deploy stage writes a small kustomize overlay for each release: the image digest, `ENV_MODE`, and a `kubernetes.io/change-cause` that names the Jenkins build. It applies the overlay as the `jenkins-deployer` account, which can change the app in one namespace and nothing else, then waits with `kubectl rollout status`. The ConfigMap name carries a hash of its content, so a configuration change is a new revision, and a rollback restores the old configuration with the old image.

## 9. Rolling deployment

Kubernetes replaces pods a few at a time. Here `maxSurge: 1` adds one new pod before removing an old one, and `maxUnavailable: 0` never drops below three ready pods. A new pod receives traffic only after its readiness probe passes, and an old pod keeps serving for 5 seconds after it is told to stop (`preStop`), while the Service stops sending it new requests.

- **Good:** no extra environment, gradual, built into Kubernetes.
- **Limits:** for a while two versions serve at once, so they must be compatible; a rollback is another rolling update, not instant.
- **A bad release:** if a new pod never becomes ready, the rollout stops with the old pods still serving. The deploy script stops waiting as soon as a new pod crash-loops or cannot get its image; otherwise, after `progressDeadlineSeconds` (180 s here), Kubernetes reports the rollout as failed. The deadline counts the image download too, and the live run showed why it must be generous: a first pull from ECR took 1 min 39 s.
- **Did users notice?** A probe sends about ten requests a second through the Service during every change. The deploy fails if more than 1% of them fail, and every failure is reported.

## 10. Blue-green deployment

Two complete copies, blue and green. Users reach one through the live Service. A release goes to the idle copy, is tested through a separate preview Service, and the live Service's selector is switched in one API call.

- **Good:** the release is tested in place before users see it; rollback is the same switch in reverse, so it is instant; only one version serves at a time.
- **Limits:** double the capacity while both run; databases and other shared state must work with both versions; long-lived connections may stay on the old copy until they close.

## 11. Rollback strategies

| Strategy | How | When |
|---|---|---|
| Automatic rollback in the pipeline | the Rollback stage: `kubectl rollout undo --to-revision=<recorded>`, then verify | a release fails its readiness or verification (used here) |
| Blue-green switch back | point the live Service back at the old slot | the new slot misbehaves after the switch (used here) |
| Revert the commit | the pipeline deploys the previous code as a new release | the problem is in the code and must stay fixed in git (GitOps) |
| Roll forward | ship a fix as a new release | the fix is small and rollback would lose data |
| Feature flags | turn the new behaviour off without deploying | changes too risky to tie to a deploy |

Two details matter. **Roll back to a recorded revision, not "one back":** if a failed deploy never created a new revision, `rollout undo` with no argument goes one release too far. **Configuration must roll back with the code:** a ConfigMap edited in place is not part of the Deployment's history, which is why the name here carries a content hash.

### Rolling and blue-green side by side

| | Rolling | Blue-green |
|---|---|---|
| Extra capacity | one pod (`maxSurge`) | a whole second copy |
| Versions serving at once | two, during the rollout | one |
| Tested before users see it | no, readiness only | yes, through the preview Service |
| Rollback | another rolling update | one selector change, instant |
| A release that cannot start | stuck rollout, old pods serve, pipeline rolls back | never switched to |

## 12. What the live run showed

On 17 November 2026 Jenkins ran 11 builds of this repository, pushed 10 images to Amazon ECR and released them to the cluster. The full record is in [testing.md](testing.md#live-17-november-2026-jenkins-amazon-ecr-in-us-east-1-k3d).

- **Commit to release with no hands on Jenkins.** A commit of release 1.1.0 was picked up by polling and rolled out: 287 requests during the update, 0 failed, with 1.0.0 answering until its pods were replaced.
- **A bad release, contained.** With `ENV_MODE=prod` the new pod crash-looped; the deploy failed fast after 55 seconds, users were still answered by 1.1.0 (297 requests, 0 failed), and the Rollback stage restored and verified the previous revision.
- **Blue-green.** A release was tested on the idle slot before the switch (0 of 35 requests failed during it), and a bad blue-green release was never switched to.
- **Least privilege held.** Jenkins' token could push and pull the one repository and nothing else; moving an existing tag was refused.
- **Five problems found only by running it,** each fixed with a commit the pipeline then released: an image pull longer than the progress deadline; a polling trigger lost at every Jenkins restart; 101 zombie processes on the agent; a zero-tolerance traffic gate that rolled back a good release over one stray timeout; and 3 HIGH vulnerabilities in the base image, reduced to 2 by applying Debian's security updates (the remaining glibc ones have no fix yet).

## Sources

[Jenkins Pipeline syntax](https://www.jenkins.io/doc/book/pipeline/syntax/), [Jenkins Configuration as Code](https://www.jenkins.io/projects/jcasc/), [Kubernetes Deployments](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/), [Liveness, readiness and startup probes](https://kubernetes.io/docs/concepts/configuration/liveness-readiness-startup-probes/), [Amazon ECR image tag mutability](https://docs.aws.amazon.com/AmazonECR/latest/userguide/image-tag-mutability.html), [Amazon ECR image scanning](https://docs.aws.amazon.com/AmazonECR/latest/userguide/image-scanning.html), [Amazon ECR registry authentication](https://docs.aws.amazon.com/AmazonECR/latest/userguide/registry_auth.html), [Blue/Green Deployments on AWS (whitepaper)](https://docs.aws.amazon.com/whitepapers/latest/blue-green-deployments/welcome.html).
