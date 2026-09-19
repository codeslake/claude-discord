#!/usr/bin/env bash
# Installs claude-discord: the wrapper on PATH, helpers under ~/.claude-discord/.
# Re-run after a git pull; every copy is overwritten.
set -euo pipefail
cd "$(dirname "$0")"
install -d -m 755 "$HOME/.local/bin" "$HOME/.claude-discord" \
  "$HOME/.claude-discord/hooks/lib" "$HOME/.claude-discord/hooks/turn" \
  "$HOME/.claude-discord/hooks/peers" "$HOME/.claude-discord/hooks/autoresearchclaw" \
  "$HOME/.claude-discord/hooks/tools" "$HOME/.claude-discord/rules"
install -m 755 claude-discord "$HOME/.local/bin/claude-discord"
install -m 644 discord-proxy.ts "$HOME/.claude-discord/discord-proxy.ts"
install -m 644 hooks/lib/discord.sh "$HOME/.claude-discord/hooks/lib/discord.sh"
install -m 755 hooks/turn/on-prompt hooks/turn/on-reply hooks/turn/on-stop hooks/turn/on-session-start "$HOME/.claude-discord/hooks/turn/"
install -m 755 hooks/peers/mention-guard hooks/peers/checkin hooks/peers/thread-guard hooks/peers/edit-gate "$HOME/.claude-discord/hooks/peers/"
install -m 755 hooks/tools/thread "$HOME/.claude-discord/hooks/tools/"
install -m 755 hooks/autoresearchclaw/on-start hooks/autoresearchclaw/events "$HOME/.claude-discord/hooks/autoresearchclaw/"
install -m 644 rules/dev-manager.md rules/autoresearchclaw.md "$HOME/.claude-discord/rules/"
# A file an earlier version installed that the repo no longer ships (the
# autoresearchclaw watcher, turn/on-compact) goes: every project reaches these
# through its hooks symlink. Only hooks/<topic>/ and rules/ are swept.
for f in "$HOME"/.claude-discord/hooks/*/* "$HOME"/.claude-discord/rules/*; do
  { [ -f "$f" ] || [ -L "$f" ]; } && [ ! -e "${f#"$HOME/.claude-discord/"}" ] || continue
  rm -f "$f"
done
echo "installed ~/.local/bin/claude-discord and ~/.claude-discord/{discord-proxy.ts,hooks/,rules/}"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "note: ~/.local/bin is not on PATH" >&2;; esac
