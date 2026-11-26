"""Structural tests for the ucode-based SponsorBlockTV package."""

from __future__ import annotations

import pathlib
import re
import unittest

import support

APP_MAKEFILE = support.REPO_ROOT / "../../utils/sponsorblocktv" / "Makefile"


class UcodeLayoutTests(unittest.TestCase):
    def test_fresh_install_has_no_placeholder_devices(self):
        text = (support.PACKAGE_FILES / "sponsorblocktv.config").read_text(encoding="utf-8")
        sections = re.findall(r"^\s*config\s+(\w+)", text, re.M)
        self.assertEqual(sections, ["sponsorblocktv"])

    def test_lib_modules_exist(self):
        for name in support.LIB_MODULES:
            self.assertTrue(
                (support.LIB_DIR / name).exists(),
                f"missing lib module {name}",
            )

    def test_cast_modules_exist(self):
        for name in support.CAST_MODULES:
            self.assertTrue(
                (support.LIB_DIR / "cast" / name).exists(),
                f"missing cast module {name}",
            )

    def test_cli_scripts_exist(self):
        for name in support.CLI_SCRIPTS:
            self.assertTrue(
                (support.UCODE_DIR / name).exists(),
                f"missing CLI script {name}",
            )

    def test_cli_scripts_have_ucode_shebang(self):
        # Only the two explicitly scoped transport helpers use Python.
        for name in support.CLI_SCRIPTS:
            if name in ("sponsorblocktv-cast-bridge", "sponsorblocktv-watch-page"):
                continue
            text = support.read_cli_script(name)
            self.assertTrue(
                text.startswith("#!/usr/bin/env ucode"),
                f"{name} missing ucode shebang",
            )

    def test_cast_bridge_is_python(self):
        text = support.read_cli_script("sponsorblocktv-cast-bridge")
        self.assertTrue(
            text.startswith("#!/usr/bin/env python3"),
            "cast bridge missing python3 shebang",
        )

    def test_no_unapproved_python_scripts_shipped(self):
        # The core runtime remains ucode; only explicit transport helpers use Python.
        for path in support.UCODE_DIR.rglob("*"):
            if path.is_file() and path.name not in ("sponsorblocktv-cast-bridge", "sponsorblocktv-watch-page"):
                text = path.read_text(encoding="utf-8", errors="ignore")
                self.assertNotIn("python3", text, f"python3 reference in {path}")
                self.assertNotIn("#!/usr/bin/env python", text, f"python shebang in {path}")

    def test_vendored_python_files(self):
        vendor = support.PACKAGE_FILES / "python"
        for name in ("pychromecast", "google/protobuf", "casttube"):
            self.assertTrue((vendor / name / "__init__.py").is_file())
        self.assertTrue((vendor / "VENDOR-MANIFEST.json").is_file())
        for name in ("requests", "urllib3", "certifi", "idna", "charset_normalizer", "chardet", "ifaddr", "zeroconf"):
            self.assertFalse((vendor / name).exists())
            self.assertFalse(list(vendor.glob(name + "-*.dist-info")))
        import json
        manifest = json.loads((vendor / "VENDOR-MANIFEST.json").read_text(encoding="utf-8"))
        self.assertEqual(len(manifest), 3)
        self.assertEqual({r["package"].split("_")[0] for r in manifest}, {"python3-pychromecast", "python3-protobuf", "python3-casttube"})
        self.assertFalse(list(vendor.glob("ifaddr-*.dist-info")))
        self.assertFalse(list(vendor.rglob("*.so")))
        self.assertFalse((vendor / "zeroconf").exists())

    def test_no_python_dependency_packages(self):
        pkg_dir = support.REPO_ROOT / "../../utils"
        for child in pkg_dir.iterdir():
            if child.is_dir():
                self.assertFalse(
                    child.name.startswith("python3-") or child.name == "python-flit-scm",
                    f"stale python dependency package {child.name}",
                )


