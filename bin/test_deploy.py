#!/usr/bin/env python3
"""Tests for the RE408 deploy scripts in bin/: the Code flow's ship-to-main squash and the
helpers and deploy steps the Deploy flow runs.

The scripts are bash, so these tests drive them as subprocesses against throwaway git repos
(a bare `origin` plus a clone) and a stub `relay` CLI (`RELAY=<stub>`). They need only `git`,
`bash` and `python3`, because `mix precommit` runs them on CI's ubuntu runner too.

Run: python3 bin/test_deploy.py
"""
import base64
import os
import re
import shutil
import stat
import subprocess
import tempfile
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(REPO_ROOT, "bin")

SHIP = os.path.join(BIN, "ship_to_main.sh")
TOUCHED = os.path.join(BIN, "card_touched_flutter.sh")

TITLE = "let’s move Deploying off of CI"
TRAILER = "Co-Authored-By: Claude <noreply@anthropic.com>"
NOTHING_TO_SHIP = "ship_to_main: nothing to ship — origin/main..HEAD is empty"


def git(cwd, *args):
    """Run git in `cwd` and return its stripped stdout; raise on failure."""
    return subprocess.run(
        ["git", *args], cwd=cwd, check=True, capture_output=True, text=True
    ).stdout.strip()


def _configure(repo):
    git(repo, "config", "user.name", "Test")
    git(repo, "config", "user.email", "test@example.com")
    git(repo, "config", "commit.gpgsign", "false")
    # No background auto-gc / maintenance: a detached gc racing TemporaryDirectory cleanup fails the test.
    git(repo, "config", "gc.auto", "0")
    git(repo, "config", "maintenance.auto", "false")


def make_repo(tmp):
    """A bare `origin` and a clone of it with one initial commit on `main`, pushed.

    Returns (work_dir, origin_dir)."""
    origin = os.path.join(tmp, "origin.git")
    work = os.path.join(tmp, "work")
    subprocess.run(["git", "init", "-q", "--bare", "-b", "main", origin], check=True)
    subprocess.run(["git", "clone", "-q", origin, work], check=True, capture_output=True)
    _configure(work)
    git(work, "checkout", "-q", "-B", "main")
    commit(work, {"README.md": "hello\n"}, "initial")
    git(work, "push", "-q", "origin", "main")
    return work, origin


