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
import json
import os
import threading
import unittest
import urllib.error

RELAY_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "relay")
FIXTURE_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "test", "fixtures", "brainstorm_questions.json",
)
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

    def test_print_card_shows_the_tag_on_the_status_line(self):
        card = {"ref": "RLY-1", "title": "Do it", "status": "queued",
                "active_owner": None, "owners": [], "tag": "infra"}
        text = capture(relay.print_card, card)
        status_line = next(l for l in text.splitlines() if l.startswith("status:"))
        self.assertIn("tag: #infra", status_line)

    def test_print_card_omits_tag_when_unset(self):
        card = {"ref": "RLY-1", "title": "Do it", "status": "queued",
                "active_owner": None, "owners": []}
        text = capture(relay.print_card, card)
        self.assertNotIn("tag:", text)


class SetTagTest(unittest.TestCase):
    """relay tag REF [VALUE] — PATCHes {"tag": value}, null when omitted/empty."""

    def setUp(self):
        self._api = relay.api
        self.addCleanup(setattr, relay, "api", self._api)
        self.sent = []
        relay.api = lambda method, path, body=None, **k: (
            self.sent.append((method, path, body)) or
            {"data": {"ref": "RLY-1", "title": "Do it", "status": "queued",
                      "active_owner": None}}
        )

    def test_a_value_patches_the_tag(self):
        relay.set_tag("RLY-1", "infra")
        self.assertEqual(self.sent, [("PATCH", "/api/cards/RLY-1", {"tag": "infra"})])

    def test_no_value_patches_null_to_clear(self):
        relay.set_tag("RLY-1", None)
        self.assertEqual(self.sent, [("PATCH", "/api/cards/RLY-1", {"tag": None})])

    def test_empty_string_also_patches_null(self):
        relay.set_tag("RLY-1", "")
        self.assertEqual(self.sent, [("PATCH", "/api/cards/RLY-1", {"tag": None})])

    def test_cli_wiring_parses_the_optional_value(self):
        p = relay.build_parser()
        args = p.parse_args(["tag", "RLY-1", "infra"])
        self.assertEqual((args.ref, args.value), ("RLY-1", "infra"))
        args = p.parse_args(["tag", "RLY-1"])
        self.assertIsNone(args.value)


class NeedsInputBodyTest(unittest.TestCase):
    """needs_input_body builds the POST body: plain question vs. structured --questions JSON."""

    def test_plain_question_builds_question_body(self):
        self.assertEqual(relay.needs_input_body("plain q", None), {"question": "plain q"})

    def test_structured_questions_build_questions_body(self):
        raw = '[{"prompt": "p", "options": ["a", "b"]}]'
        self.assertEqual(
            relay.needs_input_body(None, raw),
            {"questions": [{"prompt": "p", "options": ["a", "b"]}]},
        )

    def test_malformed_json_dies(self):
        with self.assertRaises(SystemExit):
            relay.needs_input_body(None, "{not json")

    def test_non_list_payload_dies(self):
        with self.assertRaises(SystemExit):
            relay.needs_input_body(None, '{"prompt": "p"}')

    def test_empty_array_dies(self):
        with self.assertRaises(SystemExit):
            relay.needs_input_body(None, "[]")

    def test_brainstorm_fixture_builds_questions_body_verbatim(self):
        """RLY-109 — the producer seam. The same fixture the Elixir drawer test posts must
        survive --questions @file into the POST body untouched: prompts, options, and
        allow_text all preserved. Task 2's board_live_brainstorm_questions_test.exs pins
        the other end of this contract."""
        with open(FIXTURE_PATH) as f:
            raw = f.read()
        expected = json.loads(raw)

        body = relay.needs_input_body(None, raw)

        self.assertEqual(body, {"questions": expected})
        self.assertNotIn("question", body)

    def test_brainstorm_fixture_covers_the_shapes_the_stepper_must_render(self):
        """The fixture is only a useful contract if it stays brainstorm-shaped: a long-option
        question (the overflow case that motivated this card) and an open-ended one (the
        textarea path). Guard the fixture itself so a future edit can't quietly gut it."""
        with open(FIXTURE_PATH) as f:
            questions = json.load(f)

        self.assertIsInstance(questions, list)
        self.assertEqual(len(questions), 3)
        for q in questions:
            self.assertIn("prompt", q)
            self.assertIsInstance(q["options"], list)
            self.assertIsInstance(q["allow_text"], bool)

        # index 0 — sentence-length options: the labels that overflowed a nowrap .btn
        self.assertTrue(any(len(o) > 80 for o in questions[0]["options"]))
        # index 2 — open-ended: no options, so the stepper shows only its textarea
        self.assertEqual(questions[2]["options"], [])
        self.assertTrue(questions[2]["allow_text"])


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
        relay.run_step = lambda step, vars, cwd=relay.ROOT, tag="", sink=None: True
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

    def test_work_auto_continue_leaves_arrival_status_to_server_snap(self):
        # RLY-75: work() must not override the server's arrival-status snap after move().
        entry = {**self.ENTRY, "done": "Plan:Done"}  # not a :Review checkpoint -> auto-continue
        relay.work(self.CARD, entry, "fresh")
        set_status_calls = [c for c in self.calls if c[0] == "set_status"]
        self.assertEqual(set_status_calls, [("set_status", "RLY-9", "working")])

    def test_work_review_checkpoint_leaves_arrival_status_to_server_snap(self):
        # RLY-75: work() must not override the server's arrival-status snap after move().
        relay.work(self.CARD, self.ENTRY, "fresh")  # self.ENTRY["done"] == "Code:Review"
        set_status_calls = [c for c in self.calls if c[0] == "set_status"]
        self.assertEqual(set_status_calls, [("set_status", "RLY-9", "working")])


