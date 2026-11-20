#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["typer==0.24.1", "pydantic==2.12.5"]
# ///
"""Owner-local macOS collector handoff. Never arms, signals or kills a broker."""
from __future__ import annotations

from datetime import datetime, timezone
import errno
import json
import os
from pathlib import Path
import secrets
import select
import stat
import subprocess
import time
from typing import Literal

from pydantic import BaseModel, ConfigDict, StrictBool, StrictStr, model_validator
import typer


class Refused(RuntimeError):
    pass


class Config(BaseModel):
    model_config = ConfigDict(extra="forbid")
    collector_label: StrictStr
    collector_plist: Path
    notifier_label: StrictStr
    notifier_plist: Path
    collector_status: Path
    ready_file: Path
    command: list[StrictStr]


class Health(BaseModel):
    status: Literal["running"]
    mode: Literal["disarmed"]
    observed_at: datetime
    process_id: StrictStr
    client_status: Literal["ready"]
    credential_persistence_pending: StrictBool
    executor_started: StrictBool
    strategies_started: StrictBool
    baseline_verified: StrictBool

    @model_validator(mode="after")
    def safe_readiness(self) -> Health:
        if self.credential_persistence_pending or self.strategies_started or not self.baseline_verified:
            raise ValueError("unsafe readiness")
        return self


class Ready(Health):
    nonce: StrictStr
    executor_port_ready: StrictBool

    @model_validator(mode="after")
    def connected_executor(self) -> Ready:
        if not self.executor_started or not self.executor_port_ready:
            raise ValueError("executor not ready")
        return self


