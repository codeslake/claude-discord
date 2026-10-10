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
  project, and the plugin's first hook run in a bot session leaves no
  claude-discord hook entry in the project's own settings files (one it may
  not edit runs as a no-op; see Migration).
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
  .claude-plugin/plugin.json        name "discord-agents", version (semver)
  hooks/hooks.json                  the nine hooks, ${CLAUDE_PLUGIN_ROOT} paths
  hooks/lib, turn/, peers/, autoresearchclaw/   (as today)
  tools/thread, tools/local-bots, tools/arc-events   (moved out of hooks/)
  rules/dev-manager.md, rules/autoresearchclaw.md   (injected, not copied)
  bin/claude-discord                the wrapper (moved from the repo root)
  runtime/discord-chunk.ts, runtime/discord-proxy.ts
  shim/claude-discord               the ~/.local/bin launcher, see below
  test-claude-discord.sh, README.md, CLAUDE.md, docs/
```

`plugin.json` declares no MCP server. The plugin carries hooks only. Its name is
`discord-agents` (R18): `claude plugin validate` reserves names starting with
`claude-`, and a loader that enforces it would silently drop every bot's hooks.
The install path stays `.claude/skills/claude-discord` and the CLI stays
`claude-discord`.

## Install scopes

`setup` asks two questions once per project (`--scope project|global` and
`--method link|clone` for scripts; owner decision 2026-10-10), installs, and
only then asks the bot questions (R17), so a failed clone writes no bot file
(`install` asks neither, see below):

- **scope**: **project** (default, Enter) puts the plugin at
  `<project>/.claude/skills/claude-discord`; **global** at
  `~/.claude/skills/claude-discord`.
- **method**: **link** (default, Enter) makes that path a symlink to the
  machine's one source clone, `~/.claude-discord/source` (cloned from
  `https://github.com/codeslake/claude-discord` when missing), so one `update`
  moves every bot on the machine. **clone** makes that path its own git clone,
  so a project can pin its own version.
  The measured link problems do not bite: every hook and tool resolves its
  real directory (`cd -P`, `readlink -f`) instead of trusting
  `${CLAUDE_PLUGIN_ROOT}`, and the plugin declares no MCP server, so the
  skipped `.mcp.json` does not matter.

A git-tracked project (a worktree, a submodule or a subdirectory of a repo
included) gets the path in the repo's `info/exclude`, added only when missing.
When the project already has an install at either scope, setup uses it and
asks nothing; both questions are validated before any other setup step
writes anything.

`claude-discord install [--scope project|global] [--method link|clone]` does
the install part alone: the plugin, the shim, `runtime/`, the compat copy and
the install record. It reads no stdin at all, so a bootstrap script's stdin is
left alone: an install already there decides the scope, else project; the
method is link unless `--method` says otherwise; an untrusted project gets a
one-line hint (accept the trust dialog, or answer y in `setup`), never a
question. It is safe to re-run, and it is the bootstrap's command.

Every setup prompt's Enter keeps the bot's current value (the token, the
mention policy read from its `access.json`, the mode, the peers list). Stdin
ending before a required answer (the IDs, the token, the mention policy) prints
which prompt went unanswered and exits 2; the mode and peers prompts take their
default.

A plugin present in both places loads once, the global copy winning, and the
project copy reports "shadowed" (measured). Two links to the source clone are
the same code, so both scopes may hold an install when both are links to
`~/.claude-discord/source` (a new one beside an existing link is made a link).
When a clone is involved on either side, `setup` and `install` refuse before
writing anything, naming the other path. A bot in `$HOME` (`pwd -P` equals
`cd -P $HOME`) has `~/.claude` as its project `.claude`, so its install is the
global one, and setup says so. Re-running `setup` is idempotent: an existing
link or clone is kept as it is.

Project scope loads only when `~/.claude.json` has
`projects[<path>].hasTrustDialogAccepted = true` for that exact path (a
trusted parent is not enough; measured). `setup` checks it and, when it is
missing, says so and offers to write it; it never writes it silently.
`install` only prints the hint.

## The launcher

The plugin's `bin/` is on PATH only for a session's Bash tool (measured), so
a terminal needs a stable entry. `setup` installs `~/.local/bin/claude-discord`
as a short shim (`shim/claude-discord`, copied, not linked) that finds the
wrapper for the current directory:

1. `<project root>/.claude/skills/claude-discord/bin/claude-discord`, where the
   project root is the nearest ancestor holding `.claude/discord-agents` or
   `.claude/skills/claude-discord`;
