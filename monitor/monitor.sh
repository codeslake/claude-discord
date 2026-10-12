#!/usr/bin/env bash
# claude-discord's backend monitor: one process per manager bot. Every 5 min
# it runs `claude-discord health --all --json --patch` on each host of the
# bot's ledger (<project>/.claude/discord-agents/<bot>/hosts; `local` is this
# machine, the rest go over ssh), folds the answers into state.json and posts
# one message per state change to #bot-health-check with the manager bot's
# token. It never restarts or stops anything.
#
# Run by the wrapper only:
#   claude-discord monitor [--ensure] <bot> [--holder tui|session <pid>]
# registers the holder (when given), then starts the monitor detached unless
# one already holds the lock. The monitor lives while a holder lives (the TUI,
# the manager session) and exits within one tick (30 s) of the last one.
#
# Everything it keeps is under ~/.claude-discord/records/monitor/<bot>/:
#   lock                       the flock target (fd 9 of the monitor)
#   state.json (+ .tmp)        what the TUI shows; `posted` makes a restart quiet
#   monitor.log, monitor.log.1 256 KiB each at most
#   holders/<kind>-<pid>       "<pid> <start time> <kind>"
#   pass.out                   one host's answer, only during a pass
# Nothing in /tmp: no mktemp and no here-document or here-string anywhere in
# this file (bash 3.2 backs both with a temp file).
# Runs under macOS /bin/bash 3.2: no associative arrays, no fractional read -t.
set -u
self=${1:?wrapper path}; shift
locked=no kind="" hpid="" bot=""
while [ $# -gt 0 ]; do
  case $1 in
    --ensure) ;;
    --locked) locked=yes;;   # internal: this process holds the lock on fd 9
    --holder) kind=${2:-} hpid=${3:-}; shift 3 2>/dev/null || shift $#; continue;;
    -*) echo "usage: claude-discord monitor [--ensure] <bot> [--holder tui|session <pid>]" >&2; exit 2;;
    *) bot=$1;;
  esac
  shift
