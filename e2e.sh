#!/bin/bash
# End-to-end test for handoff, against your real remote (HANDOFF_HOST).
# Uses throwaway sessions and repos only; never touches your real sessions or
# handoff state. Makes a few small `claude -p --model haiku` calls.
#
# Covers: plain repo + git worktree reached through a symlink, the same-tree and
# same-repo guards, a LIVE session that hands ITSELF (and another) off from its
# own bash prompt, path rewrite both ways, edit + commit on the remote, the
# laptop-changed guard on `in`, and resume back on the laptop.
#
#   ./e2e.sh                       E2E_DIR=~/handoff-e2e by default
#   E2E_WT_DIR=/Volumes/X/wt ./e2e.sh   put the worktree somewhere else
#   E2E_VIA=shell ./e2e.sh         self-handoff typed as `! handoff out ...` instead of
#                                  asked of Claude in plain words (needs the skill installed)
#   E2E_MODE=auto                  permission mode of the live session (default auto)
# Output: a PASS/FAIL log in $E2E_DIR/logs/e2e-<timestamp>.log
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
H=${HANDOFF_BIN:-$HERE/handoff}
E2E_DIR=${E2E_DIR:-$HOME/handoff-e2e}
REPO=$E2E_DIR/repo
WTREAL=${E2E_WT_DIR:-$E2E_DIR/worktrees}
LINK=$HOME/.handoff-e2e-link            # symlink -> $WTREAL; session B's cwd goes through it
WT=$LINK/wt1                            # logical cwd of session B
export HANDOFF_STATE=$E2E_DIR/state     # separate from your real ~/.handoff
export PATH=$(dirname "$H"):$PATH       # the live session's `handoff` is the one under test
VIA=${E2E_VIA:-agent}
mkdir -p "$E2E_DIR/logs"
LOG=$E2E_DIR/logs/e2e-$(date +%Y%m%d-%H%M%S).log
fails=0
exec > >(tee "$LOG") 2>&1
check() { if ( set +o pipefail; eval "$2" ); then echo "PASS  $1"; else echo "FAIL  $1"; fails=$((fails+1)); fi; }
CONFIG=${HANDOFF_CONFIG:-$HOME/.config/handoff/config}; [ -f "$CONFIG" ] && . "$CONFIG"
HOST=${HANDOFF_HOST:?set HANDOFF_HOST in $CONFIG}
eval "$(sed -n '/^# Tailscale SSH/,/^}/p' "$H")"   # msh: real exit codes over ssh
remote() { msh "$@"; }
rpath() { "$H" _paths "$1" | awk -F' -> ' '{print $2}'; }   # laptop path -> remote path
ask() { claude -p --model haiku --output-format json --resume "$1" "$2" </dev/null | jq -r .result; }
enc() { printf '%s' "$1" | sed 's/[^a-zA-Z0-9]/-/g'; }
remote_clean() {   # no globs: the remote login shell may be zsh, which aborts on no match
  remote "rm -rf $(printf %q "$RREPO") $(printf %q "$RWT") ~/.handoff-e2e-link; find ~/.claude/projects -maxdepth 1 \\( -name $(printf %q "$(enc "$RREPO")*") -o -name $(printf %q "$(enc "$RWT")*") -o -name $(printf %q "$(enc "$RH/.handoff-e2e-link")*") \\) -exec rm -rf {} +"
}
type_in() { remote "tmux send-keys -t $1 -l $(printf %q "$2"); sleep 1; tmux send-keys -t $1 C-m"; }

echo "handoff e2e  $(date -u +%FT%TZ)  host=$HOST"
RH=$(rpath "$HOME"); RREPO=$(rpath "$REPO"); RWT=$(rpath "$WTREAL")
[ -n "$RH" ] || { echo "FAIL  cannot reach $HOST"; exit 1; }
echo "remote home=$RH  repo=$RREPO  worktrees=$RWT"

# --- clean slate (only our own dirs)
remote_clean
remote "mkdir -p ~/.handoff-e2e-link && ln -s /tmp ~/.handoff-e2e-link/wt1"   # stale link from an older run: must be replaced
tmux -L hotest kill-server 2>/dev/null
git -C "$REPO" worktree remove --force "$WTREAL/wt1" 2>/dev/null; rm -rf "$REPO" "$WTREAL" "$LINK" "$HANDOFF_STATE"
mkdir -p "$REPO" "$WTREAL" && ln -s "$WTREAL" "$LINK"
cd "$REPO" && git init -q && echo laptop-v1 > note.txt && git add -A && git -c user.email=t@t -c user.name=t commit -qm init
git worktree add -q "$WTREAL/wt1" -b wt1 && echo wt-laptop-v1 > "$WTREAL/wt1/wt.txt"

