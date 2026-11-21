"""Inject a real signal after OS spawn, before the caller receives Popen's PID."""
from collections.abc import Callable
import json
import os
from pathlib import Path
import runpy
import signal
import subprocess
import sys
from types import FrameType

signal_number = int(sys.argv[1])
sys.argv = sys.argv[2:]
controller = sys.argv[0]


def interrupt_spawn(frame: FrameType, event: str, _arg: object) -> Callable | None:
    if event == "return" and frame.f_code is subprocess.Popen.__init__.__code__:
        arguments = frame.f_locals.get("args")
        if (isinstance(arguments, (list, tuple))
                and any(str(argument).endswith("handoff_fixture.exs") for argument in arguments)):
            candidate = frame.f_locals["self"]
            if candidate._child_created and candidate.pid:
                sys.settrace(None)
                path = Path(os.environ["FIXTURE_DIRECTORY"]) / "trace-candidate.json"
                descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                with os.fdopen(descriptor, "w") as output:
                    json.dump({"process_id": candidate.pid}, output)
                os.kill(os.getpid(), signal_number)
                return None
    return interrupt_spawn


sys.settrace(interrupt_spawn)
runpy.run_path(controller, run_name="__main__")
