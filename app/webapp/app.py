"""davine-webapp: the week 7 web app, now built from source so the pipeline can test it.

Routes:
    /         the home page, showing the release and the pod that answered
    /healthz  liveness: the process is up and answering
    /readyz   readiness: the settings loaded, so the pod may receive traffic
    /version  the release as JSON, for scripts and the pipeline's Verify stage
    /metrics  Prometheus metrics (see metrics.py)
"""

from __future__ import annotations

from flask import Flask, Response, jsonify, render_template, request

from .config import Config
from .metrics import Metrics

SECURITY_HEADERS = {
    "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; "
    "frame-ancestors 'none'",
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Referrer-Policy": "no-referrer",
}


def create_app(config: Config) -> Flask:
    app = Flask(__name__)
    metrics = Metrics(config)
    app.extensions["davine_metrics"] = metrics

    def release() -> dict[str, str]:
        return {
            "app": "davine-webapp",
            "version": config.version,
            "commit": config.commit,
            "env_mode": config.env_mode,
            # Which pod answered: refresh the page during a rolling update and watch it change.
            "pod": config.pod_name,
        }

    @app.get("/")
    def home() -> str:
        return render_template("index.html", **release())

    @app.get("/healthz")
    def healthz() -> Response:
        return jsonify(status="ok")

    @app.get("/readyz")
    def readyz() -> Response:
        # The settings were checked before create_app ran, so a running app is ready. A release
        # that adds a dependency (a database, a queue) checks it here, not in /healthz:
        # failing readiness removes the pod from the Service, failing liveness restarts it.
        return jsonify(status="ready", env_mode=config.env_mode)

    @app.get("/version")
    def version() -> Response:
        return jsonify(release())

    @app.get("/metrics")
    def prometheus() -> Response:
        return Response(metrics.render(), mimetype="text/plain; version=0.0.4")

    @app.errorhandler(404)
    def not_found(_error) -> tuple[Response, int]:
        return jsonify(error="not found"), 404

    @app.errorhandler(405)
    def method_not_allowed(_error) -> tuple[Response, int]:
        return jsonify(error="method not allowed"), 405

    @app.after_request
    def finish(response: Response) -> Response:
        metrics.observe(request.path, response.status_code)
        response.headers.update(SECURITY_HEADERS)
        if request.path != "/":
            response.headers["Cache-Control"] = "no-store"
        return response

    return app
