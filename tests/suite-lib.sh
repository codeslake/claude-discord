# The acceptance suite's shared preamble, sourced by test-claude-discord.sh (core) and test-install.sh: the sandbox HOME,
# the stubs (claude, curl, sleep, jq, fake-worker), the lint and manifest checks, the stand-in repo and the first setup.
# Sourced, never run: it reads the caller's $1 (the wrapper's path) and a failure exits the caller.
set -euo pipefail
# claude-discord and its hooks read CLAUDE_* and DISCORD_* from the caller
# (launcher, process wrapper, state dir, refresh child marker, project dir).
# Clear the whole namespace first: a bot session running this suite would
# otherwise point refresh at its own state dir, and a shell that wraps claude
# would turn PLAIN into LAUNCHER. The suite sets the ones it needs below.
for v in "${!CLAUDE_@}" "${!DISCORD_@}"; do unset "$v"; done
# No backend starts by itself here (setup, the TUI and a manager's hooks would each start a keeper): the blocks that test
# those starts unset this for the one call.
export CLAUDE_DISCORD_NO_AUTOSTART=1
S=${1:?script path}; S=$(cd "$(dirname "$S")" && pwd)/$(basename "$S")   # absolute: the test cd-s into a throwaway project
D=$(cd "$(dirname "$S")/.." && pwd -P)   # repo root = plugin root (bin/claude-discord); -P matches the hooks' plugin_root

CMD_PROMPT='h="$CLAUDE_PROJECT_DIR/.claude/discord-agents/hooks/turn/on-prompt"; [ ! -x "$h" ] || "$h"'
CMD_REPLY='h="$CLAUDE_PROJECT_DIR/.claude/discord-agents/hooks/turn/on-reply"; [ ! -x "$h" ] || "$h"'
CMD_STOP='h="$CLAUDE_PROJECT_DIR/.claude/discord-agents/hooks/turn/on-stop"; [ ! -x "$h" ] || "$h"'
CMD_SESSION='h="$CLAUDE_PROJECT_DIR/.claude/discord-agents/hooks/turn/on-session-start"; [ ! -x "$h" ] || "$h"'
CMD_COMPACT_OLD='h="$CLAUDE_PROJECT_DIR/.claude/discord-agents/hooks/turn/on-compact"; [ ! -x "$h" ] || "$h"'   # an earlier version's entry
CMD_TGUARD='h="$CLAUDE_PROJECT_DIR/.claude/discord-agents/hooks/peers/thread-guard"; [ ! -x "$h" ] || "$h"'
CMD_GUARD='h="$CLAUDE_PROJECT_DIR/.claude/discord-agents/hooks/peers/mention-guard"; [ ! -x "$h" ] || "$h"'
CMD_CHECKIN='h="$CLAUDE_PROJECT_DIR/.claude/discord-agents/hooks/peers/checkin"; [ ! -x "$h" ] || "$h"'
CMD_GATE='h="$CLAUDE_PROJECT_DIR/.claude/discord-agents/hooks/peers/edit-gate"; [ ! -x "$h" ] || "$h"'
CMD_ARC='h="$CLAUDE_PROJECT_DIR/.claude/discord-agents/hooks/autoresearchclaw/on-start"; [ ! -x "$h" ] || "$h"'
# Adds to settings file $1 (created when absent) every entry an earlier release registered, the thread-guard one under both matchers it used.
declare -A PLANTED=()   # input JSON -> the same with the old entries planted: the jq below is the same for every call, so one run per distinct input
plant_old() {
  local f=$1 base='{}' out
  [ ! -s "$f" ] || base=$(<"$f")
  mkdir -p "$(dirname "$f")"
  if [ -z "${PLANTED[$base]+set}" ]; then
  out=$(printf '%s' "$base" | jq --arg p "$CMD_PROMPT" --arg r "$CMD_REPLY" --arg st "$CMD_STOP" --arg ss "$CMD_SESSION" --arg co "$CMD_COMPACT_OLD" --arg t "$CMD_TGUARD" --arg g "$CMD_GUARD" --arg c "$CMD_CHECKIN" --arg e "$CMD_GATE" --arg a "$CMD_ARC" '
    .hooks.UserPromptSubmit += [{hooks: [{type: "command", command: $p}]}]
    | .hooks.Stop += [{hooks: [{type: "command", command: $st}]}]
    | .hooks.SessionStart += [{matcher: "startup|resume|compact|clear", hooks: [{type: "command", command: $ss}]}, {matcher: "compact|clear", hooks: [{type: "command", command: $co}]}, {matcher: "startup|resume|compact|clear", hooks: [{type: "command", command: $a}]}]
    | .hooks.PostToolUse += [{matcher: "mcp__plugin_discord_discord__reply", hooks: [{type: "command", command: $r}]}, {matcher: "mcp__plugin_discord_discord__reply", hooks: [{type: "command", command: $c}]}]
    | .hooks.PreToolUse += [{matcher: "mcp__plugin_discord_discord__reply|mcp__plugin_discord_discord__edit_message", hooks: [{type: "command", command: $t}]}, {matcher: "mcp__plugin_discord_discord__reply", hooks: [{type: "command", command: $t}]}, {matcher: "mcp__plugin_discord_discord__reply", hooks: [{type: "command", command: $g}]}, {matcher: "Edit|Write|MultiEdit", hooks: [{type: "command", command: $e}]}]') || return 0   # not JSON: the file is left as it is
  PLANTED[$base]=$out
  fi
  printf '%s\n' "${PLANTED[$base]}" > "$f"
}
# The test's own waits (~600 short naps). A /bin/sleep for each is a fork and an exec on top of the nap (~1 ms, ~0.6 s a
# run), so this shell asks one helper instead: a perl started once, as a coprocess, that sleeps what a line on its stdin
# says and answers with a line. The read that waits for the answer has no timeout. Not `read -t` on a pipe the shell
# holds open: when the process is descheduled between bash's alarm check and read(2), the alarm fires first and the read
# never returns (bash 5.1; measured 2026-10-11, 0.01 s naps on one contended CPU hung 3 of 3 loops, /bin/sleep 0 of 3).
# Anywhere but in this shell (bash keeps a coprocess's descriptors out of a subshell, and they are close-on-exec), or with
# the helper gone, a nap is /bin/sleep, past the sleep stub. The helper is started here, before HOME is the sandbox (it
# is none of the sandbox's processes), and disowned (a bare `wait` must not wait for it); it ends with its stdin, which
# is this shell's exit, and looks once a second whether this shell is still its parent.
coproc NAPPER { exec perl -e '$| = 1; my $pp = getppid(); my $rin = ""; vec($rin, 0, 1) = 1;
  while (1) { if (select(my $r = $rin, undef, undef, 1)) { defined(my $l = <STDIN>) or exit 0; select(undef, undef, undef, $l + 0); print "\n" } elsif (getppid() != $pp) { exit 0 } }' 2>/dev/null; }
NAP_PID=$NAPPER_PID NAP_SH=$BASHPID; disown "$NAP_PID"
nap() {
  if [ "$BASHPID" = "$NAP_SH" ] && kill -0 "$NAP_PID" 2>/dev/null && printf '%s\n' "$1" >&"${NAPPER[1]}" && IFS= read -r _ <&"${NAPPER[0]}"; then return 0; fi
  /bin/sleep "$1"
}
echo() { case ${1-} in ok:*) LAST_OK=$1;; esac; builtin echo "$@"; }   # the last ok: line, which the TERM trap names
wait_for_file() {  # $1 = path; up to 2s in 0.002s steps, for an async write to land
  local n=0
  while [ ! -s "$1" ] && [ "$n" -lt 1000 ]; do nap 0.002; n=$((n+1)); done
}

# grep -q without a process: a spawn costs ~2.7 ms here and the suite makes ~500 of them. It answers the plain cases itself, a
# literal pattern (-F or not, -x, a leading ^ or trailing $ on a literal) on stdin or in one readable file, and hands every
# other call (any other flag, a regex, several files, a missing file) to the real grep untouched.
grep() {
  local flags="" pat file="" data="" l need hay nl=$'\n' bol=0 eol=0
  local -a args=("$@")
  while [ $# -gt 0 ]; do
    case $1 in
      --) shift; break;;
      -[qFxz]*) case ${1#-} in *[!qFxz]*) command grep "${args[@]}"; return;; esac; flags+=${1#-}; shift;;
      -*) command grep "${args[@]}"; return;;
      *) break;;
    esac
  done
  case $flags in *q*) ;; *) command grep "${args[@]}"; return;; esac
  if [ $# -lt 1 ] || [ $# -gt 2 ]; then command grep "${args[@]}"; return; fi
  pat=$1; file=${2:-}
  case $pat in ''|*"$nl"*) command grep "${args[@]}"; return;; esac
  case $flags in
    *z*) # -qzxF on one file (a /proc environ): a NUL-separated record equal to the pattern
      case $flags in *F*x*|*x*F*) ;; *) command grep "${args[@]}"; return;; esac
      { [ -n "$file" ] && [ -r "$file" ]; } || { command grep "${args[@]}"; return; }
      while IFS= read -rd '' data; do [ "$data" != "$pat" ] || return 0; done < "$file"
      [ "$data" = "$pat" ]; return ;;
  esac
  case $flags in *x*) bol=1; eol=1;; esac
  case $flags in
    *F*) ;;
    *) case $pat in \^*) bol=1; pat=${pat#^};; esac
       case $pat in *'$') eol=1; pat=${pat%?};; esac
       case $pat in ''|*[\\.\[*^$]*) command grep "${args[@]}"; return;; esac ;;
  esac
  # Read in chunks of a fixed size (-N): bash reads a pipe (a here-string) a byte per syscall to find a delimiter, but not
  # for -N; a NUL byte is dropped (text only here).
  if [ -n "$file" ]; then
    if [ ! -e "$file" ] && [ ! -L "$file" ]; then printf 'grep: %s: No such file or directory\n' "$file" >&2; return 2; fi
    { [ -f "$file" ] && [ -r "$file" ]; } || { command grep "${args[@]}"; return; }
    while IFS= read -r -N 65536 l; do data+=$l; done < "$file"; data+=$l
  else
    while IFS= read -r -N 65536 l; do data+=$l; done; data+=$l
  fi
  need=$pat; hay=$nl$data$nl
  [ $bol = 0 ] || need=$nl$need
  [ $eol = 0 ] || need=$need$nl
  [[ $hay == *"$need"* ]]
}

