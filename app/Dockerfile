# davine-webapp image. Three stages, all built by the Jenkins pipeline:
#   build    installs the pinned dependencies into a virtualenv and compiles the app
#   test     build + test tools; the pipeline runs pytest and ruff in it, so the tests run on
#            the same Python and the same dependencies that ship
#   runtime  a fresh slim image with only the virtualenv and the app, run as a non-root user
#
# docker build --target runtime --build-arg APP_VERSION=1.0.0 --build-arg GIT_COMMIT=$(git rev-parse --short HEAD) -t davine-webapp app/

# The base image is pinned by digest, so a rebuild of the same commit uses the same base. Both
# build and runtime start from this untouched stage.
FROM python:3.14.10-slim-trixie@sha256:9aaa474097d094040649f2162a627c0049b408f52138d980916788d80f04802f AS python

FROM python AS build
ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_ROOT_USER_ACTION=ignore \
    PYTHONDONTWRITEBYTECODE=1 \
    PATH=/opt/venv/bin:$PATH
WORKDIR /src
RUN python -m venv /opt/venv
# Every package, including dependencies of dependencies, is pinned by version and hash.
COPY requirements.txt .
RUN pip install --require-hashes --no-deps -r requirements.txt
COPY gunicorn.conf.py .
COPY webapp/ webapp/
RUN python -m compileall -q webapp

FROM build AS test
COPY requirements-dev.txt .
RUN pip install --require-hashes --no-deps -r requirements-dev.txt
COPY pyproject.toml .
COPY tests/ tests/
CMD ["pytest"]

FROM python AS runtime
# Apply the Debian security updates published since the base image was built. ECR's scan of the
# first live images found 3 HIGH findings in OS packages; zlib's had a fixed version available.
RUN apt-get update \
 && apt-get upgrade -y --no-install-recommends \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --system --gid 10001 app \
 && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app
WORKDIR /app
COPY --from=build /opt/venv /opt/venv
COPY --from=build /src/gunicorn.conf.py ./
COPY --from=build /src/webapp ./webapp
# The release is baked in here, after the slow layers, so a new version reuses their cache.
ARG APP_VERSION=0.0.0
ARG GIT_COMMIT=unknown
ENV PATH=/opt/venv/bin:$PATH \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    APP_VERSION=${APP_VERSION} \
    GIT_COMMIT=${GIT_COMMIT}
USER 10001:10001
EXPOSE 8080
# For plain Docker and the pipeline's smoke test. Kubernetes ignores it and uses its own probes.
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/healthz', timeout=2)"]
CMD ["gunicorn", "--config", "gunicorn.conf.py", "webapp.wsgi:app"]
