#!/usr/bin/env bash
# Acceptance test for dotfiles/scripts/claude-discord. Runs entirely in a
# throwaway HOME; touches nothing real. Usage: test-claude-discord.sh <script>
set -euo pipefail
S=${1:?script path}; S=$(cd "$(dirname "$S")" && pwd)/$(basename "$S")   # absolute: the test cd-s into a throwaway project
D=$(dirname "$S")   # repo root: where hooks/ and install.sh live

CMD_PROMPT='h="$CLAUDE_PROJECT_DIR/.claude/discord-agents/hooks/turn/on-prompt"; [ ! -x "$h" ] || "$h"'
CMD_REPLY='h="$CLAUDE_PROJECT_DIR/.claude/discord-agents/hooks/turn/on-reply"; [ ! -x "$h" ] || "$h"'
CMD_STOP='h="$CLAUDE_PROJECT_DIR/.claude/discord-agents/hooks/turn/on-stop"; [ ! -x "$h" ] || "$h"'
CMD_COMPACT='h="$CLAUDE_PROJECT_DIR/.claude/discord-agents/hooks/turn/on-compact"; [ ! -x "$h" ] || "$h"'
has_cmd() { jq -e --arg ev "$1" --arg cmd "$2" '[.hooks[$ev][]?.hooks[]?.command] | index($cmd) != null' "$3" >/dev/null 2>&1; }
has_matcher() { jq -e --arg ev "$1" --arg m "$2" --arg cmd "$3" '[.hooks[$ev][]? | select(.matcher == $m) | .hooks[]?.command] | index($cmd) != null' "$4" >/dev/null 2>&1; }
has_hooks() {  # $1 = settings.json path; all four entries present
  has_cmd UserPromptSubmit "$CMD_PROMPT" "$1" &&
  has_matcher PostToolUse mcp__plugin_discord_discord__reply "$CMD_REPLY" "$1" &&
  has_cmd Stop "$CMD_STOP" "$1" &&
  has_matcher SessionStart 'compact|clear' "$CMD_COMPACT" "$1"
}
wait_for_file() {  # $1 = path; up to 2s in 0.1s steps, for an async write to land
  local n=0
  while [ ! -s "$1" ] && [ "$n" -lt 20 ]; do sleep 0.1; n=$((n+1)); done
}

bash -n "$S"
bash -n "$D/install.sh"
bash -n "$D/hooks/lib/discord.sh"
bash -n "$D/hooks/turn/on-prompt"
bash -n "$D/hooks/turn/on-reply"
bash -n "$D/hooks/turn/on-stop"
bash -n "$D/hooks/turn/on-compact"
bash -n "$D/hooks/peers/mention-guard"
bash -n "$D/hooks/peers/checkin"
bash -n "$D/hooks/peers/edit-gate"
[ "$(grep -c "if (msg.author.bot) return" "$S")" = 1 ] || { echo "FAIL: server.ts patch block must appear exactly once in the wrapper"; exit 1; }

export HOME=/tmp/claude-discord-test-$$; mkdir -p "$HOME"; trap 'rm -rf /tmp/claude-discord-test-$$' EXIT
mkdir -p "$HOME/.claude/plugins" "$HOME/fakeplugin" "$HOME/bin"
echo '{"plugins":{"discord@claude-plugins-official":[{"installPath":"'"$HOME"'/fakeplugin"}]}}' > "$HOME/.claude/plugins/installed_plugins.json"
printf 'client.on(%s, msg => {\n  if (msg.author.bot) return\n  handleInbound(msg)\n})\nfunction isAddressed(msg) {\n  if (client.user && msg.mentions.has(client.user)) return true\n}\n' "'messageCreate'" > "$HOME/fakeplugin/server.ts"
printf '#!/bin/bash\necho "LAUNCHER $*"\n' > "$HOME/bin/claude-launcher"; chmod +x "$HOME/bin/claude-launcher"
printf '#!/bin/bash\necho "PLAIN $*"\n' > "$HOME/bin/claude"; chmod +x "$HOME/bin/claude"
CURL_LOG="$HOME/curl.log"; : > "$CURL_LOG"
CURL_STDIN_LOG="$HOME/curl.stdin.log"; : > "$CURL_STDIN_LOG"
cat > "$HOME/bin/curl" <<'EOF'
#!/bin/bash
# Logs its args to CURL_LOG instead of stdout, since the caller redirects
# stdout/stderr to /dev/null for the real, detached curl call. Also drains
# stdin to CURL_STDIN_LOG, since the real call sends the auth header there
# (-H @-), never in argv.
printf '%s\n' "$*" >> "$CURL_LOG"
cat >> "$CURL_STDIN_LOG" 2>/dev/null
EOF
chmod +x "$HOME/bin/curl"
export PATH="$HOME/bin:$PATH"
export CURL_LOG CURL_STDIN_LOG
export CLAUDE_DISCORD_LAUNCHER=claude-launcher
mkdir -p "$HOME/.claude-discord"; : > "$HOME/.claude-discord/discord-proxy.ts"
cp -r "$D/hooks" "$HOME/.claude-discord/hooks"   # stand-in for install.sh, not exercised here
cp -r "$D/rules" "$HOME/.claude-discord/rules"
P="$HOME/project"; mkdir -p "$P"; cd "$P"; git init -q .
R="$P/.claude/discord-agents"

printf '1550575144320110662\n111\n222, 333 ,\ntokA\ny\n' | bash "$S" setup alpha >/dev/null
[ "$(jq -r '.groups["1550575144320110662"].requireMention' "$R/alpha/access.json")" = false ]
[ "$(jq -c '.groups["1550575144320110662"].allowFrom' "$R/alpha/access.json")" = '["111","222","333"]' ]
[ "$(jq -c '.allowFrom' "$R/alpha/access.json")" = '["111"]' ]
[ "$(jq -r '.ackReaction' "$R/alpha/access.json")" = "👀" ]
grep -q "^DISCORD_ALLOW_IDS='222,333,'$" "$R/config.env"
grep -q "^DISCORD_BOT_TOKEN=tokA$" "$R/alpha/.env"
[ "$(cat "$R/alpha/mode")" = none ] || { echo "FAIL: no mode answer (EOF) must store the default, none"; exit 1; }
echo "ok: setup writes config.env, .env, access.json (with ackReaction) and mode (default none); others normalised; no-mention honoured"

has_hooks "$P/.claude/settings.json"
[ -L "$R/hooks" ] || { echo "FAIL: setup must create the hooks symlink"; exit 1; }
[ "$(readlink "$R/hooks")" = "$HOME/.claude-discord/hooks" ] || { echo "FAIL: hooks symlink must point at the installed copy"; exit 1; }
echo "ok: setup also registers the four discord-turn hooks and the hooks symlink (after access.json is written)"

printf 'tokB\nn\n' | bash "$S" setup beta >/dev/null
[ "$(jq -r '.groups["1550575144320110662"].requireMention' "$R/beta/access.json")" = true ]
echo "ok: second bot asks only token+mention and reuses shared IDs"

printf '999\n111\n\ntokA2\nn\n' | bash "$S" setup alpha --reset >/dev/null
grep -q "^DISCORD_CHANNEL_ID='999'$" "$R/config.env"
grep -q "^DISCORD_BOT_TOKEN=tokA2$" "$R/alpha/.env"
[ -f "$R/beta/.env" ] && [ -f "$R/beta/access.json" ]
echo "ok: --reset re-asks everything, other bots untouched"

# Direct hook-behaviour tests, through the project's own symlinked copy
# (alpha's state is now stable: channel 999, token tokA2).
DSD="$R/alpha"
H="$R/hooks/turn"

# Real prompts are multi-line, with a closing tag:
# <channel source="..." chat_id="…" message_id="…" ...>\n<@id> text\n</channel>
rm -rf "$DSD/turns" "$DSD/last-message-id"; : > "$CURL_LOG"
out=$(DISCORD_STATE_DIR="$DSD" bash "$H/on-prompt" <<<'{"session_id":"s1","prompt":"<channel source=\"plugin:discord:discord\" chat_id=\"111\" message_id=\"222\" user=\"u\" user_id=\"9\" ts=\"t\">\nhello\n</channel>"}')
ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')
[ "$ctx" = 'Discord turn. You are alpha, the Claude Code session behind the Discord bot alpha in channel 999. Answer only with the discord reply tool and write no CLI text. Mention a bot as <@id> only when you need it to act or answer; if you were mentioned but nothing is asked of you, do not reply. 👀 and ✅ reactions are added automatically.' ] || { echo "FAIL: on-prompt context text wrong: $ctx"; exit 1; }
[ "$(cat "$DSD/turns/s1")" = "111 222 9" ] || { echo "FAIL: turns file wrong (chat_id message_id user_id)"; exit 1; }
[ "$(cat "$DSD/last-message-id")" = "222" ] || { echo "FAIL: last-message-id wrong"; exit 1; }
[ ! -s "$CURL_LOG" ] || { echo "FAIL: on-prompt must never call curl"; exit 1; }
echo "ok: on-prompt records chat_id/message_id/user_id and last-message-id, and prints the identity context, without calling curl"

