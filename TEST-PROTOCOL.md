# Handoff test protocol

An agent runs this protocol inside a real Codex or Claude Code session. It proves
that your laptop, your remote host and your agent CLI work together. Run it once
after you install or change the setup, and before you trust a real handoff.

The agent hands **its own session** to the remote and back. So the test covers the
real path: your config, your permissions, your login on both machines, and your
network.

| Phase | Where | What it proves |
|---|---|---|
| 0. Preflight | laptop | tools, ssh, remote root, agent CLI version and login, sandbox |
| 1. Scripted test | laptop | the full loop with throwaway sessions (`e2e-codex.sh` or `e2e.sh`) |
| 2. Live handoff | laptop, then remote | this session moves, keeps its memory, and works on the remote |
| 3. Return | laptop | files, commits and memory come back; the remote is clean |

Time: about 20 minutes. Cost: a few small model calls, plus the turns of this session.

## For the user: start the test

1. Set up `~/.config/handoff/config` (see `config.example`) and put `handoff` on your PATH.
2. Make an empty test folder and start a new session in it:

   ```sh
   mkdir -p ~/handoff-live-test && cd ~/handoff-live-test && git init
   codex          # or: claude
   ```

3. Send this message:

   > Run the handoff test protocol in `<path to this repo>/TEST-PROTOCOL.md`.

4. Warning: Codex runs `handoff` with ssh, so it needs network access outside the
   sandbox. Approve the command when Codex asks. If the laptop is yours and you trust
   it, you can start Codex with `--dangerously-bypass-approvals-and-sandbox` instead.
5. Wait. The session leaves the laptop during phase 2 and comes back by itself for
   phase 3, in tmux session `ho-back-<short id>`. The agent tells you the name. To
   watch phase 3, run `tmux attach -t ho-back-<short id>`.
6. Read the result in `.handoff/E2E-REPORT.md` in the test folder.

## For the agent: rules

- Run the phases in order. Stop at the first phase that fails. Report what failed,
  the evidence, and the fix you suggest.
- Use only the test folder. Do not touch other folders, sessions or remote paths,
  except as the steps say.
- Do not push, fetch or change git remotes.
- Do not read secrets, such as `auth.json` or tokens.
- Record each check as PASS or FAIL, with its evidence: the command, plus the
  output line that proves the result.
- `REPO` is the folder that holds this protocol. `AGENT` is `codex` or `claude`.
  `SID` is your session ID: `$CODEX_THREAD_ID` (Codex) or `$CLAUDE_CODE_SESSION_ID`
  (Claude Code).

## Phase 0: preflight

1. Run `handoff doctor AGENT`.
2. PASS when the last line is `RESULT: OK`. A WARN line is not a failure, but
   copy it into the report.
3. If it fails, stop. Report each `FAIL` line and its fix.

## Phase 1: scripted test

1. Start the script in the background, because it takes about 5 minutes:

   ```sh
   E2E_SKIP_DOCTOR=1 nohup REPO/e2e-codex.sh > /tmp/handoff-e2e-phase1.log 2>&1 &   # Codex (phase 0 ran doctor)
   E2E_VIA=shell nohup REPO/e2e.sh > /tmp/handoff-e2e-phase1.log 2>&1 &   # Claude Code
   ```

2. Every 30 seconds, read the last lines of the log. Stop waiting when a `RESULT:`
   line shows, or after 15 minutes.
3. PASS when the log shows `RESULT: PASS`.
4. If it fails, stop. Report every `FAIL` line and the log path.

## Phase 2: live handoff of this session

1. Make a code word: run `openssl rand -hex 3`. Say the word in your reply to the
   user. Do not write it to any file. In phase 3 you must recall it from memory, and
   that proves that the transcript came back.
2. Write `.handoff/E2E-STATE.md` with:
   - `laptop_host`: output of `hostname`
   - `laptop_path`: output of `pwd -P`
   - `sid`: your session ID
   - `agent`: `codex` or `claude`
   - `started`: output of `date -u +%FT%TZ`
   - the result of phases 0 and 1, with evidence
3. Make a laptop commit:

   ```sh
   echo laptop > laptop.txt && git add laptop.txt && git -c user.email=e2e@local -c user.name=e2e commit -m "e2e: laptop"
   ```