2. else `~/.claude/skills/claude-discord/bin/claude-discord`;
3. else the machine's source clone, `~/.claude-discord/source/bin/claude-discord`
   (R3), so a project with no install of its own, new or not yet migrated,
   still reaches `setup`, a launch, `refresh`, `update` and `--version`;
4. else it prints that claude-discord is not set up on this machine and the
   clone one-liner (shown only when the source clone is missing).

Each project therefore runs the version installed for it. The shim itself
changes rarely; `update` refreshes it when it differs.

## Bootstrap

A machine with no clone yet runs the one-liner in the README:
`git clone https://github.com/codeslake/claude-discord ~/.claude-discord/source && ~/.claude-discord/source/bin/claude-discord install`,
from the project directory, then `claude-discord setup <bot>` per bot.
The first clone is the machine's source clone, so nothing is removed
afterwards: `install` links to it (method link) or clones from the repo URL
(method clone), and installs the shim.

Every clone and pull runs with `GIT_TERMINAL_PROMPT=0` (a script never hangs
on a credential prompt) under `timeout 120` where `timeout` exists. They use
the ambient git config and environment; a proxy is set per clone, e.g.
`git -C ~/.claude-discord/source config http.proxy <url>` (a machine where a
direct path is forbidden, such as lmd79).

## Update

`claude-discord update` runs, for the clone the shim resolved (a link
resolves to the source clone): `git -C <clone> pull --ff-only`, then the
patch step, the compat copy refresh and the shim refresh, all run from the freshly pulled code as a
new process (the running one still holds the old functions; `runtime/` and
the patched cache are machine-wide, so the source clone owns them, else the
first clone pulled), then prints the plugin version before and after and tells the operator to run
`/reload-plugins` in running sessions (a bot does it through the self-reload
skill). `update --all` does the same for every clone recorded in
`~/.claude-discord/records/installs` (one path per line, written by `setup`,
pruned when a path no longer exists), each real clone once however many
links point at it. A clone on a detached HEAD (pinned to a tag or sha) is
reported `pinned at <sha>, skipped` and is not a failure. Hook scripts and
tools run from the clone on disk, so a running bot uses the new ones at its
next hook call; `/reload-plugins` is for the manifest and `hooks/hooks.json`.

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

The entries earlier releases wrote into settings files (a command naming
`/.claude/discord-agents/hooks/`) are removed by the plugin's own first hook run
in a bot session, not by `setup` (R15; see Migration), and nothing else in
those files is touched. The `discord-agents/hooks` symlink is
kept for this release (old peers' committed settings may still point at it)
and removed in the next one.

## Rules and tool paths

The dev-manager rule text (today copied to
`.claude/rules/claude-discord-dev-manager.md`, read by every session of the
project) is emitted by the plugin's SessionStart hook as `additionalContext`,
only for a bot whose mode is `dev-manager`, on startup, resume, compact and
clear: the same path autoresearchclaw already uses. The plugin's first hook
run in a bot session removes the old rule file (R15).

No text hard-codes `~/.claude-discord/hooks/tools/...` any more. The wrapper's
system prompt, the on-prompt identity text and thread-guard's deny message
name `$CLAUDE_PLUGIN_ROOT/tools/thread` resolved to an absolute path at the
moment they are written, and the rule text names `$CLAUDE_DISCORD_TOOLS`,
which the SessionStart hook states in the session's context.

What the old `install.sh` put under `~/.claude-discord/` is replaced by
`setup` (ruling R8). A project set up by the previous release and not yet by
this one keeps its settings hook entries, and those resolve through
`.claude/discord-agents/hooks` to `~/.claude-discord/hooks`; a session started
by the old wrapper also names `~/.claude-discord/hooks/tools/thread`. Deleting
the copies would silently disable all of them, so for this release:

- `~/.claude-discord/hooks/{turn,peers,lib,autoresearchclaw}`, every tool under
  `hooks/tools/*`, and the top-level `discord-chunk.ts` and `discord-proxy.ts`
  become **links**: the hooks and tools into `~/.claude-discord/compat/`, the
  two `.ts` files into the stable runtime copy `~/.claude-discord/runtime/`,
  which `setup` fills first so the links never dangle. A real directory or file
  there is replaced; a symlink at `hooks/` itself is removed as a link and
  its target left alone.
- `compat/` (R16) is a plain copy, no git, of the real plugin's (the source
  clone, else the clone itself, never a project's own link)
  `hooks/{turn,peers,lib,autoresearchclaw}`, `tools/` and `rules/`. The
  previous release's `install.sh` writes through these links (measured by
  dong-dev-bot: six files of the source clone changed, and `update` then
  refused to pull for good); through the copy the write never reaches a git
  tree. `setup`, `install` and `update` rebuild it when it differs from the
  plugin, in a new directory swapped in by rename (a hook already running keeps
  its open file).