class FailureReasonTest(unittest.TestCase):
    """A failing step streamed its error to the runner's console and then dropped it:
    the card only ever said "<stage> stage did not complete". Three cards stalled that
    way in one day, each needing a transcript dig to learn why. The card must carry
    the reason."""

    CARD = {"ref": "RLY-9", "title": "t"}
    ENTRY = {"stage": "Code", "from": "Plan", "done": "Review",
             "action": [{"shell": "false"}]}
    PATCHED = ("DRY", "move", "set_status", "comment", "get_card", "log",
               "needs_input", "_stream_shell")

    def setUp(self):
        self._saved = {k: getattr(relay, k) for k in self.PATCHED}
        relay.DRY = False
        self.flagged = []
        relay.move = lambda *a, **k: None
        relay.set_status = lambda *a, **k: None
        relay.comment = lambda *a, **k: None
        relay.get_card = lambda ref: {"status": "working"}
        relay.log = lambda *a, **k: None
        relay.needs_input = lambda ref, msg: self.flagged.append((ref, msg))
        # The real failure shape: git refusing to clobber a leftover edit.
        relay._stream_shell = lambda cmd, cwd, tag="", sink=None: (
            sink is not None
            and sink.extend([
                "error: Your local changes to the following files would be "
                "overwritten by checkout:",
                "\t.claude/workflows/execute-plan.js",
                "Aborting",
            ])
        ) or False
        self.addCleanup(lambda: [setattr(relay, k, v) for k, v in self._saved.items()])

    def test_the_flagged_reason_includes_the_failing_step_output(self):
        relay.work(self.CARD, self.ENTRY, "fresh")

        self.assertEqual(len(self.flagged), 1, self.flagged)
        _, msg = self.flagged[0]
        # Without this, the card says only "Code stage did not complete" and the cause
        # is buried in a runner log nobody is watching.
        self.assertIn("execute-plan.js", msg)
        self.assertIn("would be overwritten by checkout", msg)

    def test_the_flagged_reason_still_names_the_stage(self):
        relay.work(self.CARD, self.ENTRY, "fresh")

        _, msg = self.flagged[0]
        self.assertIn("Code", msg)