# A stale .replied flag (as if an earlier on-stop never ran) must not survive
# into a new turn on the same session_id, or on-stop would react on it using
# an old reply that has nothing to do with this turn.
: > "$DSD/turns/s1.replied"
out=$(DISCORD_STATE_DIR="$DSD" bash "$H/on-prompt" <<<'{"session_id":"s1","prompt":"<channel source=\"plugin:discord:discord\" chat_id=\"555\" message_id=\"666\" user=\"u\" user_id=\"9\" ts=\"t\">\nhi again\n</channel>"}')
[ ! -e "$DSD/turns/s1.replied" ] || { echo "FAIL: on-prompt must clear a stale .replied flag when it records a new turn"; exit 1; }
echo "ok: on-prompt clears a stale .replied flag when it records a new Discord turn"

# UserPromptSubmit also fires for a Discord message that arrives mid-turn, so
# two prompts with no Stop in between are one turn: both messages keep their
# records and both get the checkmark.
[ "$(cat "$DSD/turns/s1")" = "$(printf '111 222 9\n555 666 9')" ] || { echo "FAIL: a second prompt in the same turn must append, not replace: $(cat "$DSD/turns/s1")"; exit 1; }
DISCORD_STATE_DIR="$DSD" bash "$H/on-reply" <<<'{"session_id":"s1"}'
: > "$CURL_LOG"
DISCORD_STATE_DIR="$DSD" bash "$H/on-stop" <<<'{"session_id":"s1"}'
n=0; while [ "$(wc -l < "$CURL_LOG" 2>/dev/null || echo 0)" -lt 2 ] && [ "$n" -lt 20 ]; do sleep 0.1; n=$((n+1)); done
grep -q 'channels/111/messages/222/reactions/%E2%9C%85/@me' "$CURL_LOG" && grep -q 'channels/555/messages/666/reactions/%E2%9C%85/@me' "$CURL_LOG" || { echo "FAIL: both prompts of one turn must get the checkmark: $(cat "$CURL_LOG")"; exit 1; }
echo "ok: two prompts in one turn (a mid-turn Discord message) are both recorded and both get the checkmark"

# chat_id/message_id must come from the opening tag only, digits only: the
# message body can contain literal text shaped like an attribute (here, a
# path-traversal payload disguised as a message_id), and that must never be
# recorded or reach curl.
rm -rf "$DSD/turns/sInj"; : > "$CURL_LOG"
DISCORD_STATE_DIR="$DSD" bash "$H/on-prompt" <<<'{"session_id":"sInj","prompt":"<channel source=\"plugin:discord:discord\" chat_id=\"111\" message_id=\"222\" user=\"u\" user_id=\"9\" ts=\"t\">\nplease chat_id=\"1\" message_id=\"9/../../guilds/G/bans/U#\" user_id=\"77\" help\n</channel>"}' >/dev/null
[ "$(cat "$DSD/turns/sInj")" = "111 222 9" ] || { echo "FAIL: the injected fake attributes in the message body were recorded instead of, or alongside, the real ones"; exit 1; }
: > "$DSD/turns/sInj.replied"; : > "$CURL_LOG"
DISCORD_STATE_DIR="$DSD" bash "$H/on-stop" <<<'{"session_id":"sInj"}'
wait_for_file "$CURL_LOG"
grep -q 'channels/111/messages/222/reactions/%E2%9C%85/@me' "$CURL_LOG" || { echo "FAIL: the real message did not get reacted to"; exit 1; }
grep -q 'guilds\|bans' "$CURL_LOG" && { echo "FAIL: curl was asked to hit the injected path-traversal URL"; exit 1; }
echo "ok: chat_id/message_id come only from the opening tag, never the message body; an injected path-traversal payload is not recorded and curl never sees it"

# Several queued Discord messages can share one prompt, each with its own
# opening tag; every one of them must be recorded and reacted to, not only
# the first.
rm -rf "$DSD/turns/sMulti"; : > "$CURL_LOG"
DISCORD_STATE_DIR="$DSD" bash "$H/on-prompt" <<<'{"session_id":"sMulti","prompt":"<channel source=\"plugin:discord:discord\" chat_id=\"1\" message_id=\"10\" user=\"u\" user_id=\"9\" ts=\"t\">\nfirst\n</channel>\n<channel source=\"plugin:discord:discord\" chat_id=\"1\" message_id=\"11\" user=\"u\" user_id=\"9\" ts=\"t\">\nsecond\n</channel>"}' >/dev/null
[ "$(cat "$DSD/turns/sMulti")" = "$(printf '1 10 9\n1 11 9')" ] || { echo "FAIL: both queued messages must be recorded, one line each"; exit 1; }
[ "$(cat "$DSD/last-message-id")" = "11" ] || { echo "FAIL: last-message-id must be the most recently queued message"; exit 1; }
: > "$DSD/turns/sMulti.replied"; : > "$CURL_LOG"
DISCORD_STATE_DIR="$DSD" bash "$H/on-stop" <<<'{"session_id":"sMulti"}'
n=0; while [ "$(wc -l < "$CURL_LOG" 2>/dev/null || echo 0)" -lt 2 ] && [ "$n" -lt 20 ]; do sleep 0.1; n=$((n+1)); done
grep -q 'channels/1/messages/10/reactions/%E2%9C%85/@me' "$CURL_LOG" || { echo "FAIL: the first queued message did not get reacted to"; exit 1; }
grep -q 'channels/1/messages/11/reactions/%E2%9C%85/@me' "$CURL_LOG" || { echo "FAIL: the second queued message did not get reacted to"; exit 1; }
echo "ok: several queued Discord messages in one prompt each get their own opening tag recorded and reacted to"

# The identity/rules context is injected once per session, not every turn.
rm -f "$DSD/turns/sPrime.primed"; rm -rf "$DSD/turns/sPrime"
PP='{"session_id":"sPrime","prompt":"<channel source=\"plugin:discord:discord\" chat_id=\"1\" message_id=\"2\" user=\"u\" user_id=\"9\" ts=\"t\">\nhi\n</channel>"}'
out=$(DISCORD_STATE_DIR="$DSD" bash "$H/on-prompt" <<<"$PP")
[ -n "$out" ] || { echo "FAIL: the first Discord turn in a session must print the identity context"; exit 1; }
[ -f "$DSD/turns/sPrime.primed" ] || { echo "FAIL: the first turn must create the primed flag"; exit 1; }
out=$(DISCORD_STATE_DIR="$DSD" bash "$H/on-prompt" <<<"$PP")
[ -z "$out" ] || { echo "FAIL: a second turn in the same session must print nothing"; exit 1; }
DISCORD_STATE_DIR="$DSD" bash "$H/on-compact" <<<'{"session_id":"sPrime"}'
[ ! -f "$DSD/turns/sPrime.primed" ] || { echo "FAIL: on-compact must remove the primed flag"; exit 1; }
out=$(DISCORD_STATE_DIR="$DSD" bash "$H/on-prompt" <<<"$PP")
[ -n "$out" ] || { echo "FAIL: the turn after a compact/clear must print the identity context again"; exit 1; }
RP='{"session_id":"sPrime","prompt":"<channel source=\"plugin:discord:discord\" chat_id=\"1\" message_id=\"2\" user=\"u\" user_id=\"9\" ts=\"t\">\nrefresh\n</channel>"}'
out=$(DISCORD_STATE_DIR="$DSD" bash "$H/on-prompt" <<<"$RP" | jq -r '.hookSpecificOutput.additionalContext')
grep -q "handoff.md" <<<"$out" || { echo "FAIL: refresh must still fire on an already-primed session"; exit 1; }
echo "ok: the identity context is injected once per session, on-compact re-primes after a compaction/clear, and refresh still fires while primed"

rm -rf "$DSD/turns/s2"
out=$(DISCORD_STATE_DIR="$DSD" bash "$H/on-prompt" <<<'{"session_id":"s2","prompt":"hello from cli"}')
[ -z "$out" ] || { echo "FAIL: on-prompt must be silent for a plain prompt"; exit 1; }
[ ! -e "$DSD/turns/s2" ] || { echo "FAIL: on-prompt must not write turns state for a plain prompt"; exit 1; }
echo "ok: on-prompt is silent and writes no state for a plain CLI prompt"

