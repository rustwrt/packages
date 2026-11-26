"""Regression coverage for dependency installation without touching a router."""
import pathlib
import subprocess
import unittest
import test_init
from test_init import SHELL

SCRIPT = pathlib.Path(__file__).resolve().parents[3] / "luci/luci-app-sponsorblocktv/root/usr/sbin/sponsorblocktv-install-deps"

@unittest.skipUnless(SHELL, "POSIX shell unavailable")
class InstallerTests(unittest.TestCase):
    def run_case(self, initial, expected, failure=False):
        source = SCRIPT.read_text(encoding="utf-8")
        body = source[source.index("install() {"):source.index('exec 9>')]
        body = body.replace("/usr/sbin/sponsorblocktv-deps", "fake_deps")
        # The manager log and calls are fixture-only. No real package manager runs.
        stub = r"""
set -eu
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
stage() { :; }
opkg() { :; }
fake_deps() { if [ -f "$dir/installed" ]; then return 0; fi; printf '%s' "$INITIAL"; return "$FAILURE"; }
manager() {
    shift
    if [ "$2" = list ]; then
        printf '%s\n' 'sponsorblocktv - 0.1.0-r1' 'python3 - 3.11' >"$dir/output"
    elif [ "$2" = install ]; then
        shift 2
        printf 'INSTALL:%s\n' "$*"
        touch "$dir/installed"
    fi
}
"""
        result = subprocess.run([SHELL, "-s"], input=stub+body+"\ninstall\n", text=True,
            capture_output=True, env=dict(test_init.InitScriptExecutionTests()._env(), INITIAL=initial, FAILURE="1" if failure else "0"), timeout=15)
        self.assertEqual(result.returncode == 0, not failure, result.stdout+result.stderr)
        actual = [line for line in result.stdout.splitlines() if line.startswith("INSTALL:")]
        self.assertEqual(actual, expected)

    def test_missing_core_once(self):
        self.run_case("MISSING sponsorblocktv\nMISSING python3\nMISSING sponsorblocktv\n", ["INSTALL:sponsorblocktv python3"])

    def test_existing_core_not_reinstalled(self):
        self.run_case("MISSING python3\n", ["INSTALL:python3"])

    def test_healthy_no_install(self):
        self.run_case("", [])

    def test_failed_verification_not_reinstall(self):
        self.run_case("", [], failure=True)