# --- sessions: A (repo, live), A2 (repo, transcript only), B (worktree via symlink)
A=$(cd "$REPO" && claude -p --model haiku --output-format json "Read note.txt; reply only its contents." </dev/null | jq -r .session_id)
A2=$(cd "$REPO" && claude -p --model haiku --output-format json "Reply only: ok" </dev/null | jq -r .session_id)
B=$(cd "$WTREAL/wt1" && claude -p --model haiku --output-format json "Read wt.txt; reply only its contents." </dev/null | jq -r .session_id)
echo "A=$A  A2=$A2  B=$B"
tmux -L hotest new-session -d -s live -x 200 -y 50 -c "$REPO" "claude --resume $A --permission-mode ${E2E_MODE:-auto}"
sleep 6; tmux -L hotest send-keys -t live Down; sleep 0.5; tmux -L hotest send-keys -t live C-m   # folder-trust prompt
# B stands in for a session whose recorded cwd is a symlinked path (Claude Code
# records real paths for new sessions; older ones, or tools that cd through
# symlinks, can have logical ones). A registry entry backed by a sleep keeps it "live".
sleep 600 >/dev/null 2>&1 & BPID=$!; FAKE=~/.claude/sessions/$BPID.json
trap 'kill $BPID 2>/dev/null; rm -f "$FAKE"; tmux -L hotest kill-server 2>/dev/null' EXIT
jq -n --argjson pid $BPID --arg s "$B" --arg c "$WT" '{pid:$pid, sessionId:$s, cwd:$c, name:"wt1-symlinked", status:"idle", updatedAt:(now*1000|floor)}' > "$FAKE"
check "B shows live with the symlinked cwd" '"$H" list | grep -q "wt1-symlinked.*$WT"'
for _ in $(seq 1 30); do APID=$(grep -l "\"$A\"" ~/.claude/sessions/*.json 2>/dev/null | head -1 | xargs -I{} jq -r .pid {} 2>/dev/null); [ -n "${APID:-}" ] && kill -0 "$APID" 2>/dev/null && break; sleep 1; done
check "A is live on the laptop (pid ${APID:-none})" '[ -n "${APID:-}" ] && kill -0 "$APID" 2>/dev/null'

# --- guards: A2 shares A's tree, B shares A's repo, while A is live
cd "$HOME"
G=$("$H" out "$A2" 2>&1); grc=$?; echo "guard said: $G"
check "same-tree guard refuses A2 while A is live" '[ $grc -ne 0 ] && [[ "$G" == *"other live sessions"* ]]'
check "guard left nothing on the remote" '! ls "$HANDOFF_STATE/out/" | grep -q .'
G=$("$H" out "$B" 2>&1); grc=$?; echo "guard said: $G"
check "same-repo guard refuses B (other worktree) while A is live" '[ $grc -ne 0 ] && [[ "$G" == *"same repo"* ]]'

# --- A hands itself AND B off from inside A; A must be processed last
sleep 2
if [ "$VIA" = agent ]; then   # plain words; the handoff skill has to do the rest
  tmux -L hotest send-keys -t live -l "I'm heading out. Hand this session and the session wt1-symlinked off to the remote."
else
  tmux -L hotest send-keys -t live -l "!"; sleep 1; tmux -L hotest send-keys -t live -l "$H out $A $B"
fi
sleep 1; tmux -L hotest send-keys -t live C-m
for _ in $(seq 1 90); do [ -f "$HANDOFF_STATE/out/$A" ] && grep -q "running on" "$HANDOFF_STATE/log/$A.log" 2>/dev/null && remote "tmux has-session -t ho-${A:0:8}" && break; sleep 2; done
[ -f "$HANDOFF_STATE/out/$A" ] || { echo "--- live pane"; tmux -L hotest capture-pane -p -S -40 -t live 2>/dev/null; echo "---"; }
if [ "$VIA" = agent ]; then
  check "agent: Claude ran handoff out itself (Bash tool call in A's transcript)" 'jq -r "select(.type==\"assistant\") | .message.content[]? | select(.type==\"tool_use\" and .name==\"Bash\") | .input.command" ~/.claude/projects/$(enc "$REPO")/$A.jsonl 2>/dev/null | grep -q "handoff out"'
fi
check "self-handoff: A recorded as on the remote" '[ -f "$HANDOFF_STATE/out/$A" ]'
check "self-handoff: laptop process for A stopped" '! kill -0 "$APID" 2>/dev/null'
check "self-handoff: A runs on the remote" 'remote "tmux has-session -t ho-${A:0:8}"'
echo "--- self-handoff log"; sed 's/\x1b\[[0-9;]*m//g' "$HANDOFF_STATE/log/$A.log" 2>/dev/null; echo "---"

check "batch: B on the remote too" '[ -f "$HANDOFF_STATE/out/$B" ] && remote "tmux has-session -t ho-${B:0:8}"'
check "laptop process for B stopped" '! kill -0 "${BPID:-0}" 2>/dev/null'
sleep 10
check "Remote Control active for A" 'remote "tmux capture-pane -p -t ho-${A:0:8}" | grep -q "remote-control is active"'
check "Remote Control active for B" 'remote "tmux capture-pane -p -t ho-${B:0:8}" | grep -q "remote-control is active"'
check "B logical path on the remote links to its tree (stale link replaced)" '[ "$(remote "readlink ~/.handoff-e2e-link/wt1")" = "$RWT/wt1" ]'
check "worktree .git points at the remote path" 'remote "cat $(printf %q "$RWT/wt1/.git")" | grep -q "$RREPO/.git/worktrees/wt1"'

# --- work on the remote (stands in for the phone)
type_in "ho-${A:0:8}" "Overwrite note.txt so it contains exactly: mini-v2"
type_in "ho-${B:0:8}" "Append a line wt-mini-v2 to wt.txt, then run: git add -A && git -c user.email=t@t -c user.name=t commit -m from-mini"
for _ in $(seq 1 36); do
  remote "grep -q mini-v2 $(printf %q "$RREPO/note.txt") && git -C $(printf %q "$RWT/wt1") log --oneline | grep -q from-mini" && break; sleep 5
done
check "remote edited note.txt" 'remote "cat $(printf %q "$RREPO/note.txt")" | grep -q mini-v2'
remote "git -C $(printf %q "$RWT/wt1") log --oneline" | grep -q from-mini || { echo "--- B pane"; remote "tmux capture-pane -p -S -60 -t ho-${B:0:8}"; echo "---"; }
check "remote committed in the worktree" 'remote "git -C $(printf %q "$RWT/wt1") log --oneline" | grep -q from-mini'

# --- guard: laptop copy changed while the remote owns it
echo stray > "$REPO/stray.txt"
G=$("$H" in "$A" 2>&1); grc=$?
check "laptop-changed guard refuses in" '[ $grc -ne 0 ] && [[ "$G" == *"changed on the laptop"* ]]'
check "A still on the remote after refusal" '[ -f "$HANDOFF_STATE/out/$A" ] && remote "tmux has-session -t ho-${A:0:8}"'
rm -f "$REPO/stray.txt"

# --- in (all)
"$H" in; rc=$?
check "handoff in exit 0" '[ $rc -eq 0 ]'
check "nothing left on the remote" '"$H" status | grep -q "nothing is on"'
check "no e2e tmux left on the remote" '! remote "tmux ls -F \"#S\" 2>/dev/null" | grep -qE "^ho-(${A:0:8}|${B:0:8})$"'
check "laptop note.txt = mini-v2" 'grep -q mini-v2 "$REPO/note.txt"'
check "laptop worktree has from-mini commit" 'git -C "$WTREAL/wt1" log --oneline | grep -q from-mini'
check "laptop worktree .git points at laptop path" 'grep -q "^gitdir: $REPO/.git/worktrees/wt1" "$WTREAL/wt1/.git"'
check "laptop symlink still a symlink" '[ -L "$LINK" ]'
if [ "$RH" != "$HOME" ]; then
  check "no remote paths left in transcripts" '! grep -q "$RH/" ~/.claude/projects/$(enc "$REPO")/$A.jsonl ~/.claude/projects/$(enc "$WTREAL/wt1")/$B.jsonl'
fi

# --- resume back on the laptop: does it remember the remote turn?
RA=$(cd "$REPO" && ask "$A" "In this conversation, what value did you write to note.txt most recently? Reply with only that value.")
RB=$(cd "$WTREAL/wt1" && ask "$B" "Run git log --oneline -1 and reply with only the commit message.")
echo "A says: $RA"; echo "B says: $RB"
check "A remembers the remote work on the laptop" '[[ "$RA" == *mini-v2* ]]'
check "B sees the remote commit on the laptop" '[[ "$RB" == *from-mini* ]]'

# --- leave nothing behind
tmux -L hotest kill-server 2>/dev/null; kill "$BPID" 2>/dev/null; rm -f "$FAKE"
remote_clean
echo; [ $fails -eq 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL ($fails)"
echo "log: $LOG"
exit $fails