class ResetWorktreeTest(unittest.TestCase):
    """A leftover edit in a pool worktree once blocked every Code stage for hours:
    `git checkout -B` refuses to clobber local changes, the step exited 1, and the
    runner reported only "Code stage did not complete". Preparing a worktree must
    therefore never be blocked by what a previous job left behind."""

    def setUp(self):
        self.runs = []
        real = relay.subprocess.run

        def fake_run(cmd, **kw):
            self.runs.append((cmd, kw.get("cwd")))
            # Report the worktree as dirty so the salvage path is exercised.
            if cmd[:3] == ["git", "status", "--porcelain"]:
                return argparse.Namespace(stdout=" M .claude/workflows/execute-plan.js\n")
            return argparse.Namespace(stdout="", returncode=0)

        relay.subprocess.run = fake_run
        self.addCleanup(setattr, relay.subprocess, "run", real)

    def git_cmds(self):
        return [c for c, _ in self.runs if c and c[0] == "git"]

    def test_a_dirty_worktree_is_reset_hard_and_cleaned_before_checkout(self):
        relay.reset_worktree("/tmp/wt", "origin/main")
        cmds = [" ".join(c) for c in self.git_cmds()]

        # The two that actually unblock it, in order, before the checkout.
        self.assertTrue(any(c.startswith("git reset --hard") for c in cmds), cmds)
        self.assertTrue(any(c.startswith("git clean -fd") for c in cmds), cmds)
        reset_at = next(i for i, c in enumerate(cmds) if c.startswith("git reset --hard"))
        checkout_at = next(i for i, c in enumerate(cmds) if "checkout --detach" in c)
        self.assertLess(reset_at, checkout_at, cmds)

    def test_leftovers_are_stashed_not_silently_destroyed(self):
        relay.reset_worktree("/tmp/wt", "origin/main")
        cmds = [" ".join(c) for c in self.git_cmds()]

        # A pool worktree is scratch space, but a real fix was once stranded in one.
        # Salvage first so it is recoverable via `git stash list`.
        self.assertTrue(any(c.startswith("git stash push") for c in cmds), cmds)
        stash_at = next(i for i, c in enumerate(cmds) if c.startswith("git stash push"))
        reset_at = next(i for i, c in enumerate(cmds) if c.startswith("git reset --hard"))
        self.assertLess(stash_at, reset_at, cmds)

    def test_clean_does_not_use_x_so_build_caches_survive(self):
        relay.reset_worktree("/tmp/wt", "origin/main")
        clean = next(c for c in self.git_cmds() if c[:2] == ["git", "clean"])

        # -fdx would nuke gitignored deps/_build/node_modules and make every job pay
        # a full rebuild.
        self.assertNotIn("-fdx", clean)
        self.assertNotIn("-x", clean)

    def test_every_git_call_targets_the_worktree_not_the_repo_root(self):
        relay.reset_worktree("/tmp/wt", "origin/main")

        # A reset --hard aimed at ROOT would blow away the user's own working tree.
        for cmd, cwd in self.runs:
            self.assertEqual(cwd, "/tmp/wt", cmd)


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
        relay._stream_shell = lambda cmd, cwd, tag="", sink=None: (
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


class AttachTest(unittest.TestCase):
    def setUp(self):
        self._api = relay.api
        self.addCleanup(setattr, relay, "api", self._api)

    def _tmpfile(self, suffix, data):
        import tempfile
        fd, path = tempfile.mkstemp(suffix=suffix)
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        self.addCleanup(os.remove, path)
        return path

    def test_attach_reads_binary_base64_encodes_and_prints_markdown(self):
        import base64
        sent = []
        relay.api = lambda method, path, body=None, **k: (
            sent.append((method, path, body)) or
            {"data": {"id": "abc", "url": "/attachments/abc",
                      "markdown": "![shot.png](/attachments/abc)"}}
        )
        raw = b"\x89PNG\r\n\x1a\n binary\x00bytes"
        path = self._tmpfile(".png", raw)
        args = argparse.Namespace(ref="RLY-1", file=path, caption=None, json=False)

        out = capture(relay.cmd_attach, args)

        method, apath, body = sent[0]
        self.assertEqual(method, "POST")
        self.assertEqual(apath, "/api/cards/RLY-1/attachments")
        self.assertEqual(body["content_type"], "image/png")
        self.assertEqual(base64.b64decode(body["data_base64"]), raw)
        self.assertIn("![shot.png](/attachments/abc)", out)

    def test_attach_json_prints_json(self):
        relay.api = lambda *a, **k: {"data": {"id": "abc", "url": "/attachments/abc",
                                               "markdown": "![x](/attachments/abc)"}}
        path = self._tmpfile(".png", b"x")
        args = argparse.Namespace(ref="RLY-1", file=path, caption=None, json=True)

        out = capture(relay.cmd_attach, args)

        self.assertIn('"id": "abc"', out)


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
                                 [{"kind": "claude", "ref": "RLY-1", "text": "hello", "run_id": None}])])

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
        self.assertEqual(fw.q.get_nowait(),
                          {"kind": "lifecycle", "ref": None, "text": "started", "run_id": None})


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


