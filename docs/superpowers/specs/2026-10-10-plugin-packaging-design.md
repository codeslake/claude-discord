# claude-discord as a plugin: packaging and CLI (sub-project 1)

Status: draft for the owner's review, 2026-10-10. Decisions come from
codeslake/tor-aic-research issue #1, comments 6092544397 to 6093066614.
Measurements cited are Claude Code 2.1.296 on lmd42 (probe notes kept with
junyong-dev-bot).

## Goal

claude-discord becomes a self-contained Claude Code plugin. What a bot needs
(hooks, rules, tools, the launcher) lives in one directory that `setup`
installs and `update` refreshes, so no session depends on files scattered
under `~/.claude-discord/hooks`, on hook entries written into a project's
settings files, or on a rule file every session of the project loads.

Success means:

- `claude-discord setup <bot>` leaves exactly one copy of the plugin for the
  project and no claude-discord hook entries in any settings file.
- Every running bot on lmd42, wmac, pmac, lmd79 and dongyong22's wmac moves
  to the plugin without a restart and keeps answering.
- `claude-discord --bg --name RVP` and `claude-discord --bg --resume <uuid>`
  work as the owner ordered (issue #1 C11).
- The suite still runs serially in 40 s on stubs only.

## Out of scope

- The backend monitor, health alerts to `#bot-health-check` and the TUI: the
  next spec. This spec only extracts the patch step they will call.
- A per-token router (shared bot token) and relation armbands: later specs.
- Our own Discord MCP server: withdrawn. A channel server that is not on
  Anthropic's approved list registers only through a managed policy file, and
  `--dangerously-load-development-channels` is dropped for `--bg` and never
  saved for a respawn (measured). The official
  `discord@claude-plugins-official` stays the channel, with our patches.

## Layout

The repo itself is the plugin. Everything a session or hook needs is inside it.

```
claude-discord/                     (the git clone setup makes)
  .claude-plugin/plugin.json        name "claude-discord", version (semver)
  hooks/hooks.json                  the nine hooks, ${CLAUDE_PLUGIN_ROOT} paths
  hooks/lib, turn/, peers/, autoresearchclaw/   (as today)
  tools/thread, tools/local-bots, tools/arc-events   (moved out of hooks/)
  rules/dev-manager.md, rules/autoresearchclaw.md   (injected, not copied)
  bin/claude-discord                the wrapper (moved from the repo root)
  runtime/discord-chunk.ts, runtime/discord-proxy.ts
  shim/claude-discord               the ~/.local/bin launcher, see below
  test-claude-discord.sh, README.md, CLAUDE.md, docs/
```

`plugin.json` declares no MCP server. The plugin carries hooks only.

## Install scopes

`setup` asks once per project (`--scope project|global` for scripts):

- **project** (default, Enter): `git clone https://github.com/codeslake/claude-discord <project>/.claude/skills/claude-discord`.
  The clone is a plain directory, not a link: the measured link problems
  (`${CLAUDE_PLUGIN_ROOT}` naming the link, `.mcp.json` skipped outside the
  project) do not arise. A git-tracked project gets the path in
  `.git/info/exclude`, added only when missing.
- **global**: the same clone at `~/.claude/skills/claude-discord`.

A plugin present in both places loads once, the global copy winning, and the
project copy reports "shadowed" (measured). `setup` therefore refuses to
install a project copy when a global one exists, and the reverse, naming the
other path. Re-running `setup` is idempotent: an existing clone is kept and
not re-cloned.

Project scope loads only when `~/.claude.json` has
`projects[<path>].hasTrustDialogAccepted = true` for that exact path (a
trusted parent is not enough; measured). `setup` checks it and, when it is
missing, says so and offers to write it; it never writes it silently.

## The launcher

The plugin's `bin/` is on PATH only for a session's Bash tool (measured), so
a terminal needs a stable entry. `setup` installs `~/.local/bin/claude-discord`
as a 20-line shim (`shim/claude-discord`, copied, not linked) that finds the
wrapper for the current directory:

1. `<project root>/.claude/skills/claude-discord/bin/claude-discord`, where the
   project root is the nearest ancestor holding `.claude/discord-agents` or
   `.claude/skills/claude-discord`;
2. else `~/.claude/skills/claude-discord/bin/claude-discord`;
3. else it prints that claude-discord is not set up here and how to set it up.

Each project therefore runs the version installed for it. The shim itself
changes rarely; `update` refreshes it when it differs.

## Bootstrap

A machine with no clone yet runs the one-liner in the README:
`git clone https://github.com/codeslake/claude-discord ~/.claude-discord/bootstrap && ~/.claude-discord/bootstrap/bin/claude-discord setup <bot>`.
`setup` then makes the real clone at the chosen scope and installs the shim;
the bootstrap clone is removed at the end of a successful setup.

## Update

`claude-discord update` runs, for the clone the shim resolved:
`git -C <clone> pull --ff-only`, then the patch step, then the shim refresh,
then prints the plugin version before and after and tells the operator to run
`/reload-plugins` in running sessions (a bot does it through the self-reload
skill). `update --all` does the same for every clone recorded in
`~/.claude-discord/records/installs` (one path per line, written by `setup`,
pruned when a path no longer exists).

Versioning: `plugin.json` `version` is bumped in every commit that changes
behaviour; `update` prints it, and `claude-discord --version` prints it with
the clone's short sha.

## Hooks

`hooks/hooks.json` registers all nine hooks unconditionally with
`"${CLAUDE_PLUGIN_ROOT}/hooks/<topic>/<script>"`, no shell wrapper. Each script
already exits 0 when `DISCORD_STATE_DIR` is unset or its mode does not match,
so a non-bot session in the project pays one exec per event. Matchers stay on
the official plugin's tool names (`mcp__plugin_discord_discord__reply` and
`__edit_message`), since the official plugin stays the channel.

