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

if [ -n "${DISCORD_STATE_DIR:-}" ] && [ -d "$DISCORD_STATE_DIR" ]; then
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

# user_info <id> [name]: looks a Discord user up and sets u_kind (bot, human,
# or none: no such user) and u_name. Answers are cached as "<id> kind name"
# in <state dir>/user-kinds, since an account never changes kind; a peers.json
# bot needs no call. A cached kind is enough unless "name" is asked for and
# the line has none. Returns 0 for a user, 1 for none or not an id, 2 when
# it could not tell (no token, no curl, a timeout, another status), uncached.
user_info() {
  local id=$1 i kind name out status k=$DISCORD_STATE_DIR/user-kinds
  u_kind="" u_name=""
  case $id in ''|*[!0-9]*) return 1;; esac
  u_name=$(jq -r --arg id "$id" 'first(.peers[]? | select((.bot_id // "" | tostring) == $id) | .name // "") // empty' "$DISCORD_STATE_DIR/../peers.json" 2>/dev/null) || u_name=""
  [ -z "$u_name" ] || { u_kind=bot; return 0; }
  if [ -f "$k" ]; then
    while read -r i kind name; do
      [ "$i" = "$id" ] || continue
      u_kind=$kind; [ -z "$name" ] || u_name=$name
    done < "$k"
  fi
  [ "$u_kind" != none ] || return 1
  [ -z "$u_kind" ] || [ -z "${2:-}" ] || [ -n "$u_name" ] || u_kind=""
  [ -z "$u_kind" ] || return 0
  [ -n "$bot_token" ] || load_token
  [ -n "$bot_token" ] && command -v curl >/dev/null 2>&1 || return 2
  out=$(printf 'Authorization: Bot %s\n' "$bot_token" | curl -s -m 3 -w '\n%{http_code}' -H @- "https://discord.com/api/v10/users/$id" 2>/dev/null) || return 2
  status=${out##*$'\n'}
  case $status in
    200) { read -r kind; IFS= read -r name; } < <(printf '%s' "${out%$'\n'*}" | jq -r 'select((.id // "" | tostring) != "") | (if .bot == true then "bot" else "human" end), ((.global_name // .username // "") | gsub("[\\s]+"; " "))' 2>/dev/null)
         [ -n "$kind" ] || return 2 ;;
    404) kind=none name="" ;;
    *) return 2 ;;
  esac
  printf '%s %s %s\n' "$id" "$kind" "$name" >> "$k" 2>/dev/null
  u_kind=$kind u_name=$name
  [ "$kind" != none ]
}

# is_bot_user <user id>: succeeds when that Discord user is a bot (user_info).
# Anything unknown fails: a guard built on this must never block on a guess.
is_bot_user() {
  user_info "$1"
  [ "$u_kind" = bot ]
}

# is_channel <id>: succeeds when that id is a Discord channel or thread (a
# snowflake is unique across Discord, so an id GET /channels answers for is
# one). The bot's own channel and access.json's group keys are; any other id
# is looked up in <state dir>/channel-ids ("<id> channel|other", tools/thread
# adds every thread it opens), else asked once with GET /channels/{id}: 200
# is a channel, 404 is not, and both are cached. Anything else (no token, no
# curl, a timeout, another status) returns 2, uncached: unknown, not "no".
is_channel() {
  local id=$1 i kind out status k=$DISCORD_STATE_DIR/channel-ids
  case $id in ''|*[!0-9]*) return 1;; esac
  [ "$id" != "${bot_channel:-}" ] || return 0
  jq -e --arg id "$id" '.groups | objects | has($id)' "$DISCORD_STATE_DIR/access.json" >/dev/null 2>&1 && return 0
  if [ -f "$k" ]; then
    while read -r i kind; do [ "$i" != "$id" ] || { [ "$kind" = channel ]; return; }; done < "$k"
  fi
  [ -n "$bot_token" ] || load_token
  [ -n "$bot_token" ] && command -v curl >/dev/null 2>&1 || return 2
  out=$(printf 'Authorization: Bot %s\n' "$bot_token" | curl -s -m 3 -w '\n%{http_code}' -H @- "https://discord.com/api/v10/channels/$id" 2>/dev/null) || return 2
  status=${out##*$'\n'}
  case $status in 200) kind=channel;; 404) kind=other;; *) return 2;; esac
  printf '%s %s\n' "$id" "$kind" >> "$k" 2>/dev/null
  [ "$kind" = channel ]
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
