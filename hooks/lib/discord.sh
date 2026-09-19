# Sourced by every script under hooks/turn/, hooks/peers/ and
# hooks/autoresearchclaw/; never registered on its own. Resolves the current
# bot's identity, channel and mode from $DISCORD_STATE_DIR and provides
# `react` to add a reaction, `post` to send a channel message and `peers` to
# list a dev-manager's peers. No `set -e`: a caller under `set -u` must survive
# every file here being missing.

bot_name=""
bot_channel=""
bot_groups=""
bot_token=""
bot_mode=""

# resolve_channel: sets bot_channel to the bot's channel. That is the single
# group key in its access.json: the plugin reads that file on every message,
# and moving a bot to another channel is an edit there, which config.env's
# DISCORD_CHANNEL_ID (written once, at setup) does not follow. Without
# exactly one digits-only key (the file missing or unreadable, no group, or
# several) it is config.env's DISCORD_CHANNEL_ID. bot_groups holds the keys,
# one per line, so a caller can tell "several" apart. The start path in
# claude-discord applies the same rule.
resolve_channel() {
  local config="$DISCORD_STATE_DIR/../config.env"
  bot_channel=""
  if [ -f "$config" ]; then
    bot_channel=$(grep '^DISCORD_CHANNEL_ID=' "$config" | head -1)
    bot_channel=${bot_channel#DISCORD_CHANNEL_ID=}
    bot_channel=${bot_channel#\'}
    bot_channel=${bot_channel%\'}
  fi
  bot_groups=$(jq -r '.groups | objects | keys[]' "$DISCORD_STATE_DIR/access.json" 2>/dev/null) || bot_groups=""
  case $bot_groups in
    ''|*[!0-9]*) ;;
    *) bot_channel=$bot_groups ;;
  esac
}

if [ -n "${DISCORD_STATE_DIR:-}" ] && [ -d "$DISCORD_STATE_DIR" ]; then
  bot_name=$(basename "$DISCORD_STATE_DIR")
  resolve_channel
  env_file="$DISCORD_STATE_DIR/.env"
  if [ -f "$env_file" ]; then
    bot_token=$(grep '^DISCORD_BOT_TOKEN=' "$env_file" | head -1)
    bot_token=${bot_token#DISCORD_BOT_TOKEN=}
  fi
  bot_mode=$(cat "$DISCORD_STATE_DIR/mode" 2>/dev/null) || bot_mode=""
fi

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
  [ -n "$bot_token" ] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  printf 'Authorization: Bot %s\n' "$bot_token" | curl -s -m 5 -X PUT -H @- \
    "https://discord.com/api/v10/channels/$1/messages/$2/reactions/$3/@me" \
    >/dev/null 2>&1 &
  disown 2>/dev/null || :
}

# post <channel_id> <text>
# POSTs <text> as a new message in the channel, detached and with the token
# on stdin exactly like react. Mentions are switched off (allowed_mentions),
# so no text can ping anyone, and the text is cut at Discord's 2000
# characters. A no-op without a token, curl or text, or with a non-numeric
# channel id.
post() {
  case $1 in ''|*[!0-9]*) return 0;; esac
  [ -n "$2" ] && [ -n "$bot_token" ] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  local body
  body=$(jq -nc --arg c "$2" '{content: ($c | .[0:2000]), allowed_mentions: {parse: []}}' 2>/dev/null) || return 0
  printf 'Authorization: Bot %s\n' "$bot_token" | curl -s -m 10 -X POST -H @- -H 'Content-Type: application/json' \
    --data-binary "$body" "https://discord.com/api/v10/channels/$1/messages" \
    >/dev/null 2>&1 &
  disown 2>/dev/null || :
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
