# Sourced by every script under hooks/turn/, hooks/peers/ and
# hooks/autoresearchclaw/; never registered on its own. Resolves the current
# bot's identity, channel and mode from $DISCORD_STATE_DIR and provides
# `react` to add a reaction and `peers` to list a dev-manager's peers. No
# `set -e`: a caller under `set -u` must survive every file here being
# missing.

bot_name=""
bot_channel=""
bot_access_ids=""
bot_token=""
bot_mode=""
unset hook_input   # set by hook_session only, never from the environment

# The plugin root, from this file's own location (hooks/lib/discord.sh), with
# symlinks resolved: tools and rules are named by absolute path in the text a
# session reads, so it must be the real install, wherever setup put it.
# cd -P: the hooks are often reached through the project's discord-agents/hooks
# symlink, and a logical `..` from there would land in discord-agents/.
plugin_root=$(cd -P "${BASH_SOURCE[0]%/*}/../.." 2>/dev/null && pwd -P) || plugin_root=""   # ${..%/*}: sourced by path, one fork less than dirname
thread_tool=$plugin_root/tools/thread

# resolve_channel: sets bot_channel to the bot's channel, and bot_access_ids to
# the ids its access.json lets in there (that group's allowFrom, then the
# top-level one; one a line). The channel is the single
# group key in its access.json: the plugin reads that file on every message,
# and moving a bot to another channel is an edit there. Without exactly one
# digits-only key (the file missing or unreadable, no group, or several) the
# bot has no channel (1.18.1: config.env, setup's defaults, is not read at run
# time; it is one file for every bot of the project).
resolve_channel() {
  local out
  bot_channel="" bot_access_ids=""
  # One jq for both answers (a jq start is 10 ms with jq 1.6, and every prompt asks): the channel on the first line,
  # then the ids that channel's group and the top-level allowFrom name, one a line. An allowFrom of the wrong shape
  # costs only the ids, never the channel (try).
  out=$(jq -r '((.groups | objects | keys) // []) as $k
    | (if ($k | length) == 1 and ($k[0] | test("^[0-9]+$")) then $k[0] else "" end) as $ch
    | $ch, try ((.groups[$ch].allowFrom // [])[], (.allowFrom // [])[]) catch empty' "$DISCORD_STATE_DIR/access.json" 2>/dev/null) && [ -n "$out" ] || return 0
  bot_channel=${out%%$'\n'*}
  case $out in *$'\n'*) bot_access_ids=${out#*$'\n'};; esac
}

# proj_state: the project's state dir (config.env, peers.json, checkin/); bots_root: its bot dirs' parent; project_dir:
# the project. Computed once, no fork, from the state dir's shape (1.18.0, bin/lib/state.sh has the layout):
#   ~/.claude-discord/projects/<key>/bots/<bot>          proj_state is up to /bots/, project_dir its `project` file
#   <project>/.claude/discord-agents/<bot>, a symlink    a job whose respawnFlags froze the old path: the link's target, as above
#   <project>/.claude/discord-agents/<bot>, a directory  not moved yet: proj_state is its parent, as before 1.18.0
# A bot is the session its state dir belongs to: a `claude -p` started from a
# bot's shell inherits DISCORD_STATE_DIR, and in another project it is not that
# bot (Claude Code gives every hook CLAUDE_PROJECT_DIR, measured on 2.1.296).
# The bot's own project, or a git worktree of it: a bot started with --worktree
# runs with CLAUDE_PROJECT_DIR set to that worktree. Any other directory, under
# the project or not, is another session.
sd=${DISCORD_STATE_DIR:-}; sd=${sd%/}; project_dir="" proj_state="" bots_root=""
case $sd in
  */.claude/discord-agents/*)
    project_dir=${sd%/.claude/discord-agents/*} proj_state=${sd%/*}; bots_root=$proj_state
    if [ -L "$sd" ]; then
      pd_here=$PWD; { cd -P -- "$sd" 2>/dev/null && sd=$PWD; } || :; cd -- "$pd_here" 2>/dev/null || :
      case $sd in */bots/*) proj_state=${sd%/bots/*}; bots_root=$proj_state/bots;; esac
    fi;;
  */bots/*)
    proj_state=${sd%/bots/*}; bots_root=$proj_state/bots
    { IFS= read -r project_dir < "$proj_state/project"; } 2>/dev/null || :;;
  ?*) proj_state=${sd%/*}; bots_root=$proj_state;;
esac
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
        p=$project_dir; main=""
        while [ -n "$p" ] && ! [ "$p" -ef "${l#worktree }" ]; do case $p in */*) pre=/${p##*/}$pre; p=${p%/*};; *) p="";; esac; done
        [ -n "$p" ] || return 1   # the bot project is not under this repo's main worktree
      elif [ "${l#worktree }$pre" -ef "$CLAUDE_PROJECT_DIR" ]; then return 0; fi;;
    esac
  done <<<"$(git -C "$project_dir" worktree list --porcelain 2>/dev/null)"
  return 1
}
if [ -n "${DISCORD_STATE_DIR:-}" ] && [ -d "$DISCORD_STATE_DIR" ] &&
   { [ -z "${CLAUDE_PROJECT_DIR:-}" ] || [ "$project_dir" -ef "$CLAUDE_PROJECT_DIR" ] || in_bot_worktree; }; then
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
  jq -e --arg id "$id" 'any(.peers[]?; (.bot_id // "" | tostring) == $id)' "$proj_state/peers.json" >/dev/null 2>&1 && return 0
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
    | select(length > 0)' "$proj_state/peers.json" 2>/dev/null
}

# plugin_gate: every hook calls it right after sourcing this file (a tool never
# does: it would read the terminal). Returns 1 when the hook must exit 0 at once.
# Hooks earlier releases wrote into settings files keep running beside the
# plugin's until setup or update strips them (a file it could not rewrite, a
# machine not updated yet), and a hook run twice records a turn twice. So the plugin's
# own hook (CLAUDE_PLUGIN_ROOT set and $0 under it) leaves a marker,
# <state dir>/plugin-sessions/<session id>, on its first run in a session, and
# an old one (run from .claude/discord-agents/hooks/ or ~/.claude-discord/hooks/,
# or with no CLAUDE_PLUGIN_ROOT) does nothing in a session that has one. That
# first run is also the migration: it takes this project's own old entries and
# rule copies out (old-hooks.sh), in a session the plugin is known to be loaded
# in, which setup cannot know. The event it happens in may run both once.
# Cheap on purpose, since it runs on every event: no jq, one [ -e ], and an old
# hook of a bot no plugin hook ever ran for does not even read its stdin.
# A session with no marker yet must also be the bot's own Claude Code process
# (bot_process): a `claude -p` started from the bot's Bash inherits its state
# dir, and was taken for the bot (a turn, a marker, a context) until 1.17.0.
# Only that positive verdict is cached, as the marker.
plugin_gate() {
  local m=${DISCORD_STATE_DIR:-}/plugin-sessions root=${CLAUDE_PLUGIN_ROOT:-} sid old=1 won="" mp="" rc
  [ -n "$bot_name" ] || return 0
  case $0 in
    */.claude/discord-agents/hooks/*|"$HOME"/.claude-discord/hooks/*) ;;
    *) [ -z "$root" ] || case $0 in "$root"/*) old="";; esac ;;
  esac
  if [ -n "$old" ]; then
    [ -d "$m" ] || { bot_process; [ $? != 1 ]; return; }
    hook_session || { bot_process; [ $? != 1 ]; return; }
    [ -e "$m/$sid" ] || { bot_process; [ $? != 1 ]; return; }
    # A marked session whose plugin install is gone again (rolled back) has no
    # plugin hooks left: the old path is all it has, so it runs.
    [ -e "$project_dir/.claude/skills/claude-discord/hooks/hooks.json" ] ||
      [ -e "$HOME/.claude/skills/claude-discord/hooks/hooks.json" ]
    [ $? != 0 ]
    return
  fi
  hook_session || { bot_process; [ $? != 1 ]; return; }
  # The marker holds the pid of the process it was written for: a `claude -p
  # --continue` or `--resume <the bot's session>` reuses the bot's session id
  # in a process of its own, which is decided again (and a respawned bot, a new
  # pid on the same id, is decided again once). Builtins only: no fork.
  if [ -e "$m/$sid" ]; then
    { IFS= read -r mp < "$m/$sid"; } 2>/dev/null || :
    if [ -z "${CLAUDE_PID:-}" ] || [ "$mp" = "$CLAUDE_PID" ]; then
      printf '%s\n' "$mp" 2>/dev/null > "$m/$sid"   # a live session keeps its marker fresh, so the month-old prune never takes it
      return 0
    fi
    bot_process; rc=$?
    [ "$rc" != 0 ] || printf '%s\n' "$CLAUDE_PID" 2>/dev/null > "$m/$sid"
    [ "$rc" != 1 ]
    return
  fi
  bot_process; rc=$?
  [ "$rc" != 1 ] || return 1
  # Open for want of evidence (CLAUDE_PID set, but no record of that process yet: Claude Code 2.1.301 runs
  # SessionStart hooks before it writes the record): this event acts, and nothing is cached.
  [ "$rc" = 0 ] || return 0
  mkdir -p "$m" 2>/dev/null || return 0
  set -C; { printf '%s\n' "${CLAUDE_PID:-}" > "$m/$sid"; } 2>/dev/null && won=1; set +C   # noclobber: of the event's parallel hooks, one migrates
  [ -n "$won" ] || return 0
  find "$m" -type f -mtime +30 -exec rm -f {} + 2>/dev/null   # markers no hook has touched for a month
  . "$plugin_root/hooks/lib/old-hooks.sh" 2>/dev/null && migrate_project
  return 0
}
# hook_stdin: sets input to the hook's stdin: what hook_session read, or a cat
# when it did not run (a builtin read is no cheaper: bash reads a pipe a byte
# per call, 1.5 ms for 500 bytes against cat's 2 ms, 30 ms for 50 kB).
hook_stdin() {
  if [ -n "${hook_input+x}" ]; then input=$hook_input; else input=$(cat 2>/dev/null); fi
}
# bot_process: whether the Claude Code process that ran this hook ($CLAUDE_PID,
# set by Claude Code per process: a child's hooks get the child's pid) is the
# bot's own. 0: it is (its record was found and matched); 1: it is not; 2: no
# evidence either way, so open, uncached. Decided on its
# ~/.claude/sessions/<pid>.json (measured 2.1.296-2.1.301, Linux and macOS
# alike), not on the environment, which a child inherits: a background
# worker's record has kind bg, entrypoint cli and its jobId, which must be
# this job's (${CLAUDE_JOB_DIR##*/}); a record with no jobId is a foreground
# session, the bot (even one started under a bot's environment, CLAUDE_JOB_DIR
# inherited) unless its entrypoint is sdk-cli, a `claude -p` child. On Linux the
# record's procStart must be the process's (field 22 of its stat), or it is a
# dead process's that had this pid: no record of this one. No CLAUDE_PID at all
# (a Claude Code that does not set it): 0, as before 1.17.0, cached as then, so
# the old-entry gate and migration keep working there. No fork: two reads and
# two regexes.
bot_process() {
  local p=${CLAUDE_PID:-} j="" s re
  [ -n "$p" ] || return 0
  case $p in *[!0-9]*) return 2;; esac
  { IFS= read -r -d '' j < "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions/$p.json"; } 2>/dev/null
  [ -n "$j" ] || return 2
  if [ -r "/proc/$p/stat" ]; then
    { IFS= read -r s < "/proc/$p/stat"; } 2>/dev/null || return 2
    s=${s##*) }; set -f; set -- $s; set +f
    re='"procStart"[[:space:]]*:[[:space:]]*"?([0-9]+)'
    [[ $j =~ $re ]] && [ "${BASH_REMATCH[1]}" = "${20:-}" ] || return 2
  fi
  re='"jobId"[[:space:]]*:[[:space:]]*"([^"]*)"'
  if [[ $j =~ $re ]]; then
    [ -n "${CLAUDE_JOB_DIR:-}" ] && [ "${BASH_REMATCH[1]}" = "${CLAUDE_JOB_DIR##*/}" ] || return 1
  else
    re='"entrypoint"[[:space:]]*:[[:space:]]*"sdk-cli"'
    ! [[ $j =~ $re ]] || return 1
  fi
}
# hook_session: sets sid from the hook's stdin JSON and hands the same input
# back on stdin for the hook to read, and in hook_input, which a hook that
# wants it whole takes instead of a second cat (hook_stdin). The top-level
# session_id comes first in the object Claude Code writes, and the leftmost
# match wins.
hook_session() {
  local re='"session_id"[[:space:]]*:[[:space:]]*"([^"/\\]+)"' input
  input=$(cat 2>/dev/null) || input=""
  hook_input=$input
  exec <<<"$input"
  [[ $input =~ $re ]] || return 1
  sid=${BASH_REMATCH[1]}
  case $sid in .*) return 1;; esac
}

