"""The entry point gunicorn loads: `gunicorn --config gunicorn.conf.py webapp.wsgi:app`.

gunicorn preloads this module in its master process, so an invalid setting stops the container
before any worker starts, with one readable line in the log instead of a traceback per worker.
"""

from __future__ import annotations

import os
import sys

from .app import create_app
from .config import ConfigError, load_config

try:
    app = create_app(load_config(os.environ))
except ConfigError as error:
    print(f"davine-webapp: refusing to start: {error}", file=sys.stderr, flush=True)
    raise SystemExit(3) from None
