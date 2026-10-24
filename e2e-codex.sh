#!/bin/bash
# End-to-end test of handoff with the Codex CLI, against your real remote
# (HANDOFF_HOST). Uses throwaway repos and Codex sessions only; never touches your
# real sessions or handoff state. Makes a few small calls with a cheap model.
#
# Covers: `handoff doctor codex`, a LIVE Codex TUI (daemon mode, as you run it)
# that hands ITSELF off through its own shell tool, the same-tree guard, a dry
# run, a non-live session with .handoff/HANDOFF.md that works alone on the remote
# and writes FINISH.md, `handoff wait`, an edit typed into the remote TUI, the
# laptop-changed guard, `handoff in`, path rewrite both ways, and the resumed
# laptop session remembering the remote work.
#
#   ./e2e-codex.sh                      E2E_DIR=~/handoff-e2e-codex by default
#   E2E_MODEL=gpt-5.6-luna              model of the throwaway sessions
#   E2E_LOCAL_ARGS=...                  flags for the laptop TUI (default: bypass approvals
#                                       and sandbox, so `handoff out self` may use ssh)
#   E2E_SKIP_DOCTOR=1                   skip `handoff doctor codex` (the test protocol ran it)
# It adds trust entries for its two repos to ~/.codex/config.toml (laptop and remote)
# and removes them again at the end.
# Output: a PASS/FAIL log in $E2E_DIR/logs/e2e-codex-<timestamp>.log
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
H=${HANDOFF_BIN:-$HERE/handoff}
E2E_DIR=${E2E_DIR:-$HOME/handoff-e2e-codex}
REPO=$E2E_DIR/repo                      # live session A works here
REPO2=$E2E_DIR/repo2                    # session C gets a HANDOFF.md task here
MODEL=${E2E_MODEL:-gpt-5.6-luna}
LOCAL_ARGS=${E2E_LOCAL_ARGS:---dangerously-bypass-approvals-and-sandbox}
export HANDOFF_STATE=$E2E_DIR/state     # separate from your real ~/.handoff
export HANDOFF_MAX_AGE_DAYS=0 HANDOFF_WAIT_POLL=3 HANDOFF_START_WAIT=2
mkdir -p "$E2E_DIR/logs"
LOG=$E2E_DIR/logs/e2e-codex-$(date +%Y%m%d-%H%M%S).log
fails=0
exec > >(tee "$LOG") 2>&1
check() { if ( set +o pipefail; eval "$2" ); then echo "PASS  $1"; else echo "FAIL  $1"; fails=$((fails+1)); fi; }
CONFIG=${HANDOFF_CONFIG:-$HOME/.config/handoff/config}; [ -f "$CONFIG" ] && . "$CONFIG"
export HANDOFF_ROOT=${E2E_ROOT:-"~/handoff-e2e-codex-root"} HANDOFF_MAX_AGE_DAYS=0   # the config file must not win
HOST=${HANDOFF_HOST:?set HANDOFF_HOST in $CONFIG}
eval "$(sed -n '/^# Tailscale SSH/,/^# --- path mapping/p' "$H")"   # msh/mshi: real exit codes over ssh
remote() { msh "$@"; }
eval "$(grep '^sid8() ' "$H")"   # short id, as in tmux names and output
rpath() { "$H" _paths "$1" | awk -F' -> ' '{print $2}'; }   # laptop path -> remote path
# Codex tool commands run in its daemon, not under the TUI: they do not see our
# exported variables. Commands typed for Codex carry them on the command line.
HENV="HANDOFF_STATE=$(printf %q "$HANDOFF_STATE") HANDOFF_ROOT='$HANDOFF_ROOT' HANDOFF_MAX_AGE_DAYS=0"   # quoted: ~ means the remote home
T="tmux -L hoe2ecx"

