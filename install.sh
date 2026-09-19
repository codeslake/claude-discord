#!/usr/bin/env bash
# Installs claude-discord: the wrapper on PATH, helpers under ~/.claude-discord/.
# Re-run after a git pull; every copy is overwritten.
set -euo pipefail
cd "$(dirname "$0")"
install -d -m 755 "$HOME/.local/bin" "$HOME/.claude-discord" \
  "$HOME/.claude-discord/hooks/lib" "$HOME/.claude-discord/hooks/turn" \
  "$HOME/.claude-discord/hooks/peers" "$HOME/.claude-discord/hooks/autoresearchclaw" \
  "$HOME/.claude-discord/rules"
install -m 755 claude-discord "$HOME/.local/bin/claude-discord"
install -m 644 discord-proxy.ts "$HOME/.claude-discord/discord-proxy.ts"
install -m 644 hooks/lib/discord.sh "$HOME/.claude-discord/hooks/lib/discord.sh"
install -m 755 hooks/turn/on-prompt hooks/turn/on-reply hooks/turn/on-stop hooks/turn/on-session-start "$HOME/.claude-discord/hooks/turn/"
install -m 755 hooks/peers/mention-guard hooks/peers/checkin hooks/peers/edit-gate "$HOME/.claude-discord/hooks/peers/"
install -m 755 hooks/autoresearchclaw/on-start hooks/autoresearchclaw/watch "$HOME/.claude-discord/hooks/autoresearchclaw/"
install -m 644 rules/dev-manager.md "$HOME/.claude-discord/rules/dev-manager.md"
echo "installed ~/.local/bin/claude-discord and ~/.claude-discord/{discord-proxy.ts,hooks/,rules/}"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "note: ~/.local/bin is not on PATH" >&2;; esac
