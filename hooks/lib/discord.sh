# Sourced by every script under hooks/turn/, hooks/peers/ and
# hooks/autoresearchclaw/; never registered on its own. Resolves the current
# bot's identity, channel and mode from $DISCORD_STATE_DIR and provides
# `react` to add a reaction and `peers` to list a dev-manager's peers. No
# `set -e`: a caller under `set -u` must survive every file here being
# missing.

bot_name=""
bot_channel=""
bot_token=""
bot_mode=""

# The plugin root, from this file's own location (hooks/lib/discord.sh), with
# symlinks resolved: tools and rules are named by absolute path in the text a
# session reads, so it must be the real install, wherever setup put it.
# cd -P: the hooks are often reached through the project's discord-agents/hooks
# symlink, and a logical `..` from there would land in discord-agents/.
plugin_root=$(cd -P "${BASH_SOURCE[0]%/*}/../.." 2>/dev/null && pwd -P) || plugin_root=""   # ${..%/*}: sourced by path, one fork less than dirname
thread_tool=$plugin_root/tools/thread

# resolve_channel: sets bot_channel to the bot's channel. That is the single
# group key in its access.json: the plugin reads that file on every message,
# and moving a bot to another channel is an edit there, which config.env's
# DISCORD_CHANNEL_ID (written once, at setup) does not follow. Without
# exactly one digits-only key (the file missing or unreadable, no group, or
# several) it is config.env's DISCORD_CHANNEL_ID. The start path in
# claude-discord applies the same rule.
resolve_channel() {
  local config="$DISCORD_STATE_DIR/../config.env" groups line
  bot_channel=""
  if [ -f "$config" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case $line in DISCORD_CHANNEL_ID=*) bot_channel=${line#DISCORD_CHANNEL_ID=}; break;; esac
    done < "$config"
    bot_channel=${bot_channel#\'}
    bot_channel=${bot_channel%\'}
  fi
  groups=$(jq -r '.groups | objects | keys[]' "$DISCORD_STATE_DIR/access.json" 2>/dev/null) || groups=""
  case $groups in
    ''|*[!0-9]*) ;;
    *) bot_channel=$groups ;;
  esac
}

# A bot is the session its state dir belongs to: a `claude -p` started from a
# bot's shell inherits DISCORD_STATE_DIR, and in another project it is not that
# bot (Claude Code gives every hook CLAUDE_PROJECT_DIR, measured on 2.1.296).
# The bot's own project, or a git worktree of it: a bot started with --worktree
# runs with CLAUDE_PROJECT_DIR set to that worktree. Any other directory, under
# the project or not, is another session.
bot_project=${DISCORD_STATE_DIR:-}; bot_project=${bot_project%/}; bot_project=${bot_project%/.claude/discord-agents/*}
# in_bot_worktree: CLAUDE_PROJECT_DIR is the bot project's directory in a
# linked worktree: <worktree><prefix>, prefix being the project's path under the
# first entry, the main worktree (empty when the project is the repo root; git
# prints that entry resolved, so the walk up compares with -ef). Run only when
# the paths differ, so the bot's own sessions fork nothing; a git that fails (a
# $HOME project that is no repo) answers no.
in_bot_worktree() {
  local l p pre="" main=1
  while IFS= read -r l; do
    case $l in "worktree "?*)
      if [ -n "$main" ]; then
        p=$bot_project; main=""
        while [ -n "$p" ] && ! [ "$p" -ef "${l#worktree }" ]; do case $p in */*) pre=/${p##*/}$pre; p=${p%/*};; *) p="";; esac; done
        [ -n "$p" ] || return 1   # the bot project is not under this repo's main worktree
      elif [ "${l#worktree }$pre" -ef "$CLAUDE_PROJECT_DIR" ]; then return 0; fi;;
    esac
  done <<<"$(git -C "$bot_project" worktree list --porcelain 2>/dev/null)"
  return 1
}
if [ -n "${DISCORD_STATE_DIR:-}" ] && [ -d "$DISCORD_STATE_DIR" ] &&
   { [ -z "${CLAUDE_PROJECT_DIR:-}" ] || [ "$DISCORD_STATE_DIR/.." -ef "$CLAUDE_PROJECT_DIR/.claude/discord-agents" ] || in_bot_worktree; }; then
  bot_name=${DISCORD_STATE_DIR%/}; bot_name=${bot_name##*/}
  IFS= read -r bot_mode 2>/dev/null < "$DISCORD_STATE_DIR/mode" || :
fi
# bot_token: read by react() and tools/thread only, on demand.
load_token() {
  local line
  [ -f "$DISCORD_STATE_DIR/.env" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in DISCORD_BOT_TOKEN=*) bot_token=${line#DISCORD_BOT_TOKEN=}; return 0;; esac
  done < "$DISCORD_STATE_DIR/.env"
}

# react <chat_id> <message_id> <url-encoded emoji>
# PUTs the reaction via curl, fully detached (stdout/stderr redirected,
# backgrounded) so the caller returns before the HTTP call finishes. The
# token goes over curl's stdin (-H @-), never argv, so it never shows up in
# ps/cmdline. curl honours HTTPS_PROXY on its own; nothing extra is needed
# for that. A no-op when there is no token (covers a missing state dir too,
# since bot_token stays empty then), no curl on PATH, or either id is not
# all digits -- ids reach here from prompt text, and a non-numeric id could
# turn the URL into a path to a different API endpoint.
react() {
  case $1 in ''|*[!0-9]*) return 0;; esac
  case $2 in ''|*[!0-9]*) return 0;; esac
  [ -n "$bot_token" ] || load_token
  [ -n "$bot_token" ] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  printf 'Authorization: Bot %s\n' "$bot_token" | curl -s -m 5 -X PUT -H @- \
    "https://discord.com/api/v10/channels/$1/messages/$2/reactions/$3/@me" \
    >/dev/null 2>&1 &
  disown 2>/dev/null || :
}

# is_bot_user <user id>: succeeds when that Discord user is a bot. A
# peers.json bot_id is one; any other id is looked up once with GET
# /users/{id} (its `bot` field) and the answer cached as "<id> bot|human"
# in <state dir>/user-kinds, since an account never changes kind. Anything
# unknown -- not an id, no token, no curl, a failed call -- fails: a guard
# built on this must never block on a guess.
is_bot_user() {
  local id=$1 i kind out status k=$DISCORD_STATE_DIR/user-kinds
  case $id in ''|*[!0-9]*) return 1;; esac
  jq -e --arg id "$id" 'any(.peers[]?; (.bot_id // "" | tostring) == $id)' "$DISCORD_STATE_DIR/../peers.json" >/dev/null 2>&1 && return 0
  if [ -f "$k" ]; then
    while read -r i kind; do [ "$i" != "$id" ] || { [ "$kind" = bot ]; return; }; done < "$k"
  fi
  [ -n "$bot_token" ] || load_token
  [ -n "$bot_token" ] && command -v curl >/dev/null 2>&1 || return 1
  out=$(printf 'Authorization: Bot %s\n' "$bot_token" | curl -s -m 3 -w '\n%{http_code}' -H @- "https://discord.com/api/v10/users/$id" 2>/dev/null) || return 1
  status=${out##*$'\n'}
  [ "$status" = 200 ] || return 1
  kind=$(printf '%s' "${out%$'\n'*}" | jq -r 'if (.id // "" | tostring) != "" then (if .bot == true then "bot" else "human" end) else empty end' 2>/dev/null)
  [ -n "$kind" ] || return 1
  printf '%s %s\n' "$id" "$kind" >> "$k" 2>/dev/null
  [ "$kind" = bot ]
}

# peers: prints this bot's peers from the project's peers.json as a JSON
# array of {name, bot_id}, self excluded by name (case-insensitive), entries
# without a name or a numeric bot_id dropped. Prints nothing -- the caller's
# cue to do nothing -- unless this bot is a dev-manager and has a peer.
peers() {
  [ "$bot_mode" = dev-manager ] || return 0
  jq -c --arg self "$bot_name" '[.peers[]? | {name: (.name // "" | tostring), bot_id: (.bot_id // "" | tostring)}
    | select(.name != "" and (.bot_id | test("^[0-9]+$")) and (.name | ascii_downcase) != ($self | ascii_downcase))]
    | select(length > 0)' "$DISCORD_STATE_DIR/../peers.json" 2>/dev/null
}

