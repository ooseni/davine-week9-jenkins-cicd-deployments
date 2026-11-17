import re

from webapp.config import Config
from webapp.metrics import Metrics

# One sample line of the Prometheus text format: name, optional labels, a number.
SAMPLE = re.compile(r'^[a-z_]+(\{([a-z_]+="[^"]*",?)+\})? [0-9.e+-]+$')


def test_build_info_names_the_release(client):
    body = client.get("/metrics").get_data(as_text=True)
    assert (
        'davine_webapp_build_info{version="1.0.0",commit="abc1234",env_mode="production"} 1' in body
    )


def test_metrics_use_the_prometheus_text_format(client):
    response = client.get("/metrics")
    assert response.mimetype == "text/plain"
    assert "version=0.0.4" in response.headers["Content-Type"]
    for line in response.get_data(as_text=True).splitlines():
        assert line.startswith("# ") or SAMPLE.match(line), line


def test_requests_are_counted_by_path_and_status(client):
    client.get("/version")
    client.get("/version")
    client.get("/nope")
    body = client.get("/metrics").get_data(as_text=True)
    assert 'davine_webapp_http_requests_total{path="/version",code="200"} 2' in body
    assert 'davine_webapp_http_requests_total{path="other",code="404"} 1' in body


def test_unknown_paths_cannot_create_new_label_values(client):
    for n in range(50):
        client.get(f"/scan/{n}")
    body = client.get("/metrics").get_data(as_text=True)
    assert "/scan/" not in body
    assert 'path="other",code="404"} 50' in body


def test_label_values_are_escaped():
    odd = Config(env_mode='pro"d\\x\n', version="1.0.0", commit="abc1234", pod_name="p")
    text = Metrics(odd, clock=lambda: 1700000000.0).render()
    assert 'env_mode="pro\\"d\\\\x\\n"' in text
    assert "davine_webapp_start_time_seconds 1700000000.000" in text