out=$(DISCORD_STATE_DIR="$DSD" bash "$H/on-prompt" <<<'{"session_id":"s3","prompt":"<channel source=\"plugin:discord:discord\" chat_id=\"111\" message_id=\"333\" user=\"u\" user_id=\"9\" ts=\"t\">\n  <@42> ReFresh  \n</channel>"}')
ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')
grep -qF "Write $DSD/handoff.md" <<<"$ctx" || { echo "FAIL: refresh handoff instructions missing"; exit 1; }
grep -qF 'claude-discord refresh alpha' <<<"$ctx" || { echo "FAIL: refresh command missing the bot name"; exit 1; }
out=$(DISCORD_STATE_DIR="$DSD" bash "$H/on-prompt" <<<'{"session_id":"s3b","prompt":"<channel source=\"plugin:discord:discord\" chat_id=\"111\" message_id=\"333\" user=\"u\" user_id=\"9\" ts=\"t\">\n<@!42> ReFresh\n</channel>"}')
ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')
grep -qF "Write $DSD/handoff.md" <<<"$ctx" || { echo "FAIL: refresh must also trigger with a <@!id> nickname mention stripped"; exit 1; }
out=$(DISCORD_STATE_DIR="$DSD" bash "$H/on-prompt" <<<'{"session_id":"s4","prompt":"<channel source=\"plugin:discord:discord\" chat_id=\"1\" message_id=\"2\" user=\"u\" user_id=\"9\" ts=\"t\">\nrefresh please\n</channel>"}')
ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')
grep -q "handoff.md" <<<"$ctx" && { echo "FAIL: refresh triggered on a message that only contains the word"; exit 1; }
echo "ok: an exact 'refresh' message (real multi-line shape with a closing tag, <@id>/<@!id> mentions stripped, whitespace collapsed and trimmed, case-insensitive) appends the handoff instructions; a longer message does not"

out=$(printf 'not json' | DISCORD_STATE_DIR="$DSD" bash "$H/on-prompt" 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] || { echo "FAIL: on-prompt must exit 0 with no output on invalid JSON"; exit 1; }
out=$(printf '' | DISCORD_STATE_DIR="$DSD" bash "$H/on-prompt"); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] || { echo "FAIL: on-prompt must exit 0 with no output on empty stdin"; exit 1; }
echo "ok: on-prompt exits 0 with no output on invalid JSON and on empty stdin"

mv "$HOME/.claude-discord/hooks/lib/discord.sh" "$HOME/.claude-discord/hooks/lib/discord.sh.bak"
for hookname in turn/on-prompt turn/on-reply turn/on-stop turn/on-compact peers/mention-guard peers/checkin peers/edit-gate; do
  out=$(DISCORD_STATE_DIR="$DSD" bash "$R/hooks/$hookname" <<<'{"session_id":"sX","prompt":"<channel source=\"plugin:discord:discord\" chat_id=\"1\" message_id=\"2\">\nhi\n</channel>"}'); rc=$?
  [ "$rc" -eq 0 ] && [ -z "$out" ] || { echo "FAIL: $hookname with a missing lib must exit 0 with no output"; exit 1; }
done
mv "$HOME/.claude-discord/hooks/lib/discord.sh.bak" "$HOME/.claude-discord/hooks/lib/discord.sh"
echo "ok: a missing lib/discord.sh makes every hook exit 0 with no output, never an unbound-variable crash"

rm -rf "$DSD/turns"; mkdir -p "$DSD/turns"
printf '111 222\n' > "$DSD/turns/s5"
: > "$CURL_LOG"; : > "$CURL_STDIN_LOG"
DISCORD_STATE_DIR="$DSD" bash "$H/on-reply" <<<'{"session_id":"s5"}'
[ -f "$DSD/turns/s5.replied" ] || { echo "FAIL: on-reply must set the .replied flag"; exit 1; }
DISCORD_STATE_DIR="$DSD" bash "$H/on-stop" <<<'{"session_id":"s5"}'
wait_for_file "$CURL_LOG"
wait_for_file "$CURL_STDIN_LOG"
grep -q 'channels/111/messages/222/reactions/%E2%9C%85/@me' "$CURL_LOG" || { echo "FAIL: on-stop must react with the checkmark on the recorded message"; exit 1; }
grep -q 'tokA2' "$CURL_LOG" && { echo "FAIL: the bot token appeared in curl's argv (visible in ps/cmdline)"; exit 1; }
grep -qF 'Authorization: Bot tokA2' "$CURL_STDIN_LOG" || { echo "FAIL: the token must reach curl via stdin (-H @-), so dropping that would break the real call"; exit 1; }
[ ! -e "$DSD/turns/s5" ] && [ ! -e "$DSD/turns/s5.replied" ] || { echo "FAIL: on-stop must remove both per-turn files"; exit 1; }
echo "ok: on-stop reacts with a checkmark only after on-reply, removes both per-turn files, keeps the token out of curl's argv, and sends it correctly via stdin"

mkdir -p "$DSD/turns"
printf '111 222\n' > "$DSD/turns/s6"
: > "$CURL_LOG"
DISCORD_STATE_DIR="$DSD" bash "$H/on-stop" <<<'{"session_id":"s6"}'
sleep 0.3
[ ! -s "$CURL_LOG" ] || { echo "FAIL: on-stop must not react without a prior reply"; exit 1; }
[ ! -e "$DSD/turns/s6" ] || { echo "FAIL: on-stop must remove the turns file even without a reply"; exit 1; }
echo "ok: on-stop removes the turns file without reacting when the turn never replied"

out=$(printf 'not json' | DISCORD_STATE_DIR="$DSD" bash "$H/on-stop" 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] || { echo "FAIL: on-stop must exit 0 with no output on invalid JSON"; exit 1; }
out=$(printf '' | DISCORD_STATE_DIR="$DSD" bash "$H/on-stop"); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] || { echo "FAIL: on-stop must exit 0 with no output on empty stdin"; exit 1; }
echo "ok: on-stop exits 0 with no output on invalid JSON and on empty stdin"

mkdir -p "$R/noenv/turns"
printf '111 222\n' > "$R/noenv/turns/s7"
: > "$R/noenv/turns/s7.replied"
: > "$CURL_LOG"
DISCORD_STATE_DIR="$R/noenv" bash "$H/on-stop" <<<'{"session_id":"s7"}'
sleep 0.3
[ ! -s "$CURL_LOG" ] || { echo "FAIL: on-stop must not call curl when the bot has no .env/token"; exit 1; }
[ ! -e "$R/noenv/turns/s7" ] || { echo "FAIL: on-stop must still remove files without a token"; exit 1; }
rm -rf "$R/noenv"
echo "ok: a bot directory without .env never calls curl, and on-stop still cleans up and exits 0"

echo marker > "$P/.claude/MARKER"
printf '' | bash "$S" setup .. --reset >/dev/null 2>&1 && { echo "FAIL: setup .. --reset should refuse"; exit 1; }
[ -f "$P/.claude/MARKER" ] || { echo "FAIL: '..' as bot name escaped root and wiped the project .claude"; exit 1; }
echo "ok: setup rejects '..' as bot name, project .claude untouched"

out=$(printf '' | bash "$S" setup hooks 2>&1) && { echo "FAIL: setup hooks should have been refused, it collides with the hooks symlink"; exit 1; }
rc=$?
[ "$rc" -eq 2 ] && grep -qF "bot name 'hooks' is reserved for the hooks directory" <<<"$out" || { echo "FAIL: setup hooks must be refused by the reserved-name guard specifically (exit 2, its own message), got rc=$rc: $out"; exit 1; }
out=$(bash "$S" hooks 2>&1) && { echo "FAIL: starting a bot named hooks should have been refused"; exit 1; }
rc=$?
[ "$rc" -eq 2 ] && grep -qF "bot name 'hooks' is reserved for the hooks directory" <<<"$out" || { echo "FAIL: starting a bot named hooks must be refused by the reserved-name guard specifically (exit 2, its own message), got rc=$rc: $out"; exit 1; }
out=$(printf '' | bash "$S" setup checkin 2>&1) && { echo "FAIL: setup checkin should have been refused"; exit 1; }
rc=$?
[ "$rc" -eq 2 ] && grep -qF "bot name 'checkin' is reserved for the checkin directory" <<<"$out" || { echo "FAIL: setup checkin must be refused by the reserved-name guard, got rc=$rc: $out"; exit 1; }
out=$(bash "$S" checkin 2>&1) && { echo "FAIL: starting a bot named checkin should have been refused"; exit 1; }
rc=$?
[ "$rc" -eq 2 ] && grep -qF "bot name 'checkin' is reserved for the checkin directory" <<<"$out" || { echo "FAIL: starting a bot named checkin must be refused by the reserved-name guard, got rc=$rc: $out"; exit 1; }
echo "ok: the bot names 'hooks' and 'checkin' are reserved and rejected by both setup and start, by the reserved-name guard specifically"

bash "$S" gamma >/dev/null 2>&1 && { echo "FAIL: run without setup should refuse"; exit 1; }
echo "ok: run refuses without setup"

