import pytest

from webapp.app import create_app
from webapp.config import Config

RELEASE = Config(env_mode="production", version="1.0.0", commit="abc1234", pod_name="pod-a")


@pytest.fixture
def app():
    return create_app(RELEASE)


@pytest.fixture
def client(app):
    return app.test_client()
