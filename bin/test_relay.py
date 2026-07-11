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
        relay.run_step = lambda step, vars, cwd=relay.ROOT, tag="": True
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


class CwdRoutingTest(unittest.TestCase):
    def setUp(self):
        self._shell, self._claude, self._dry = (
            relay._stream_shell, relay._stream_claude, relay.DRY)
        relay.DRY = False
        self.addCleanup(setattr, relay, "_stream_shell", self._shell)
        self.addCleanup(setattr, relay, "_stream_claude", self._claude)
        self.addCleanup(setattr, relay, "DRY", self._dry)

    def test_shell_step_routes_rendered_cmd_cwd_and_tag(self):
        seen = {}
        relay._stream_shell = lambda cmd, cwd, tag="": (
            seen.update(cmd=cmd, cwd=cwd, tag=tag) or True)
        relay.run_step({"shell": "echo {ref}"}, {"ref": "RLY-7"},
                       cwd="/tmp/wt", tag="[RLY-7] ")
        self.assertEqual(seen, {"cmd": "echo RLY-7", "cwd": "/tmp/wt", "tag": "[RLY-7] "})

    def test_claude_step_routes_prompt_cwd_and_tag(self):
        seen = {}
        relay._stream_claude = lambda prompt, cwd=relay.ROOT, tag="": (
            seen.update(prompt=prompt, cwd=cwd, tag=tag) or True)
        relay.run_step({"claude": "do {ref}"}, {"ref": "RLY-7"},
                       cwd="/tmp/wt", tag="[RLY-7] ")
        self.assertEqual(seen, {"prompt": "do RLY-7", "cwd": "/tmp/wt", "tag": "[RLY-7] "})

    def test_claude_event_line_carries_the_tag(self):
        ev = {"type": "assistant",
              "message": {"content": [{"type": "text", "text": "hello there"}]}}
        text = capture(relay._print_claude_event, ev, "[RLY-7] ")
        self.assertIn("[RLY-7] ", text)
        self.assertIn("hello there", text)


class FindAllReadyTest(unittest.TestCase):
    STAGES = [
        {"id": 10, "name": "Next up",   "wip_limit": None, "parent_id": None},
        {"id": 2,  "name": "Spec",      "wip_limit": None, "parent_id": None},
        {"id": 11, "name": "Spec:Done", "wip_limit": None, "parent_id": None},
        {"id": 3,  "name": "Plan",      "wip_limit": None, "parent_id": None},
        {"id": 12, "name": "Plan:Done", "wip_limit": None, "parent_id": None},
        {"id": 4,  "name": "Code",      "wip_limit": None, "parent_id": None},
    ]
    CFG = {"pipeline": [
        {"stage": "Spec", "from": "Next up",   "done": "Spec:Review", "pool": "clean"},
        {"stage": "Plan", "from": "Spec:Done",  "done": "Plan:Done",   "pool": "clean"},
        {"stage": "Code", "from": "Plan:Done",  "done": "Code:Review", "pool": "work"},
    ]}

    def board(self, cards, stages=None):
        return {"stages": stages or self.STAGES, "cards": cards}

    def test_dispatches_up_to_pool_budget(self):
        cards = [{"ref": f"RLY-{n}", "stage_id": 10, "status": "queued"} for n in range(1, 6)]
        ready = relay.find_all_ready(self.board(cards), self.CFG, set(),
                                     {"clean": 3, "work": 1})
        self.assertEqual(len(ready), 3)  # clean budget caps at 3
        self.assertTrue(all(e["stage"] == "Spec" for _, e, _ in ready))

    def test_excludes_in_flight_refs(self):
        cards = [{"ref": "RLY-1", "stage_id": 10, "status": "queued"},
                 {"ref": "RLY-2", "stage_id": 10, "status": "queued"}]
        ready = relay.find_all_ready(self.board(cards), self.CFG, {"RLY-1"},
                                     {"clean": 3, "work": 1})
        self.assertEqual([c["ref"] for c, _, _ in ready], ["RLY-2"])

    def test_respects_zero_pool_budget(self):
        cards = [{"ref": "RLY-1", "stage_id": 12, "status": "queued"}]  # ready for Code
        ready = relay.find_all_ready(self.board(cards), self.CFG, set(),
                                     {"clean": 3, "work": 0})
        self.assertEqual(ready, [])

    def test_resume_takes_the_slot_before_fresh(self):
        cards = [{"ref": "RLY-1", "stage_id": 4,  "status": "working"},  # resuming in Code
                 {"ref": "RLY-2", "stage_id": 12, "status": "queued"}]   # fresh for Code
        ready = relay.find_all_ready(self.board(cards), self.CFG, set(),
                                     {"clean": 3, "work": 1})
        self.assertEqual(len(ready), 1)
        self.assertEqual(ready[0][0]["ref"], "RLY-1")
        self.assertEqual(ready[0][2], "resume")

    def test_wip_limit_caps_fresh_even_with_pool_budget(self):
        stages = [s for s in self.STAGES if s["name"] != "Code"] + \
                 [{"id": 4, "name": "Code", "wip_limit": 2, "parent_id": None}]
        cards = [{"ref": f"RLY-{n}", "stage_id": 12, "status": "queued"} for n in range(1, 6)]
        ready = relay.find_all_ready(self.board(cards, stages), self.CFG, set(),
                                     {"clean": 3, "work": 5})
        self.assertEqual(len(ready), 2)  # WIP limit 2 wins over 5 free work slots