def commit(work_dir, files, subject):
    """Write `files` ({relative path: content}) in `work_dir`, commit them, return the sha."""
    for rel, content in files.items():
        path = os.path.join(work_dir, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
        git(work_dir, "add", "--", rel)
    git(work_dir, "commit", "-q", "-m", subject)
    return git(work_dir, "rev-parse", "HEAD")


def stub_bin(tmp, name, script_body):
    """Write an executable stub `tmp/stubs/<name>` and return its path."""
    stubs = os.path.join(tmp, "stubs")
    os.makedirs(stubs, exist_ok=True)
    path = os.path.join(stubs, name)
    with open(path, "w", encoding="utf-8") as f:
        f.write(script_body)
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return path


def deploy_env_names():
    """Every deploy variable the scripts read, scrubbed so the developer's own shell (e.g. a
    direnv-loaded .envrc.local) can't leak into a test."""
    return {"FLY_API_TOKEN", "FASTLANE_USER", "FASTLANE_PASSWORD", "BETA_GROUP",
            "TESTFLIGHT_EXTERNAL", *IOS_VARS, *ANDROID_VARS}


def run_script(script, args, cwd, env_overrides=None):
    """Run a repo bin/ script by absolute path, stubs first on PATH, deploy secrets scrubbed."""
    env = {k: v for k, v in os.environ.items() if k not in deploy_env_names()}
    overrides = dict(env_overrides or {})
    stubs = overrides.pop("STUBS", None)
    if stubs:
        env["PATH"] = stubs + os.pathsep + env.get("PATH", "")
    env.update(overrides)
    return subprocess.run(
        [script, *args], cwd=cwd, env=env, capture_output=True, text=True
    )


RELAY_STUB = """#!/usr/bin/env bash
echo "$*" >> "{log}"
if [ "$1" = card ] && [ "$3" = --field ] && [ "$4" = title ]; then
  printf '%s\\n' "{title}"
fi
exit 0
"""


class ScriptCase(unittest.TestCase):
    """Shared fixture: a fresh origin + clone and a stub relay that logs its argv."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = self._tmp.name
        self.work, self.origin = make_repo(self.tmp)
        self.relay_log = os.path.join(self.tmp, "relay.log")
        self.relay = stub_bin(
            self.tmp, "relay", RELAY_STUB.format(log=self.relay_log, title=TITLE)
        )

    def run_in_work(self, script, *args):
        return run_script(
            script,
            list(args),
            self.work,
            {"RELAY": self.relay, "STUBS": os.path.dirname(self.relay)},
        )

    def relay_calls(self):
        if not os.path.exists(self.relay_log):
            return []
        with open(self.relay_log, encoding="utf-8") as f:
            return [line.rstrip("\n") for line in f]

    def comment_calls(self):
        return [c for c in self.relay_calls() if c.startswith("comment")]

    def remote_main(self):
        return git(self.origin, "rev-parse", "main")


class ShipToMainTest(ScriptCase):
    """RE408 drops PRs from the RE board's Code flow: `merge` squashes the card's branch into one
    `<REF> <title>` commit and pushes it fast-forward to main. It must never force and never
    re-fetch — if main moved since `resync`, the push has to be rejected so the flow loops back
    to rebase, instead of silently folding someone else's commits into this card's commit."""

    def branch_two_ahead(self):
        self.old_main = git(self.work, "rev-parse", "HEAD")
        git(self.work, "checkout", "-q", "-b", "card")
        commit(self.work, {"lib/x.ex": "one\n"}, "a1")
        commit(self.work, {"lib/x.ex": "two\n"}, "a2")
        self.branch_tree = git(self.work, "rev-parse", "HEAD^{tree}")

    def test_squashes_the_branch_into_one_ref_title_commit_on_main(self):
        self.branch_two_ahead()
        result = self.run_in_work(SHIP, "RE408")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

        self.assertEqual(
            git(self.origin, "log", "main", "-1", "--format=%s"), f"RE408 {TITLE}"
        )
        self.assertEqual(git(self.origin, "rev-parse", "main^"), self.old_main)
        self.assertEqual(git(self.origin, "rev-list", "--count", f"{self.old_main}..main"), "1")
        body = git(self.origin, "log", "main", "-1", "--format=%b")
        self.assertIn("* a1", body)
        self.assertIn("* a2", body)
        self.assertLess(body.index("* a1"), body.index("* a2"))
        self.assertIn(TRAILER, body)
        self.assertEqual(git(self.origin, "rev-parse", "main^{tree}"), self.branch_tree)

    def test_comments_the_short_sha_on_the_card(self):
        self.branch_two_ahead()
        result = self.run_in_work(SHIP, "RE408")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

        short = git(self.work, "rev-parse", "--short", "origin/main")
        self.assertIn(f"comment RE408 Shipped to main as {short}", self.relay_calls())

    def test_nothing_ahead_of_origin_main_is_a_no_op(self):
        before = self.remote_main()
        head_before = git(self.work, "rev-parse", "HEAD")
        result = self.run_in_work(SHIP, "RE408")

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn(NOTHING_TO_SHIP, result.stdout + result.stderr)
        self.assertEqual(git(self.work, "rev-parse", "HEAD"), head_before)
        self.assertEqual(self.remote_main(), before)
        self.assertEqual(self.comment_calls(), [])

    def test_a_second_run_after_shipping_is_a_no_op(self):
        self.branch_two_ahead()
        first = self.run_in_work(SHIP, "RE408")
        self.assertEqual(first.returncode, 0, first.stderr + first.stdout)
        shipped = self.remote_main()

        second = self.run_in_work(SHIP, "RE408")
        self.assertEqual(second.returncode, 0, second.stderr + second.stdout)
        self.assertIn(NOTHING_TO_SHIP, second.stdout + second.stderr)
        self.assertEqual(self.remote_main(), shipped)

    def test_a_moved_main_rejects_the_push_without_forcing(self):
        git(self.work, "checkout", "-q", "-b", "card")
        commit(self.work, {"lib/x.ex": "card\n"}, "card change")

        other = os.path.join(self.tmp, "other")
        subprocess.run(["git", "clone", "-q", self.origin, other], check=True, capture_output=True)
        _configure(other)
        theirs = commit(other, {"lib/y.ex": "theirs\n"}, "someone else")
        git(other, "push", "-q", "origin", "main")

        result = self.run_in_work(SHIP, "RE408")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.remote_main(), theirs)
        self.assertEqual(self.comment_calls(), [])

    def test_an_empty_card_title_fails_before_squashing(self):
        self.branch_two_ahead()
        head_before = git(self.work, "rev-parse", "HEAD")
        stub_bin(self.tmp, "relay", RELAY_STUB.format(log=self.relay_log, title="  "))

        result = self.run_in_work(SHIP, "RE408")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("ship_to_main: card RE408 has no title", result.stderr)
        self.assertEqual(git(self.work, "rev-parse", "HEAD"), head_before)
        self.assertEqual(self.remote_main(), self.old_main)

    def test_a_failed_card_comment_after_the_push_still_exits_0(self):
        self.branch_two_ahead()
        stub_bin(
            self.tmp,
            "relay",
            RELAY_STUB.format(log=self.relay_log, title=TITLE).replace(
                "exit 0", '[ "$1" = comment ] && exit 7\nexit 0'
            ),
        )

        result = self.run_in_work(SHIP, "RE408")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        short = git(self.work, "rev-parse", "--short", "origin/main")
        self.assertIn(f"could not comment on RE408 (shipped as {short})", result.stderr)

    def test_no_argument_prints_usage(self):
        result = self.run_in_work(SHIP)
        self.assertNotEqual(result.returncode, 0)
        self.assertRegex(result.stdout + result.stderr, r"usage:.*bin/ship_to_main\.sh <REF>")

    def test_the_script_never_forces_or_fetches(self):
        with open(SHIP, encoding="utf-8") as f:
            text = f.read()
        for banned in ("--force", "--force-with-lease", "git fetch", "git-fetch"):
            self.assertNotIn(banned, text)
        self.assertIsNone(re.search(r"push[^\n]*\s\+", text), "push with a + refspec")


class CardTouchedFlutterTest(ScriptCase):
    """The Deploy flow ships to TestFlight / Play only when the card's own commit on main touched
    flutter/. The card's commit is found by its `<REF> ` subject prefix — the trailing space keeps
    RE40 from matching RE408 — and only the newest such commit counts."""

    def push_main(self):
        git(self.work, "push", "-q", "origin", "main")
        git(self.work, "fetch", "-q", "origin")

    def test_newest_card_commit_touching_flutter_exits_0(self):
        commit(self.work, {"flutter/lib/main.dart": "void main() {}\n"}, "RE408 flutter thing")
        self.push_main()
        result = self.run_in_work(TOUCHED, "RE408")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

    def test_only_the_newest_card_commit_counts(self):
        commit(self.work, {"flutter/pubspec.yaml": "name: x\n"}, "RE408 older flutter")
        commit(self.work, {"lib/relay.ex": "defmodule Relay do end\n"}, "RE408 newer elixir")
        self.push_main()
        result = self.run_in_work(TOUCHED, "RE408")
        self.assertEqual(result.returncode, 1, result.stderr + result.stdout)

    def test_no_card_commit_exits_1_with_a_log_line(self):
        result = self.run_in_work(TOUCHED, "RE999")
        self.assertEqual(result.returncode, 1, result.stderr + result.stdout)
        self.assertIn(
            "card_touched_flutter: no commit for RE999 on origin/main — "
            "treating as no flutter/ change",
            result.stdout + result.stderr,
        )

    def test_prefix_match_needs_the_trailing_space(self):
        commit(self.work, {"flutter/lib/main.dart": "x\n"}, "RE4080 thing")
        self.push_main()
        result = self.run_in_work(TOUCHED, "RE408")
        self.assertEqual(result.returncode, 1, result.stderr + result.stdout)

    def test_a_commit_with_thousands_of_flutter_paths_exits_0(self):
        # Enough paths to overflow a pipe buffer: a `git diff | grep -q` under pipefail would
        # SIGPIPE git diff and read as "did not touch flutter/".
        for i in range(3000):
            path = os.path.join(self.work, "flutter", "assets", f"f{i:04d}.txt")
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as f:
                f.write(f"{i}\n")
        git(self.work, "add", "flutter")
        git(self.work, "commit", "-q", "-m", "RE408 regenerate assets")
        self.push_main()
        result = self.run_in_work(TOUCHED, "RE408")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

    def test_a_ref_in_a_body_line_is_not_a_card_commit(self):
        commit(self.work, {"flutter/lib/main.dart": "x\n"}, "RE408 flutter thing")
        commit(
            self.work,
            {"lib/relay.ex": "defmodule Relay do end\n"},
            "RE500 other card\n\nRE408 is mentioned here",
        )
        self.push_main()
        result = self.run_in_work(TOUCHED, "RE408")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

    def test_no_argument_exits_2_with_usage(self):
        result = self.run_in_work(TOUCHED)
        self.assertEqual(result.returncode, 2)
        self.assertIn("usage:", result.stdout + result.stderr)



# ── Deploy scripts (the Deploy flow's nodes) ──────────────────────────────────────────────

DEPLOY_FLY = os.path.join(BIN, "deploy_fly.sh")
DEPLOY_IOS = os.path.join(BIN, "deploy_ios.sh")
DEPLOY_ANDROID = os.path.join(BIN, "deploy_android.sh")
FLUTTER_VALIDATE = os.path.join(BIN, "flutter_validate.sh")
IOS_FASTFILE = os.path.join(REPO_ROOT, "flutter", "ios", "fastlane", "Fastfile")
ANDROID_FASTFILE = os.path.join(REPO_ROOT, "flutter", "android", "fastlane", "Fastfile")

SECRETS_HINT = "export them in the runner's environment (e.g. .envrc.local), then restart it"
FLY_FAIL = f"deploy_fly: missing required variables: FLY_API_TOKEN — {SECRETS_HINT}"
IOS_SKIP = "deploy_ios: no flutter/ changes for RE408 — skipping iOS"
ANDROID_SKIP = "deploy_android: no flutter/ changes for RE408 — skipping Android"
ANDROID_NO_CREDS = "deploy_android: Android credentials not configured — skipping Play deploy (RLY-103)"

PEM = "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----"
VALIDATION = [
    "flutter pub get",
    "flutter analyze",
    "dart format --set-exit-if-changed .",
    "flutter test",
]

# Every tool stub appends one line per call to the shared log, then does its tool's extra bit.
TOOL_STUB = """#!/usr/bin/env bash
kf=0
if [ -n "${{FASTLANE_API_KEY_PATH:-}}" ] && [ -f "$FASTLANE_API_KEY_PATH" ]; then kf=1; fi
echo "$(basename "$0") $* | cwd=$PWD BUILD_NUMBER=${{BUILD_NUMBER:-}} APP_VERSION=${{APP_VERSION:-}} keyfile_exists=$kf" >> "{log}"
{extra}
exit 0
"""

# flutter: STUB_FLUTTER_FAIL=<subcommand> makes that subcommand exit 1.
FLUTTER_EXTRA = '[ "${STUB_FLUTTER_FAIL:-}" = "$1" ] && exit 1'

# flyctl: STUB_FLYCTL_EXIT overrides the exit code.
FLYCTL_EXTRA = 'exit "${STUB_FLYCTL_EXIT:-0}"'

# fastlane: the build-number lanes write STUB_BUILD_NUMBER; `deploy` captures the secret files
# it can see into {cap}/ so the test can inspect them after the script cleaned up.
FASTLANE_EXTRA = """
case "$*" in
  *next_build_number) printf '%s\\n' "${{STUB_BUILD_NUMBER:-1}}" > "$RELAY_BUILD_NUMBER_FILE" ;;
  deploy)
    if [ -n "${{FASTLANE_API_KEY_PATH:-}}" ]; then
      echo "$FASTLANE_API_KEY_PATH" > "{cap}/keypath"
      [ -f "$FASTLANE_API_KEY_PATH" ] && cp "$FASTLANE_API_KEY_PATH" "{cap}/key.p8"
    fi
    if [ -f key.properties ]; then
      cp key.properties "{cap}/key.properties"
      sf=$(sed -n 's/^storeFile=//p' key.properties)
      echo "$sf" > "{cap}/storefile"
      [ -f "$sf" ] && cp "$sf" "{cap}/keystore"
    fi
    if [ -n "${{PLAY_STORE_CONFIG_JSON_PATH:-}}" ]; then
      echo "$PLAY_STORE_CONFIG_JSON_PATH" > "{cap}/playpath"
      [ -f "$PLAY_STORE_CONFIG_JSON_PATH" ] && echo yes > "{cap}/play_exists"
    fi
    ;;
