#!/usr/bin/env python3
"""Unit tests for the bin/relay runner's card-switch log formatting.

bin/relay has no .py extension and only runs main() under __main__, so we load it by
file path as a module and exercise its pure log helpers (banner) plus the DRY-mode
work() path, which prints the card-switch banner then returns before any API call.

Run: python3 bin/test_relay.py
"""
import argparse
import contextlib
import importlib.machinery
import importlib.util
import io
import os
import unittest
import urllib.error

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


class _FakeResp:
    """Minimal stand-in for a urlopen() result: a context manager with .read()."""

    def __init__(self, body=b"{}"):
        self._body = body

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def read(self):
        return self._body


def _http_error(code, body=b""):
    return urllib.error.HTTPError("http://x", code, "err", {}, io.BytesIO(body))


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

    def test_work_auto_continue_sets_ready_not_a_done_status(self):
        entry = {**self.ENTRY, "done": "Plan:Done"}  # not a :Review checkpoint -> auto-continue
        relay.work(self.CARD, entry, "fresh")
        set_status_calls = [c for c in self.calls if c[0] == "set_status"]
        self.assertIn(("set_status", "RLY-9", "ready"), set_status_calls)

    def test_work_review_checkpoint_sets_in_review(self):
        relay.work(self.CARD, self.ENTRY, "fresh")  # self.ENTRY["done"] == "Code:Review"
        set_status_calls = [c for c in self.calls if c[0] == "set_status"]
        self.assertIn(("set_status", "RLY-9", "in_review"), set_status_calls)


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


class LogForwarderTest(unittest.TestCase):
    def setUp(self):
        self._forwarder, self._api = relay.FORWARDER, relay.api
        self.addCleanup(setattr, relay, "FORWARDER", self._forwarder)
        self.addCleanup(setattr, relay, "api", self._api)

    def test_drain_and_send_posts_the_batch_via_api(self):
        sent = []
        relay.api = lambda method, path, body=None, **k: sent.append((method, path, body))
        fw = relay.LogForwarder(flush_interval=0.01)
        fw.enqueue("claude", "hello", "RLY-1")
        fw._send(fw._drain())
        self.assertEqual(sent, [("POST", "/api/board/logs",
                                 [{"kind": "claude", "ref": "RLY-1", "text": "hello"}])])

    def test_send_swallows_api_die(self):
        relay.api = lambda *a, **k: relay.die("API 500: nope")  # die() raises SystemExit
        fw = relay.LogForwarder()
        fw.enqueue("error", "x", None)
        fw._send(fw._drain())  # must not raise

    def test_enqueue_drops_when_full_instead_of_blocking(self):
        fw = relay.LogForwarder(max_queue=2)
        fw.enqueue("claude", "a", None)
        fw.enqueue("claude", "b", None)
        fw.enqueue("claude", "c", None)  # dropped, does not block
        self.assertEqual(fw.q.qsize(), 2)

    def test_forward_is_a_noop_without_a_forwarder(self):
        relay.FORWARDER = None
        relay.forward("claude", "x", "RLY-1")  # must not raise

    def test_forward_enqueues_to_the_active_forwarder(self):
        fw = relay.LogForwarder()
        relay.FORWARDER = fw
        relay.forward("lifecycle", "started", None)
        self.assertEqual(fw.q.get_nowait(), {"kind": "lifecycle", "ref": None, "text": "started"})


class ForwardEmitPointsTest(unittest.TestCase):
    def setUp(self):
        self.sent = []
        self._forward, self._forwarder, self._dry = relay.forward, relay.FORWARDER, relay.DRY
        relay.FORWARDER = None
        relay.forward = lambda kind, text, ref=None: self.sent.append((kind, text, ref))
        self.addCleanup(setattr, relay, "forward", self._forward)
        self.addCleanup(setattr, relay, "FORWARDER", self._forwarder)
        self.addCleanup(setattr, relay, "DRY", self._dry)

    def test_ref_from_tag(self):
        self.assertEqual(relay._ref_from_tag("[RLY-7] "), "RLY-7")
        self.assertIsNone(relay._ref_from_tag(""))

    def test_log_forwards_lifecycle(self):
        capture(relay.log, "watching…")
        self.assertIn(("lifecycle", "watching…", None), self.sent)

    def test_claude_event_forwards_claude_with_ref_from_tag(self):
        ev = {"type": "assistant",
              "message": {"content": [{"type": "text", "text": "hi"}]}}
        capture(relay._print_claude_event, ev, "[RLY-7] ")
        self.assertEqual(self.sent, [("claude", "🤖 hi", "RLY-7")])

    def test_flag_forwards_error_with_ref(self):
        relay.DRY = True  # skip the needs_input API call inside flag()
        capture(relay.flag, "RLY-9", "boom")
        self.assertIn(("error", "  ⚑ RLY-9: boom", "RLY-9"), self.sent)


