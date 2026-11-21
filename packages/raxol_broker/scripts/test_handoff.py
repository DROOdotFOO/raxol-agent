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


def await_file(path, predicate=lambda _: True, *, controller=None):
    events = handoff.Events()
    events.directory(path.parent)
    if controller is not None:
        events.process(controller.pid)
    try:
        while True:
            if path.exists() and predicate(path):
                return
            if controller is not None and controller.poll() is not None:
                output, error = controller.communicate()
                raise AssertionError(f"fixture coordinator exited before publication: {output} {error}")
            if not events.queue.control(None, 8, 60):
                logs = "\n".join(log.read_text() for log in path.parent.glob("*.log"))
                for plist in path.parent.glob("*.plist"):
                    label = plistlib.loads(plist.read_bytes())["Label"]
                    state = subprocess.run(["/bin/launchctl", "print", f"gui/{os.getuid()}/{label}"],
                        capture_output=True, text=True)
                    logs += "\n" + "\n".join(line for line in state.stdout.splitlines()
                        if any(key in line for key in ("state =", "pid =", "runs =", "last exit")))
                    for line in state.stdout.splitlines():
                        if line.strip().startswith("pid = "):
                            pid = line.strip().split(" = ", 1)[1]
                            process = subprocess.run(["/bin/ps", "-p", pid, "-o", "comm=,args="],
                                capture_output=True, text=True, check=True)
                            logs += "\n" + process.stdout
                raise TimeoutError("isolated fixture publication failed:\n" + logs)
    finally:
        events.close()


def finish_fixture(pid):
    events = handoff.Events()
    try:
        if events.process(pid):
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                return  # Exited between registration and signal.
            events.wait_exit(pid, 30)
    finally:
        events.close()


@pytest.fixture
def private_directory():
    parent = Path.home() / ".raxol/broker/handoff-tests"
    parent.mkdir(mode=0o700, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=parent) as directory:
        base = Path(directory)
        base.chmod(0o700)
        yield base


@pytest.fixture
def install(private_directory):
    base = private_directory
    mix = shutil.which("mix")
    build = Path(os.environ.get("MIX_BUILD_PATH", str(PACKAGE / "_build/test"))).absolute()
    if not mix or not (build / "lib/raxol_broker/ebin/Elixir.Raxol.Broker.CollectorHandoff.beam").exists():
        pytest.skip("source the toolchain and prebuild MIX_ENV=test; export that MIX_BUILD_PATH")
    environment = {key: os.environ[key] for key in
        ("PATH", "MIX_HOME", "MIX_ARCHIVES", "RAXOL_PATH") if key in os.environ}
    environment.update(MIX_ENV="test", MIX_BUILD_PATH=str(build), FIXTURE_DIRECTORY=str(base))
    command = [mix, "run", "--no-start", "--no-compile", "--no-deps-check",
        str(PACKAGE / "test/support/handoff_fixture.exs")]
    suffix = uuid.uuid4().hex
    labels = {role: "io.axol.fixture." + role + "." + suffix for role in ("collector", "notifier")}
    controllers = []
    try:
        for role, label in labels.items():
            arguments = ([sys.executable, str(PACKAGE / "test/support/handoff_notifier_fixture.py")]
                if role == "notifier" else command + [role])
            path = base / (role + ".plist")
            path.write_bytes(plistlib.dumps({"Label": label, "ProgramArguments": arguments,
                "WorkingDirectory": str(PACKAGE), "RunAtLoad": True,
                "EnvironmentVariables": environment, "StandardOutPath": str(base / (role + ".log")),
                "StandardErrorPath": str(base / (role + ".log"))}))
            path.chmod(0o600)
            handoff.launchctl("bootstrap", f"gui/{os.getuid()}", str(path))
        await_file(base / "status.json")
        config = handoff.Config(collector_label=labels["collector"],
            collector_plist=base / "collector.plist", notifier_label=labels["notifier"],
            notifier_plist=base / "notifier.plist", collector_status=base / "status.json",
            ready_file=base / "ready.json", command=command + ["candidate"])
        yield config, base, environment, controllers
    finally:
        # Stop the controller first: otherwise it can bootstrap jobs after
        # teardown. All PIDs below belong only to this credential-free fixture.
        for controller in controllers:
            if controller.poll() is None:
                controller.kill()  # Credential-free coordinator only; prevent recovery during teardown.
            controller.wait(timeout=30)
        candidate = base / "ready.json.candidate"
        if candidate.exists():
            finish_fixture(int(json.loads(candidate.read_text())["process_id"]))
        for label in labels.values():
            if handoff.service_loaded(label):
                result = subprocess.run(["/bin/launchctl", "print", f"gui/{os.getuid()}/{label}"],
                    capture_output=True, text=True, check=True)
                pid = next((int(line.strip().split(" = ")[1]) for line in result.stdout.splitlines()
                    if line.strip().startswith("pid = ")), None)
                handoff.launchctl("bootout", f"gui/{os.getuid()}/{label}")
                if pid:
                    finish_fixture(pid)