esac
"""

# relay: `version --field sha` prints line N of {seq} on its Nth call (the last line after).
RELAY_VERSION_STUB = """#!/usr/bin/env bash
echo "$*" >> "{log}"
if [ "$1" = version ]; then
  n=$(grep -c '^version' "{log}")
  total=$(wc -l < "{seq}")
  [ "$n" -gt "$total" ] && n=$total
  sed -n "${{n}}p" "{seq}"
fi
exit 0
"""

IOS_VARS = {
    "APP_STORE_CONNECT_PRIVATE_KEY": base64.b64encode(PEM.encode()).decode(),
    "APP_STORE_CONNECT_KEY_ID": "KEY123",
    "APP_STORE_CONNECT_ISSUER_ID": "issuer-1",
    "MATCH_PASSWORD": "matchpw",
    "MATCH_GIT_BASIC_AUTHORIZATION": "basic-auth",
    "RELAY_BASE_URL": "https://relay.example.com",
    "GOOGLE_IOS_CLIENT_ID": "ios-client",
    "GOOGLE_SERVER_CLIENT_ID": "server-client",
}

ANDROID_VARS = {
    "ANDROID_KEYSTORE_BASE64": base64.b64encode(b"KS").decode(),
    "ANDROID_KEYSTORE_PASSWORD": "storepw",
    "ANDROID_KEY_PASSWORD": "keypw",
    "ANDROID_KEY_ALIAS": "upload",
    "PLAY_STORE_CONFIG_JSON_BASE64": base64.b64encode(b'{"type":"service_account"}').decode(),
}


class DeployCase(ScriptCase):
    """A clone holding a Flutter app skeleton, with logging stubs for every external tool."""

    def setUp(self):
        super().setUp()
        commit(
            self.work,
            {
                "flutter/pubspec.yaml": "name: relay\nversion: 1.2.3+7\n",
                "flutter/ios/.keep": "",
                "flutter/android/.keep": "",
            },
            "flutter skeleton",
        )
        git(self.work, "push", "-q", "origin", "main")
        self.log = os.path.join(self.tmp, "tools.log")
        self.cap = os.path.join(self.tmp, "captured")
        os.makedirs(self.cap)
        stub_bin(self.tmp, "flutter", TOOL_STUB.format(log=self.log, extra=FLUTTER_EXTRA))
        stub_bin(self.tmp, "dart", TOOL_STUB.format(log=self.log, extra=""))
        stub_bin(self.tmp, "flyctl", TOOL_STUB.format(log=self.log, extra=FLYCTL_EXTRA))
        stub_bin(
            self.tmp,
            "fastlane",
            TOOL_STUB.format(log=self.log, extra=FASTLANE_EXTRA.format(cap=self.cap)),
        )
        self.stubs = os.path.dirname(self.relay)
        self.head = git(self.work, "rev-parse", "HEAD")
        # The scripts' mktemp files land here, so a test can prove none outlived the script.
        self.scratch = os.path.join(self.tmp, "scratch")
        os.makedirs(self.scratch)

    def ship_card(self, flutter):
        files = {"flutter/lib/a.dart": "void a() {}\n"} if flutter else {"lib/a.ex": "a\n"}
        commit(self.work, files, "RE408 the card")
        git(self.work, "push", "-q", "origin", "main")
        git(self.work, "fetch", "-q", "origin")
        self.head = git(self.work, "rev-parse", "HEAD")

    def run_deploy(self, script, args=(), env=None):
        overrides = {"RELAY": self.relay, "STUBS": self.stubs, "TMPDIR": self.scratch}
        overrides.update(env or {})
        return run_script(script, list(args), self.work, overrides)

    def tool_lines(self):
        if not os.path.exists(self.log):
            return []
        with open(self.log, encoding="utf-8") as f:
            return [line.rstrip("\n") for line in f]

    def commands(self):
        """Just the `<tool> <argv>` part of each log line."""
        return [line.split(" | ")[0] for line in self.tool_lines()]

    def line_for(self, command):
        return next(line for line in self.tool_lines() if line.split(" | ")[0] == command)

    def captured(self, name):
        path = os.path.join(self.cap, name)
        if not os.path.exists(path):
            return None
        with open(path, encoding="utf-8") as f:
            return f.read()

    def assert_cwd(self, command, suffix):
        self.assertRegex(self.line_for(command), r"cwd=\S*/work" + re.escape(suffix) + " ")


class DeployFlyTest(DeployCase):
    """deploy_fly.sh reproduces CI's `flyctl deploy` and only reports success once the board's
    /api/version serves HEAD — a deploy that never goes live must fail, not hang. It is
    idempotent: deploying Relay restarts the board, whose boot resume re-runs this node, so a
    HEAD that is already live must succeed without deploying again (else it loops forever)."""

    def relay_versions(self, *shas):
        seq = os.path.join(self.tmp, "versions")
        with open(seq, "w", encoding="utf-8") as f:
            f.write("".join(s + "\n" for s in shas))
        stub_bin(self.tmp, "relay", RELAY_VERSION_STUB.format(log=self.relay_log, seq=seq))

    def version_calls(self):
        return [c for c in self.relay_calls() if c.startswith("version")]

    def test_no_fly_token_fails_without_calling_flyctl(self):
        result = self.run_deploy(DEPLOY_FLY)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn(FLY_FAIL, result.stderr)
        self.assertEqual(self.commands(), [])

    def test_a_head_that_is_already_live_succeeds_without_deploying(self):
        self.relay_versions(self.head)
        result = self.run_deploy(DEPLOY_FLY, env={"FLY_API_TOKEN": "x"})
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(self.commands(), [])
        self.assertIn(f"deploy_fly: {self.head} is already live — skipping the deploy", result.stdout)
        self.assertEqual(self.version_calls(), ["version --field sha"])

    def test_deploys_head_and_waits_until_it_is_live(self):
        self.relay_versions("0000000", self.head)
        result = self.run_deploy(DEPLOY_FLY, env={"FLY_API_TOKEN": "x"})
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

        built_at = git(self.work, "log", "-1", "--format=%cI", "HEAD")
        self.assertEqual(
            self.commands(),
            [
                f"flyctl deploy --remote-only --build-arg GIT_SHA={self.head} "
                f"--build-arg BUILT_AT={built_at}"
            ],
        )
        self.assertTrue(
            result.stdout.rstrip("\n").endswith(f"deploy_fly: live at {self.head}"),
            result.stdout,
        )
        self.assertEqual(self.version_calls(), ["version --field sha"] * 2)

    def test_polls_until_the_live_sha_is_head(self):
        self.relay_versions("0000000", "0000000", self.head)
        result = self.run_deploy(
            DEPLOY_FLY, env={"FLY_API_TOKEN": "x", "DEPLOY_POLL_SECONDS": "0"}
        )
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(len(self.version_calls()), 3)

    def test_gives_up_after_the_timeout(self):
        self.relay_versions("deadbeef")
        result = self.run_deploy(
            DEPLOY_FLY,
            env={"FLY_API_TOKEN": "x", "DEPLOY_POLL_SECONDS": "1", "DEPLOY_TIMEOUT_SECONDS": "2"},
        )
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn(
            f"deploy_fly: live version is deadbeef, expected {self.head} — gave up after 2s",
            result.stderr,
        )

    def test_a_failed_flyctl_deploy_never_polls(self):
        self.relay_versions("0000000")
        result = self.run_deploy(
            DEPLOY_FLY, env={"FLY_API_TOKEN": "x", "STUB_FLYCTL_EXIT": "3"}
        )
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.version_calls(), ["version --field sha"])  # the pre-check only


class DeployIosTest(DeployCase):
    """deploy_ios.sh: skip web-only cards before looking at secrets, fail fast naming every
    missing secret, then validate → build number → TestFlight upload → external distribution,
    removing the .p8 on every exit path."""

    def run_ios(self, **env):
        return self.run_deploy(DEPLOY_IOS, ["RE408"], env)

    def full_env(self, **changes):
        env = dict(IOS_VARS, STUB_BUILD_NUMBER="42")
        env.update(changes)
        return env

    def test_a_card_without_flutter_changes_skips_before_the_secret_check(self):
        self.ship_card(flutter=False)
        result = self.run_ios()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn(IOS_SKIP, result.stdout)
        self.assertEqual(self.commands(), [])

    def test_missing_and_empty_variables_are_all_named(self):
        self.ship_card(flutter=True)
        env = dict(IOS_VARS, MATCH_PASSWORD="")
        del env["APP_STORE_CONNECT_KEY_ID"]
        result = self.run_ios(**env)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn(
            "deploy_ios: missing required variables: APP_STORE_CONNECT_KEY_ID MATCH_PASSWORD — "
            f"{SECRETS_HINT}",
            result.stderr,
        )
        self.assertEqual(self.commands(), [])

    def test_validates_numbers_uploads_and_distributes_in_order(self):
        self.ship_card(flutter=True)
        result = self.run_ios(**self.full_env())
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

        self.assertEqual(
            self.commands(),
            VALIDATION
            + [
                "fastlane ios next_build_number",
                "fastlane deploy",
                "fastlane ios distribute_external",
            ],
        )
        for command in VALIDATION:
            self.assert_cwd(command, "/flutter")
        self.assert_cwd("fastlane ios next_build_number", "/flutter/ios")
        self.assert_cwd("fastlane deploy", "/flutter/ios")
        self.assertIn("BUILD_NUMBER=42 ", self.line_for("fastlane deploy"))
        self.assertIn("keyfile_exists=1", self.line_for("fastlane deploy"))
        self.assertIn(
            "BUILD_NUMBER=42 APP_VERSION=1.2.3 ", self.line_for("fastlane ios distribute_external")
        )
        self.assertTrue(self.captured("key.p8").startswith("-----BEGIN PRIVATE KEY-----"))
        self.assertFalse(os.path.exists(self.captured("keypath").strip()))
        self.assertEqual(os.listdir(self.scratch), [])

    def test_a_raw_pem_private_key_is_written_as_is(self):
        self.ship_card(flutter=True)
        result = self.run_ios(**self.full_env(APP_STORE_CONNECT_PRIVATE_KEY=PEM))
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertTrue(self.captured("key.p8").startswith("-----BEGIN PRIVATE KEY-----"))

    def test_testflight_external_false_skips_distribution(self):
        self.ship_card(flutter=True)
        result = self.run_ios(**self.full_env(TESTFLIGHT_EXTERNAL="false"))
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("fastlane deploy", self.commands())
        self.assertFalse(any("distribute_external" in c for c in self.commands()))

    def test_a_failed_validation_stops_before_fastlane_and_removes_the_key(self):
        self.ship_card(flutter=True)
        result = self.run_ios(**self.full_env(STUB_FLUTTER_FAIL="test"))
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(any(c.startswith("fastlane") for c in self.commands()))
        self.assertEqual(os.listdir(self.scratch), [])

class DeployAndroidTest(DeployCase):
    """deploy_android.sh: skip web-only cards, skip cleanly (exit 0) until the RLY-103
    credentials exist, otherwise validate → build number → Play internal upload, removing the
    keystore, key.properties and Play JSON on exit."""

    def run_android(self, **env):
        return self.run_deploy(DEPLOY_ANDROID, ["RE408"], env)

    def test_a_card_without_flutter_changes_skips(self):
        self.ship_card(flutter=False)
        result = self.run_android()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn(ANDROID_SKIP, result.stdout)
        self.assertEqual(self.commands(), [])

    def test_an_empty_credential_skips_the_play_deploy(self):
        self.ship_card(flutter=True)
        result = self.run_android(**dict(ANDROID_VARS, ANDROID_KEYSTORE_BASE64=""))
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn(ANDROID_NO_CREDS, result.stdout.splitlines())
        self.assertEqual(self.commands(), [])

    def test_builds_and_uploads_with_temporary_signing_files(self):
        self.ship_card(flutter=True)
        result = self.run_android(**dict(ANDROID_VARS, STUB_BUILD_NUMBER="17"))
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

        self.assertEqual(
            self.commands(),
            VALIDATION + ["fastlane android next_build_number", "fastlane deploy"],
        )
        self.assert_cwd("fastlane deploy", "/flutter/android")
        self.assertIn("BUILD_NUMBER=17 ", self.line_for("fastlane deploy"))

        props = self.captured("key.properties")
        self.assertIn("keyAlias=upload\n", props)
        self.assertIn("storePassword=storepw\n", props)
        self.assertIn("keyPassword=keypw\n", props)
        self.assertEqual(self.captured("keystore"), "KS")
        self.assertEqual(self.captured("play_exists"), "yes\n")

        self.assertFalse(os.path.exists(os.path.join(self.work, "flutter/android/key.properties")))
        self.assertFalse(os.path.exists(self.captured("storefile").strip()))
        self.assertFalse(os.path.exists(self.captured("playpath").strip()))
        self.assertEqual(os.listdir(self.scratch), [])


class FastfileTest(unittest.TestCase):
    """The runner deploys need a build-number lane per platform and a read-only `match`."""

    def read(self, path):
        with open(path, encoding="utf-8") as f:
            return f.read()

    def test_both_fastfiles_define_next_build_number(self):
        self.assertIn("lane :next_build_number", self.read(IOS_FASTFILE))
        self.assertIn("lane :next_build_number", self.read(ANDROID_FASTFILE))

    def test_ios_fastfile_gates_match_on_relay_deploy(self):
        self.assertIn("RELAY_DEPLOY", self.read(IOS_FASTFILE))

    @unittest.skipUnless(shutil.which("ruby"), "ruby not on PATH")
    def test_both_fastfiles_are_valid_ruby(self):
        for path in (IOS_FASTFILE, ANDROID_FASTFILE):
            result = subprocess.run(["ruby", "-c", path], capture_output=True, text=True)
            self.assertIn("Syntax OK", result.stdout, path + result.stderr)


if __name__ == "__main__":
    unittest.main()
