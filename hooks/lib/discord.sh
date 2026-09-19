# Sourced by hooks/turn/on-prompt, on-reply and on-stop; never registered
# on its own. Resolves the current bot's identity from $DISCORD_STATE_DIR
# and provides `react` to add a reaction. No `set -e`: a caller under
# `set -u` must survive every file here being missing.

bot_name=""
bot_channel=""
bot_token=""

if [ -n "${DISCORD_STATE_DIR:-}" ] && [ -d "$DISCORD_STATE_DIR" ]; then
  bot_name=$(basename "$DISCORD_STATE_DIR")
  config="$DISCORD_STATE_DIR/../config.env"
  if [ -f "$config" ]; then
    bot_channel=$(grep '^DISCORD_CHANNEL_ID=' "$config" | head -1)
    bot_channel=${bot_channel#DISCORD_CHANNEL_ID=}
    bot_channel=${bot_channel#\'}
    bot_channel=${bot_channel%\'}
  fi
  env_file="$DISCORD_STATE_DIR/.env"
  if [ -f "$env_file" ]; then
    bot_token=$(grep '^DISCORD_BOT_TOKEN=' "$env_file" | head -1)
    bot_token=${bot_token#DISCORD_BOT_TOKEN=}
  fi
fi

# react <chat_id> <message_id> <url-encoded emoji>
# PUTs the reaction via curl, fully detached (stdin/stdout/stderr redirected,
# backgrounded) so the caller returns before the HTTP call finishes. curl
# honours HTTPS_PROXY on its own; nothing extra is needed for that. A no-op
# when there is no token (covers a missing state dir too, since bot_token
# stays empty then) or no curl on PATH.
react() {
  [ -n "$bot_token" ] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  curl -s -m 5 -X PUT \
    -H "Authorization: Bot $bot_token" \
    "https://discord.com/api/v10/channels/$1/messages/$2/reactions/$3/@me" \
    </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || :
}
