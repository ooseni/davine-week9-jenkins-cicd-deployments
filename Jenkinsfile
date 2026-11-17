// davine-webapp delivery pipeline (Davine Technologies internship, week 9).
//
//   GitHub -> Checkout -> Build -> Test -> Package -> Push (Amazon ECR) -> Deploy (Kubernetes)
//          -> Verify -> Rollback, which runs only when Deploy or Verify fails
//
// The stages are thin: the deploy, verify and rollback logic lives in scripts/, where it is
// tested on a real cluster by tests/e2e.sh in GitHub Actions, outside Jenkins.
pipeline {
    // Builds run on the agent container, never on the controller (it has 0 executors).
    agent { label 'docker' }

    parameters {
        choice(name: 'STRATEGY', choices: ['rolling', 'blue-green'],
               description: 'rolling: replace pods one at a time behind NodePort 30080. ' +
                            'blue-green: release to the idle slot, test it, then switch NodePort 30081 to it.')
        booleanParam(name: 'SIMULATE_BAD_RELEASE', defaultValue: false,
                     description: 'Rehearse a failed release: deploy this build with ENV_MODE=prod, a typo the app ' +
                                  'refuses to start with. The rollout fails and the Rollback stage runs.')
    }

    // Jenkins asks GitHub for new commits every two minutes, so nothing has to reach in from the
    // internet. Week 5 used a webhook through an ngrok tunnel.
    triggers { pollSCM('H/2 * * * *') }

    options {
        timestamps()
        skipDefaultCheckout()                   // the Checkout stage below does it, once
        timeout(time: 30, unit: 'MINUTES')
        disableConcurrentBuilds()               // two deploys at once would race on the cluster
        buildDiscarder(logRotator(numToKeepStr: '30'))
    }

    environment {
        APP_NAME = 'davine-webapp'
        NAMESPACE = 'davine-space'
        // From params, which carry the defaults even on a job's very first build, when Jenkins has
        // not yet exported the parameters as environment variables.
        DEPLOY_STRATEGY = "${params.STRATEGY ?: 'rolling'}"
        ENV_MODE = "${params.SIMULATE_BAD_RELEASE ? 'prod' : 'production'}"
        STATE_DIR = "${WORKSPACE}/.deploy"
        // ECR_REPOSITORY_URL and DAVINE_NODE_HOST are global variables that Configuration as Code
        // sets from scripts/jenkins_up.sh, so the AWS account ID never appears in this repository.
        HADOLINT_IMAGE = 'hadolint/hadolint:v2.15.1@sha256:32dac94127fd60b7b7e3fbfc65e1383b9b5e25c9bfd7b8536de7a539fe68a12d'
    }

    stages {
        stage('Checkout') {
            steps {
                script {
                    def scmVars = checkout scm
                    env.GIT_COMMIT = scmVars.GIT_COMMIT
                    env.GIT_URL = scmVars.GIT_URL
                    env.GIT_SHORT = sh(script: 'git rev-parse --short=7 HEAD', returnStdout: true).trim()
                    env.APP_VERSION = readFile('VERSION').trim()
                    // Unique per build, because ECR tags are immutable: a tag can never be moved
                    // to different content.
                    env.IMAGE_TAG = "${env.APP_VERSION}-${env.GIT_SHORT}-b${env.BUILD_NUMBER}"
                    currentBuild.displayName = "#${env.BUILD_NUMBER} ${env.APP_VERSION} (${env.GIT_SHORT})"
                    currentBuild.description = params.STRATEGY + (params.SIMULATE_BAD_RELEASE ? ', bad release rehearsal' : '')
                }
                sh 'git log -1 --format="Building commit %h by %an: %s"'
            }
        }

        stage('Build') {
            steps {
                // The build stage installs the hash-pinned dependencies and compiles the app; the
                // test stage adds pytest and ruff on top. Docker's layer cache makes repeats fast.
                sh 'docker build --target build -t "$APP_NAME:build-$IMAGE_TAG" app/'
                sh 'docker build --target test -t "$APP_NAME:test-$IMAGE_TAG" app/'
            }
        }

        stage('Test') {
            parallel {
                stage('Unit tests') {
                    steps {
                        sh '''
                            mkdir -p reports
                            set +e
                            docker run --name "unit-$BUILD_TAG" "$APP_NAME:test-$IMAGE_TAG"
                            rc=$?
                            docker cp "unit-$BUILD_TAG:/src/reports/junit.xml" reports/junit.xml
                            docker rm "unit-$BUILD_TAG" >/dev/null
                            exit $rc
                        '''
                    }
                    post { always { junit testResults: 'reports/junit.xml', allowEmptyResults: false } }
                }
                stage('Static checks') {
                    steps {
                        sh 'docker run --rm "$APP_NAME:test-$IMAGE_TAG" sh -c "ruff check . && ruff format --check ."'
                        sh 'docker run --rm -i "$HADOLINT_IMAGE" < app/Dockerfile'
                        sh 'scripts/validate_manifests.sh'
                    }
                }
            }
        }

        stage('Package') {
            steps {
                sh '''
                    docker build --target runtime --provenance=false \
                      --build-arg APP_VERSION="$APP_VERSION" --build-arg GIT_COMMIT="$GIT_SHORT" \
                      --label org.opencontainers.image.title="$APP_NAME" \
                      --label org.opencontainers.image.version="$APP_VERSION" \
                      --label org.opencontainers.image.revision="$GIT_COMMIT" \
                      --label org.opencontainers.image.source="${GIT_URL%.git}" \
                      --label org.opencontainers.image.created="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                      -t "$ECR_REPOSITORY_URL:$IMAGE_TAG" app/
                '''
                sh 'scripts/smoke_test.sh "$ECR_REPOSITORY_URL:$IMAGE_TAG" "$APP_VERSION" "$GIT_SHORT"'
            }
        }

        stage('Push') {
            steps {
                withCredentials([usernamePassword(credentialsId: 'ecr-registry',
                                                  usernameVariable: 'REGISTRY_USERNAME',
                                                  passwordVariable: 'REGISTRY_PASSWORD')]) {
                    sh '''
                        export DOCKER_CONFIG="$WORKSPACE/.docker"   # this build's login only
                        registry="${ECR_REPOSITORY_URL%%/*}"
                        printf '%s' "$REGISTRY_PASSWORD" | docker login --username "$REGISTRY_USERNAME" --password-stdin "$registry"
                        docker push "$ECR_REPOSITORY_URL:$IMAGE_TAG"
                        docker inspect --format '{{index .RepoDigests 0}}' "$ECR_REPOSITORY_URL:$IMAGE_TAG" > image-ref.txt
                        docker logout "$registry"
                    '''
                }
                script { env.IMAGE_REF = readFile('image-ref.txt').trim() }
                echo "Pushed ${env.IMAGE_REF}. Deploying by digest, so the cluster runs exactly these bytes."
            }
        }

        stage('Deploy') {
            steps {
                script { env.DEPLOY_STARTED = 'true' }
                // A failure here marks the build failed but lets the Rollback stage run.
                catchError(buildResult: 'FAILURE', stageResult: 'FAILURE') {
                    withCredentials([file(credentialsId: 'k3d-deployer-kubeconfig', variable: 'KUBECONFIG'),
                                     usernamePassword(credentialsId: 'ecr-registry',
                                                      usernameVariable: 'REGISTRY_USERNAME',
                                                      passwordVariable: 'REGISTRY_PASSWORD')]) {
                        sh '''
                            export REGISTRY_SERVER="${ECR_REPOSITORY_URL%%/*}"
                            export CHANGE_CAUSE="Jenkins build #$BUILD_NUMBER: $APP_VERSION ($GIT_SHORT), ENV_MODE=$ENV_MODE"
                            if [ "$DEPLOY_STRATEGY" = blue-green ]; then
                                scripts/blue_green.sh deploy "$IMAGE_REF" "$APP_VERSION" "$ENV_MODE"
                            else
                                scripts/deploy_rolling.sh "$IMAGE_REF" "$ENV_MODE"
                            fi
                        '''
                    }
                }
            }
        }

        stage('Verify') {
            when { expression { currentBuild.currentResult == 'SUCCESS' } }
            steps {
                catchError(buildResult: 'FAILURE', stageResult: 'FAILURE') {
                    withCredentials([file(credentialsId: 'k3d-deployer-kubeconfig', variable: 'KUBECONFIG')]) {
                        sh '''
                            if [ "$DEPLOY_STRATEGY" = blue-green ]; then
                                scripts/verify.sh --blue-green "$APP_VERSION" "$IMAGE_REF"
                            else
                                scripts/verify.sh "$APP_VERSION" "$IMAGE_REF"
                            fi
                        '''
                    }
                }
            }
        }

        stage('Rollback') {
            when { expression { env.DEPLOY_STARTED == 'true' && currentBuild.currentResult == 'FAILURE' } }
            steps {
                withCredentials([file(credentialsId: 'k3d-deployer-kubeconfig', variable: 'KUBECONFIG')]) {
                    sh '''
                        if [ "$DEPLOY_STRATEGY" = blue-green ]; then
                            scripts/blue_green.sh rollback
                        else
                            scripts/rollback_rolling.sh
                        fi
                    '''
                }
                script { currentBuild.description += ', rolled back' }
            }
        }
    }

    post {
        always {
            archiveArtifacts artifacts: '.deploy/*.log, .deploy/*.env, reports/*.xml', allowEmptyArchive: true
            sh '''
                rm -rf "$WORKSPACE/.docker"
                docker image rm "$APP_NAME:build-$IMAGE_TAG" "$APP_NAME:test-$IMAGE_TAG" \
                  "$ECR_REPOSITORY_URL:$IMAGE_TAG" >/dev/null 2>&1 || true
            '''
        }
        success { echo "Release ${env.APP_VERSION} (${env.GIT_SHORT}) is live and verified." }
        failure { echo 'The build failed. If it got as far as Deploy, the Rollback stage restored the previous release.' }
    }
}