class HeartbeatBeatTest(unittest.TestCase):
    """RLY-141: the heartbeat carries identity + manifest and always beats."""

    def _capture_beat(self, hb):
        calls = []
        orig = relay.api
        relay.api = lambda *args, **kwargs: calls.append(args)
        try:
            hb._beat()
        finally:
            relay.api = orig
        return calls

    def test_beat_posts_identity_plus_manifest_even_when_idle(self):
        hb = relay.Heartbeat(lambda: {"pools": [], "jobs": [], "refs": []}, interval=30)
        calls = self._capture_beat(hb)

        self.assertEqual(len(calls), 1)
        method, path, body = calls[0]
        self.assertEqual((method, path), ("POST", "/api/board/heartbeat"))
        # the always-beat decision: an idle runner still posts, with empty lists
        self.assertEqual(body["refs"], [])
        self.assertEqual(body["jobs"], [])
        self.assertEqual(body["interval"], 30)
        self.assertEqual(body["host"], hb.identity["host"])
        self.assertTrue(body["runner_id"].startswith(body["host"] + "-"))
        self.assertTrue(body["started_at"].endswith("Z"))

    def test_manifest_lands_in_the_payload(self):
        manifest = {
            "pools": [{"name": "clean", "mode": "shared", "used": 1, "total": 3}],
            "jobs": [{"ref": "RLY-9", "stage": "Code", "pool": "clean",
                      "started_at": "2026-07-17T08:01:00Z"}],
            "refs": ["RLY-9"],
        }
        hb = relay.Heartbeat(lambda: manifest, interval=30)
        (_, _, body), = self._capture_beat(hb)

        self.assertEqual(body["pools"], manifest["pools"])
        self.assertEqual(body["jobs"], manifest["jobs"])
        self.assertEqual(body["refs"], ["RLY-9"])

    def test_runner_id_is_stable_across_beats(self):
        hb = relay.Heartbeat(lambda: {"pools": [], "jobs": [], "refs": []}, interval=30)
        first = self._capture_beat(hb)[0][2]["runner_id"]
        second = self._capture_beat(hb)[0][2]["runner_id"]
        self.assertEqual(first, second)

    def test_a_manifest_crash_never_raises_out_of_beat(self):
        hb = relay.Heartbeat(lambda: 1 / 0, interval=30)
        hb._beat()  # must swallow, exactly like an api() failure


