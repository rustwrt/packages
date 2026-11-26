"""Tests for the ucode UCI -> config.json bridge (lib/config.uc).

The config module is pure logic (no network), so it can be exercised directly
when a `ucode` interpreter is available. Structural checks always run.
"""

from __future__ import annotations

import json
import os
import pathlib
import tempfile
import unittest

import support

UCI_SHOW = """\
sponsorblocktv.main=sponsorblocktv
sponsorblocktv.main.enabled='1'
sponsorblocktv.main.debug='1'
sponsorblocktv.main.http_tracing='0'
sponsorblocktv.main.data_dir='/etc/sponsorblocktv/data'
sponsorblocktv.main.join_name='Living Room'
sponsorblocktv.main.apikey='AIza-secret'
sponsorblocktv.main.skip_categories='sponsor'
sponsorblocktv.main.skip_categories='intro'
sponsorblocktv.main.skip_count_tracking='0'
sponsorblocktv.main.mute_ads='1'
sponsorblocktv.main.skip_ads='0'
sponsorblocktv.main.minimum_skip_length='3'
sponsorblocktv.main.auto_play='0'
sponsorblocktv.main.use_proxy='1'
sponsorblocktv.main.sponsorblock_api_url='https://example.test/api/'
sponsorblocktv.@device[0]=device
sponsorblocktv.@device[0].screen_id='screen-abc'
sponsorblocktv.@device[0].name='TV one'
sponsorblocktv.@device[0].offset='-250'
sponsorblocktv.@device[1]=device
sponsorblocktv.@device[1].screen_id=''
sponsorblocktv.@device[1].name='Unpaired'
sponsorblocktv.@device[1].offset='0'
sponsorblocktv.@whitelist[0]=whitelist
sponsorblocktv.@whitelist[0].id='UC123'
sponsorblocktv.@whitelist[0].name='Some channel'
"""


class ConfigModuleStructureTests(unittest.TestCase):
    """Structural checks that always run (no ucode interpreter needed)."""

    def test_config_module_exists(self):
        self.assertTrue((support.LIB_DIR / "config.uc").exists())

    def test_config_module_exports(self):
        text = support.read_ucode_module("config.uc")
        for name in ("parse_uci_show", "build_config", "write_config", "main"):
            self.assertIn(name, text)

    def test_valid_categories_present(self):
        text = support.read_ucode_module("config.uc")
        for cat in ("sponsor", "selfpromo", "intro", "outro", "music_offtopic",
                    "interaction", "exclusive_access", "preview", "filler", "hook"):
            self.assertIn(cat, text)

    def test_defaults_present(self):
        text = support.read_ucode_module("config.uc")
        self.assertIn("SponsorBlockTV", text)
        self.assertIn("https://sponsor.ajay.app/api/", text)


