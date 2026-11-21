"""A real file-observing launchd process; no Mix build lock or broker client."""
import json
import os
from pathlib import Path
import signal
import threading

stop = threading.Event()
signal.signal(signal.SIGTERM, lambda *_: stop.set())
directory = Path(os.environ["FIXTURE_DIRECTORY"])
status = directory / "status.json"
observed = json.loads(status.read_text()) if status.exists() else {}
path = directory / "notifier-observed.jsonl"
temporary = path.with_suffix(".tmp")
temporary.write_text(json.dumps({"process_id": observed.get("process_id")}) + "\n")
temporary.chmod(0o600)
temporary.replace(path)
stop.wait()
