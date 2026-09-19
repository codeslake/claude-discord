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
[ "$(grep -c "if (msg.author.bot) return" "$S")" = 1 ] || { echo "FAIL: server.ts patch block must appear exactly once in the wrapper"; exit 1; }

export HOME=/tmp/claude-discord-test-$$; mkdir -p "$HOME"; trap 'rm -rf /tmp/claude-discord-test-$$' EXIT
mkdir -p "$HOME/.claude/plugins" "$HOME/fakeplugin" "$HOME/bin"
echo '{"plugins":{"discord@claude-plugins-official":[{"installPath":"'"$HOME"'/fakeplugin"}]}}' > "$HOME/.claude/plugins/installed_plugins.json"
printf 'client.on(%s, msg => {\n  if (msg.author.bot) return\n  handleInbound(msg)\n})\nfunction isAddressed(msg) {\n  if (client.user && msg.mentions.has(client.user)) return true\n}\n' "'messageCreate'" > "$HOME/fakeplugin/server.ts"
printf '#!/bin/bash\necho "LAUNCHER $*"\n' > "$HOME/bin/claude-launcher"; chmod +x "$HOME/bin/claude-launcher"
printf '#!/bin/bash\necho "PLAIN $*"\n' > "$HOME/bin/claude"; chmod +x "$HOME/bin/claude"
CURL_LOG="$HOME/curl.log"; : > "$CURL_LOG"
cat > "$HOME/bin/curl" <<'EOF'
#!/bin/bash
# Logs its args to CURL_LOG instead of stdout, since the caller redirects
# stdout/stderr to /dev/null for the real, detached curl call.
printf '%s\n' "$*" >> "$CURL_LOG"
EOF
chmod +x "$HOME/bin/curl"
export PATH="$HOME/bin:$PATH"
export CURL_LOG
export CLAUDE_DISCORD_LAUNCHER=claude-launcher
mkdir -p "$HOME/.claude-discord"; : > "$HOME/.claude-discord/discord-proxy.ts"
cp -r "$D/hooks" "$HOME/.claude-discord/hooks"   # stand-in for install.sh, not exercised here
P="$HOME/project"; mkdir -p "$P"; cd "$P"; git init -q .
R="$P/.claude/discord-agents"

printf '1550575144320110662\n111\n222, 333 ,\ntokA\ny\n' | bash "$S" setup alpha >/dev/null
[ "$(jq -r '.groups["1550575144320110662"].requireMention' "$R/alpha/access.json")" = false ]
[ "$(jq -c '.groups["1550575144320110662"].allowFrom' "$R/alpha/access.json")" = '["111","222","333"]' ]
[ "$(jq -c '.allowFrom' "$R/alpha/access.json")" = '["111"]' ]
[ "$(jq -r '.ackReaction' "$R/alpha/access.json")" = "👀" ]
grep -q "^DISCORD_ALLOW_IDS='222,333,'$" "$R/config.env"
grep -q "^DISCORD_BOT_TOKEN=tokA$" "$R/alpha/.env"
echo "ok: setup writes config.env, .env, access.json (with ackReaction); others normalised; no-mention honoured"

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
[ "$(cat "$DSD/turns/s1")" = "111 222" ] || { echo "FAIL: turns file wrong"; exit 1; }
[ "$(cat "$DSD/last-message-id")" = "222" ] || { echo "FAIL: last-message-id wrong"; exit 1; }
[ ! -s "$CURL_LOG" ] || { echo "FAIL: on-prompt must never call curl"; exit 1; }
echo "ok: on-prompt records chat_id/message_id and last-message-id, and prints the identity context, without calling curl"

# A stale .replied flag (as if an earlier on-stop never ran) must not survive
# into a new turn on the same session_id, or on-stop would react on it using
# an old reply that has nothing to do with this turn.
: > "$DSD/turns/s1.replied"
out=$(DISCORD_STATE_DIR="$DSD" bash "$H/on-prompt" <<<'{"session_id":"s1","prompt":"<channel source=\"plugin:discord:discord\" chat_id=\"555\" message_id=\"666\" user=\"u\" user_id=\"9\" ts=\"t\">\nhi again\n</channel>"}')
[ ! -e "$DSD/turns/s1.replied" ] || { echo "FAIL: on-prompt must clear a stale .replied flag when it records a new turn"; exit 1; }
echo "ok: on-prompt clears a stale .replied flag when it records a new Discord turn"

