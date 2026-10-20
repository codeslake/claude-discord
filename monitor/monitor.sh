#!/usr/bin/env bash
# claude-discord's backend monitor: one process per manager bot. Every 5 min
# it runs `claude-discord health --all --json --patch` on each host of the
# bot's ledger (<project>/.claude/discord-agents/<bot>/hosts; `local` is this
# machine, the rest go over ssh), folds the answers into state.json and posts
# one message per state change to #bot-health-check with the manager bot's
# token. It never restarts or stops anything.
#
# Run through the wrapper. The backend of a manager bot is a keeper and the monitor it keeps up; it runs until
# `claude-discord monitor --stop <bot>`, whoever started it.
#   claude-discord monitor [--ensure] <bot> [--holder tui|keeper <pid>]
# registers the holder (when given), then starts the monitor detached unless
# one already holds the lock. The monitor ends on `--stop` (the `stopped`
# marker), a removed ledger or a signal, never for want of a holder: the
# records say who watches (a keeper, an open TUI) and are what the TUI shows.
# Every tick it starts the keeper again when none runs, as the keeper starts it.
#   claude-discord monitor --keep <bot> [--detach]
# the keeper: a holder of its own that runs the same --ensure every 60 s, so a
# dead monitor comes back with nothing else open (and the monitor brings a dead
# keeper back: a watch with neither left needs both gone inside one tick).
# Foreground (tmux, a container
# entrypoint, systemd); --detach (setup, the TUI, a manager session that finds
# none) checks, then runs it in its own session and returns. One per bot: it holds keeper.lock for its life. It
# runs the new monitor.sh once `claude-discord update` changed it. No OS scheduler, ever.
#   claude-discord monitor --stop <bot>     TERMs the keepers and the monitor and leaves the `stopped` marker:
#                                           nothing starts them again but
#   claude-discord monitor --start <bot>    clears the marker and starts the keeper detached.
#   claude-discord monitor --check <bot>    asks the running monitor for a pass at its next tick (the TUI's Check now,
#                                           and after it changed the ledger); starts nothing.
#
# Everything it keeps is under ~/.claude-discord/records/monitor/<key>/<bot>/ (<key>: the project's, state.sh):
#   lock                       the flock target (fd 9 of the monitor), holding its pid
#   keeper.lock                the flock target of the keeper (fd 8), held for its whole life
#   state.json (+ .tmp)        what the TUI shows; `posted` makes a restart quiet. Never a token and never the value
#                              of a ledger KEY=VALUE word (a proxy URL may hold a password): the key names only
#   monitor.log, monitor.log.1 256 KiB each at most
#   holders/<kind>-<pid>       "<pid> <start time> <kind>"
#   stopped                    `--stop` was run: no automatic start until `--start`
#   pass-now                   `--check` was run: the monitor removes it at a tick and runs a pass, 60 s at least
#                              after the last pass began (however many requests: one pass)
#   refused.<id>               a detached start met a monitor this side cannot see: this side's hooks start nothing until
#                              `--start` or a start that gets through. <id> is the pid namespace (the digits of
#                              `readlink /proc/self/ns/pid`), so the other side of a shared home is not stopped by it;
#                              plain `refused` where /proc has none (a Mac)
#   last-start.<id>            the last automatic start of the keeper, by a hook or by the monitor (epoch seconds,
#                              same <id>): none again within 60 s
#   pass.out                   one host's answer, only during a pass
#   post.out                   one POST's answer and status, only during a pass
# Nothing in /tmp: no mktemp and no here-document or here-string anywhere in
# this file (bash 3.2 backs both with a temp file).
# Runs under macOS /bin/bash 3.2: no associative arrays, no fractional read -t.
set -u
self=${1:?wrapper path}; shift
alert_channel=1558283274487341137   # #bot-health-check: both owners' managers post here; write-only
locked=no start="" kind="" hpid="" bot="" keep="" stop="" detach="" kept="" check=""
usage="usage: claude-discord monitor [--ensure] <bot> [--holder tui|keeper <pid>] | --keep <bot> [--detach] | --stop <bot> | --start <bot> | --check <bot>"
while [ $# -gt 0 ]; do
  case $1 in
    --ensure) ;;
    --locked) locked=yes;;   # internal: this process holds the lock on fd 9
    --keep) keep=yes;;
    --kept) kept=yes;;       # internal: this keeper holds keeper.lock on fd 8
    --stop) stop=yes;;
    --check) check=yes;;
    --start) start=yes keep=yes detach=yes;;
    --detach) detach=yes;;
    --holder) kind=${2:-} hpid=${3:-}; shift 3 2>/dev/null || shift $#; continue;;
    -*) echo "$usage" >&2; exit 2;;
    *) bot=$1;;
  esac
  shift