done
case $bot in ''|.|..|*/*) echo "usage: claude-discord monitor [--ensure] <bot> [--holder tui|session <pid>]" >&2; exit 2;; esac
dir=$PWD/.claude/discord-agents/$bot
# The ledger is the on/off switch: no hosts file, no monitor.
[ -f "$dir/hosts" ] && [ -f "$dir/.env" ] || { echo "claude-discord: monitor: $dir has no hosts ledger (claude-discord setup $bot --mode writes one)" >&2; exit 1; }
M=$HOME/.claude-discord/records/monitor/$bot
umask 077
mkdir -p "$M/holders" || exit 1

# lstart <pid>: the process's start time. A pid alone can be reused; a pid
# with its start time cannot. Linux: field 22 of /proc/<pid>/stat, read with
# no fork (this runs every tick); elsewhere `ps -o lstart=`, whitespace
# collapsed ("Oct  1" has two spaces). Prints nothing for no such process
# (or, on Linux, for a zombie no parent has reaped yet).
lstart() {
  local st
  if [ -r "/proc/$1/stat" ]; then
    { read -r st < "/proc/$1/stat"; } 2>/dev/null || return 0
    set -f; set -- ${st##*) }; set +f   # after "<pid> (<comm>) ", which may hold spaces: field 3 on
    [ "${1:-}" = Z ] || echo "${20:-}"   # a zombie is dead, whatever kill -0 says
  else
    set -- $(ps -o lstart= -p "$1" 2>/dev/null); echo "$*"
  fi
}

if [ -n "$kind$hpid" ]; then
  case $kind in tui|session) ;; *) echo "claude-discord: monitor: --holder takes tui or session, got '$kind'" >&2; exit 2;; esac
  case $hpid in ''|*[!0-9]*) echo "claude-discord: monitor: --holder needs a pid, got '$hpid'" >&2; exit 2;; esac
  st=$(lstart "$hpid")
  [ -n "$st" ] || { echo "claude-discord: monitor: no process $hpid to hold for" >&2; exit 1; }
  printf '%s %s %s\n' "$hpid" "$st" "$kind" > "$M/holders/$kind-$hpid"
fi

if [ "$locked" = no ]; then
  # flock through perl: flock(1) is util-linux and a manager may be a Mac.
  # One try at once, then perl forks and this returns, so a caller never
  # waits. The child (setsid, stdin closed, output appended to monitor.log,
  # the only trace a crash leaves) keeps trying for up to 5 s:
  # winning makes it the monitor, losing means one is running. The wait is the
  # exit race's cover: a holder that registers just as the old monitor leaves
  # (it saw no holder a moment earlier) gets the lock when that one is gone and
  # starts the next. The lock is dup'd to fd 9 (no close-on-exec), so it lives
  # exactly as long as the monitor process; the kernel drops it on any death.
  : >> "$M/lock"
  perl -MPOSIX -MFcntl=:flock -e '
    my $tries = int(shift(@ARGV) * 10 + 0.5);
    open(my $l, ">>", shift @ARGV) or exit 1;
    my $won = flock($l, LOCK_EX | LOCK_NB);
    defined(my $pid = fork()) or exit 1;
    exit 0 if $pid;
    POSIX::setsid();
    until ($won) { exit 0 if --$tries < 0; select(undef, undef, undef, 0.1); $won = flock($l, LOCK_EX | LOCK_NB); }
    POSIX::dup2(fileno($l), 9) == 9 or exit 1;
    exec @ARGV;' "${CLAUDE_DISCORD_MONITOR_LOCK_WAIT:-5}" "$M/lock" bash "$0" "$self" --locked "$bot" </dev/null >>"$M/monitor.log" 2>&1
  exit 0
fi

# ---- the monitor itself (fd 9 holds the lock) ------------------------------
# Every child that can outlive a moment (sleep, ssh, the local health)
# is started with 9>&-: a child that survived a crash would otherwise keep the
# lock and no new monitor could start.
# CLAUDE_DISCORD_MONITOR_LOCK_WAIT (above; 5) is the fourth interval the suite shortens.
tick=${CLAUDE_DISCORD_MONITOR_TICK:-30}        # holder check, seconds
pass=${CLAUDE_DISCORD_MONITOR_PASS:-300}       # a pass at most this often; health's unknown_cap=6 assumes 300
cap=${CLAUDE_DISCORD_MONITOR_HOST_CAP:-90}     # per host, enforced here (no timeout(1) on macOS)
# Fractional values are for the suite; bash counts in whole steps. A running
# host is polled every step (1 s, or a fifth of a tick shorter than 5 s).
read -r step pass_n cap_n tick_n < <(awk -v t="$tick" -v p="$pass" -v c="$cap" 'BEGIN {
  s = (t < 5 ? t / 5 : 1); printf "%s %d %d %d\n", s, (p / t < 1 ? 1 : int(p / t + 0.5)), int(c / s + 0.5), int(t / s + 0.5) }')
child="" state="" h_rc=0

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
# One line per event; never a message body, a header or a token. $ts, when set, stamps a burst of lines with one date.
log() { printf '%s %s\n' "${ts:-$(now)}" "$*" >> "$M/monitor.log" 2>/dev/null || :; }
# The cap, checked once per pass and at start: past 256 KiB the log becomes monitor.log.1, replacing the one before.
rotate() {
  local sz
  sz=$(wc -c < "$M/monitor.log" 2>/dev/null) || sz=0
  [ "${sz:-0}" -ge 262144 ] || return 0
  mv -f "$M/monitor.log" "$M/monitor.log.1" 2>/dev/null || return 0
  # The launcher opened monitor.log as this process's stdout and stderr: reopen
  # them on the new file, or they would keep growing monitor.log.1 past the cap.
  exec >> "$M/monitor.log" 2>&1
}
write_state() { printf '%s\n' "$state" > "$M/state.json.tmp" 2>/dev/null && mv -f "$M/state.json.tmp" "$M/state.json" 2>/dev/null || :; }
# read_cfg: mowner from the manager project's config.env (KEY='value' or
# KEY=value), with no fork: DISCORD_USER_ID, the manager's own owner.
read_cfg() {
  local l v
  mowner=""
  while IFS= read -r l || [ -n "$l" ]; do
    v=${l#*=}; v=${v#\'}; v=${v%\'}
    case $l in DISCORD_USER_ID=*) mowner=$v;; esac
  done < "$dir/../config.env" 2>/dev/null
}

# holders_alive: removes the records of dead holders; 0 when one still lives.
holders_alive() {
  local f p rest alive=1
  for f in "$M"/holders/*; do
    [ -f "$f" ] || continue
    p="" rest=""
    read -r p rest < "$f" 2>/dev/null || :
    case $p in ''|*[!0-9]*) rm -f "$f"; continue;; esac
    if kill -0 "$p" 2>/dev/null && [ "$(lstart "$p")" = "${rest% *}" ]; then alive=0; else rm -f "$f"; fi
  done
  return $alive
}
# Read twice before giving up: a holder may have registered just now.
no_holders() { holders_alive && return 1; holders_alive && return 1; return 0; }
holders_json() {  # sets hj: the holder records as a JSON array, with no fork
  local f b
  hj=""
  for f in "$M"/holders/*; do
    [ -f "$f" ] || continue
    b=${f##*/}; hj="$hj${hj:+,}{\"kind\":\"${b%%-*}\",\"pid\":${b##*-}}"
  done
  hj="[$hj]"
}
finish() {  # $1 = reason: kill the pass child, leave a state that reads as stopped, drop the holder records
  [ -z "$child" ] || kill "$child" 2>/dev/null
  rm -f "$M/pass.out"
  state=$(printf '%s' "$state" | jq -c --arg now "$(now)" '.monitor.pid = null | .monitor.holders = [] | .monitor.stopped_at = $now' 2>/dev/null) && write_state
  # On no-holders every record left was dead and is already gone; a record
  # that appears now belongs to a holder whose --ensure is waiting for this
  # lock, so it stays for the monitor that ensure starts (a stale one is pruned
  # by the next start's first holder check). On a signal the monitor is being taken down, and no
  # record may outlive it.
  [ "$1" = no-holders ] || rm -f "$M"/holders/* 2>/dev/null
  log "exit reason=$1"
  exit 0
}
trap 'finish signal' TERM INT HUP

# run_host: one host's health document into $M/pass.out, its exit status in
# h_rc (124 = the per-host cap). The child is polled, never waited on: the
# holder check keeps running every tick while a host is slow. ssh's own
# failure is exit 255, and only that is retried, once, with ControlPath=none
# (a stale master refuses falsely) and counts as hostdown. Any other status
# is the remote command's (claude-discord missing or too old), which is
# blind; so is the cap, since ConnectTimeout=8 already bounds the
# connection: a host that reaches the cap connected and never finished.
# Except a laptop's: one asleep behind its reverse tunnel can hang the forward
# past the cap, and a laptop's unreachability is never posted (hostdown).
run_host() {  # uses $host $remote, the envs array, and run_pass's step counter k
  local t k0
  for t in first retry; do
    if [ "$host" = local ]; then
      env ${envs[@]+"${envs[@]}"} "$HOME/.local/bin/claude-discord" health --all --json --patch > "$M/pass.out" 2>/dev/null < /dev/null 9>&- &
    elif [ "$t" = first ]; then
      ssh -o BatchMode=yes -o ConnectTimeout=8 "$host" "$remote" > "$M/pass.out" 2>/dev/null < /dev/null 9>&- &
    else
      ssh -o BatchMode=yes -o ConnectTimeout=8 -o ControlPath=none "$host" "$remote" > "$M/pass.out" 2>/dev/null < /dev/null 9>&- &
    fi
    child=$! k0=$k
    while kill -0 "$child" 2>/dev/null; do
      k=$((k + 1))
      if [ $((k - k0)) -gt "$cap_n" ]; then
        kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; child="" h_rc=124
        log "host $host no answer within ${cap}s"
        return 0
      fi
      # One counter for the whole pass, not per host: however many hosts are
      # slow, the holder check comes every tick.
      [ $((k % tick_n)) != 0 ] || ! no_holders || finish no-holders
      sleep "$step" 9>&-
    done
    wait "$child" 2>/dev/null; h_rc=$?; child=""
    [ "$h_rc" = 255 ] && [ "$host" != local ] && [ "$t" = first ] || return 0
    log "host $host ssh-failed rc=255 (retried with ControlPath=none)"
  done
}

# The reducer: (state, this pass's host results) -> the new state and the log
# events. One jq program, so every rule of "what a pass saw" is in one place:
#   - a verdict that changes restarts its `since`;
#   - while a host is noreach, hostdown or blind its bots are frozen;
#   - a project whose health crashed (an `error` entry) is blind for the bots
#     it had, which are kept, never dropped;
#   - a bot that left its host's answer is dropped, not announced.
# Input, raw lines: the state JSON, then two lines per host, "<host> US <laptop> US <exit status>" and the host's
# answer with its newlines made spaces (still valid JSON when it was).
# Output lines: "S<state JSON>", "N<bot count>", "E<event>".
reduce='
def good: . == "ok" or . == "busy";
# observe: fold one observation into an entry; `since` moves only when the verdict changes.
def observe($v; $d; $meta): (. // {}) as $o
  | $o + $meta + {verdict: $v, detail: $d}
  | if ($o.verdict // null) != $v then . + {since: $now, since_s: $now_s} else . end;

[inputs] as $in
| ($in[0] | fromjson) as $old
| [range(1; $in | length - 1; 2) as $i | ($in[$i] | split("\u001f")) as $h
   | {host: $h[0], laptop: ($h[1] == "true"), rc: ($h[2] | tonumber), doc: ($in[$i + 1] | try fromjson catch null)}] as $res
| reduce $res[] as $r ({state: $old, events: [], frozen: []};
    ($r.doc | if type == "object" and (.projects | type) == "array" then . else null end) as $doc
    | ([$doc.projects[]? | .project as $p | .bots[]? | . + {project: $p}]) as $bots
    | (if $r.rc == 255 or ($r.rc == 124 and $r.laptop) then "hostdown"
       elif $doc == null or $r.rc != 0 then "blind"
       elif ($bots | length) > 0 and all($bots[]; .verdict == "noreach") then "noreach"
       else "ok" end) as $reach
    | (if $reach == "hostdown" or $reach == "blind" then $reach
       elif ($doc.patch.rc // 0) != 0 then "patchfail"
       else $reach end) as $hv
    | (if $hv == "hostdown" and $r.rc == 124 then "no answer from \($r.host) within the per-host limit (a laptop: asleep behind its tunnel?)"
       elif $hv == "hostdown" then "ssh to \($r.host) failed (exit 255), also with ControlPath=none"
       elif $hv == "blind" and $r.rc == 124 then "\($r.host) connected but health --all did not finish within the per-host limit"
       elif $hv == "blind" and $doc != null then "health --all on \($r.host) printed its document but exited \($r.rc)"
       elif $hv == "blind" then "\($r.host) answered without a health document (exit \($r.rc)): claude-discord is missing there or older than health --all"
       elif $hv == "patchfail" then (($doc.patch.output // "") | gsub("\n"; " | "))
       elif $hv == "noreach" then "\($r.host) cannot reach Discord"
       else "" end) as $hd
    | (.state.hosts[$r.host].verdict // null) as $was
    | .state.hosts[$r.host] |= observe($hv; $hd;
        {host: $r.host, name: (if $r.host == "local" then ($doc.host // (.name // "local")) else $r.host end),
         laptop: $r.laptop, reach: $reach, owner_id: $mowner, checked: $now}
        + (if $doc != null then {version: ($doc.version // "?"), patch: (if $doc.patch == null then "-" elif ($doc.patch.rc // 0) == 0 then "ok" else "fail" end)} else {} end))
    | (if $was != $hv and ($was != null or ($hv | good | not)) then .events += ["transition \($r.host)|- \($was // "new")->\($hv)"] else . end)
    | if $reach != "ok" then .frozen += [$r.host]
      else
        ($bots | map("\($r.host)|\(.project)|\(.bot)")) as $present
        | ([$doc.projects[] | select(.error != null) | {(.project | tostring): (.error | tostring)}] | add // {}) as $errs
        | reduce $bots[] as $b (.;
            "\($r.host)|\($b.project)|\($b.bot)" as $k
            | (.state.bots[$k].verdict // null) as $bw
            | .state.bots[$k] |= observe($b.verdict; ($b.detail // "");
                {host: $r.host, name: (if $r.host == "local" then ($doc.host // "local") else $r.host end),
                 project: $b.project, bot: $b.bot, home: ($doc.home // ""), owner_id: ($b.owner_id // ""), servers: ($b.servers // "")})
            | if $bw != $b.verdict and ($bw != null or ($b.verdict | good | not)) then .events += ["transition \($k) \($bw // "new")->\($b.verdict)"] else . end)
        # The bots a crashed project had: blind with its error, every other field as last seen.
        | reduce ([.state.bots | to_entries[] | select(.value.host == $r.host and $errs[.value.project // ""] != null) | .key][]) as $k (.;
            (.state.bots[$k].verdict // null) as $bw
            | .state.bots[$k] |= observe("blind"; $errs[.project]; {})
            | if $bw != "blind" then .events += ["transition \($k) \($bw // "new")->blind"] else . end)
        | ([.state.bots | to_entries[] | select(.value.host == $r.host and $errs[.value.project // ""] == null
              and ((.key as $k | $present | index($k)) == null)) | .key]) as $gone
        | .events += ($gone | map("drop \(.)"))
        | .state.bots |= with_entries(select(.key as $k | ($gone | index($k)) == null))
      end)
| .state.monitor += {last_pass: $now, next_pass: (($now_s + $every) | floor | todate), pass_s: $pass_s, holders: $holders}
| .state as $s | .events as $ev
| "S" + ($s | tojson), "N\($s.bots | length)",
  ($ev[] | "E" + .)
'
run_pass() {
  local t0=$SECONDS now_s line w host laptop remote doc results="" out l rest hosts=0 nb=0 mowner ts="" hj k=0
  local envs=()
  rotate
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}   # a ledger saved with CRLF line endings
    set -f; set -- $line; set +f
    host=${1:-}; [ $# = 0 ] || shift
    case $host in ''|'#'*) continue;; esac
    # An ssh host name, never an option: the ledger is the owner's file, but a leading "-" would be read by ssh as a flag.
    case $host in -*|*[!A-Za-z0-9._@-]*) log "ledger: host skipped (not a plain ssh host name)"; continue;; esac
    laptop=false; [ "${1:-}" != laptop ] || { laptop=true; shift; }
    envs=()
    for w in "$@"; do
      if [[ $w =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then envs+=("$w"); else log "ledger: $host: a word that is not KEY=VALUE was skipped"; fi
    done
    remote="env $([ ${#envs[@]} = 0 ] || printf '%q ' "${envs[@]}")~/.local/bin/claude-discord health --all --json --patch"
    run_host
    doc=$(< "$M/pass.out") 2>/dev/null || doc=""
    results="$results$host"$'\x1f'"$laptop"$'\x1f'"$h_rc"$'\n'"${doc//$'\n'/ }"$'\n'
    hosts=$((hosts + 1))
  done < "$dir/hosts"
  rm -f "$M/pass.out"
  read_cfg; holders_json
  read -r now_s ts < <(date -u '+%s %Y-%m-%dT%H:%M:%SZ')
  out=$(printf '%s\n%s' "$state" "$results" | jq -nrR --arg now "$ts" --argjson now_s "$now_s" --arg mowner "$mowner" \
    --argjson every "$pass" --argjson pass_s "$(( SECONDS - t0 ))" --argjson holders "$hj" "$reduce" 2>/dev/null) ||
    { log "pass failed: the reducer rejected its input"; return 0; }
  while IFS= read -r l; do
    rest=${l#?}
    case $l in
      S*) state=$rest;;
      N*) nb=$rest;;
      E*) log "$rest";;
    esac
  done < <(printf '%s\n' "$out")
  write_state
  log "pass hosts=$hosts bots=$nb $(( SECONDS - t0 ))s"
}

rotate
# Start from the kept state (its `posted` is what keeps a restart quiet). A
# state file that is not ours (truncated, another version, another manager)
# starts empty and says so: findings still standing are then posted once more.
state=$(jq -c --arg bot "$bot" 'if type == "object" and .version == 1 and .manager == $bot then . else error("no") end' "$M/state.json" 2>/dev/null) || {
  [ ! -s "$M/state.json" ] || log "state unreadable, starting empty"
  state=$(jq -nc --arg bot "$bot" '{version: 1, manager: $bot, monitor: {}, hosts: {}, bots: {}, alerts: []}')
}
holders_json
state=$(printf '%s' "$state" | jq -c --argjson pid "$$" --arg now "$(now)" --argjson holders "$hj" \
  '.monitor = ((.monitor // {}) + {pid: $pid, started: $now, holders: $holders}) | del(.monitor.stopped_at)')
write_state
log start
n=$pass_n   # the first pass right after start
while :; do
  [ -f "$dir/hosts" ] || finish no-ledger
  ! no_holders || finish no-holders
  # Straight back to the holder check after a pass: the last in-pass check may be most of a tick old.
  if [ "$n" -ge "$pass_n" ]; then run_pass; n=0; continue; fi
  sleep "$tick" 9>&-
  n=$((n + 1))
done