def run_controller(context):
    config, base, environment, controllers = context
    path = base / "config.json"
    path.write_text(config.model_dump_json())
    path.chmod(0o600)
    deadline = (datetime.now(timezone.utc) + timedelta(minutes=3)).isoformat()
    controller = subprocess.Popen([sys.executable, str(PACKAGE / "scripts/handoff.py"), str(path), deadline],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=dict(os.environ, **environment))
    controllers.append(controller)
    return controller


def release_drain(context):
    config, base, _, _ = context
    await_file(base / "stopping")
    # The credential-capable VM is still managed; no bootout before its ACK.
    assert not config.ready_file.exists()
    os.kill(handoff.service_pid(config.collector_label), signal.SIGUSR2)


def test_expired_consent_keeps_collector_running(install):
    config, _, _, _ = install
    old = handoff.service_pid(config.collector_label)
    with pytest.raises(handoff.Refused, match="expired"):
        handoff.run(config, datetime.now(timezone.utc) - timedelta(seconds=1))
    assert handoff.service_pid(config.collector_label) == old
    assert handoff.health(config.collector_status).executor_started is False


def test_waits_for_real_exit_before_opening_same_journal(install):
    config, base, _, _ = install
    old = handoff.service_pid(config.collector_label)
    controller = run_controller(install)
    release_drain(install)
    output, error = controller.communicate(timeout=60)
    assert controller.returncode == 0, error
    result = json.loads(output)
    ready = handoff.Ready.model_validate_json(config.ready_file.read_text())
    assert result["armed"] is False
    assert int(ready.process_id) != old
    assert ready.executor_started is True and ready.executor_port_ready is True
    assert ready.strategies_started is False


def test_failed_start_waits_for_healthy_recovery_before_notifier(install):
    config, base, _, _ = install
    config.command[-1] = "fail"
    old = handoff.service_pid(config.collector_label)
    controller = run_controller(install)
    release_drain(install)
    await_file(base / "recovering", controller=controller)
    assert controller.poll() is None
    assert not handoff.service_loaded(config.notifier_label)
    recovering = json.loads(config.collector_status.read_text())
    assert recovering["status"] == "starting"
    os.kill(int(recovering["process_id"]), signal.SIGUSR2)
    output, error = controller.communicate(timeout=60)
    assert controller.returncode == 1
    assert "candidate startup failed" in error
    restored = handoff.health(config.collector_status)
    assert not restored.executor_started and int(restored.process_id) != old
    assert handoff.service_pid(config.collector_label) == int(restored.process_id)
    await_file(base / "notifier-observed.jsonl",
        lambda path: json.loads(path.read_text().splitlines()[-1]).get("process_id") == restored.process_id)


@pytest.mark.parametrize("role", ["bad_nonce", "bad_pid"])
def test_invalid_receipt_never_kills_candidate_or_starts_second_refresher(install, role):
    config, base, _, _ = install
    config.command[-1] = role
    controller = run_controller(install)
    release_drain(install)
    _, error = controller.communicate(timeout=60)
    assert controller.returncode == 1 and "candidate still alive" in error
    assert not handoff.service_loaded(config.collector_label)
    assert not handoff.service_loaded(config.notifier_label)
    actual = json.loads((base / "ready.json.candidate").read_text())["process_id"]
    events = handoff.Events()
    try:
        assert events.process(actual)
    finally:
        events.close()


def test_unresponsive_drain_never_unloads_or_replaces_old_collector(install):
    config, base, _, _ = install
    config.drain_timeout_seconds = 1
    config.recovery_timeout_seconds = 1
    old = handoff.service_pid(config.collector_label)
    controller = run_controller(install)
    await_file(base / "stopping")
    _, error = controller.communicate(timeout=10)
    assert controller.returncode == 1
    assert json.loads(error)["state_changed"] is True
    assert handoff.service_pid(config.collector_label) == old
    assert not (base / "ready.json.candidate").exists()
    assert handoff.service_loaded(config.notifier_label)


@pytest.mark.parametrize("signal_number", [signal.SIGTERM, signal.SIGHUP])
def test_controller_interrupt_restores_monitoring_without_unloading_busy_collector(install, signal_number):
    config, base, _, _ = install
    config.recovery_timeout_seconds = 1
    old = handoff.service_pid(config.collector_label)
    controller = run_controller(install)
    await_file(base / "stopping")
    os.kill(controller.pid, signal_number)
    _, error = controller.communicate(timeout=10)
    assert controller.returncode == 1
    assert json.loads(error)["phase"] == "recover_collector_drain"
    assert handoff.service_pid(config.collector_label) == old
    assert handoff.service_loaded(config.notifier_label)
    assert not (base / "ready.json.candidate").exists()