bash -n "$S"
# macOS runs the wrapper under /bin/bash 3.2, which this Linux suite never does:
# refuse the bash 4+ constructs that would only fail there, in everything a Mac runs. A code line that can
# never run on macOS ends in the comment `# bash4-ok: <why>` (no quote in <why>: a marker with a quote after
# it may sit inside a string); the word anywhere else exempts nothing, and a comment line is never code.
# Constructs: ${x,,} ${x^^} (with a pattern too, on $1 $@ $*, and through ${!ref,,}), mapfile/readarray/coproc
# (in $( ) and before a < too), declare/local/typeset -A or -n, [[ -v, ${a[-1]}, ;& and ;;&, ${x@Q}-style
# transforms, wait -n, |& and &>>.
bash4_lint() {
  grep -nHE '\$\{!?([A-Za-z_][A-Za-z_0-9]*(\[[^]]*\])?|[0-9]+|[@*])(,,?|\^\^?)[^}]*\}|(^|[;&|(`[:space:]])(mapfile|readarray|coproc)([[:space:]<]|$)|(declare|local|typeset)[[:space:]]+-[a-zA-Z]*[An]|\[\[[[:space:]]+-v[[:space:]]|\$\{[A-Za-z_][A-Za-z_0-9]*\[-[0-9]|;;?&([^&]|$)|\$\{[^}]*@[A-Za-z]\}|(^|[;&|[:space:]])wait[[:space:]]+-n|\|&|&>>' "$@" |
    grep -vE '^[^:]*:[0-9]+:[[:space:]]*#|^[^:]*:[0-9]+:[[:space:]]*[^#[:space:]].*[[:space:]]# bash4-ok: [^"'"'"'`]*$'
}
# The lint itself: every construct is caught, a trailing marker exempts its line, the bare word does not.
LF=$(mktemp); trap 'rm -f "$LF"' EXIT
cat > "$LF" <<'EOF'
a=${x,,}
a=${x^^[a-z]}
a=${1,,}
a=${@^^}
mapfile -t a < f
local -n ref=x
declare -A m
[[ -v x ]] && :
a=${arr[-1]}
case $x in a) : ;& b) : ;;& esac
a=${x@Q}
wait -n
cmd |& cat
cmd &>> log
a=$(mapfile -t x < f)
readarray<f
a=${!ref,,}
echo "x # bash4-ok: y" ${a,,}
echo bash4-ok ${y,,}
z=${x,,}   # bash4-ok: Linux-only path
# a comment with ${x,,} and bash4-ok
EOF
[ "$(bash4_lint "$LF" | wc -l | tr -d ' ')" = 19 ] || { echo "FAIL: the bash 4 lint must flag each of the 19 code lines and exempt only the trailing marker: $(bash4_lint "$LF")"; exit 1; }
rm -f "$LF"; trap - EXIT
if bash4_lint "$S" "$D"/bin/lib/*.sh "$D/shim/claude-discord" "$D"/hooks/*/* "$D"/tools/* "$D/monitor/monitor.sh"; then
  echo "FAIL: bash 4+ construct in the wrapper, its bin/lib, shim, hooks, tools or monitor (macOS /bin/bash is 3.2)"; exit 1
fi
# 1.15.0: the wrapper sources bin/lib/*.sh on demand; each is parsed on the Mac too.
for f in "$D"/bin/lib/*.sh; do bash -n "$f"; done
# A lib is sourced, never run: no shebang and no execute bit, or `bin/lib/x.sh` run by hand defines its functions with an
# empty $1 and exits 0 saying nothing.
for f in "$D"/bin/lib/*.sh; do
  [ ! -x "$f" ] && [ "$(head -c 2 "$f")" != "#!" ] || { echo "FAIL: $f is a sourced lib: no shebang, no execute bit"; exit 1; }
done
bash -n "$D/hooks/lib/discord.sh"
bash -n "$D/hooks/lib/old-hooks.sh"
bash -n "$D/hooks/turn/on-prompt"
bash -n "$D/hooks/turn/on-reply"
bash -n "$D/hooks/turn/on-stop"
bash -n "$D/hooks/turn/on-session-start"
bash -n "$D/hooks/peers/thread-guard"
bash -n "$D/hooks/peers/edit-gate"
bash -n "$D/tools/thread"
bash -n "$D/tools/local-bots"
bash -n "$D/hooks/autoresearchclaw/on-start"
bash -n "$D/tools/arc-events"
bash -n "$D/shim/claude-discord"
bash -n "$D/monitor/monitor.sh"
# The monitor writes nothing to /tmp, and bash 3.2 backs every here-document and here-string with a temp file there.
! command grep -n '<<' "$D/monitor/monitor.sh" || { echo "FAIL: no here-document or here-string in monitor/monitor.sh (bash 3.2 writes them to TMPDIR)"; exit 1; }
# The plugin manifest and hooks.json: valid JSON, name discord-agents (a "claude-" name is reserved), and every
# hook command names a script that exists in the repo and is executable.
jq -e '.name == "discord-agents" and (.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))' "$D/.claude-plugin/plugin.json" >/dev/null || { echo "FAIL: plugin.json needs name discord-agents and a semver version"; exit 1; }
cmds=$(jq -r '.hooks[][] .hooks[] .command' "$D/hooks/hooks.json") || { echo "FAIL: hooks.json is not valid"; exit 1; }
[ "$(printf '%s\n' "$cmds" | wc -l | tr -d ' ')" = 7 ] || { echo "FAIL: hooks.json must register the seven hooks: $cmds"; exit 1; }
# One process per reply on each side: on-reply alone after it (checkin merged into it), thread-guard alone before it
# (mention-guard merged into it).
[ "$(jq -c '[.hooks.PostToolUse[] | select(.matcher as $m | "mcp__plugin_discord_discord__reply" | test("^(" + $m + ")$")) | .hooks[].command],
  [.hooks.PreToolUse[] | select(.matcher as $m | "mcp__plugin_discord_discord__reply" | test("^(" + $m + ")$")) | .hooks[].command]' "$D/hooks/hooks.json" | tr '\n' ' ')" = '["\"${CLAUDE_PLUGIN_ROOT}/hooks/turn/on-reply\""] ["\"${CLAUDE_PLUGIN_ROOT}/hooks/peers/thread-guard\""] ' ] ||
  { echo "FAIL: one process per reply: hooks.json runs on-reply alone after a reply and thread-guard alone before it"; exit 1; }
while IFS= read -r c; do
  # quoted, so a plugin root with a space in its path still runs
  case $c in '"${CLAUDE_PLUGIN_ROOT}/hooks/'*'"') ;; *) echo "FAIL: hook command must be \"\${CLAUDE_PLUGIN_ROOT}/hooks/...\" (quoted): $c"; exit 1;; esac
  f=${c#'"${CLAUDE_PLUGIN_ROOT}/'}; f=$D/${f%'"'}
  [ -x "$f" ] || { echo "FAIL: hooks.json names a missing or non-executable $f"; exit 1; }
done <<<"$cmds"
# The README's Hooks section: the seven-column table in every purpose group and the Mods section, and a row for every
# script hooks.json registers.
hdr='| Event | Matcher | Script | Purpose (why, what, when) | Exact effect | Context cost (measured) | Who |'
[ "$(command grep -cxF "$hdr" "$D/README.md")" = 6 ] && command grep -qx '### Mods' "$D/README.md" || { echo "FAIL: the README's hooks are one seven-column table per purpose group, and a Mods section"; exit 1; }
while IFS= read -r c; do
  f=${c#'"${CLAUDE_PLUGIN_ROOT}/hooks/'}; f=${f%'"'}
  command grep -qF "| \`$f\` | Why: " "$D/README.md" || { echo "FAIL: the README's hook table has no row for $f"; exit 1; }
done <<<"$cmds"
jq -e '.hooks.PreToolUse[] | select(.matcher == "mcp__plugin_discord_discord__reply|mcp__plugin_discord_discord__edit_message") | .hooks[] | select(.command | endswith("peers/thread-guard\""))' "$D/hooks/hooks.json" >/dev/null || { echo "FAIL: thread-guard must cover reply and edit_message"; exit 1; }
! jq -e '.hooks.PostToolUse[] | select(.matcher | test("react"))' "$D/hooks/hooks.json" >/dev/null || { echo "FAIL: no hook may run after a react (the Stop hook reacts by itself)"; exit 1; }
echo "ok: plugin.json and hooks.json are valid and every hook command exists"
[ "$(grep -c "if (msg.author.bot) return" "$D/bin/lib/patch.sh")" = 1 ] || { echo "FAIL: server.ts patch block must appear exactly once in bin/lib/patch.sh (patch_official lives there since 1.15.0)"; exit 1; }
# KILL_AT_EXIT: pids this test started (fake workers), so a failed assertion
# cannot leave one running.
KILL_AT_EXIT=""
# The sandbox, a throwaway HOME. The suite makes and removes tens of thousands of small files there (the jq cache, the
# clones, the compat rebuilds), which a container's overlay root makes slow: on tmpfs the run is ~0.9 s shorter (measured
# 2026-10-14 in lmd79's container, three interleaved runs each). So /dev/shm when it is a tmpfs with room (256 MB free;
# the sandbox peaks at ~16 MB) on which a script runs (not noexec), else /tmp as before. Nothing reads the place by name.
SBX=/tmp/claude-discord-test-$$
if [ -d /dev/shm ] && [ -w /dev/shm ]; then
  sbt="" sba=0 sbs=0; read -r sbt sba sbs < <(stat -f -c '%T %a %S' /dev/shm 2>/dev/null) || :
  case $sba$sbs in *[!0-9]*) sba=0;; esac
  if [ "$sbt" = tmpfs ] && [ $(( sba * sbs / 1048576 )) -ge 256 ]; then
    sbd=/dev/shm/claude-discord-test-$$
    if mkdir -p "$sbd" && printf '#!/bin/sh\n' > "$sbd/x" && chmod +x "$sbd/x" && "$sbd/x" 2>/dev/null; then SBX=$sbd; rm -f "$sbd/x"; else rm -rf "$sbd"; fi
  fi
fi
export HOME=$SBX; mkdir -p "$HOME"
# sandbox_pids: everything running from the sandbox, detached or not: its path in argv, or (Linux) the sandbox as the HOME it
# inherited (an orphaned `/bin/sleep 30` names no path of the suite's). Never `pgrep -f`, whose own argv matches. The ps and
# the grep run apart from each other and from the final filter, which drops this shell and the subshells running this.
sandbox_pids() {
  local me=$BASHPID a c="" t
  a=$(ps -eo pid=,args= | SB=$HOME awk 'index($0, ENVIRON["SB"] "/") { print $1 }') || :
  if [ -d /proc/self ]; then
    c=$(echo "$BASHPID"; exec grep -lszE "^HOME=$HOME(/|\$)" /proc/[0-9]*/environ) || :
    c=$(printf '%s\n' "$c" | awk 'NR == 1 { g = $1; next } { split($0, f, "/"); if (f[3] != g) print f[3] }')   # the first line is the grep's own pid
  fi
  t=$(ps -eo pid=,ppid=) || :
  # Drop this process and its ancestors (the suite and the subshells running this): they carry the HOME too.
  { printf '%s\n' "$t"; printf '%s\n%s\n' "$a" "$c"; } | awk -v me="$me" 'NF == 2 { pp[$1] = $2; next } NF == 1 { c[$1] = 1 }
    END { for (q = me; q > 1; q = pp[q]) s[q] = 1; for (q in c) if (!(q in s) && q != 1) print q }'
}
# reap_sandbox: TERM everything sandbox_pids names, wait for it to go (looked at every 0.02 s), KILL what is left after 2 s. Runs on every exit path
# (the EXIT trap: a failing case, the watchdog's TERM, the end), so a keeper or monitor a case detached and did not stop
# cannot outlive the HOME it reads (one did, 20:04Z-21:41Z).
reap_sandbox() {
  local pids n sig=TERM
  for n in $(seq 125); do
    pids=$(sandbox_pids); [ -n "$pids" ] || return 0
    [ "$n" -le 100 ] || sig=KILL
    kill -$sig $pids 2>/dev/null || :; nap 0.02
  done
}
trap 'kill $KILL_AT_EXIT 2>/dev/null || :; reap_sandbox; rm -rf "$SBX"' EXIT
# Watchdog: a hang fails the suite, saying where, instead of blocking its caller. After $1 s it lists every process under
# the shell that armed it (a hung command, a nap too: it is /bin/sleep) and kills that shell and all of them at once: a
# grandchild in a $(...) holds the capture pipe open, so killing the children alone left the shell blocked. The shell's
# TERM trap then names the block (the last ok: line) and the function stack. The watchdog's own trap takes its sleep down,
# and it says nothing once its shell is gone (SIGKILLed, the pid free for reuse): then it is no longer that shell's child.
arm_watchdog() {
  local target=$BASHPID
  ( trap 'kill $(jobs -p) 2>/dev/null; exit' TERM; /bin/sleep "$1" & wait $! || exit 0
    me=$BASHPID; [ "$(ps -o ppid= -p $me)" -eq "$target" ] 2>/dev/null || exit 0   # $me: inside $(...) $BASHPID is that subshell
    kids=$(ps -eo pid=,ppid=,args= | awk -v p="$target" -v me="$me" '{ pp[$1] = $2; a[$1] = $0 }
      END { d[p] = 1; do { n = 0; for (q in pp) if (!(q in d) && q != me && (pp[q] in d)) { d[q] = 1; n = 1 } } while (n)
            for (q in d) if (q != p) print a[q] }') || :
    echo "FAIL: still running after $1 s (budget 40 s), in the block after the last ok: line${kids:+; the processes under it:$'\n'$kids}"
    kill "$target" $(printf '%s\n' "$kids" | awk '{print $1}') 2>/dev/null ) & KILL_AT_EXIT="$KILL_AT_EXIT $!"; disown $!   # disowned: a bare `wait` below must not wait for it
  trap 'echo "FAIL: stopped by SIGTERM (the watchdog, or a kill from outside) in the block after \"${LAST_OK:-the start}\"${FUNCNAME[0]+, in ${FUNCNAME[*]}, called from line(s) ${BASH_LINENO[*]}}"; exit 1' TERM
}
arm_watchdog 60
# The watchdog itself, armed at 0.1 s in a subshell over a hung grandchild inside a $(...) (the shape of a hook hung under
# a plugin_hook capture): the shell fails within a second, the listing names the hung process, and nothing is left.
printf '/bin/sleep 3.%s; :\n' $$ > "$HOME/hang.sh"   # `; :` keeps bash from exec-ing the sleep: it stays a grandchild
rc=0; t=$SECONDS; out=$( (arm_watchdog 0.1; x=$(bash "$HOME/hang.sh")) 2>&1 ) || rc=$?; t=$((SECONDS - t)); left=$(ps -eo args=)
[ "$rc" != 0 ] && [ "$t" -le 1 ] && grep -qF 'FAIL: still running after 0.1 s' <<<"$out" && grep -qF "/bin/sleep 3.$$" <<<"$out" && ! grep -qxF "/bin/sleep 3.$$" <<<"$left" ||
  { echo "FAIL: the watchdog must kill a hung grandchild and its shell within a second (rc=$rc, ${t} s): $out"; exit 1; }
echo "ok: the watchdog kills the whole process tree under a hung shell, a grandchild holding a \$(...) pipe included"
# The fake plugin sits in the cache layout the patch verb walks; $HOME/fakeplugin
# is a link to its one version dir, which the assertions read through.
FAKEDIR="$HOME/.claude/plugins/cache/claude-plugins-official/discord/0.0.4"
mkdir -p "$FAKEDIR" "$HOME/bin"; ln -s "$FAKEDIR" "$HOME/fakeplugin"
printf 'client.on(%s, msg => {\n  if (msg.author.bot) return\n  handleInbound(msg)\n})\nfunction isAddressed(msg) {\n  if (client.user && msg.mentions.has(client.user)) return true\n}\nasync function reply(text, limit, mode) {\n        const chunks = chunk(text, limit, mode)\n}\n      meta: {\n        user_id: msg.author.id,\n        ts: x,\n      },\nconst TOKEN = process.env.DISCORD_BOT_TOKEN\nif (!TOKEN) {\n  process.stderr.write("no token")\n  process.exit(1)\n}\nclient.login(TOKEN).catch(err => {\n  process.exit(1)\n})\n' "'messageCreate'" > "$HOME/fakeplugin/server.ts"
cp "$HOME/fakeplugin/server.ts" "$HOME/server.ts.pristine"
printf '#!/bin/bash\necho "LAUNCHER $*"\n[ ! -e "$HOME/launch.fails" ]\n' > "$HOME/bin/claude-launcher"; chmod +x "$HOME/bin/claude-launcher"
printf '#!/bin/bash\ncase $1 in agents) exit 1;; *) echo "PLAIN $*";; esac\n' > "$HOME/bin/claude"; chmod +x "$HOME/bin/claude"
CURL_LOG="$HOME/curl.log"; : > "$CURL_LOG"
CURL_STDIN_LOG="$HOME/curl.stdin.log"; : > "$CURL_STDIN_LOG"
CURL_REPLIES="$HOME/curl.replies"; : > "$CURL_REPLIES"
cat > "$HOME/bin/curl" <<'EOF'
#!/bin/bash
# Logs its args to CURL_LOG instead of stdout, since the caller redirects
# stdout/stderr to /dev/null for the real, detached curl call. Also drains
# stdin to CURL_STDIN_LOG, since the real call sends the auth header there
# (-H @-), never in argv. A caller that READS the answer (the thread helper)
# queues one "<http status> <body>" line per call in CURL_REPLIES; the line
# is consumed and printed back as the real `-w '\n%{http_code}'` shape, body
# first. With nothing queued nothing is printed, as before.
# Builtins only (read, printf): a spawned head, cat or tail costs more than the stub's whole job, and it runs ~100 times.
printf '%s\n' "$*" >> "$CURL_LOG"
[ -z "${HTTPS_PROXY:-}${https_proxy:-}" ] || printf '%s|%s\n' "${HTTPS_PROXY:-}" "${https_proxy:-}" >> "$HOME/curl.proxy"   # the env a call ran with (the monitor's POST)
while IFS= read -r l || [ -n "$l" ]; do printf '%s\n' "$l"; done >> "$CURL_STDIN_LOG" 2>/dev/null
# A held answer, after the request: with $HOME/curl.hold the call says it is under way (curl.held) and answers only when
# the case lets it (curl.go), so what a case does "during a POST" is done during it on any machine (5 s at most).
if [ -f "$HOME/curl.hold" ]; then echo 1 > "$HOME/curl.held"; n=0; until [ -e "$HOME/curl.go" ] || [ "$n" -ge 1000 ]; do /bin/sleep 0.005; n=$((n + 1)); done; fi
line=""; rest=()
{ IFS= read -r line && while IFS= read -r l; do rest+=("$l"); done; } < "$CURL_REPLIES" 2>/dev/null || :   # no mapfile: bash 3.2 runs this on a Mac
if [ -n "$line" ]; then
  if [ ${#rest[@]} -gt 0 ]; then printf '%s\n' "${rest[@]}" > "$CURL_REPLIES.rest"; else : > "$CURL_REPLIES.rest"; fi && mv "$CURL_REPLIES.rest" "$CURL_REPLIES"
  printf '%s\n%s' "${line#* }" "${line%% *}"
fi
EOF
chmod +x "$HOME/bin/curl"
# `sleep`, stubbed by duration so the suite stays inside its 40 s budget
# (CLAUDE.md) without dropping an assertion; any other duration is real:
#   0.5  refresh's wait for the old session to exit (20 rounds): 0.01 s.
#   3    refresh's pause for the old gateway to let go: not slept.
#   0.05 on-session-start's wait for a held pins.json.lock (4 rounds): 0.01 s.
#   0.1  monitor --stop's poll for the keeper, then the monitor, to be gone (50 rounds each): 0.01 s. The monitor's
#        lock wait is a real 0.1 s here and goes through this stub too, so the suite writes that one 0.10.
# sh, not bash: the monitor sleeps a step at a time through it, and dash starts in a third of bash's time.
cat > "$HOME/bin/sleep" <<'EOF'
#!/bin/sh
case $* in
  0.5|0.05|0.1) exec /bin/sleep 0.01 ;;
  3) exit 0 ;;
  *) exec /bin/sleep "$@" ;;
