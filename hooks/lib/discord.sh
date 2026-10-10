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
plugin_root=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd -P) || plugin_root=""
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