`register_hooks` turns into a remover: it deletes every entry whose command
names `/.claude/discord-agents/hooks/` from the project's `settings.json` and
`settings.local.json`, and nothing else. The `discord-agents/hooks` symlink is
kept for this release (old peers' committed settings may still point at it)
and removed in the next one.

## Rules and tool paths

The dev-manager rule text (today copied to
`.claude/rules/claude-discord-dev-manager.md`, read by every session of the
project) is emitted by the plugin's SessionStart hook as `additionalContext`,
only for a bot whose mode is `dev-manager`, on startup, resume, compact and
clear: the same path autoresearchclaw already uses. `setup` removes the old
rule file.

No text hard-codes `~/.claude-discord/hooks/tools/...` any more. The wrapper's
system prompt, the on-prompt identity text and thread-guard's deny message
name `$CLAUDE_PLUGIN_ROOT/tools/thread` resolved to an absolute path at the
moment they are written. For this release `~/.claude-discord/hooks/tools/thread`
stays as a symlink to the installed tool, so a session started by the old
wrapper keeps working until its next start.

What the old `install.sh` put under `~/.claude-discord/` is removed by
`setup`: `hooks/` (except that one link), `rules/`, and the top-level
`discord-chunk.ts` and `discord-proxy.ts`. What stays there is `runtime/`,
`records/`, `scratch/` (bots' own notes) and the compat link, which the next
release removes too. `~/.local/bin/claude-discord` is replaced by the shim.

## Patches on the official plugin

The four patches (bot authors reach the allowFrom gate, `@everyone` ignored,
fence-safe chunking, the proxy preload in `bunfig.toml`) move out of the start
path into `claude-discord patch`, and a fifth joins them: the official
plugin's `.mcp.json` gets `"env": {"DISCORD_STATE_DIR": "${DISCORD_STATE_DIR}"}`.
Claude Code's 15-minute MCP failure cache keys on the server config hashed
after `${VAR}` expansion (measured), and the official config carries no env,
so today one bot's failed start skips the channel for every bot started on
the machine in the next 15 minutes (issue #1 F1). With the env line each bot
hashes differently. `patch` does all five:

- applies to **every** version directory under
  `~/.claude/plugins/cache/claude-plugins-official/discord/*/`, since an
  auto-update adds a new unpatched directory while bots run on the old one
  (measured: updates run 0-10 min after any process starts; running sessions
  keep their version; a new start, respawn, config-changing `/reload-plugins`
  or `/mcp` reconnect uses the new one);
- idempotent, silent when nothing changed, exit 1 with the file and the patch
  name when a pattern no longer matches;
- imports the runtime files from a stable copy at `~/.claude-discord/runtime/`
  (copied by `setup`/`update` from the clone), because the official plugin's
  cache is machine-wide while clones are per project.

Callers: the wrapper's start (as today), the plugin's SessionStart hook (so a
respawn or an auto-update before the start is covered), and, in the next spec,
the backend monitor every five minutes.

## CLI

- `claude-discord --bg --name RVP` starts bot RVP; `--name`/`-n` IS the bot
  name and the session name (the refusal added in 7979aee becomes this
  meaning). The bot must be set up in the project.
- `claude-discord --bg --resume <uuid|name|short id>` finds the bot from the
  job record whose `respawnFlags` carry `DISCORD_STATE_DIR` (the same match
  refresh uses), else from the single bot in the project, else asks for
  `--name`.
- If the session that `--resume` names is live, the start refuses and points
  at `claude-discord refresh <bot>`: a second copy would put two sessions on
  one token, and the old row could be revived by a fleet claim.
- The positional form `claude-discord RVP --bg ...` keeps working this release
  and prints one deprecation line naming the new form.
- Subcommands keep the bot positional: `setup <bot>`, `refresh <bot>`,
  `health`, `update`, `patch`. The owner's order is about the launch mirroring
  `claude`; `refresh` keeps refusing `--name`.
- Every other argument still passes through to `claude` unchanged; the
  owner's launcher sets permission mode, effort and model.

## Migration (running bots, no restart)

Per machine, by its operator (dkim's boxes: dong-dev-bot):

1. `git clone` and `setup` (scope chosen per project) install the plugin and,
   in the same run, remove the old settings hook entries and the old rule
   file. Hooks in settings files apply live (measured), so from this moment a
   running bot has no claude-discord hooks.
2. Each running bot runs `/reload-plugins` (self-reload skill), which loads
   the plugin's `hooks.json` (measured). The gap between 1 and 2 is seconds.
   A message that lands in the gap gets no ✅ and no turn record; the next
   message heals both.
3. `claude-discord --version` and `health` confirm each bot.

Rollback: `git -C <clone> checkout <previous tag>` and `setup` again, or the
previous release's `install.sh`, which re-registers the settings hooks.

## Testing

- The bash suite stays the gate (40 s serial, stubs only). New cases: the
  shim's resolution order; `setup --scope` both ways, the both-scopes refusal
  and idempotence; `register_hooks` removing old entries and nothing else;
  `hooks.json` naming only files that exist and are executable; the
  SessionStart rule injection by mode; `patch` across two version dirs (all
  five, including the `.mcp.json` env line), idempotence and the no-match
  exit; `--name` and `--resume` bot resolution, the refusal to resume a live
  session, and the deprecation line; `setup` removing the old
  `~/.claude-discord/hooks` and `rules` copies while keeping the compat link.
- `claude plugin validate` (or the equivalent load check) runs as a separate
  script outside the 40 s budget, as decided in issue #1 C1 Q1.
- Before main, one live check on lmd42 with a non-critical bot: install,
  `/reload-plugins`, one answered mention with ✅.

## Review

junyong-dev-bot implements; dong-dev-bot reviews every diff before main and
installs on lmd79 and dongyong22's wmac after main.