def test_collector_exit_during_drain_is_not_lost(install):
    config, base, _, _ = install
    old = handoff.service_pid(config.collector_label)
    controller = run_controller(install)
    await_file(base / "stopping")
    finish_fixture(old)
    await_file(base / "recovering", controller=controller)
    recovering = json.loads(config.collector_status.read_text())
    os.kill(int(recovering["process_id"]), signal.SIGUSR2)
    _, error = controller.communicate(timeout=60)
    assert controller.returncode == 1
    restored = handoff.health(config.collector_status)
    assert int(restored.process_id) != old
    assert handoff.service_loaded(config.notifier_label)
    assert not (base / "ready.json.candidate").exists()


@pytest.mark.parametrize("role", ["cleanup_ready", "cleanup_bad_nonce"])
def test_cleanup_failure_preserves_ready_or_live_candidate_result(install, role):
    config, base, _, _ = install
    config.command[-1] = role
    controller = run_controller(install)
    release_drain(install)
    output, error = controller.communicate(timeout=60)
    report = json.loads(output if controller.returncode == 0 else error)
    assert report["cleanup_incomplete"] is True
    if role == "cleanup_ready":
        assert controller.returncode == 0 and report["status"] == "disarmed_handoff_ready"
        actual = report["process_id"]
    else:
        assert controller.returncode == 1 and "candidate still alive" in report["reason"]
        actual = report["candidate_process_id"]
    assert actual == json.loads((base / "ready.json.candidate").read_text())["process_id"]
    assert not handoff.service_loaded(config.collector_label)
    assert not handoff.service_loaded(config.notifier_label)
    events = handoff.Events()
    try:
        assert events.process(actual)
    finally:
        events.close()


def test_exec_uses_the_verified_target_not_a_swapped_symlink(install):
    config, base, _, _ = install
    link = base / "launcher"
    link.symlink_to(config.command[0])
    config.command[0] = str(link)
    controller = run_controller(install)
    await_file(base / "stopping")
    link.unlink()
    link.symlink_to("/usr/bin/false")
    os.kill(handoff.service_pid(config.collector_label), signal.SIGUSR2)
    output, error = controller.communicate(timeout=60)
    assert controller.returncode == 0, error
    assert json.loads(output)["status"] == "disarmed_handoff_ready"


def test_evidence_reader_does_not_wait_on_the_running_runtime_build_lock(install):
    config, base, environment, _ = install
    result = subprocess.run(["bash", str(PACKAGE / "scripts/evidence.sh"),
        "--date", datetime.now(timezone.utc).date().isoformat(), "--journal", str(base / "journal")],
        capture_output=True, text=True, timeout=15, env=dict(os.environ, **environment))
    assert result.returncode == 0, result.stderr
    report = json.loads(result.stdout)
    assert report["journal_integrity"] == "VERIFIED"
    assert report["result"] == "UNVERIFIED"
    assert handoff.service_pid(config.collector_label) == int(handoff.health(config.collector_status).process_id)


def test_reused_log_refuses_before_disrupting_collection(install):
    config, base, _, _ = install
    old = handoff.service_pid(config.collector_label)
    (base / "ready.json.log").write_text("previous attempt")
    controller = run_controller(install)
    _, error = controller.communicate(timeout=10)
    assert controller.returncode == 1 and json.loads(error)["state_changed"] is False
    assert handoff.service_pid(config.collector_label) == old
    assert handoff.service_loaded(config.notifier_label)


@pytest.mark.parametrize("unsafe", ["symlink", "ancestor", "writable"])
def test_untrusted_control_paths_are_rejected(private_directory, unsafe):
    base = private_directory
    real = base / "real"
    real.mkdir(mode=0o700)
    path = real / "control"
    path.write_text("{}")
    path.chmod(0o600)
    if unsafe == "symlink":
        link = real / "link"
        link.symlink_to(path)
        path = link
    elif unsafe == "ancestor":
        link = base / "link"
        link.symlink_to(real, target_is_directory=True)
        path = link / "control"
    else:
        real.chmod(0o777)
    with pytest.raises(handoff.Refused):
        handoff.trusted(path)


def test_non_owner_control_file_is_rejected():
    if os.getuid() == 0:
        pytest.skip("requires a non-root operator")
    with pytest.raises(handoff.Refused):
        handoff.trusted(Path("/etc/hosts"))