- `rules/` is removed: only the old rule copies read it.
- `runtime/`, `records/`, `scratch/` (bots' own notes) and `source/` stay.
  `compat/` goes with the links.
- The next release removes the links, but only those no job record still names: a bot started by the old wrapper keeps `~/.claude-discord/hooks/tools/thread` in its saved `--append-system-prompt`, and a `claude respawn` replays it (measured on lmd42 2026-10-10: RVP and cswap). Grep `~/.claude/jobs/*/state.json` before deleting, or relaunch those bots through the wrapper first.

`~/.local/bin/claude-discord` is replaced by the shim.

## Patches on the official plugin

The four patches (bot authors reach the allowFrom gate, `@everyone` ignored,
fence-safe chunking, the proxy preload in `bunfig.toml`) move out of the start
path into `claude-discord patch`, and a fifth joins them: the official
plugin's `.mcp.json` gets `"env": {"CLAUDE_DISCORD_BOT": "${DISCORD_STATE_DIR:-}"}`
(R19). Our own key, not the server's `DISCORD_STATE_DIR`: unset, a plain
`${DISCORD_STATE_DIR}` stays a literal string and masks the server's default
state dir for a user of the official plugin without claude-discord, while
`${VAR:-}` expands to an empty string (measured, 2.1.296). An earlier
release's `"DISCORD_STATE_DIR": "${DISCORD_STATE_DIR}"` line is removed.
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
  (copied by `setup`/`update` from the real clone), because the official
  plugin's cache is machine-wide while clones are per project;
- never downgrades: `runtime/VERSION` names the plugin version that wrote
  the runtime copy, and a wrapper older than a readable stamp leaves the
  runtime and the cache alone (one line saying so) instead of flipping them
  back at every start of two installs of different versions.

Callers: the wrapper's start (as today), the plugin's SessionStart hook (so a
respawn or an auto-update before the start is covered; a failure there is
appended to the bot's `health.log`, not discarded), and, in the next spec,
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
  one token, and the old row could be revived by a fleet claim. A dead
  session the agent list still shows as done counts as live too, so the
  refusal also names `claude stop <job id>`, after which `--resume` works.
- The positional form `claude-discord RVP --bg ...` keeps working this release
  and prints one deprecation line naming the new form. Beside `--name` it is
  refused (`claude-discord <bot> --name <other>`: a first bare word naming a set-up
  bot), naming both forms, instead of starting `<other>` with `<bot>` as a
  prompt.
- Subcommands keep the bot positional: `setup <bot>`, `refresh <bot>`,
  `health`, `update`, `patch`. The owner's order is about the launch mirroring
  `claude`; `refresh` keeps refusing `--name`.
- Every other argument still passes through to `claude` unchanged; the
  owner's launcher sets permission mode, effort and model.

## Migration (running bots, no restart)

Per machine, by its operator (dkim's boxes: dong-dev-bot):

1. `git clone` and `setup` (scope chosen per project) install the plugin. Setup
   removes nothing from the project (R15): it cannot know whether the plugin
   will load (an untrusted project, a trust prompt answered n, a bot that has
   not reloaded yet), and removing the old settings hooks before it does would
   leave the bot with none (✅, mention-guard, edit-gate, thread-guard gone, and
   after a compact the dev-manager rule too).
2. Each running bot runs `/reload-plugins` (self-reload skill). Measured on
   2.1.296, interactive and `--bg`: a plugin directory created after the
   session started loads on `/reload-plugins` with no restart and no respawn,
   and its UserPromptSubmit hook fires on the next prompt; a hook removed
   from `settings.local.json` stops on the very next prompt.
3. The migration happens on the plugin's first hook run in that session, the
   first moment the plugin is known to be loaded there. Every hook's first
   line exits 0 without `DISCORD_STATE_DIR` (no fork, nothing sourced), and
   `edit-gate`, which a global install runs on every edit on the machine,
   also exits there for a bot that is not a dev-manager. A session is a bot
   only in its own project: a `claude -p` that inherits `DISCORD_STATE_DIR`
   in another project (`$DISCORD_STATE_DIR/..` is not
   `$CLAUDE_PROJECT_DIR/.claude/discord-agents`) is not. Every hook then calls
   `plugin_gate` (`hooks/lib/discord.sh`). A plugin hook
   (`CLAUDE_PLUGIN_ROOT` set and the script under it) in a bot session
   (`DISCORD_STATE_DIR` set) reads `session_id` from its stdin JSON (a bash
   match, no jq) and checks for `$DISCORD_STATE_DIR/plugin-sessions/<session_id>`
   (one `[ -e ]`; a hook that finds it touches it, so a live session's marker
   stays fresh). On the first run it creates that marker (noclobber, so one
   of an event's parallel hooks wins), prunes markers no hook touched for 30
   days, and
   removes this project's own old entries: from
   `$CLAUDE_PROJECT_DIR/.claude/settings.json` and `settings.local.json` only
   when each is a regular file (`[ -f ] && [ ! -L ]`) and is not
   `~/.claude/settings.json` (a bot in `$HOME`), and only when the project's
   `.claude` (and its `rules/`) resolves inside the project (a `.claude` that
   is a link into a dotfiles tree is not the project's own), and the
   `.claude/rules/claude-discord-*.md` files (`hooks/lib/old-hooks.sh`). A
   regular file is replaced by renaming a mode-preserving copy, so Claude Code,
   which re-reads settings live, never reads it half written. A symlinked
   settings file or the user-global one is never edited.
4. An old-path hook (no `CLAUDE_PLUGIN_ROOT`, or run from a path under
   `/.claude/discord-agents/hooks/` or `~/.claude-discord/hooks/`) exits 0 at
   once when its session has a marker. With no `plugin-sessions/` directory at
   all it does not even read its stdin, so an unmigrated bot pays nothing.
5. `claude-discord --version` and `health` confirm each bot.

Known double run: the first event after `/reload-plugins` runs the old hooks
and the plugin's in parallel, and the old one may check for the marker before
the plugin's has written it: that one event is recorded twice (one duplicate
turn record per bot, a second ✅ attempt). Where an old entry stays because the
plugin may not edit its file (a symlinked settings.json, the user-global
settings.json, as on lmd79), the same happens once at the first event of every
new session (a startup, a `/clear`, which brings a new session id). `setup`
names such files on stderr with the command that removes the entries by hand,
`bash <plugin>/hooks/lib/old-hooks.sh <file>...` (for a symlink it renames a
new copy over the resolved target, so the link stays; the owner commits it
where the file lives). Those entries still serve every bot on the machine, and
on every machine sharing that file, whose plugin is not loaded yet: removing
them early silently takes ✅, mention-guard, edit-gate and thread-guard from
those bots (dong #3). The hint says so: run it only once each of those bots has
a `<bot dir>/plugin-sessions/` marker.

The plugin's SessionStart hook does NOT run on a reload, only at the next real
start, compact or clear. That is harmless here: the dev-manager rule text is
already in the running session's context from the old rule file (removing the
file does not unload it), and the official plugin was patched by the wrapper
when the bot started.

Rollback (R13): the previous release's `install.sh` writes through the R8
links (into the compat copy since R16), and a plugin install left in place
keeps loading, so first remove the plugin installs (each path in
`~/.claude-discord/records/installs`: `rm` a link, `rm -rf` a clone) and
`rm -rf ~/.claude-discord/hooks ~/.claude-discord/discord-chunk.ts
~/.claude-discord/discord-proxy.ts` (only links remain there); then
`cd ~/.claude-discord/source && git checkout <previous tag> && ./install.sh`,
which re-registers the settings hooks. Or stay on this release and
`git -C <clone> checkout <previous tag>` of a clone-method install.

## Testing

- The bash suite stays the gate (40 s serial, stubs only). New cases: the
  shim's resolution order; `setup --scope` both ways, the both-scopes refusal
  and idempotence; the old-entry removal touching nothing else;
  `hooks.json` naming only files that exist and are executable; the
  SessionStart rule injection by mode; `patch` across two version dirs (all
  five, including the `.mcp.json` env line), idempotence and the no-match
  exit; `--name` and `--resume` bot resolution, the refusal to resume a live
  session, and the deprecation line; `setup` replacing the old
  `~/.claude-discord/hooks` and `.ts` copies with compat links (R8) into the
  compat copy (R16), which absorbs an old `install.sh` write, and removing
  `rules`; the plugin's first hook run migrating only the project's regular
  settings files and rule copies, an old-path hook exiting in a marked session
  and running in an unmarked one, setup removing nothing (a trust answered n
  included); `install` asking nothing; Enter keeping `requireMention`; the EOF
  message; a failed clone writing no bot file; `update` and `update --all` (one pull per real clone,
  removed projects pruned); `--version`.
- `claude plugin validate` (or the equivalent load check) runs as a separate
  script outside the 40 s budget, as decided in issue #1 C1 Q1.
- Before main, one live check on lmd42 with a non-critical bot: install,
  `/reload-plugins`, one answered mention with ✅.

## Review

junyong-dev-bot implements; dong-dev-bot reviews every diff before main and
installs on lmd79 and dongyong22's wmac after main.
