#!/usr/bin/env bash
# Acceptance test for dotfiles/scripts/claude-discord. Runs entirely in a
# throwaway HOME; touches nothing real. Usage: test-claude-discord.sh <script>
set -euo pipefail
S=${1:?script path}; S=$(cd "$(dirname "$S")" && pwd)/$(basename "$S")   # absolute: the test cd-s into a throwaway project
bash -n "$S"
[ "$(grep -c "if (msg.author.bot) return" "$S")" = 1 ] || { echo "FAIL: server.ts patch block must appear exactly once in the wrapper"; exit 1; }
export HOME=/tmp/claude-discord-test-$$; mkdir -p "$HOME"; trap 'rm -rf /tmp/claude-discord-test-$$' EXIT
mkdir -p "$HOME/.claude/plugins" "$HOME/fakeplugin" "$HOME/bin"
echo '{"plugins":{"discord@claude-plugins-official":[{"installPath":"'"$HOME"'/fakeplugin"}]}}' > "$HOME/.claude/plugins/installed_plugins.json"
printf 'client.on(%s, msg => {\n  if (msg.author.bot) return\n  handleInbound(msg)\n})\n' "'messageCreate'" > "$HOME/fakeplugin/server.ts"
printf '#!/bin/bash\necho "LAUNCHER $*"\n' > "$HOME/bin/claude-launcher"; chmod +x "$HOME/bin/claude-launcher"
printf '#!/bin/bash\necho "PLAIN $*"\n' > "$HOME/bin/claude"; chmod +x "$HOME/bin/claude"
export PATH="$HOME/bin:$PATH"
export CLAUDE_DISCORD_LAUNCHER=claude-launcher
mkdir -p "$HOME/.claude"; : > "$HOME/.claude/discord-proxy.ts"
P="$HOME/project"; mkdir -p "$P"; cd "$P"; git init -q .
R="$P/.claude/discord-agents"

printf '1550575144320110662\n111\n222, 333 ,\ntokA\ny\n' | bash "$S" setup alpha >/dev/null
[ "$(jq -r '.groups["1550575144320110662"].requireMention' "$R/alpha/access.json")" = false ]
[ "$(jq -c '.groups["1550575144320110662"].allowFrom' "$R/alpha/access.json")" = '["111","222","333"]' ]
[ "$(jq -c '.allowFrom' "$R/alpha/access.json")" = '["111"]' ]
grep -q "^DISCORD_ALLOW_IDS='222,333,'$" "$R/config.env"
grep -q "^DISCORD_BOT_TOKEN=tokA$" "$R/alpha/.env"
echo "ok: setup writes config.env, .env, access.json; others normalised; no-mention honoured"

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
grep -q "discord-proxy.ts" "$HOME/fakeplugin/bunfig.toml"
echo "ok: run goes through claude-launcher, patches server.ts, writes bunfig, loop guard in prompt"

bash "$S" alpha >/dev/null 2>&1
[ "$(grep -c 'client.user?.id) return' "$HOME/fakeplugin/server.ts")" = 1 ]
echo "ok: patch is idempotent"

out=$(env -u CLAUDE_DISCORD_LAUNCHER bash "$S" alpha 2>&1)
grep -q "^PLAIN --channels plugin:discord@claude-plugins-official" <<<"$out"
echo "ok: without CLAUDE_DISCORD_LAUNCHER the plain claude on PATH is used"

rm -f "$HOME/.claude/discord-proxy.ts"
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

mkdir -p "$HOME/nobin"
cp "$HOME/bin/claude-launcher" "$HOME/nobin/claude-launcher"
out=$(PATH="$HOME/nobin:/usr/bin:/bin" CLAUDE_DISCORD_LAUNCHER=claude-launcher bash "$S" alpha 2>&1) && { echo "FAIL: should refuse without claude on PATH"; exit 1; }
rc=$?
[ "$rc" -eq 127 ] || { echo "FAIL: expected exit 127, got $rc"; exit 1; }
grep -q "claude is not on PATH" <<<"$out"
echo "ok: CLAUDE_DISCORD_LAUNCHER set, no claude on PATH -> exit 127, error on stderr"
echo "ALL PASS"
