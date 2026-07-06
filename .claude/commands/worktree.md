---
description: Create or move into a git worktree (smart: enters if it exists, creates if not)
argument-hint: <name>
allowed-tools: Bash(git worktree list:*), Bash(git worktree list), EnterWorktree
---

Move this session into a git worktree named `$ARGUMENTS`.

If no name was given (`$ARGUMENTS` is empty), ask the user what to name the worktree (a short feature/branch slug), then continue.

Steps:

1. Run `git worktree list` to see existing worktrees.
2. Look for a worktree whose path ends in `.claude/worktrees/$ARGUMENTS` (that's where this command's worktrees live).
3. **If it already exists:** call `EnterWorktree` with `path` set to that worktree's absolute path to switch into it. Do not create a new one.
4. **If it does not exist:** call `EnterWorktree` with `name: "$ARGUMENTS"` to create a fresh worktree on a new branch and switch into it.

After switching, confirm to the user which worktree the session is now in (created vs. entered) and the current branch.