trust_add() {       # file path...: the folder dialog is skipped only by a saved entry
  local f=$1 p; shift
  for p in "$@"; do grep -qxF "[projects.\"$p\"]" "$f" 2>/dev/null || printf '\n[projects."%s"]\ntrust_level = "trusted"\n' "$p" >> "$f"; done
}
# drops only the table header and its key lines; a comment or blank line after it stays
trust_drop_awk='/^[ \t]*$/ { held = held $0 "\n"; next } /^\[/ { skip = (index($0, a) == 1 || index($0, b) == 1); if (skip) { held = ""; next } } skip && /^[A-Za-z0-9_-]+ *=/ { next } { skip = 0; printf "%s", held; held = ""; print } END { printf "%s", held }'
new_session() {     # cwd prompt -> thread id
  (cd "$1" && codex exec -m "$MODEL" -s read-only --skip-git-repo-check --json "$2" </dev/null 2>/dev/null) \
    | jq -r 'select(.type=="thread.started") | .thread_id' | head -1
}
type_local() { $T send-keys -t "$1" -l "$2"; sleep 0.5; $T send-keys -t "$1" C-m; }
type_remote() { remote "tmux send-keys -t $1 -l $(printf %q "$2"); sleep 0.5; tmux send-keys -t $1 C-m"; }
turn_answer() {     # sid question -> the final reply of the turn that asked it, read from
  # the rollout once the turn completed (the screen wraps and streams; this does not)
  local f ans i
  for i in $(seq 1 180); do
    f=$(ls ~/.codex/sessions/*/*/*/rollout-*-"$1".jsonl 2>/dev/null | head -1)
    ans=$(jq -r --arg q "$2" 'if .type == "response_item" and .payload.type == "message" and .payload.role == "user"
        and ([.payload.content[]?.text // ""] | join(" ") | contains($q)) then "Q"
      elif .type == "event_msg" and .payload.type == "task_complete" then "A\t" + ((.payload.last_agent_message // "") | gsub("\n"; " "))
      else empty end' "$f" 2>/dev/null | awk -F'\t' '$1 == "Q" { f = 1; next } f && $1 == "A" { print $2; exit }')
    [ -n "$ans" ] && { printf '%s' "$ans"; return; }
    sleep 1
  done
}
ask_tui() {         # sid cwd question -> the answer, through a laptop TUI (daemon mode,
  # like `codex resume` after `handoff in`)
  $T kill-session -t ask 2>/dev/null
  $T new-session -d -s ask -x 220 -y 60 -c "$2" "codex resume -C $(printf %q "$2") $LOCAL_ARGS $1 $(printf %q "$3")"
  turn_answer "$1" "$3"
  $T kill-session -t ask 2>/dev/null
}
codex_ids() { printf '%s\n' "${A:-}" "${A2:-}" "${C:-}" | grep .; }
cleanup() {         # only our own dirs, sessions and trust entries
  $T kill-server 2>/dev/null; [ -n "${C:-}" ] && tmux kill-session -t "ho-back-$(sid8 "$C")" 2>/dev/null
  case "$RROOT" in *e2e*) ;; *) echo "FAIL  refusing to clean root $RROOT (no 'e2e' in it)"; exit 1 ;; esac
  local ids; ids=$(codex_ids | xargs)
  remote "for s in $ids; do codex delete --force \$s </dev/null >/dev/null 2>&1; done; rm -rf $(printf %q "$RROOT")
    f=~/.codex/config.toml; [ -f \$f ] && awk -v a=$(printf %q "[projects.\"$RROOT/") -v b=$(printf %q "[projects.\"$RROOT\"]") $(printf %q "$trust_drop_awk") \$f > \$f.tmp && mv \$f.tmp \$f; true"
  for s in $ids; do codex delete --force "$s" </dev/null >/dev/null 2>&1; done
  local f=$HOME/.codex/config.toml
  [ -f "$f" ] && awk -v a="[projects.\"$E2E_DIR/" -v b="[projects.\"$E2E_DIR\"]" "$trust_drop_awk" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

echo "handoff e2e (codex)  $(date -u +%FT%TZ)  host=$HOST  model=$MODEL"
RH=$(rpath "$HOME"); RREPO=$(rpath "$REPO"); RREPO2=$(rpath "$REPO2")
[ -n "$RH" ] || { echo "FAIL  cannot reach $HOST"; exit 1; }
RROOT=${HANDOFF_ROOT/#\~/$RH}
echo "remote home=$RH  root=$RROOT  repo=$RREPO"

# --- preflight: stop early when the setup cannot work
if [ "${E2E_SKIP_DOCTOR:-0}" = 1 ]; then
  echo "SKIP  doctor codex (E2E_SKIP_DOCTOR=1)"
else
  "$H" doctor codex; drc=$?
  check "doctor codex passes" '[ $drc -eq 0 ]'
  [ $drc -eq 0 ] || { echo "RESULT: FAIL (fix the doctor findings first)"; exit 1; }
fi

# --- clean slate
A="" A2="" C=""
cleanup
rm -rf "$REPO" "$REPO2" "$HANDOFF_STATE"; mkdir -p "$REPO" "$REPO2"
cd "$REPO" && git init -q && echo laptop-v1 > note.txt && printf 'big.bin\n' > .gitignore && git add -A && git -c user.email=t@t -c user.name=t commit -qm init
dd if=/dev/zero of=big.bin bs=1024 count=2048 2>/dev/null                   # ignored: must stay on the laptop
cd "$REPO2" && git init -q && echo task > README && git add -A && git -c user.email=t@t -c user.name=t commit -qm init
mkdir -p .handoff && cat > .handoff/HANDOFF.md <<'EOF'
# Task (handoff e2e)
1. Run `hostname` and `pwd`.
2. Create result.txt with two lines: `remote-ok` and the hostname.
3. Commit it locally: git add result.txt && git -c user.email=t@t -c user.name=t commit -m from-remote
4. Write .handoff/FINISH.md as asked.
Commits are allowed. Do not push.
EOF
trust_add "$HOME/.codex/config.toml" "$REPO" "$REPO2"

# --- sessions: A2 (same tree, not live), C (repo2, not live), then A: started as plain
# `codex` (no id in its arguments, as people start it) plus a second window on the same
# thread; `out` has to find and stop both
A2=$(new_session "$REPO" "Reply only: ok")
C=$(new_session "$REPO2" "Read README and reply only its contents.")
QA="Remember the code word KESTREL-3. Read note.txt and reply only its contents."
touch "$E2E_DIR/.mark"
$T new-session -d -s live -x 220 -y 60 -c "$REPO" "codex -m $MODEL $LOCAL_ARGS $(printf %q "$QA")"
A=""
for _ in $(seq 1 60); do
  for f in $(find ~/.codex/sessions -name 'rollout-*.jsonl' -newer "$E2E_DIR/.mark" 2>/dev/null); do
    [ "$(head -1 "$f" | jq -r .payload.cwd)" = "$REPO" ] && A=$(head -1 "$f" | jq -r .payload.id)
  done
  [ -n "$A" ] && break; sleep 1
done
echo "A=$A  A2=$A2  C=$C"
check "three throwaway sessions created" '[ -n "$A" ] && [ -n "$A2" ] && [ -n "$C" ]'
RA0=$(turn_answer "$A" "$QA"); echo "A first said: $RA0"
$T new-session -d -s live2 -x 220 -y 60 -c "$REPO" "codex resume -C $(printf %q "$REPO") $LOCAL_ARGS $A"
for _ in $(seq 1 60); do [ "$("$H" list 2>/dev/null | grep -c "^  $(sid8 "$A") *codex .*tui")" -ge 2 ] && break; sleep 1; done
check "A shows live in both windows, the plain one too" '[ "$("$H" list | grep -c "^  $(sid8 "$A") *codex .*tui")" -ge 2 ]'
win_pid() { local p; p=$($T list-panes -t "$1" -F '#{pane_pid}'); case "$(ps -o comm= -p "$p")" in *codex) echo "$p" ;; *) pgrep -P "$p" | head -1 ;; esac; }
APID=$(win_pid live); APID2=$(win_pid live2); echo "A windows: $APID $APID2"
AX=$(ls ~/.codex/sessions/*/*/*/rollout-*-"$A".jsonl); AINODE=$(stat -f %i "$AX" 2>/dev/null || stat -c %i "$AX")

# --- guards and dry run
cd "$HOME"
G=$("$H" out "$A2" 2>&1); grc=$?; echo "guard said: $G"
check "same-tree guard refuses A2 while A is live" '[ $grc -ne 0 ] && [[ "$G" == *"other live sessions"* ]]'
D=$("$H" out "$A2" --dry-run --force 2>&1); echo "$D" | sed -n '1,8p'
check "dry run reports the transfer" '[[ "$D" == *"would send"* ]] && [[ "$D" == *"dry run"* ]]'
check "dry run left nothing on the remote" '! ls "$HANDOFF_STATE/out/" | grep -q . && ! remote "test -e $(printf %q "$RREPO/note.txt")"'

# --- A hands itself off through its own shell tool
type_local live "Run this exact shell command once, then end your turn with one short line: $HENV $H out self"
for _ in $(seq 1 240); do [ -f "$HANDOFF_STATE/out/$A" ] && grep -q "running on" "$HANDOFF_STATE/log/$A.log" 2>/dev/null && break; sleep 1; done
[ -f "$HANDOFF_STATE/out/$A" ] || { echo "--- live pane"; $T capture-pane -p -S -60 -t live 2>/dev/null; echo "---"; }
echo "--- self-handoff log"; sed 's/\x1b\[[0-9;]*m//g' "$HANDOFF_STATE/log/$A.log" 2>/dev/null; echo "---"
check "self-handoff: A recorded as on the remote" '[ -f "$HANDOFF_STATE/out/$A" ]'
check "self-handoff: both laptop windows of A stopped" '[ -n "$APID" ] && [ -n "$APID2" ] && ! kill -0 "$APID" 2>/dev/null && ! kill -0 "$APID2" 2>/dev/null'
check "self-handoff: A runs on the remote" 'remote "tmux has-session -t ho-$(sid8 "$A")"'
check "self-handoff: the turn ended before the copy" 'remote "ls ~/.codex/sessions/*/*/*/rollout-*-$A.jsonl" >/dev/null && [ "$(remote "cat ~/.codex/sessions/*/*/*/rollout-*-$A.jsonl" | jq -r "select(.type==\"event_msg\") | .payload.type | select(test(\"^(task_started|task_complete|turn_aborted)$\"))" | tail -1)" != task_started ]'
check "remote runs codex without the daemon" 'remote "pgrep -af \"[c]odex resume --no-daemon.* $A\"" >/dev/null'
check "remote folder trusted in ~/.codex/config.toml" 'remote "grep -qxF $(printf %q "[projects.\"$RREPO\"]") ~/.codex/config.toml"'
check "ignored big.bin not sent" '! remote "test -e $(printf %q "$RREPO/big.bin")"'
check "mirror stamped" '"$H" mirrors | grep -q "$RREPO"'

# --- C: not live, with a task; works alone and writes FINISH.md
"$H" out "$C"; orc=$?
check "out C exit 0" '[ $orc -eq 0 ]'
"$H" wait "$C" --timeout 300; wrc=$?
check "wait C returns once FINISH.md is written and C is idle" '[ $wrc -eq 0 ]'
check "C wrote result.txt on the remote" 'remote "head -1 $(printf %q "$RREPO2/result.txt")" | grep -qx remote-ok'
check "C committed on the remote" 'remote "git -C $(printf %q "$RREPO2") log --oneline" | grep -q from-remote'
check "status flags FINISH.md" '"$H" status | grep "$(sid8 "$C")" | grep -q "FINISH.md"'
QC="From memory, without running commands: what was the first line you wrote to result.txt? Reply only that line."
# a bogus TMUX, as a Codex daemon started inside tmux passes on: back must ignore it
TMUX=/tmp/handoff-e2e-no-such-socket,1,0 "$H" back "$C" --timeout 300 --args "$LOCAL_ARGS" --prompt "$QC"
for _ in $(seq 1 120); do tmux has-session -t "ho-back-$(sid8 "$C")" 2>/dev/null && break; sleep 1; done
echo "--- back log"; sed 's/\x1b\[[0-9;]*m//g' "$HANDOFF_STATE/log/back-$C.log" 2>/dev/null; echo "---"
check "back brought C home and printed its FINISH.md" '[ ! -e "$HANDOFF_STATE/out/$C" ] && grep -q "FINISH.md:" "$HANDOFF_STATE/log/back-$C.log"'
check "back resumed C here in tmux ho-back" 'tmux has-session -t "ho-back-$(sid8 "$C")"'
RC=$(turn_answer "$C" "$QC"); echo "C says: $RC"
check "C remembers the remote task" '[[ "$RC" == *remote-ok* ]]'
tmux kill-session -t "ho-back-$(sid8 "$C")" 2>/dev/null

# --- work typed into the remote TUI (stands in for you on the remote)
type_remote "ho-$(sid8 "$A")" "Overwrite note.txt so it contains exactly: mini-v2"
for _ in $(seq 1 90); do remote "grep -q mini-v2 $(printf %q "$RREPO/note.txt")" && break; sleep 2; done
remote "grep -q mini-v2 $(printf %q "$RREPO/note.txt")" || { echo "--- A remote pane"; remote "tmux capture-pane -p -S -60 -t ho-$(sid8 "$A")"; echo "---"; }
check "remote edited note.txt" 'remote "cat $(printf %q "$RREPO/note.txt")" | grep -q mini-v2'
check "wait does not count A as done without FINISH.md" '! "$H" wait "$A" --timeout 1 >/dev/null 2>&1'

# --- guard: laptop copy changed while the remote owns it
echo stray > "$REPO/stray.txt"
G=$("$H" in "$A" 2>&1); grc=$?
check "laptop-changed guard refuses in" '[ $grc -ne 0 ] && [[ "$G" == *"changed on the laptop"* ]]'
check "A still on the remote after refusal" '[ -f "$HANDOFF_STATE/out/$A" ] && remote "tmux has-session -t ho-$(sid8 "$A")"'
rm -f "$REPO/stray.txt"

# --- in (all); the laptop daemon may still hold A open: in must extend the file in place
ATXLINES=$(. "$HANDOFF_STATE/out/$A"; echo "$TXLINES"); ATXSUM=$(. "$HANDOFF_STATE/out/$A"; echo "$TXSUM")
echo "laptop daemon holds A at in: $([ -e ~/.codex/thread-writer-locks/"$A".lock ] && echo yes || echo no)"
I=$("$H" in 2>&1); rc=$?; echo "$I"
check "handoff in exit 0" '[ $rc -eq 0 ]'
check "in printed the codex resume command" '[[ "$I" == *"codex resume $A"* ]]'
check "nothing left on the remote" '"$H" status | grep -q "nothing is on"'
check "no e2e tmux left on the remote" '! remote "tmux ls -F \"#S\" 2>/dev/null" | grep -qE "^ho-($(sid8 "$A")|$(sid8 "$C"))$"'
check "remote rollouts deleted" '! remote "ls ~/.codex/sessions/*/*/*/ 2>/dev/null" | grep -qE "$A|$C"'
check "laptop note.txt = mini-v2" 'grep -q mini-v2 "$REPO/note.txt"'
check "laptop repo2 has result.txt and the from-remote commit" 'grep -qx remote-ok "$REPO2/result.txt" && git -C "$REPO2" log --oneline | grep -q from-remote'
check "ignored big.bin still on the laptop" '[ -f "$REPO/big.bin" ]'
check "A rollout is the same file (inode) after in" '[ "$(stat -f %i "$AX" 2>/dev/null || stat -c %i "$AX")" = "$AINODE" ]'
check "A rollout keeps the laptop lines byte for byte" '[ "$(head -n "$ATXLINES" "$AX" | shasum | cut -c1-16)" = "$ATXSUM" ]'
AX=$(ls ~/.codex/sessions/*/*/*/rollout-*-"$A".jsonl 2>/dev/null); CX=$(ls ~/.codex/sessions/*/*/*/rollout-*-"$C".jsonl 2>/dev/null)
check "laptop rollouts are valid JSON lines" 'jq -e . "$AX" "$CX" >/dev/null'
check "no root paths left in rollouts" '! grep -q "$RROOT/" "$AX" "$CX"'
if [ "$RH" != "$HOME" ]; then
  check "no remote home paths left in rollouts" '! grep -q "$RH/" "$AX" "$CX"'
fi

# --- resume back on the laptop (through the daemon, as `codex resume` does)
RA=$(ask_tui "$A" "$REPO" "From memory, without running commands: what is the code word, and what did you write to note.txt most recently? Reply as WORD VALUE.")
echo "A says: $RA"
check "A remembers the laptop turn and the remote work" '[[ "$RA" == *KESTREL-3* ]] && [[ "$RA" == *mini-v2* ]]'
check "the new laptop turn landed in the rollout file on disk" '[ -n "$RA" ]'   # turn_answer reads the file at the path

# --- leave nothing behind
cleanup
check "no e2e trust entries left on the laptop" '! grep -qF "[projects.\"$E2E_DIR" ~/.codex/config.toml'
check "no e2e root left on the remote" '! remote "test -e $(printf %q "$RROOT")"'
echo; [ $fails -eq 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL ($fails)"
echo "log: $LOG"
exit $fails