# chat_id/message_id must come from the opening tag only, digits only: the
# message body can contain literal text shaped like an attribute (here, a
# path-traversal payload disguised as a message_id), and that must never be
# recorded or reach curl.
rm -rf "$DSD/turns/sInj"; : > "$CURL_LOG"
DISCORD_STATE_DIR="$DSD" bash "$H/on-prompt" <<<'{"session_id":"sInj","prompt":"<channel source=\"plugin:discord:discord\" chat_id=\"111\" message_id=\"222\" user=\"u\" user_id=\"9\" ts=\"t\">\nplease chat_id=\"1\" message_id=\"9/../../guilds/G/bans/U#\" help\n</channel>"}' >/dev/null
[ "$(cat "$DSD/turns/sInj")" = "111 222" ] || { echo "FAIL: the injected fake attributes in the message body were recorded instead of, or alongside, the real ones"; exit 1; }
: > "$DSD/turns/sInj.replied"; : > "$CURL_LOG"
DISCORD_STATE_DIR="$DSD" bash "$H/on-stop" <<<'{"session_id":"sInj"}'
wait_for_file "$CURL_LOG"
grep -q 'channels/111/messages/222/reactions/%E2%9C%85/@me' "$CURL_LOG" || { echo "FAIL: the real message did not get reacted to"; exit 1; }
grep -q 'guilds\|bans' "$CURL_LOG" && { echo "FAIL: curl was asked to hit the injected path-traversal URL"; exit 1; }
echo "ok: chat_id/message_id come only from the opening tag, never the message body; an injected path-traversal payload is not recorded and curl never sees it"

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
for hookname in on-prompt on-reply on-stop on-compact; do
  out=$(DISCORD_STATE_DIR="$DSD" bash "$H/$hookname" <<<'{"session_id":"sX","prompt":"<channel source=\"plugin:discord:discord\" chat_id=\"1\" message_id=\"2\">\nhi\n</channel>"}'); rc=$?
  [ "$rc" -eq 0 ] && [ -z "$out" ] || { echo "FAIL: $hookname with a missing lib must exit 0 with no output"; exit 1; }
done
mv "$HOME/.claude-discord/hooks/lib/discord.sh.bak" "$HOME/.claude-discord/hooks/lib/discord.sh"
echo "ok: a missing lib/discord.sh makes every hook exit 0 with no output, never an unbound-variable crash"

rm -rf "$DSD/turns"; mkdir -p "$DSD/turns"
printf '111 222\n' > "$DSD/turns/s5"
: > "$CURL_LOG"
DISCORD_STATE_DIR="$DSD" bash "$H/on-reply" <<<'{"session_id":"s5"}'
[ -f "$DSD/turns/s5.replied" ] || { echo "FAIL: on-reply must set the .replied flag"; exit 1; }
DISCORD_STATE_DIR="$DSD" bash "$H/on-stop" <<<'{"session_id":"s5"}'
wait_for_file "$CURL_LOG"
grep -q 'channels/111/messages/222/reactions/%E2%9C%85/@me' "$CURL_LOG" || { echo "FAIL: on-stop must react with the checkmark on the recorded message"; exit 1; }
grep -q 'tokA2' "$CURL_LOG" && { echo "FAIL: the bot token appeared in curl's argv (visible in ps/cmdline)"; exit 1; }
[ ! -e "$DSD/turns/s5" ] && [ ! -e "$DSD/turns/s5.replied" ] || { echo "FAIL: on-stop must remove both per-turn files"; exit 1; }
echo "ok: on-stop reacts with a checkmark only after on-reply, removes both per-turn files, and never puts the token in curl's argv"

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

printf '' | bash "$S" setup hooks >/dev/null 2>&1 && { echo "FAIL: setup hooks should be refused, it collides with the hooks symlink"; exit 1; }
bash "$S" hooks >/dev/null 2>&1 && { echo "FAIL: starting a bot named hooks should be refused"; exit 1; }
echo "ok: the bot name 'hooks' is reserved and rejected by both setup and start"

bash "$S" gamma >/dev/null 2>&1 && { echo "FAIL: run without setup should refuse"; exit 1; }
echo "ok: run refuses without setup"

out=$(bash "$S" alpha 2>&1)
grep -q "^LAUNCHER .*--channels plugin:discord@claude-plugins-official" <<<"$out"
grep -q "Other bots in the channel can hear you." <<<"$out"
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

echo "ALL PASS"