# revive_backends: every manager of this machine (records/managers: "<key> <bot>" a line, written by setup, bot rename
# and compat; state.sh write_managers) gets its keeper started, detached, when none runs and its owner did not stop it.
# Any bot's session start and prompt run it, so a backend killed by a restart comes back with the first bot that wakes.
# No file: built once by write_managers (state.sh sourced for that alone: a glob, no fork). No manager, every keeper
# alive: builtins only (no fork on Linux), and silent. A line twice is one backend (keeper_alive cannot see a keeper
# just backgrounded); a line whose ledger or dev-manager mode is gone starts nothing.
# CLAUDE_DISCORD_NO_AUTOSTART turns it off on a machine (the other side of a shared home; the suite).
revive_backends() {
  local mf="$HOME/.claude-discord/records/managers" k b q m bot_name bot_key bot_project seen=" "
  [ -z "${CLAUDE_DISCORD_NO_AUTOSTART:-}" ] || return 0
  [ -f "$mf" ] || { . "$plugin_root/bin/lib/state.sh" && write_managers; } 2>/dev/null || :
  [ -f "$mf" ] || return 0
  while read -r k b || [ -n "$k" ]; do
    [ -n "$k" ] && [ -n "$b" ] || continue
    case $seen in *" $k/$b "*) continue;; esac
    seen="$seen$k/$b "
    q=""; { IFS= read -r q < "$HOME/.claude-discord/projects/$k/project"; } 2>/dev/null || :
    [ -n "$q" ] && [ -f "$HOME/.claude-discord/projects/$k/bots/$b/hosts" ] || continue
    m=""; { read -r m < "$HOME/.claude-discord/projects/$k/bots/$b/mode"; } 2>/dev/null || :
    [ "$m" = dev-manager ] || continue   # a line whose bot left the mode (setup --mode) forks nothing
    bot_name=$b bot_key=$k bot_project=$q
    keeper_alive || ensure_keeper
  done < "$mf"
}
# ensure_keeper: the manager bot's backend (a keeper and its monitor), started detached when none runs. The --keep
# front checks (one keeper per bot; nothing while the owner's --stop marker stands) and returns at once; stdio closed
# and backgrounded, so the hook leaves nothing on Claude Code's pipe. The session is no holder: the backend outlives it.
ensure_keeper() {
  [ -x "$plugin_root/bin/claude-discord" ] || return 0
  # A start that keeps failing (the keeper dies at once) would fork this on every prompt of every bot: at most one
  # attempt a minute per pid namespace. The time is stored as epoch seconds and read with no fork on Linux
  # (EPOCHSECONDS is bash 5; `date` elsewhere). Not --start's or the TUI's: they never come through here.
  local d="$HOME/.claude-discord/records/monitor/$bot_key/$bot_name" f="" now last="" ns=""
  [ ! -L /proc/self/ns/pid ] || { ns=$(readlink /proc/self/ns/pid); ns=${ns//[!0-9]/}; ns=${ns:+.$ns}; }
  f=$d/last-start$ns now=${EPOCHSECONDS:-$(date +%s)}
  { read -r last < "$f"; } 2>/dev/null
  case $last in ''|*[!0-9]*) ;; *) [ $((now - last)) -ge 60 ] || return 0;; esac
  mkdir -p "$d" 2>/dev/null && printf '%s\n' "$now" > "$f" 2>/dev/null
  # Without the calling session's own: the keeper and its monitor outlive it, and any bot's hook starts them, so they keep
  # neither its state dir nor its plugin and project paths. Proxies for the monitor belong in the ledger's per-host words.
  (cd "$bot_project" && env -u DISCORD_STATE_DIR -u CLAUDE_PROJECT_DIR -u CLAUDE_PLUGIN_ROOT -u CLAUDECODE \
    "$plugin_root/bin/claude-discord" monitor --keep "$bot_name" --detach) </dev/null >/dev/null 2>&1 &
}
# keeper_alive: the backend is up, was stopped on purpose (the `stopped` marker) or was refused for good (`refused.<pid namespace id>`,
# this side's own: a monitor this side cannot see), so a prompt starts nothing. A live
# keeper is a holders/keeper-<pid> record whose pid runs `bash <root>/monitor/monitor.sh <wrapper> --keep <bot>`: a pid
# reused by another program or another bot's keeper is none (a same-named manager of another project keeps its own
# records under its key). Linux reads /proc/<pid>/cmdline with no fork (on-prompt
# asks on every prompt); elsewhere one `ps` fork per record.
keeper_alive() {
  local d="$HOME/.claude-discord/records/monitor/$bot_key/$bot_name" f p s a0 a1 a2 a3 a4 ns
  [ ! -e "$d/stopped" ] || return 0
  # The marker is per pid namespace (monitor.sh names it); the readlink fork happens only when some marker exists.
  # Decided: a marker of a namespace that no longer exists is not removed (it costs one readlink per prompt).
  for f in "$d"/refused*; do
    [ -e "$f" ] || break
    ns=""; [ ! -L /proc/self/ns/pid ] || { ns=$(readlink /proc/self/ns/pid); ns=${ns//[!0-9]/}; ns=${ns:+.$ns}; }
    [ ! -e "$d/refused$ns" ] || return 0
    break
  done
  for f in "$d"/holders/keeper-*; do
    p=${f##*/keeper-}
    case $p in ''|*[!0-9]*) continue;; esac
    if [ -d /proc/self ]; then
      a0="" a1="" a2="" a3="" a4=""
      { IFS= read -rd '' a0; IFS= read -rd '' a1; IFS= read -rd '' a2; IFS= read -rd '' a3; IFS= read -rd '' a4; } 2>/dev/null < "/proc/$p/cmdline"
      [[ $a1 == */monitor/monitor.sh && $a3 == --keep && $a4 == "$bot_name" ]] && return 0
    else
      s=$(ps -p "$p" -o command= 2>/dev/null)
      [[ $s == *monitor/monitor.sh*" --keep $bot_name" ]] && return 0
    fi
  done
  return 1
}