esac
EOF
chmod +x "$HOME/bin/sleep"
# `jq`, memoized. jq 1.6 compiles its builtins at every start (10.7 ms here, 2026-10-11), and the wrapper, the hooks and
# this suite start it ~1600 times, ~1000 of them with a call already made in this run: half the suite's wall time. jq is a
# pure function of its arguments, the files it names and its stdin, so the first answer to each distinct call is kept and
# replayed (~2 ms). A file is keyed by its contents, not its path (the same document read from another project's copy
# is a hit): jq's output names no input file except through input_filename (an `input` builtin, run by real jq) and its
# stderr (never kept). Whatever the stub does not fully understand runs the real jq untouched: an option outside the plain
# set, a filter that names the clock, the environment, `input` or a module, a file argument that is not a readable
# regular file. An answer that came with stderr, or a failure other than -e's 1 or 4, is never kept. One answer is known
# without jq: a lone input file that does not exist in a searchable directory reads no input, so jq runs no filter and
# prints only its open error (rc 2); the wrapper probes absent files that way ~45 times a run.
# An entry is "<rc>\n<key><stdout>\004" in a file named by the lengths of the key's parts, created with noclobber (hooks
# run in parallel); a reader takes it only when it holds its own key and ends in \004, so a half-written one is a miss.
# Inputs and entries are read line by line (c ends up byte for byte the content): bash reads a file in blocks that way,
# and a byte per syscall with any other delimiter.
# JQ_REAL and JQ_CACHE in the environment override the built-in paths (the self-test below).
mkdir -p "$HOME/jq.cache"; JQR=$(command -v jq)
{ printf '#!/bin/bash\nJQ_REAL=${JQ_REAL:-%q}; JQ_CACHE=${JQ_CACHE:-%q}\n' "$JQR" "$HOME/jq.cache"; cat <<'EOF'
args=("$@"); filter=""; have=0; null=0; sl=0; inputs=0; files=(); key=""   # key: the arguments, a file as \003
real() { exec "$JQ_REAL" "${args[@]}"; }
slurp() { local l; c=""; while IFS= read -r l; do c+=$l$'\n'; done; c+=$l; }   # shortcut: drops a NUL, so a\0b and ab share a key and jq -R sees ab; no caller sends one (JSON has none), and spotting one costs a byte-wise read
while [ $# -gt 0 ]; do
  a=$1; shift
  case $a in
    --arg|--argjson) [ $# -ge 2 ] || real; key+=$a$'\001'$1$'\001'$2$'\001'; shift 2;;
    --slurpfile|--rawfile) [ $# -ge 2 ] || real; files+=("$2"); key+=$a$'\001'$1$'\001\003\001'; shift 2;;
    -[a-zA-Z]*) case ${a#-} in *[!nrcesSjaRMC]*) real;; esac; case $a in *n*) null=1;; esac; case $a in *s*) sl=1;; esac; key+=$a$'\001';;
    -*) real;;
    *) if [ $have = 0 ]; then filter=$a; have=1; key+=$a$'\001'; else files+=("$a"); inputs=1; key+=$'\003\001'; fi;;
  esac
