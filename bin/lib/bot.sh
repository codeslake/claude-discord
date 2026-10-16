# sourced by bin/claude-discord: the bot verb

# bot: a bot's token and its name (1.14.0), for people and the TUI, which changes them through this verb only. A bot's
# name here is its Discord username (b_name_re: 2 to 32 of A-Z a-z 0-9 _ -, not starting with -; no reserved_name): its directory, its session's name and what
# the monitor and the TUI show.
#   bot <name> token          the new token, read from the terminal with its echo off; Discord is asked who it is (GET
#                             /users/@me as that token): a token Discord refuses, or one of another bot, is refused;
#                             <bot dir>/.env replaced by rename, mode 600, its other lines kept. A running session logs in
#                             with it within 10 s.
#   bot <name> rename <new>   Discord's name first (PATCH /users/@me as the bot: about two changes an hour are allowed,
#                             and a refusal changes nothing here), then everything here keyed by the name (below). <new>
#                             that Discord has already: only the name here changes (the TUI's `=`).
#   bot add [--mode <mode>] [--start]   a new bot in this project: its token read as token reads it, its Discord username
#                             its name, set up by `setup` with its answers on stdin (the project's channel and owner
#                             are config.env's; an @mention required), started (`--bg --name`) with --start.
#   bot <name> recover [--fresh]   (1.16.0, the TUI's f and F) a down bot brought back: `claude respawn <id>` of its last
#                             session when claude agents still lists it as started in this project (pinned-job, then
#                             the newest plugin-sessions marker, then live_sessions), else `claude-discord --bg --name`;
#                             two or more listed: refused. --fresh (a stale bot): every listed session stopped, then
#                             --bg --name, as refresh --force. The plan is printed with its `run:` line, then the one
#                             question; the command's status is passed on. recover.log gets a line per run.
# Each asks one question at the terminal, after the marker line access set prints (U+2060), and refuses without a
# terminal on stdin and stdout (exit 3): token and add before they read anything, rename and recover after printing what
# they would do. The token is never printed, never in an argument list, the environment or a log: read from the terminal
# (or .env), sent to curl and to setup on their stdin.
# --host <alias> [--manager <bot>] --project <dir>: as access --host; the host needs claude-discord 1.14.0 (recover: 1.16.0).
# Exit status: 0 done, or nothing to change; 1 it could not (Discord refused or did not answer, a token of another bot,
# no such bot, a name taken, a failed write or start; recover: what runs is unknown, two sessions listed, an untrusted
# workspace, a stop that failed, or the command it ran exited non-zero: what was done and what was not is said); 2 usage,
# a name that is none, what was typed is no token, or a session renaming or recovering its own bot; 3 no terminal: nothing
# read, changed or run; 4 answered no; 5 --host: no answer from the host, or its claude-discord is too old for the act.
if [ "${1:-}" = bot ]; then
  { set +x; } 2>/dev/null   # a token is read below: no xtrace (bash -x, SHELLOPTS=xtrace) may copy it into a transcript
  shift
  b_usage="usage: claude-discord bot [--host <alias> [--manager <bot>]] [--project <dir>] <bot> token | <bot> rename <new name> | <bot> recover [--fresh] | add [--mode none|dev-manager|autoresearchclaw] [--start]"
  b_name_re='^[A-Za-z0-9_][A-Za-z0-9_-]{1,31}$'   # a bot's name: Discord's username, which it is; never an option's -
  a_host="" a_proj="" hb=""
  while [ $# -gt 0 ]; do
    case $1 in
      --host|--manager|--project)
        [ $# -ge 2 ] || { echo "$b_usage" >&2; exit 2; }
        case $1 in --host) a_host=$2;; --manager) hb=$2;; *) a_proj=$2;; esac
        shift 2;;
      --) shift; break;;
      -*) echo "$b_usage" >&2; exit 2;;
      *) break;;
    esac
  done
  [ $# -ge 1 ] || { echo "$b_usage" >&2; exit 2; }
  bot=$1 act=${2:-} new="" b_mode=none b_start="" b_fresh=""; shift
  [ "$bot" != add ] || act=add
  [ $# = 0 ] || [ "$act" = add ] || shift
  case $bot in ''|.|..|*/*) echo "claude-discord: bot: the bot's name must be a plain directory name" >&2; exit 2;; esac
  case $act in
    add)
      while [ $# -gt 0 ]; do
        case $1 in
          --mode) [ $# -ge 2 ] || { echo "$b_usage" >&2; exit 2; }
                  case $2 in none|dev-manager|autoresearchclaw) b_mode=$2;; *) echo "$b_usage" >&2; exit 2;; esac; shift 2;;
          --start) b_start=1; shift;;
          *) echo "$b_usage" >&2; exit 2;;
        esac
      done;;
    token) [ $# = 0 ] || { echo "$b_usage" >&2; exit 2; };;
    rename)
      [ $# = 1 ] || { echo "$b_usage" >&2; exit 2; }
      new=$1
      c_match "$new" "$b_name_re" || { echo "claude-discord: bot: the new name is 2 to 32 of A-Z a-z 0-9 _ -, not starting with - (Discord's username, which it becomes)" >&2; exit 2; };;
    recover)
      while [ $# -gt 0 ]; do
        case $1 in --fresh) b_fresh=1; shift;; *) echo "$b_usage" >&2; exit 2;; esac
      done;;
    *) echo "$b_usage" >&2; exit 2;;
  esac
  b_noterm() { echo "claude-discord: bot: $act reads the token from a terminal and asks there: run it in a terminal (stdin and stdout); nothing was read or changed" >&2; exit 3; }
  if [ -n "$a_host" ]; then
    [ "$act" = rename ] || [ "$act" = recover ] || { [ -t 0 ] && [ -t 1 ]; } || b_noterm   # nothing is read over ssh without a terminal here
    if [ "$act" = add ]; then via_host bot 1.14.0 add --mode "$b_mode" ${b_start:+--start}; fi
    if [ "$act" = recover ]; then via_host bot 1.16.0 "$bot" recover ${b_fresh:+--fresh}; fi
    via_host bot 1.14.0 "$bot" "$act" ${new:+"$new"}
  fi
  if [ -n "$a_proj" ]; then
    cd "$a_proj" 2>/dev/null || { echo "claude-discord: bot: no such project directory (--project)" >&2; exit 1; }
  else
    # The project above the cwd that has the bot; for add, the one above it with bots.
    bp=$PWD bw=$bot; [ "$act" != add ] || bw=""
    while [ ! -d "$bp/.claude/discord-agents/$bw" ] && [ -n "$bp" ]; do bp=${bp%/*}; done
    [ -z "$bp" ] || cd "$bp"
  fi
  root=$PWD/.claude/discord-agents; d=$root/$bot M=$helpers/records/monitor
  bn=${bot//[[:cntrl:]]/}   # the name as it is printed
  b_host_name=$(uname -n); b_host_name=${b_host_name%%.*}
  [ "$act" = add ] || [ -f "$d/.env" ] || { echo "claude-discord: bot: no bot '$bn' set up in $root (claude-discord setup <bot>)" >&2; exit 1; }
  command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 || { echo "claude-discord: bot needs jq and curl" >&2; exit 1; }
  # b_api <method> <path> [<JSON body>]: Discord asked with $tok, which goes to curl on its stdin as health sends it;
  # sets status and resp.
  b_api() {
    local out=""
    out=$(printf 'Authorization: Bot %s\n' "$tok" | curl -s --max-time 10 -w '\n%{http_code}' -X "$1" -H @- ${3:+-H 'Content-Type: application/json' --data-binary "$3"} "https://discord.com/api/v10/$2" 2>/dev/null) || out=""
    status=${out##*$'\n'} resp=${out%$'\n'*}
    case $status in ''|*[!0-9]*) status=000;; esac
  }
  # b_me <what to do when Discord refuses it>: who $tok is: b_id, b_user (its username, as Discord gives it), b_isbot,
  # and b_shown (that name made safe to print: another program's text). Exit 1 when Discord refused the token or did not
  # answer.
  b_me() {
    local l
    b_api GET users/@me
    l=$(printf '%s' "$resp" | jq -r 'objects | [(.id // "" | tostring), (.bot == true | tostring), (.username // "" | tostring)] | join("\u001f")' 2>/dev/null) || l=""
    IFS=$'\x1f' read -r b_id b_isbot b_user <<<"$l" || :
    b_shown=$(printf '%s' "$b_user" | LC_ALL=C tr -d '\000-\037\177'); b_shown=${b_shown:0:40}
    case $status in
      2*) c_match "$b_id" '^[0-9]{1,20}$' || { echo "claude-discord: bot: Discord's answer had no bot id in it; nothing was changed" >&2; exit 1; };;
      401) echo "claude-discord: bot: Discord refused the token (HTTP 401): $1; nothing was changed" >&2; exit 1;;
      *) echo "claude-discord: bot: Discord did not answer (HTTP $status); nothing was changed" >&2; exit 1;;
    esac
  }
  # b_read: the token, from the terminal with its echo off (turned off before the prompt is printed, so nothing typed or
  # written to it is shown), after the marker line: into tok. Ctrl-C puts the echo back.
  b_read() {
    st=$(stty -g 2>/dev/null) && stty -echo 2>/dev/null || { echo "claude-discord: bot: the terminal's echo could not be turned off, so no token is read" >&2; exit 1; }
    trap 'stty "$st" 2>/dev/null' EXIT; trap 'exit 130' INT TERM HUP
    printf '\342\201\240\n' >&2
    tok=""; IFS= read -r -p "Token (hidden): " tok || tok=""
    stty "$st" 2>/dev/null; trap - EXIT INT TERM HUP
    echo >&2
    tok=${tok%$'\r'}
    c_match "$tok" '^[A-Za-z0-9._-]{20,200}$' || { tok=""; echo "claude-discord: bot: what was typed is no bot token (letters, digits and . _ -, 20 to 200 of them); nothing was changed" >&2; exit 2; }
  }
  # b_ask <question>: the one question, after the marker (the TUI asks only after it); anything but y is exit 4.
  b_ask() {
    local a=""
    printf '\342\201\240\n' >&2
    read -r -p "$1 [y/N] " a || a=""
    case $a in y|Y) ;; *) echo "claude-discord: bot: answered no; nothing was changed" >&2; exit 4;; esac
  }
  # b_mgr_free <name> [<its old name>]: no manager of that name has a backend on this machine, or exit 1 naming where one
  # is: one backend (state dir, keeper, monitor) per manager NAME on a machine (setup says why).
  b_mgr_free() {
    local p
    [ ! -e "$M/$1" ] || [ "$M/$1" -ef "$M/${2:-}" ] || { echo "claude-discord: bot: $M/$1 is there: a manager named $1 has a backend on this machine; nothing was changed" >&2; exit 1; }
    while IFS= read -r p || [ -n "$p" ]; do
      p=${p%$'\r'}
      [ -n "$p" ] && [ -f "$p/.claude/discord-agents/$1/hosts" ] || continue
      echo "claude-discord: bot: '$1' is a dev-manager with a hosts ledger in $p: one backend serves one manager name per machine; nothing was changed" >&2; exit 1
    done < <(cat "$helpers/records/projects" 2>/dev/null)
  }
  # b_set_up [<a bot dir to skip>]: b_where, the first bot directory of this machine (this project's, then the recorded
  # projects') that is the bot $b_id (its bot-id) or holds $tok (the token line of its .env, compared here: never printed
  # or passed on); "" for none. b_how says which: id or token. One bot, one session: two sessions on one token both answer.
  b_set_up() {
    local p f id l
    b_where="" b_how=id
    while IFS= read -r p || [ -n "$p" ]; do
      p=${p%$'\r'}
      for f in "$p"/.claude/discord-agents/*/.env; do
        [ -n "$p" ] && [ -f "$f" ] && ! { [ -n "${1:-}" ] && [ "${f%/.env}" -ef "$1" ]; } || continue
        id=""; { read -r id < "${f%/.env}/bot-id"; } 2>/dev/null || :
        [ "$id" != "$b_id" ] || b_where=${f%/.env}
        { while IFS= read -r l || [ -n "$l" ]; do
            case $l in DISCORD_BOT_TOKEN=*) l=${l#DISCORD_BOT_TOKEN=}; [ -n "$b_where" ] || [ "${l%$'\r'}" != "$tok" ] || b_where=${f%/.env} b_how=token; break;; esac
          done < "$f"; } 2>/dev/null || :
        l=""
        [ -z "$b_where" ] || return 0
      done
    done < <(printf '%s\n' "$PWD"; cat "$helpers/records/projects" 2>/dev/null)
  }
  # b_case_free <name> [<this bot's dir>]: no other bot of this machine (a bot directory of this project or a recorded
  # one, or a manager's records/monitor/<name>) has that name but for its case, or exit 1 naming it: on a
  # case-insensitive file system the two are one directory, and the hooks compare names without case. The bot itself
  # (its directory, a manager's own records) is none other.
  b_case_free() {
    local p f n
    shopt -s nocasematch
    while IFS= read -r p || [ -n "$p" ]; do
      p=${p%$'\r'}
      for f in "$p"/.claude/discord-agents/*/.env "$M"/*/; do
        f=${f%/}; f=${f%/.env}; n=${f##*/}
        [ -n "$p" ] && [ -d "$f" ] && [[ $n == "$1" ]] && [ "$n" != "$1" ] || continue
        if [ "$f" = "$M/$n" ]; then [ -n "$mgr" ] && [ "$n" = "$bot" ] && continue; else [ -n "${2:-}" ] && [ "$f" -ef "$2" ] && continue; fi
        shopt -u nocasematch
        echo "claude-discord: bot: '$1' is the name of $f but for its case: on a case-insensitive file system they are one directory, and the hooks compare names without case; nothing was changed" >&2; exit 1
      done
    done < <(printf '%s\n' "$PWD"; cat "$helpers/records/projects" 2>/dev/null)
    shopt -u nocasematch
  }
  # b_mv <from> <to>: rename(2); when both are one directory (a case-only rename on a case-insensitive file system),
  # through a temporary name beside it, and back to <from> when the second step fails.
  b_mv() {
    if [ -e "$2" ] && [ "$1" -ef "$2" ]; then
      perl -e 'rename $ARGV[0], $ARGV[2] or exit 1; rename $ARGV[2], $ARGV[1] and exit 0; rename $ARGV[2], $ARGV[0]; exit 1' "$1" "$2" "${2%/*}/.${2##*/}.cd.$$"
    else
      perl -e 'rename $ARGV[0], $ARGV[1] or exit 1' "$1" "$2"
    fi
  }
  # b_dname <bot dir> <name>: Discord's name for the bot, as health keeps it (discord-name: "<read at> <name>").
  b_dname() { printf '%s %s\n' "$(date +%s)" "${2//[[:cntrl:]]/}" > "$1/discord-name" 2>/dev/null || :; }
  # b_log <bot dir> <what>: a line in the bot's access.log, as access set writes it (the token: the fact only).
  b_log() { (umask 077; printf '%s %s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(id -un 2>/dev/null || echo unknown)" "$b_host_name" "$2" >> "$1/access.log") 2>/dev/null || :; }

  if [ "$act" = add ]; then
    # The project's channel and owner are set: add asks none of what setup asks of a project's first bot.
    DISCORD_CHANNEL_ID="" DISCORD_USER_ID="" DISCORD_ALLOW_IDS=""
    [ ! -f "$root/config.env" ] || . "$root/config.env"
    c_match "$DISCORD_CHANNEL_ID" '^[0-9]{1,20}$' && c_match "$DISCORD_USER_ID" '^[0-9]{1,20}$' ||
      { echo "claude-discord: bot: add needs a project whose channel and owner are set ($root/config.env): set up its first bot with claude-discord setup <bot> at a terminal there; nothing was changed" >&2; exit 1; }
    [ -t 0 ] && [ -t 1 ] || b_noterm
    b_read
    b_me "copy it again (Developer Portal, the bot's Bot tab, Reset Token)"
    [ "$b_isbot" = true ] || { echo "claude-discord: bot: that token is no bot's (Discord says it is a user's); nothing was changed" >&2; exit 1; }
    new=$b_user
    # Its name here is its Discord username: one that is no name here is renamed on Discord first.
    ! reserved_name "$new" || new=" $new"
    c_match "$new" "$b_name_re" || { echo "claude-discord: bot: Discord calls this bot '$b_shown', and a bot's name here is its Discord username: 2 to 32 of A-Z a-z 0-9 _ -, not starting with -, and no name claude-discord itself uses. Rename it in the Developer Portal first (the bot's Bot tab, Username), then add it again; nothing was changed" >&2; exit 1; }
    [ ! -e "$root/$new" ] || { echo "claude-discord: bot: a bot '$new' is set up in $root already (claude-discord bot $new token replaces its token); nothing was changed" >&2; exit 1; }
    mgr=""; b_case_free "$new"
    # One bot, one session: a bot set up on this machine already (its id in a bot-id, or its token in a .env) is not set
    # up twice.
    b_set_up
    if [ "$b_how" = token ] && [ -n "$b_where" ]; then
      echo "claude-discord: bot: that token is the token of $b_where already: two sessions on one token both answer; nothing was changed" >&2; exit 1
    fi
    [ -z "$b_where" ] || { echo "claude-discord: bot: that token's bot ($b_id) is set up in $b_where already: two sessions on one token both answer; nothing was changed" >&2; exit 1; }
    [ "$b_mode" != dev-manager ] || b_mgr_free "$new"
    printf '%s\n' "claude-discord: bot: add $new (Discord $b_id) on $b_host_name, $root/$new" \
      "    it listens in channel $DISCORD_CHANNEL_ID (config.env): an @mention required, from $DISCORD_USER_ID${DISCORD_ALLOW_IDS:+ and $DISCORD_ALLOW_IDS}" \
      "    mode: $b_mode$([ "$b_mode" != dev-manager ] || echo ": a hosts ledger (this machine) and its monitor, which posts in #bot-health-check")" \
      "    $([ -n "$b_start" ] && echo "it starts at once: claude-discord --bg --name $new" || echo "it is not started: claude-discord --bg --name $new starts it")"
    b_ask "Add this bot?"
    # Checked again after the question: the one window a human leaves open, in which another terminal's add or setup
    # may have made the bot (1.14.1).
    [ ! -e "$root/$new" ] || { echo "claude-discord: bot: a bot '$new' appeared in $root while the question was open; nothing was changed" >&2; exit 1; }
    # setup, as at a terminal: its answers on its stdin (the token, Enter for the mention question, the mode, Enter for a
    # manager's peers and hosts), its install questions not asked. Whatever it wrote goes when it fails: the bot was not there.
    if ! printf '%s\n\n%s\n\n\n' "$tok" "$b_mode" | CLAUDE_DISCORD_SETUP_NOASK=1 "$self_path" setup "$new"; then
      tok=""; rm -rf "${root:?}/$new"
      echo "claude-discord: bot: setup failed (above); nothing was added" >&2; exit 1
    fi
    tok=""
    printf '%s\n' "$b_id" > "$root/$new/bot-id" 2>/dev/null || :
    b_dname "$root/$new" "$new"
    b_log "$root/$new" "added (bot $b_id, mode $b_mode)"
    if [ -n "$b_start" ]; then
      ! untrusted || { echo "claude-discord: bot: $new is added, not started: $PWD is not a trusted workspace (run 'claude' here once and accept the trust prompt), then claude-discord --bg --name $new" >&2; exit 1; }
      "$self_path" --bg --name "$new" || { echo "claude-discord: bot: $new is added, but did not start (above): claude-discord --bg --name $new" >&2; exit 1; }
    fi
    echo "claude-discord: bot: $new added${b_start:+ and started}"
    exit 0
  fi

  if [ "$act" = token ]; then
    [ -t 0 ] && [ -t 1 ] || b_noterm
    b_read
    b_me "copy it again (Developer Portal, the bot's Bot tab, Reset Token)"
    [ "$b_isbot" = true ] || { echo "claude-discord: bot: that token is no bot's (Discord says it is a user's); nothing was changed" >&2; exit 1; }
    b_keep="" b_old=""
    while IFS= read -r l || [ -n "$l" ]; do
      case $l in DISCORD_BOT_TOKEN=*) [ -n "$b_old" ] || b_old=${l#DISCORD_BOT_TOKEN=};; *) b_keep="$b_keep$l"$'\n';; esac
    done < "$d/.env"
    [ "$b_old" != "$tok" ] || { b_old=""; echo "claude-discord: bot: that is $bn's token already; nothing to change"; exit 0; }
    # The same bot: its id, kept in bot-id (health keeps it), else the one Discord gives for the token in .env now (asked
    # with that token as the new one was). Never its username, which another bot may have too.
    me=""; { read -r me < "$d/bot-id"; } 2>/dev/null || :
    if ! c_match "$me" '^[0-9]{1,20}$' && [ -n "$b_old" ]; then
      b_new=$tok tok=$b_old
      b_api GET users/@me
      tok=$b_new b_new=""
      case $status in 2*) me=$(printf '%s' "$resp" | jq -r 'objects | .id // "" | tostring' 2>/dev/null) || me="";; *) me="";; esac
    fi
    b_old="" b_unchecked=""
    if c_match "$me" '^[0-9]{1,20}$'; then
      [ "$me" = "$b_id" ] || { echo "claude-discord: bot: that token is the bot $b_shown ($b_id), not $bn ($me): a token of another bot is refused, it would make this another bot; nothing was changed" >&2; exit 1; }
    else
      # Neither (no bot-id, and Discord refuses the token in .env: it was reset): a bot set up on this machine is
      # another bot; any other is said, in red, as unchecked.
      b_set_up "$d"
      [ -z "$b_where" ] || { echo "claude-discord: bot: that token is of the bot $b_shown ($b_id), set up in $b_where already: $bn's own id could not be checked, and a token of another bot is refused; nothing was changed" >&2; exit 1; }
      b_unchecked=1
    fi
    printf '%s\n' "claude-discord: bot: $bn on $b_host_name, $d/.env" \
      "    its token is replaced by this one, of $b_shown ($b_id); the old one is not kept" \
      "    a running session of $bn logs in with it within 10 s (one started before claude-discord 1.14.0: claude-discord refresh $bn --force)"
    [ -z "$b_unchecked" ] || printf '\033[1;31m  ! %s\033[0m\n    %s\n' "this bot's id could not be checked: $b_id ($b_shown)" \
      "no bot-id is kept for $bn and Discord refuses the token in its .env: that this is $bn is up to you"
    b_ask "Replace the token?"
    # By rename, never in place: the plugin re-reads .env every 10 s while it waits for a token, by its path.
    (umask 077; printf 'DISCORD_BOT_TOKEN=%s\n%s' "$tok" "$b_keep" > "$d/.env.cd.$$") && mv -f "$d/.env.cd.$$" "$d/.env" ||
      { rm -f "$d/.env.cd.$$"; echo "claude-discord: bot: could not write $d/.env; it is as it was" >&2; exit 1; }
    tok=""
    printf '%s\n' "$b_id" > "$d/bot-id" 2>/dev/null || :
    b_dname "$d" "$b_user"
    b_log "$d" "token: replaced (bot $b_id)"
    echo "claude-discord: bot: $d/.env written. A running session of $bn logs in with it within 10 s."
    exit 0
  fi

  if [ "$act" = recover ]; then
    # recover [--fresh] (1.16.0): the TUI's f and F. The decision is made here, on the bot's machine, the only place that
    # can read `claude agents --json`, pinned-job and plugin-sessions/. The bot's last session, when it is still listed
    # as started in this project, is restarted in place: `claude respawn <id>` (the same id and sessionId, a new process,
    # its conversation kept, its hooks run again: on-session-start starts the keeper and primes it). None listed: a
    # fresh --bg start. Two or more listed: refused (which copy to stop is a person's call), unless --fresh, which stops
    # every one and starts one, as refresh --force does for a stale bot (no detached child: the session that runs this
    # is never the bot's own). The plan is printed with its `run:` line, the one question asked after the marker, the
    # command run in the foreground and its status passed on; nothing runs on `n` or without a terminal. Not waited
    # for: whether the bot answers is the monitor's next pass's to say (a respawned worker may sit idle until a message).
    [ -z "${DISCORD_STATE_DIR:-}" ] || ! [ "$DISCORD_STATE_DIR" -ef "$d" ] ||
      { echo "claude-discord: bot: a session cannot recover its own bot: it is stopped or restarted on the way. Run it in a terminal outside $bn's session" >&2; exit 2; }
    b_unknown() { echo "claude-discord: bot: 'claude agents --json' failed, so what is running is unknown; nothing was run" >&2; exit 1; }
    # The bot's last session: <bot dir>/pinned-job (the job id of the last background session this bot pinned, written at
    # every startup and resume), else the newest marker of <bot dir>/plugin-sessions/ (one per session, named by its
    # session id, touched by every hook event; a resumed job keeps its id and changes its sessionId, so the first 8
    # characters count too). Each counts only when claude agents lists it (no --all: a retired session is not listed;
    # `state done` is not dead) as started in this project: a pinned job of another cwd is a bot moved since, and a
    # respawn would restart it there. Then live_sessions (by name, or by the job record): one row is that session.
    b_pin=""; { read -r b_pin < "$d/pinned-job"; } 2>/dev/null || :
    c_match "$b_pin" '^[0-9a-f]{8}$' || b_pin=""
    b_sid=$(ls -t "$d/plugin-sessions" 2>/dev/null | head -n 1) || b_sid=""
    c_match "$b_sid" '^[0-9a-f-]{8,64}$' || b_sid=""
    b_agents=$(claude agents --json 2>/dev/null) || b_unknown
    b_last=$(printf '%s' "${b_agents:-null}" | jq -r --arg pin "$b_pin" --arg sid "$b_sid" --arg cwd "$(pwd -P)" '
      if type != "array" then error("not a list") else
        [.[] | objects | select(.cwd == $cwd and (.id | type) == "string")] as $rows |
        (first($rows[] | select($pin != "" and .id == $pin) | . + {how: "pinned-job"}) //
         first($rows[] | select($sid != "" and ((.sessionId // "" | tostring) == $sid or .id == $sid[0:8])) | . + {how: "plugin-sessions"}) //
         empty)
        | "\(.id) \(.how) \(.state // "-") \(.pid // "-")" end' 2>/dev/null) || b_unknown
    live=$(live_sessions "$bot" "$d") || b_unknown
    b_id="" b_how="" b_state="" b_pid=""; [ -z "$b_last" ] || read -r b_id b_how b_state b_pid <<<"$b_last"
    # Every listed session of the bot started here: live_sessions' rows, and the last session when it is not among them
    # (renamed with /rename and no job record of this bot). Two on one token both answer: the count decides.
    b_rows=$live
    [ -z "$b_id" ] || printf '%s\n' "$live" | grep -q "^$b_id " || b_rows="$b_rows${b_rows:+$'\n'}$b_id $b_pid"
    b_n=0 b_names="" b_stops=""
    while read -r id pid; do
      [ -n "$id" ] || continue
      b_n=$((b_n + 1)); b_names="$b_names${b_names:+, }$id pid $pid"
      [ "$id" != - ] && b_stops="$b_stops${b_stops:+, }claude stop $id" || b_stops="$b_stops${b_stops:+, }kill $pid"
    done <<<"$b_rows"
    if [ -n "$b_id" ]; then b_found="its last session $b_id ($b_how) is listed by claude agents (state $b_state, pid $b_pid)"
    elif [ "$b_n" = 1 ]; then read -r b_id b_pid <<<"$b_rows"; b_found="its session $b_id is listed by claude agents (by its name or its job record, pid $b_pid)"
    elif [ -n "$b_pin$b_sid" ]; then b_found="its last session ${b_pin:-$b_sid} ($([ -n "$b_pin" ] && echo pinned-job || echo plugin-sessions)) is not listed by claude agents as started in $PWD, and no session of $bn started there is"
    else b_found="it has no last session on record (no pinned-job, no plugin-sessions marker), and no session of $bn started in $PWD is listed"; fi
    if [ -n "$b_fresh" ]; then b_do=fresh b_cmd="claude-discord --bg --name $bn"
    elif [ "$b_n" -ge 2 ]; then
      echo "claude-discord: bot: $b_n sessions of $bn are listed ($b_names): two on one token both answer. Stop the copy by hand (claude stop <id>), or recover --fresh stops every one and starts one; nothing was run" >&2; exit 1
    elif [ "$b_n" = 1 ] && [ "$b_id" = - ]; then
      # A foreground session (no job record: started at a terminal, or /bg'd) is not the daemon's to respawn.
      echo "claude-discord: bot: the one listed session of $bn is a foreground one (pid $b_pid, no job id), which claude respawn cannot restart: stop it by hand, or recover --fresh stops it and starts a background one; nothing was run" >&2; exit 1
    elif [ "$b_n" = 1 ]; then b_do=respawn b_cmd="claude respawn $b_id"
    else b_do=start b_cmd="claude-discord --bg --name $bn"; fi
    # Trust before anything is stopped: a `claude --bg` start refuses an untrusted workspace (fail-open, as refresh).
    [ "$b_do" = respawn ] || ! untrusted || { echo "claude-discord: bot: $PWD is not a trusted workspace, so a --bg start would refuse: run 'claude' here once and accept the trust prompt; nothing was run" >&2; exit 1; }
    printf '%s\n' "claude-discord: bot: recover${b_fresh:+ --fresh} $bn on $b_host_name, $d" "    $b_found"
    case $b_do in
      respawn) echo "    run: $b_cmd    (the session comes back under the same id with a new process; its conversation is kept, and its hooks run again)";;
      start) echo "    run: cd $PWD && $b_cmd    (a fresh session; handoff.md is folded in when there is one)";;
      *) if [ -n "$b_stops" ]; then echo "    run: $b_stops, then cd $PWD && $b_cmd    (every listed session stopped first; a fresh session, its conversation lost unless handoff.md is there)"
         else echo "    run: cd $PWD && $b_cmd    (no session of $bn is listed, so nothing is stopped; a fresh session)"; fi;;
    esac
    [ -t 0 ] && [ -t 1 ] || { echo "claude-discord: bot: not a terminal (stdin and stdout), so nothing was run: run it in a terminal to answer" >&2; exit 3; }
    b_ask "Recover $bn?"
    # b_rlog <command> <exit>: a line in the bot's recover.log, in the shape of access.log's.
    b_rlog() { (umask 077; printf '%s %s %s recover%s: %s (exit %s)\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(id -un 2>/dev/null || echo unknown)" "$b_host_name" "${b_fresh:+ --fresh}" "$1" "$2" >> "$d/recover.log") 2>/dev/null || :; }
    if [ "$b_do" = fresh ] && [ -n "$b_rows" ] && ! stop_sessions "$bn" "$b_rows"; then
      # Nothing is started: a start beside a session that still runs puts two sessions on one token.
      b_rlog "$b_stops" 1
      echo "claude-discord: bot: $bn still runs after stop (pid ${alive[*]}): nothing was started${stopped_ids:+; stopped: $stopped_ids}. Stop it by hand (claude stop <id>), then claude-discord --bg --name $bn" >&2; exit 1
    fi
    b_rc=0
    case $b_do in
      respawn) claude respawn "$b_id" || b_rc=$?;;
      fresh) start_fresh "$self_path" "$bot" "$d" "Catch up on the channel." || b_rc=$?;;
      *) start_fresh "$self_path" "$bot" "$d" || b_rc=$?;;
    esac
    b_rlog "$b_cmd" "$b_rc"
    echo "claude-discord: bot: ran $b_cmd (exit $b_rc)${put_back:+; its handoff was put back}; the monitor's next pass says whether $bn answers"
    [ "$b_rc" = 0 ] || exit 1
    exit 0
  fi

  # rename <new>. What is keyed by the name here, and how each moves (README, A bot's name):
  #   the bot's directory, with its token, access.json, mode, ledger, logs, caches and handoff: one rename(2);
  #   its running session: stopped first, started again under the new name after, from its handoff.md when it has one;
  #   this bot's line in the peers.json of each project of this machine, found by its id (a bot skips its own NAME there);
  #   its scratch directory, ~/.claude-discord/scratch/<name>;
  #   a manager's backend: its keeper and monitor stopped, records/monitor/<name> (state, alerts, log) moved, state.json's
  #   manager renamed, the backend started again unless its owner had stopped it, and its watcher record on each host
  #   of its ledger renamed (over ssh, as hosts add wrote it).
  # Not here: the monitor's row of the old name leaves at its next pass, unannounced; peers on other machines keep the old
  # name in their peers.json (they reach it by id); both are said. Before the directory moves, a failure undoes what was
  # stopped; after it, what fails is said and the rest goes on: the name here is the new one either way.
  nd=$root/$new
  ! reserved_name "$new" || { echo "claude-discord: bot: '$new' is a word of claude-discord (a subcommand, bot add, or a directory beside the bots), so no bot may take the name" >&2; exit 2; }
  [ ! -e "$nd" ] || [ "$nd" -ef "$d" ] || { echo "claude-discord: bot: a bot '$new' is set up in $root already" >&2; exit 1; }
  # The session that would run this is the one stopped on the way.
  [ -z "${DISCORD_STATE_DIR:-}" ] || ! [ "$DISCORD_STATE_DIR" -ef "$d" ] ||
    { echo "claude-discord: bot: a session cannot rename its own bot: it is stopped on the way. Run it in a terminal outside $bn's session" >&2; exit 2; }
  mode=""; { read -r mode < "$d/mode"; } 2>/dev/null || :
  mgr=""; [ "$mode" != dev-manager ] || [ ! -f "$d/hosts" ] || [ "$new" = "$bot" ] || mgr=1
  [ -z "$mgr" ] || b_mgr_free "$new" "$bot"
  b_case_free "$new" "$d"
  tok=""
  { while IFS= read -r l || [ -n "$l" ]; do case $l in DISCORD_BOT_TOKEN=*) tok=${l#DISCORD_BOT_TOKEN=}; break;; esac; done < "$d/.env"; } 2>/dev/null || :
  [ -n "$tok" ] || { echo "claude-discord: bot: no token in $d/.env (claude-discord bot $bn token)" >&2; exit 1; }
  b_me "claude-discord bot $bn token, first"
  me=""; { read -r me < "$d/bot-id"; } 2>/dev/null || :
  ! c_match "$me" '^[0-9]{1,20}$' || [ "$me" = "$b_id" ] ||
    { echo "claude-discord: bot: $d/.env holds the token of the bot $b_shown ($b_id), not $bn's ($me): claude-discord bot $bn token puts its own back; nothing was changed" >&2; exit 1; }
  [ "$b_user" != "$new" ] || [ "$new" != "$bot" ] || { echo "claude-discord: bot: $bn is its name here and on Discord already; nothing to change"; exit 0; }
  # A peer of that name in peers.json: the bot would skip it as itself.
  b_clash=$(jq -r --arg n "$new" --arg id "$b_id" 'first(.peers[]? | objects | select((.name // "" | tostring | ascii_downcase) == ($n | ascii_downcase) and (.bot_id // "" | tostring) != $id) | .bot_id | tostring) // empty' "$root/peers.json" 2>/dev/null) || b_clash=""
  [ -z "$b_clash" ] || { echo "claude-discord: bot: the peer $new (${b_clash//[!0-9]/}) in $root/peers.json has that name, and a bot skips its own name there; nothing was changed" >&2; exit 1; }
  live=""
  if [ "$new" != "$bot" ]; then
    live=$(live_sessions "$bot" "$d") || { echo "claude-discord: bot: 'claude agents --json' failed, so what runs is unknown; nothing was changed" >&2; exit 1; }
    [ -z "$live" ] || ! untrusted || { echo "claude-discord: bot: $PWD is not a trusted workspace, so $bn would not start again after the rename: run 'claude' here once and accept the trust prompt; nothing was changed" >&2; exit 1; }
  fi
  b_n=0; [ -z "$live" ] || b_n=$(printf '%s\n' "$live" | grep -c .)
  printf '%s\n' "claude-discord: bot: $bn on $b_host_name, $root"
  if [ "$b_user" = "$new" ]; then echo "    Discord: it is $new there already: Discord is not asked to change it"
  else echo "    Discord: $b_shown -> $new (about 2 changes an hour are allowed: if Discord refuses, nothing here is changed)"; fi
  if [ "$new" != "$bot" ]; then
    echo "    here: $bn -> $new (its directory, and its line in the peers.json of this machine's projects)"
    if [ -z "$live" ]; then echo "    it is not running: renamed only (claude-discord --bg --name $new starts it)"
    elif [ -s "$d/handoff.md" ]; then echo "    it runs ($b_n session$([ "$b_n" = 1 ] || echo s)): stopped, renamed, started again as $new from its handoff.md"
    else echo "    it runs ($b_n session$([ "$b_n" = 1 ] || echo s)): stopped, renamed, started again as $new with no handoff.md: an empty context that catches up from the channel (its conversation is not carried over)"; fi
    [ -z "$mgr" ] || echo "    a manager: its keeper and monitor stop, its state, alerts and log move to $M/$new, its backend starts again as $new, and its record on each ledger host is renamed"
  fi
  [ -t 0 ] && [ -t 1 ] || { echo "claude-discord: bot: not a terminal (stdin and stdout), so nothing was changed: run it in a terminal to answer" >&2; exit 3; }
  b_ask "Rename it to $new?"
  b_disc=""
  if [ "$b_user" != "$new" ]; then
    b_api PATCH users/@me "{\"username\":\"$new\"}"
    l=$(printf '%s' "$resp" | jq -r 'objects | (.username // "") | tostring' 2>/dev/null) || l=""
    case $status in
      2*) [ "$l" = "$new" ] || { echo "claude-discord: bot: Discord calls it '$(printf '%s' "$l" | LC_ALL=C tr -d '\000-\037\177' | cut -c1-40)' now, not $new: nothing here was changed" >&2; exit 1; };;
      *) l=$(printf '%s' "$resp" | jq -r 'objects | [.errors.username._errors[]?.message?, .message, (.retry_after | if . then "retry after \(.) s" else null end)] | map(select(type == "string")) | join(": ")' 2>/dev/null) || l=""
         echo "claude-discord: bot: Discord refused the new name (HTTP $status${l:+: $(printf '%s' "$l" | LC_ALL=C tr -d '\000-\037\177' | cut -c1-200)}); nothing was changed" >&2; exit 1;;
    esac
    b_disc=1
    b_log "$d" "rename: on Discord $b_shown -> $new"
  fi
  tok=""
  b_dname "$d" "$new"
  [ "$new" != "$bot" ] || { echo "claude-discord: bot: Discord calls it $new now, as it is called here"; exit 0; }
  b_again=""; [ -z "$b_disc" ] || b_again=" (Discord calls it $new now: run this again to rename it here)"
  if [ -n "$live" ] && ! stop_sessions "$bn" "$live"; then
    # Nothing is started again: a start beside a session that still runs puts two sessions on one token (the very thing
    # stop_sessions guards). The ones that did stop are named, with the command that starts one.
    echo "claude-discord: bot: $bn still runs after stop (pid ${alive[*]}): nothing here was renamed$b_again. Stop it by hand first${stopped_ids:+; stopped and not started again: $stopped_ids (claude-discord --bg --name $bot starts one)}" >&2; exit 1
  fi
  b_undo() {  # the directory did not move: what was stopped runs again; of the markers, only the one made here goes
    if [ -n "$mgr" ]; then
      [ -z "$b_made" ] || { rm -f "$M/$new/stopped"; rmdir "$M/$new" 2>/dev/null || :; }
      [ -n "$was_stopped" ] || bash "$self_root/monitor/monitor.sh" "$self_path" --start "$bot" </dev/null >/dev/null 2>&1 || :
    fi
    [ -z "$live" ] || start_fresh "$self_path" "$bot" "$d" "Catch up on the channel and continue from your handoff." || :
  }
  was_stopped="" b_made=""
  if [ -n "$mgr" ]; then
    [ ! -e "$M/$bot/stopped" ] || was_stopped=1
    bash "$self_root/monitor/monitor.sh" "$self_path" --stop "$bot" </dev/null >/dev/null 2>&1 || :
    # A marker under the new name before the directory has it: no session's hook starts a backend for it meanwhile. One
    # directory for both names (a case-only rename on a case-insensitive file system): the marker --stop wrote is it.
    if ! { [ -e "$M/$new" ] && [ "$M/$new" -ef "$M/$bot" ]; }; then
      mkdir -p "$M" && mkdir "$M/$new" && b_made=1 && : > "$M/$new/stopped" ||
        { b_undo; echo "claude-discord: bot: could not make $M/$new: nothing here was renamed$b_again" >&2; exit 1; }
    fi
  fi
  b_mv "$d" "$nd" ||
    { b_undo; echo "claude-discord: bot: could not rename $d: nothing here was renamed$b_again" >&2; exit 1; }
  b_log "$nd" "rename: $bn -> $new"
  b_rc=0 b_warn=""
  # This bot's line in each project's peers.json, by its id.
  while IFS= read -r p || [ -n "$p" ]; do
    p=${p%$'\r'}
    [ -n "$p" ] && [ -f "$p/.claude/discord-agents/peers.json" ] || continue
    jq_edit "$p/.claude/discord-agents/peers.json" --arg id "$b_id" --arg n "$new" \
      'if (.peers | type) == "array" then .peers |= map(if type == "object" and ((.bot_id // "") | tostring) == $id then .name = $n else . end) else . end'
  done < <(printf '%s\n' "$PWD"; cat "$helpers/records/projects" 2>/dev/null)
  if [ -d "$helpers/scratch/$bot" ] && { [ ! -e "$helpers/scratch/$new" ] || [ "$helpers/scratch/$new" -ef "$helpers/scratch/$bot" ]; }; then
    b_mv "$helpers/scratch/$bot" "$helpers/scratch/$new" 2>/dev/null || b_warn="$b_warn"$'\n'"    its scratch directory stays $helpers/scratch/$bot"
  elif [ -d "$helpers/scratch/$bot" ]; then   # the new name's is there already (a bot of that name once): neither is touched, said (1.14.1)
    b_warn="$b_warn"$'\n'"    its scratch directory stays $helpers/scratch/$bot: $helpers/scratch/$new is there already"
  fi
  if [ -n "$mgr" ]; then
    [ -z "$b_made" ] || rm -f "$M/$new/stopped"
    if [ ! -d "$M/$bot" ]; then
      [ -z "$b_made" ] || rmdir "$M/$new" 2>/dev/null || :
    elif { [ -z "$b_made" ] || rmdir "$M/$new" 2>/dev/null; } && b_mv "$M/$bot" "$M/$new"; then
      # The monitor starts from a state.json only when it names this manager: else it would post standing findings again.
      { jq -c --arg m "$new" '.manager = $m' "$M/$new/state.json" > "$M/$new/state.json.tmp" && mv -f "$M/$new/state.json.tmp" "$M/$new/state.json"; } 2>/dev/null || rm -f "$M/$new/state.json.tmp"
    else
      b_warn="$b_warn"$'\n'"    its state and alerts stay in $M/$bot: the monitor of $new starts with none (a finding standing now is posted again)"
    fi
    if [ -n "$was_stopped" ]; then
      b_warn="$b_warn"$'\n'"    its backend stays stopped, as you left it: claude-discord monitor --start $new"
    else
      bash "$self_root/monitor/monitor.sh" "$self_path" --start "$new" </dev/null >/dev/null 2>&1 ||
        { b_rc=1; b_warn="$b_warn"$'\n'"    its backend did not start: claude-discord monitor --start $new"; }
    fi
    # Its record on each host of its ledger (hosts add wrote it): renamed over ssh, a host that does not answer said.
    mine=""; { read -r mine < "$helpers/host-id"; } 2>/dev/null || :
    if c_match "$mine" "$hid_re" && c_match "$new" "$mgr_re"; then
      while IFS= read -r line || [ -n "$line" ]; do
        set -f; set -- ${line%$'\r'}; set +f
        a=${1:-}
        [ "$a" != local ] && c_match "$a" "$alias_re" || continue
        h_ssh "$a" "~/.local/bin/claude-discord --version --watch $new $mine $a"
        if [ "$h_rc" = 0 ]; then
          ! c_match "$bot" "$mgr_re" || h_ssh "$a" "~/.local/bin/claude-discord --version --unwatch $bot $mine"
        else
          b_warn="$b_warn"$'\n'"    $a did not answer (ssh exit $h_rc), so its watcher record still names $bn: ssh $a '~/.local/bin/claude-discord --version --watch $new $mine $a'"
        fi
      done < "$nd/hosts"
    fi
  fi
  b_ran=""
  if [ -n "$live" ]; then
    if start_fresh "$self_path" "$new" "$nd" "Catch up on the channel and continue from your handoff."; then b_ran=1
    else b_rc=1; b_warn="$b_warn"$'\n'"    $new did not start (above)${put_back:+; its handoff was put back}: claude-discord --bg --name $new"; fi
  fi
  echo "claude-discord: bot: renamed: $nd${b_disc:+ (and on Discord)}"
  [ -z "$b_ran" ] || echo "    its session runs again as $new"
  [ -n "$live" ] || echo "    it was not running: claude-discord --bg --name $new starts it"
  echo "    the monitor shows $new from its next pass; the row of $bn leaves it then, unannounced"
  [ "$mode" != dev-manager ] || echo "    peers on other machines list it as $bn in their peers.json, by its id $b_id, so they still reach it; to show the new name there, their owner runs claude-discord setup <their bot> --mode, with the peer $new:$b_id:<owner id>:<machine>"
  [ -z "$b_warn" ] || printf 'claude-discord: bot: not done:%s\n' "$b_warn" >&2
  # The last line, for a program (the TUI follows a renamed manager by it): the directory moved, whatever failed after.
  echo "renamed: $bn -> $new"
  exit "$b_rc"
fi
