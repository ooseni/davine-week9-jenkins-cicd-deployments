"""gunicorn settings for davine-webapp in a container."""

bind = "0.0.0.0:8080"

# One worker process with four threads. The request counters in /metrics live in the process,
# so one worker keeps them whole; Kubernetes adds capacity with more pods, not more workers.
workers = 1
threads = 4

# Load the app in the master first: a bad setting stops the container at once (see wsgi.py).
preload_app = True

# The heartbeat file goes to memory, because the container's root filesystem is read-only.
# /dev/shm is private to the container; gunicorn's own docs recommend it for this.
worker_tmp_dir = "/dev/shm"  # noqa: S108

# On SIGTERM, finish requests in flight for up to 20 s. The pod's 30 s grace period covers this
# plus the 5 s preStop pause that lets the Service stop sending new requests first.
graceful_timeout = 20
timeout = 30
keepalive = 2

accesslog = "-"
errorlog = "-"
loglevel = "info"
access_log_format = '%(h)s "%(r)s" %(s)s %(b)s %(M)sms'
