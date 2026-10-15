---
name: handoff
description: Hand live Claude Code sessions from this laptop to the always-on remote Mac (so the user can close the laptop and continue from the Claude app on their phone through Remote Control) and bring them back. Use when the user says they are leaving, heading out, closing the laptop, going mobile, or asks to hand off, move or send this session (or several, or "everything") to the mini or remote; and when they say they are back, home, or want sessions brought back or handed back to the laptop. Also for "what's on the mini" / handoff status.
---

# handoff

The `handoff` CLI does the work. It moves a session by stopping it on the
laptop, syncing its git tree, `.git` and transcript to the remote, and resuming
it there in tmux with Remote Control on. The user then continues from the
Claude app on their phone. `handoff in` reverses it.

If `handoff` is not on PATH, tell the user to install it from
https://github.com/zaycruz/claude-handoff and stop.

## Leaving: "I'm heading out", "hand this off"

**Just this session** (the default when the user doesn't name others):

1. Say it in one line *before* you run anything, because this turn ends when
   the session stops. For example: "Handing this session to <host>. Pick it up
   under Remote Control in the Claude app."
2. Run `handoff out self`. Pass the Bash tool a timeout of 300000.
3. The command returns at once. It prints that the session stops in a few
   seconds and resumes on the remote. Stop there and don't start new work: it
   would be cut off.

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

1. Run `handoff in` (all) or `handoff in <id>`.
2. Show the user the `cd ... && claude --resume <id>` lines it prints, one per
   session, so they can reopen them. Don't start `claude` processes on the
   laptop yourself.

## When the CLI refuses

Read the message. Never add `--force` unless the user explicitly says to. The
guards protect their work.

| Message | What to do |
|---|---|
| `other live sessions work inside ...` | Those sessions share the repo. Offer to hand them off together, in the same command, or to stop them first. |
| `... changed on the laptop while ... was on <host>` | Syncing back would overwrite laptop changes. Show `git status` for that folder and ask: commit/stash first, or `--force` to let the remote's copy win. Files it replaces are kept in `~/.handoff/backup/`. |
| `refusing to sync a whole home dir` | The session runs in the home folder. Explain, and suggest starting Claude in the project folder next time. |
| `would run N sessions` | Over the remote's limit. Hand off fewer, or bring some back first. |
| `is already on <host>` | It is already there. `handoff status` lists what the remote owns. |
| `<path> exists on <host> and is not <path>` | A different folder sits at that path on the remote. Tell the user. Don't delete it. |

## Rules

- A session that `handoff status` lists belongs to the remote. Don't resume it
  on the laptop until `handoff in`.
- `handoff status` shows what is on the remote right now.