class BoardIncludeDoneTest(unittest.TestCase):
    def setUp(self):
        self._api = relay.api
        self.addCleanup(setattr, relay, "api", self._api)
        self.calls = []
        relay.api = lambda method, path, body=None, **k: (
            self.calls.append((method, path))
            or {"board": {"name": "B", "key": "RLY"}, "stages": [], "cards": []}
        )

    def test_board_defaults_to_the_plain_path(self):
        capture(relay.cmd_board, argparse.Namespace(json=True, include_done=False))
        self.assertEqual(self.calls, [("GET", "/api/board")])

    def test_include_done_flag_forwards_the_query_param(self):
        capture(relay.cmd_board, argparse.Namespace(json=True, include_done=True))
        self.assertEqual(self.calls, [("GET", "/api/board?include_done=1")])

    def test_parser_accepts_include_done(self):
        args = relay.build_parser().parse_args(["board", "--include-done"])
        self.assertTrue(args.include_done)


class ApiRetryTest(unittest.TestCase):
    """api() rides out transient failures with bounded retries + backoff, but never
    retries a non-idempotent POST 5xx or a 4xx, and still die()s when exhausted."""

    def setUp(self):
        self._saved = {k: getattr(relay, k) for k in ("env", "_api_backoff", "log")}
        relay.env = lambda name: "http://example.test"
        relay._api_backoff = lambda attempt: None   # never actually sleep
        relay.log = lambda *a, **k: None
        self._urlopen = relay.urllib.request.urlopen
        self.calls = []

    def tearDown(self):
        for k, v in self._saved.items():
            setattr(relay, k, v)
        relay.urllib.request.urlopen = self._urlopen

    def _script(self, outcomes):
        """Make urlopen return/raise each outcome in order, counting calls."""
        seq = list(outcomes)

        def fake(req, *a, **k):
            self.calls.append(req)
            outcome = seq.pop(0)
            if isinstance(outcome, Exception):
                raise outcome
            return outcome

        relay.urllib.request.urlopen = fake

    def test_get_retries_5xx_then_succeeds(self):
        self._script([_http_error(500), _FakeResp(b'{"ok": 1}')])
        self.assertEqual(relay.api("GET", "/api/board"), {"ok": 1})
        self.assertEqual(len(self.calls), 2)

    def test_get_exhausts_retries_then_dies(self):
        self._script([_http_error(500), _http_error(500), _http_error(500)])
        with self.assertRaises(SystemExit):
            relay.api("GET", "/api/board")
        self.assertEqual(len(self.calls), relay.API_MAX_ATTEMPTS)

    def test_urlerror_retries_any_method(self):
        self._script([urllib.error.URLError("refused"), _FakeResp(b"{}")])
        self.assertEqual(relay.api("POST", "/api/cards", {"t": "x"}), {})
        self.assertEqual(len(self.calls), 2)

    def test_post_5xx_is_not_retried(self):
        self._script([_http_error(500)])
        with self.assertRaises(SystemExit):
            relay.api("POST", "/api/comments", {"body": "hi"})
        self.assertEqual(len(self.calls), 1)

    def test_patch_retries_5xx_then_succeeds(self):
        self._script([_http_error(500), _FakeResp(b'{"ok": 1}')])
        self.assertEqual(
            relay.api("PATCH", "/api/cards/RLY-1", {"status": "ready"}), {"ok": 1})
        self.assertEqual(len(self.calls), 2)

    def test_4xx_is_not_retried(self):
        self._script([_http_error(422, b'{"error": {"message": "bad"}}')])
        with self.assertRaises(SystemExit):
            relay.api("GET", "/api/board")
        self.assertEqual(len(self.calls), 1)

    def test_soft_404_returns_none_without_retry(self):
        self._script([_http_error(404)])
        self.assertIsNone(relay.api("GET", "/api/cards/NOPE", soft_404=True))
        self.assertEqual(len(self.calls), 1)


class WatchLoopResilienceTest(unittest.TestCase):
    """A scan() that die()s (exhausted api() retries) is caught and logged; the watch
    loop does not propagate the SystemExit and the runner keeps going."""

    def setUp(self):
        self._saved = {k: getattr(relay, k) for k in
                       ("get_board", "load_config", "env", "log", "DRY")}
        relay.DRY = True   # skip forwarder + worktree setup
        relay.env = lambda name: "x"
        relay.load_config = lambda: {"poll_interval": 1, "pipeline": []}
        self.logs = []
        relay.log = lambda msg="", **k: self.logs.append((msg, k.get("kind")))
        os.environ.setdefault("RELAY_URL", "http://example.test")
        os.environ.setdefault("RELAY_API_KEY", "k")

    def tearDown(self):
        for k, v in self._saved.items():
            setattr(relay, k, v)

    def test_watch_survives_a_scan_that_dies(self):
        def boom():
            relay.die("API 500: down")   # what get_board() does when api() exhausts
        relay.get_board = boom

        # Must return normally — no SystemExit escapes the loop.
        relay.cmd_watch(
            relay.argparse.Namespace(once=True, dry_run=True, interval=1))

        self.assertTrue(any("board scan failed" in msg for msg, _ in self.logs))
        self.assertTrue(any(kind == "error" for _, kind in self.logs))


if __name__ == "__main__":
    unittest.main()