@unittest.skipUnless(support.ucode_binary(), "ucode interpreter not available")
class ConfigLogicTests(unittest.TestCase):
    """Logic tests that require a ucode interpreter."""

    def _eval(self, expr: str):
        result = support.run_ucode_expr(expr)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def test_parse_uci_show(self):
        # Build a ucode expression that parses UCI_SHOW and prints JSON.
        uci_json = json.dumps(UCI_SHOW)
        expr = (
            "import * as c from 'config.uc'; "
            "let s = c.parse_uci_show(" + uci_json + "); "
            "let types = []; "
            "for (let i = 0; i < length(s); i++) types[length(types)] = s[i].type; "
            "print(sprintf('%.J', types));"
        )
        out = self._eval(expr)
        self.assertEqual(json.loads(out), ["sponsorblocktv", "device", "device", "whitelist"])

    def test_build_config_devices(self):
        uci_json = json.dumps(UCI_SHOW)
        expr = (
            "import * as c from 'config.uc'; "
            "let cfg = c.build_config(c.parse_uci_show(" + uci_json + ")); "
            "print(sprintf('%.J', {n: length(cfg.devices), id: cfg.devices[0].screen_id, "
            "name: cfg.devices[0].name, offset: cfg.devices[0].offset}));"
        )
        out = self._eval(expr)
        data = json.loads(out)
        self.assertEqual(data["n"], 1)
        self.assertEqual(data["id"], "screen-abc")
        self.assertEqual(data["name"], "TV one")
        self.assertEqual(data["offset"], -250)

    def test_build_config_booleans(self):
        uci_json = json.dumps(UCI_SHOW)
        expr = (
            "import * as c from 'config.uc'; "
            "let cfg = c.build_config(c.parse_uci_show(" + uci_json + ")); "
            "print(sprintf('%.J', {mute: cfg.mute_ads, skip: cfg.skip_ads, "
            "track: cfg.skip_count_tracking, autoplay: cfg.auto_play, proxy: cfg.use_proxy, "
            "min: cfg.minimum_skip_length}));"
        )
        out = self._eval(expr)
        data = json.loads(out)
        self.assertTrue(data["mute"])
        self.assertFalse(data["skip"])
        self.assertFalse(data["track"])
        self.assertFalse(data["autoplay"])
        self.assertTrue(data["proxy"])
        self.assertEqual(data["min"], 3)

    def test_build_config_lists_and_secrets(self):
        uci_json = json.dumps(UCI_SHOW)
        expr = (
            "import * as c from 'config.uc'; "
            "let cfg = c.build_config(c.parse_uci_show(" + uci_json + ")); "
            "print(sprintf('%.J', {cats: cfg.skip_categories, key: cfg.apikey, "
            "wl: cfg.channel_whitelist, url: cfg.sponsorblock_api_url}));"
        )
        out = self._eval(expr)
        data = json.loads(out)
        self.assertEqual(data["cats"], ["sponsor", "intro"])
        self.assertEqual(data["key"], "AIza-secret")
        self.assertEqual(data["wl"], [{"id": "UC123", "name": "Some channel"}])
        self.assertEqual(data["url"], "https://example.test/api/")

    def test_defaults_when_options_missing(self):
        uci = "sponsorblocktv.main=sponsorblocktv\nsponsorblocktv.@device[0]=device\nsponsorblocktv.@device[0].screen_id='abc'\n"
        uci_json = json.dumps(uci)
        expr = (
            "import * as c from 'config.uc'; "
            "let cfg = c.build_config(c.parse_uci_show(" + uci_json + ")); "
            "print(sprintf('%.J', {cats: cfg.skip_categories, join: cfg.join_name, "
            "min: cfg.minimum_skip_length, url: cfg.sponsorblock_api_url, "
            "track: cfg.skip_count_tracking, autoplay: cfg.auto_play, "
            "name: cfg.devices[0].name}));"
        )
        out = self._eval(expr)
        data = json.loads(out)
        self.assertEqual(data["cats"], ["sponsor"])
        self.assertEqual(data["join"], "SponsorBlockTV")
        self.assertEqual(data["min"], 1)
        self.assertEqual(data["url"], "https://sponsor.ajay.app/api/")
        self.assertTrue(data["track"])
        self.assertTrue(data["autoplay"])
        self.assertEqual(data["name"], "YouTube on TV")

    def test_empty_category_list_disables_skipping(self):
        uci = "sponsorblocktv.main=sponsorblocktv\nsponsorblocktv.main.skip_categories=''\n"
        uci_json = json.dumps(uci)
        expr = (
            "import * as c from 'config.uc'; "
            "let cfg = c.build_config(c.parse_uci_show(" + uci_json + ")); "
            "print(sprintf('%.J', cfg.skip_categories));"
        )
        out = self._eval(expr)
        self.assertEqual(json.loads(out), [])

    def test_unknown_categories_dropped(self):
        uci = ("sponsorblocktv.main=sponsorblocktv\n"
               "sponsorblocktv.main.skip_categories='sponsor'\n"
               "sponsorblocktv.main.skip_categories='not-a-category'\n")
        uci_json = json.dumps(uci)
        expr = (
            "import * as c from 'config.uc'; "
            "let cfg = c.build_config(c.parse_uci_show(" + uci_json + ")); "
            "print(sprintf('%.J', cfg.skip_categories));"
        )
        out = self._eval(expr)
        self.assertEqual(json.loads(out), ["sponsor"])

    def test_duplicate_devices_collapse(self):
        uci = ("sponsorblocktv.main=sponsorblocktv\n"
               "sponsorblocktv.@device[0]=device\n"
               "sponsorblocktv.@device[0].screen_id='same'\n"
               "sponsorblocktv.@device[1]=device\n"
               "sponsorblocktv.@device[1].screen_id='same'\n")
        uci_json = json.dumps(uci)
        expr = (
            "import * as c from 'config.uc'; "
            "let cfg = c.build_config(c.parse_uci_show(" + uci_json + ")); "
            "print(sprintf('%.J', length(cfg.devices)));"
        )
        out = self._eval(expr)
        self.assertEqual(json.loads(out), 1)

    def test_no_uci_only_keys_leak(self):
        uci_json = json.dumps(UCI_SHOW)
        expr = (
            "import * as c from 'config.uc'; "
            "let cfg = c.build_config(c.parse_uci_show(" + uci_json + ")); "
            "let keys = ['enabled','debug','http_tracing','data_dir']; "
            "let leaked = []; "
            "for (let i = 0; i < length(keys); i++) { "
            "  if (keys[i] in cfg) leaked[length(leaked)] = keys[i]; "
            "} "
            "print(sprintf('%.J', leaked));"
        )
        out = self._eval(expr)
        self.assertEqual(json.loads(out), [])


if __name__ == "__main__":
    unittest.main()
