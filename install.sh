#!/usr/bin/env bash
# Installs claude-discord: the wrapper on PATH, helpers under ~/.claude-discord/.
# Re-run after a git pull; every copy is overwritten.
set -euo pipefail
cd "$(dirname "$0")"
install -d -m 755 "$HOME/.local/bin" "$HOME/.claude-discord"
install -m 755 claude-discord "$HOME/.local/bin/claude-discord"
install -m 644 discord-proxy.ts "$HOME/.claude-discord/discord-proxy.ts"
install -m 755 discord-turn-hook "$HOME/.claude-discord/discord-turn-hook"
echo "installed ~/.local/bin/claude-discord and ~/.claude-discord/{discord-proxy.ts,discord-turn-hook}"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "note: ~/.local/bin is not on PATH" >&2;; esac