out=$(bash "$S" alpha 2>&1)
grep -q "^LAUNCHER .*--channels plugin:discord@claude-plugins-official" <<<"$out"
grep -q "Other bots in the channel can hear you." <<<"$out"
grep -qF "Another bot receives your messages only when you @mention it and it allowlists your bot." <<<"$out" || { echo "FAIL: the system prompt must say how bots reach each other now"; exit 1; }
grep -qF "Sessions on this machine can also be reached with ListAgents and SendMessage" <<<"$out" || { echo "FAIL: the system prompt must keep SendMessage for same-machine sessions"; exit 1; }
! grep -q "Bots cannot hear each other" <<<"$out" || { echo "FAIL: the stale 'Bots cannot hear each other' claim is still in the system prompt"; exit 1; }
grep -q "Mention a bot as <@id> only when you need it to act or answer; if you were mentioned but nothing is asked of you, do not reply." <<<"$out"
! grep -q "never @mention it" <<<"$out"
grep -q "if (msg.author.id === client.user?.id) return" "$HOME/fakeplugin/server.ts"
! grep -q "if (msg.author.bot) return" "$HOME/fakeplugin/server.ts"
grep -q "msg.mentions.has(client.user, { ignoreEveryone: true }))" "$HOME/fakeplugin/server.ts"
grep -q "$HOME/.claude-discord/discord-proxy.ts" "$HOME/fakeplugin/bunfig.toml"
grep -q -- "--settings {\"enabledPlugins\": {\"discord@claude-plugins-official\": true}, \"env\": {\"DISCORD_STATE_DIR\": \"$R/alpha\"}, \"worktree\": {\"bgIsolation\": \"none\"}}" <<<"$out"
echo "ok: run goes through claude-launcher, patches server.ts (bot + @everyone), preload from ~/.claude-discord, state dir and worktree.bgIsolation:none in --settings env; the mention rule keeps its new wording in the system prompt"

bash "$S" alpha >/dev/null 2>&1
[ "$(grep -c 'client.user?.id) return' "$HOME/fakeplugin/server.ts")" = 1 ]
[ "$(grep -c 'ignoreEveryone' "$HOME/fakeplugin/server.ts")" = 1 ]
echo "ok: both patches are idempotent"

out=$(env -u CLAUDE_DISCORD_LAUNCHER bash "$S" alpha 2>&1)
grep -q "^PLAIN --channels plugin:discord@claude-plugins-official" <<<"$out"
echo "ok: without CLAUDE_DISCORD_LAUNCHER the plain claude on PATH is used"

rm -f "$HOME/.claude-discord/discord-proxy.ts"
bash "$S" alpha >/dev/null 2>&1
[ ! -f "$HOME/fakeplugin/bunfig.toml" ]
echo "ok: no preload file -> no bunfig.toml (bun defaults)"

printf 'x\n' > "$P/.claude/marker"
bash "$S" setup .. --reset </dev/null >/dev/null 2>&1 && { echo "FAIL: .. accepted"; exit 1; }
[ -f "$P/.claude/marker" ]
echo "ok: setup .. --reset refused, project .claude intact"

[ "$(cat "$R/.gitignore")" = "*" ]
[ -z "$(git -C "$P" status --porcelain --ignored=no -- .claude/discord-agents)" ]
git -C "$P" check-ignore -q .claude/discord-agents/alpha/.env
echo "ok: state is under the project .claude and git ignores every file in it"

# --resume takes a full id, a short id, or a session NAME resolved from this
# project's transcripts; an unknown value is passed through for claude to judge.
PROJ="$HOME/.claude/projects/$(printf '%s' "$P" | tr './' '--')"
mkdir -p "$PROJ"
printf '{"type":"custom-title","customTitle":"old-name"}\n{"type":"custom-title","customTitle":"my-session"}\n' > "$PROJ/11111111-2222-3333-4444-555555555555.jsonl"
printf '{"type":"custom-title","customTitle":"other"}\n' > "$PROJ/99999999-8888-7777-6666-555555555555.jsonl"
out=$(bash "$S" alpha --resume my-session 2>&1)
grep -q -- "--resume 11111111-2222-3333-4444-555555555555" <<<"$out" || { echo "FAIL: name was not resolved to a session id"; exit 1; }
out=$(bash "$S" alpha --resume=11111111 2>&1)
grep -q -- "--resume=11111111-2222-3333-4444-555555555555" <<<"$out" || { echo "FAIL: short id was not expanded"; exit 1; }
out=$(bash "$S" alpha --resume 99999999-8888-7777-6666-555555555555 2>&1)
grep -q -- "--resume 99999999-8888-7777-6666-555555555555" <<<"$out" || { echo "FAIL: a full id must pass through untouched"; exit 1; }
out=$(bash "$S" alpha --resume no-such-name 2>&1)
grep -q -- "--resume no-such-name" <<<"$out" || { echo "FAIL: an unknown name must pass through"; exit 1; }
grep -q "old-name" <<<"$out" && { echo "FAIL: matched a stale title"; exit 1; }
echo "ok: --resume accepts a session name, a short id, and passes ids and unknown names through"

out=$(env -u CLAUDE_DISCORD_LAUNCHER CLAUDE_CODE_PROCESS_WRAPPER="$HOME/bin/claude-launcher" bash "$S" alpha 2>&1)
grep -q "^LAUNCHER " <<<"$out" || { echo "FAIL: CLAUDE_CODE_PROCESS_WRAPPER was ignored"; exit 1; }
echo "ok: CLAUDE_CODE_PROCESS_WRAPPER is used when CLAUDE_DISCORD_LAUNCHER is unset"

echo '{"env":{"CLAUDE_CODE_PROCESS_WRAPPER":"'"$HOME"'/bin/claude-launcher"}}' > "$HOME/.claude/settings.json"
out=$(env -u CLAUDE_DISCORD_LAUNCHER -u CLAUDE_CODE_PROCESS_WRAPPER bash "$S" alpha 2>&1)
grep -q -- "^LAUNCHER $HOME/bin/claude --channels" <<<"$out" || { echo "FAIL: settings.json's env.CLAUDE_CODE_PROCESS_WRAPPER was not used"; exit 1; }
echo "ok: settings.json's env.CLAUDE_CODE_PROCESS_WRAPPER runs the wrapper with the claude bin path as \$1 when nothing else is set"

echo '{"env":{}}' > "$HOME/.claude/settings.json"
out=$(env -u CLAUDE_DISCORD_LAUNCHER -u CLAUDE_CODE_PROCESS_WRAPPER bash "$S" alpha 2>&1)
grep -q "^PLAIN " <<<"$out" || { echo "FAIL: a settings.json without the key should fall through to plain claude"; exit 1; }
echo "ok: settings.json present without the key still runs plain claude"
rm -f "$HOME/.claude/settings.json"

# The name may sit anywhere, or be left out when the project has one bot.
out=$(bash "$S" --bg alpha 2>&1)
grep -q -- "^LAUNCHER .*--bg" <<<"$out" && grep -q -- "-n alpha" <<<"$out" || { echo "FAIL: name after a flag"; exit 1; }
rm -rf "$R/beta"                      # leave exactly one bot set up
out=$(bash "$S" --bg --resume my-session 2>&1)
grep -q -- "-n alpha" <<<"$out" || { echo "FAIL: single bot was not inferred"; exit 1; }
grep -q -- "--resume 11111111-2222-3333-4444-555555555555" <<<"$out" || { echo "FAIL: --resume value was read as the name"; exit 1; }
printf 'tokB\nn\n' | bash "$S" setup beta >/dev/null
out=$(bash "$S" --bg 2>&1) && { echo "FAIL: two bots and no name should refuse"; exit 1; }
grep -q "several bots" <<<"$out" || { echo "FAIL: wrong error for two bots"; exit 1; }
rm -rf "$R/beta"
echo "ok: name before or after the flags, inferred when the project has one bot, refused when it has two"

mkdir -p "$HOME/nobin"
cp "$HOME/bin/claude-launcher" "$HOME/nobin/claude-launcher"
out=$(PATH="$HOME/nobin:/usr/bin:/bin" CLAUDE_DISCORD_LAUNCHER=claude-launcher bash "$S" alpha 2>&1) && { echo "FAIL: should refuse without claude on PATH"; exit 1; }
rc=$?
[ "$rc" -eq 127 ] || { echo "FAIL: expected exit 127, got $rc"; exit 1; }
grep -q "claude is not on PATH" <<<"$out"
echo "ok: CLAUDE_DISCORD_LAUNCHER set, no claude on PATH -> exit 127, error on stderr"

# Hook registration on the START path: a separate project, with a bot set up
# by hand (as if by a version before this feature existed: access.json and
# config.env present, no settings.json, no ackReaction, no hooks symlink), so
# the assertions below are about the start path only, not entangled with
# setup's own registration above.
P2="$HOME/project2"; mkdir -p "$P2/.claude/discord-agents/gamma"; cd "$P2"
printf "DISCORD_CHANNEL_ID='1'\nDISCORD_USER_ID='2'\nDISCORD_ALLOW_IDS=''\n" > "$P2/.claude/discord-agents/config.env"
printf 'DISCORD_BOT_TOKEN=tokG\n' > "$P2/.claude/discord-agents/gamma/.env"
jq -n '{dmPolicy:"allowlist", allowFrom:["2"], groups:{"1":{requireMention:true, allowFrom:["2"]}}}' > "$P2/.claude/discord-agents/gamma/access.json"