class MakefileTests(unittest.TestCase):
    def setUp(self):
        self.text = APP_MAKEFILE.read_text(encoding="utf-8")

    def test_no_python_dependencies(self):
        # The core runtime is ucode; only the Chromecast bridge uses Python.
        for bad in ("python-flit", "python3-light"):
            self.assertNotIn(bad, self.text)

    def test_ucode_dependencies_declared(self):
        for dep in ("+ucode", "+ucode-mod-uloop", "+ucode-mod-uclient",
                    "+ucode-mod-socket", "+ucode-mod-struct", "+ucode-mod-digest",
                    "+ca-bundle"):
            self.assertIn(dep, self.text)

    def test_pychromecast_dependency_declared(self):
        for name in ("pychromecast", "protobuf", "casttube", "ifaddr", "charset-normalizer"):
            self.assertNotIn("+python3-" + name, self.text)
        for dep in ("+python3 ", "+python3-zeroconf", "+python3-requests", "+python3-urllib3", "+python3-certifi", "+python3-idna", "+python3-chardet"):
            self.assertIn(dep, self.text)
        self.assertIn("files/python", self.text)

    def test_no_ffi_or_native_tls_dependency(self):
        # ucode-mod-ffi and the abandoned native TLS module are not used.
        self.assertNotIn("+ucode-mod-ffi", self.text)
        self.assertNotIn("+ucode-mod-ustream-tls", self.text)

    def test_installs_ucode_scripts(self):
        for name in support.CLI_SCRIPTS:
            self.assertIn(name, self.text)

    def test_installs_lib_dir(self):
        self.assertIn("files/ucode/lib", self.text)

    def test_no_compileall(self):
        self.assertNotIn("compileall", self.text)

    def test_no_python_build_dep(self):
        self.assertNotIn("python3/host", self.text)

    def test_native_recipes_normalize_payload_permissions(self):
        for recipe in (APP_MAKEFILE, support.LUCI_DIR / "Makefile"):
            text = recipe.read_text(encoding="utf-8")
            self.assertIn("find $(1) -type d -exec chmod 0755 {} +", text)
            self.assertIn("find $(1) -type f -exec chmod 0644 {} +", text)
        self.assertIn("chmod 0600 $(1)/etc/config/sponsorblocktv", self.text)
        self.assertNotIn("$(CP) ./root/. $(1)/", (support.LUCI_DIR / "Makefile").read_text(encoding="utf-8"))


class InitScriptTests(unittest.TestCase):
    def setUp(self):
        self.text = (support.PACKAGE_FILES / "sponsorblocktv.init").read_text(encoding="utf-8")

    def test_uses_ucode_not_python(self):
        self.assertIn("/usr/bin/ucode", self.text)
        self.assertNotIn("python3", self.text)

    def test_calls_write_config(self):
        self.assertIn("sponsorblocktv-write-config", self.text)

    def test_procd_used(self):
        self.assertIn("USE_PROCD=1", self.text)
        self.assertIn("procd_open_instance", self.text)


class DepsScriptTests(unittest.TestCase):
    def setUp(self):
        self.text = (support.LUCI_DIR / "root" / "usr" / "sbin" / "sponsorblocktv-deps").read_text(encoding="utf-8")

    def test_checks_ucode_packages(self):
        for pkg in ("ucode", "ucode-mod-uclient", "ucode-mod-socket"):
            self.assertIn(pkg, self.text)

    def test_checks_cast_bridge_dependency(self):
        self.assertNotIn("python3-pychromecast", self.text)
        for dep in ("python3-requests", "python3-urllib3", "python3-certifi", "python3-idna", "python3-chardet"):
            self.assertIn(dep, self.text)
        self.assertNotIn("python3-ifaddr", self.text)
        self.assertIn("python3-zeroconf", self.text)
        self.assertIn("result=$(/usr/sbin/sponsorblocktv-cast-bridge self-test)", self.text)

    def test_verifies_ucode_import(self):
        self.assertIn("ucode", self.text)


if __name__ == "__main__":
    unittest.main()
