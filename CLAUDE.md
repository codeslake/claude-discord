# claude-discord

- A dev-manager session follows `rules/dev-manager.md` (the plugin's SessionStart hook injects it for a dev-manager bot).
- Code and comments are English.
- The test suite (`./test-claude-discord.sh ./bin/claude-discord`) must finish within 40 s wall time run serially, using stubs only: no real claude, claude -p, --bg sessions, network or Discord; no parallelism to hide time.
- A probe outside the suite sets a literal sandbox `HOME` in the same shell call that uses it, chains with `&&`, and never writes the real `~/.claude.json`, `~/.claude`, `~/.claude-discord` or `~/.local/bin`: env does not survive between Bash calls, and a probe that assumed it did overwrote the real `~/.claude.json` (2026-10-10).