class ExecutorConfigTest(unittest.TestCase):
    def setUp(self):
        self._path = relay.EXECUTOR_CONFIG_PATH
        self.addCleanup(setattr, relay, "EXECUTOR_CONFIG_PATH", self._path)

    def _write(self, obj):
        import tempfile
        fd, path = tempfile.mkstemp(suffix=".json")
        with os.fdopen(fd, "w") as f:
            json.dump(obj, f)
        self.addCleanup(os.remove, path)
        relay.EXECUTOR_CONFIG_PATH = path

    def test_missing_file_yields_defaults(self):
        relay.EXECUTOR_CONFIG_PATH = "/nope/does/not/exist.json"
        cfg = relay.load_executor_config()
        self.assertEqual(cfg["namespace"], "exec")
        self.assertEqual(cfg["capacity"], {"shared_clean": 1, "exclusive": 1})
        self.assertEqual(cfg["poll_timeout"], 25)
        self.assertEqual(cfg["heartbeat_interval"], 15)
        self.assertTrue(cfg["name"])  # defaults to hostname

    def test_partial_capacity_merges_over_defaults(self):
        self._write({"capacity": {"shared_clean": 3}})
        cfg = relay.load_executor_config()
        self.assertEqual(cfg["capacity"], {"shared_clean": 3, "exclusive": 1})

    def test_explicit_fields_win(self):
        self._write({"name": "box", "namespace": "ex2", "poll_timeout": 5})
        cfg = relay.load_executor_config()
        self.assertEqual((cfg["name"], cfg["namespace"], cfg["poll_timeout"]), ("box", "ex2", 5))

    def test_malformed_json_dies_with_the_cli_die_message(self):
        import tempfile
        fd, path = tempfile.mkstemp(suffix=".json")
        with os.fdopen(fd, "w") as f:
            f.write("{not json")
        self.addCleanup(os.remove, path)
        relay.EXECUTOR_CONFIG_PATH = path
        with self.assertRaises(SystemExit):
            relay.load_executor_config()


