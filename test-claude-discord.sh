#!/usr/bin/env bash
# Acceptance test for dotfiles/scripts/claude-discord. Runs entirely in a
# throwaway HOME; touches nothing real. Usage: test-claude-discord.sh <script>
set -euo pipefail
S=${1:?script path}; S=$(cd "$(dirname "$S")" && pwd)/$(basename "$S")   # absolute: the test cd-s into a throwaway project
H=$(dirname "$S")/discord-turn-hook
CMD='f="$HOME/.claude-discord/discord-turn-hook"; [ ! -x "$f" ] || "$f"'
has_hook() { jq -e --arg cmd "$CMD" '[.hooks.UserPromptSubmit[]?.hooks[]?.command] | index($cmd) != null' "$1" >/dev/null 2>&1; }
bash -n "$S"
bash -n "$H"
[ "$(grep -c "if (msg.author.bot) return" "$S")" = 1 ] || { echo "FAIL: server.ts patch block must appear exactly once in the wrapper"; exit 1; }

# discord-turn-hook: reads the UserPromptSubmit hook JSON on stdin.
if out=$(printf '%s' '{"prompt":"<channel source=\"plugin:discord:discord\" chat_id=\"1\">hi"}' | bash "$H"); then rc=0; else rc=$?; fi
[ "$rc" -eq 0 ] && [ "$out" = '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"Discord turn: answer only with the discord reply tool; write no CLI text."}}' ] || { echo "FAIL: hook must print the exact context line for a discord-channel prompt"; exit 1; }
if out=$(printf '%s' '{"prompt":"hello from the CLI"}' | bash "$H"); then rc=0; else rc=$?; fi
[ "$rc" -eq 0 ] && [ -z "$out" ] || { echo "FAIL: hook must be silent for a plain prompt"; exit 1; }
if out=$(printf '%s' 'not json' | bash "$H" 2>/dev/null); then rc=0; else rc=$?; fi
[ "$rc" -eq 0 ] && [ -z "$out" ] || { echo "FAIL: hook must exit 0 with no output on invalid JSON"; exit 1; }
if out=$(printf '' | bash "$H"); then rc=0; else rc=$?; fi
[ "$rc" -eq 0 ] && [ -z "$out" ] || { echo "FAIL: hook must exit 0 with no output on empty stdin"; exit 1; }
echo "ok: discord-turn-hook emits the context line for a discord prompt and is silent otherwise"

export HOME=/tmp/claude-discord-test-$$; mkdir -p "$HOME"; trap 'rm -rf /tmp/claude-discord-test-$$' EXIT
mkdir -p "$HOME/.claude/plugins" "$HOME/fakeplugin" "$HOME/bin"
echo '{"plugins":{"discord@claude-plugins-official":[{"installPath":"'"$HOME"'/fakeplugin"}]}}' > "$HOME/.claude/plugins/installed_plugins.json"
printf 'client.on(%s, msg => {\n  if (msg.author.bot) return\n  handleInbound(msg)\n})\nfunction isAddressed(msg) {\n  if (client.user && msg.mentions.has(client.user)) return true\n}\n' "'messageCreate'" > "$HOME/fakeplugin/server.ts"
printf '#!/bin/bash\necho "LAUNCHER $*"\n' > "$HOME/bin/claude-launcher"; chmod +x "$HOME/bin/claude-launcher"
printf '#!/bin/bash\necho "PLAIN $*"\n' > "$HOME/bin/claude"; chmod +x "$HOME/bin/claude"
export PATH="$HOME/bin:$PATH"
export CLAUDE_DISCORD_LAUNCHER=claude-launcher
mkdir -p "$HOME/.claude-discord"; : > "$HOME/.claude-discord/discord-proxy.ts"
P="$HOME/project"; mkdir -p "$P"; cd "$P"; git init -q .
R="$P/.claude/discord-agents"

printf '1550575144320110662\n111\n222, 333 ,\ntokA\ny\n' | bash "$S" setup alpha >/dev/null
[ "$(jq -r '.groups["1550575144320110662"].requireMention' "$R/alpha/access.json")" = false ]
[ "$(jq -c '.groups["1550575144320110662"].allowFrom' "$R/alpha/access.json")" = '["111","222","333"]' ]
[ "$(jq -c '.allowFrom' "$R/alpha/access.json")" = '["111"]' ]
grep -q "^DISCORD_ALLOW_IDS='222,333,'$" "$R/config.env"
grep -q "^DISCORD_BOT_TOKEN=tokA$" "$R/alpha/.env"
echo "ok: setup writes config.env, .env, access.json; others normalised; no-mention honoured"

has_hook "$P/.claude/settings.json"
echo "ok: setup also registers the discord-turn hook (after access.json is written)"

printf 'tokB\nn\n' | bash "$S" setup beta >/dev/null
[ "$(jq -r '.groups["1550575144320110662"].requireMention' "$R/beta/access.json")" = true ]
echo "ok: second bot asks only token+mention and reuses shared IDs"

