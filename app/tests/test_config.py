import pytest

from webapp.config import ENV_MODES, ConfigError, load_config

GOOD = {"ENV_MODE": "production", "APP_VERSION": "1.0.0", "GIT_COMMIT": "abc1234"}


def env(**changes):
    merged = {**GOOD, **changes}
    return {k: v for k, v in merged.items() if v is not None}


@pytest.mark.parametrize("mode", ENV_MODES)
def test_accepts_every_known_env_mode(mode):
    assert load_config(env(ENV_MODE=mode)).env_mode == mode


@pytest.mark.parametrize("mode", ["prod", "Production", "dev", "", "production;rm"])
def test_rejects_a_mistyped_env_mode(mode):
    # The pipeline's controlled bad release sets ENV_MODE=prod: it must stop the app.
    with pytest.raises(ConfigError, match="ENV_MODE must be one of"):
        load_config(env(ENV_MODE=mode))


def test_rejects_a_missing_env_mode():
    with pytest.raises(ConfigError, match="ENV_MODE"):
        load_config(env(ENV_MODE=None))


def test_trims_whitespace_around_values():
    config = load_config(env(ENV_MODE=" staging ", APP_VERSION=" 1.1.0 "))
    assert (config.env_mode, config.version) == ("staging", "1.1.0")


@pytest.mark.parametrize("version", ["", "1.0", "v1.0.0", "1.0.0-rc1", "latest"])
def test_rejects_a_version_that_is_not_semver(version):
    with pytest.raises(ConfigError, match="APP_VERSION"):
        load_config(env(APP_VERSION=version))


def test_commit_defaults_to_unknown_when_not_baked_in():
    assert load_config(env(GIT_COMMIT=None)).commit == "unknown"


@pytest.mark.parametrize("commit", ["ABC1234", "abc12", "not-a-sha", "abc1234 "])
def test_rejects_a_commit_that_is_not_a_sha(commit):
    if commit.strip() == "abc1234":
        assert load_config(env(GIT_COMMIT=commit)).commit == "abc1234"
        return
    with pytest.raises(ConfigError, match="GIT_COMMIT"):
        load_config(env(GIT_COMMIT=commit))


def test_pod_name_prefers_the_downward_api_then_hostname():
    assert load_config(env(POD_NAME="web-1", HOSTNAME="h")).pod_name == "web-1"
    assert load_config(env(HOSTNAME="h")).pod_name == "h"
    assert load_config(env()).pod_name == "local"