done
[ $have = 1 ] || real
re='(^|[^.A-Za-z0-9_])(now|env|ENV|input[a-z_]*|[a-z]*local[a-z]*|debug|stderr|halt[a-z_]*|import|include|modulemeta|get_[a-z_]*|strptime|strftime|mktime|gmtime|todate[a-z0-9]*|fromdate[a-z0-9]*|date[a-z0-9]*)([^A-Za-z0-9_]|$)'
[[ ! $filter =~ $re ]] || real
if [ ${#files[@]} = 1 ] && [ $inputs = 1 ] && [ $null = 0 ] && [ $sl = 0 ]; then   # -n opens nothing, -s still prints []
  f=${files[0]}; d=${f%/*}
  if [ "$d" != "$f" ] && [ ! -e "$f" ] && [ ! -L "$f" ] && [ -d "${d:-/}" ] && [ -x "${d:-/}" ]; then
    printf 'jq: error: Could not open file %s: No such file or directory\n' "$f" >&2; exit 2
  fi
fi
name=${#key}; fk=""
for f in "${files[@]}"; do
  { [ -f "$f" ] && [ -r "$f" ]; } || real
  slurp < "$f"; fk+=$c$'\002'; name+=-${#c}
done
key+=$fk
t=$JQ_CACHE/t$$; piped=0
if [ $null = 0 ] && [ $inputs = 0 ]; then slurp; in=$c; key+=$c; name+=-${#c}; piped=1; fi
i=0
while [ -e "$JQ_CACHE/$name.$i" ]; do
  slurp < "$JQ_CACHE/$name.$i"; rc=${c%%$'\n'*}; c=${c#*$'\n'}
  if [ "${c:0:${#key}}" = "$key" ] && [ "${c: -1}" = $'\004' ]; then c=${c:${#key}}; printf '%s' "${c%?}"; exit "$rc"; fi
  i=$((i+1))
done
rc=0
if [ $piped = 1 ]; then printf '%s' "$in" > "$t.i"; "$JQ_REAL" "${args[@]}" < "$t.i" > "$t.o" 2> "$t.e" || rc=$?
else "$JQ_REAL" "${args[@]}" > "$t.o" 2> "$t.e" || rc=$?; fi
slurp < "$t.o"; out=$c   # shortcut: t<pid>.* stay (an rm per miss costs ~0.8 s of the suite); HOME goes at exit
printf '%s' "$out"
if [ -s "$t.e" ]; then slurp < "$t.e"; printf '%s' "$c" >&2; exit "$rc"; fi
# Real jq opened the files by path after the key was read: one replaced in between (mv -f) answered for other contents.
n=""; for f in "${files[@]}"; do { slurp < "$f"; } 2>/dev/null || exit "$rc"; n+=$c$'\002'; done; [ "$n" = "$fk" ] || exit "$rc"
case $rc in 0|1|4) case $key$out in *$'\004'*) ;; *) set -C; { printf '%s\n%s%s\004' "$rc" "$key" "$out" > "$JQ_CACHE/$name.$i"; } 2>/dev/null;; esac;; esac
exit "$rc"
EOF
} > "$HOME/jqstub.sh"; chmod +x "$HOME/jqstub.sh"; cp "$HOME/jqstub.sh" "$HOME/bin/jq"
# The same stub in C, used instead wherever a C compiler builds it: one exec a call, no bash start (a hit costs ~0.9 ms
# against ~1.9, a miss ~1.5 ms less, ~1800 calls a run). Same calls kept, same calls passed to real jq, same answer for a
# missing lone file. Its entry is "<rc>\n<key length>\n<key><stdout>\004", named by the key's hash (decimal), created
# with O_EXCL and taken only whole; real jq's stdin, stdout and stderr are files, as above, but in memory with no name
# (memfd: nothing to create or remove in the cache dir, ~0.3 ms a miss, ~900 misses a run); without memfd, real jq.
cat > "$HOME/jqstub.c" <<'EOF'
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <regex.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
static char **av; static const char *jqr, *cache;
static void real(void) { av[0] = (char *)jqr; execv(jqr, av); _exit(127); }
typedef struct { char *p; size_t n, cap; } buf;
static void put(buf *b, const void *s, size_t n) {
  if (b->n + n + 1 > b->cap) { b->cap = (b->n + n + 1) * 2; b->p = realloc(b->p, b->cap); }
  memcpy(b->p + b->n, s, n); b->n += n; b->p[b->n] = 0;
}
static void puts0(buf *b, const char *s) { put(b, s, strlen(s)); }
static int slurp_fd(int fd, buf *b) {
  char t[65536]; ssize_t r;
  while ((r = read(fd, t, sizeof t)) != 0) { if (r < 0) { if (errno == EINTR) continue; return -1; } put(b, t, (size_t)r); }
  return 0;
}
static int slurp(const char *f, buf *b) { int fd = open(f, O_RDONLY), r; if (fd < 0) return -1; r = slurp_fd(fd, b); close(fd); return r; }
static int regfile(const char *f) { struct stat s; return stat(f, &s) == 0 && S_ISREG(s.st_mode) && access(f, R_OK) == 0; }
static void out(int fd, const char *p, size_t n) { while (n) { ssize_t w = write(fd, p, n); if (w <= 0) break; p += w; n -= (size_t)w; } }
int main(int argc, char **argv) {
  av = argv;
  jqr = getenv("JQ_REAL"); if (!jqr || !*jqr) jqr = JQR;
  cache = getenv("JQ_CACHE"); if (!cache || !*cache) cache = JQC;
  buf key = {0}, fk = {0}, in = {0}; const char *filter = NULL, *files[256]; int nul = 0, sl = 0, inputs = 0, nf = 0;
  for (int i = 1; i < argc; i++) {   /* the key: the arguments, \001 after each, a file as \003 */
    const char *a = argv[i];
    if (!strcmp(a, "--arg") || !strcmp(a, "--argjson")) {
      if (i + 2 >= argc) real();
      puts0(&key, a); put(&key, "\1", 1); puts0(&key, argv[i + 1]); put(&key, "\1", 1); puts0(&key, argv[i + 2]); put(&key, "\1", 1); i += 2;
    } else if (!strcmp(a, "--slurpfile") || !strcmp(a, "--rawfile")) {
      if (i + 2 >= argc || nf == 256) real();
      files[nf++] = argv[i + 2]; puts0(&key, a); put(&key, "\1", 1); puts0(&key, argv[i + 1]); put(&key, "\1\3\1", 3); i += 2;
    } else if (a[0] == '-' && ((a[1] >= 'a' && a[1] <= 'z') || (a[1] >= 'A' && a[1] <= 'Z'))) {
      if (a[strspn(a + 1, "nrcesSjaRMC") + 1]) real();
      if (strchr(a, 'n')) nul = 1;
      if (strchr(a, 's')) sl = 1;
      puts0(&key, a); put(&key, "\1", 1);
    } else if (a[0] == '-') {
      real();
    } else if (!filter) {
      filter = a; puts0(&key, a); put(&key, "\1", 1);
    } else {
      if (nf == 256) real();
      files[nf++] = a; inputs = 1; put(&key, "\3\1", 2);
    }
  }
  if (!filter) real();
  regex_t re;
  if (regcomp(&re, "(^|[^.A-Za-z0-9_])(now|env|ENV|input[a-z_]*|[a-z]*local[a-z]*|debug|stderr|halt[a-z_]*|import|include|modulemeta|get_[a-z_]*|strptime|strftime|mktime|gmtime|todate[a-z0-9]*|fromdate[a-z0-9]*|date[a-z0-9]*)([^A-Za-z0-9_]|$)", REG_EXTENDED | REG_NOSUB) != 0
      || regexec(&re, filter, 0, NULL, 0) == 0) real();
  if (nf == 1 && inputs && !nul && !sl) {   /* -n opens nothing, -s still prints [] */
    const char *f = files[0], *s = strrchr(f, '/'); struct stat st; char d[4096]; size_t dl;
    if (s && (dl = (size_t)(s - f)) < sizeof d) {
      memcpy(d, f, dl); d[dl] = 0; if (!dl) strcpy(d, "/");
      if (lstat(f, &st) != 0 && stat(d, &st) == 0 && S_ISDIR(st.st_mode) && access(d, X_OK) == 0) {
        fprintf(stderr, "jq: error: Could not open file %s: No such file or directory\n", f); return 2;
      }
    }
  }
  for (int i = 0; i < nf; i++) { if (!regfile(files[i]) || slurp(files[i], &fk) < 0) real(); put(&fk, "\2", 1); }
  put(&key, fk.p ? fk.p : "", fk.n);
  int piped = !nul && !inputs;
  if (piped) { if (slurp_fd(0, &in) < 0) real(); put(&key, in.p ? in.p : "", in.n); }
  unsigned long long h = 1469598103934665603ULL;   /* FNV-1a */
  for (size_t i = 0; i < key.n; i++) { h ^= (unsigned char)key.p[i]; h *= 1099511628211ULL; }
  char path[4096]; int i = 0;
  for (;; i++) {
    buf e = {0}; char *n1, *n2;
    snprintf(path, sizeof path, "%s/%llu.%d", cache, h, i);
    if (slurp(path, &e) < 0) break;
    if (e.n && e.p[e.n - 1] == '\4' && (n1 = memchr(e.p, '\n', e.n)) && (n2 = memchr(n1 + 1, '\n', e.n - (size_t)(n1 + 1 - e.p)))
        && strtoull(n1 + 1, NULL, 10) == key.n && (size_t)(e.p + e.n - (n2 + 1)) > key.n && !memcmp(n2 + 1, key.p, key.n)) {
      out(1, n2 + 1 + key.n, (size_t)(e.p + e.n - 1 - (n2 + 1 + key.n))); return atoi(e.p);
    }
    free(e.p);
  }
  /* Real jq's stdin (rewound after the write), stdout and stderr: anonymous files. Any failure before the fork: real jq. */
  int fi = -1, fo = memfd_create("jq.o", 0), fe = memfd_create("jq.e", 0);
  if (fo < 0 || fe < 0) real();
  if (piped) { if ((fi = memfd_create("jq.i", 0)) < 0) real(); out(fi, in.p ? in.p : "", in.n); if (lseek(fi, 0, SEEK_SET) != 0) real(); }
  pid_t c = fork();
  if (c < 0) real();
  if (c == 0) {
    if (piped) dup2(fi, 0);
    dup2(fo, 1); dup2(fe, 2); close(fo); close(fe); if (piped) close(fi);
    av[0] = (char *)jqr; execv(jqr, av); _exit(127);
  }
  int st, rc; buf o = {0}, er = {0}, nk = {0};
  while (waitpid(c, &st, 0) < 0) if (errno != EINTR) return 127;
  rc = WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st);
  if (lseek(fo, 0, SEEK_SET) == 0) slurp_fd(fo, &o);
  if (lseek(fe, 0, SEEK_SET) == 0) slurp_fd(fe, &er);
  out(1, o.p ? o.p : "", o.n);
  if (er.n) { out(2, er.p, er.n); return rc; }
  /* Real jq opened the files by path after the key was read: one replaced in between answered for other contents. */
  for (int j = 0; j < nf; j++) { if (slurp(files[j], &nk) < 0) return rc; put(&nk, "\2", 1); }
  if (nk.n != fk.n || (nk.n && memcmp(nk.p, fk.p, nk.n)) || (rc != 0 && rc != 1 && rc != 4)) return rc;
  int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
  if (fd >= 0) {
    char hd[64]; int hl = snprintf(hd, sizeof hd, "%d\n%zu\n", rc, key.n); buf e = {0};
    put(&e, hd, (size_t)hl); put(&e, key.p, key.n); put(&e, o.p ? o.p : "", o.n); put(&e, "\4", 1); out(fd, e.p, e.n); close(fd);
  }
  return rc;
}
EOF
JQS=("$HOME/jqstub.sh")   # every stub built here, for the self-test below
# The suite's own jq calls run real jq, past the stub: nearly all of them read a document no earlier call read (a state.json
# the monitor just wrote, a wrapper's output), so the stub would only add its own start and copies. (`command -v jq` names
# this function from here on: the two stubs below that exec jq take $JQR.)
jq() { "$JQR" "$@"; }
if cc -O2 -o "$HOME/jqstub" -DJQR="\"$JQR\"" -DJQC="\"$HOME/jq.cache\"" "$HOME/jqstub.c" 2>/dev/null; then cp "$HOME/jqstub" "$HOME/bin/jq"; JQS+=("$HOME/jqstub"); fi
# A file replaced between the stub's read and real jq's open (a "real" jq that does the mv -f first) must store nothing:
# the later call on the old contents gets the real answer, not the new contents' one. For each stub built.
JT=$HOME/jqtoctou; printf '#!/bin/bash\nmv -f %q %q 2>/dev/null; exec %q "$@"\n' "$JT/new" "$JT/f" "$JQR" > "$HOME/jqtoctou.real"; chmod +x "$HOME/jqtoctou.real"
for js in "${JQS[@]}"; do
  mkdir -p "$JT/c"; printf '{"v":"old"}' > "$JT/f"; printf '{"v":"new"}' > "$JT/new"
  jt() { JQ_REAL=$HOME/jqtoctou.real JQ_CACHE=$JT/c "$js" "$@"; }
  [ "$(jt -r .v "$JT/f")" = new ] && ! compgen -G "$JT/c/[0-9]*" >/dev/null && printf '{"v":"old"}' > "$JT/f" && [ "$(jt -r .v "$JT/f")" = old ] \
    && rm "$JT"/c/[0-9]* && jt -n '0 | todate' >/dev/null && ! compgen -G "$JT/c/[0-9]*" >/dev/null \
    && [ "$(jt -e .x "$JT/none" 2>&1; echo "rc=$?")" = "$("$JQR" -e .x "$JT/none" 2>&1; echo "rc=$?")" ] \
    || { echo "FAIL: a file replaced while real jq ran must not be cached under its old contents, nor a time-zone builtin; a missing file answers as real jq ($js): $(ls "$JT/c")"; exit 1; }
  rm -rf "$JT"