# b. no project settings.json yet -> start creates it with exactly one entry
# per event, and adds the missing ackReaction and hooks symlink.
[ ! -f "$P2/.claude/settings.json" ]
bash "$S" gamma >/dev/null 2>&1
has_hooks "$P2/.claude/settings.json"
[ "$(jq -c 'keys' "$P2/.claude/settings.json")" = '["hooks"]' ]
[ ! -e "$P2/.claude/settings.local.json" ] || { echo "FAIL: a project with no dev-manager must get no settings.local.json"; exit 1; }
[ "$(jq '.hooks.UserPromptSubmit | length' "$P2/.claude/settings.json")" = 1 ]
[ "$(jq '.hooks.PostToolUse | length' "$P2/.claude/settings.json")" = 1 ]
[ "$(jq '.hooks.Stop | length' "$P2/.claude/settings.json")" = 1 ]
[ "$(jq '.hooks.SessionStart | length' "$P2/.claude/settings.json")" = 1 ]
[ "$(jq -r '.hooks.PostToolUse[0].matcher' "$P2/.claude/settings.json")" = mcp__plugin_discord_discord__reply ]
[ "$(jq -r '.hooks.SessionStart[0].matcher' "$P2/.claude/settings.json")" = 'compact|clear' ]
[ "$(jq -r '.ackReaction' "$P2/.claude/discord-agents/gamma/access.json")" = "👀" ]
[ -L "$P2/.claude/discord-agents/hooks" ] || { echo "FAIL: start must create the hooks symlink"; exit 1; }
[ "$(tail -c1 "$P2/.claude/settings.json" | wc -l)" -eq 1 ] || { echo "FAIL: settings.json must end with a trailing newline"; exit 1; }
[ "$(tail -c1 "$P2/.claude/discord-agents/gamma/access.json" | wc -l)" -eq 1 ] || { echo "FAIL: access.json must end with a trailing newline"; exit 1; }
echo "ok: start creates settings.json holding exactly one entry per hook, adds ackReaction and the hooks symlink when they were missing, both files end with a trailing newline"

# c. an existing settings.json keeps its other keys; a second start is a no-op.
echo '{"enabledPlugins":{"x":true}}' > "$P2/.claude/settings.json"
bash "$S" gamma >/dev/null 2>&1
[ "$(jq -r '.enabledPlugins.x' "$P2/.claude/settings.json")" = true ]
has_hooks "$P2/.claude/settings.json"
cp "$P2/.claude/settings.json" "$P2/.claude/settings.json.before"
bash "$S" gamma >/dev/null 2>&1
cmp -s "$P2/.claude/settings.json" "$P2/.claude/settings.json.before" || { echo "FAIL: a second start must leave settings.json byte-identical"; exit 1; }
rm -f "$P2/.claude/settings.json.before"
echo "ok: start keeps other keys, adds exactly the four hook entries, and a second start is byte-identical (idempotent)"

# d. invalid JSON is left untouched; the start still reaches the exec; stderr
# names the file.
printf 'not json' > "$P2/.claude/settings.json"
cp "$P2/.claude/settings.json" "$P2/.claude/settings.json.before"
out=$(bash "$S" gamma 2>"$P2/stderr.log")
cmp -s "$P2/.claude/settings.json" "$P2/.claude/settings.json.before" || { echo "FAIL: invalid-JSON settings.json must be left untouched"; exit 1; }
rm -f "$P2/.claude/settings.json.before"
grep -qF "$P2/.claude/settings.json" "$P2/stderr.log" || { echo "FAIL: stderr must name the invalid settings file"; exit 1; }
grep -q "^LAUNCHER .*--channels plugin:discord@claude-plugins-official" <<<"$out" || { echo "FAIL: start must still reach the exec when settings.json is invalid JSON"; exit 1; }
rm -f "$P2/stderr.log"
echo "ok: invalid-JSON settings.json is left untouched, warned on stderr naming the file, and the start still execs claude"

# e. a read-only settings.json without the entries: a failed write must never
# abort the start, must leave the file as it was, and must not leave a temp
# file behind.
echo '{}' > "$P2/.claude/settings.json"; chmod 444 "$P2/.claude/settings.json"
cp "$P2/.claude/settings.json" "$P2/.claude/settings.json.before"
out=$(bash "$S" gamma 2>"$P2/stderr.log")
chmod 644 "$P2/.claude/settings.json"
cmp -s "$P2/.claude/settings.json" "$P2/.claude/settings.json.before" || { echo "FAIL: a read-only settings.json must be left untouched"; exit 1; }
rm -f "$P2/.claude/settings.json.before"
grep -qF "$P2/.claude/settings.json" "$P2/stderr.log" || { echo "FAIL: stderr must name the unwritable settings file"; exit 1; }
grep -q "^LAUNCHER .*--channels plugin:discord@claude-plugins-official" <<<"$out" || { echo "FAIL: start must still reach the exec when settings.json is read-only"; exit 1; }
[ -z "$(find "$P2/.claude" -maxdepth 1 -name 'settings.json.tmp.*')" ] || { echo "FAIL: a temp file was left behind"; exit 1; }
rm -f "$P2/stderr.log"
echo "ok: a read-only settings.json is left untouched, no temp file is left, and the start still execs claude"

# f. valid JSON that is not an object: jq can't merge into it; same guarantees.
echo '[]' > "$P2/.claude/settings.json"
cp "$P2/.claude/settings.json" "$P2/.claude/settings.json.before"
out=$(bash "$S" gamma 2>"$P2/stderr.log")
cmp -s "$P2/.claude/settings.json" "$P2/.claude/settings.json.before" || { echo "FAIL: settings.json holding [] must be left untouched"; exit 1; }
rm -f "$P2/.claude/settings.json.before"
grep -qF "$P2/.claude/settings.json" "$P2/stderr.log" || { echo "FAIL: stderr must name the file when settings.json holds []"; exit 1; }
grep -q "^LAUNCHER .*--channels plugin:discord@claude-plugins-official" <<<"$out" || { echo "FAIL: start must still reach the exec when settings.json holds []"; exit 1; }
[ -z "$(find "$P2/.claude" -maxdepth 1 -name 'settings.json.tmp.*')" ] || { echo "FAIL: a temp file was left behind"; exit 1; }
rm -f "$P2/stderr.log"
echo "ok: settings.json holding [] is left untouched, no temp file is left, and the start still execs claude"

# g. one event key already holds a non-array value: that entry's merge fails
# under set -e (a bare jq merge, not guarded by an if/&&), so this also
# proves registration cannot silently abort the start.
echo '{"hooks":{"UserPromptSubmit":{}}}' > "$P2/.claude/settings.json"
cp "$P2/.claude/settings.json" "$P2/.claude/settings.json.before"
out=$(bash "$S" gamma 2>"$P2/stderr.log")
cmp -s "$P2/.claude/settings.json" "$P2/.claude/settings.json.before" || { echo "FAIL: settings.json with a non-array UserPromptSubmit must be left untouched"; exit 1; }
rm -f "$P2/.claude/settings.json.before"
grep -qF "$P2/.claude/settings.json" "$P2/stderr.log" || { echo "FAIL: stderr must name the file"; exit 1; }
grep -q "^LAUNCHER .*--channels plugin:discord@claude-plugins-official" <<<"$out" || { echo "FAIL: start must still reach the exec"; exit 1; }
[ -z "$(find "$P2/.claude" -maxdepth 1 -name 'settings.json.tmp.*')" ] || { echo "FAIL: a temp file was left behind"; exit 1; }
rm -f "$P2/stderr.log"
echo "ok: a non-array value under one event key is warned about and left alone, and the start still execs claude under set -e"

# h. a 0-byte settings.json passes `jq empty`; it must still get the entries,
# not be silently skipped.
: > "$P2/.claude/settings.json"
bash "$S" gamma >/dev/null 2>&1
has_hooks "$P2/.claude/settings.json"
[ "$(jq -c 'keys' "$P2/.claude/settings.json")" = '["hooks"]' ]
echo "ok: a 0-byte settings.json is treated as {} and still gets the four hook entries"

# i. an explicit empty ackReaction means the owner disabled it; start must
# leave it alone, never overwrite it back to the default.
mkdir -p "$P2/.claude/discord-agents/delta"
printf 'DISCORD_BOT_TOKEN=tokD\n' > "$P2/.claude/discord-agents/delta/.env"
jq -n '{dmPolicy:"allowlist", allowFrom:["2"], ackReaction:"", groups:{"1":{requireMention:true, allowFrom:["2"]}}}' > "$P2/.claude/discord-agents/delta/access.json"
bash "$S" delta >/dev/null 2>&1
[ "$(jq -r '.ackReaction' "$P2/.claude/discord-agents/delta/access.json")" = "" ] || { echo "FAIL: an explicit empty ackReaction must be left alone"; exit 1; }
echo "ok: an explicit empty ackReaction (disabled by the owner) is left alone"