done
case $bot in ''|.|..|*/*) echo "$usage" >&2; exit 2;; esac
. "${BASH_SOURCE[0]%/*}/../bin/lib/state.sh"; proj_cwd; dir=$pd_root/$bot pstate=$pd_state   # either shape (1.18.0: ~/.claude-discord/projects/<key>/bots/<bot>; config.env beside bots/)
# The records are keyed by the project (1.18.1), so two projects may each have a manager of one name. CLAUDE_DISCORD_MONITOR_DIR
# names them elsewhere: compat's --stop of a backend started before 1.18.1 at records/monitor/<bot>, and its rollback.
M=${CLAUDE_DISCORD_MONITOR_DIR:-$HOME/.claude-discord/records/monitor/$pd_key/$bot}
# The ledger is the on/off switch: no hosts file, no monitor. --stop needs none: it stops what runs.
[ -n "$stop" ] || { [ -f "$dir/hosts" ] && [ -f "$dir/.env" ]; } || { echo "claude-discord: monitor: $dir has no hosts ledger (claude-discord setup $bot --mode writes one)" >&2; exit 1; }
# --stop of a name with neither a bot directory here nor records (a manager renamed away, a TUI still on its old name):
# nothing runs under it, and no record is made for it.
[ -z "$stop" ] || [ -d "$dir" ] || [ -d "$M" ] || { echo "claude-discord: monitor: no bot $bot here and no backend records of it: nothing to stop"; exit 0; }
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
    # In C and UTC: the record is written by --holder (a hook, the session's TZ and locale) and compared here (the
    # monitor's), and lstart is printed in the caller's locale and zone.
    set -- $(LC_ALL=C TZ=UTC0 ps -o lstart= -p "$1" 2>/dev/null); echo "$*"
  fi
}
# sig: this file's signature (mtime to the sub-second, size, inode), to see `claude-discord update` change it.
sig() { perl -MTime::HiRes=stat -e '@s = stat $ARGV[0] and print "$s[9] $s[7] $s[1]"' "$0" 2>/dev/null; }
# a_cmd <pid> <flag>: the pid runs bash .../monitor/monitor.sh <wrapper> <flag> <bot> as this side sees it.
a_cmd() {
  local c=""
  case $1 in ''|*[!0-9]*) return 1;; esac
  if [ -r "/proc/$1/cmdline" ]; then c=$(tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null); else c=$(ps -p "$1" -o command= 2>/dev/null); fi
  case "$c " in *"/monitor/monitor.sh "*" $2 $bot "*) return 0;; esac
  return 1
}
a_monitor() { a_cmd "$1" --locked; }
a_keeper() { a_cmd "$1" --keep; }
# live_rec <record>: its pid runs and started when the record says (a reused pid reads dead); sets rp to the pid.
live_rec() {
  local p="" rest=""
  { read -r p rest < "$1"; } 2>/dev/null
  case $p in ''|*[!0-9]*) return 1;; esac
  kill -0 "$p" 2>/dev/null && [ "$(lstart "$p")" = "${rest% *}" ] && rp=$p
}

if [ -n "$stop" ]; then
  # The marker first, so nothing automatic starts a keeper meanwhile; then the keepers (one would start the monitor
  # again), then the monitor the lock file names, if it runs here. Both are looked up before the marker: each leaves on
  # the marker by itself (the monitor at its next tick, a keeper at its next round), which may come before the TERM
  # below, and is reported either way.
  # A keeper whose start passed its stopped check just before the marker has no record yet and is not named here: it
  # leaves by itself within one interval (its --ensure is refused, its next round meets the marker) and starts nothing.
  l0=""; { read -r l0 < "$M/lock"; } 2>/dev/null; a_monitor "$l0" || l0=""
  ks=""
  for f in "$M"/holders/keeper-*; do
    [ -f "$f" ] || continue
    # Its command line too: a pid reused on the other side of a shared home is never signalled.
    ! { live_rec "$f" && a_keeper "$rp"; } || ks="$ks $rp"
  done
  : > "$M/stopped"
  said=""
  for rp in $ks; do
    ! a_keeper "$rp" || kill -TERM "$rp" 2>/dev/null
    echo "claude-discord: monitor: stopped keeper $rp"; said=1
    # Gone (its record with it) before the monitor goes: a monitor its last --ensure starts then finds no holder.
    n=0; while a_keeper "$rp" && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
  done
  rm -f "$M"/holders/keeper-*
  l=""; { read -r l < "$M/lock"; } 2>/dev/null
  if a_monitor "$l"; then
    kill -TERM "$l" 2>/dev/null; echo "claude-discord: monitor: stopped monitor $l"; said=1
    n=0; while a_monitor "$l" && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
  elif [ -n "$l0" ]; then
    echo "claude-discord: monitor: stopped monitor $l0"; said=1
  fi
  # Said in state.json too, for the TUI (the monitor wrote its own stop above; this is the one writer now).
  [ ! -s "$M/state.json" ] || { jq -c '.monitor.stopped_by_user = true' "$M/state.json" > "$M/state.json.tmp" && mv -f "$M/state.json.tmp" "$M/state.json"; } 2>/dev/null
  [ -n "$said" ] || echo "claude-discord: monitor: no keeper or monitor of $bot runs here"
  echo "claude-discord: monitor: $bot stays stopped until: claude-discord monitor --start $bot"
  exit 0
fi
if [ -n "$check" ]; then
  # A pass now, asked of the monitor that runs (the TUI: its Check now button, and after it changed the ledger). Only a
  # marker: the monitor meets it at a tick (see the loop below), removes it and runs the pass itself, so there is still one monitor,
  # one writer of state.json and one poster. Nothing is started here: with no monitor of this bot that this side can
  # see there is nobody to ask, and no marker is left for a later one (its first pass comes at once anyway).
  l=""; { read -r l < "$M/lock"; } 2>/dev/null
  a_monitor "$l" || { echo "claude-discord: monitor: no monitor of $bot runs here, so nothing was asked (claude-discord monitor --start $bot starts the backend)" >&2; exit 1; }
  : > "$M/pass-now" || exit 1
  echo "claude-discord: monitor: $bot checks its hosts at its next tick (within 30 s; a minute after its last pass began at the earliest)"
  exit 0
fi
# This side's refused marker (see the header): named by the pid namespace, so the other side of a shared home neither
# writes nor reads it.
rf=refused
if { [ -n "$start$keep" ] || [ "$locked" = yes ]; } && [ -L /proc/self/ns/pid ]; then ns=$(readlink /proc/self/ns/pid); ns=${ns//[!0-9]/}; [ -z "$ns" ] || rf=refused.$ns; fi
[ -z "$start" ] || rm -f "$M/stopped" "$M/$rf"
# What an automatic start meets after --stop: nothing is started until --start.
stopped_msg="claude-discord: monitor: $bot was stopped by you (monitor --stop); start it again with: claude-discord monitor --start $bot"

if [ -n "$keep" ]; then
  # Detached (setup, the TUI, a hook): what this says goes to monitor.log, and the outcome line to the caller too. The
  # detached keeper itself (kept) appends each line to monitor.log as it says it, so it follows a rotation.
  if [ -z "$detach" ]; then
    tell() { echo "$*"; }; tell_err() { echo "$*" >&2; }
  elif [ -n "$kept" ]; then
    tell() { echo "$*" >> "$M/monitor.log"; }; tell_err() { tell "$@"; }
  else
    exec 3>&1 >>"$M/monitor.log" 2>&1
    tell() { echo "$*"; echo "$*" >&3; }; tell_err() { echo "$*" >&2; echo "$*" >&3; }
  fi
  # A machine that must never start a backend by itself (the other side of a shared home; the suite): only --start does.
  [ -z "$detach" ] || [ -n "$start" ] || [ -n "$kept" ] || [ -z "${CLAUDE_DISCORD_NO_AUTOSTART:-}" ] || exit 0
  [ ! -e "$M/stopped" ] || { tell "$stopped_msg"; exit 0; }
  m=""; { read -r m < "$dir/mode"; } 2>/dev/null
  [ "$m" = dev-manager ] || { tell_err "claude-discord: monitor: --keep: $bot is not a dev-manager bot (mode '$m')"; exit 1; }
  if [ -z "$kept" ]; then
    # A home shared by two sides (a container and its host): the lock held, and the pid in it no monitor of this bot that
    # this side can see, means the monitor runs on the other side, with the bots; a keeper here would read them all as
    # down. A refusal only, never a takeover. Looked at twice, a lock wait apart: a monitor that just won the lock writes
    # its pid a moment later.
    unseen() {
      perl -MFcntl=:flock -e 'open(my $l, ">>", $ARGV[0]) or exit 1; exit(flock($l, LOCK_EX | LOCK_NB) ? 1 : 0)' "$M/lock" || return 1
      l=""; { read -r l < "$M/lock"; } 2>/dev/null
      ! a_monitor "$l"
    }
    if unseen; then
      sleep "${CLAUDE_DISCORD_MONITOR_LOCK_WAIT:-5}"
      # An automatic start (detached) leaves this side's marker, so a hook does not fork this again on every prompt; --start clears it.
      ! unseen || { [ -z "$detach" ] || : > "$M/$rf"; tell_err "claude-discord: monitor: --keep: the monitor lock is held by a monitor this side cannot see; run --keep where the bots run"; exit 1; }
    fi
    # A start that got through proves the marker stale (the monitor it met is gone).
    rm -f "$M/$rf"
    # One keeper per bot: the keeper takes $M/keeper.lock (flock, as the monitor takes its lock) BEFORE it detaches and
    # holds it on fd 8 for its whole life, through its self re-exec; the kernel drops it on any death. A starter that
    # loses it finds a keeper and exits 0. No record or pid is read, so two starters at once leave one keeper, and a
    # record another monitor deleted changes nothing. fd 8 is dup2'd, not just inherited: perl marks every higher fd
    # close-on-exec. The keeper's own children get 8>&- (a monitor it starts must not inherit the lock).
    msg="claude-discord: monitor: a keeper already runs for $bot"
    if [ -n "$detach" ]; then
      rc=0
      perl -MPOSIX -MFcntl=:flock -e '
        my ($d, $msg, $f) = splice(@ARGV, 0, 3);
        open(my $l, ">>", $f) or exit 1;
        flock($l, LOCK_EX | LOCK_NB) or do { print "$msg\n" unless $d; exit($d ? 3 : 0) };
        if ($d) { defined(my $pid = fork()) or exit 1; exit 0 if $pid; POSIX::setsid(); }
        POSIX::dup2(fileno($l), 8) == 8 or exit 1;
        exec @ARGV;' 1 "$msg" "$M/keeper.lock" bash "$0" "$self" --keep "$bot" --kept --detach </dev/null >>"$M/monitor.log" 2>&1 3>&- || rc=$?   # 3>&-: never the caller's pipe
      [ "$rc" != 3 ] || { tell "$msg"; exit 0; }
      [ "$rc" = 0 ] || exit 1
      tell "claude-discord: started the backend of $bot (a keeper and the monitor, detached); stop it with: claude-discord monitor --stop $bot"
      exit 0
    fi
    exec perl -MPOSIX -MFcntl=:flock -e '
      my ($d, $msg, $f) = splice(@ARGV, 0, 3);
      open(my $l, ">>", $f) or exit 1;
      flock($l, LOCK_EX | LOCK_NB) or do { print "$msg\n"; exit 0 };
      POSIX::dup2(fileno($l), 8) == 8 or exit 1;
      exec @ARGV;' 0 "$msg" "$M/keeper.lock" bash "$0" "$self" --keep "$bot" --kept
  fi
  iv=${CLAUDE_DISCORD_KEEP_INTERVAL:-60}   # read here only; the suite shortens it
  sp="" ksig=$(sig) kseen=""
  trap '[ -z "$sp" ] || kill "$sp" 2>/dev/null; rm -f "$M/holders/keeper-$$"; exit 0' TERM INT HUP
  tell "$(date -u +%Y-%m-%dT%H:%M:%SZ) keeper $$ start (every ${iv}s)"
  while :; do
    [ -f "$dir/hosts" ] || { rm -f "$M/holders/keeper-$$"; tell_err "claude-discord: monitor: keeper $$: $dir/hosts is gone; exiting"; exit 1; }
    # Stopped meanwhile (a start that passed its check while --stop ran): this keeper goes too.
    [ ! -e "$M/stopped" ] || { rm -f "$M/holders/keeper-$$"; tell "$stopped_msg"; exit 0; }
    # Registered again each time: a monitor taken down by a signal removes every holder record but a keeper's.
    # Detached: the log is opened per call (it follows a rotation). Foreground: stdio as it is; /dev/stderr cannot be
    # reopened when fd 2 is a socket (systemd's journal) or closed, which skips the command.
    if [ -n "$detach" ]; then bash "$0" "$self" --ensure "$bot" --holder keeper "$$" </dev/null >>"$M/monitor.log" 2>&1 8>&-
    else bash "$0" "$self" --ensure "$bot" --holder keeper "$$" </dev/null 8>&-; fi
    # claude-discord update changed this file: go on as the new one (same pid, so the record stays), once its signature
    # held for an interval and it parses, as the monitor does at a pass.
    cur=$(sig)
    if [ -n "$cur" ] && [ "$cur" != "$ksig" ]; then
      if [ "$cur" != "$kseen" ]; then kseen=$cur
      elif bash -n "$0" 2>/dev/null; then
        tell "$(date -u +%Y-%m-%dT%H:%M:%SZ) keeper $$ restart: monitor.sh changed"; trap - TERM INT HUP
        exec bash "$0" "$self" --keep "$bot" --kept ${detach:+--detach}
      fi
    fi
    # Waited on, so a TERM runs the trap at once.
    sleep "$iv" 8>&- & sp=$!; wait "$sp"; sp=""
  done
fi

# The TUI's --ensure after --stop: refused, and said in its red bar.
[ "$locked" = yes ] || [ ! -e "$M/stopped" ] || { echo "$stopped_msg" >&2; exit 1; }
# A waiter that won the lock after --stop killed the monitor (or a monitor re-exec'd while --stop ran) leaves at once:
# before the lock pid, the state and the log's start line, none of which may say it started.
[ "$locked" = no ] || [ ! -e "$M/stopped" ] || exit 0

if [ -n "$kind$hpid" ]; then
  case $kind in tui|keeper) ;; *) echo "claude-discord: monitor: --holder takes tui or keeper, got '$kind'" >&2; exit 2;; esac
  case $hpid in ''|*[!0-9]*) echo "claude-discord: monitor: --holder needs a pid, got '$hpid'" >&2; exit 2;; esac
  st=$(lstart "$hpid")
  [ -n "$st" ] || { echo "claude-discord: monitor: no process $hpid to hold for" >&2; exit 1; }
  # Written under a dot-name and moved in: the holder check's glob skips dot files, so it never reads a half-written record.
  printf '%s %s %s\n' "$hpid" "$st" "$kind" > "$M/holders/.$kind-$hpid" && mv -f "$M/holders/.$kind-$hpid" "$M/holders/$kind-$hpid"
fi

if [ "$locked" = no ]; then
  # flock through perl: flock(1) is util-linux and a manager may be a Mac.
  # One try at once, then perl forks and this returns, so a caller never
  # waits. The child (setsid, stdin closed, output appended to monitor.log,
  # the only trace a crash leaves) keeps trying for up to 5 s:
  # winning makes it the monitor, losing means one is running. The wait is the
  # exit race's cover: an --ensure that meets a monitor on its way out (a
  # signal, its restart) gets the lock when that one is gone and starts the
  # next. The lock is dup'd to fd 9 (no close-on-exec), so it lives
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
# Every child that can outlive a moment (sleep, ssh, the local health, curl)
# is started with 9>&-: a child that survived a crash would otherwise keep the
# lock and no new monitor could start.
# CLAUDE_DISCORD_MONITOR_LOCK_WAIT (above; 5) is the fourth interval the suite shortens, CHECK_GAP the fifth.
sig0=$(sig)   # this file as this process started
bad=""        # the signature of a changed monitor.sh that did not parse, logged once
seen=""       # the signature of a changed monitor.sh, exec'd once it is still the same a pass later
tick=${CLAUDE_DISCORD_MONITOR_TICK:-30}        # holder check, seconds
pass=${CLAUDE_DISCORD_MONITOR_PASS:-300}       # a pass at most this often, but for one asked for (--check):
gap=${CLAUDE_DISCORD_MONITOR_CHECK_GAP:-60}    # that one this long after the last pass began, at the earliest
cap=${CLAUDE_DISCORD_MONITOR_HOST_CAP:-90}     # per host, enforced here (no timeout(1) on macOS)
rcap=${CLAUDE_DISCORD_MONITOR_RECOVER_CAP:-90} # per automatic recover (1.19.0), the same way
sweep=${CLAUDE_DISCORD_MONITOR_SWEEP:-3600}    # the marker sweep, in a pass at most this often (whole seconds)
swept=$SECONDS                                 # the first one a whole interval after the start
# Fractional values are for the suite; bash counts in whole steps. A running
# host is polled every step (1 s, or a fifth of a tick shorter than 5 s).
read -r step pass_n cap_n tick_n gap_n rcap_n < <(awk -v t="$tick" -v p="$pass" -v c="$cap" -v g="$gap" -v r="$rcap" 'BEGIN {
  s = (t < 5 ? t / 5 : 1); printf "%s %d %d %d %d %d\n", s, (p / t < 1 ? 1 : int(p / t + 0.5)), int(c / s + 0.5), int(t / s + 0.5), int(g / t + 0.5), int(r / s + 0.5) }')
child="" tp="" state="" h_rc=0 local_env=() p_code=000 p_retry="" used=0 part="" stuck=""
# A pass child runs as its own process group (perl, as for the lock: setsid(1) is util-linux), so the cap and finish
# kill its whole subtree: a health's $(...) or an ssh's children would otherwise outlive both. The pid survives the exec.
pg='setpgrp(0, 0); exec { $ARGV[0] } @ARGV; exit 127'

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
# Never an empty state: a TERM before the first state is built, or a failed jq, would otherwise write a lone newline.
write_state() { [ -n "$state" ] || return 0; printf '%s\n' "$state" > "$M/state.json.tmp" 2>/dev/null && mv -f "$M/state.json.tmp" "$M/state.json" 2>/dev/null || :; }
# read_cfg: lang and mowner from the manager project's config.env (KEY='value'
# or KEY=value), with no fork: ALERT_LANG (en in any case, anything else ko)
# and DISCORD_USER_ID, the manager's own owner, whom a host-level finding mentions; MONITOR_RECOVER (1.19.0: no turns
# the automatic recover off, anything else leaves it on).
read_cfg() {
  local l v
  lang=ko mowner="" recover=yes
  while IFS= read -r l || [ -n "$l" ]; do
    v=${l#*=}; v=${v#\'}; v=${v%\'}
    case $l in
      ALERT_LANG=*) case $v in [eE][nN]) lang=en;; *) lang=ko;; esac;;
      DISCORD_USER_ID=*) mowner=$v;;
      MONITOR_RECOVER=*) case $v in [nN][oO]|0|[fF][aA][lL][sS][eE]|[oO][fF][fF]) recover=no;; *) recover=yes;; esac;;
    esac
  done 2>/dev/null < "$pstate/config.env"   # 2> first: a missing file's error must not reach monitor.log
}

# is_holder <path>: a record's name is tui-, keeper- or (written before 1.10.3) session-<digits>. Anything else there (a
# stray file) is no holder: as a pid it would make holders_json invalid JSON and fail every pass.
is_holder() { case ${1##*/} in tui-*|session-*|keeper-*) case ${1##*-} in ''|*[!0-9]*) return 1;; esac;; *) return 1;; esac; }
# holders_alive: removes the records of dead holders (and stray files); 0 when one still lives. Only for what the TUI
# shows and for keep_keeper below: the monitor does not end when none is left.
holders_alive() {
  local f p rest alive=1
  for f in "$M"/holders/*; do
    [ -f "$f" ] || continue
    is_holder "$f" || { rm -f "$f"; continue; }
    p="" rest=""
    read -r p rest < "$f" 2>/dev/null || :
    case $p in ''|*[!0-9]*) rm -f "$f"; continue;; esac
    if kill -0 "$p" 2>/dev/null && [ "$(lstart "$p")" = "${rest% *}" ]; then alive=0; else rm -f "$f"; fi
  done
  return $alive
}
# keep_keeper, every tick: the keeper is started again when none runs, as it starts the monitor, so the watch ends only
# when both are gone inside one tick (a killed keeper used to take the monitor with it at its next holder check, and
# nothing watched until some bot's next prompt: lmd42, 2026-10-12). No fork while a keeper record stands: holders_alive
# has just dropped the dead ones, so a record left is a live keeper's. With none (killed, or its record removed), the
# --keep front decides: it starts nothing while keeper.lock is held, after --stop, or where CLAUDE_DISCORD_NO_AUTOSTART is
# set. Not while this side's refused marker stands (as the hooks: only --start clears it), and once a minute at most, on
# the hooks' own last-start clock. fd 9 is closed for it: a keeper holding the monitor's lock would keep every later
# monitor out once this one died.
keep_keeper() {
  local f now last=""
  [ -z "${CLAUDE_DISCORD_NO_AUTOSTART:-}" ] && [ ! -e "$M/$rf" ] || return 0
  for f in "$M"/holders/keeper-*; do [ ! -f "$f" ] || return 0; done
  now=${EPOCHSECONDS:-$(date +%s)}
  { read -r last < "$M/last-start${rf#refused}"; } 2>/dev/null
  case $last in ''|*[!0-9]*) ;; *) [ $((now - last)) -ge 60 ] || return 0;; esac
  printf '%s\n' "$now" > "$M/last-start${rf#refused}" 2>/dev/null
  log "no keeper runs: starting one"
  bash "$0" "$self" --keep "$bot" --detach </dev/null >/dev/null 2>&1 9>&- || :
}
# tick_check, every tick (between passes and inside one): the lock is still this monitor's, the owner did not stop it,
# the holder records are current and a keeper runs.
tick_check() {
  lock_check
  [ ! -e "$M/stopped" ] || finish stopped
  holders_alive || :
  keep_keeper
}
holders_json() {  # sets hj: the holder records as a JSON array, with no fork
  local f b
  hj=""
  for f in "$M"/holders/*; do
    [ -f "$f" ] && is_holder "$f" || continue
    b=${f##*/}; hj="$hj${hj:+,}{\"kind\":\"${b%%-*}\",\"pid\":${b##*-}}"
  done
  hj="[$hj]"
}
# lock_check, every tick and before each post: the lock file still names this process. One removed under a running
# monitor (or replaced by a new file) lets a second monitor start on the new file, so this one leaves, without finish:
# that successor may already own state.json and the holder records. The pid in the file, not [ /dev/fd/9 -ef lock ]: on macOS stat of
# /dev/fd/9 reports another st_dev than the file's (measured, bash 3.2.57), so -ef never holds there.
lock_check() {
  local l=""
  { read -r l < "$M/lock"; } 2>/dev/null
  [ "$l" != "$$" ] || return 0
  [ -z "$child" ] || kill -- -"$child" 2>/dev/null || kill "$child" 2>/dev/null
  # Checked between posts too, so a monitor that lost its lock posts nothing more. What this pass already sent goes into
  # state.json as finish records it, or the next monitor would post it again; but only while the lock file is gone or
  # empty (no successor has read state.json yet): one that holds another pid already started from state.json, and a
  # write now would only clobber its monitor.pid. The holder records stay either way.
  [ -n "$l" ] || [ -z "${posts:-}${inflight:-}" ] || { record_posts; write_state; }
  log "exit reason=lock-lost (the lock file was removed or replaced)"
  exit 0
}
# record_posts: the posts this pass sent, applied to the state (not written). Mid-pass, run_pass's locals are visible
# here. A TERM during a POST lands only once curl is done (bash defers a trap for its foreground pipeline), before the
# post is added to `posts`: curl's own output in post.out says whether it went out, and a 2xx counts as sent.
# The payload of that POST is visible here too: its text goes into the alerts record.
record_posts() {
  if [ -n "${inflight:-}" ]; then
    o=$(< "$M/post.out") 2>/dev/null || o=""
    case ${o##*$'\n'} in 2??) posts="${posts:-}$inflight"$'\x1f'sent$'\x1f'"${payload:-}"$'\n';; esac
  fi
  [ -z "${posts:-}" ] || state=$(printf '%s' "$state" | jq -c --arg results "$posts" --arg now "${ts:-$(now)}" "$apply" 2>/dev/null || printf '%s' "$state")
}
finish() {  # $1 = reason (signal, stopped, no-ledger): kill the pass child, leave a state that reads as stopped, drop the holder records
  trap '' TERM INT HUP   # once: a --stop that TERMs a monitor already leaving on the marker would record its posts twice
  # The group; the pid alone when the signal came before the child's setpgrp.
  [ -z "$child" ] || kill -- -"$child" 2>/dev/null || kill "$child" 2>/dev/null
  [ -z "$tp" ] || kill "$tp" 2>/dev/null
  # The posts already sent are recorded, or a restart would send them again.
  record_posts
  rm -f "$M/pass.out" "$M/post.out"
  # stopped: the marker was met here (a --stop from the other side of a shared home cannot signal this monitor), so the
  # state says whose stop it was, as --stop writes it.
  state=$(printf '%s' "$state" | jq -c --arg now "$(now)" --arg why "$1" '.monitor.pid = null | .monitor.holders = [] | .monitor.stopped_at = $now
    | if $why == "stopped" then .monitor.stopped_by_user = true else . end' 2>/dev/null) && write_state
  # The monitor is being taken down, and no record may outlive it but a keeper's: the keeper lives on to start the next
  # one (--stop TERMs it first).
  for f in "$M"/holders/*; do case ${f##*/} in keeper-*) ;; *) rm -f "$f";; esac; done
  log "exit reason=$1"
  exit 0
}
trap 'finish signal' TERM INT HUP

