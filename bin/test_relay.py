#!/usr/bin/env python3
"""Unit tests for the bin/relay runner's card-switch log formatting.

bin/relay has no .py extension and only runs main() under __main__, so we load it by
file path as a module and exercise its pure log helpers (banner) plus the DRY-mode
work() path, which prints the card-switch banner then returns before any API call.

Run: python3 bin/test_relay.py
"""
import contextlib
import importlib.machinery
import importlib.util
import io
import os
import unittest

RELAY_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "relay")
_loader = importlib.machinery.SourceFileLoader("relay_runner", RELAY_PATH)
_spec = importlib.util.spec_from_file_location("relay_runner", RELAY_PATH, loader=_loader)
relay = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(relay)

RULE = "[relay] " + "#" * 63


def capture(fn, *args, **kwargs):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        fn(*args, **kwargs)
    return out.getvalue()


class BannerTest(unittest.TestCase):
    def test_banner_wraps_lines_in_hash_rule(self):
        text = capture(relay.banner, ["→ RLY-25  better relay logging",
                                      "Spec (fresh) — then Spec:Review"])
        self.assertEqual(text.splitlines(), [
            "[relay] ",
            RULE,
            "[relay] ## → RLY-25  better relay logging",
            "[relay] ## Spec (fresh) — then Spec:Review",
            RULE,
        ])

    def test_banner_rule_is_63_hashes(self):
        text = capture(relay.banner, ["x"])
        self.assertIn(RULE, text.splitlines())
        self.assertNotIn("[relay] " + "#" * 64, text.splitlines())


class WorkBannerTest(unittest.TestCase):
    CARD = {"ref": "RLY-25", "title": "better relay logging"}
    ENTRY = {"stage": "Spec", "from": "Spec · Ready", "done": "Spec:Review",
             "action": [{"shell": "echo hi"}]}

    def setUp(self):
        relay.DRY = True
        self.addCleanup(setattr, relay, "DRY", False)

    def test_work_prints_card_switch_banner_fresh(self):
        lines = capture(relay.work, self.CARD, self.ENTRY, "fresh").splitlines()
        self.assertIn("[relay] ## → RLY-25  better relay logging", lines)
        self.assertIn("[relay] ## Spec (fresh) — then Spec:Review", lines)
        self.assertIn(RULE, lines)

    def test_work_banner_shows_resume_mode(self):
        lines = capture(relay.work, self.CARD, self.ENTRY, "resume").splitlines()
        self.assertIn("[relay] ## Spec (resume) — then Spec:Review", lines)


if __name__ == "__main__":
    unittest.main()
