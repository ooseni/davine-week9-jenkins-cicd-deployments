# AI as a CI/CD development assistant | what it did and what held up

**Davine Technologies Internship Project, DevOps internship week 9.** The brief asked me to use an AI assistant to:

- generate and explain Jenkinsfiles;
- find pipeline failures and read Jenkins console logs;
- suggest improvements to the stages;
- write test cases;
- troubleshoot Docker builds;
- suggest safer deployment and rollback strategies;
- review the pipeline for security and efficiency.

No separate submission was required.

The assistant was **Claude (Anthropic's Opus 5.5 model, in Claude Code)**, used on 16 and 17 November 2026 while I rebuilt the week. I counted an answer only once a test, a scanner or the live run confirmed it. Section 8 lists where checking changed the answer.

## 1. Generating and explaining the Jenkinsfile

It drafted the declarative [`Jenkinsfile`](../Jenkinsfile) from the brief's flow (GitHub, Jenkins, build, test, Docker, deploy, verify, rollback). It explained each block in the terms used in [report section 4](report.md#4-pipeline-as-code-and-the-jenkinsfile). Two of its choices I kept on purpose:

- **Rollback is a stage of its own,** guarded by `when`, with `catchError` around Deploy and Verify, so a failed release shows a red Deploy and a green Rollback in the stage view. With a `post { failure { … } }` block the rollback would be hidden in the console.
- **The Jenkinsfile stays thin.** The logic lives in scripts that GitHub Actions can test on a real cluster, so the pipeline is not tested only by running it.

Jenkins' own declarative linter accepts the result, and rejects a deliberately broken copy, on every push ([`tests/test_jenkins.sh`](../tests/test_jenkins.sh)).

## 2. Finding pipeline failures and reading console logs

- **Rehearsal build #1 failed** with `Error cloning remote repo 'origin'`. From the console it traced the cause: the rehearsal's local copy of the repository was mounted into the controller, but checkout runs on the agent. The live run reads from GitHub, so this affected only the rehearsal.
- **A failed rollout now explains itself in the console.** It suggested printing the stuck pods, the Deployment's conditions and the last log lines of a pod that is not ready. A bad release's console therefore ends with the app's own words: `refusing to start: ENV_MODE must be one of development, staging, production; got 'prod'`.
- **The console API returned hidden annotations.** Jenkins' progressive-text API includes `ESC[8mha:…` notes. It strips them for the terminal and saves the clean `/consoleText` instead.

## 3. Suggesting improvements to the stages

Unit tests and static checks in parallel; tests inside the image's own test stage; one tag per build and deployment by digest; `disableConcurrentBuilds`, a timeout and a build discarder; a smoke test of the container before pushing it. All are in the Jenkinsfile; [report section 2](report.md#2-cicd-pipeline-optimisation) explains why.

## 4. Writing test cases

It wrote the 38 app tests, the 13 Terraform tests, the 17 redaction cases, the 17 Jenkins checks and the 25-check end-to-end test. I did not take their value on trust. I broke copies of the code seven ways (mutable tags, scanning off, `ecr:*` on the push role, trust opened to anyone, a mistyped `ENV_MODE` accepted, a security header dropped, unlimited metrics labels), and each break failed at least one test ([testing.md](testing.md#proving-the-tests-catch-mistakes)).

## 5. Troubleshooting Docker builds

- `ModuleNotFoundError: No module named 'webapp'` in the test stage: pytest was not putting the app folder on its import path; `pythonpath = ["."]` fixed it.
- ruff's security rule flagged `worker_tmp_dir = "/dev/shm"` (S108). It explained that gunicorn's documentation recommends exactly this in containers, so the line carries a reasoned `noqa` rather than a change.
- hadolint flagged `USER jenkins` (DL3066): user names may not resolve on the host. Both Jenkins images now use `USER 1000:1000`.

## 6. Safer deployment and rollback

Its suggestions, all in the manifests and scripts:

- `maxUnavailable: 0` with readiness probes;
- a 5-second `preStop` pause;
- a progress deadline, with the deploy script failing fast when a new pod crash-loops;
- rolling back to the recorded revision number rather than "one back";
- a ConfigMap whose name carries a content hash;
- blue-green with a preview Service, verified before the switch.

The traffic probe measured the result: in CI, no failed request during any rolling update, bad release, switch or switch back. In the live run, one request in 280 timed out once, before a deployment had changed anything (build #8 in [testing.md](testing.md#the-builds)); every other change served all its requests.

## 7. Reviewing the pipeline for security and efficiency

It ran Checkov and Trivy and fixed what they found rather than skipping it:

- a NetworkPolicy that blocks all outbound traffic from the app;
- the deployer limited to one named secret;
- numeric `USER` lines;
- explicit namespaces.

What remains accepted has a written reason ([`.trivyignore.yaml`](../.trivyignore.yaml), annotations in the manifests). It also flagged the agent's Docker socket as root-equivalent on the host. I kept it for the lab and recorded it as a production change.

## 8. Where checking changed the answer

The AI wrote the first drafts. Running them found these mistakes:

1. **Probes that killed healthy pods.** Pods requested 25m of CPU and probes used Kubernetes' 1-second default timeout. On a busy host a healthy pod answered slowly, failed its liveness probe and was restarted, during a blue-green switch. Pods now request 100m, and probes time out after 3 seconds.
2. **A digest check that could not be trusted.** It compared each pod's reported `imageID` with the pushed digest. For identical content pushed twice, containerd reports the first digest it stored. The pod spec already pins the digest, so that check was removed, and images are built with `--provenance=false`.
3. **Blue-green slots that never got manifest changes.** The first version created the slots once and then changed them with `kubectl set image`. Later manifest changes, like the probe fix, would never have reached them. Each release now applies an overlay with only the idle slot.
4. **Patches that stopped matching.** After the manifests gained an explicit namespace, the generated kustomize patches without one matched nothing, and every deploy failed. The end-to-end test caught it at once.
5. **A Jenkins setting that no longer exists.** `excludeClientIPFromCrumb` was removed from Jenkins; Configuration as Code refused to boot. The Jenkins test caught it before any real use.
6. **A test that misread its own result.** `awk … | grep -q .` under `pipefail` reported "no" when the answer was yes, because `grep -q` closes the pipe early.
7. **An empty strategy on the first build.** Jenkins exports parameters as environment variables only once a job knows them, so the first build's `$STRATEGY` was empty. The Jenkinsfile now takes it from `params`, which carry the defaults.

### What only the live run found

The live run against Amazon ECR found five more, and each fix went through the pipeline as a commit:

8. **A 60-second progress deadline that a slow download could beat.** The first release's image took 1 min 39 s to pull from ECR, so Kubernetes declared a healthy release stuck. The deadline is now 180 s, and the deploy script fails fast on a crash loop instead, so a broken release is still caught in under a minute (55 s and 46 s in the live run).
9. **A polling trigger that vanished at every restart.** Configuration as Code regenerates the job at start-up, which dropped the trigger the Jenkinsfile had set; a pushed commit sat unbuilt for 11 minutes. The trigger is now in the job definition too, and the Jenkins test checks it.
10. **101 zombie processes on the agent.** The agent image runs Java as process 1, which never reaps orphaned processes. The agent now runs under an init (tini); the count stayed at 0 through the following builds.
11. **A gate with zero tolerance.** One probe request timed out on the busy machine before the deployment had changed anything, and the pipeline rolled back a good release. The gate is now an error budget: more than 1% failed requests fails the deploy.
12. **Known vulnerabilities in the base image.** ECR's scan of the first images found 3 HIGH findings in Debian packages. Applying Debian's published security updates in the runtime stage removed the zlib ones; the glibc ones have no fix yet.

It also could not answer one question from the documentation: whether an ECR token outlives the one-hour role session that requested it. A test did: it does ([testing.md](testing.md#how-long-an-ecr-token-lives)).

What I took from this: the AI was right about the design and wrong about several details, and only running the code, on a busy machine and against real services, showed which was which.