# post <payload JSON>: one message to the alert channel with the manager
# bot's token, read at POST time and sent on stdin, never argv, with the
# ledger's local env (the proxy). Sets p_code (and p_retry for a 429). A 429
# with retry_after under 10 s is waited out once; anything else failed is
# left for the next pass (the caller keeps `posted` as it was).
post() {
  local tok="" line out try ra
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in DISCORD_BOT_TOKEN=*) tok=${line#DISCORD_BOT_TOKEN=}; tok=${tok%$'\r'}; break;; esac
  done 2>/dev/null < "$dir/.env"
  # The path, never the token: a missing token is the one failure curl cannot report.
  [ -n "$tok" ] || { p_code="000 (no DISCORD_BOT_TOKEN in $dir/.env)" p_retry=""; return 1; }
  for try in 1 2; do
    p_retry=""
    # Into post.out, which curl itself writes, not a $(...): finish reads it when a TERM came during the POST.
    printf 'Authorization: Bot %s\n' "$tok" | env ${local_env[@]+"${local_env[@]}"} curl -s --max-time 10 -w '\n%{http_code}' \
      -X POST -H @- -H 'Content-Type: application/json' --data-binary "$1" \
      "https://discord.com/api/v10/channels/$alert_channel/messages" > "$M/post.out" 2>/dev/null 9>&-
    out=$(< "$M/post.out") 2>/dev/null || out=""
    p_code=${out##*$'\n'}
    case $p_code in ''|*[!0-9]*) p_code=000;; esac
    case $p_code in 2*) return 0;; esac
    [ "$p_code" = 429 ] || return 1
    ra=$(printf '%s' "${out%$'\n'*}" | jq -r '.retry_after // 99' 2>/dev/null) || ra=99
    p_retry=$ra
    [ "$try" = 1 ] && awk -v r="$ra" 'BEGIN { exit !(r + 0 < 10) }' || return 1
    # Waited on, as the tick sleep is: a TERM meanwhile runs at once (finish kills it).
    sleep "$ra" 9>&- & tp=$!; wait "$tp"; tp=""
  done
  return 1
}

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
      perl -e "$pg" env ${envs[@]+"${envs[@]}"} "$HOME/.local/bin/claude-discord" health --all --json --patch > "$M/pass.out" 2>/dev/null < /dev/null 9>&- &
    elif [ "$t" = first ]; then
      perl -e "$pg" ssh -o BatchMode=yes -o ConnectTimeout=8 "$host" "$remote" > "$M/pass.out" 2>/dev/null < /dev/null 9>&- &
    else
      perl -e "$pg" ssh -o BatchMode=yes -o ConnectTimeout=8 -o ControlPath=none "$host" "$remote" > "$M/pass.out" 2>/dev/null < /dev/null 9>&- &
    fi
    child=$! k0=$k
    while kill -0 "$child" 2>/dev/null; do
      k=$((k + 1))
      if [ $((k - k0)) -gt "$cap_n" ]; then
        kill -- -"$child" 2>/dev/null || kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; child="" h_rc=124
        log "host $host no answer within ${cap}s"
        return 0
      fi
      # One counter for the whole pass, not per host: however many hosts are
      # slow, the tick's checks (the lock, a --stop, the keeper) come every tick.
      [ $((k % tick_n)) != 0 ] || tick_check
      sleep "$step" 9>&-
    done
    wait "$child" 2>/dev/null; h_rc=$?; child=""
    [ "$h_rc" = 255 ] && [ "$host" != local ] && [ "$t" = first ] || return 0
    log "host $host ssh-failed rc=255 (retried with ControlPath=none)"
  done
}

