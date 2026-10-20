# sourced by bin/claude-discord: the health verb
if [ "${1:-}" = health ]; then
  shift
  stale_min=15        # an addressed message older than this with no hook record is an alert
  turn_max_min=60     # a turns/<sid> file older than this is a wedged turn, not a live one
  unknown_cap=6       # runs in a row that could not tell, and
  unknown_min_s=1500  # seconds since the first of them (25 min: six passes 5 min apart), before saying so: both, as a
                      # pass can be asked for (monitor --check) and six runs may be seconds apart
  # However long a turn claims to be running, a message left unanswered this
  # long is worth saying out loud. `working` is a claim by the daemon, and a
  # session can sit in that state wedged on a tool call or a prompt that
  # never returns; without a ceiling the hold is unbounded and a bot can be
  # silent for days with nobody told. Deliberately generous -- well past any
  # honest turn -- so it only fires when something is really wrong.
  busy_cap_min=240    # 4 h unanswered ends the hold whatever the session says
  as_json=no timer="" all=no do_patch=no nolog=no
  for a in "$@"; do
    case $a in
      --json) as_json=yes;;
      --all) all=yes;;
      --patch) do_patch=yes;;
      --nolog) nolog=yes;;   # internal: --all's per-project runs write no health.log line and no journal line
      --uninstall-timer) timer=uninstall;;
      *) echo "usage: claude-discord health [--json] | health --all [--json] [--patch] | health --uninstall-timer" >&2; exit 2;;
    esac
  done
  [ "$do_patch" = no ] || [ "$all" = yes ] || { echo "claude-discord: health --patch needs --all" >&2; exit 2; }
  # --all: every project with a state dir (~/.claude-discord/projects/*/project, state.sh proj_arr: a project joins it
  # at its first setup or start after 1.18.0), one document.
  # This is the one command a monitor pass runs per host (locally or over
  # ssh), so with --json it exits 0 whenever it printed the document: over
  # ssh a non-zero status means "no answer from that host", never "a bot has
  # a finding". Each project is judged by this same script run there with
  # --nolog; a project whose folder is missing is reported with an error, never pruned.
  # Before the DISCORD_STATE_DIR fallback below: --all is about the machine,
  # so a bot session's own project must not stand in for the working directory.
  if [ "$all" = yes ]; then
    command -v jq >/dev/null 2>&1 || { echo "claude-discord: health needs jq" >&2; exit 1; }
    docs="" prc=null pout="" any=0
    if [ "$do_patch" = yes ]; then
      # The `patch` verb's own function, in a subshell; stderr only: file and patch name.
      prc=0; pout=$(patch_official 2>&1 >/dev/null) || prc=$?
    fi
    proj_arr
    for p in ${pl[@]+"${pl[@]}"}; do
      # Missing now is not gone for good (a volume not mounted yet, the other side of a shared home): reported, never
      # pruned, so the monitor reads it as blind and its bots stay known. Only the owner removes a key dir.
      proj_dirs "$p"
      if [ ! -d "$p" ]; then
        miss="project folder missing: $p (gone for good: remove $pd_state)"
        if [ "$as_json" = yes ]; then one=$(jq -nc --arg p "$p" --arg e "$miss" '{project: $p, bots: [], error: $e}'); docs=$docs$one$'\n'; else echo "== $p"; echo "$miss"; any=1; fi
        continue
      fi
      if [ "$as_json" = yes ]; then
        orc=0; one=$(cd "$p" 2>/dev/null && "$self_path" health --json --nolog 2>/dev/null </dev/null) || orc=$?
        # A child that printed no array is a crash, not a project without bots: the monitor reads `error` as blind.
        # Two plain assignments: bash 3.2 misreads a quoted jq program inside "$( )" inside double quotes.
        one=$(printf '%s' "${one:-null}" | jq -c --arg p "$p" --arg e "health exited $orc with no document" 'if type == "array" then {project: $p, bots: .} else {project: $p, bots: [], error: $e} end' 2>/dev/null) || one=$(jq -nc --arg p "$p" --arg e "health exited $orc with no document" '{project: $p, bots: [], error: $e}')
        docs=$docs$one$'\n'
      else
        echo "== $p"
        (cd "$p" 2>/dev/null && "$self_path" health --nolog </dev/null) || any=1
      fi
    done
    # Stale sessions (1.19.0): a plugin server whose DISCORD_STATE_DIR no longer exists serves no bot (a session of a bot
    # from before the 1.18 move revived from the agent view, 2026-10-20: no token, so it never logs in, and the agent view
    # shows it running). Found as count_servers finds a server (argv first, then the one environ entry); a path that
    # exists through a link is a bot's. The job is the one of the nearest session above it (sessions/<pid>.json), so the
    # fix can name it. Linux only: on macOS the list is empty (no /proc for the parent walk).
    stale="" proc=${CLAUDE_DISCORD_PROC:-/proc}
    if [ -d "$proc" ] && cands=$(pgrep -x bun 2>/dev/null); then
      for pid in $cands; do
        { mapfile -d '' -t args < "$proc/$pid/cmdline"; } 2>/dev/null || continue   # bash4-ok: reached only where /proc exists
        [ "${#args[@]}" -ge 2 ] && [ "${args[${#args[@]}-1]}" = start ] || continue
        hit=no; for a in "${args[@]}"; do case $a in */discord/*) hit=yes; break;; esac; done
        [ "$hit" = yes ] || continue
        { v=$(grep -aoE '(^|[^A-Za-z0-9_])DISCORD_STATE_DIR=[^[:cntrl:]]*' "$proc/$pid/environ"); } 2>/dev/null || continue
        v=${v#*DISCORD_STATE_DIR=}; v=${v%%$'\n'*}
        [ -n "$v" ] && [ ! -d "$v" ] || continue
        job="" q=$pid
        while [ "${q:-0}" -gt 1 ]; do
          if [ -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions/$q.json" ]; then
            job=$(jq -r '.jobId // ""' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions/$q.json" 2>/dev/null) || job=""; break
          fi
          { st=$(< "$proc/$q/stat"); } 2>/dev/null || break
          st=${st##*) }; q=${st#* }; q=${q%% *}   # past the command name (it may hold spaces): state, then the parent
        done
        stale="$stale$pid"$'\t'"$job"$'\t'"$v"$'\n'
      done
    fi
    if [ "$as_json" != yes ]; then
      while IFS=$'\t' read -r pid job v; do
        [ -n "$pid" ] || continue
        echo "stale session: plugin server pid $pid${job:+ of job $job} runs for $v, which no longer exists: it holds no token and never logs in; $([ -n "$job" ] && echo "claude stop $job" || echo "kill $pid")"
      done <<<"$stale"
      exit "$any"
    fi
    h=$(uname -n); h=${h%%.*}
    printf '%s' "$docs" | jq -s --arg host "$h" --arg home "$HOME" --argjson prc "$prc" --arg pout "$pout" \
      --arg ver "$(plugin_version "$self_root") ($(git -C "$self_root" rev-parse --short HEAD 2>/dev/null || echo nogit))" \
      --arg stale "$stale" \
      '{host: $host, version: $ver, home: $home, patch: (if $prc == null then null else {rc: $prc, output: $pout} end), projects: .,
        stale_sessions: [$stale | split("\n")[] | select(. != "") | split("\t") | {pid: (.[0] | tonumber), job: .[1], state_dir: .[2]}]}'
    exit 0
  fi
  # The working directory decides, and only when it holds no bots does the
  # environment stand in. `refresh` leans on DISCORD_STATE_DIR because a
  # session refreshes ITSELF, but `health` is about a project: measured,
  # running it from another project's directory inside a bot session
  # reported that session's bots instead -- a confident answer about the
  # wrong project. A session whose shell has wandered off its own project
  # still gets the fallback.
  if [ ! -d "$root" ] && [ -n "${DISCORD_STATE_DIR:-}" ]; then
    proj_of_state_dir "$DISCORD_STATE_DIR"   # either shape, a link the move left too
    [ -z "$pd_project" ] || cd "$pd_project" 2>/dev/null || :
    proj_cwd; root=$pd_root proj_state=$pd_state project_dir=$pd_project
  fi

  # Removing a timer an older version installed. Installing one is gone: the
  # owner's rule (2026-10-09) is no OS scheduler -- a systemd unit outlives
  # every session, so a bot thought stopped comes back on the next boot.
  # One unit per project, named after its basename.
  if [ "$timer" = uninstall ]; then
    slug=$(basename "$PWD" | tr -cd 'A-Za-z0-9_-'); slug=${slug:-project}
    unit=claude-discord-health-$slug
    ud=$HOME/.config/systemd/user
    [ -f "$ud/$unit.timer" ] || [ -f "$ud/$unit.service" ] || { echo "claude-discord: no timer was installed for this project"; exit 0; }
    systemctl --user disable --now "$unit.timer" >/dev/null 2>&1 || :
    # Both paths are built from $HOME and a slug of $PWD's basename, and
    # the slug falls back to "project", so neither can be empty; unlink
    # rather than rm, since it can only ever remove one plain file.
    [ -f "$ud/$unit.timer" ] && unlink "$ud/$unit.timer"
    [ -f "$ud/$unit.service" ] && unlink "$ud/$unit.service"
    systemctl --user daemon-reload >/dev/null 2>&1 || :
    echo "claude-discord: removed $unit.timer"
    exit 0
  fi

  [ -d "$root" ] || { echo "claude-discord: no bot set up in $root" >&2; exit 1; }
  command -v jq >/dev/null 2>&1 || { echo "claude-discord: health needs jq" >&2; exit 1; }
  command -v curl >/dev/null 2>&1 || { echo "claude-discord: health needs curl" >&2; exit 1; }
  [ ! -f "$proj_state/config.env" ] || . "$proj_state/config.env"

  now_s=$(date +%s)
  # A Discord id is a snowflake: its top 42 bits are milliseconds since
  # 2015-01-01, so an id alone gives both an age and an ordering with no API
  # call. Ids are ~1.5e18 and bash arithmetic is 64-bit, so this cannot
  # overflow.
  # The id arrives as a decimal STRING (see addressed_ids). Bash arithmetic
  # is 64-bit and a snowflake is ~1.5e18, so this is exact -- unlike jq 1.6,
  # whose doubles are not. A leading zero would be read as octal, so it is
  # stripped; ids never have one, but the guard costs nothing.
  snowflake_s() { local i=${1#"${1%%[!0]*}"}; printf '%s' $(( ((${i:-0} >> 22) + 1420070400000) / 1000 )); }
  is_id() { case ${1:-} in ''|*[!0-9]*) return 1;; esac; return 0; }

  # Counts the plugin servers belonging to one bot. argv FIRST, environ
  # second, and that order is the whole point: every child of a bot session
  # (its shells, its subagents, its hooks) inherits DISCORD_STATE_DIR, so
  # matching on the environment alone counts them all and reports a healthy
  # bot as a duplicate. A server is `bun run --cwd <plugin>/discord/<ver>
  # ... start`, so the argv test is: argv[0] is bun, some argument sits
  # under a .../discord/ directory, and the last argument is `start`. Only
  # then is that pid's environ read, to see WHICH bot it serves. Without a
  # /proc (macOS) the same order runs on ps output, below. Prints "unknown"
  # only when ps itself fails, which the caller treats as "cannot tell",
  # never as zero.
  # The candidate pids, found ONCE per run rather than once per bot.
  # Walking every /proc entry cost ~85 ms per call here (805 processes) and
  # ~300 ms on a busier machine. `pgrep -x bun` narrows it to the handful of
  # processes that could possibly be a plugin server (6 of 820 here) using
  # one C program instead of hundreds of shell reads. Without pgrep, or if it
  # errors, fall back to the full walk -- correctness must not depend on an
  # optional tool.
  # Per RUN, not per bot: the list is a property of the machine, not of a
  # bot, and calling it per bot cost 8 forks where 1 does (measured here:
  # 0.15 s for 8, 0.02 s for 1). It also makes the run self-consistent --
  # every bot is judged against the same instant -- where a per-bot list
  # could count a server for one bot that had already exited for the next.
  # A health run is a snapshot either way; this makes it one snapshot.
  server_cands="" mac_env="" mac_pids="" mac_ok=no
  proc=${CLAUDE_DISCORD_PROC:-/proc}   # the suite points this at a missing path to exercise the macOS count on Linux
  if [ ! -d "$proc" ]; then
    # macOS: argv first here too. -ax, because without it ps lists only
    # processes with a terminal and a --bg server has none (measured on wmac,
    # 2026-10-10: 0 of 1). The argv test on the one-line command: the first
    # word is bun, the last is start, a word sits under .../discord/. Then one
    # more ps with -E for those pids: each line is "<pid> <argv> <environment>".
    # That second call has NO -ax: on real BSD ps -ax ORs with -p and prints the
    # whole table (836 lines on wmac), so every shell and hook of the session
    # that inherits DISCORD_STATE_DIR would count as a server.
    mac_ok=no mac_pids=""
    if mac_ps=$(ps -axww -o pid=,command= 2>/dev/null) && [ -n "$mac_ps" ]; then
      mac_ok=yes
      mac_pids=$(printf '%s\n' "$mac_ps" | awk '{ a0 = $2; sub(/.*\//, "", a0) } a0 == "bun" && $NF == "start" && /\/discord\// { printf "%s%s", (n++ ? "," : ""), $1 }') || mac_pids=""
      [ -z "$mac_pids" ] || mac_env=$(ps -Eww -o pid=,command= -p "$mac_pids" 2>/dev/null) || mac_ok=no
    fi
  fi
  if [ -d "$proc" ]; then
    if command -v pgrep >/dev/null 2>&1 && server_cands=$(pgrep -x bun 2>/dev/null); then
      server_cands=$(printf "$proc/%s/cmdline " $server_cands)
    else
      server_cands=$(printf '%s ' "$proc"/[0-9]*/cmdline)
    fi
  fi

  # $1 = the bot state dir; $2 = the bot's name. A server whose DISCORD_STATE_DIR is the path before the move (a job
  # respawned on it, 1.18.0: <project>/.claude/discord-agents/<bot>, in whatever spelling the start's $PWD had) counts when
  # that path is the bot dir, through the link the move left; the link gone, such a server reads as down (accepted: it
  # would find no .env to reopen either).
  count_servers() {
    local n=0 c pid args a hit l v
    if [ ! -d "$proc" ]; then
      [ "$mac_ok" = yes ] || { printf 'unknown'; return 0; }   # ps itself failed: cannot tell, never zero
      # The token after the argv text: " DISCORD_STATE_DIR=<dir>" ending the
      # line or followed by a space, so "hbot" never counts "hbot2"'s server.
      # shortcut: ps joins env words with spaces, so a dir "/a/My" also matches a line carrying "/a/My Project/x"; quote-aware parsing if a Mac project ever has such siblings.
      local IFS=$'\n'; set -f   # one ps line at a time (a subshell: neither leaks), with no here-string (bash 3.2 writes those to TMPDIR)
      for l in $mac_env; do
        case "$l " in
          *" DISCORD_STATE_DIR=$1 "*) n=$((n + 1));;
          *" DISCORD_STATE_DIR="*"/.claude/discord-agents/$2 "*) v=${l##* DISCORD_STATE_DIR=}; v=${v%% *}; [ "$v" -ef "$1" ] && n=$((n + 1));;
        esac
      done
      printf '%s' "$n"; return 0
    fi
    for c in $server_cands; do
      # Braces around the read, not `2>/dev/null` on mapfile alone: a
      # process that exits between the glob and the read makes the SHELL
      # report the failed redirect, which mapfile's own redirection does not
      # silence, and this must print nothing but a number. No `basename`
      # either -- one fork per process on a machine with 800 of them cost
      # 281 ms a scan, against 83 ms for the expansion (measured).
      { mapfile -d '' -t args < "$c"; } 2>/dev/null || continue   # bash4-ok: reached only where /proc exists
      [ "${#args[@]}" -ge 2 ] || continue
      [ "${args[0]##*/}" = bun ] || continue
      [ "${args[${#args[@]}-1]}" = start ] || continue
      hit=no
      for a in "${args[@]}"; do case $a in */discord/*) hit=yes; break;; esac; done
      [ "$hit" = yes ] || continue
      pid=${c#"$proc"/}; pid=${pid%/cmdline}
      # ONE fork per candidate, no bash loop over its environment (a loop cost a few ms per live server per bot per
      # run: +1.9 s on the suite's health cases with 18 servers on the machine, 2026-10-18). The whole entry, as -z
      # -x anchored it before: GNU grep (the /proc branch) stops at the NUL that ends it, since NUL is a control
      # character, and the one value comes back with no NUL in it. Compared whole, so a bot named "hbot" never counts
      # "hbot2"'s server: the exact dir, else the old path's last part and a builtin -ef through the link. The match
      # starts at the NUL that ends the entry before (the `[^A-Za-z0-9_]`), which bash drops from the substitution
      # with a warning on stderr (one per server per bot per run, seen on lmd42 at 1.18.0): the assignment's stderr is
      # closed, the value is whole either way.
      { v=$(grep -aoE '(^|[^A-Za-z0-9_])DISCORD_STATE_DIR=[^[:cntrl:]]*' "$proc/$pid/environ"); } 2>/dev/null || continue
      v=${v#*DISCORD_STATE_DIR=}; v=${v%%$'\n'*}
      if [ "$v" = "$1" ]; then n=$((n + 1))
      else case $v in */.claude/discord-agents/"$2") [ "$v" -ef "$1" ] && n=$((n + 1));; esac
      fi
    done
    printf '%s' "$n"
  }

  # The age in minutes of the youngest turn in flight, or "" when none.
  # on-prompt creates turns/<session id> and appends a line for every
  # further message of the same turn, so a busy long turn keeps its mtime
  # fresh; on-stop removes it. The .primed and .replied neighbours are not
  # turn markers. The youngest, not the oldest: one wedged leftover must not
  # make a bot that is answering right now look wedged.
  turn_age_min() {  # $1 = bot state dir
    local f best="" age mt
    for f in "$1"/turns/*; do
      case $f in *.primed|*.replied|*'/*') continue;; esac
      [ -f "$f" ] || continue
      mt=$(date -r "$f" +%s 2>/dev/null) || continue
      age=$(( (now_s - mt) / 60 ))
      if [ -z "$best" ] || [ "$age" -lt "$best" ]; then best=$age; fi
    done
    printf '%s' "$best"
  }

  # Is a session of this bot, in this project, running a turn right now?
  # `.state` is useless as a LIVENESS signal (a live bot sits at `done`), but
  # this is the one thing it does measure, and the turn file's mtime cannot
  # tell a long working turn from a wedged one: on-prompt only touches that
  # file when a MESSAGE arrives, so a turn that runs for hours off a single
  # message goes stale-looking while it works. Measured 2026-09-25: this very
  # session was reported stale, with a --force refresh as the suggested fix,
  # while it was mid-turn. So the turn-file cap is only believed when the
  # daemon also says nothing is running. Unknown (no jq, no claude, a listing
  # that fails or is not a list) counts as WORKING, the quiet direction: a
  # missed alert is recoverable, an alert telling someone to force-refresh a
  # session that is busy is not.
  # Exit 0 = working, 1 = not working, 2 = could not tell. The caller treats
  # 2 like 0 (hold the alert) but counts how many runs in a row said so: a
  # daemon that keeps failing to answer is itself a sign something is wrong,
  # and holding for ever would hide it. See $unknown_cap below.
  session_working() {
    local list t=()
    command -v jq >/dev/null 2>&1 || return 2
    command -v claude >/dev/null 2>&1 || return 2
    command -v timeout >/dev/null 2>&1 && t=(timeout 5)
    list=$(${t[@]+"${t[@]}"} claude agents --json 2>/dev/null) || return 2
    printf '%s' "${list:-null}" | jq -e 'type == "array"' >/dev/null 2>&1 || return 2
    printf '%s' "$list" | jq -e --arg n "$1" --arg cwd "$(pwd -P)" '
      any(.[]; (.name? // "") == $n and (.cwd? // "") == $cwd
               and ((.state? // "") == "working" or (.status? // "") == "busy"))' \
      >/dev/null 2>&1
  }

  api() {  # $1 = path; sets $status and $resp. Token on stdin, never argv.
    local out
    out=$(printf 'Authorization: Bot %s\n' "$tok" | curl -s --max-time 10 -w '\n%{http_code}' -H @- \
      "https://discord.com/api/v10/$1" 2>/dev/null) || out=""
    status=${out##*$'\n'} resp=${out%$'\n'*}
    case $status in ''|*[!0-9]*) status=000;; esac
  }

  # 1.11.1: the names of this bot's channels, from ONE call for the guild's channel list: the main channel ($ch) and
  # every group of its access policy ($access). They are kept in <bot dir>/channel-names, one "<id> <name>" line each
  # (a name cleaned as the main one always was; written beside the file and moved over it), the main one in channel-guild
  # too, as before. Fails, and writes nothing, when the answer is no array or has not the main channel in it. $names is
  # what the document is built from. A channel the guild has not (another guild's, a deleted one) gets no line.
  guild_names() {
    local nl="" t
    api "guilds/$gid/channels"
    nl=$(printf '%s' "$resp" | jq -r --arg c "$ch" --argjson a "${access:-null}" '
      ([$c] + [$a.groups[]?.id]) as $ids
      | arrays | .[] | objects | select(.id as $i | any($ids[]; . == $i))
      | (.name // "" | tostring | gsub("[[:space:][:cntrl:]]+"; "-")) as $n | select($n != "") | "\(.id) \($n)"' 2>/dev/null) || nl=""
    case $'\n'$nl in *$'\n'"$ch "*) ;; *) return 1;; esac
    t=$'\n'$nl; t=${t#*$'\n'"$ch "}
    names=$nl cname=${t%%$'\n'*}
    { printf '%s\n' "$nl" > "$d/channel-names.$$" && mv "$d/channel-names.$$" "$d/channel-names"; } 2>/dev/null || :
    printf '%s %s %s %s\n' "$ch" "$gid" "$cname" "$now_s" > "$d/channel-guild" 2>/dev/null || :
  }

  # The ids in a messages array that addressed this bot. An author
  # outside allowFrom is dropped exactly as the plugin drops it, so
  # last-message-id's inability to ever reach such a message cannot become
  # an alert; an EMPTY allowFrom allows everyone, as it does there. With
  # requireMention false every allowed author's message counts; with it
  # true, a mention of this bot or a reply to one of its own messages does.
  # `.mentions` excludes @everyone, which the start patches the plugin to
  # ignore too, so the two agree.
  # The author id is bound to $aid before the allowFrom test: inside
  # `$allow | index(...)` the input is the allow ARRAY, so reaching for
  # `.author` there indexes an array with a string and the whole filter dies
  # (measured: every message dropped, so a dead bot read as healthy).
  # An id is never turned into a jq NUMBER. jq 1.6 -- still /usr/bin/jq on
  # this machine -- holds every number as an IEEE double, and a 19-digit
  # snowflake does not fit in 53 bits of mantissa: measured,
  # "1553056881315025049"|tonumber|tostring gives 1553056881315025200, which
  # is LARGER than the original, so it sails past last-message-id and invents
  # a stale verdict for a bot that is perfectly idle; two ids one apart also
  # compare equal. Ids therefore stay strings, compared by (length, then
  # lexically) -- exact for fixed-width decimals, and Discord ids are 18-19
  # digits and will not reach 20 this century.
  #
  # OLDEST unanswered, not newest: the age being measured is how long the bot
  # has been failing to answer, so it must start at the FIRST message it did
  # not answer. With the newest, every fresh message resets the clock -- and
  # a wedged bot is exactly one people keep calling, so the bots this is for
  # would never be reported. The set is bounded below by last-message-id, so
  # something answered long ago cannot drag the age back.
  id_newer() {  # $1 > $2, as ids
    [ "${#1}" -gt "${#2}" ] && return 0
    [ "${#1}" -lt "${#2}" ] && return 1
    [[ $1 > $2 ]]
  }
  # A candidate is also cleared when the bot itself posted a later message in
  # this same page (one chat: the channel or one thread): it spoke after the
  # message, so the message was handled even if no delivered line says so (a
  # catch-up after a refresh gap or a down bot). The bot's reply in ANOTHER
  # thread is a different page and clears nothing: one stuck thread still alerts.
  # addressed_ids: $1 = messages JSON; ids newer than $floor, not in $delivered, no later bot message here, and not
  # carrying the bot's own ☑️ or ✅ reaction (1.18.3: the Stop hook's marks; a project hook that drops a Discord prompt
  # before the session sees it marks the message ☑️ itself, README); oldest first.
  addressed_ids() {
    printf '%s' "$1" | jq -r --arg me "$me" --argjson allow "$allow" \
      --argjson mention "$mention" --arg seen "$floor" --arg delivered "$delivered" '
      ($delivered | split("\n")) as $dl |
      if type != "array" then empty else
        [ .[] | select(.author.id? == $me) | .id? | select(type == "string") ] as $mine |
        [ .[]
          | (.author.id? // "") as $aid
          | select($aid != $me)
          | select(($allow | length) == 0 or ($allow | index($aid)) != null)
          | select($mention == false
                   or ((.mentions // []) | any((.id? // "") == $me))
                   or ((.referenced_message.author.id? // "") == $me))
          | select((.reactions // []) | any((.me? == true) and ((.emoji.name? // "") | IN("☑️", "✅"))) | not)
          | .id
          | select(type == "string" and test("^[0-9]{17,20}$"))
          | select((. | length) > ($seen | length)
                   or ((. | length) == ($seen | length) and . > $seen))
          | select(. as $i | ($dl | index($i)) == null)
          | select(. as $i | any($mine[]; (length > ($i | length))
                                          or (length == ($i | length) and . > $i)) | not) ]
        | sort | .[]
      end' 2>/dev/null || :
  }
  # The oldest of $oldest and every id read from $1, kept in $oldest.
  note_oldest() {  # $1 = messages JSON
    local id
    while IFS= read -r id; do
      case $id in ''|*[!0-9]*) continue;; esac
      # `cond && oldest=$id` alone would be FATAL here: under `set -e` a
      # loop body whose last command returns non-zero aborts the script, and
      # that is precisely the ordinary case -- the second id not being older
      # than the first. Measured: two unanswered messages made the whole
      # check die mid-run with no output and no error. The else branch keeps
      # the body's status zero. (Same trap as `session_working; x=$?`.)
      if [ -z "$oldest" ] || id_newer "$oldest" "$id"; then oldest=$id; fi
    done < <(addressed_ids "$1")
  }

  # Can this machine reach Discord at all? `GET /gateway` needs no token, so
  # its answer separates "the network is blocked" from "this bot's token was
  # refused" -- and without that separation the two are indistinguishable:
  # measured 2026-09-25, a run with no HTTPS_PROXY got 403 on every call and
  # blamed every bot's token, which would have sent every owner to check a
  # credential that was perfectly fine. So when the network is down, that is
  # the single finding and no token is blamed. The wording names the likely cause,
  # since a missing proxy is what produced it here.
  # Same `-w '\n%{http_code}'` shape as api() below rather than
  # `-o /dev/null -w '%{http_code}'`: the status must be taken from the LAST
  # line, since a body is written whatever -o says.
  net_status=$(curl -s --max-time 10 -w '\n%{http_code}' \
    https://discord.com/api/v10/gateway </dev/null 2>/dev/null) || net_status=""
  net_status=${net_status##*$'\n'}
  case $net_status in ''|*[!0-9]*) net_status=000;; esac
  case $net_status in 2*) net=ok;; *) net=down;; esac

  # A project fact, not a per-bot one, so it is read once rather than once
  # per bot. An explicit null test, not `// "unknown"`: jq's `//` treats
  # FALSE as empty, so the untrusted case -- the one worth reporting -- would
  # read as "unknown" and the hint would be lost.
  trusted=$(jq -r --arg p "$PWD" '.projects[$p].hasTrustDialogAccepted | if . == null then "unknown" else tostring end' "$HOME/.claude.json" 2>/dev/null) || trusted=unknown
  [ -n "$trusted" ] || trusted=unknown

  # Fields are collected separated by US (0x1f) and turned into JSON once,
  # after the loop -- one jq for the whole run instead of one per bot. A
  # variable rather than a temp file: the loop is no subshell, so it
  # survives, and a machine whose TMPDIR is unwritable still works
  # (measured: with mktemp failing, the file version printed two errors and
  # no result at all). US is chosen because no bot name, verdict, detail or
  # line of refresh.log can contain it; a bash variable could not hold NUL.
  rows=""
  for d in "$root"/*/; do
    d=${d%/}
    [ -f "$d/.env" ] || continue
    # Shell expansion, not `basename`: one fork per bot per run, five minutes
    # apart forever, for a string operation bash already does. $d has had its
    # trailing slash stripped just above, so ${d##*/} is the directory name.
    bot=${d##*/}
    tok=$(grep '^DISCORD_BOT_TOKEN=' "$d/.env" 2>/dev/null | head -1) || tok=""
    tok=${tok#DISCORD_BOT_TOKEN=}
    servers=$(count_servers "$d" "$bot")
    turn=$(turn_age_min "$d")
    last_seen=$(cat "$d/last-message-id" 2>/dev/null) || last_seen=0
    is_id "$last_seen" || last_seen=0
    # What "unanswered" is measured against. With a delivered log (on-prompt
    # appends every message id the session was handed, 200 kept) a message is
    # a candidate when it is newer than the OLDEST id in that log and is not
    # in it: it never reached the session. last-message-id cannot be the
    # bound there, since it moves past a message stuck in one thread as soon
    # as the bot answers in another. Without the log (a bot whose hooks have
    # not run since this release) the bound stays last-message-id, as before.
    floor=$last_seen delivered=""
    if [ -s "$d/delivered" ]; then
      floor=""
      # `|| :`: an unreadable file must not abort the run under set -e.
      while IFS= read -r id || [ -n "$id" ]; do
        is_id "$id" || continue
        delivered="$delivered$id"$'\n'
        if [ -z "$floor" ] || id_newer "$floor" "$id"; then floor=$id; fi
      done < "$d/delivered" || :
      [ -n "$floor" ] || floor=$last_seen
    fi
    refresh_tail=$(tail -1 "$d/refresh.log" 2>/dev/null) || refresh_tail=""

    # The channel is the single numeric group key in access.json (where a bot
    # is moved), config.env's otherwise: the same rule as the start path and
    # hooks/lib/discord.sh. Two keys are as ambiguous as none.
    # requireMention and allowFrom come from that same group, so all three
    # are read in ONE jq: a fork per field per bot per run is pure waste, and
    # it showed up in the suite's wall time.
    # Note the explicit null tests rather than `//`: jq's `//` treats FALSE
    # as empty, so `requireMention // true` read an owner's deliberate
    # "answer everything" (false) as true and dropped every message there as
    # unaddressed -- a wedged bot in such a channel was undetectable. Third
    # place that operator bit here; false is a meaningful value in all of
    # them, so `//` is never right for one.
    # The fourth field is the whole access policy, for the TUI (1.11.0), from this same jq: every numeric group with
    # its requireMention and allowFrom, dmPolicy and the DM allowFrom. An id is kept only when it is all digits and the
    # policy only when it is all letters, so that JSON holds no backslash and no tab and survives @tsv and `read` as it is.
    # No channel is written "-": a tab is IFS whitespace, so an empty first field would shift the others left.
    # A `groups` that is missing or no object reads as no group ($g), not as no answer: a bot that takes DMs only still
    # reports its DM policy, and its channel is config.env's as before.
    cfg=$(jq -r --arg fb "${DISCORD_CHANNEL_ID:-}" '
      def ids: [arrays[] | tostring | select(test("^[0-9]+$"))] | unique;
      ((.groups | objects) // {}) as $g
      | ($g | keys) as $k
      | (if ($k | length) == 1 and ($k[0] | test("^[0-9]+$")) then $k[0] else $fb end) as $ch
      | [ (if $ch == "" then "-" else $ch end),
          ($g[$ch].requireMention | if . == null then true else . end | tostring),
          (($g[$ch].allowFrom // []) | map(tostring) | unique | @json),
          ({dm: (.dmPolicy | if type == "string" and test("^[A-Za-z]+$") then . else null end), dm_allow: (.allowFrom | ids),
            groups: [$g | to_entries[] | select((.key | test("^[0-9]+$")) and (.value | type) == "object")
                     | {id: .key, mention: (.value.requireMention != false), allow: (.value.allowFrom | ids)}]} | tojson) ]
      | @tsv' "$d/access.json" 2>/dev/null) || cfg=""
    access=""
    IFS=$'\t' read -r ch mention allow access <<<"$cfg"
    case ${ch:-} in ''|*[!0-9]*) ch=${DISCORD_CHANNEL_ID:-};; esac
    case ${mention:-} in true|false) ;; *) mention=true;; esac
    case ${allow:-} in '['*) ;; *) allow='[]';; esac
    # The guild and the name of the channel, cached as "<channel> <guild> <name> <read at, epoch s>" (see below). Read
    # here, before any verdict, so the name is known whatever Discord answers this run. A line for another channel is
    # not used; one an older version wrote (two fields) has no name and no age.
    gid="" cname="" cat_s="" cached=$(cat "$d/channel-guild" 2>/dev/null) || cached=""
    case $cached in "$ch "*) read -r cch gid cname cat_s <<<"$cached";; esac
    # Leading zeros go, as for lm below: to bash 08 is an octal number that is none, and that error would end this whole
    # health block and let the script run on into the launcher (it started the bot's session). All zeros is 0.
    case $cat_s in ''|*[!0-9]*) cat_s=0;; esac
    cat_s=${cat_s#"${cat_s%%[!0]*}"}; cat_s=${cat_s:-0}
    [ "$cname" != - ] || cname=""
    # 1.11.1: the names kept for this bot's channels (guild_names) and its mode, both read by the shell itself.
    names="" mode=""
    { while read -r cch t; do names="$names$cch $t"$'\n'; done < "$d/channel-names"; } 2>/dev/null || :
    { read -r mode < "$d/mode"; } 2>/dev/null || :
    mode=${mode//[[:cntrl:]]/}; mode=${mode:-none}
    # 1.14.0: the bot's Discord username (a bot's name here is that username; the TUI says `≠ Discord` when they differ),
    # kept in discord-name as "<read at, epoch s> <name>" and read again once it is a day old, by the users/@me call that
    # also tells the bot's id. A number with a leading zero is decimal (cat_s says why).
    dn_s="" dname=""; { read -r dn_s dname < "$d/discord-name"; } 2>/dev/null || :
    case $dn_s in ''|*[!0-9]*) dn_s=0;; esac
    dn_s=${dn_s#"${dn_s%%[!0]*}"}; dn_s=${dn_s:-0}; dname=${dname//[[:cntrl:]]/}

    verdict=ok detail="" oldest="" age=0 me="" status=000 resp=""
    if [ "$net" = down ]; then
      verdict=noreach detail="this machine cannot reach Discord (HTTP $net_status on the unauthenticated /gateway), so nothing can be said about any bot; behind a proxy, check HTTPS_PROXY"
    elif [ -z "$tok" ] || ! is_id "$ch"; then
      verdict=unknown detail="no token or channel in $d"
    else
      # A bot's own user id never changes, so it is asked for once and kept
      # in the state dir: that is one fewer HTTP call
      # AND one fewer jq per bot per run, for a fact that was already known.
      # A cached value is trusted only if it looks like an id.
      me=$(cat "$d/bot-id" 2>/dev/null) || me=""
      if ! is_id "$me" || [ $((now_s - dn_s)) -ge 86400 ]; then
        api users/@me
        nme="" nn=""
        l=$(printf '%s' "$resp" | jq -r 'objects | [(.id // "" | tostring), (.username // "" | tostring | gsub("[[:cntrl:]]"; ""))] | join("\u001f")' 2>/dev/null) || l=""
        IFS=$'\x1f' read -r nme nn <<<"$l" || :
        if ! is_id "$me" && is_id "$nme"; then me=$nme; printf '%s\n' "$me" > "$d/bot-id" 2>/dev/null || :; fi
        # A read that fails keeps the name it had, and is tried again in an hour, not at every run. So does one that
        # answers as another bot (the token in .env replaced by some other bot's): that name is not this bot's (1.14.1).
        if is_id "$nme" && [ "$nme" = "$me" ] && [ -n "$nn" ]; then dname=$nn; printf '%s %s\n' "$now_s" "$dname" > "$d/discord-name" 2>/dev/null || :
        elif [ -n "$dname" ]; then printf '%s %s\n' "$((now_s - 82800))" "$dname" > "$d/discord-name" 2>/dev/null || :; fi
      fi
      if ! is_id "$me"; then
        # 401 and 403 mean the credential itself was refused. Anything else
        # -- a timeout or DNS failure (000), a rate limit (429), a Discord
        # outage (5xx) -- is not the token's fault, and saying it is sends
        # someone to rotate a credential that was fine. Those are reported
        # as what they are and no bot is blamed.
        case $status in
          401|403) verdict=unreachable detail="Discord refused this bot's token (HTTP $status)";;
          429)     verdict=throttled detail="Discord is rate-limiting this bot (HTTP 429); nothing can be said about it this run";;
          *)       verdict=apierror detail="Discord did not answer for this bot (HTTP $status); the token was not rejected, so this is Discord's side or the network";;
        esac
      else
        api "channels/$ch/messages?limit=50"
        case $status in
          2*)      note_oldest "$resp";;
          401|403) verdict=unreachable detail="cannot read the channel (HTTP $status): the bot's channel permissions or its token";;
          429)     verdict=throttled detail="Discord is rate-limiting this bot (HTTP 429); nothing can be said about it this run";;
          *)       verdict=apierror detail="cannot read the channel (HTTP $status); the token was not rejected, so this is Discord's side or the network";;
        esac
        # Threads carry their own messages, and one request for the guild's
        # active threads answers with every thread's last_message_id, so a
        # thread is only READ when something in it is newer than the last id
        # the hooks recorded. Normally that is nothing at all. The
        # last_message_id comparison is done in the shell, on strings, for
        # the jq-1.6 precision reason above.
        if [ "$verdict" = ok ]; then
          # The guild a channel belongs to cannot change -- a channel is
          # created inside one guild and is deleted, not moved -- so this
          # whole request exists to learn one immutable fact. It is kept in
          # the state dir like bot-id, which is one fewer HTTP call AND one
          # fewer jq per bot per run.
          # The CHANNEL is stored beside the guild because the bot's channel
          # CAN change (access.json is edited to move it), and a cache keyed
          # on nothing would then answer for the old channel. A cached line
          # is used only when its channel is still this one and the guild
          # still looks like an id; anything else re-fetches and rewrites it.
          # Since 1.11.0 the NAME of the channel is kept there too (the TUI's channel column), and a name can change,
          # so the line is read again once it is a day old (its fourth field is when it was read): one call a day per
          # bot, and the jq that read the guild reads both. A line with no age (an older version's) is read once.
          # A read that fails keeps the line as it is: the guild in it is still right. Two steps, since bash 3.2
          # misreads a quoted jq program inside "$( )" inside double quotes. "-" stands for a missing guild or name,
          # so no field is empty (a tab is IFS whitespace) and the line always has four words.
          # Since 1.11.1 the daily read is the guild's channel list (guild_names), which has the name of every channel
          # of the bot and costs the same one call. The channel itself is asked only for what the list cannot give: the
          # guild, the first time ever (two calls, once), and the main name on a day the list fails.
          had=$gid
          if ! is_id "$gid" || { [ $((now_s - cat_s)) -ge 86400 ] && ! guild_names; }; then
            api "channels/$ch"
            cg=$(printf '%s' "$resp" | jq -r '[(.guild_id // "-" | tostring), (.name // "" | tostring | gsub("[[:space:][:cntrl:]]+"; "-") | if . == "" then "-" else . end)] | @tsv' 2>/dev/null) || cg=""
            ngid="" nname=""
            IFS=$'\t' read -r ngid nname <<<"$cg" || :
            if is_id "$ngid"; then
              gid=$ngid cname=$nname
              printf '%s %s %s %s\n' "$ch" "$gid" "$cname" "$now_s" > "$d/channel-guild" 2>/dev/null || :
              [ "$cname" != - ] || cname=""
            elif is_id "$had"; then
              # Both reads failed (Discord answers for messages but not for these): the line is kept, guild and name,
              # and only its age is set to an hour short of a day, so the next try is in an hour, not at every run
              # (two calls per bot every 5 minutes for as long as it lasts).
              printf '%s %s %s %s\n' "$ch" "$gid" "${cname:--}" "$((now_s - 82800))" > "$d/channel-guild" 2>/dev/null || :
            fi
            is_id "$had" || ! is_id "$gid" || guild_names || :
          fi
          if is_id "$gid"; then
            api "guilds/$gid/threads/active"
            for t in $(printf '%s' "$resp" | jq -r --arg c "$ch" '
                  (.threads // []) | .[] | select((.parent_id // "") == $c)
                  | [(.id // ""), (.last_message_id // "0")] | @tsv' 2>/dev/null |
                  while IFS=$'\t' read -r tid tlast; do
                    is_id "$tid" || continue
                    case $tlast in (''|*[!0-9]*) tlast=0;; esac   # (: bash 3.2 ends $( ) at a bare )
                    id_newer "$tlast" "$floor" && printf '%s\n' "$tid"
                  done); do
              api "channels/$t/messages?limit=50"
              case $status in 2*) note_oldest "$resp";; *) continue;; esac
            done
          fi
        fi
      fi
    fi

    # $oldest is already known to be newer than last-message-id (both the
    # channel and the thread filters require it), so there is nothing left
    # to compare here.
    if [ "$verdict" = ok ] && [ -n "$oldest" ]; then
      age=$(( (now_s - $(snowflake_s "$oldest")) / 60 ))
      if [ "$age" -ge "$stale_min" ]; then
        # `session_working; working=$?` would be fatal: the script runs under
        # `set -e`, and a non-zero exit from a command that is neither last
        # nor in a condition aborts it -- silently, since health prints as it
        # goes (measured: the whole check died with no output). `&&`/`||`
        # makes it a tested command, which set -e allows.
        working=1
        [ -z "$turn" ] || { session_working "$bot" && working=0 || working=$?; }
        # A run that could not tell is counted, with the time of the first of
        # the streak; a run that could resets both. Past the cap (so many
        # runs AND so long since the first) the hold is given up and the
        # not-knowing is itself the finding: `claude agents` failing
        # repeatedly means the daemon is unwell, which is exactly when a bot
        # breaks. health-unknown holds "<count> <epoch of the first>"; a file
        # of before 1.12.0 holds the count only, and its streak starts now.
        if [ "$working" = 2 ]; then
          # Checked and stripped of leading zeros BEFORE the arithmetic (see cat_s above): what is no count starts at 0,
          # and what is no time of the past is now.
          unknowns="" first=""
          { read -r unknowns first < "$d/health-unknown"; } 2>/dev/null || :
          case $unknowns in ''|*[!0-9]*) unknowns=0 first="";; esac
          case $first in ''|*[!0-9]*) first=$now_s;; esac
          unknowns=${unknowns#"${unknowns%%[!0]*}"}; unknowns=$(( ${unknowns:-0} + 1 ))
          first=${first#"${first%%[!0]*}"}; [ "${first:-0}" -le "$now_s" ] || first=$now_s
          first=${first:-0}
          printf '%s %s\n' "$unknowns" "$first" > "$d/health-unknown" 2>/dev/null || :
        else
          unknowns=0
          [ ! -f "$d/health-unknown" ] || unlink "$d/health-unknown" 2>/dev/null || :
        fi
        if [ "$working" = 2 ] && [ "$unknowns" -ge "$unknown_cap" ] && [ $((now_s - first)) -ge "$unknown_min_s" ]; then
          verdict=nostate detail="unanswered for ${age}m and 'claude agents' has not answered for $unknowns runs, so whether a turn is running cannot be told; the daemon itself may be unwell"
        elif [ -n "$turn" ] && { [ "$turn" -lt "$turn_max_min" ] || [ "$working" != 1 ]; } &&
             [ "$age" -lt "$busy_cap_min" ]; then
          verdict=busy detail="a turn has been in flight ${turn}m; holding the finding"
          case $working in
            0) detail="$detail (the session is running one now)";;
            2) detail="$detail (run $unknowns with no answer from 'claude agents', for $(( (now_s - first) / 60 ))m; a finding after $unknown_cap runs and $((unknown_min_s / 60))m)";;
          esac
        elif transcript_moved "$d" "$stale_min"; then
          # A transcript of one of its sessions (by the hooks' markers, so the id it has NOW, after a /clear too) that
          # changed within stale_min: the session works, on a long turn or on something that is not Discord (1.17.1;
          # cswap on 2026-10-17: 7 h of cross-session work read as STUCK, and the TUI's f discarded it). Held without
          # the 4 h cap, which is for a session that only CLAIMS to work: the risk (README) is a session looping for
          # ever, which reads busy until its transcript stops moving. Last before stale: the one find it forks runs
          # only when nothing cheaper holds the finding.
          verdict=busy detail="unanswered for ${age}m, but a transcript of its session changed within the last ${stale_min}m: it is working, not on Discord; holding the finding"
        else
          verdict=stale
          case $servers in
            0)       detail="no plugin server: the bot is down";;
            1)       detail="the plugin server is up, so its hooks or its turn are stuck";;
            unknown) detail="cannot count plugin servers on this machine";;
            *)       detail="$servers plugin servers: two sessions share this bot's token";;
          esac
          detail="unanswered for ${age}m -- $detail"
          [ -z "$turn" ] || detail="$detail; a turn file has sat there ${turn}m"
          [ "$age" -lt "$busy_cap_min" ] || [ "$working" = 1 ] ||
            detail="$detail; the session still claims to be working, but ${busy_cap_min}m unanswered is too long to keep holding"
        fi
      fi
    fi
    # A duplicate is worth saying even when the bot is answering: both
    # sessions answer, so the channel gets every reply twice.
    if [ "$verdict" = ok ] && [ "$servers" != unknown ] && [ "$servers" -gt 1 ]; then
      verdict=duplicate detail="$servers plugin servers share this bot's token"
    fi
    # No server and nothing waiting to be answered: still down, and worth
    # naming before someone writes into a channel nobody is listening on.
    if [ "$verdict" = ok ] && [ "$servers" = 0 ]; then
      verdict=down detail="no plugin server for this bot"
      case $refresh_tail in *'not trusted'*) detail="$detail; its last refresh failed on workspace trust";; esac
      [ "$trusted" != false ] || detail="$detail; this project is not trusted, so a --bg start will refuse"
    fi

    rows=$rows$bot$'\x1f'$verdict$'\x1f'$detail$'\x1f'$servers$'\x1f'${turn:-}$'\x1f'
    rows=$rows${oldest:-}$'\x1f'$last_seen$'\x1f'${age:-0}$'\x1f'$refresh_tail$'\x1f'$trusted$'\x1f'
    # 1.11.0, for the TUI: the channel and its cached name, the second the last message handed to the session was made
    # (the snowflake of last-message-id, as snowflake_s reads one, with no fork; empty when there is none) and the
    # access policy. The monitor carries them into state.json.
    lm=""
    [ "$last_seen" = 0 ] || { lm=${last_seen#"${last_seen%%[!0]*}"}; lm=$(( ((${lm:-0} >> 22) + 1420070400000) / 1000 )); }
    is_id "$ch" || ch=""
    rows=$rows$ch$'\x1f'$cname$'\x1f'$lm$'\x1f'$access$'\x1f'$names$'\x1f'$mode$'\x1f'$dname$'\x1f'


    line="claude-discord health: $bot $verdict${detail:+ -- $detail}"
    # Not under --all (--nolog): at a monitor's 5-minute cadence both would grow without bound.
    if [ "$nolog" = no ]; then
      printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$line" >> "$d/health.log" 2>/dev/null || :
      # journal too, because the log above lives in the state dir of a bot
      # whose whole problem may be that nobody is looking at it.
      ! command -v logger >/dev/null 2>&1 || logger -t claude-discord-health -- "$line" 2>/dev/null || :
    fi

    [ "$as_json" = yes ] || echo "$line"
  done
  # One jq for the whole run: it reads the NUL-separated fields, groups them
  # seventeen at a time into objects, prints them when asked, and reports through
  # its exit status whether anything needs a human -- so a caller can tell
  # without parsing anything. `busy` is not a
  # finding. No bots at all is an empty list, which is "nothing wrong".
  # The findings flag goes on its own LAST line, so what precedes it stays
  # exactly the JSON a caller would parse; the shell strips that line off
  # before printing. A marker merged into the document would corrupt the one
  # thing --json exists to produce. The document comes out already indented
  # (-r prints only a string raw), so printing it needs no second jq.
  rows=$(printf '%s' "$rows" | jq -rRs --argjson show "$([ "$as_json" = yes ] && echo true || echo false)" --arg owner "${DISCORD_USER_ID:-}" '
    [ splits("\u001f") ] | .[:-1]
    | [ range(0; length; 17) as $i
        # 1.11.1: the kept "<id> <name>" lines, as a name per id for the groups of `access`.
        | (.[$i+14] | split("\n") | map(select(. != "") | split(" ") | {key: .[0], value: (.[1] // "")}) | from_entries) as $n
        | { bot: .[$i], verdict: .[$i+1], detail: .[$i+2], servers: .[$i+3],
            turn_min: .[$i+4], oldest_unanswered: .[$i+5], last_seen: .[$i+6],
            unanswered_min: (.[$i+7] | tonumber? // 0), refresh_tail: .[$i+8],
            trusted: .[$i+9], owner_id: $owner,
            channel: .[$i+10], channel_name: .[$i+11],
            last_message_at: ((.[$i+12] | tonumber? // null) | if . == null then null else todate end),
            mode: .[$i+15], discord_name: (.[$i+16] | if . == "" then null else . end),
            access: (.[$i+13] | (try fromjson catch null) | if type == "object" then .groups |= map(. + {name: ($n[.id] // "")}) else . end) } ]
    | (if $show then . else empty end),
      (if all(.[]; .verdict == "ok" or .verdict == "busy") then "ok" else "finding" end)
    ' 2>/dev/null) || rows=finding
  verdicts=${rows##*$'\n'}
  if [ "$as_json" = yes ] && [ "$rows" != "$verdicts" ]; then
    printf '%s\n' "${rows%$'\n'*}"
  fi
  [ "$verdicts" = ok ] || exit 1
  exit 0
fi