class DispatchOnceTest(unittest.TestCase):
    """`watch --once` dispatches every ready card into its pool's worktree, in
    parallel worker threads, and frees all slots when the pass completes."""

    def setUp(self):
        self._saved = {k: getattr(relay, k) for k in
                       ("get_board", "work", "ensure_worktree", "refresh_worktree",
                        "load_config", "env", "log", "DRY")}
        relay.DRY = False
        relay.log = lambda *a, **k: None
        relay.env = lambda name: "x"
        relay.ensure_worktree = lambda *a, **k: None
        relay.refresh_worktree = lambda *a, **k: None
        os.environ.setdefault("RELAY_URL", "http://example.test")
        os.environ.setdefault("RELAY_API_KEY", "k")

    def tearDown(self):
        for k, v in self._saved.items():
            setattr(relay, k, v)

    def test_once_dispatches_both_ready_cards_into_clean_worktree(self):
        board = {"stages": FindAllReadyTest.STAGES,
                 "cards": [{"ref": "RLY-1", "stage_id": 10, "status": "queued", "title": "a"},
                           {"ref": "RLY-2", "stage_id": 10, "status": "queued", "title": "b"}]}
        relay.get_board = lambda: board
        relay.load_config = lambda: {
            "poll_interval": 1,
            "pools": {"clean": {"worktree": "clean", "mode": "shared",
                                "base": "origin/main", "concurrency": 2}},
            "pipeline": [{"stage": "Spec", "from": "Next up", "done": "Spec:Review",
                          "pool": "clean", "action": [{"shell": "true"}]}]}
        calls, lock = [], relay.threading.Lock()

        def fake_work(card, entry, mode, cwd=relay.ROOT, tag=""):
            with lock:
                calls.append((card["ref"], cwd, tag))
        relay.work = fake_work

        relay.cmd_watch(relay.argparse.Namespace(once=True, dry_run=False, interval=1))

        self.assertEqual(sorted(r for r, _, _ in calls), ["RLY-1", "RLY-2"])
        self.assertTrue(all(cwd.endswith(os.path.join("worktrees", "clean"))
                            for _, cwd, _ in calls))
        self.assertTrue(all(tag.startswith("[RLY-") for _, _, tag in calls))


if __name__ == "__main__":
    unittest.main()
