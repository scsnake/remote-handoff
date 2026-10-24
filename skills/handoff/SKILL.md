---
name: handoff
description: Hand live Claude Code or Codex CLI sessions from this laptop to the always-on remote host (so the user can close the laptop; Claude sessions continue from the Claude app on their phone through Remote Control) and bring them back. Use when the user says they are leaving, heading out, closing the laptop, going mobile, or asks to hand off, move or send this session (or several, or "everything") to the mini or remote; and when they say they are back, home, or want sessions brought back or handed back to the laptop. Also for "what's on the mini" / handoff status.
---

# handoff

The `handoff` CLI does the work. It moves a session by stopping it on the
laptop, syncing its git tree, `.git` and transcript to the remote, and resuming
it there in tmux. `handoff in` reverses it.

- Claude Code: the remote session has Remote Control on. The user continues from
  the Claude app on their phone.
- Codex: there is no Remote Control. The remote session works on
  `.handoff/HANDOFF.md` alone, or waits. The user can watch it with
  `ssh -t <host> tmux attach -t ho-<id>`. Codex runs your shell commands in a
  sandbox without network, and `handoff` needs ssh: ask for approval to run it
  outside the sandbox.

Before the first real handoff, the user can run `handoff doctor` (setup check) or
the test protocol in `TEST-PROTOCOL.md` of the handoff repo.

If `handoff` is not on PATH, tell the user to install it from
https://github.com/zaycruz/claude-handoff and stop.

## Leaving: "I'm heading out", "hand this off"

**Just this session** (the default when the user doesn't name others):

1. If the remote should keep working on its own (not only wait for the phone),
   write `.handoff/HANDOFF.md` at the repo root. Keep it self-contained: goal and
   definition of done, done so far, numbered next steps, decisions and why,
   constraints (what not to touch, whether local commits are allowed), exact
   verify commands, and data already on the remote (give its path instead of
   sending it). The remote session then starts on it and writes
   `.handoff/FINISH.md` when done or blocked.
2. Run `handoff out self --dry-run`. It shows the file count, size, and largest
   files it would send. Compare them with the task:
   - Write `.handoff/filter` (rsync rules, first match wins, before
     `.gitignore`): `- /data/raw/` skips a path the task does not read,
     `+ /fixtures/***` sends an ignored path it needs. Add a `#` reason per rule.
   - When unsure, send it: a missing input blocks the remote. Ask the user
     before sending large inputs.
   - Over `HANDOFF_WARN_MB` the real run stops; `--yes` sends anyway.
3. Optional: if the user wants the session back on the laptop by itself once the
   remote is done, run `handoff back self --prompt "<what to do next>"` first.
   It needs a `HANDOFF.md` task, because it waits for `FINISH.md`. The laptop must
   be on at that time.
4. Say it in one line *before* you run anything, because this turn ends when
   the session stops. For example: "Handing this session to <host>. Pick it up
   under Remote Control in the Claude app." (Codex: "... It continues there in
   tmux.")
5. Run `handoff out self`. Claude Code: pass the Bash tool a timeout of 300000.
6. The command returns at once. It prints that the session stops in a few
   seconds and resumes on the remote. End your turn at once, with one short
   line. Do not start new work: it would be cut off. (Codex: the CLI waits for
   your turn to end before it copies the session.)

`out` also warns when the remote's skills or plugins differ from the laptop's.
That only matters if the task needs a skill that is not loaded yet; mention it
to the user (they sync skills with their own deploy) and go on.

**Several sessions, or "everything":**

1. Run `handoff list`. It shows live laptop sessions (id, name, status, folder)
   and what is already on the remote.
2. Pick the candidates:
   - Sessions in project folders. Sessions in the home directory are refused.
   - `idle` before `busy`. Stopping a busy session cuts off its current turn,
     so name the busy ones and ask about them.
   - The ones the user named or plausibly cares about, such as recent ones.
3. The remote has limited memory (default limit 8 sessions,
   `HANDOFF_MAX_SESSIONS`). For "everything", propose a short list and get a
   yes. Don't send dozens.
4. Hand them off in **one** command. Sessions that share a repo must go
   together: `handoff out <id> <id> ... [self]`. Put `self` in the same command
   if this session goes too. The CLI processes it last.
5. Report what moved, in a short list of names.

## Back: "I'm back", "bring them home"

This only works on the laptop. The laptop pulls from the remote. If you are
running on the remote (the user is on their phone), say the hand-back has to be
started from the laptop and stop.

1. Run `handoff in` (all) or `handoff in <id>`. To wait until remote tasks
   finish first, run `handoff wait` (it returns when every session wrote
   `FINISH.md` and is idle).
2. Show the user the `cd ... && claude --resume <id>` or `codex resume <id>`
   lines it prints, one per session, so they can reopen them. Don't start agent
   processes on the laptop yourself.
3. If it printed a `.handoff/FINISH.md`, summarize it: status, changes,
   verification, open questions, missing inputs.

## When the CLI refuses

Read the message. Never add `--force` unless the user explicitly says to. The
guards protect their work.

| Message | What to do |
|---|---|
| `other live sessions work inside ...` | Those sessions share the repo. Offer to hand them off together, in the same command, or to stop them first. |
| `... changed on the laptop while ... was on <host>` | Syncing back would overwrite laptop changes. Show `git status` for that folder and ask: commit/stash first, or `--force` to let the remote's copy win. Files it replaces are kept in `~/.handoff/backup/`. |
| `refusing to sync a whole home dir` | The session runs in the home folder. Explain, and suggest starting Claude in the project folder next time. |
| `would send N MB` | Run `--dry-run`, skip big paths in `.handoff/filter`, or ask the user before `--yes`. |
| `has N MB free` | The remote disk is too full. Tell the user; `handoff prune` may free space. |
| `would run N sessions` | Over the remote's limit. Hand off fewer, or bring some back first. |
| `is already on <host>` | It is already there. `handoff status` lists what the remote owns. |
| `<path> exists on <host> and is not <path>` | A different folder sits at that path on the remote. Tell the user. Don't delete it. |
| `is in the middle of a turn` | A Codex session is still working. Closing its window does not stop the turn. Wait, or ask the user to interrupt it (Esc). |
| `the laptop transcript of ... changed` | The session was resumed on the laptop while the remote owned it. Ask the user which copy wins. `--force` takes the remote one. |
| `several Codex windows work in ...` | The CLI cannot tell which window is the session. Ask the user to close it. |
| `the Codex turn did not end` | The self-handoff waited 3 minutes for the turn to end. The session stays on the laptop. |

## Mirrors on the remote

The synced tree stays on the remote under `HANDOFF_ROOT` after `in`, so the
next `out` only sends changes. `handoff mirrors` lists them with size and last
use. `out` prunes mirrors unused for `HANDOFF_MAX_AGE_DAYS` (default 30);
`handoff prune [--max-age N] [--dry-run]` does it by hand.

## Rules

- A session that `handoff status` lists belongs to the remote. Don't resume it
  on the laptop until `handoff in`.
- `handoff status` shows what is on the remote right now.