# j. an existing real directory at .claude/discord-agents/hooks is left
# alone, not clobbered into a symlink.
P3="$HOME/project3"; mkdir -p "$P3/.claude/discord-agents/eps"; cd "$P3"
printf "DISCORD_CHANNEL_ID='1'\nDISCORD_USER_ID='2'\nDISCORD_ALLOW_IDS=''\n" > "$P3/.claude/discord-agents/config.env"
printf 'DISCORD_BOT_TOKEN=tokE\n' > "$P3/.claude/discord-agents/eps/.env"
mkdir -p "$P3/.claude/discord-agents/hooks"; echo marker > "$P3/.claude/discord-agents/hooks/MARKER"
out=$(bash "$S" eps 2>&1)
[ -f "$P3/.claude/discord-agents/hooks/MARKER" ] || { echo "FAIL: a real hooks directory must not be touched"; exit 1; }
[ ! -L "$P3/.claude/discord-agents/hooks" ] || { echo "FAIL: a real hooks directory must not become a symlink"; exit 1; }
grep -q "is not a symlink, leaving it alone" <<<"$out" || { echo "FAIL: a real hooks directory must warn on stderr"; exit 1; }
echo "ok: an existing real hooks directory is left alone with a warning, not clobbered"

# Modes. A fresh project (channel 42) with a foreign rule file, a user's own
# PostToolUse hook in settings.json and Claude Code's own permission grants in
# settings.local.json; mgr is a dev-manager. peers.json lists mgr itself too
# (one list shared across machines), which every consumer must skip by name.
# The turn hooks live in settings.json (the same on every machine); the peers
# hooks in settings.local.json, since they depend on which bots this machine
# runs.
P4="$HOME/project4"; mkdir -p "$P4/.claude/rules"; cd "$P4"
R4="$P4/.claude/discord-agents"
RULE="$P4/.claude/rules/claude-discord-dev-manager.md"
SJ="$P4/.claude/settings.json"
SL="$P4/.claude/settings.local.json"
CMD_GUARD='h="$CLAUDE_PROJECT_DIR/.claude/discord-agents/hooks/peers/mention-guard"; [ ! -x "$h" ] || "$h"'
CMD_CHECKIN='h="$CLAUDE_PROJECT_DIR/.claude/discord-agents/hooks/peers/checkin"; [ ! -x "$h" ] || "$h"'
CMD_GATE='h="$CLAUDE_PROJECT_DIR/.claude/discord-agents/hooks/peers/edit-gate"; [ ! -x "$h" ] || "$h"'
has_peers_hooks() {
  has_matcher PreToolUse mcp__plugin_discord_discord__reply "$CMD_GUARD" "$1" &&
  has_matcher PostToolUse mcp__plugin_discord_discord__reply "$CMD_CHECKIN" "$1" &&
  has_matcher PreToolUse 'Edit|Write|MultiEdit' "$CMD_GATE" "$1"
}
echo mine > "$P4/.claude/rules/other.md"
echo '{"permissions":{"allow":["Bash(ls)"]},"hooks":{"PostToolUse":[{"matcher":"mcp__plugin_discord_discord__reply","hooks":[{"type":"command","command":"my-own-hook"}]}]}}' > "$SJ"
echo '{"permissions":{"allow":["Bash(git status)"]}}' > "$SL"
out=$(printf '42\n111\n\ntokM\nn\ndev-manager\ndong:900:800:wmac, junyong:901:801:lmd42,mgr:902:803:here,bad:x:1:2\n' | bash "$S" setup mgr 2>"$P4/err")
[ "$(cat "$R4/mgr/mode")" = dev-manager ] || { echo "FAIL: mode by name was not stored"; exit 1; }
[ "$(jq -c '.peers' "$R4/peers.json")" = '[{"name":"dong","bot_id":"900","owner_id":"800","machine":"wmac"},{"name":"junyong","bot_id":"901","owner_id":"801","machine":"lmd42"},{"name":"mgr","bot_id":"902","owner_id":"803","machine":"here"}]' ] || { echo "FAIL: peers.json wrong: $(cat "$R4/peers.json")"; exit 1; }
grep -qF 'bad:x:1:2' "$P4/err" || { echo "FAIL: a malformed peer entry must be warned about"; exit 1; }
[ "$(jq -c '.groups["42"].allowFrom' "$R4/mgr/access.json")" = '["111","900","901"]' ] || { echo "FAIL: peers (not self) must join the group allowFrom: $(jq -c . "$R4/mgr/access.json")"; exit 1; }
[ "$(jq -c '.allowFrom' "$R4/mgr/access.json")" = '["111"]' ] || { echo "FAIL: the DM allowFrom must not get the peers"; exit 1; }
grep -qF "Ask each peer's owner to add this bot's id to their allowFrom; both directions are needed." <<<"$out" || { echo "FAIL: the both-directions note is missing"; exit 1; }
cmp -s "$D/rules/dev-manager.md" "$RULE" || { echo "FAIL: the dev-manager rule was not dropped into .claude/rules"; exit 1; }
sed -n 3p "$RULE" | grep -qF 'only when your Discord-turn context contains a `Dev manager:` line' || { echo "FAIL: the rule must open with its condition, since every session in the project loads it"; exit 1; }
has_hooks "$SJ" && ! grep -q 'hooks/peers/' "$SJ" || { echo "FAIL: settings.json must hold the turn hooks and no peers hook: $(cat "$SJ")"; exit 1; }
has_peers_hooks "$SL" && ! grep -q 'hooks/turn/' "$SL" || { echo "FAIL: settings.local.json must hold the three peers hooks and no turn hook: $(cat "$SL")"; exit 1; }
[ "$(jq -c '.permissions' "$SJ")" = '{"allow":["Bash(ls)"]}' ] && has_cmd PostToolUse my-own-hook "$SJ" || { echo "FAIL: unrelated settings keys and the user's own hook must survive"; exit 1; }
[ "$(jq -c '.permissions' "$SL")" = '{"allow":["Bash(git status)"]}' ] || { echo "FAIL: settings.local.json's permission grants must survive"; exit 1; }
echo "ok: setup with mode dev-manager (by name) writes mode, peers.json (malformed entry warned), the group allowFrom, the rule file (conditional first line), the turn hooks in settings.json and the peers hooks in settings.local.json"

cp "$R4/peers.json" "$P4/peers.before"; cp "$SJ" "$P4/settings.before"; cp "$SL" "$P4/local.before"
printf '\nn\n2\n\n' | bash "$S" setup mgr >/dev/null
grep -q '^DISCORD_BOT_TOKEN=tokM$' "$R4/mgr/.env" || { echo "FAIL: an empty token on a re-run must keep the current token"; exit 1; }
[ "$(cat "$R4/mgr/mode")" = dev-manager ] || { echo "FAIL: mode by number was not stored"; exit 1; }
cmp -s "$R4/peers.json" "$P4/peers.before" || { echo "FAIL: an empty peers answer must keep peers.json as it was"; exit 1; }
cmp -s "$SJ" "$P4/settings.before" && cmp -s "$SL" "$P4/local.before" || { echo "FAIL: a re-run with nothing new must leave both settings files byte-identical"; exit 1; }
[ "$(jq -c '.groups["42"].allowFrom' "$R4/mgr/access.json")" = '["111","900","901"]' ] || { echo "FAIL: a re-run rewrites access.json, and the kept peers must be re-added"; exit 1; }
printf '\nn\n2\ndong2:900:810:pmac\n' | bash "$S" setup mgr >/dev/null
[ "$(jq -c '[.peers[] | select(.bot_id == "900")]' "$R4/peers.json")" = '[{"name":"dong2","bot_id":"900","owner_id":"810","machine":"pmac"}]' ] && [ "$(jq '.peers | length' "$R4/peers.json")" = 3 ] || { echo "FAIL: peers must merge by bot_id: $(cat "$R4/peers.json")"; exit 1; }
printf '\nn\n\ndong:900:800:wmac\n' | bash "$S" setup mgr >/dev/null
[ "$(cat "$R4/mgr/mode")" = dev-manager ] || { echo "FAIL: an empty mode answer must keep the current mode"; exit 1; }
[ "$(jq -r '.peers[] | select(.bot_id == "900") | .name' "$R4/peers.json")" = dong ] || { echo "FAIL: merge back"; exit 1; }
err=$(printf '\nn\nbogus\n\n' | bash "$S" setup mgr 2>&1 >/dev/null)
[ "$(cat "$R4/mgr/mode")" = dev-manager ] || { echo "FAIL: an unknown mode answer must keep the default (the current mode)"; exit 1; }
grep -q bogus <<<"$err" || { echo "FAIL: an unknown mode answer must be warned about"; exit 1; }
cp "$R4/peers.json" "$P4/peers.before"
jq '.peers += [{"bot_id":"905"}]' "$P4/peers.before" > "$R4/peers.json"
printf '\nn\n2\n\n' | bash "$S" setup mgr >/dev/null
[ "$(jq -c '.groups["42"].allowFrom' "$R4/mgr/access.json")" = '["111","900","901","905"]' ] || { echo "FAIL: a peer without a name must not empty the allowFrom update: $(jq -c . "$R4/mgr/access.json")"; exit 1; }
cp "$P4/peers.before" "$R4/peers.json"
echo "ok: re-run: empty token keeps it, mode by number, empty/unknown mode keeps the current one (unknown warned), empty peers keeps the list, peers merge by bot_id, a nameless peer still reaches allowFrom"

