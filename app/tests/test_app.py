import importlib
import sys

import pytest


def test_home_page_shows_the_release(client):
    response = client.get("/")
    assert response.status_code == 200
    assert response.mimetype == "text/html"
    body = response.get_data(as_text=True)
    assert "release 1.0.0" in body
    assert "abc1234" in body
    assert "production" in body


def test_healthz_is_ok(client):
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.get_json() == {"status": "ok"}


def test_readyz_reports_ready_with_the_env_mode(client):
    response = client.get("/readyz")
    assert response.status_code == 200
    assert response.get_json() == {"status": "ready", "env_mode": "production"}


def test_version_reports_the_built_release(client):
    assert client.get("/version").get_json() == {
        "app": "davine-webapp",
        "version": "1.0.0",
        "commit": "abc1234",
        "env_mode": "production",
    }


def test_unknown_path_is_a_json_404(client):
    response = client.get("/admin")
    assert response.status_code == 404
    assert response.get_json() == {"error": "not found"}


def test_wrong_method_is_a_json_405(client):
    response = client.post("/version")
    assert response.status_code == 405
    assert response.get_json() == {"error": "method not allowed"}


@pytest.mark.parametrize("path", ["/", "/version", "/missing"])
def test_every_response_carries_the_security_headers(client, path):
    headers = client.get(path).headers
    assert headers["X-Content-Type-Options"] == "nosniff"
    assert headers["X-Frame-Options"] == "DENY"
    assert headers["Referrer-Policy"] == "no-referrer"
    assert "default-src 'none'" in headers["Content-Security-Policy"]


def test_api_responses_are_not_cached_but_the_page_may_be(client):
    assert client.get("/version").headers["Cache-Control"] == "no-store"
    assert "Cache-Control" not in client.get("/").headers


def test_wsgi_refuses_to_start_with_a_bad_env_mode(monkeypatch, capsys):
    monkeypatch.setenv("ENV_MODE", "prod")
    monkeypatch.setenv("APP_VERSION", "1.0.0")
    sys.modules.pop("webapp.wsgi", None)
    with pytest.raises(SystemExit) as stopped:
        importlib.import_module("webapp.wsgi")
    assert stopped.value.code == 3
    assert "refusing to start: ENV_MODE must be one of" in capsys.readouterr().err


def test_wsgi_builds_the_app_from_the_environment(monkeypatch):
    monkeypatch.setenv("ENV_MODE", "staging")
    monkeypatch.setenv("APP_VERSION", "2.3.4")
    monkeypatch.setenv("GIT_COMMIT", "0123abc")
    sys.modules.pop("webapp.wsgi", None)
    wsgi = importlib.import_module("webapp.wsgi")
    assert wsgi.app.test_client().get("/version").get_json()["version"] == "2.3.4"
