"""macOS integration: real launchd, OS exits, FileStore and MCP.Fake. No live store."""
from datetime import datetime, timedelta, timezone
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import uuid

import pytest

PACKAGE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("broker_handoff", PACKAGE / "scripts/handoff.py")
handoff = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = handoff
spec.loader.exec_module(handoff)
pytestmark = pytest.mark.skipif(not hasattr(select, "kqueue"), reason="macOS launchd integration")


def await_file(path, predicate=lambda _: True):
    events = handoff.Events()
    events.directory(path.parent)
    try:
        while True:
            if path.exists() and predicate(path):
                return
            if not events.queue.control(None, 8, 30):
                logs = "\n".join(log.read_text() for log in path.parent.glob("*.log"))
                raise TimeoutError("isolated fixture publication failed:\n" + logs)
    finally:
        events.close()


@pytest.fixture
def install(request):
    parent = Path.home() / ".raxol/broker/handoff-tests"
    parent.mkdir(mode=0o700, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=parent) as directory:
        base = Path(directory)
        os.chmod(base, 0o700)
        suffix = uuid.uuid4().hex
        labels = {role: "io.axol.fixture." + role + "." + suffix for role in ("collector", "notifier")}
        def cleanup_setup():
            for label in labels.values():
                result = subprocess.run(["/bin/launchctl", "print", f"gui/{os.getuid()}/{label}"],
                    capture_output=True, text=True)
                if result.returncode == 0:
                    pid = next((int(line.strip().split(" = ")[1]) for line in result.stdout.splitlines()
                        if line.strip().startswith("pid = ")), None)
                    handoff.launchctl("bootout", f"gui/{os.getuid()}/{label}")
                    if pid:
                        try:
                            os.kill(pid, signal.SIGUSR1)
                        except ProcessLookupError:
                            pass  # Fixture already exited during bootout.
        request.addfinalizer(cleanup_setup)
        environment = {key: os.environ[key] for key in ("PATH", "MIX_HOME", "MIX_ARCHIVES")}
        environment.update(MIX_ENV="test", RAXOL_PATH="/Users/droo/CODE/raxol-broker-liveview",
            MIX_BUILD_PATH=str(PACKAGE / "_build/canary_runtime"), FIXTURE_DIRECTORY=str(base))
        command = [shutil.which("mix"), "run", "--no-start", "--no-compile",
            str(PACKAGE / "test/support/handoff_fixture.exs")]
        for role, label in labels.items():
            document = {"Label": label, "ProgramArguments": command + [role],
                "WorkingDirectory": str(PACKAGE), "RunAtLoad": True,
                "EnvironmentVariables": environment,
                "StandardOutPath": str(base / (role + ".log")),
                "StandardErrorPath": str(base / (role + ".log"))}
            path = base / (role + ".plist")
            path.write_bytes(plistlib.dumps(document))
            path.chmod(0o600)
            handoff.launchctl("bootstrap", f"gui/{os.getuid()}", str(path))
        await_file(base / "status.json")
        config = handoff.Config(collector_label=labels["collector"],
            collector_plist=base / "collector.plist", notifier_label=labels["notifier"],
            notifier_plist=base / "notifier.plist", collector_status=base / "status.json",
            ready_file=base / "ready.json", command=command + ["candidate"])
        previous = {key: os.environ.get(key) for key in environment}
        os.environ.update(environment)
        try:
            yield config, base
        finally:
            os.environ.update({key: value for key, value in previous.items() if value is not None})
            for key, value in previous.items():
                if value is None:
                    os.environ.pop(key, None)
            ready = base / "ready.json"
            if ready.exists():
                pid = int(json.loads(ready.read_text())["process_id"])
                try:
                    os.kill(pid, signal.SIGUSR1)
                except ProcessLookupError:
                    pass  # Candidate already exited, so no refresher can remain.
                watcher = handoff.Events()
                try:
                    if watcher.process(pid):
                        watcher.wait_exit(pid, 30)
                finally:
                    watcher.close()
            for role, label in labels.items():
                status = subprocess.run(["/bin/launchctl", "print", f"gui/{os.getuid()}/{label}"], capture_output=True)
                if status.returncode == 0:
                    pid = handoff.service_pid(label)
                    handoff.launchctl("bootout", f"gui/{os.getuid()}/{label}")
                    try:
                        os.kill(pid, signal.SIGUSR1)
                    except ProcessLookupError:
                        pass  # Default TERM may already have completed shutdown.
                    watcher = handoff.Events()
                    try:
                        if watcher.process(pid):
                            watcher.wait_exit(pid, 30)
                    finally:
                        watcher.close()


def test_expired_consent_keeps_collector_running(install):
    config, _ = install
    old = handoff.service_pid(config.collector_label)
    with pytest.raises(handoff.Refused, match="expired"):
        handoff.run(config, datetime.now(timezone.utc) - timedelta(seconds=1))
    assert handoff.service_pid(config.collector_label) == old
    assert handoff.health(config.collector_status).executor_started is False


def run_controller(config, base):
    path = base / "config.json"
    path.write_text(config.model_dump_json())
    path.chmod(0o600)
    deadline = (datetime.now(timezone.utc) + timedelta(minutes=3)).isoformat()
    return subprocess.Popen([sys.executable, str(PACKAGE / "scripts/handoff.py"), str(path), deadline],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def test_waits_for_real_exit_before_opening_same_journal(install):
    config, base = install
    old = handoff.service_pid(config.collector_label)
    controller = run_controller(config, base)
    await_file(base / "stopping")
    assert controller.poll() is None
    assert not config.ready_file.exists()
    os.kill(old, signal.SIGUSR1)
    output, error = controller.communicate(timeout=60)
    assert controller.returncode == 0, error
    result = json.loads(output)
    ready = handoff.Ready.model_validate_json(config.ready_file.read_text())
    assert result["armed"] is False
    assert int(ready.process_id) != old
    assert ready.executor_started is True
    assert ready.executor_port_ready is True
    assert ready.strategies_started is False


def test_failed_start_restores_collector_before_notifier(install):
    config, base = install
    config.command[-1] = "fail"
    old = handoff.service_pid(config.collector_label)
    controller = run_controller(config, base)
    await_file(base / "stopping")
    os.kill(old, signal.SIGUSR1)
    output, error = controller.communicate(timeout=60)
    assert controller.returncode == 1
    assert "candidate startup failed" in error
    restored = handoff.health(config.collector_status)
    assert restored.executor_started is False
    assert int(restored.process_id) != old
    assert handoff.service_pid(config.collector_label) == int(restored.process_id)
    assert handoff.service_pid(config.notifier_label) > 1
    assert not config.ready_file.exists()
