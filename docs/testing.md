# Testing

**Davine Technologies Internship Project, DevOps internship week 9.** Three layers: checks that run on every push with no AWS credentials, an end-to-end deployment test on a real Kubernetes cluster in CI, and the live run of 17 November 2026 with Jenkins, Amazon ECR and the cluster.

## On every push (GitHub Actions, pinned images and checksummed binaries)

**Job 1: checks**

| Step | Tool and version | Result |
|---|---|---|
| Workflow lint | actionlint 1.7.12 | no issues |
| App unit tests | pytest 9.2 on Python 3.14.10, in the image's test stage | 38 of 38 pass, 100% line and branch coverage (at least 95% required) |
| App lint | ruff 0.17.5 (pycodestyle, pyflakes, isort, bugbear, pyupgrade, bandit) | no issues |
| Dockerfile lint | hadolint 2.15.1 | no issues in 3 Dockerfiles |
| Manifests | kubeconform 0.8.0, strict, Kubernetes 1.36 schemas | 15 of 15 rendered resources valid |
| Shell lint | ShellCheck 0.11.0 | no issues in 12 scripts and 3 test scripts |
| Redaction | bash | 17 of 17 cases pass |
| Terraform | fmt, validate, `terraform test` (1.17.1, mocked AWS provider) | 13 of 13 pass |
| Terraform lint | TFLint 0.66.0 | 0 issues |
| Security scan | Checkov 3.4.3 | Terraform 11 passed; rendered Kubernetes 277 passed, 9 skipped; Dockerfiles 194 passed, 1 skipped; each skip has a written reason |
| Security scan | Trivy 0.76.2 | 0 findings, 5 ignores, each with a written reason in `.trivyignore.yaml` |
| Secrets | gitleaks 8.30.1 over the full history | no leaks |

**Job 2: Jenkins.** [`tests/test_jenkins.sh`](../tests/test_jenkins.sh) builds the controller image and starts it with dummy secrets. 17 checks, all passing:

- Configuration as Code loads with no error;
- anonymous requests get 403 and a wrong password gets 401;
- the built-in node has 0 executors, and the TCP agent port is closed;
- the agent `docker-agent` exists with the `docker` label;
- the job reads `Jenkinsfile` from `main` of this repository, and polls GitHub every two minutes from the moment the controller starts;
- both credentials exist, and all 69 pinned plugins are active;
- Jenkins' declarative linter accepts the Jenkinsfile, and rejects a broken copy.

**Job 3: end to end.** [`tests/e2e.sh`](../tests/e2e.sh) creates a k3d cluster with a local registry and builds releases 1.0.0 and 1.1.0. It then acts as `jenkins-deployer`, exactly as Jenkins does. 25 checks:

1. **Rolling, first release:** deploy 1.0.0 and verify.
2. **Rolling update to 1.1.0:** a probe sends about ten requests a second throughout; no request may fail.
3. **Bad release** (`ENV_MODE=prod`): the deploy must fail, 1.1.0 must keep answering with no failed request, and the rollback must restore 1.1.0 and its configuration.
4. **Blue-green, first release** to the idle slot, verified through the preview Service, then switched.
5. **Blue-green switch to 1.1.0** under traffic, with no failed request.
6. **Instant switch back to 1.0.0,** with no failed request.
7. **A bad blue-green release** is never switched to; users stay on 1.0.0.
8. **NetworkPolicy:** an app pod cannot open an outbound connection, while a pod outside the namespace can (the control).

### The 13 Terraform tests

[`terraform/tests/registry.tftest.hcl`](../terraform/tests/registry.tftest.hcl) plans against a mocked AWS provider and asserts one decision per test:

- **Repository:** tags immutable; scan on push and KMS encryption; the lifecycle policy expires untagged images first and keeps the newest 10, with the "any" rule last as ECR requires; keeping fewer than 3 or more than 100 images is refused.
- **Who may assume the push role:** this account as principal, narrowed to the applying role's ARN; an explicit `trusted_principal_arn` replaces it; a wildcard or a user ARN is refused; sessions last at most an hour.
- **What the role may do:** only `ecr:GetAuthorizationToken` uses `Resource: "*"`; push and pull apply to this repository's ARN only, with exactly seven actions; no delete, policy, setting, tag, create or wildcard action; the inline policy is attached to the push role.

### Proving the tests catch mistakes

On 17 November 2026 I broke copies of the code seven ways. Each break failed at least one test, and the repository was untouched.

| Break | Failed |
|---|---|
| ECR tags made mutable | 1 Terraform test |
| Scan on push turned off | 1 Terraform test |
| `ecr:*` added to the push role | 2 Terraform tests |
| Trust policy opened to any principal | 1 Terraform test |
| A mistyped `ENV_MODE` accepted | 7 app tests |
| The `X-Content-Type-Options` header dropped | 3 app tests |
| Every request path recorded as a metrics label | 2 app tests |

## Live, 17 November 2026 (Jenkins, Amazon ECR in us-east-1, k3d)

Jenkins 2.580.2 and the k3d cluster ran on my machine (WSL2, 4 CPUs, 6 GB); the registry and the push role were real AWS resources. Times are UTC. Every transcript is in [`evidence/`](evidence), redacted.

### The builds

