# claude-discord

- A dev-manager session follows `rules/dev-manager.md` (setup installs it into the project as `.claude/rules/claude-discord-dev-manager.md`).
- Code and comments are English.
- The test suite (`./test-claude-discord.sh ./claude-discord`) must finish within 30 s wall time run serially, using stubs only: no real claude, claude -p, --bg sessions, network or Discord; no parallelism to hide time.