printf '999\n111\n\ntokA2\nn\n' | bash "$S" setup alpha --reset >/dev/null
grep -q "^DISCORD_CHANNEL_ID='999'$" "$R/config.env"
grep -q "^DISCORD_BOT_TOKEN=tokA2$" "$R/alpha/.env"
[ -f "$R/beta/.env" ] && [ -f "$R/beta/access.json" ]
echo "ok: --reset re-asks everything, other bots untouched"

echo marker > "$P/.claude/MARKER"
printf '' | bash "$S" setup .. --reset >/dev/null 2>&1 && { echo "FAIL: setup .. --reset should refuse"; exit 1; }
[ -f "$P/.claude/MARKER" ] || { echo "FAIL: '..' as bot name escaped root and wiped the project .claude"; exit 1; }
echo "ok: setup rejects '..' as bot name, project .claude untouched"

bash "$S" gamma >/dev/null 2>&1 && { echo "FAIL: run without setup should refuse"; exit 1; }
echo "ok: run refuses without setup"

out=$(bash "$S" alpha 2>&1)
grep -q "^LAUNCHER .*--channels plugin:discord@claude-plugins-official" <<<"$out"
grep -q "never @mention it" <<<"$out"
grep -q "if (msg.author.id === client.user?.id) return" "$HOME/fakeplugin/server.ts"
! grep -q "if (msg.author.bot) return" "$HOME/fakeplugin/server.ts"
grep -q "msg.mentions.has(client.user, { ignoreEveryone: true }))" "$HOME/fakeplugin/server.ts"
grep -q "$HOME/.claude-discord/discord-proxy.ts" "$HOME/fakeplugin/bunfig.toml"
grep -q -- "--settings {\"enabledPlugins\": {\"discord@claude-plugins-official\": true}, \"env\": {\"DISCORD_STATE_DIR\": \"$R/alpha\"}}" <<<"$out"
echo "ok: run goes through claude-launcher, patches server.ts (bot + @everyone), preload from ~/.claude-discord, state dir in --settings env, loop guard in prompt"

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
# config.env present, no settings.json), so the assertions below are about
# the start path only, not entangled with setup's own registration above.
P2="$HOME/project2"; mkdir -p "$P2/.claude/discord-agents/gamma"; cd "$P2"
printf "DISCORD_CHANNEL_ID='1'\nDISCORD_USER_ID='2'\nDISCORD_ALLOW_IDS=''\n" > "$P2/.claude/discord-agents/config.env"
printf 'DISCORD_BOT_TOKEN=tokG\n' > "$P2/.claude/discord-agents/gamma/.env"
jq -n '{dmPolicy:"allowlist", allowFrom:["2"], groups:{"1":{requireMention:true, allowFrom:["2"]}}}' > "$P2/.claude/discord-agents/gamma/access.json"

# b. no project settings.json yet -> start creates it with exactly one entry.
[ ! -f "$P2/.claude/settings.json" ]
bash "$S" gamma >/dev/null 2>&1
has_hook "$P2/.claude/settings.json"
[ "$(jq -c 'keys' "$P2/.claude/settings.json")" = '["hooks"]' ]
[ "$(jq '.hooks.UserPromptSubmit | length' "$P2/.claude/settings.json")" = 1 ]
[ "$(jq '.hooks.UserPromptSubmit[0].hooks | length' "$P2/.claude/settings.json")" = 1 ]
echo "ok: start creates settings.json holding exactly one hook entry when the file was missing"

# c. an existing settings.json keeps its other keys; a second start is a no-op.
echo '{"enabledPlugins":{"x":true}}' > "$P2/.claude/settings.json"
bash "$S" gamma >/dev/null 2>&1
[ "$(jq -r '.enabledPlugins.x' "$P2/.claude/settings.json")" = true ]
has_hook "$P2/.claude/settings.json"
[ "$(jq '.hooks.UserPromptSubmit | length' "$P2/.claude/settings.json")" = 1 ]
cp "$P2/.claude/settings.json" "$P2/.claude/settings.json.before"
bash "$S" gamma >/dev/null 2>&1
cmp -s "$P2/.claude/settings.json" "$P2/.claude/settings.json.before" || { echo "FAIL: a second start must leave settings.json byte-identical"; exit 1; }
rm -f "$P2/.claude/settings.json.before"
echo "ok: start keeps other keys, adds exactly one hook entry, and a second start is byte-identical"

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

# e. a read-only settings.json without the entry: a failed write must never
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

# g. a 0-byte settings.json passes `jq empty`; it must still get the entry,
# not be silently skipped.
: > "$P2/.claude/settings.json"
bash "$S" gamma >/dev/null 2>&1
has_hook "$P2/.claude/settings.json"
[ "$(jq -c 'keys' "$P2/.claude/settings.json")" = '["hooks"]' ]
echo "ok: a 0-byte settings.json is treated as {} and still gets the hook entry"

echo "ALL PASS"