| Build | Started | Started by | Release | Result |
|---|---|---|---|---|
| [#1](evidence/jenkins-build-01-2026-11-17.txt) | 08:49 | me (first build) | rolling, 1.0.0 | **failed**: the image took 1 min 39 s to pull from ECR, past the 60 s progress deadline, so a good release was declared stuck; there was nothing earlier to roll back to |
| [#2](evidence/jenkins-build-02-2026-11-17.txt) | 08:59 | polling, the fix commit | rolling, 1.0.0 | passed; 263 requests during the update, 0 failed |
| [#3](evidence/jenkins-build-03-2026-11-17.txt) | 09:02 | me | blue-green, 1.0.0 | passed; the first release went to green, was verified through the preview Service (11 checks), then switched |
| [#4](evidence/jenkins-build-04-2026-11-17.txt) | 09:05 | polling, the 1.1.0 commit | rolling, 1.0.0 to 1.1.0 | passed; 287 requests during the update, 0 failed: 179 answered by 1.0.0, then 108 by 1.1.0 |
| [#5](evidence/jenkins-build-05-2026-11-17.txt) | 09:08 | me | blue-green, 1.0.0 to 1.1.0 | passed; 1.1.0 verified on blue, then the switch: 35 requests, 0 failed; green kept 2 pods of 1.0.0 for an instant switch back |
| [#6](evidence/jenkins-build-06-2026-11-17.txt) | 09:11 | me, bad release | rolling, `ENV_MODE=prod` | **failed as intended**: the script failed fast 55 s after applying, when a new pod hit `CrashLoopBackOff`; the console quotes the app's reason; 297 requests during it, 0 failed; Rollback returned to revision 3 (1.1.0) and verified 12 of 12 |
| [#7](evidence/jenkins-build-07-2026-11-17.txt) | 09:14 | me, bad release | blue-green | **aborted by me**: the machine was overloaded (another k3d cluster crash-looping, an image layer taking 332 s to unpack), and blue-green pods were failing their probes before this build deployed anything |
| [#8](evidence/jenkins-build-08-2026-11-17.txt) | 10:17 | polling, a fix commit | rolling, 1.1.0 | **failed**: 1 of 280 probe requests timed out ([log](evidence/jenkins-build-08-traffic-probe-2026-11-17.log)) at 10:20:09, before the Deployment changed at 10:20:10; the zero-tolerance gate rolled back a good release |
| [#9](evidence/jenkins-build-09-2026-11-17.txt) | 10:25 | polling, the error budget fix | rolling, 1.1.0 | passed; 286 requests, 0 failed |
| [#10](evidence/jenkins-build-10-2026-11-17.txt) | 10:28 | me, bad release | blue-green, `ENV_MODE=prod` | **failed as intended**: green failed fast 46 s after applying, the switch was never made, users stayed on blue; Rollback scaled green to 0 and verified blue |
| [#11](evidence/jenkins-build-11-2026-11-17.txt) | 10:41 | polling, the security update commit | rolling, 1.1.0 | passed; 369 requests, 0 failed |

Five builds were started by commits through polling, as a team would release; the others I started to rehearse a strategy or a bad release.

### Verified afterwards

[`verify_live.sh`](../scripts/verify_live.sh), [transcript](evidence/verify-live-2026-11-17.txt): **22 passed, 0 failed.**

- **Repository:** tags immutable, scan on push, KMS encryption, 2 lifecycle rules.
- **Images:** 10, one per build that reached Push, each with its own tag, each scan complete. Moving an existing tag to another image was refused with `ImageTagAlreadyExistsException`.
- **Scan results:** builds 1 to 10 had 3 HIGH, 12 MEDIUM and 3 LOW findings, all in Debian packages of the base image. Build 11 applies the published security updates: 2 HIGH, 11 MEDIUM, 3 LOW. The two HIGH findings left are in glibc 2.41-12+deb13u4, for which Debian has no fixed version yet.
- **The push role, acting as it:** a registry token and an image pull are allowed; listing repositories, deleting an image, creating a repository and listing S3 buckets are denied. IAM's policy simulator agrees: `ecr:PutImage` allowed on this repository only; deletes, policy changes and `iam:CreateAccessKey` denied.
- **The cluster** runs the image from ECR by digest, and that digest is in ECR. The pull secret names the ECR registry. The rollout history shows each release by Jenkins build, including the rollbacks.

### How long an ECR token lives

ECR's documentation says a token lasts 12 hours, but says nothing about a token requested through an assumed role whose session lasts one hour. I tested it ([transcript](evidence/ecr-token-lifetime-2026-11-17.txt)): both tokens minted that morning still read an image manifest (HTTP 200) after their role sessions had ended; without a token the request got 401. Listing tags with the same tokens got 403, because the role has no `ecr:ListImages`.

### The end-to-end test on this machine

[`tests/e2e.sh`](../tests/e2e.sh) ran on the same machine that morning, before the live run: 25 of 25 ([transcript](evidence/e2e-local-2026-11-17.txt)).

### The teardown

[`teardown.sh`](../scripts/teardown.sh), [transcript](evidence/teardown-2026-11-17.txt): **8 passed, 0 failed.** It removed Jenkins and its volume, then the cluster. `terraform destroy` removed the 4 AWS resources, the repository with its 10 images included. Searches then found nothing left: no `davine-wk9` repository or role, no resource tagged with this project, no cluster, container or volume, no secret file in `.live/`, and no lab image in Docker. The estimated AWS cost is well under one US cent. About 0.5 GB of images were stored for about four hours, and image pulls were inside the free data transfer allowance.

### What the live run does not cover

- **Blue-green's instant switch back** ran in the end-to-end test, not in a live Jenkins build: in the live run, the one blue-green release that failed (#10) never reached users, so there was nothing to switch back.
- **Load:** the traffic probe sends about ten requests a second, enough to show whether users see errors during a change, not how the app behaves under real load.
- **Restores of Jenkins itself:** its configuration is code, but its build history lives in a Docker volume that was not backed up.