printf 'tokP\nn\nnone\n' | bash "$S" setup plain >/dev/null
[ "$(cat "$R4/plain/mode")" = none ] && [ -f "$RULE" ] && has_peers_hooks "$SL" || { echo "FAIL: one dev-manager bot is enough to keep the dev-manager drops (union over bots)"; exit 1; }
echo stale > "$RULE"; echo x > "$P4/.claude/rules/claude-discord-old.md"
bash "$S" mgr >/dev/null 2>&1
cmp -s "$D/rules/dev-manager.md" "$RULE" || { echo "FAIL: start must restore a changed rule file"; exit 1; }
[ ! -e "$P4/.claude/rules/claude-discord-old.md" ] || { echo "FAIL: start must remove a claude-discord-*.md no mode produces"; exit 1; }
cp "$SJ" "$P4/settings.before"; cp "$SL" "$P4/local.before"; cp "$RULE" "$P4/rule.before"
bash "$S" mgr >/dev/null 2>&1
cmp -s "$SJ" "$P4/settings.before" && cmp -s "$SL" "$P4/local.before" && cmp -s "$RULE" "$P4/rule.before" || { echo "FAIL: a second start must change nothing"; exit 1; }
echo "ok: the drops are the union over the project's bots; start restores the rule, removes a stale claude-discord-*.md, and is idempotent"

# Migration: an earlier version registered the peers hooks in settings.json.
# A start moves them: gone from settings.json (PreToolUse, then empty, goes
# too), kept once in settings.local.json.
jq --arg g "$CMD_GUARD" --arg c "$CMD_CHECKIN" --arg e "$CMD_GATE" '.hooks.PreToolUse = [{matcher: "mcp__plugin_discord_discord__reply", hooks: [{type: "command", command: $g}]}, {matcher: "Edit|Write|MultiEdit", hooks: [{type: "command", command: $e}]}] | .hooks.PostToolUse += [{matcher: "mcp__plugin_discord_discord__reply", hooks: [{type: "command", command: $c}]}]' "$SJ" > "$P4/s.tmp" && cat "$P4/s.tmp" > "$SJ" && rm -f "$P4/s.tmp"
bash "$S" mgr >/dev/null 2>&1
! grep -q 'hooks/peers/' "$SJ" && [ "$(jq '.hooks | has("PreToolUse")' "$SJ")" = false ] || { echo "FAIL: start must move the peers hooks out of settings.json: $(jq -c . "$SJ")"; exit 1; }
cmp -s "$SJ" "$P4/settings.before" && cmp -s "$SL" "$P4/local.before" || { echo "FAIL: after the migration both files must be as before, the peers hooks only in settings.local.json"; exit 1; }
echo "ok: peers hooks an earlier version left in settings.json are removed from it (an event left empty goes), settings.local.json keeps its single copy"

# Peers hooks, through the project's symlinked copy.
G="$R4/hooks/peers"
guard() { DISCORD_STATE_DIR="$R4/${2:-mgr}" CLAUDE_PROJECT_DIR="$P4" bash "$G/mention-guard" <<<"$1"; }
reason() { jq -r 'select(.hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "deny") | .hookSpecificOutput.permissionDecisionReason'; }
REASON_A='Mention dong as <@900>; a bot only receives messages that mention it.'
out=$(guard '{"session_id":"g1","tool_input":{"chat_id":"42","text":"Dong, please review"}}')
[ "$(reason <<<"$out")" = "$REASON_A" ] || { echo "FAIL: naming a peer without its mention must be denied: $out"; exit 1; }
out=$(guard '{"session_id":"g1","tool_input":{"chat_id":"42","text":"dong에게 리뷰 부탁"}}')
[ "$(reason <<<"$out")" = "$REASON_A" ] || { echo "FAIL: a peer name followed by Korean text is still a name: $out"; exit 1; }
out=$(guard '{"session_id":"g1","tool_input":{"chat_id":"42","text":"<@900> dong, please review"}}')
[ -z "$out" ] || { echo "FAIL: naming a peer with its mention must pass silently: $out"; exit 1; }
out=$(guard '{"session_id":"g1","tool_input":{"chat_id":"42","text":"<@!900> dong, please review"}}')
[ -z "$out" ] || { echo "FAIL: the nickname form <@!id> is a mention too: $out"; exit 1; }
out=$(guard '{"session_id":"g1","tool_input":{"chat_id":"42","text":"<@123> dongyong22, your call"}}')
[ -z "$out" ] || { echo "FAIL: a peer name inside a longer word (dong in dongyong22) is not the peer: $out"; exit 1; }
out=$(guard '{"session_id":"g1","tool_input":{"chat_id":"42","text":"MGR here, all done"}}')
[ -z "$out" ] || { echo "FAIL: the bot naming itself must pass (self skipped by name): $out"; exit 1; }
out=$(guard '{"session_id":"g1","tool_input":{"chat_id":"42","text":"Dong, please review"}}' plain)
[ -z "$out" ] || { echo "FAIL: mention-guard must be a no-op for a bot that is not a dev-manager: $out"; exit 1; }
out=$(DISCORD_STATE_DIR="$R4/mgr" bash "$R4/hooks/turn/on-prompt" <<<'{"session_id":"g2","prompt":"<channel source=\"plugin:discord:discord\" chat_id=\"42\" message_id=\"555\" user=\"junyong\" user_id=\"901\" ts=\"t\">\nlooks good\n</channel>"}')
[ "$(cat "$R4/mgr/turns/g2")" = "42 555 901" ] || { echo "FAIL: on-prompt must record the triggering user_id"; exit 1; }
ctx=$(jq -r '.hookSpecificOutput.additionalContext' <<<"$out")
grep -qxF 'Peers (mention to reach them): dong <@900>, junyong <@901>' <<<"$ctx" || { echo "FAIL: a dev-manager's context must list its peers, self excluded: $ctx"; exit 1; }
grep -qxF 'Dev manager: work alone end to end; ping a peer only for a review, a test on its machine, an R&R split or a heads-up before changing shared files; after each iteration post one short report.' <<<"$ctx" || { echo "FAIL: the dev-manager line is missing: $ctx"; exit 1; }
out=$(DISCORD_STATE_DIR="$R4/plain" bash "$R4/hooks/turn/on-prompt" <<<'{"session_id":"g3","prompt":"<channel source=\"plugin:discord:discord\" chat_id=\"42\" message_id=\"556\" user=\"u\" user_id=\"111\" ts=\"t\">\nhi\n</channel>"}')
grep -q 'Peers\|Dev manager' <<<"$out" && { echo "FAIL: a plain bot must not get the dev-manager context"; exit 1; }
REASON_B='You are answering junyong; mention it as <@901> or it never sees this.'
out=$(guard '{"session_id":"g2","tool_input":{"chat_id":"42","text":"thanks, merged"}}')
[ "$(reason <<<"$out")" = "$REASON_B" ] || { echo "FAIL: answering a peer-triggered turn without its mention must be denied: $out"; exit 1; }
out=$(guard '{"session_id":"g2","tool_input":{"chat_id":"42","text":"<@901> thanks, merged"}}')
[ -z "$out" ] || { echo "FAIL: answering a peer with its mention must pass: $out"; exit 1; }
# One prompt, two queued messages: the peer's, then the human's. Rule B
# follows reply_to when it is set, else the turn's LAST message only.
DISCORD_STATE_DIR="$R4/mgr" bash "$R4/hooks/turn/on-prompt" <<<'{"session_id":"g4","prompt":"<channel source=\"plugin:discord:discord\" chat_id=\"42\" message_id=\"557\" user=\"junyong\" user_id=\"901\" ts=\"t\">\nlooks good\n</channel>\n<channel source=\"plugin:discord:discord\" chat_id=\"42\" message_id=\"558\" user=\"u\" user_id=\"111\" ts=\"t\">\nship it?\n</channel>"}' >/dev/null
[ "$(cat "$R4/mgr/turns/g4")" = "$(printf '42 557 901\n42 558 111')" ] || { echo "FAIL: both queued messages of one prompt must be recorded"; exit 1; }
out=$(guard '{"session_id":"g4","tool_input":{"chat_id":"42","text":"yes, shipping"}}')
[ -z "$out" ] || { echo "FAIL: a reply to the human (the last message) must not be held to the peer's mention: $out"; exit 1; }
out=$(guard '{"session_id":"g4","tool_input":{"chat_id":"42","reply_to":"558","text":"yes, shipping"}}')
[ -z "$out" ] || { echo "FAIL: a reply_to the human's message must not be held to the peer's mention: $out"; exit 1; }
out=$(guard '{"session_id":"g4","tool_input":{"chat_id":"42","reply_to":"557","text":"thanks"}}')
[ "$(reason <<<"$out")" = "$REASON_B" ] || { echo "FAIL: a reply_to the peer's message without its mention must be denied: $out"; exit 1; }
out=$(printf 'not json' | DISCORD_STATE_DIR="$R4/mgr" bash "$G/mention-guard" 2>&1) || { echo "FAIL: mention-guard must exit 0 on invalid JSON"; exit 1; }
[ -z "$out" ] || { echo "FAIL: mention-guard must print nothing on invalid JSON"; exit 1; }
echo "ok: mention-guard denies a named peer (word boundaries, Korean suffix ok) without its <@id> or <@!id>, and an unmentioned answer to the peer that reply_to or else the turn's last message names; passes for self, a non-dev-manager, dongyong22, a reply to a human, and invalid JSON; on-prompt adds the peers context for a dev-manager only"

