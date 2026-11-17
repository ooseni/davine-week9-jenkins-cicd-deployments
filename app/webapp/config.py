"""Runtime settings, read once from the environment and checked before the app serves anything.

A release with a wrong setting must fail at start-up. Kubernetes then sees a pod that never
becomes ready, the rolling update stops, and the pods of the previous release keep serving.
An app that starts anyway with a bad setting would pass its probes and serve wrong answers.
"""

from __future__ import annotations

import re
from collections.abc import Mapping
from dataclasses import dataclass

# The values week 7's ConfigMap used for ENV_MODE, plus staging.
ENV_MODES = ("development", "staging", "production")

_SEMVER = re.compile(r"\d+\.\d+\.\d+")
_COMMIT = re.compile(r"[0-9a-f]{7,40}")


class ConfigError(ValueError):
    """A setting is missing or invalid. The message names the setting and the allowed values."""


@dataclass(frozen=True)
class Config:
    env_mode: str
    version: str
    commit: str
    pod_name: str


def load_config(environ: Mapping[str, str]) -> Config:
    """Build the settings from environment variables, or raise ConfigError."""
    env_mode = environ.get("ENV_MODE", "").strip()
    if env_mode not in ENV_MODES:
        raise ConfigError(f"ENV_MODE must be one of {', '.join(ENV_MODES)}; got {env_mode!r}")

    # APP_VERSION and GIT_COMMIT are baked into the image at build time, so /version reports
    # what was built, not what a ConfigMap claims. In week 7 the version lived in the ConfigMap.
    version = environ.get("APP_VERSION", "").strip()
    if not _SEMVER.fullmatch(version):
        raise ConfigError(f"APP_VERSION must look like 1.2.3; got {version!r}")

    commit = environ.get("GIT_COMMIT", "").strip() or "unknown"
    if commit != "unknown" and not _COMMIT.fullmatch(commit):
        raise ConfigError(f"GIT_COMMIT must be a git SHA in lowercase hex; got {commit!r}")

    # Kubernetes passes the pod name through the downward API. HOSTNAME is the same value
    # inside a pod, and the container ID under plain Docker.
    pod_name = environ.get("POD_NAME", "").strip() or environ.get("HOSTNAME", "").strip() or "local"

    return Config(env_mode=env_mode, version=version, commit=commit, pod_name=pod_name)
