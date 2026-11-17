# The Jenkins controller, configured entirely as code: pinned plugins (plugins.txt) and
# Configuration as Code (casc/jenkins.yaml). No setup wizard, no clicks in the UI. Week 5 set
# Jenkins up by hand; its "Lab vs production" table named configuration as code as the fix.
FROM jenkins/jenkins:2.580.2-lts-jdk21@sha256:74401de6a6f92e1afe1b02d1c8e3d0c33f263bfb5275dd8813f9150355f2367b

# Skip the setup wizard: the admin user, security and the job come from casc/jenkins.yaml.
ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false -Xmx768m" \
    CASC_JENKINS_CONFIG=/usr/share/jenkins/casc

COPY --chown=jenkins:jenkins plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt --latest false

COPY --chown=jenkins:jenkins casc/ /usr/share/jenkins/casc/

# The base image already runs as the jenkins user (UID and GID 1000); stated here, by number, so
# it cannot silently change.
USER 1000:1000

HEALTHCHECK --interval=10s --timeout=5s --start-period=60s --retries=6 \
  CMD ["curl", "-fs", "-o", "/dev/null", "http://127.0.0.1:8080/login"]