checkin() { DISCORD_STATE_DIR="$R4/mgr" CLAUDE_PROJECT_DIR="$P4" bash "$G/checkin" <<<"$1"; }
out=$(checkin '{"session_id":"c1","tool_input":{"text":"no mention here"}}')
[ -z "$out" ] && [ ! -e "$R4/checkin/c1" ] || { echo "FAIL: a reply without a peer mention is no check-in"; exit 1; }
checkin '{"session_id":"c2","tool_input":{"text":"<@902> note to self"}}' >/dev/null
[ ! -e "$R4/checkin/c2" ] || { echo "FAIL: mentioning yourself is no check-in"; exit 1; }
out=$(checkin '{"session_id":"c1","tool_input":{"text":"<@901> I will change on-prompt"}}')
[ -z "$out" ] && [ -f "$R4/checkin/c1" ] || { echo "FAIL: a reply mentioning a peer must touch checkin/<session_id>, silently"; exit 1; }
checkin '{"session_id":"c3","tool_input":{"text":"<@!900> I will change on-stop"}}' >/dev/null
[ -f "$R4/checkin/c3" ] || { echo "FAIL: a <@!id> mention of a peer is a check-in too"; exit 1; }
echo "ok: checkin touches checkin/<session_id> only for a reply that mentions a peer (<@id> or <@!id>), and prints nothing"

# edit-gate, against a claude-discord checkout that is a git repo with the
# gitignored bot state inside it (the refresh handoff is written there).
CD="$HOME/src/claude-discord"; mkdir -p "$CD/.claude/discord-agents" "$HOME/src/other"; git init -q "$CD"
: > "$CD/x.sh"; : > "$HOME/src/other/x.sh"; ln -s "$CD" "$HOME/src/link"
printf '*\n' > "$CD/.claude/discord-agents/.gitignore"
: > "$CD/.claude/discord-agents/tracked.md"; git -C "$CD" add x.sh; git -C "$CD" add -f .claude/discord-agents/tracked.md
gate() { DISCORD_STATE_DIR="$R4/${3:-mgr}" CLAUDE_PROJECT_DIR="$P4" bash "$G/edit-gate" <<<"{\"session_id\":\"$1\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$2\"}}"; }
mtime() { perl -e 'print +(stat $ARGV[0])[9]' "$1"; }
age() { perl -e 'utime time - $ARGV[0], time - $ARGV[0], $ARGV[1]' "$1" "$2"; }
GATE_REASON='Before changing claude-discord, announce on Discord what you will change (mention <@900> <@901>); you do not need to wait for an answer.'
for f in "$CD/x.sh" "$HOME/src/link/x.sh" "$CD/new-file.sh" "$CD/.claude/discord-agents/tracked.md"; do
  out=$(gate e1 "$f")
  [ "$(reason <<<"$out")" = "$GATE_REASON" ] || { echo "FAIL: editing $f without a check-in must be denied: $out"; exit 1; }
done
for f in "$CD/.claude/discord-agents/mgr/handoff.md" "$HOME/src/other/x.sh"; do
  out=$(gate e1 "$f")
  [ -z "$out" ] && [ ! -e "$R4/checkin/e1" ] || { echo "FAIL: $f (gitignored, or outside claude-discord) must pass silently and touch nothing: $out"; exit 1; }
done
out=$(gate e1 "$CD/x.sh" plain)
[ -z "$out" ] || { echo "FAIL: edit-gate must be a no-op for a bot that is not a dev-manager"; exit 1; }
: > "$R4/checkin/e1"; age 1800 "$R4/checkin/e1"; before=$(mtime "$R4/checkin/e1")
out=$(gate e1 "$CD/x.sh")
[ -z "$out" ] || { echo "FAIL: an edit with a fresh check-in must pass: $out"; exit 1; }
[ "$(mtime "$R4/checkin/e1")" -gt "$before" ] || { echo "FAIL: an allowed edit must re-touch the check-in (sliding window)"; exit 1; }
age 3700 "$R4/checkin/e1"
out=$(gate e1 "$CD/x.sh")
[ "$(reason <<<"$out")" = "$GATE_REASON" ] || { echo "FAIL: a check-in older than 60 minutes must be denied: $out"; exit 1; }
echo "ok: edit-gate denies claude-discord edits (tracked or untracked, via a symlink, a new file) without a check-in or with a stale one; passes with a fresh one and re-touches it, for gitignored bot state (a handoff.md in a dir not created yet), outside claude-discord and for a non-dev-manager"

# Switching mgr to none (by number): no bot is a dev-manager any more. A
# user's own hook inside our edit-gate group must survive the cleanup.
jq '(.hooks.PreToolUse[] | select(.matcher == "Edit|Write|MultiEdit") | .hooks) += [{"type":"command","command":"mine-in-group"}]' "$SL" > "$P4/s.tmp" && cat "$P4/s.tmp" > "$SL" && rm -f "$P4/s.tmp"
cp "$SJ" "$P4/settings.before"
printf '\nn\n1\n' | bash "$S" setup mgr >/dev/null
[ "$(cat "$R4/mgr/mode")" = none ] || { echo "FAIL: mode none by number"; exit 1; }
[ ! -e "$RULE" ] || { echo "FAIL: switching to none must remove the dev-manager rule"; exit 1; }
[ "$(cat "$P4/.claude/rules/other.md")" = mine ] || { echo "FAIL: a foreign .claude/rules file must survive"; exit 1; }
! grep -q 'hooks/peers/' "$SL" || { echo "FAIL: switching to none must remove every peers hook entry: $(cat "$SL")"; exit 1; }
cmp -s "$SJ" "$P4/settings.before" || { echo "FAIL: settings.json (turn hooks, unrelated keys, the user's own hook) must be untouched"; exit 1; }
[ "$(jq -c '.permissions' "$SL")" = '{"allow":["Bash(git status)"]}' ] || { echo "FAIL: settings.local.json's permission grants must survive"; exit 1; }
[ "$(jq -c '.hooks.PreToolUse' "$SL")" = '[{"matcher":"Edit|Write|MultiEdit","hooks":[{"type":"command","command":"mine-in-group"}]}]' ] || { echo "FAIL: only our entries go; a group left empty goes, a group still holding a user hook stays: $(jq -c '.hooks.PreToolUse' "$SL")"; exit 1; }
[ "$(jq '.hooks | has("PostToolUse")' "$SL")" = false ] || { echo "FAIL: an event left with no groups must be dropped: $(jq -c . "$SL")"; exit 1; }
echo "ok: switching to none removes the rule file and every peers hook entry (empty groups and events dropped), keeps settings.json, the permission grants, a user's own hooks and a foreign rule file"

# Back to dev-manager, then autoresearchclaw: it drops nothing.
printf '\nn\n2\n' | bash "$S" setup mgr >/dev/null   # EOF at the peers prompt: same as empty
has_peers_hooks "$SL" && [ -f "$RULE" ] || { echo "FAIL: back to dev-manager must restore its drops"; exit 1; }
printf '\nn\nautoresearchclaw\n' | bash "$S" setup mgr >/dev/null
[ "$(cat "$R4/mgr/mode")" = autoresearchclaw ] || { echo "FAIL: mode autoresearchclaw"; exit 1; }
[ -z "$(find "$P4/.claude/rules" -name 'claude-discord-*')" ] || { echo "FAIL: autoresearchclaw must drop no rule file"; exit 1; }
! grep -q 'hooks/peers/' "$SL" "$SJ" || { echo "FAIL: autoresearchclaw must register no peers hook"; exit 1; }
has_hooks "$SJ" || { echo "FAIL: the turn hooks must survive"; exit 1; }
echo "ok: autoresearchclaw drops nothing"

echo "ALL PASS"
