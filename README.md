# remote-handoff

Move live [Claude Code](https://claude.com/claude-code) and
[Codex CLI](https://github.com/openai/codex) sessions from your laptop to an
always-on remote host (macOS or Linux), let them keep working there, and move
them back. The session keeps its memory both ways: the transcript, the repo,
`.git` and the commits made on the remote all come home.

Close the laptop while a long task runs, give a job to a stronger machine, or
pick a Claude Code session up on your phone through Remote Control. The agent
can also hand itself off: say "I'm heading out", and with `handoff back` it
returns and resumes on the laptop when the remote part is done.

```
laptop                                   remote host (always on)
──────                                   ───────────────────────
handoff out my-session  ───────────────▶ tmux: claude --resume <id>
  stops the session                            or codex resume <id>
  syncs repo + .git + transcript           works on .handoff/HANDOFF.md,
                                           or you drive it (Remote Control)
handoff in  ◀────────────────────────────  stops it, syncs everything back,
  prints the resume command                commits made there included
```

## Origin

Based on [zaycruz/claude-handoff](https://github.com/zaycruz/claude-handoff) by
Zay Cruz (MIT), at commit `def2b14`. That version moves Claude Code sessions
between macOS machines. This project adds:

- **Remote root.** Trees go to `HANDOFF_ROOT/<path relative to home>` (default
  `~/handoff`), not the same path under the remote home. A handoff can no longer
  rsync over a real checkout that already lives on the remote.
- **What gets sent.** `.gitignore` files are honoured, and `.handoff/filter` adds
  task rules written by the agent. `in` applies the same rules, so it never
  deletes laptop files that were never sent.
- **Size.** `out --dry-run` shows what would be sent. `out` stops above
  `HANDOFF_WARN_MB` (`--yes` sends anyway) and when the remote disk is too full.
- **Notes.** With `.handoff/HANDOFF.md` in the tree, the remote session starts
  working on it at once and writes `.handoff/FINISH.md`. `in` prints it.
- **Model and effort** of the session are kept on the remote.
- **Symlinks out of the tree** (such as linked skills) are sent as copies; the
  laptop links stay links.
- **Mirrors.** The remote transcript is removed after `in`; the tree stays as a
  warm mirror. `handoff mirrors` lists them, `out` prunes the ones unused for
  `HANDOFF_MAX_AGE_DAYS`, `handoff prune` does it by hand.
- **Skills check.** `out` warns when the remote's skills or plugins differ.
- **Codex CLI.** Codex sessions move the same way (see [Codex](#codex)).
- **Setup check.** `handoff doctor` checks both machines and the agent CLIs.
- **Wait and return.** `handoff wait` blocks until the remote tasks are done.
  `handoff back` waits, brings the session home, and resumes it in local tmux.
- **Retries.** ssh and rsync calls retry when the connection drops.
- **Test protocol.** [TEST-PROTOCOL.md](TEST-PROTOCOL.md): an agent hands its own
  session to the remote and back, and writes a report.
- Tested with a Linux remote.

## Codex

Codex CLI sessions (tested with 0.164.0) move with the same commands. A session
ID tells `handoff` which agent it belongs to. Differences from Claude Code:

- There is no Remote Control. The remote session works on `.handoff/HANDOFF.md`
  alone, or waits in tmux. Watch it with `ssh -t <host> tmux attach -t ho-<id>`.
- On the laptop, Codex runs sessions inside a shared app-server daemon. Closing a
  Codex window does not stop a running turn, so `out` waits until the turn ends.
- `handoff out self` finds the session from `CODEX_THREAD_ID`. Codex runs shell
  commands in a sandbox without network, so the command needs approval to run
  outside it.
- On the remote, Codex runs with `--no-daemon`, so `in` really stops it.
- The folder trust is saved in the remote `~/.codex/config.toml` (Codex has no
  other way to skip the trust dialog). `prune` removes it with the mirror.
- After `in`, use `codex resume <id>`. `codex exec resume` fails while the laptop
  daemon still holds the session.
- Codex's Linux sandbox needs unprivileged user namespaces. If `handoff doctor
  codex` reports that it fails on the remote, fix the host, or set
  `HANDOFF_CODEX_ARGS="--dangerously-bypass-approvals-and-sandbox"` for a host you trust.
- Subagent threads of a Codex session are not moved.

## Just tell Claude

With the plugin installed, you don't type commands. In any session:

> I'm heading out.

Claude says it is handing the session off, runs `handoff out self`, and the
session continues on the remote. Pick it up under Remote Control in the Claude
app. You can also say:

- "Hand off this session and the api one too": one batch, so sessions that
  share a repo move together.
- "Hand off everything": Claude lists live sessions and proposes a short set.
  The remote has a session limit, and busy sessions get flagged.
- "I'm back": on the laptop, Claude runs `handoff in` and gives you the
  `claude --resume` lines.

Claude never passes `--force` unless you say so. When a guard refuses, it tells
you why and what you can do.

Claude needs to run `handoff` without an approval prompt. Auto mode
(`--permission-mode auto`) allowed it in testing. In the default mode, approve
it once, or add `"Bash(handoff:*)"` to `permissions.allow` in your settings.

## What it does

`handoff out <session>`
1. Copies the session's git tree to the remote with rsync while the session is
   still running. For a git worktree it also copies the shared `.git`.
2. Stops the session on the laptop, then syncs again.
3. Copies the transcript (and subagent transcripts and file history), rewriting
   paths for the remote: a different user name, different disks.
4. Marks the folder as trusted on the remote, so no dialog blocks the session.
5. Resumes the session there in tmux with `claude --resume <id> --remote-control <name>`.

`handoff out self` hands off the session that runs it: Claude's Bash tool, or
`! handoff out self` at the prompt.

`handoff in`
1. Stops the remote session and syncs the tree, `.git` and transcript back,
   rewriting paths the other way. Laptop files it replaces are kept in
   `~/.handoff/backup/`.
2. Prints the `claude --resume` command to continue on the laptop.

When a session hands itself off, the CLI returns at once. The sync, stop and
restart finish in a detached process a few seconds later.

### Guards

- `out` refuses when another live session on the laptop works in the same tree
  or in another worktree of the same repo, because `in` would overwrite its
  changes. Hand them off together (`handoff out a b`) or stop them first.
- `in` refuses when the laptop copy changed while the remote owned it (HEAD,
  working tree or any ref).
- `out` refuses a session whose folder is your home directory, a sync larger
  than `HANDOFF_WARN_MB` (default 500; `--yes` sends anyway), a sync that does
  not fit on the remote disk, and more than `HANDOFF_MAX_SESSIONS` (default 8)
  sessions on the remote. Each session uses about 0.5 GB of memory.
- If the session's path already exists on the remote and points to a
  different folder, `out` replaces a stale symlink and refuses a real directory.

`--force` skips the guards.

## Requirements

- Upstream: tested with macOS on both ends over
  [Tailscale SSH](https://tailscale.com/kb/1193/tailscale-ssh), Claude Code 2.1.296.
  This project: tested from a Mac laptop to an Ubuntu remote over plain SSH, Claude
  Code 2.1.310 and Codex CLI 0.164.0.
- On the laptop: bash, rsync 3.x, jq, git, python3 (for `setsid`) and ssh access
  to the remote without a password prompt. macOS ships openrsync as
  `/usr/bin/rsync`, which `handoff` refuses: it ignores the filter rules that keep
  `in` from deleting unsent laptop files. Install rsync with `brew install rsync`,
  or point `HANDOFF_RSYNC` at an rsync 3 binary.
- On the remote: Claude Code installed and logged in to the same account as
  the laptop (that is how the sessions show up in the app), plus tmux, jq, git
  and rsync.
- Remote Control on your Claude plan.

## Install

The CLI:

```sh
git clone https://github.com/scsnake/remote-handoff ~/remote-handoff
ln -s ~/remote-handoff/handoff ~/.local/bin/handoff
mkdir -p ~/.config/handoff
cp ~/remote-handoff/config.example ~/.config/handoff/config   # then set HANDOFF_HOST
```

The Claude Code plugin (the `handoff` skill), in Claude Code:

```
/plugin install handoff --marketplace scsnake/remote-handoff
```

Or link the skill by hand: `ln -s ~/remote-handoff/skills/handoff ~/.claude/skills/handoff`.

## Use

```sh
handoff list                 # live sessions on the laptop, and what is on the remote
handoff out my-session       # by name, id or id prefix; several at once is fine
handoff out self             # the session you are in (from its ! prompt)
# close the laptop, open the Claude app, find the session under Remote Control
handoff in                   # brings back everything that is on the remote
handoff status               # what the remote owns right now
handoff out self --dry-run   # what would be sent, change nothing
handoff doctor               # check the setup on both machines first
handoff wait                 # block until remote tasks wrote FINISH.md and are idle
handoff back self --prompt "check the results"   # wait, come back, resume here in tmux
handoff mirrors              # trees kept on the remote, size and last use
handoff prune --dry-run      # mirrors older than HANDOFF_MAX_AGE_DAYS
```

While a session is on the remote, don't resume it on the laptop. Watch it from
the laptop with `ssh -t <host> tmux attach -t ho-<short id>` (`out` prints it: the first 8
characters of the id, plus the last 4 for Codex ids).

## Configuration

`~/.config/handoff/config` is a bash file. See [config.example](config.example).

| Variable | Meaning |
|---|---|
| `HANDOFF_HOST` | ssh host of the remote Mac (required) |
| `HANDOFF_PATHS` | extra path prefixes that differ between machines, `"local=remote"`, or `"local>remote"` for one way. Home always maps to home. |
| `HANDOFF_CLAUDE_ARGS` | extra arguments for `claude` on the remote, e.g. `--permission-mode auto` |
| `HANDOFF_REMOTE_SHELL` | login shell used on the remote (default `zsh`) |
| `HANDOFF_ROOT` | where trees go on the remote (default `~/handoff`; empty = same path under the remote home) |
| `HANDOFF_WARN_MB` | stop when one sync sends more than this (default 500) |
| `HANDOFF_MAX_AGE_DAYS` | prune mirrors unused this long on `out` (default 30; 0 = never) |
| `HANDOFF_GITIGNORE` | honour `.gitignore` files (default 1) |
| `HANDOFF_RSYNC` | rsync 3.x binary to use (default `rsync` on PATH) |
| `HANDOFF_SKILLS_CHECK` | warn when the remote's skills/plugins differ (default 1) |
| `HANDOFF_MAX_SESSIONS` | most sessions on the remote at once (default 8) |
| `HANDOFF_CODEX_ARGS` | extra arguments for `codex resume` on the remote |
| `HANDOFF_BUSY_WAIT` / `HANDOFF_SELF_WAIT` | seconds to wait for a Codex turn to end (default 30 / 180) |
| `HANDOFF_WAIT_POLL` / `HANDOFF_WAIT_TIMEOUT` | `wait` and `back`: seconds between checks (default 30), limit (default 0 = none) |

## Test

`e2e.sh` runs the whole loop against your real remote with throwaway sessions
and repos. It uses its own state folder, so your real sessions are never
touched. It makes a few small paid `claude -p --model haiku` calls and takes
about 3 minutes.

```sh
./e2e.sh                 # Claude is asked in plain words to hand itself off (needs the skill)
E2E_VIA=shell ./e2e.sh   # same, typed as `! handoff out ...`
./e2e-codex.sh           # Codex: a live TUI hands itself off, plus wait, back and in
# logs: ~/handoff-e2e/logs/, ~/handoff-e2e-codex/logs/
```

To prove your own setup before a real handoff, run the
[test protocol](TEST-PROTOCOL.md) in a real session. The agent runs `doctor` and
the scripted test, hands itself to the remote and back, and writes
`.handoff/E2E-REPORT.md`.

It checks:
- the guards
- Claude, asked "I'm heading out. Hand this session and ... off", using the
  skill to hand itself and a second session off. The test confirms the
  `handoff out` call in the transcript.
- Remote Control starting on the remote
- the remote editing a file and committing in a worktree reached through a
  symlink
- the laptop-changed guard
- path rewriting both ways
- the resumed laptop session remembering what happened on the remote
- (added here) the remote root, `--dry-run`, an ignored file staying on the laptop, a
  symlink out of the tree, mirror stamps, and the remote transcript cleanup

## Limits

- One remote host.
- Sessions in your home directory are refused. Start Claude in a project folder.
- `.beads/` folders are not synced; they hold a per-machine database.
- The trust and transcript handling depend on how Claude Code stores sessions
  today (`~/.claude/sessions`, `~/.claude/projects`). A future version may
  change that.

## License

MIT