done
echo "ok: the jq stub stores no answer for a file replaced while real jq ran or a time-zone builtin"
# Stands in for a session's claude process: runs each argument through
# sh -c, as Claude Code runs a hook command, and reads its output to EOF (a
# hook that left a child holding that pipe would hang here), appending it to
# $WORKER_OUT; then touches $WORKER_OUT.done and lives until killed. It leads
# a process group of its own, so a hook that left any child behind, its
# output redirected or not, is found in that group once the worker is gone.
cat > "$HOME/bin/fake-worker" <<'EOF'
#!/usr/bin/env perl
setpgrp(0, 0);
for my $c (@ARGV) {
  open(my $h, "-|", "/bin/sh", "-c", $c) or die; local $/; my $o = <$h>; close $h;
  open(my $f, ">>", $ENV{WORKER_OUT}) or die; print $f $o // ""; close $f;
}
open(my $d, ">", "$ENV{WORKER_OUT}.done") or die; close $d;
sleep 600;
EOF
chmod +x "$HOME/bin/fake-worker"
export PATH="$HOME/bin:$PATH"
export CURL_LOG CURL_STDIN_LOG CURL_REPLIES
export CLAUDE_DISCORD_LAUNCHER=claude-launcher
mkdir -p "$HOME/.claude-discord"
# The shim runs the clone for the current project, else the global one.
SH="$D/shim/claude-discord"; SP="$HOME/shim test/proj"; mkdir -p "$SP/.claude/skills/claude-discord/bin" "$SP/sub"
printf '#!/bin/bash\necho project-copy "$@"\n' > "$SP/.claude/skills/claude-discord/bin/claude-discord"; chmod +x "$SP/.claude/skills/claude-discord/bin/claude-discord"
mkdir -p "$HOME/.claude/skills/claude-discord/bin"; printf '#!/bin/bash\necho global-copy "$@"\n' > "$HOME/.claude/skills/claude-discord/bin/claude-discord"; chmod +x "$HOME/.claude/skills/claude-discord/bin/claude-discord"
[ "$(cd "$SP/sub" && bash "$SH" --bg x)" = "project-copy --bg x" ] || { echo "FAIL: the shim must run the project's clone from a subdirectory"; exit 1; }
# A nested project with discord-agents but no clone of its own: the walk stops there and runs the global clone, not the outer project's.
mkdir -p "$SP/sub/inner/.claude/discord-agents"
[ "$(cd "$SP/sub/inner" && bash "$SH" health)" = "global-copy health" ] || { echo "FAIL: a project without its own clone runs the global one"; exit 1; }
rm -rf "$HOME/.claude/skills/claude-discord"
# No install of its own and no global one, but the machine's source clone: a new or unmigrated project still reaches it (setup, a launch, update).
mkdir -p "$HOME/.claude-discord/source/bin"; printf '#!/bin/bash\necho source-copy "$@"\n' > "$HOME/.claude-discord/source/bin/claude-discord"; chmod +x "$HOME/.claude-discord/source/bin/claude-discord"
[ "$(cd "$SP/sub/inner" && bash "$SH" setup bot)" = "source-copy setup bot" ] && [ "$(cd "$HOME" && bash "$SH" update --all)" = "source-copy update --all" ] || { echo "FAIL: with no install of its own the shim must run the source clone"; exit 1; }
rm -rf "$HOME/.claude-discord"
out=$(cd "$HOME" && bash "$SH" 2>&1) && { echo "FAIL: with no clone the shim must fail"; exit 1; }
grep -q 'not set up' <<<"$out" && grep -q 'git clone' <<<"$out" || { echo "FAIL: the shim must say how to set up: $out"; exit 1; }
rm -rf "$HOME/shim test" "$HOME/.claude/skills"
echo "ok: the shim runs the project's clone (path with a space, from a subdirectory), else the global one, else the source clone, else explains"
# Where a project's state is, for every fixture (1.18.0): pstate <project> its state dir ~/.claude-discord/projects/<key>
# (config.env, peers.json, checkin/), broot <project> the directory holding its bot dirs (bots/), bdir <project> <bot> one
# bot's dir. Each makes the project and its key dir with its `project` file when missing (a fixture built by hand is then
# the new shape to the wrapper and the hooks). The old shape, <project>/.claude/discord-agents/, is written literally where
# a case is about a project not moved yet.
pstate() { local d; mkdir -p "$1"; d=$HOME/.claude-discord/projects/$(skey "$1"); mkdir -p "$d"; [ -f "$d/project" ] || (cd "$1" && pwd -P) > "$d/project"; printf '%s\n' "$d"; }
broot() { local d; d=$(pstate "$1"); mkdir -p "$d/bots"; printf '%s/bots\n' "$d"; }
bdir() { printf '%s/%s\n' "$(broot "$1")" "$2"; }
# skey <project>: the state key of a project (physical path), the suite's own copy of the rule bin/lib/state.sh's proj_key follows (its table case pins the two equal).
skey() { local p; p=$(cd "$1" 2>/dev/null && pwd -P) || p=$1; local LC_ALL=C; printf '%s\n' "${p//[^A-Za-z0-9]/-}"; }

