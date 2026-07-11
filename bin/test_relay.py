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
import tempfile
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


class TickVersionGateTest(unittest.TestCase):
    """The watch loop's version gate: cheap outer poll, fingerprint inner gate."""

    PATCHED = ("DRY", "STATE_PATH", "get_board_version", "get_board",
               "find_ready", "work", "log")

    def setUp(self):
        self._saved = {k: getattr(relay, k) for k in self.PATCHED}
        tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".json")
        tmp.close()
        self._state_path = tmp.name
        relay.STATE_PATH = self._state_path
        relay.DRY = False
        relay.log = lambda *a, **k: None
        self.worked = []
        relay.work = lambda *a, **k: self.worked.append(a)
        relay.find_ready = lambda b, cfg: None  # default: nothing ready

    def tearDown(self):
        for k, v in self._saved.items():
            setattr(relay, k, v)
        os.remove(self._state_path)

    def _seed_state(self, **kw):
        import json
        json.dump(kw, open(self._state_path, "w"))

    def test_unchanged_version_skips_the_board_fetch(self):
        self._seed_state(version=7, fingerprint="fp")
        relay.get_board_version = lambda: 7
        fetched = []
        relay.get_board = lambda: fetched.append(True) or {"cards": [], "stages": []}

        self.assertFalse(relay.tick({}))
        self.assertEqual(fetched, [])  # cheap gate: no full-board fetch at all

    def test_changed_version_fetches_scans_and_works(self):
        self._seed_state(version=7, fingerprint="old")
        relay.get_board_version = lambda: 8
        relay.get_board = lambda: {"cards": [{"ref": "RLY-1", "stage_id": 1}], "stages": []}
        relay.find_ready = lambda b, cfg: ({"ref": "RLY-1"}, {"stage": "Code"}, "fresh")

        self.assertTrue(relay.tick({}))
        self.assertEqual(len(self.worked), 1)

    def test_version_bump_without_readiness_change_short_circuits(self):
        board = {"cards": [{"ref": "RLY-1", "stage_id": 1, "status": None, "active_owner": None}]}
        self._seed_state(version=1, fingerprint=relay.fingerprint(board))
        relay.get_board_version = lambda: 2  # version moved (e.g. a comment)
        relay.get_board = lambda: board
        scanned = []
        relay.find_ready = lambda b, cfg: scanned.append(True)

        self.assertFalse(relay.tick({}))
        self.assertEqual(scanned, [])  # inner fingerprint gate stops us before find_ready

    def test_missing_endpoint_falls_back_to_fingerprint(self):
        # Older server: the version endpoint 404s → get_board_version() is None.
        # tick still fetches the board and uses the fingerprint gate.
        board = {"cards": [{"ref": "RLY-1", "stage_id": 1, "status": None, "active_owner": None}]}
        self._seed_state(version=None, fingerprint=relay.fingerprint(board))
        relay.get_board_version = lambda: None
        fetched = []
        relay.get_board = lambda: fetched.append(True) or board

        self.assertFalse(relay.tick({}))
        self.assertEqual(fetched, [True])  # board WAS fetched despite the version gate


