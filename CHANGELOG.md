# Changelog

Releases of davine-webapp, the application the pipeline builds and deploys. The version lives in
[`VERSION`](VERSION); the pipeline bakes it into the image and tags each build
`<version>-<commit>-b<build number>`.

## 1.0.0

- Week 7's web app rebuilt from source as a Flask app served by gunicorn: home page, `/healthz`,
  `/readyz`, `/version` and Prometheus `/metrics`.
- Settings are checked at start-up: an unknown `ENV_MODE` stops the app with exit code 3, so a
  misconfigured release never becomes ready.
- Runs as a non-root user on a read-only filesystem.
