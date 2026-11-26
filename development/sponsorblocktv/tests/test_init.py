"""Execute the procd init script against stubbed rc.common/procd helpers.

The init script is POSIX sh sourced by /etc/rc.common; it calls config_* and
procd_* shell helpers that are stubbed here so the real control flow (config
load, enabled gate, env handling, command construction, bridge failure) runs on
a host shell.

Only bash/sh are used; tests skip when no POSIX shell is available.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest

import support

INIT = support.PACKAGE_FILES / "sponsorblocktv.init"

STUBS = r"""
procd_open_instance() {
	# Match firmware variants that unconditionally shift the instance name.
	local name="$1"; shift || return 1
	printf 'INSTANCE=%s\n' "$name"
}
procd_close_instance() { :; }
procd_set_param() {
	local type="$1"; shift
	case "$type" in
		command) printf 'CMD=%s\n' "$*" ;;
		env)     printf 'ENV=%s\n' "$*" ;;
		*)       printf 'PARAM=%s %s\n' "$type" "$*" ;;
	esac
}
procd_add_reload_trigger() { printf 'TRIGGER=%s\n' "$*"; }
logger() { printf 'LOG=%s\n' "$*"; }
mkdir() { printf 'MKDIR=%s\n' "$*"; }
config_load() { :; }
config_foreach() {
	if [ "$2" = "device" ] && grep -q '^config device' "$UCI_FILE"; then
		"$1" dev1
	fi
}
config_get_bool() {
	# config_get_bool <var> <section> <option> [default]
	eval "$1=\$(cfg_read '$3' '${4:-0}')"
	case "$(eval echo \"\$$1\")" in
		1|true|yes|on) eval "$1=1" ;;
		*)             eval "$1=0" ;;
	esac
}
config_get() {
	# config_get <var> <section> <option> [default]
	eval "$1=\$(cfg_read '$3' '$4')"
}
cfg_read() {
	[ -n "$UCI_FILE" ] && [ -f "$UCI_FILE" ] || { printf '%s' "$2"; return; }
	local v
	v=$(sed -n "s/^[[:space:]]*option[[:space:]]\{1,\}$1[[:space:]]\{1,\}'\{0,1\}\([^']*\)'\{0,1\}[[:space:]]*$/\1/p" "$UCI_FILE" | head -n 1)
	if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "$2"; fi
}
start() { start_service; }
stop() { printf 'STOP\n'; [ "$TEST_STOP_FAIL" != 1 ]; }
running() { [ "$TEST_RUNNING" = 1 ]; }
"""


def _find_shell():
    if os.name == "nt":
        for candidate in (
            os.path.join(os.environ.get("ProgramFiles", ""), "Git", "usr", "bin", "bash.exe"),
            os.path.join(os.environ.get("ProgramFiles", ""), "Git", "bin", "bash.exe"),
        ):
            if os.path.isfile(candidate):
                return candidate
        return shutil.which("bash")
    return shutil.which("bash") or shutil.which("sh")


SHELL = _find_shell()


def _posix(path: str) -> str:
    if os.name == "nt":
        drive, rest = os.path.splitdrive(os.path.abspath(path))
        return "/" + drive.rstrip(":").lower() + rest.replace("\\", "/")
    return path


@unittest.skipUnless(SHELL, "no POSIX shell available")
class InitScriptExecutionTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.stub = os.path.join(self.root, "procd.sh")
        self._write(self.stub, STUBS)
        self.bridge = os.path.join(self.root, "write-config")
        self._write(self.bridge, '#!/bin/sh\nprintf "BRIDGE=%s\\n" "$1"\n', mode=0o755)
        self.log = os.path.join(self.root, "bridge.log")
        self.uci_file = os.path.join(self.root, "uci")

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    @staticmethod
    def _write(path, text, mode=0o644):
        with open(path, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
        os.chmod(path, mode)

    def run_init(self, uci_text, action="start", bridge_ok=True, bridge_delay=False, with_device=True):
        if with_device:
            uci_text += "\nconfig device 'dev1'\n\toption screen_id 'test-screen'\n"
        self._write(self.uci_file, uci_text)
        if not bridge_ok:
            self._write(self.bridge, "#!/bin/sh\nexit 1\n", mode=0o755)
        harness = os.path.join(self.root, "harness.sh")
        self._write(
            harness,
            "STUB=%s\nUCI_FILE=%s\nDATA=%s\n"
            "SBTV_WRITE_CONFIG=\"%s\"\n"
            "SBTV_RUN=\"/usr/sbin/sponsorblocktv-run\"\n"
            "SBTV_APP_DIR=\"/usr/lib/sponsorblocktv\"\n"
            ". \"$STUB\"\n"
            ". \"%s\"\n"
            "%s\n"
            % (
                _posix(self.stub),
                _posix(self.uci_file),
                _posix(self.root),
                _posix(self.bridge),
                _posix(INIT),
                action,
            ),
        )
        result = subprocess.run(
            [SHELL, _posix(harness)],
            capture_output=True,
            text=True,
            env=self._env(),
            timeout=60,
        )
        return result

    def _env(self):
        env = dict(os.environ)
        if os.name == "nt":
            # Ensure the shell finds its own coreutils (sed/head) rather than
            # relying on the Windows PATH, which the MSYS layer rewrites.
            bindir = os.path.dirname(SHELL)
            extra = [bindir, os.path.join(os.path.dirname(bindir), "bin")]
            env["PATH"] = os.pathsep.join(extra + [env.get("PATH", "")])
        env.setdefault("TMPDIR", "/tmp")
        return env

    def test_enabled_starts_with_env_and_bridge(self):
        result = self.run_init("config sponsorblocktv 'main'\n\toption enabled '1'\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("BRIDGE=/etc/sponsorblocktv/data", result.stdout)
        self.assertIn("INSTANCE=instance1", result.stdout)
        self.assertNotIn("shift", result.stderr)
        self.assertIn("ENV=SBTV_APP_DIR=/usr/lib/sponsorblocktv", result.stdout)
        self.assertIn("CMD=/usr/bin/ucode -g 1000 /usr/sbin/sponsorblocktv-run "
                      "--data /etc/sponsorblocktv/data", result.stdout)

    def test_no_devices_does_not_spawn(self):
        result = self.run_init("config sponsorblocktv 'main'\n\toption enabled '1'\n", with_device=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("CMD=", result.stdout)
        self.assertNotIn("BRIDGE=", result.stdout)

    def test_disabled_boot_does_nothing(self):
        result = self.run_init("config sponsorblocktv 'main'\n\toption enabled '0'\n", action="boot")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("CMD=", result.stdout)
        self.assertNotIn("BRIDGE=", result.stdout)

    def test_disabled_explicit_start_still_works(self):
        result = self.run_init("config sponsorblocktv 'main'\n\toption enabled '0'\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("CMD=", result.stdout)

    def test_disabled_reload_does_not_start_stopped_service(self):
        result = self.run_init("config sponsorblocktv 'main'\n\toption enabled '0'\n", action="reload_service")
        self.assertNotIn("CMD=", result.stdout)

    def test_disabled_reload_preserves_running_service(self):
        result = self.run_init("config sponsorblocktv 'main'\n\toption enabled '0'\n", action="TEST_RUNNING=1; reload_service")
        self.assertIn("STOP", result.stdout)
        self.assertIn("CMD=", result.stdout)

    def test_debug_and_http_tracing_flags(self):
        result = self.run_init(
            "config sponsorblocktv 'main'\n\toption enabled '1'\n"
            "\toption debug '1'\n\toption http_tracing '1'\n"
        )
        self.assertIn("--data /etc/sponsorblocktv/data --debug --http-tracing",
                      result.stdout)

    def test_custom_data_dir_used_for_bridge_and_command(self):
        result = self.run_init(
            "config sponsorblocktv 'main'\n\toption enabled '1'\n"
            "\toption data_dir '/mnt/usb/sbtv'\n"
        )
        self.assertIn("BRIDGE=/mnt/usb/sbtv", result.stdout)
        self.assertIn("--data /mnt/usb/sbtv", result.stdout)

    def test_bridge_failure_aborts_start(self):
        result = self.run_init(
            "config sponsorblocktv 'main'\n\toption enabled '1'\n", bridge_ok=False
        )
        self.assertIn("could not write config", result.stdout)
        self.assertNotIn("CMD=", result.stdout)

    def test_failed_reload_keeps_running_service(self):
        result = self.run_init("config sponsorblocktv 'main'\n\toption enabled '1'\n",
                               action="TEST_RUNNING=1; reload_service", bridge_ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("retaining running service", result.stdout)
        self.assertNotIn("STOP", result.stdout)
        self.assertNotIn("CMD=", result.stdout)

    def test_reload_stop_failure_does_not_start(self):
        result = self.run_init("config sponsorblocktv 'main'\n\toption enabled '1'\n",
                               action="TEST_RUNNING=1; TEST_STOP_FAIL=1; reload_service")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not stop previous service", result.stdout)
        self.assertNotIn("CMD=", result.stdout)

    def test_reload_trigger_declared(self):
        result = self.run_init(
            "config sponsorblocktv 'main'\n\toption enabled '1'\n", action="service_triggers"
        )
        self.assertIn("TRIGGER=sponsorblocktv", result.stdout)


if __name__ == "__main__":
    unittest.main()
