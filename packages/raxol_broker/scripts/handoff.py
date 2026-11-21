#!/usr/bin/env -S uv run --locked --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["typer==0.24.1", "pydantic==2.12.5"]
# ///
"""Owner-local macOS handoff. Only the verified read-only collector is signalled."""
from __future__ import annotations

from datetime import datetime, timezone
import errno
import json
import os
from pathlib import Path
import plistlib
import secrets
import select
import stat
import signal
import subprocess
import time
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, StrictBool, StrictStr, ValidationError, model_validator
import typer


class Refused(RuntimeError):
    def __init__(self, reason: str, *, phase: str = "preflight", state_changed: bool = False) -> None:
        super().__init__(reason)
        self.phase = phase
        self.state_changed = state_changed
        self.cleanup_incomplete = False
        self.candidate_process_id: int | None = None
        self.launch_outcome_unknown = False


class Config(BaseModel):
    model_config = ConfigDict(extra="forbid")
    collector_label: StrictStr
    collector_plist: Path
    notifier_label: StrictStr
    notifier_plist: Path
    collector_status: Path
    ready_file: Path
    command: list[StrictStr]
    ready_timeout_seconds: int = Field(default=600, strict=True, ge=1, le=900)
    drain_timeout_seconds: int = Field(default=60, strict=True, ge=1, le=120)
    recovery_timeout_seconds: int = Field(default=300, strict=True, ge=1, le=600)


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
    handoff_protocol: int = Field(default=0, strict=True)

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
        if (not stat.S_ISDIR(metadata.st_mode) or metadata.st_mode & 0o022
                or metadata.st_uid not in (0, os.getuid())):
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
        self.exited: set[int] = set()

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
                self.exited.add(pid)
                return False  # Already exited, not a liveness guess.
            raise

    def wait(self, timeout: float) -> list:
        events = self.queue.control(None, 8, timeout)
        self.exited.update(int(event.ident) for event in events
            if event.filter == select.KQ_FILTER_PROC and event.fflags & select.KQ_NOTE_EXIT)
        return events

    def wait_exit(self, pid: int, timeout: float) -> None:
        limit = time.monotonic() + timeout
        while pid not in self.exited:
            left = limit - time.monotonic()
            if left <= 0:
                raise Refused("old process did not exit; no replacement started")
            self.wait(left)

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


def service_loaded(label: str) -> bool:
    result = subprocess.run(["/bin/launchctl", "print", f"gui/{os.getuid()}/{label}"],
        capture_output=True, text=True, timeout=30)
    if result.returncode == 0:
        return True
    if "Could not find service" in result.stderr:
        return False
    raise Refused("cannot determine launchd service state")


def await_health(config: Config, old_pid: int | None, timeout: float = 300) -> None:
    events = Events()
    events.directory(config.collector_status.parent)
    limit = time.monotonic() + timeout
    try:
        while True:
            try:
                current = health(config.collector_status)
                if (int(current.process_id) != old_pid and not current.executor_started
                        and service_pid(config.collector_label) == int(current.process_id)):
                    return
            except (ValidationError, OSError, Refused):
                # Atomic publication may not exist or be healthy yet. Never
                # accept it; retain the bound and wait for another publication.
                pass
            left = limit - time.monotonic()
            if left <= 0 or not events.wait(left):
                raise Refused("read-only recovery did not publish fresh healthy status")
    finally:
        events.close()


def await_quiesced(path: Path, pid: int, nonce: str, events: Events, timeout: float) -> bool:
    limit = time.monotonic() + timeout
    while True:
        if pid in events.exited:
            raise Refused("collector exited during cooperative shutdown")
        if path.exists():
            trusted(path)
            report = json.loads(path.read_text())
            if report.get("nonce") != nonce or report.get("process_id") != str(pid):
                raise Refused("collector acknowledgement does not match this attempt")
            if report.get("status") == "blocked":
                return False
            if (report.get("status") == "quiesced" and report.get("client_stopped") is True
                    and report.get("journal_closed") is True):
                return True
            raise Refused("collector did not confirm safe credential shutdown")
        left = limit - time.monotonic()
        if left <= 0 or not events.wait(left):
            raise Refused("collector did not acknowledge cooperative shutdown")