P="$HOME/project"; mkdir -p "$P"; cd "$P"; git init -q .
# A local stand-in for GitHub, built from the WORKING TREE (a clone of $D would
# carry only committed HEAD, so a red-green cycle could not see an edit). Every
# setup below clones it, so it exists from the first one; the network is never
# reached. The main project is trusted so no setup asks.
SRC="$HOME/src-repo"; mkdir -p "$SRC"
# Only files that exist (a tracked file deleted in the tree is still listed), and never the nested worktrees or the SDD notes.
(cd "$D" && git ls-files -co --exclude-standard -z | while IFS= read -r -d '' f; do
  if [ -e "$f" ]; then case $f in .worktrees/*|.superpowers/*) ;; *) printf '%s\0' "$f";; esac; fi
done | tar --null -T - -cf -) | tar -xf - -C "$SRC" &&
  (cd "$SRC" && git init -q . && git add -A && git -c user.email=t@t -c user.name=t commit -qm stand-in) || { echo "FAIL: could not build the stand-in repo"; exit 1; }
export CLAUDE_DISCORD_REPO=$SRC
# compat writers poll a held lock in short steps and give up within seconds here. The give-up bound (5 s) is NOT past
# the default stale bound (5 s) on purpose: a leaked lock fails the suite instead of being broken; stale-lock cases age
# the lock with touch -d.
export CLAUDE_DISCORD_COMPAT_STEP_S=0.01 CLAUDE_DISCORD_COMPAT_WAIT_S=5
PHOME=$(cd "$HOME" && pwd -P)   # setup keys trust by the physical path
jq -n --arg h "$PHOME" '[$h + "/project", $h + "/project-moved", $h + "/project4", $h + "/project-all", $h + "/project-upper", $h + "/project-runpath", $h + "/project-later", $h + "/project2"] | map({key: ., value: {hasTrustDialogAccepted: true}}) | {projects: from_entries}' > "$HOME/.claude.json"
R=$(broot "$P") RS=$(pstate "$P")   # the bot dirs of the main project, and its state dir (config.env, peers.json, checkin/)

printf '\n1550575144320110662\n111\n222, 333 ,\ntokA\ny\n' | bash "$S" setup alpha --scope project >/dev/null
# No --method: the default is link, and the first setup on a machine clones the source.
[ -L "$P/.claude/skills/claude-discord" ] && [ "$(readlink "$P/.claude/skills/claude-discord")" = "$HOME/.claude-discord/source" ] && [ -d "$HOME/.claude-discord/source/.git" ] || { echo "FAIL: the default method must link the project to a freshly cloned source"; exit 1; }
[ "$(jq -r '.groups["1550575144320110662"].requireMention' "$R/alpha/access.json")" = false ]
[ "$(jq -c '.groups["1550575144320110662"].allowFrom' "$R/alpha/access.json")" = '["111","222","333"]' ]
[ "$(jq -c '.allowFrom' "$R/alpha/access.json")" = '["111"]' ]
[ "$(jq -r '.ackReaction' "$R/alpha/access.json")" = "👀" ]
grep -q "^DISCORD_ALLOW_IDS='222,333,'$" "$RS/config.env"
grep -q "^DISCORD_BOT_TOKEN=tokA$" "$R/alpha/.env"
[ "$(<"$R/alpha/mode")" = none ] || { echo "FAIL: no mode answer (EOF) must store the default, none"; exit 1; }
echo "ok: setup writes config.env, .env, access.json (with ackReaction) and mode (default none); others normalised; no-mention honoured"

# From here the suite runs the installed plugin, as a project does: the source clone the first setup made.
# Its hooks resolve plugin_root to it, so that is the path asserted.
PC=$(cd -P "$HOME/.claude-discord/source" && pwd -P); S=$PC/bin/claude-discord
TT=$PC/tools/thread   # the hooks name the thread tool by its absolute path in the plugin
! grep -qs '/.claude/discord-agents/hooks/' "$P/.claude/settings.local.json" "$P/.claude/settings.json" || { echo "FAIL: setup must register no settings hook, the plugin's hooks.json does"; exit 1; }
[ ! -e "$P/.claude/discord-agents" ] || { echo "FAIL: setup must leave no hooks link or state under the project's .claude (1.18.0): $(ls -la "$P/.claude/discord-agents")"; exit 1; }
echo "ok: setup registers no settings hook and leaves nothing under the project's .claude but the install"
