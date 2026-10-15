# handoff

Move live [Claude Code](https://claude.com/claude-code) sessions from your laptop
to an always-on Mac, keep working from your phone, and move them back when you
are home.

I do most of my work on a laptop and use Claude's Remote Control from my phone
when I'm out. But I don't want to leave the laptop running in my backpack. So
before I close it, I hand my sessions off to a Mac mini at home. I pick them up
on my phone through Remote Control, and when I'm back I hand them off to the
laptop again.

```
laptop                                   Mac mini (always on)
──────                                   ────────────────────
handoff out my-session  ───────────────▶ tmux: claude --resume <id> --remote-control
  stops the session                        ▲
  syncs repo + .git + transcript           │  Claude app on your phone
                                           │  (Remote Control)
handoff in  ◀────────────────────────────  stops it, syncs everything back,
  prints `claude --resume <id>`            commits made there included
```

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
- `out` refuses a session whose folder is your home directory, a repo larger
  than `HANDOFF_MAX_GB` (default 5), and more than `HANDOFF_MAX_SESSIONS`
  (default 8) sessions on the remote. Each session uses about 0.5 GB of memory.
- If the session's path already exists on the remote and points to a
  different folder, `out` replaces a stale symlink and refuses a real directory.

`--force` skips the guards.

## Requirements

- Two Macs. Tested with macOS on both ends, laptop to Mac mini, over
  [Tailscale SSH](https://tailscale.com/kb/1193/tailscale-ssh), with Claude Code
  2.1.296.
- On the laptop: bash, rsync, jq, git, python3 (for `setsid`) and ssh access to
  the remote without a password prompt.
- On the remote: Claude Code installed and logged in to the same account as
  the laptop (that is how the sessions show up in the app), plus tmux, jq, git
  and rsync.
- Remote Control on your Claude plan.

## Install

The CLI:

```sh
git clone https://github.com/zaycruz/claude-handoff ~/claude-handoff
ln -s ~/claude-handoff/handoff ~/.local/bin/handoff
mkdir -p ~/.config/handoff
cp ~/claude-handoff/config.example ~/.config/handoff/config   # then set HANDOFF_HOST
```

The Claude Code plugin (the `handoff` skill), in Claude Code:

```
/plugin install handoff --marketplace zaycruz/claude-handoff
```

Or link the skill by hand: `ln -s ~/claude-handoff/skills/handoff ~/.claude/skills/handoff`.

## Use

```sh
handoff list                 # live sessions on the laptop, and what is on the remote
handoff out my-session       # by name, id or id prefix; several at once is fine
handoff out self             # the session you are in (from its ! prompt)
# close the laptop, open the Claude app, find the session under Remote Control
handoff in                   # brings back everything that is on the remote
handoff status               # what the remote owns right now
```

While a session is on the remote, don't resume it on the laptop. Watch it from
the laptop with `ssh -t <host> tmux attach -t ho-<first 8 chars of the id>`.

## Configuration

`~/.config/handoff/config` is a bash file. See [config.example](config.example).

| Variable | Meaning |
|---|---|
| `HANDOFF_HOST` | ssh host of the remote Mac (required) |
| `HANDOFF_PATHS` | extra path prefixes that differ between machines, `"local=remote"`, or `"local>remote"` for one way. Home always maps to home. |
| `HANDOFF_CLAUDE_ARGS` | extra arguments for `claude` on the remote, e.g. `--permission-mode auto` |
| `HANDOFF_REMOTE_SHELL` | login shell used on the remote (default `zsh`) |
| `HANDOFF_MAX_GB` | size limit for a synced tree (default 5) |
| `HANDOFF_MAX_SESSIONS` | most sessions on the remote at once (default 8) |

## Test

`e2e.sh` runs the whole loop against your real remote with throwaway sessions
and repos. It uses its own state folder, so your real sessions are never
touched. It makes a few small paid `claude -p --model haiku` calls and takes
about 3 minutes.

```sh
./e2e.sh                 # Claude is asked in plain words to hand itself off (needs the skill)
E2E_VIA=shell ./e2e.sh   # same, typed as `! handoff out ...`
# log: ~/handoff-e2e/logs/e2e-<timestamp>.log
```

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

## Limits

- One remote host.
- Sessions in your home directory are refused. Start Claude in a project folder.
- `.beads/` folders are not synced; they hold a per-machine database.
- The trust and transcript handling depend on how Claude Code stores sessions
  today (`~/.claude/sessions`, `~/.claude/projects`). A future version may
  change that.

## License

MIT
