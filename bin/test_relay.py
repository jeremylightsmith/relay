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


class PrintCardTest(unittest.TestCase):
    def test_print_card_shows_changes_requested_banner_before_the_ref_line(self):
        card = {
            "ref": "RLY-1",
            "title": "Do it",
            "status": "queued",
            "active_owner": None,
            "owners": [],
            "description": "the details",
            "rejection": {
                "note": "Handle the empty case",
                "from_stage": "Review",
                "to_stage": "Code",
                "rejected_by": "Jeremy",
                "rejected_at": "2026-07-08T00:00:00Z",
            },
        }
        text = capture(relay.print_card, card)

        self.assertIn("CHANGES REQUESTED", text)
        self.assertIn("sent back to Code", text)
        self.assertIn("Handle the empty case", text)
        self.assertLess(text.index("CHANGES REQUESTED"), text.index("RLY-1"))

    def test_print_card_has_no_banner_for_a_clean_card(self):
        card = {"ref": "RLY-1", "title": "Do it", "status": "queued", "active_owner": None, "owners": []}
        text = capture(relay.print_card, card)
        self.assertNotIn("CHANGES REQUESTED", text)


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


class FindReadyWipTest(unittest.TestCase):
    """Sub-lane cards count toward their parent main stage's WIP limit."""

    # Code (main, id 4, wip_limit 2) with Review (id 5) and Done (id 6)
    # sub-lanes; Plan (id 3) feeds Code.
    STAGES = [
        {"id": 3, "name": "Plan", "wip_limit": None, "parent_id": None},
        {"id": 4, "name": "Code", "wip_limit": 2, "parent_id": None},
        {"id": 5, "name": "Code:Review", "wip_limit": None, "parent_id": 4},
        {"id": 6, "name": "Code:Done", "wip_limit": None, "parent_id": 4},
    ]
    CFG = {"pipeline": [{"stage": "Code", "from": "Plan", "done": "Code:Review"}]}

    def board(self, cards):
        return {"stages": self.STAGES, "cards": cards}

    def test_sub_lane_cards_count_toward_the_parent_limit(self):
        # Code's main lane is empty, but its Review+Done lanes hold 2 cards —
        # exactly the limit — so a fresh Plan card must NOT be pulled.
        cards = [
            {"ref": "RLY-1", "stage_id": 5, "status": "queued"},
            {"ref": "RLY-2", "stage_id": 6, "status": "queued"},
            {"ref": "RLY-3", "stage_id": 3, "status": "queued"},
        ]
        self.assertIsNone(relay.find_ready(self.board(cards), self.CFG))

    def test_under_limit_across_sub_lanes_pulls_a_fresh_card(self):
        # Only one card in the whole Code column (in Review) → under the
        # limit of 2 → the Plan card is pulled fresh into Code.
        cards = [
            {"ref": "RLY-1", "stage_id": 5, "status": "queued"},
            {"ref": "RLY-3", "stage_id": 3, "status": "queued"},
        ]
        ready = relay.find_ready(self.board(cards), self.CFG)
        self.assertIsNotNone(ready)
        card, entry, mode = ready
        self.assertEqual(card["ref"], "RLY-3")
        self.assertEqual(entry["stage"], "Code")
        self.assertEqual(mode, "fresh")

    def test_main_lane_alone_at_limit_still_blocks(self):
        # Regression: pre-existing main-only counting still holds.
        cards = [
            {"ref": "RLY-1", "stage_id": 4, "status": "queued"},
            {"ref": "RLY-2", "stage_id": 4, "status": "queued"},
            {"ref": "RLY-3", "stage_id": 3, "status": "queued"},
        ]
        self.assertIsNone(relay.find_ready(self.board(cards), self.CFG))

    def test_no_limit_is_never_full(self):
        # Plan has no wip_limit, so many cards in it never block its own pull.
        cards = [{"ref": f"RLY-{n}", "stage_id": 3, "status": "queued"} for n in range(1, 6)]
        board = {
            "stages": self.STAGES + [{"id": 2, "name": "Spec", "wip_limit": None, "parent_id": None}],
            "cards": cards,
        }
        cfg = {"pipeline": [{"stage": "Plan", "from": "Spec", "done": "Plan:Done"}]}
        # Spec is empty so there's nothing to pull, but wip_ok(Plan) must be True (no crash).
        self.assertIsNone(relay.find_ready(board, cfg))


if __name__ == "__main__":
    unittest.main()