class FindReadyOwnershipTest(unittest.TestCase):
    """Rule 4: the runner never pulls a human-owned card; AI-owned/unowned stay eligible."""

    STAGES = [
        {"id": 3, "name": "Plan", "wip_limit": None, "parent_id": None},
        {"id": 4, "name": "Code", "wip_limit": None, "parent_id": None},
    ]
    CFG = {"pipeline": [{"stage": "Code", "from": "Plan", "done": "Code:Review"}]}

    def board(self, cards):
        return {"stages": self.STAGES, "cards": cards}

    def test_skips_a_human_owned_card_in_from(self):
        cards = [{"ref": "RLY-1", "stage_id": 3, "status": "queued", "active_owner": "human"}]
        self.assertIsNone(relay.find_ready(self.board(cards), self.CFG))

    def test_pulls_an_unowned_card_fresh(self):
        cards = [{"ref": "RLY-1", "stage_id": 3, "status": "queued", "active_owner": None}]
        ready = relay.find_ready(self.board(cards), self.CFG)
        self.assertIsNotNone(ready)
        self.assertEqual(ready[0]["ref"], "RLY-1")
        self.assertEqual(ready[2], "fresh")

    def test_resumes_an_ai_owned_working_card(self):
        cards = [{"ref": "RLY-2", "stage_id": 4, "status": "working", "active_owner": "ai"}]
        ready = relay.find_ready(self.board(cards), self.CFG)
        self.assertIsNotNone(ready)
        self.assertEqual(ready[2], "resume")

    def test_skips_a_human_owned_working_card_in_stage(self):
        cards = [{"ref": "RLY-3", "stage_id": 4, "status": "working", "active_owner": "human"}]
        self.assertIsNone(relay.find_ready(self.board(cards), self.CFG))


class WorkOwnershipTest(unittest.TestCase):
    """Rule 6: work() no longer own()s before or release()s after — the server claims on move."""

    CARD = {"ref": "RLY-9", "title": "t"}
    ENTRY = {"stage": "Code", "from": "Plan", "done": "Code:Review",
             "action": [{"shell": "echo hi"}]}
    PATCHED = ("DRY", "own", "release", "move", "set_status", "comment",
               "run_step", "get_card", "log", "flag")

    def setUp(self):
        self._saved = {k: getattr(relay, k) for k in self.PATCHED}
        relay.DRY = False
        self.calls = []
        relay.own = lambda ref: self.calls.append(("own", ref))
        relay.release = lambda ref: self.calls.append(("release", ref))
        relay.move = lambda ref, stage: self.calls.append(("move", ref, stage))
        relay.set_status = lambda ref, status: self.calls.append(("set_status", ref, status))
        relay.comment = lambda ref, body: self.calls.append(("comment", ref))
        relay.flag = lambda ref, msg: self.calls.append(("flag", ref))
        relay.run_step = lambda step, vars: True
        relay.get_card = lambda ref: {"status": "in_review"}
        relay.log = lambda *a, **k: None

    def tearDown(self):
        for k, v in self._saved.items():
            setattr(relay, k, v)

    def test_work_neither_owns_nor_releases(self):
        relay.work(self.CARD, self.ENTRY, "fresh")
        names = [c[0] for c in self.calls]
        self.assertNotIn("own", names)
        self.assertNotIn("release", names)
        # it still pushes the finished card to the done stage
        self.assertIn("move", names)


class BuildPoolsTest(unittest.TestCase):
    def test_shared_pool_has_n_slots_all_one_worktree(self):
        cfg = {"pools": {"clean": {"worktree": "clean", "mode": "shared",
                                   "base": "origin/main", "concurrency": 3}}}
        pools = relay.build_pools(cfg)
        self.assertEqual(pools["clean"]["slots"], ["clean", "clean", "clean"])
        self.assertEqual(pools["clean"]["free"], ["clean", "clean", "clean"])
        self.assertEqual(pools["clean"]["spec"]["base"], "origin/main")

    def test_exclusive_pool_has_distinct_numbered_worktrees(self):
        cfg = {"pools": {"work": {"worktree": "work", "mode": "exclusive",
                                  "base": "origin/main", "concurrency": 2}}}
        pools = relay.build_pools(cfg)
        self.assertEqual(pools["work"]["slots"], ["work-1", "work-2"])
        self.assertEqual(pools["work"]["free"], ["work-1", "work-2"])

    def test_no_pools_key_is_empty(self):
        self.assertEqual(relay.build_pools({}), {})

    def test_worktree_path_is_under_dot_claude_worktrees(self):
        self.assertTrue(relay.worktree_path("work-1")
                        .endswith(os.path.join(".claude", "worktrees", "work-1")))


if __name__ == "__main__":
    unittest.main()