# plugin_gate: every hook calls it right after sourcing this file (a tool never
# does: it would read the terminal). Returns 1 when the hook must exit 0 at once.
# Hooks earlier releases wrote into settings files keep running beside the
# plugin's where setup cannot remove them (the user-global settings.json, a
# symlinked one), and a hook run twice records a turn twice. So the plugin's
# own hook (CLAUDE_PLUGIN_ROOT set and $0 under it) leaves a marker,
# <state dir>/plugin-sessions/<session id>, on its first run in a session, and
# an old one (run from .claude/discord-agents/hooks/ or ~/.claude-discord/hooks/,
# or with no CLAUDE_PLUGIN_ROOT) does nothing in a session that has one. That
# first run is also the migration: it takes this project's own old entries and
# rule copies out (old-hooks.sh), in a session the plugin is known to be loaded
# in, which setup cannot know. The event it happens in may run both once.
# Cheap on purpose, since it runs on every event: no jq, one [ -e ], and an old
# hook of a bot no plugin hook ever ran for does not even read its stdin.
plugin_gate() {
  local m=${DISCORD_STATE_DIR:-}/plugin-sessions root=${CLAUDE_PLUGIN_ROOT:-} sid old=1 won=""
  [ -n "$bot_name" ] || return 0
  case $0 in
    */.claude/discord-agents/hooks/*|"$HOME"/.claude-discord/hooks/*) ;;
    *) [ -z "$root" ] || case $0 in "$root"/*) old="";; esac ;;
  esac
  if [ -n "$old" ]; then
    [ -d "$m" ] || return 0
    hook_session || return 0
    [ -e "$m/$sid" ] || return 0
    # A marked session whose plugin install is gone again (rolled back) has no
    # plugin hooks left: the old path is all it has, so it runs.
    [ -e "$bot_project/.claude/skills/claude-discord/hooks/hooks.json" ] ||
      [ -e "$HOME/.claude/skills/claude-discord/hooks/hooks.json" ]
    [ $? != 0 ]
    return
  fi
  hook_session || return 0
  if [ -e "$m/$sid" ]; then
    : > "$m/$sid" 2>/dev/null   # a live session keeps its marker fresh (no fork), so the month-old prune never takes it
    return 0
  fi
  mkdir -p "$m" 2>/dev/null || return 0
  set -C; { : > "$m/$sid"; } 2>/dev/null && won=1; set +C   # noclobber: of the event's parallel hooks, one migrates
  [ -n "$won" ] || return 0
  find "$m" -type f -mtime +30 -exec rm -f {} + 2>/dev/null   # markers no hook has touched for a month
  . "$plugin_root/hooks/lib/old-hooks.sh" 2>/dev/null && migrate_project
  return 0
}
# hook_session: sets sid from the hook's stdin JSON and hands the same input
# back on stdin for the hook to read. The top-level session_id comes first in
# the object Claude Code writes, and the leftmost match wins.
hook_session() {
  local re='"session_id"[[:space:]]*:[[:space:]]*"([^"/\\]+)"' input
  input=$(cat 2>/dev/null) || input=""
  exec <<<"$input"
  [[ $input =~ $re ]] || return 1
  sid=${BASH_REMATCH[1]}
  case $sid in .*) return 1;; esac
}

# session_pid: the pid of the Claude Code CLI process this hook runs under: a
# process whose argv[0] (never a later argument: a `bash .../claude-proxied
# .../claude/versions/x` wrapper is no session) is .../claude or lies under
# .../claude/versions/, and whose argv[1] is not `daemon`. $CLAUDE_PID first,
# when it names such a process: Claude Code sets it to its own pid for its
# children, so it is exact. Else the nearest such ancestor, three levels at
# most: Claude Code runs a hook directly, through sh -c, or with a
# CLAUDE_CODE_SHELL_PREFIX through two sh -c (sh -c "<prefix> 'sh -c ...'"),
# and dash does not exec the last command. Nearest, and capped: above a --bg
# session sit its --bg-pty-host and `claude daemon`, which never exits, and a
# terminal's own claude may sit above a script that runs a hook by hand.
# Linux reads CLAUDE_PID's /proc cmdline with no fork. Prints nothing when
# there is none.
session_pid() {
  local p=${CLAUDE_PID:-} n=0 a0="" a1=""
  if [[ $p =~ ^[0-9]+$ ]]; then
    if [ -d /proc/self ]; then
      { IFS= read -rd '' a0; IFS= read -rd '' a1; } 2>/dev/null < "/proc/$p/cmdline"
    else
      set -f; set -- $(ps -o args= -p "$p" 2>/dev/null); set +f; a0=${1:-} a1=${2:-}
    fi
    case $a0 in claude|*/claude|*/claude/versions/*)
      [ "$a1" = daemon ] || { printf '%s' "$p"; return 0; };;
    esac
  fi
  p=$PPID
  while [ "$n" -lt 3 ] && [ "${p:-0}" -gt 1 ]; do
    set -f; set -- $(ps -o ppid= -o args= -p "$p" 2>/dev/null); set +f   # ppid, argv[0], argv[1], ...
    [ $# -ge 2 ] || return 0
    case $2 in claude|*/claude|*/claude/versions/*)
      [ "${3:-}" = daemon ] || { printf '%s' "$p"; return 0; };;
    esac
    p=$1 n=$((n + 1))
  done
}

# ensure_monitor: this session (session_pid) as a holder of its manager bot's
# backend monitor, which is started if none runs. Detached, stdio closed, so the
# hook returns at once and leaves nothing on Claude Code's pipe. No session
# found is said in the bot's health.log, not skipped in silence.
ensure_monitor() {
  local spid
  [ -x "$plugin_root/bin/claude-discord" ] || return 0
  spid=$(session_pid)
  [ -n "$spid" ] || printf '%s %s: no claude session process found (CLAUDE_PID or three levels up): monitor not ensured\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${0##*/}" >> "$DISCORD_STATE_DIR/health.log" 2>/dev/null || :
  # An if, not `[ -z ] || (...) &`: the & would take the whole || list into a forked subshell that keeps the hook's own
  # stdout open until --ensure ends, and Claude Code reads the hook's pipe to EOF.
  if [ -n "$spid" ]; then
    (cd "$bot_project" && "$plugin_root/bin/claude-discord" monitor --ensure "$bot_name" --holder session "$spid") </dev/null >/dev/null 2>&1 &
  fi
}
# monitor_alive: the manager's monitor runs. The pid state.json names in "monitor" (written first there, within the
# first 512 bytes) must be a `bash <root>/monitor/monitor.sh <wrapper> --locked <bot>` command line: a pid reused by
# another program, a zombie or another bot's monitor is no monitor. Linux reads /proc/<pid>/cmdline with no fork
# (on-prompt asks on every prompt); elsewhere one `ps` fork per prompt, the price of telling a reused pid on a Mac.
monitor_alive() {
  local s="" pid a0="" a1="" a2="" a3="" a4="" re='"monitor":\{([^{}]*,)?"pid":([0-9]+)'
  { IFS= read -r -n 512 s < "$HOME/.claude-discord/records/monitor/$bot_name/state.json"; } 2>/dev/null
  [[ $s =~ $re ]] || return 1
  pid=${BASH_REMATCH[2]}
  if [ -d /proc/self ]; then
    { IFS= read -rd '' a0; IFS= read -rd '' a1; IFS= read -rd '' a2; IFS= read -rd '' a3; IFS= read -rd '' a4; } 2>/dev/null < "/proc/$pid/cmdline"
    [[ $a1 == */monitor/monitor.sh && $a3 == --locked && $a4 == "$bot_name" ]]
  else
    s=$(ps -p "$pid" -o command= 2>/dev/null)
    [[ $s == *monitor/monitor.sh*" --locked $bot_name" ]]
  fi
}