4. Write `.handoff/HANDOFF.md` with this text. Replace `<laptop_host>` and
   `<laptop_path>` with the values from step 2.

   ```markdown
   # Handoff test, remote part

   You are the same session, now on the remote host. Do these checks. Record
   PASS or FAIL, with evidence, for each one.

   R1. `hostname` is not <laptop_host>.
   R2. `pwd -P` is not <laptop_path>.
   R3. `git log --oneline -1` shows "e2e: laptop".
   R4. Recall the code word from phase 2, from memory only. Do not read files to find it.
   R5. INFO, not PASS or FAIL: compare your session ID ($CODEX_THREAD_ID or
       $CLAUDE_CODE_SESSION_ID) with the `sid` in .handoff/E2E-STATE.md. Write
       SAME or DIFFERENT, and both IDs. A new ID is allowed: the aim is that the
       remote does its part and the laptop then continues the job.
   R6. Run: hostname > remote.txt && git add remote.txt && git -c user.email=e2e@local -c user.name=e2e commit -m "e2e: remote"
       PASS when the commit exists.

   Commits are allowed. Do not push.
   Then write .handoff/FINISH.md: a table of R1 to R6 with result and evidence, the
   code word from R4, and the line `REMOTE RESULT: PASS` or `REMOTE RESULT: FAIL`.
   Then end your turn. Do not wait for the user.
   ```

5. Start the watcher. It waits until the remote writes `FINISH.md` and is idle.
   Then it brings the session back and resumes it in local tmux with the phase 3
   prompt:

   ```sh
   handoff back self --prompt "Continue the handoff test protocol in REPO/TEST-PROTOCOL.md at phase 3."
   ```

   If your session runs without a sandbox, add the same flag for the local resume,
   so that phase 3 can use ssh without a prompt: `--args "--dangerously-bypass-approvals-and-sandbox"`
   (Codex), or `--args "--permission-mode auto"` (Claude Code).
6. Tell the user in one short line: "Phase 2: I am moving to the remote now.
   Phase 3 resumes in tmux `<name>`." Use the tmux name that `handoff back` printed.
7. Run `handoff out self`. Then end your turn at once, with one short line. Do not
   run other commands after it. The session stops on the laptop a few seconds later.

## Phase 2R: on the remote

`handoff` resumes you on the remote with a prompt that tells you to read
`.handoff/HANDOFF.md`. Do what it says, write `FINISH.md`, and end your turn.

## Phase 3: back on the laptop

The watcher resumes you with the phase 3 prompt. Do these checks:

1. L1. Recall the code word from memory, before you read any file. Then compare it
   with the code word in `.handoff/FINISH.md`. PASS when the two are the same.
2. L2. `hostname` is `laptop_host` from `.handoff/E2E-STATE.md`.
3. L3. `.handoff/FINISH.md` shows `REMOTE RESULT: PASS`.
4. L4. `git log --oneline -2` shows "e2e: remote", then "e2e: laptop".
5. L5. `remote.txt` contains a host name that is not `laptop_host`.
6. L6. `handoff status` does not show your session ID.
7. L7. `handoff mirrors` lists the remote copy of this folder.
8. L8. The part of your transcript from before this phase has no paths of the
   remote. Find the transcript with
   `ls ~/.codex/sessions/*/*/*/rollout-*-SID.jsonl` (Codex) or
   `ls ~/.claude/projects/*/SID.jsonl` (Claude Code). Search only the records
   before the phase 3 prompt for the mirror path that `handoff mirrors` printed:
   the L7 output and your own search command in this phase quote it too. PASS
   when there is no match. Note: `in` maps remote paths back to laptop paths in
   the whole transcript, so the remote output of R2 now shows the laptop path.
   Trust `FINISH.md` for what the remote printed.
9. Write `.handoff/E2E-REPORT.md`:
   - one table with every check from phases 0 to 3: phase, check, result, evidence
   - `handoff` version: `git -C REPO rev-parse --short HEAD`, plus `(modified)` when
     `git -C REPO status --porcelain` is not empty
   - agent CLI versions on both ends, from the phase 0 output
   - the last line: `RESULT: PASS` when all checks pass, or `RESULT: FAIL (n)`
10. Give the user a short summary: the result, each failed check, and the report path.

## Clean up (optional)

The remote copy of the test folder stays as a warm mirror. `handoff prune` removes
it after `HANDOFF_MAX_AGE_DAYS`. To remove it now, run
`handoff prune --max-age 1` on the next day, or delete the path that
`handoff mirrors` shows.