def run(config: Config, deadline: datetime) -> dict:
    if not hasattr(select, "kqueue"):
        raise Refused("this handoff controller requires macOS kqueue")
    if remaining(deadline, 1801) > 1800:
        raise Refused("handoff deadline must be within thirty minutes")
    for path, label in ((config.collector_plist, config.collector_label),
                        (config.notifier_plist, config.notifier_label)):
        trusted(path)
        if plistlib.loads(path.read_bytes()).get("Label") != label:
            raise Refused("plist label does not match the configured service")
    trusted(config.collector_status.parent, directory=True)
    trusted(config.ready_file.parent, directory=True)
    request = config.collector_status.parent / "handoff-request.json"
    acknowledgement = config.collector_status.parent / "handoff-quiesced.json"
    candidate_file = config.ready_file.parent / (config.ready_file.name + ".candidate")
    for path in (config.ready_file, Path(str(config.ready_file) + ".tmp"),
                 request, acknowledgement, Path(str(acknowledgement) + ".tmp"), candidate_file):
        if path.exists() or path.is_symlink():
            raise Refused("handoff artifacts must use new exclusive paths")
    if not config.command or not Path(config.command[0]).is_absolute():
        raise Refused("start command must use an absolute executable")
    executable = Path(config.command[0]).resolve(strict=True)
    metadata = executable.stat()
    if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid not in (0, os.getuid())
            or metadata.st_mode & 0o022 or not os.access(executable, os.X_OK)):
        raise Refused("start executable is not trusted or executable")
    for parent in executable.parents:
        metadata = parent.lstat()
        if metadata.st_mode & 0o022 or metadata.st_uid not in (0, os.getuid()):
            raise Refused("unsafe executable ancestor")
    current = health(config.collector_status)
    if current.executor_started or current.handoff_protocol != 1:
        raise Refused("collector must support cooperative shutdown with no executor")
    pid = int(current.process_id)
    if pid <= 1 or service_pid(config.collector_label) != pid:
        raise Refused("collector health does not name its launchd process")
    events = Events()
    notifier_stop_attempted = False
    requested = False
    quiesced = False
    exited = False
    child: subprocess.Popen | None = None
    launch_started = False
    log = None
    phase = "preflight"
    result: dict | None = None
    failure: Refused | None = None
    previous_signals = {signal.SIGINT: signal.getsignal(signal.SIGINT)}

    def interrupted(_number: int, _frame) -> None:
        # Finish one bounded recovery even if the terminal sends another signal.
        for number in (signal.SIGTERM, signal.SIGHUP):
            signal.signal(number, signal.SIG_IGN)
        raise Refused("controller interrupted")

    nonce = secrets.token_hex(24)
    try:
        for number in (signal.SIGTERM, signal.SIGHUP):
            previous_signals[number] = signal.signal(number, interrupted)
        # Fail on a reused log before touching any service.
        log = open(config.ready_file.parent / (config.ready_file.name + ".log"),
            "x", opener=private_open)
        if not events.process(pid):
            raise Refused("collector exited before the handoff began")
        events.directory(config.ready_file.parent)
        events.directory(config.collector_status.parent)
        remaining(deadline, 30)
        phase = "stop_notifier"
        notifier_stop_attempted = True
        launchctl("bootout", f"gui/{os.getuid()}/{config.notifier_label}")
        phase = "drain_collector"
        remaining(deadline, 30)
        with open(request, "x", opener=private_open) as output:
            json.dump({"process_id": str(pid), "nonce": nonce,
                "deadline": deadline.isoformat()}, output)
            output.flush()
            os.fsync(output.fileno())
        requested = True
        events.wait(0)
        if pid in events.exited or service_pid(config.collector_label) != pid:
            raise Refused("collector exited or changed before the drain signal")
        os.kill(pid, signal.SIGUSR2)
        quiesced = await_quiesced(acknowledgement, pid, nonce, events,
            remaining(deadline, config.drain_timeout_seconds))
        if not quiesced:
            raise Refused("collector credential shutdown is blocked; no unload attempted")
        phase = "unload_quiesced_collector"
        events.wait(0)
        if pid in events.exited or service_pid(config.collector_label) != pid:
            raise Refused("collector exited or changed before unload")
        launchctl("bootout", f"gui/{os.getuid()}/{config.collector_label}")
        events.wait_exit(pid, remaining(deadline, 60))
        exited = True
        phase = "start_candidate"
        remaining(deadline, 30)
        environment = dict(os.environ, BROKER_HANDOFF_DEADLINE=deadline.isoformat(),
            BROKER_HANDOFF_NONCE=nonce, BROKER_HANDOFF_READY=str(config.ready_file))
        launch_started = True
        child = subprocess.Popen([str(executable), *config.command[1:]], stdin=subprocess.DEVNULL,
            stdout=log, stderr=log, env=environment, start_new_session=True)
        with open(candidate_file, "x", opener=private_open) as output:
            json.dump({"process_id": child.pid}, output)
        alive = events.process(child.pid)
        phase = "await_candidate"
        ready_limit = time.monotonic() + config.ready_timeout_seconds
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
                result = {"status": "disarmed_handoff_ready", "process_id": child.pid,
                    "armed": False, "strategies_started": False, "cleanup_incomplete": False}
                return result
            if not alive or child.poll() is not None:
                raise Refused("candidate startup failed")
            wait = min(remaining(deadline, config.ready_timeout_seconds), ready_limit - time.monotonic())
            if wait <= 0:
                raise Refused("candidate readiness timed out")
            batch = events.wait(wait)
            if not batch:
                raise Refused("candidate readiness timed out")
            if any(event.filter == select.KQ_FILTER_PROC and event.ident == child.pid for event in batch):
                alive = False
    except BaseException as error:
        for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(number, signal.SIG_IGN)
        failed_phase = phase
        changed = notifier_stop_attempted or requested
        if launch_started and child is None:
            failure = Refused("candidate launch outcome unknown: do not force-stop or restart collector; owner action required",
                phase=failed_phase, state_changed=True)
            failure.launch_outcome_unknown = True
            try:
                if notifier_stop_attempted and not service_loaded(config.notifier_label):
                    launchctl("bootstrap", f"gui/{os.getuid()}", str(config.notifier_plist))
            except Exception as notifier_error:
                raise failure from notifier_error
            raise failure from error
        if child is not None and child.poll() is None:
            failure = Refused("candidate still alive: leave disarmed, do not force-stop or restart collector",
                phase=failed_phase, state_changed=True)
            failure.candidate_process_id = child.pid
            raise failure from error
        try:
            # No bootout is allowed until the client has stopped and the journal
            # closed. launchd's finite SIGKILL fallback then cannot lose a token.
            if requested and not quiesced and pid not in events.exited:
                phase = "recover_collector_drain"
                try:
                    quiesced = await_quiesced(acknowledgement, pid, nonce, events,
                        config.recovery_timeout_seconds)
                except Refused:
                    if pid not in events.exited:
                        raise
            events.wait(0)
            if pid in events.exited:
                phase = "restore_exited_collector"
                if service_loaded(config.collector_label):
                    # No -k: launchd starts only an inactive job, never a second refresher.
                    try:
                        launchctl("kickstart", f"gui/{os.getuid()}/{config.collector_label}")
                    except Refused:
                        if service_pid(config.collector_label) == pid:
                            raise
                else:
                    launchctl("bootstrap", f"gui/{os.getuid()}", str(config.collector_plist))
                await_health(config, pid, config.recovery_timeout_seconds)
            elif quiesced:
                phase = "restore_collector"
                loaded = service_loaded(config.collector_label)
                if loaded and service_pid(config.collector_label) != pid:
                    # A managed replacement already exists: never unload its client.
                    await_health(config, pid, config.recovery_timeout_seconds)
                else:
                    if loaded:
                        launchctl("bootout", f"gui/{os.getuid()}/{config.collector_label}")
                    if not exited:
                        events.wait_exit(pid, config.recovery_timeout_seconds)
                    launchctl("bootstrap", f"gui/{os.getuid()}", str(config.collector_plist))
                    await_health(config, pid, config.recovery_timeout_seconds)
        except Exception as recovery_error:
            failure = Refused("read-only recovery blocked; owner action required",
                phase=phase, state_changed=changed)
            raise failure from recovery_error
        finally:
            # Alert-only monitoring must also return after a refused/stalled drain.
            if notifier_stop_attempted:
                phase = "restore_notifier"
                try:
                    if not service_loaded(config.notifier_label):
                        launchctl("bootstrap", f"gui/{os.getuid()}", str(config.notifier_plist))
                except Exception as notifier_error:
                    failure = Refused("notifier recovery blocked; owner action required",
                        phase=phase, state_changed=changed)
                    raise failure from notifier_error
        reason = str(error) if isinstance(error, Refused) else "handoff operation failed"
        failure = Refused(reason, phase=failed_phase, state_changed=changed)
        raise failure from error
    finally:
        for number in previous_signals:
            signal.signal(number, signal.SIG_IGN)
        events.close()
        if log is not None:
            log.close()
        for path in (request, acknowledgement):
            try:
                if json.loads(path.read_text()).get("nonce") == nonce:
                    path.unlink()
            except FileNotFoundError:
                pass  # Not published, or already consumed by the owner worker.
            except (json.JSONDecodeError, OSError):
                # Preserve readiness or the live-candidate instruction, never mask it.
                if result is not None:
                    result["cleanup_incomplete"] = True
                elif failure is not None:
                    failure.cleanup_incomplete = True
                else:
                    typer.echo(json.dumps({"status": "cleanup_incomplete",
                        "phase": "cleanup", "state_changed": requested}), err=True)
        for number, handler in previous_signals.items():
            signal.signal(number, handler)


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
            "phase": error.phase if isinstance(error, Refused) else "preflight",
            "state_changed": error.state_changed if isinstance(error, Refused) else False,
            "cleanup_incomplete": error.cleanup_incomplete if isinstance(error, Refused) else False,
            "candidate_process_id": error.candidate_process_id if isinstance(error, Refused) else None,
            "launch_outcome_unknown": error.launch_outcome_unknown if isinstance(error, Refused) else False,
            "reason": str(error) if isinstance(error, Refused) else "invalid or unreadable handoff input"}), err=True)
        raise typer.Exit(1) from error


if __name__ == "__main__":
    typer.run(main)