def trusted(path: Path, *, directory: bool = False) -> None:
    info = path.lstat()
    expected = stat.S_ISDIR if directory else stat.S_ISREG
    if not expected(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise Refused("control paths must be owner-only regular files/directories")
    # Refuse symlinked ancestors too; /tmp is intentionally not a control root.
    for parent in path.absolute().parents:
        metadata = parent.lstat()
        if not stat.S_ISDIR(metadata.st_mode) or metadata.st_mode & 0o022:
            raise Refused("unsafe control-path ancestor")


def health(path: Path) -> Health:
    trusted(path)
    result = Health.model_validate_json(path.read_text())
    if result.observed_at.tzinfo is None:
        raise Refused("health timestamp has no timezone")
    age = (datetime.now(timezone.utc) - result.observed_at).total_seconds()
    if not 0 <= age <= 30 or not result.process_id.isdecimal():
        raise Refused("health is stale or has an invalid process ID")
    return result


def remaining(deadline: datetime, maximum: float) -> float:
    left = (deadline - datetime.now(timezone.utc)).total_seconds()
    if left <= 0:
        raise Refused("handoff permission expired")
    return min(left, maximum)


class Events:
    """Register before changing state; wait on kernel events, never sleeps."""
    def __init__(self) -> None:
        self.queue = select.kqueue()
        self.handles: list[int] = []

    def directory(self, path: Path) -> None:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        self.handles.append(fd)
        self.queue.control([select.kevent(fd, filter=select.KQ_FILTER_VNODE,
            flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
            fflags=select.KQ_NOTE_WRITE | select.KQ_NOTE_RENAME)], 0, 0)

    def process(self, pid: int) -> bool:
        try:
            self.queue.control([select.kevent(pid, filter=select.KQ_FILTER_PROC,
                flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                fflags=select.KQ_NOTE_EXIT)], 0, 0)
            return True
        except OSError as error:
            if error.errno == errno.ESRCH:
                return False  # Already exited, not a liveness guess.
            raise

    def wait_exit(self, pid: int, timeout: float) -> None:
        limit = time.monotonic() + timeout
        while True:
            left = limit - time.monotonic()
            if left <= 0:
                raise Refused("old process did not exit; no replacement started")
            events = self.queue.control(None, 8, left)
            if any(event.filter == select.KQ_FILTER_PROC and event.ident == pid for event in events):
                return

    def close(self) -> None:
        self.queue.close()
        for fd in self.handles:
            os.close(fd)


def launchctl(*args: str) -> str:
    result = subprocess.run(["/bin/launchctl", *args], capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise Refused("launchctl operation failed; inspect the owner-local service logs")
    return result.stdout


def service_pid(label: str) -> int:
    output = launchctl("print", f"gui/{os.getuid()}/{label}")
    for line in output.splitlines():
        if line.strip().startswith("pid = "):
            return int(line.strip().split(" = ", 1)[1])
    raise Refused("collector has no running launchd process")


def await_health(config: Config, old_pid: int, timeout: float = 300) -> None:
    events = Events()
    events.directory(config.collector_status.parent)
    limit = time.monotonic() + timeout
    try:
        while True:
            trusted(config.collector_status)
            current = Health.model_validate_json(config.collector_status.read_text())
            if int(current.process_id) != old_pid and not current.executor_started:
                health(config.collector_status)
                return
            left = limit - time.monotonic()
            if left <= 0 or not events.queue.control(None, 8, left):
                raise Refused("read-only recovery did not publish fresh healthy status")
    finally:
        events.close()


def run(config: Config, deadline: datetime) -> dict:
    if not hasattr(select, "kqueue"):
        raise Refused("this handoff controller requires macOS kqueue")
    remaining(deadline, 30)
    for path in (config.collector_plist, config.notifier_plist):
        trusted(path)
    trusted(config.collector_status.parent, directory=True)
    trusted(config.ready_file.parent, directory=True)
    if config.ready_file.exists() or config.ready_file.is_symlink():
        raise Refused("ready file must be a new exclusive path")
    if not config.command or not Path(config.command[0]).is_absolute():
        raise Refused("start command must use an absolute executable")
    current = health(config.collector_status)
    if current.executor_started:
        raise Refused("collector unexpectedly has an executor")
    pid = int(current.process_id)
    if pid <= 1 or service_pid(config.collector_label) != pid:
        raise Refused("collector health does not name its launchd process")
    events = Events()
    stopped = False
    notifier_stopped = False
    exited = False
    child: subprocess.Popen | None = None
    nonce = secrets.token_hex(24)
    try:
        if not events.process(pid):
            raise Refused("collector exited before the handoff began")
        events.directory(config.ready_file.parent)
        remaining(deadline, 30)
        launchctl("bootout", f"gui/{os.getuid()}/{config.notifier_label}")
        notifier_stopped = True
        remaining(deadline, 30)
        launchctl("bootout", f"gui/{os.getuid()}/{config.collector_label}")
        stopped = True
        events.wait_exit(pid, remaining(deadline, 60))
        exited = True
        remaining(deadline, 30)
        environment = dict(os.environ, BROKER_HANDOFF_DEADLINE=deadline.isoformat(),
            BROKER_HANDOFF_NONCE=nonce, BROKER_HANDOFF_READY=str(config.ready_file))
        # The trusted owner-supplied program must exec the broker VM, stay in
        # foreground, never arm/restore strategies, and publish atomic readiness.
        with open(config.ready_file.parent / (config.ready_file.name + ".log"), "x", opener=private_open) as log:
            child = subprocess.Popen(config.command, stdin=subprocess.DEVNULL,
                stdout=log, stderr=log, env=environment, start_new_session=True)
        alive = events.process(child.pid)
        ready_limit = time.monotonic() + 180
        while True:
            remaining(deadline, 30)
            if config.ready_file.exists():
                trusted(config.ready_file)
                ready = Ready.model_validate_json(config.ready_file.read_text())
                checked = health(config.ready_file)
                if ready.nonce != nonce or int(checked.process_id) != child.pid:
                    raise Refused("readiness receipt does not belong to this runtime")
                if not alive or child.poll() is not None:
                    raise Refused("candidate exited instead of remaining ready")
                return {"status": "disarmed_handoff_ready", "process_id": child.pid,
                    "armed": False, "strategies_started": False}
            if not alive or child.poll() is not None:
                raise Refused("candidate startup failed")
            wait = min(remaining(deadline, 180), ready_limit - time.monotonic())
            if wait <= 0:
                raise Refused("candidate readiness timed out")
            batch = events.queue.control(None, 8, wait)
            if not batch:
                raise Refused("candidate readiness timed out")
            if any(event.filter == select.KQ_FILTER_PROC and event.ident == child.pid for event in batch):
                alive = False
    except BaseException:
        # Never kill a candidate that might hold an unstored rotated token.
        # An unresponsive surviving runtime is an owner-action incident, not
        # permission to overlap credential refreshers or claim rollback success.
        if child is not None and child.poll() is None:
            raise Refused("candidate still alive: leave disarmed, do not force-stop or restart collector")
        if stopped:
            if not exited:
                events.wait_exit(pid, 300)
            launchctl("bootstrap", f"gui/{os.getuid()}", str(config.collector_plist))
            await_health(config, pid)
        if notifier_stopped:
            launchctl("bootstrap", f"gui/{os.getuid()}", str(config.notifier_plist))
        raise
    finally:
        events.close()


def private_open(path: str, flags: int) -> int:
    return os.open(path, flags, 0o600)


def main(config: Path, deadline: str) -> None:
    """Run an explicitly approved DISARMED handoff, not an ARM/order approval."""
    try:
        trusted(config)
        deadline = datetime.fromisoformat(deadline.replace("Z", "+00:00"))
        if deadline.tzinfo is None:
            raise Refused("deadline requires an explicit timezone")
        result = run(Config.model_validate_json(config.read_text()), deadline)
        typer.echo(json.dumps(result))
    except Exception as error:
        # Validation details may contain command arguments: never print them.
        typer.echo(json.dumps({"status": "refused", "error_type": type(error).__name__,
            "reason": str(error) if isinstance(error, Refused) else "invalid or unreadable handoff input"}), err=True)
        raise typer.Exit(1) from error


if __name__ == "__main__":
    typer.run(main)