class ExecutorPoolTest(unittest.TestCase):
    CFG = {"namespace": "exec", "capacity": {"shared_clean": 2, "exclusive": 2}}

    def pool(self):
        return relay.ExecutorPool(self.CFG)

    def test_namespace_is_disjoint_from_the_watcher_pools(self):
        p = self.pool()
        names = [p.shared_name] + list(p.excl)
        self.assertEqual(p.shared_name, "exec-clean")
        self.assertEqual(sorted(p.excl), ["exec-work-1", "exec-work-2"])
        self.assertTrue(all(n.startswith("exec-") for n in names))
        self.assertNotIn("clean", names)  # the watcher's shared worktree name
        self.assertNotIn("work-1", names)

    def test_shared_clean_reuses_one_worktree_without_reset(self):
        p = self.pool()
        a = p.assign({"isolation": "shared_clean", "run_id": "r1"})
        b = p.assign({"isolation": "shared_clean", "run_id": "r2"})
        self.assertEqual(a, ("exec-clean", False))
        self.assertEqual(b, ("exec-clean", False))
        self.assertIsNone(p.assign({"isolation": "shared_clean", "run_id": "r3"}))  # cap 2

    def test_shared_capacity_reflects_free_slots(self):
        p = self.pool()
        self.assertEqual(p.capacity()["shared_clean"], 2)
        p.assign({"isolation": "shared_clean", "run_id": "r1"})
        self.assertEqual(p.capacity()["shared_clean"], 1)
        p.release({"isolation": "shared_clean", "run_id": "r1"}, "exec-clean", "done")
        self.assertEqual(p.capacity()["shared_clean"], 2)

    def test_first_exclusive_job_of_a_run_resets_its_slot(self):
        p = self.pool()
        slot, reset = p.assign({"isolation": "exclusive", "run_id": "r1"})
        self.assertEqual(slot, "exec-work-1")
        self.assertTrue(reset)  # first job of the run → reset before use

    def test_subsequent_job_of_same_run_reuses_slot_without_reset(self):
        p = self.pool()
        slot1, _ = p.assign({"isolation": "exclusive", "run_id": "r1"})
        p.release({"isolation": "exclusive", "run_id": "r1"}, slot1, "running")
        slot2, reset2 = p.assign({"isolation": "exclusive", "run_id": "r1"})
        self.assertEqual(slot2, slot1)
        self.assertFalse(reset2)  # same run reuses the worktree as-is

    def test_running_and_parked_keep_the_slot_bound(self):
        p = self.pool()
        slot, _ = p.assign({"isolation": "exclusive", "run_id": "r1"})
        p.release({"isolation": "exclusive", "run_id": "r1"}, slot, "parked")
        # parked run keeps its slot: capacity shows it as NOT free, and a different run
        # cannot take it (only the other free slot).
        self.assertEqual(p.capacity()["exclusive"], 1)
        other, _ = p.assign({"isolation": "exclusive", "run_id": "r2"})
        self.assertEqual(other, "exec-work-2")

    def test_terminal_run_state_frees_the_slot(self):
        p = self.pool()
        slot, _ = p.assign({"isolation": "exclusive", "run_id": "r1"})
        p.release({"isolation": "exclusive", "run_id": "r1"}, slot, "done")
        self.assertEqual(p.capacity()["exclusive"], 2)

    def test_revoke_run_state_none_frees_the_slot(self):
        p = self.pool()
        slot, _ = p.assign({"isolation": "exclusive", "run_id": "r1"})
        p.release({"isolation": "exclusive", "run_id": "r1"}, slot, None)  # revoke
        self.assertEqual(p.capacity()["exclusive"], 2)

    def test_exclusive_capacity_exhausts_then_returns_none(self):
        p = self.pool()
        p.assign({"isolation": "exclusive", "run_id": "r1"})
        p.assign({"isolation": "exclusive", "run_id": "r2"})
        self.assertEqual(p.capacity()["exclusive"], 0)
        self.assertIsNone(p.assign({"isolation": "exclusive", "run_id": "r3"}))

    def test_release_on_unknown_slot_does_not_raise(self):
        p = self.pool()
        # A slot the pool never handed out (e.g. a stale/None slot from a caller bug)
        # must not crash release() with a KeyError — it's a no-op for an unbound slot.
        p.release({"isolation": "exclusive", "run_id": "r1"}, "exec-work-99", "done")
        p.release({"isolation": "exclusive", "run_id": "r1"}, None, "done")
        self.assertEqual(p.capacity()["exclusive"], 2)

    def test_refresh_idle_shared_holds_the_lock_across_the_reset(self):
        """refresh_idle_shared's idle-check and the destructive refresh_worktree() reset
        (git reset --hard + git clean, per reset_worktree's own docstring) must be atomic
        under the pool lock — otherwise a job can be assign()ed into the shared worktree
        between the check and the reset, and the reset then blows it out from under a
        running job."""
        p = self.pool()
        refresh_started = threading.Event()
        release_refresh = threading.Event()
        events = []

        def fake_refresh_worktree(name, base):
            events.append("refresh-start")
            refresh_started.set()
            release_refresh.wait(timeout=2)
            events.append("refresh-end")

        real = relay.refresh_worktree
        relay.refresh_worktree = fake_refresh_worktree
        self.addCleanup(setattr, relay, "refresh_worktree", real)

        refresher = threading.Thread(target=p.refresh_idle_shared)
        refresher.start()
        self.assertTrue(refresh_started.wait(timeout=2))

        assigned = {}

        def do_assign():
            assigned["result"] = p.assign({"isolation": "shared_clean", "run_id": "r1"})
            events.append("assign")

        assigner = threading.Thread(target=do_assign)
        assigner.start()
        assigner.join(timeout=0.2)  # give it a real chance to race in if unlocked
        self.assertNotIn("assign", events)  # must still be blocked behind the pool lock

        release_refresh.set()
        refresher.join(timeout=2)
        assigner.join(timeout=2)

        self.assertEqual(events, ["refresh-start", "refresh-end", "assign"])
        self.assertEqual(assigned["result"], ("exec-clean", False))


class ExecutorConfigCommittedFileTest(unittest.TestCase):
    """The committed .relay/executor.json is a shared example checked into every clone; it
    must not hardcode one developer's executor identity (the `name` is the executor's wire
    identity used for claim/heartbeat/revoke — RLY-135 review)."""

    def test_committed_executor_json_has_no_personal_name(self):
        path = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            ".relay", "executor.json",
        )
        with open(path) as f:
            cfg = json.load(f)
        self.assertNotIn("name", cfg)


if __name__ == "__main__":
    unittest.main()