# run_cmd <host> <remote command> <project> <bot> (1.19.0): one automatic recover, `bot <bot> recover --yes`, run as
# run_host runs health: its own process group, polled, the tick's checks kept, cut at the cap (c_rc 124). Locally the
# shim from the bot's project; on a host over ssh with the ledger line's env words (h_envs), as its health ran. Its
# output is not kept: whether the bot answers is the next pass's to say, and the bot's recover.log has the line.
run_cmd() {
  local k0 e="" l
  if [ "$1" = local ]; then
    perl -e "$pg" env ${local_env[@]+"${local_env[@]}"} bash -c 'cd -- "$1" && exec "$2" bot "$3" recover --yes' _ "$3" "$HOME/.local/bin/claude-discord" "$4" \
      >/dev/null 2>&1 < /dev/null 9>&- &
  else
    # This host's env words, no here-string (bash 3.2 writes those to TMPDIR): the first line naming it.
    l=$'\n'$h_envs; l=${l#*$'\n'"$1"$'\x1f'}; [ "$l" = $'\n'"$h_envs" ] || e=${l%%$'\n'*}
    perl -e "$pg" ssh -o BatchMode=yes -o ConnectTimeout=8 "$1" "${e:+env $e}$2" >/dev/null 2>&1 < /dev/null 9>&- &
  fi
  child=$! k0=$k
  while kill -0 "$child" 2>/dev/null; do
    k=$((k + 1))
    if [ $((k - k0)) -gt "$rcap_n" ]; then
      kill -- -"$child" 2>/dev/null || kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; child="" c_rc=124
      return 0
    fi
    [ $((k % tick_n)) != 0 ] || tick_check
    sleep "$step" 9>&-
  done
  wait "$child" 2>/dev/null; c_rc=$?; child=""
}

# The reducer: (state, this pass's host results) -> the new state, the log
# events and the messages to post. One jq program, so every rule of "what
# counts as a real failure" is in one place:
#   - a verdict that changes restarts its `since`;
#   - a finding is posted once it has held for its hold time and differs
#     from what the channel was last told (`posted`);
#   - the first ok or busy after a posted finding posts the recovery line;
#   - noreach is never posted; a laptop's hostdown is never posted;
#   - while a host is noreach, hostdown or blind its bots are frozen;
#   - a project whose health crashed (an `error` entry) is blind for the bots
#     it had, which are kept, never dropped; one with no bot known yet gets an
#     entry of its own (key host|project|-, no `bot`), so it alerts too;
#   - a bot that left its host's answer is dropped and logged, not announced;
#   - a host that left the ledger is kept for a day (left_s), frozen with its
#     bots and their `posted`, so a brief removal posts nothing again; then it
#     is dropped with its bots, logged, not announced;
#   - (1.19.0) a stale session in a host's answer (a plugin server whose state dir is gone) is an entry of its own,
#     key host|stale|<job or pid>, posted at once, healed (its recovery posted) once it left the answer;
#   - (1.19.0) a bot still down a pass after its [down] went out is recovered: an R line, at most every 30 minutes per
#     bot, never the manager itself, never on a frozen host, not with MONITOR_RECOVER=no.
# Input, raw lines: the state JSON, then two lines per host, "<host> US <laptop> US <exit status> US <display name> US
# <env key names, space-separated>" and the answer of the host with its newlines made spaces (still valid JSON when it was).
# Output lines: "S<state JSON>", "N<bot count>", "E<event>", "O<scope US key US kind US verdict US payload JSON>",
# "R<key US host US subject US remote command US project US bot>".
reduce='
def hold: {"down": 300, "duplicate": 300, "unreachable": 300, "throttled": 1800, "apierror": 1800,
           "stale": 0, "nostate": 0, "patchfail": 0, "hostdown": 1800, "blind": 300, "stale-session": 0};
def good: . == "ok" or . == "busy";
def short($home): if $home != "" and startswith($home + "/") then "~" + .[($home | length):] else . end;
# A path with anything but plain characters goes in double quotes, with what the shell would still expand escaped.
def cdp: (.home // "") as $h | (.project | short($h)) as $s
  | if ($s | test("^[A-Za-z0-9._/~+-]+$")) then $s else "\"" + (.project | gsub("(?<c>[\\\\\"$`])"; "\\\(.c)")) + "\"" end;
# A bot name with anything but plain characters goes in single quotes (wrap below escapes them again for ssh).
def qbot: .bot | if test("^[A-Za-z0-9._+-]+$") then . else "\u0027" + gsub("\u0027"; "\u0027\\\u0027\u0027") + "\u0027" end;
def cd: if .host == "local" then "claude-discord" else "~/.local/bin/claude-discord" end;
# A remote command goes in single quotes for the local shell that pastes it; the remote shell then reads what cdp quoted.
def wrap($e): if $e.host == "local" then . else "ssh \($e.host) \u0027\(gsub("\u0027"; "\u0027\\\u0027\u0027"))\u0027" end;
def fix: . as $e
  | if   .verdict == "down"        then ("cd \(cdp) && \(cd) bot \(qbot) recover" | wrap($e))
    elif .verdict == "stale-session" then ((if (.job // "") != "" then "claude stop \(.job)" else "kill \(.pid)" end) | wrap($e))
    elif .verdict == "stale"       then ("cd \(cdp) && \(cd) bot \(qbot) recover" | wrap($e))
    elif .verdict == "duplicate"   then (if .host == "local" then "" else "on \(.host): " end) + "claude agents, then claude stop <id> for the copy that is not the bot\u0027s"
    elif .verdict == "unreachable" then "check DISCORD_BOT_TOKEN in the bot\u0027s state dir, ~/.claude-discord/projects/\(.project | gsub("[^A-Za-z0-9]"; "-"))/bots/\(.bot)/.env, and the bot\u0027s channel permissions"
    elif .verdict == "nostate"     then (if .host == "local" then "" else "on \(.host): " end) + "claude agents by hand; the daemon is unwell"
    elif .verdict == "throttled" or .verdict == "apierror" then ("cd \(cdp) && \(cd) health" | wrap($e))
    elif .verdict == "patchfail"   then ("\(cd) update" | wrap($e)) + "; still failing means the patch needs a claude-discord fix"
    elif .verdict == "hostdown"    then "ssh -o BatchMode=yes -o ConnectTimeout=8 -o ControlPath=none \(.host) \u0027echo up\u0027"
    # A crashed project: its own health run shows why. A host without a document: is claude-discord there at all.
    elif .verdict == "blind" and .project != null then ("cd \(cdp) && \(cd) health" | wrap($e))
    elif .verdict == "blind"       then ("~/.local/bin/claude-discord --version" | wrap($e)) + ", then setup or update there"
    else "" end;
def labels: if $lang == "en" then {reason: "reason", fix: "fix"} else {reason: "사유", fix: "복구"} end;
def subject: (.home // "") as $h
  | if .bot then "\(.bot) on \(.name) (\(.project | short($h)))" elif .project then "\(.name) (\(.project | short($h)))" else .name end;
# The owner to mention: a Discord id is digits only, so anything else (a hand-edited config) mentions nobody, logged.
# tostring: an id written as a JSON number must not make the reducer fail every pass.
def owner: (.owner_id // "") | tostring | if test("^[0-9]+$") then . else "" end;
def finding_text: labels as $l
  | ((if owner != "" then "<@\(owner)> " else "" end)
     + "[\(.verdict)] \(subject)\n\($l.reason): \(.detail)\n\($l.fix): \(.fix)") | .[0:1900];
# The recovery line has no label, so it reads the same in both languages.
def recovery_text: ((($now_s - (.posted_since_s // $now_s)) / 60) | floor) as $m
  | (if .posted == "stale-session" then "[recovered] \(subject): the stale session is gone after \($m)m"
     else "[recovered] \(subject): answering again after \($m)m (was \(.posted))" end) | .[0:1900];
def payload($kind): if $kind == "finding"
  then {content: finding_text, allowed_mentions: (if owner != "" then {users: [owner]} else {parse: []} end)}
  else {content: recovery_text, allowed_mentions: {parse: []}} end;
# group_payload: one message for several bots of one host (an array of entries), each distinct owner mentioned once.
# Whole entries only, as many as fit in 1900 characters; the bots past that are named in one last line, so none is dropped
# unseen (their `posted` is set with the rest).
def fit($head; $es; $names): ([range($es | length; -1; -1)] | map(. as $n | $head + ($es[0:$n] | join("\n"))
    + (if $n < ($es | length) then "\n… and \(($es | length) - $n) more: " + ($names[$n:] | join(", ")) else "" end))
  | map(select(length <= 1900)) | first) // ($head | .[0:1900]);
def group_payload($kind): labels as $l | (map(owner) | map(select(. != "")) | unique) as $os
  | (map((.home // "") as $h | "\(.bot) (\(.project | short($h)))")) as $who
  | if $kind == "finding"
    then {content: fit(($os | map("<@\(.)> ") | join("")) + "[down] \(length) bots on \(.[0].name)\n";
                       [range(length) as $i | "\($who[$i])\n\($l.reason): \(.[$i].detail)\n\($l.fix): \(.[$i].fix)"]; map(.bot)),
          allowed_mentions: (if ($os | length) > 0 then {users: $os} else {parse: []} end)}
    else {content: fit("[recovered] \(length) bots on \(.[0].name): answering again (was down)\n";
                       [range(length) as $i | "\($who[$i]) after \(((($now_s - (.[$i].posted_since_s // $now_s)) / 60) | floor))m"]; map(.bot)),
          allowed_mentions: {parse: []}} end;
# observe: fold one observation into an entry; `since` moves only when the verdict changes (or is missing, as in a
# state an older monitor or a hand wrote: due counts from it, and a reducer that fails fails every pass).
def observe($v; $d; $meta): (. // {}) as $o
  | $o + $meta + {verdict: $v, detail: $d}
  | if ($o.verdict // null) != $v or ($o.since_s | type) != "number" then . + {since: $now, since_s: $now_s} else . end
  | . + {fix: fix};
# warn_only: a finding the channel is not told when it appears: never posted at all (noreach, hostdown of a laptop) or
# only once it has held for half an hour (throttled, apierror, hostdown). The pass that first sees one records it in
# `alerts` as not_posted, so the Alerts tab of the TUI shows what the channel was never told. `unknown` (a bot with no
# token or channel) is not a finding. (No apostrophe in these comments: the program is one single-quoted string.)
def warn_only: .verdict != "unknown" and (hold[.verdict] == null or hold[.verdict] >= 1800 or (.verdict == "hostdown" and .laptop == true));
def due:
  if (.verdict | good) and (.posted // null) != null then "recovery"
  elif hold[.verdict] != null and ((.verdict == "hostdown" and .laptop == true) | not)
       and (.posted // null) != .verdict and ($now_s - .since_s) >= hold[.verdict] then "finding"
  else null end;

# host_step($r): one host result folded into {state, events}. $r.bad, when set, is why its document could not be read.
def host_step($r):
    ($r.doc | if type == "object" and (.projects | type) == "array" then . else null end) as $doc
    | ([$doc.projects[]? | .project as $p | .bots[]? | . + {project: $p}]) as $bots
    # hostdown is a failure of ssh itself, so never local: a local health that exits 255, or a local laptop past the cap
    # (a hung health on a Mac manager), is blind and alerts.
    | (if $r.host != "local" and ($r.rc == 255 or ($r.rc == 124 and $r.laptop)) then "hostdown"
       elif $doc == null or $r.rc != 0 then "blind"
       elif ($bots | length) > 0 and all($bots[]; .verdict == "noreach") then "noreach"
       else "ok" end) as $reach
    | (if $reach == "hostdown" or $reach == "blind" then $reach
       elif ($doc.patch.rc // 0) != 0 then "patchfail"
       else $reach end) as $hv
    | (if $hv == "hostdown" and $r.rc == 124 then "no answer from \($r.host) within the per-host limit (a laptop: asleep behind its tunnel?)"
       elif $hv == "hostdown" then "ssh to \($r.host) failed (exit 255), also with ControlPath=none"
       elif $hv == "blind" and $r.rc == 124 then "\($r.host) connected but health --all did not finish within the per-host limit"
       elif $hv == "blind" and $r.bad != null then "health --all on \($r.host) printed a document of the wrong shape (exit \($r.rc)): \($r.bad)"
       elif $hv == "blind" and $doc != null then "health --all on \($r.host) printed its document but exited \($r.rc)"
       elif $hv == "blind" then "\($r.host) answered without a health document (exit \($r.rc)): claude-discord is missing there or older than health --all"
       elif $hv == "patchfail" then (($doc.patch.output // "") | gsub("\n"; " | "))
       elif $hv == "noreach" then "\($r.host) cannot reach Discord"
       else "" end) as $hd
    | (.state.hosts[$r.host].verdict // null) as $was
    | .state.hosts[$r.host] |= observe($hv; $hd;
        {host: $r.host, name: (if $r.host == "local" then ($doc.host // (.name // "local")) else $r.host end),
         laptop: $r.laptop, reach: $reach, owner_id: $mowner, checked: $now, display: $r.display, env: $r.env}
        + (if $doc != null then {hostname: ($doc.host // ""), version: ($doc.version // "?"), patch: (if $doc.patch == null then "-" elif ($doc.patch.rc // 0) == 0 then "ok" else "fail" end)} else {} end))
    | (if $was != $hv and ($was != null or ($hv | good | not)) then .events += ["transition \($r.host)|- \($was // "new")->\($hv)"] else . end)
    | if $reach != "ok" then .
      else
        ($doc.stale_sessions // [] | map(. + {k: "\($r.host)|stale|\(if (.job // "") != "" then .job else (.pid | tostring) end)"})) as $stale
        | (($bots | map("\($r.host)|\(.project)|\(.bot)")) + ($stale | map(.k))) as $present
        | ([$doc.projects[] | select(.error != null) | {(.project | tostring): (.error | tostring)}] | add // {}) as $errs
        | reduce $bots[] as $b (.;
            "\($r.host)|\($b.project)|\($b.bot)" as $k
            | (.state.bots[$k].verdict // null) as $bw
            | .state.bots[$k] |= observe($b.verdict; ($b.detail // "");
                {host: $r.host, name: (if $r.host == "local" then ($doc.host // "local") else $r.host end),
                 project: $b.project, bot: $b.bot, home: ($doc.home // ""), owner_id: ($b.owner_id // ""), servers: ($b.servers // ""),
                 # What health 1.11.0 adds, for the TUI. An older claude-discord on that host sends none: null, shown as "-".
                 channel: ($b.channel // null), channel_name: ($b.channel_name // null), last_message_at: ($b.last_message_at // null),
                 access: ($b.access // null),
                 # 1.11.1: the bot mode (the name of each access group travels inside `access`); null from an older host.
                 mode: ($b.mode // null),
                 # 1.14.0: its Discord username (the TUI says when it is not the bot name); null from an older host.
                 discord_name: ($b.discord_name // null)})
            | if $bw != $b.verdict and ($bw != null or ($b.verdict | good | not)) then .events += ["transition \($k) \($bw // "new")->\($b.verdict)"] else . end)
        # Stale sessions (1.19.0): no bot, the dead state dir as its project, the owner of the manager, the job to stop.
        | reduce $stale[] as $s (.;
            (.state.bots[$s.k].verdict // null) as $bw
            | .state.bots[$s.k] |= observe("stale-session";
                "plugin server pid \($s.pid)\(if ($s.job // "") != "" then " of job \($s.job)" else "" end) runs for \($s.state_dir), which no longer exists: it holds no token and never logs in";
                {host: $r.host, name: (if $r.host == "local" then ($doc.host // "local") else $r.host end),
                 project: $s.state_dir, home: ($doc.home // ""), owner_id: $mowner, job: ($s.job // ""), pid: $s.pid})
            | if $bw != "stale-session" then .events += ["transition \($s.k) \($bw // "new")->stale-session"] else . end)
        # A crashed project with no entry at all here (crashed on first sight): an entry of its own, or it would vanish.
        | reduce ($errs | keys[]) as $p (.;
            if any(.state.bots[]; .host == $r.host and .project == $p) then .
            else "\($r.host)|\($p)|-" as $k
              | .state.bots[$k] = ({} | observe("blind"; $errs[$p];
                  {host: $r.host, name: (if $r.host == "local" then ($doc.host // "local") else $r.host end),
                   project: $p, home: ($doc.home // ""), owner_id: $mowner}))
              | .events += ["transition \($k) new->blind"] end)
        # The bots a crashed project had: blind with its error, every other field as last seen.
        | reduce ([.state.bots | to_entries[] | select(.value.host == $r.host and $errs[.value.project // ""] != null) | .key][]) as $k (.;
            (.state.bots[$k].verdict // null) as $bw
            | .state.bots[$k] |= observe("blind"; $errs[.project]; {})
            | if $bw != "blind" then .events += ["transition \($k) \($bw // "new")->blind"] else . end)
        | ([.state.bots | to_entries[] | select(.value.host == $r.host and $errs[.value.project // ""] == null
              and ((.key as $k | $present | index($k)) == null)) | .key]) as $left
        # A project entry the channel was told about reads ok once its project answers, so its recovery is
        # posted; it is dropped on a later pass, once that went out.
        | .state.bots as $sb | ([$left[] | select(. as $k | $sb[$k] | .bot == null and .posted != null)]) as $healed
        | reduce $healed[] as $k (.; .events += ["transition \($k) \(.state.bots[$k].verdict)->ok"] | .state.bots[$k] |= observe("ok"; ""; {}))
        | ($left - $healed) as $gone
        | .events += ($gone | map("drop \(.)"))
        | .state.bots |= with_entries(select(.key as $k | ($gone | index($k)) == null))
      end;

[inputs] as $in
| ($in[0] | fromjson) as $old
| [range(1; $in | length - 1; 2) as $i | ($in[$i] | split("\u001f")) as $h
   | {host: $h[0], laptop: ($h[1] == "true"), rc: ($h[2] | tonumber), display: ($h[3] // ""), env: (($h[4] // "") | split(" ")),
      doc: ($in[$i + 1] | try fromjson catch null)}] as $res
# A document that parses but has another shape inside (an older or newer claude-discord, a broken shim) makes
# host_step raise: that host alone is blind, with the error (capped, it may quote the document); the rest still count.
| reduce $res[] as $r ({state: $old, events: []};
    . as $acc | try host_step($r) catch ((tostring | .[:200]) as $e | $acc | host_step($r + {doc: null, bad: $e})))
# A host that left the ledger keeps its entry, its bots and what the channel was told for a day (left_s, frozen below):
# back within it (a hand edit undone, a line lost for a pass) it posts nothing it already posted. Then it goes, with its bots.
| ($res | map(.host)) as $ledger
| ([.state.hosts | to_entries[] | select(.value.left_s == null and (.key as $h | $ledger | index($h)) == null) | .key]) as $hleft
| .state.hosts |= with_entries(if (.key as $h | $ledger | index($h)) == null then .value.left_s = (.value.left_s // $now_s) else .value |= del(.left_s) end)
| ([.state.hosts | to_entries[] | select(.value.left_s != null and $now_s - .value.left_s >= 86400) | .key]) as $hgone
| .state.hosts |= with_entries(select(.key as $h | $hgone | index($h) == null))
| .state.hosts as $hk
| ([.state.bots | to_entries[] | select((.value.host // "") as $h | $hk[$h] == null) | .key]) as $bgone
| .events += ($hleft | map("left \(.)|- (kept a day)")) + ($hgone | map("drop \(.)|-")) + ($bgone | map("drop \(.)"))
| .state.bots |= with_entries(select(.key as $k | $bgone | index($k) == null))
| .state.monitor += {last_pass: $now, next_pass: (($now_s + $every) | floor | todate), pass_s: $pass_s, holders: $holders, post_failed: false,
                     lang: $lang, owner_id: $mowner}
| del(.state.monitor.error)
| .state as $s | .events as $ev
# Bots of a host that is not reachable as a whole, or that left the ledger, are frozen: this pass says nothing about them.
| [$s.hosts | to_entries[] | select(.value.reach != "ok" or .value.left_s != null) | .key] as $frozen
| ([$s.hosts | to_entries[] | select(.value.left_s == null) | {scope: "hosts", key: .key, e: .value}]
   + [$s.bots | to_entries[] | select(.value.host as $h | $frozen | index($h) == null) | {scope: "bots", key: .key, e: .value}]) as $all
# One not_posted record per key and verdict a day, not one per appearance: these verdicts come and go by nature, and a
# bot going between throttled and ok every other pass would fill the 100 records in 17 hours and push every real post
# out. So none when the last record of that key is already a not_posted of the same verdict under a day old.
| ($s.alerts // []) as $kept
| ([$all[] | select(.e.since_s == $now_s and (.e.verdict | good | not) and (.e | warn_only) and (.e | due) != "finding")
    | {ts: $now, key: (if .scope == "hosts" then .key + "|-" else .key end), kind: "finding", verdict: .e.verdict, status: "not_posted", detail: (.e.detail // "")}
    | select(. as $q | ([$kept[] | select(type == "object" and .key == $q.key)] | last) as $p
        | ($p.status == "not_posted" and $p.verdict == $q.verdict and $now_s - ($p.ts | try fromdate catch 0) < 86400) | not)]) as $quiet
| "S" + ($s | .alerts = (((.alerts // []) + $quiet) | .[-100:]) | tojson), "N\([$s.bots[] | select(.bot)] | length)",
  ($ev[] | "E" + .),
  ($all[] | select((.e | due) == "finding" and (.e.owner_id // "" | tostring) != "" and (.e | owner) == "")
   | "Eowner_id of \(.key) is not a Discord id: posted without a mention"),
  ([$all[] | . + {kind: (.e | due)} | select(.kind != null)] as $due
   # Two or more downs among the bots of one host in one pass, or two or more recoveries from down there, go out as ONE
   # message (the sessions of a host tend to fall and come back together); its key field lists their keys, RS-separated.
   | ($due | map(select(.scope == "bots" and .e.bot != null and (if .kind == "finding" then .e.verdict else .e.posted end) == "down"))
      | group_by([.e.host, .kind]) | map(select(length > 1))) as $groups
   | ([$groups[][].key]) as $grouped
   | ($due[] | select(.key as $k | $grouped | index($k) | not)
      | "O" + ([.scope, .key, .kind, (if .kind == "finding" then .e.verdict else .e.posted end), (.kind as $kind | .e | payload($kind) | tojson)] | join("\u001f"))),
     ($groups[] | "O" + (["bots", (map(.key) | join("\u001e")), .[0].kind, "down", (.[0].kind as $kind | map(.e) | group_payload($kind) | tojson)] | join("\u001f")))),
  # A bot the channel was told is down and still is (two passes at least: the hold, then this one) is recovered, once
  # in 30 minutes; never the manager itself (a session cannot recover its own bot), never with MONITOR_RECOVER=no.
  ($all[] | select($recover == "yes" and .scope == "bots" and .e.bot != null and .e.verdict == "down" and .e.posted == "down"
                   and ($now_s - (.e.recover_s // 0)) >= 1800
                   and ((.e.host == "local" and .e.bot == $manager and .e.project == $mproj) | not))
   | "R" + ([.key, .e.host, (.e | subject), "cd \(.e | cdp) && ~/.local/bin/claude-discord bot \(.e | qbot) recover --yes", .e.project, .e.bot] | join("\u001f")))
'
# apply: the POST results back into the state. A sent finding sets `posted`
# (what makes a restart, and the next pass, quiet); a sent recovery clears it;
# a failed one changes nothing, so the next pass tries again.
# Input lines: "<scope> US <key> US <kind> US <verdict> US <status> US <payload JSON>" (the payload may be missing), and for
# a recover (1.19.0) " US <its exit status>" after it: its time and status go on the bot (recover_s, recover_rc) whatever
# became of the post, so a recover whose post failed is not run again before its 30 minutes.
apply='
# A grouped post (keys RS-separated) counts for each of its bots: `posted` stays per bot. Each result becomes one
# `alerts` record with what the TUI shows: the reason (`detail`; for a recovery, how long it took) and the posted
# text. A sent post went out on a retry when the last record of its key is a failed one. A POST that keeps failing is
# recorded once, not once a pass: 100 records are kept, and a Discord outage must not push a day of history out.
($results | split("\n") | map(select(. != "") | split("\u001f") | {scope: .[0], key: (.[1] | split("\u001e")[]), kind: .[2], verdict: .[3], status: .[4],
   text: (.[5] // "" | try (fromjson | .content) catch null), rc: (.[6] // "" | tonumber? // null)})) as $rs
| ($now | fromdate) as $now_s
| reduce $rs[] as $r (.;
    (if $r.scope == "hosts" then $r.key + "|-" else $r.key end) as $ak
    | (.[$r.scope][$r.key] // {}) as $e
    | ((.alerts // []) | map(select(type == "object" and .key == $ak)) | last) as $prev   # a hand-edited element that is no record: skipped, never an error every pass
    | (if $r.kind == "recover" then .[$r.scope][$r.key] |= (. + {recover_s: $now_s, recover_rc: $r.rc})
       elif $r.status != "sent" then .
       elif $r.kind == "finding" then .[$r.scope][$r.key] |= (. + {posted: .verdict, posted_at: $now, posted_since_s: .since_s})
       else .[$r.scope][$r.key] |= del(.posted, .posted_at, .posted_since_s) end)
    | if $r.status == "failed" and $prev.status == "failed" and $prev.kind == $r.kind and $prev.verdict == $r.verdict then .
      else .alerts += [{ts: $now, key: $ak, kind: $r.kind, verdict: $r.verdict, status: $r.status,
                        detail: (if $r.kind == "recovery" then "back after \((($now_s - ($e.posted_since_s // $now_s)) / 60) | floor)m"
                                 elif $r.kind == "recover" then "exit \($r.rc // "?")" else ($e.detail // "") end)}
                       + (if $r.status == "sent" then {text: $r.text} else {} end)
                       + (if $r.status == "sent" and $prev.status == "failed" then {retried: true} else {} end)] end)
| .alerts |= .[-100:]
| .monitor.post_failed = any($rs[]; .status == "failed")
'
run_pass() {
  local t0=$SECONDS now_s start line w host laptop hname hkeys remote doc results="" out l rest hosts=0 nb=0 mowner ts="" hj k=0 \
    lang scope key lk knd verdict payload st posts="" findings=0 posted=0 inflight="" recover recs="" h_envs="" c_rc rhost rsubj rcmd rproj rbot txt
  local envs=() has_local=""
  local_env=()   # a ledger that lost its local line: POSTs with the monitor's own env
  rotate
  # The pass's time is its start: holds then count between pass starts, which are PASS apart, whatever the hosts take.
  read -r now_s start < <(date -u '+%s %Y-%m-%dT%H:%M:%SZ')
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}   # a ledger saved with CRLF line endings
    set -f; set -- $line; set +f
    host=${1:-}; [ $# = 0 ] || shift
    case $host in ''|'#'*) continue;; esac
    # An ssh host name, never an option: the ledger is the owner's file, but a leading "-" would be read by ssh as a flag.
    case $host in -*|*[!A-Za-z0-9._@-]*) log "ledger: host skipped (not a plain ssh host name)"; continue;; esac
    laptop=false; [ "${1:-}" != laptop ] || { laptop=true; shift; }
    envs=() hname="" hkeys=""
    for w in "$@"; do
      # name=<display> (lower case, the one reserved word of that shape) is what the TUI calls this host: it is never an
      # environment word, for env here or over ssh. Control characters go: US and a newline are this pass's separators.
      case $w in name=*) hname=${w#name=}; hname=${hname//[[:cntrl:]]/}; continue;; esac
      [[ $w =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || { log "ledger: $host: a word that is not KEY=VALUE was skipped"; continue; }
      hkeys="$hkeys${hkeys:+ }${w%%=*}"   # the names only, for the TUI: a value (a proxy URL may hold a password) never reaches state.json
      # A proxy word sets both spellings: curl prefers the lowercase one, which the session's own env may already set.
      case ${w%%=*} in
        HTTPS_PROXY|https_proxy) envs+=("HTTPS_PROXY=${w#*=}" "https_proxy=${w#*=}");;
        HTTP_PROXY|http_proxy) envs+=("HTTP_PROXY=${w#*=}" "http_proxy=${w#*=}");;
        ALL_PROXY|all_proxy) envs+=("ALL_PROXY=${w#*=}" "all_proxy=${w#*=}");;
        NO_PROXY|no_proxy) envs+=("NO_PROXY=${w#*=}" "no_proxy=${w#*=}");;
        *) envs+=("$w");;
      esac
    done
    [ "$host" != local ] || { local_env=(${envs[@]+"${envs[@]}"}); has_local=1; }
    remote="env $([ ${#envs[@]} = 0 ] || printf '%q ' "${envs[@]}")~/.local/bin/claude-discord health --all --json --patch"
    h_envs="$h_envs$host"$'\x1f'"$([ ${#envs[@]} = 0 ] || printf '%q ' "${envs[@]}")"$'\n'   # for a recover on this host (run_cmd)
    run_host
    doc=$(< "$M/pass.out") 2>/dev/null || doc=""
    results="$results$host"$'\x1f'"$laptop"$'\x1f'"$h_rc"$'\x1f'"$hname"$'\x1f'"$hkeys"$'\n'"${doc//$'\n'/ }"$'\n'
    hosts=$((hosts + 1))
  done < "$dir/hosts"
  rm -f "$M/pass.out"
  used=$k   # the steps the hosts took, for the main loop's count (the posts', rare and 10 s a call at most, are not counted)
  read_cfg; holders_json
  ts=$(now)
  out=$(printf '%s\n%s' "$state" "$results" | jq -nrR --arg now "$start" --argjson now_s "$now_s" --arg lang "$lang" --arg mowner "$mowner" \
    --arg recover "$recover" --arg manager "$bot" --arg mproj "$pd_project" \
    --argjson every "$pass" --argjson pass_s "$(( SECONDS - t0 ))" --argjson holders "$hj" "$reduce" 2>/dev/null) ||
    { log "pass failed: the reducer rejected its input"
      # Said in state.json too (the TUI's red bar), or a monitor failing every pass would show its last good pass as current.
      out=$(printf '%s' "$state" | jq -c --arg e "the reducer rejected its input at $ts (monitor.log)" '.monitor.error = $e' 2>/dev/null) && state=$out
      write_state; return 0; }
  while IFS= read -r l; do
    rest=${l#?}
    case $l in
      S*) state=$rest;;
      N*) nb=$rest;;
      E*) log "$rest";;
      O*) set -f; IFS=$'\x1f'; set -- $rest; IFS=$' \t\n'; set +f   # split with no fork: tojson escapes any US in the payload
          scope=$1 key=$2 knd=$3 verdict=$4 payload=$5
          # A --stop is looked for between posts (a POST may take 10 s and more): from then on the rest stay
          # pending, and finish records what was sent before the monitor leaves. The lock likewise (lock_check).
          lock_check; [ ! -e "$M/stopped" ] || finish stopped
          [ "$knd" != finding ] || findings=$((findings + 1))
          lk=$key; [ "$scope" != hosts ] || lk="$key|-"   # the log's key, as the TUI and the spec name a host
          lk=${lk//$'\x1e'/,}   # a grouped post's keys
          # In flight from here until it is in `posts` (finish records a 2xx); post.out emptied first, so an
          # earlier POST's status is never read as this one's.
          : > "$M/post.out"; inflight="$scope"$'\x1f'"$key"$'\x1f'"$knd"$'\x1f'"$verdict"
          if post "$payload"; then
            posted=$((posted + 1)); log "post $lk $verdict $p_code"; st=sent
          else
            log "post $lk $verdict failed $p_code${p_retry:+ retry_after=$p_retry}"; st=failed
          fi
          # One command for both: a trap runs between commands, never inside one, so it sees the post once.
          posts="$posts$inflight"$'\x1f'"$st"$'\x1f'"$payload"$'\n' inflight="";;
      R*) recs="$recs$rest"$'\n';;
    esac
  done < <(printf '%s\n' "$out")
  # The recovers (1.19.0), after this pass's posts: each run, logged, and said in the channel with its exit status.
  while IFS=$'\x1f' read -r key rhost rsubj rcmd rproj rbot; do
    [ -n "$key" ] || continue
    lock_check; [ ! -e "$M/stopped" ] || finish stopped
    run_cmd "$rhost" "$rcmd" "$rproj" "$rbot"
    log "recover $key rc=$c_rc"
    if [ "$c_rc" = 0 ]; then txt="[recover] $rsubj: ran bot recover --yes (exit 0); the next pass says whether it answers"
    elif [ "$c_rc" = 124 ]; then txt="[recover failed] $rsubj: bot recover --yes did not finish within ${rcap}s"
    else txt="[recover failed] $rsubj: bot recover --yes exited $c_rc (its recover.log on that host says why)"; fi
    payload=$(jq -nc --arg c "$txt" '{content: $c[0:1900], allowed_mentions: {parse: []}}')
    : > "$M/post.out"; inflight="bots"$'\x1f'"$key"$'\x1f'"recover"$'\x1f'"down"
    if post "$payload"; then posted=$((posted + 1)); log "post $key recover $p_code"; st=sent
    else log "post $key recover failed $p_code${p_retry:+ retry_after=$p_retry}"; st=failed; fi
    posts="$posts$inflight"$'\x1f'"$st"$'\x1f'"$payload"$'\x1f'"$c_rc"$'\n' inflight=""
  done < <(printf '%s' "$recs")
  rm -f "$M/post.out"
  # A failed apply keeps the state as it was (nothing marked posted: the next pass posts again), never an empty one.
  if [ -n "$posts" ]; then
    out=$(printf '%s' "$state" | jq -c --arg results "$posts" --arg now "$ts" "$apply" 2>/dev/null) && state=$out posts="" ||
      log "pass failed: could not apply the post results"
  fi
  write_state
  # The marker sweep (bin/lib/state.sh) of this machine's recorded projects, when the ledger watches this machine (a
  # local line): never at a session start, which every startup, resume, clear and compact runs. A remote host's
  # markers are its own monitor's; on a shared home, the bots this side's `claude agents` does not list are left.
  if [ -n "$has_local" ] && [ $((SECONDS - swept)) -ge "${sweep%%.*}" ]; then
    swept=$SECONDS
    sweep_recorded 2>/dev/null 9>&- || :
  fi
  log "pass hosts=$hosts bots=$nb findings=$findings posted=$posted $(( SECONDS - t0 ))s"
}

rotate
# This monitor's pid in the lock file (lock_check reads it). By path, truncating: only the lock's holder writes it, and
# --ensure and the lock waiter open it for append and write nothing.
printf '%s\n' "$$" > "$M/lock"
# Start from the kept state (its `posted` is what keeps a restart quiet). A
# state file that is not ours (truncated, another version, another manager)
# starts empty and says so: findings still standing are then posted once more.
state=$(jq -c --arg bot "$bot" 'if type == "object" and .version == 1 and .manager == $bot then . else error("no") end' "$M/state.json" 2>/dev/null) || {
  [ ! -s "$M/state.json" ] || log "state unreadable, starting empty"
  state=$(jq -nc --arg bot "$bot" '{version: 1, manager: $bot, monitor: {}, hosts: {}, bots: {}, alerts: []}')
}
holders_json
state=$(printf '%s' "$state" | jq -c --argjson pid "$$" --arg now "$(now)" --argjson holders "$hj" \
  '.monitor = ((.monitor // {}) + {pid: $pid, started: $now, holders: $holders}) | del(.monitor.stopped_at, .monitor.stopped_by_user)')
write_state
log start
n=$pass_n   # the first pass right after start
while :; do
  [ -f "$dir/hosts" ] || finish no-ledger
  tick_check
  # A pass asked for (monitor --check): now, not when the interval is up, but CHECK_GAP (60 s) after the last pass
  # began at the earliest (n counts the ticks since then): what a finding waits is counted in passes here and in health
  # runs there, and a request every tick would turn their minutes into seconds. A marker met earlier stays and is
  # served then: one pass, however many requests. The marker goes before the pass, so a request made while a pass runs
  # gets one after it. A marker that cannot be removed would mean a pass every tick: said once, then none is looked at
  # until this monitor is started again.
  if [ -z "$stuck" ] && [ "$n" -ge "$gap_n" ] && [ -e "$M/pass-now" ]; then
    if rm -f "$M/pass-now" 2>/dev/null; then n=$pass_n; log "check requested: a pass now"
    else stuck=1; log "check requested, but $M/pass-now cannot be removed: no request is served until the monitor is started again"; fi
  fi
  # Straight back to the tick's checks after a pass: the last in-pass one may be most of a tick old.
  # Passes start PASS apart, not PASS after the last one ended: the ticks its hosts took count, and the first sleep
  # after it is the rest of the tick they ended in.
  if [ "$n" -ge "$pass_n" ]; then
    # claude-discord update changed this file: go on as the new one, within a pass. Same pid, and fd 9 (no close-on-exec)
    # keeps the lock across exec; it re-reads state.json, whose `posted` keeps it from posting again. The file is compared
    # with itself as this process started it (mtime to the sub-second, size, inode), not with state.json by -nt: a
    # future mtime (a clock stepped back, a copied file) would restart every tick, and bash 3.2's -nt counts whole seconds.
    # An empty signature (replaced right now) is no change: never exec a missing file.
    cur=$(sig)
    # A file caught mid-write (git pull unlinks and rewrites it) may be cut off at a line end and still parse, and the
    # exec'd process would die at once: exec it only once its signature has held for a whole pass, if it parses and
    # still holds through the parse; else keep the running code and look again next pass, logging each broken signature
    # once. One that dies anyway is started again by its manager's next prompt (on-prompt) or the TUI.
    if [ -n "$cur" ] && [ "$cur" != "$sig0" ]; then
      if [ "$cur" != "$seen" ]; then seen=$cur; log "monitor.sh changed: restart at the next pass if it holds still"
      elif bash -n "$0" 2>/dev/null && [ "$(sig)" = "$cur" ]; then log "restart: monitor.sh changed"; exec bash "$0" "$self" --locked "$bot"
      elif [ "$cur" != "$bad" ]; then bad=$cur; log "update skipped: monitor.sh does not parse, keeping the running code"; fi
    fi
    run_pass; n=$((used / tick_n)) part=""
    [ $((used % tick_n)) = 0 ] || part=$(awk -v s="$step" -v m=$((tick_n - used % tick_n)) 'BEGIN { print s * m }')
    continue
  fi
  # Waited on, not run in the foreground: a trapped TERM then runs at once, not after up to a tick (finish kills the sleep).
  sleep "${part:-$tick}" 9>&- & tp=$!; wait "$tp"; tp="" part=""
  n=$((n + 1))
done
