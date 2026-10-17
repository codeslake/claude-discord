# claude-discord

- A dev-manager session follows `rules/dev-manager.md` (the plugin's SessionStart hook injects it for a dev-manager bot).
- Code and comments are English.
- The test suite is two files sharing `tests/suite-lib.sh`: `./test-claude-discord.sh ./bin/claude-discord` (core) and `./test-install.sh ./bin/claude-discord` (setup, install, update, compat, patch). Each must finish within 40 s wall time run serially on the reference machine (lmd42), using stubs only: no real claude, claude -p, --bg sessions, network or Discord; no parallelism to hide time. Run the file a change touches while working, both before a push.
- A probe outside the suite sets a literal sandbox `HOME` in the same shell call that uses it, chains with `&&`, and never writes the real `~/.claude.json`, `~/.claude`, `~/.claude-discord` or `~/.local/bin`: env does not survive between Bash calls, and a probe that assumed it did overwrote the real `~/.claude.json` (2026-10-10).
