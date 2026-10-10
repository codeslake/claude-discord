# claude-discord plugin packaging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the claude-discord repo into a skills-dir Claude Code plugin that `setup` git-clones into a project (or globally), with hooks in `hooks/hooks.json`, a stable `~/.local/bin` shim, a `patch` subcommand for the official discord plugin, and the `--name`/`--resume` CLI.

**Architecture:** The repo root becomes the plugin root (`.claude-plugin/plugin.json`, `hooks/hooks.json`). The bash wrapper moves to `bin/claude-discord`; session tools move to `tools/`; the two bun helpers move to `runtime/` and are copied to a stable `~/.claude-discord/runtime/` that the patched official plugin imports. Hooks find the plugin root from their own path, never from `~/.claude-discord/hooks`. `register_hooks` becomes a remover of old settings entries.

**Tech Stack:** bash (3.2-compatible: macOS), jq, perl (patches), git, the existing stub-only suite `test-claude-discord.sh`.

**Spec:** `docs/superpowers/specs/2026-10-10-plugin-packaging-design.md` (branch `spec/plugin-packaging`). Read it before Task 1.

## Global Constraints

- Suite: `./test-claude-discord.sh ./bin/claude-discord` must pass serially in 40 s wall time on stubs only (no real claude, network, Discord, `--bg`), per `CLAUDE.md`. Measure it quiet (load < 4) before the last commit.
- Code and comments in English; match the wrapper's comment density (a why per non-obvious line).
- bash 3.2 compatible (no `declare -A`, no `${x,,}`, no `mapfile` outside health's Linux-only path, no `&>>`).
- No file outside the repo, `$HOME/.claude-discord/{runtime,records}`, the chosen skills dir and `~/.local/bin/claude-discord` is written by `setup`/`update`.
- Plugin name `claude-discord`; `plugin.json` `version` starts at `1.0.0` and is bumped in every behaviour-changing commit.
- Hook matchers stay `mcp__plugin_discord_discord__reply` and `mcp__plugin_discord_discord__reply|mcp__plugin_discord_discord__edit_message` (the official plugin stays the channel).
- Official plugin cache glob: `$HOME/.claude/plugins/cache/claude-plugins-official/discord/*/`.
- Repo URL default: `https://github.com/codeslake/claude-discord`; tests override it with `CLAUDE_DISCORD_REPO` (a local bare repo), never the network.
- Every commit on a review branch; dong-dev-bot reviews before main (project rule).

## Review Focus

1. **A project whose path contains spaces** (`/home/x/my project`): the shim, setup's clone path, `.git/info/exclude` and `hooks.json` commands must all quote; expected: works. Test added in Task 5 and Task 6.
2. **Setup re-run on a machine that still has the old install** (`~/.claude-discord/hooks/`, settings.local.json entries, `.claude/rules/claude-discord-dev-manager.md`): expected one plugin copy, zero old entries, compat `tools/thread` link present, `scratch/` untouched. Test in Task 7.
3. **Two discord plugin versions in the cache, one already patched** (auto-update while bots run): expected both patched, second run silent, exit 0. Test in Task 3.
4. **Upstream server.ts changed so a pattern no longer matches**: expected exit 1 naming file and patch, other patches still applied, start continues with a warning. Test in Task 3.
5. **`--resume` of a session that is still live**: expected refusal pointing at `refresh`, nothing started. Test in Task 8.

---

### Task 1: Plugin manifest and hooks.json

**Files:**
- Create: `.claude-plugin/plugin.json`
- Create: `hooks/hooks.json`
- Modify: `test-claude-discord.sh` (new block near the top, after the `bash -n` lines)

**Interfaces:**
- Produces: `hooks/hooks.json` naming `${CLAUDE_PLUGIN_ROOT}/hooks/<topic>/<script>` for the nine hooks; `plugin.json` `.version`, read later by `--version` (Task 9).

- [ ] **Step 1: Write the failing test** (append after the existing `bash -n` block)

```bash
# The plugin manifest and hooks.json: valid JSON, name claude-discord, and every
# hook command names a script that exists in the repo and is executable.
jq -e '.name == "claude-discord" and (.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))' "$D/.claude-plugin/plugin.json" >/dev/null || { echo "FAIL: plugin.json needs name claude-discord and a semver version"; exit 1; }
cmds=$(jq -r '.hooks[][] .hooks[] .command' "$D/hooks/hooks.json") || { echo "FAIL: hooks.json is not valid"; exit 1; }
[ "$(printf '%s\n' "$cmds" | wc -l | tr -d ' ')" = 9 ] || { echo "FAIL: hooks.json must register the nine hooks: $cmds"; exit 1; }
while IFS= read -r c; do
  # quoted, so a plugin root with a space in its path still runs
  case $c in '"${CLAUDE_PLUGIN_ROOT}/hooks/'*'"') ;; *) echo "FAIL: hook command must be \"\${CLAUDE_PLUGIN_ROOT}/hooks/...\" (quoted): $c"; exit 1;; esac
  f=${c#'"${CLAUDE_PLUGIN_ROOT}/'}; f=$D/${f%'"'}
  [ -x "$f" ] || { echo "FAIL: hooks.json names a missing or non-executable $f"; exit 1; }
done <<<"$cmds"
jq -e '.hooks.PreToolUse[] | select(.matcher == "mcp__plugin_discord_discord__reply|mcp__plugin_discord_discord__edit_message") | .hooks[] | select(.command | endswith("peers/thread-guard\""))' "$D/hooks/hooks.json" >/dev/null || { echo "FAIL: thread-guard must cover reply and edit_message"; exit 1; }
echo "ok: plugin.json and hooks.json are valid and every hook command exists"
```

- [ ] **Step 2: Run it**

Run: `./test-claude-discord.sh ./claude-discord 2>&1 | grep -m1 -E 'FAIL|ok: plugin'`
Expected: `FAIL: plugin.json needs name claude-discord ...` (file missing).

- [ ] **Step 3: Create the files**

`.claude-plugin/plugin.json`:
```json
{
  "name": "claude-discord",
  "version": "1.0.0",
  "description": "Runs Claude Code sessions behind their own Discord bots: turn hooks, peer guards, thread tools.",
  "author": {"name": "codeslake"},
  "license": "MIT"
}
```

`hooks/hooks.json` (same events and matchers `register_hooks` writes today, `claude-discord:131-134`):
```json
{
  "hooks": {
    "UserPromptSubmit": [
      {"hooks": [{"type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/turn/on-prompt\""}]}
    ],
    "PostToolUse": [
      {"matcher": "mcp__plugin_discord_discord__reply", "hooks": [
        {"type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/turn/on-reply\""},
        {"type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/peers/checkin\""}
      ]}
    ],
    "Stop": [
      {"hooks": [{"type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/turn/on-stop\""}]}
    ],
    "SessionStart": [
      {"matcher": "startup|resume|compact|clear", "hooks": [
        {"type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/turn/on-session-start\""},
        {"type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/autoresearchclaw/on-start\""}
      ]}
    ],
    "PreToolUse": [
      {"matcher": "mcp__plugin_discord_discord__reply", "hooks": [
        {"type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/peers/mention-guard\""}
      ]},
      {"matcher": "mcp__plugin_discord_discord__reply|mcp__plugin_discord_discord__edit_message", "hooks": [
        {"type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/peers/thread-guard\""}
      ]},
      {"matcher": "Edit|Write|MultiEdit", "hooks": [
        {"type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/peers/edit-gate\""}
      ]}
    ]
  }
}
```

- [ ] **Step 4: Run it**

Run: `./test-claude-discord.sh ./claude-discord 2>&1 | grep -m1 -E 'FAIL|ok: plugin'`
Expected: `ok: plugin.json and hooks.json are valid and every hook command exists`.

- [ ] **Step 5: Commit**

```bash
git add .claude-plugin/plugin.json hooks/hooks.json
git commit -m "plugin: manifest and hooks.json for the nine hooks" -- .claude-plugin/plugin.json hooks/hooks.json test-claude-discord.sh
```

---

### Task 2: Move the wrapper, tools and runtime files into the plugin layout

**Files:**
- Move: `claude-discord` → `bin/claude-discord`
- Move: `hooks/tools/thread` → `tools/thread`, `hooks/tools/local-bots` → `tools/local-bots`, `hooks/autoresearchclaw/events` → `tools/arc-events`
- Move: `discord-chunk.ts`, `discord-proxy.ts` → `runtime/`
- Modify: `hooks/lib/discord.sh` (add `plugin_root`), `hooks/turn/on-prompt:111`, `hooks/peers/thread-guard:193`, `hooks/autoresearchclaw/on-start:20`, `rules/autoresearchclaw.md:9`, `bin/claude-discord:1185` (system prompt), `test-claude-discord.sh` (paths)

**Interfaces:**
- Produces: in `hooks/lib/discord.sh`, `plugin_root` (absolute path of the plugin root, resolved from the lib's own location) and `thread_tool="$plugin_root/tools/thread"`. In the wrapper, `self_root` = absolute plugin root (`bin/..`).
- Consumes: nothing new.

- [ ] **Step 1: Move with history**

```bash
mkdir -p bin tools runtime
git mv claude-discord bin/claude-discord
git mv hooks/tools/thread tools/thread
git mv hooks/tools/local-bots tools/local-bots
git mv hooks/autoresearchclaw/events tools/arc-events
git mv discord-chunk.ts runtime/discord-chunk.ts
git mv discord-proxy.ts runtime/discord-proxy.ts
```

- [ ] **Step 2: Repoint the suite** (it now takes `./bin/claude-discord`; the repo root is one level up)

In `test-claude-discord.sh` line 12 replace
`D=$(dirname "$S")   # repo root: where hooks/ and install.sh live`
with
`D=$(cd "$(dirname "$S")/.." && pwd -P)   # repo root = plugin root (bin/claude-discord); -P matches the hooks' plugin_root`

and replace every `"$D/hooks/tools/thread"`, `"$D/hooks/tools/local-bots"`, `"$D/hooks/autoresearchclaw/events"` with `"$D/tools/thread"`, `"$D/tools/local-bots"`, `"$D/tools/arc-events"`:

```bash
sed -i 's#"\$D/hooks/tools/thread"#"$D/tools/thread"#g; s#"\$D/hooks/tools/local-bots"#"$D/tools/local-bots"#g; s#"\$D/hooks/autoresearchclaw/events"#"$D/tools/arc-events"#g' test-claude-discord.sh
grep -n 'hooks/tools\|autoresearchclaw/events' test-claude-discord.sh   # every remaining hit is reviewed by hand
```

Also replace the suite's install stand-in (lines 115-117): instead of copying `$D/hooks` and `$D/rules` into `$HOME/.claude-discord/`, link them, so every hook the suite runs through `$R/hooks` resolves `plugin_root` to `$D`:
```bash
mkdir -p "$HOME/.claude-discord"
ln -s "$D/hooks" "$HOME/.claude-discord/hooks"; ln -s "$D/rules" "$HOME/.claude-discord/rules"
```
(the two `: > discord-*.ts` stand-ins move to `$HOME/.claude-discord/runtime/` in Task 3). The test at line 457 that moves `hooks/lib/discord.sh` aside must then move the repo file and restore it in a `trap`, or copy the tree first; prefer copying `$D` to `$HOME/plugin-copy` once and linking that, so no test ever renames a file in the working tree.

- [ ] **Step 3: Write the failing test for the resolved tool path** (in the on-prompt identity assertion at `test-claude-discord.sh:193`, replace `~/.claude-discord/hooks/tools/thread` with the resolved path)

```bash
# the identity text names the thread tool by its absolute path in the plugin
TT="$D/tools/thread"
```
and in the expected string at line 193 use `$TT start` (make that assertion a double-quoted string with `$TT` expanded).

- [ ] **Step 4: Run it**

Run: `./test-claude-discord.sh ./bin/claude-discord 2>&1 | grep -m1 FAIL`
Expected: FAIL on the identity text (still names `~/.claude-discord/hooks/tools/thread`).

- [ ] **Step 5: Implement**

`hooks/lib/discord.sh`, after the variable defaults (near line 12):
```bash
# The plugin root, from this file's own location (hooks/lib/discord.sh), with
# symlinks resolved: tools and rules are named by absolute path in the text a
# session reads, so it must be the real install, wherever setup put it.
# cd -P: the hooks are often reached through the project's discord-agents/hooks
# symlink, and a logical `..` from there would land in discord-agents/.
plugin_root=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd -P) || plugin_root=""
thread_tool=$plugin_root/tools/thread
```

`hooks/turn/on-prompt:111`: replace `~/.claude-discord/hooks/tools/thread start` with `$thread_tool start`.

`hooks/peers/thread-guard:193`: replace `(~/.claude-discord/hooks/tools/thread start` with `($thread_tool start` and change the single-quoted deny string to double quotes, escaping its inner `"` as `\"`.

`hooks/autoresearchclaw/on-start:20`: `rule=$plugin_root/rules/autoresearchclaw.md`.

`rules/autoresearchclaw.md:9`: replace `~/.claude-discord/hooks/autoresearchclaw/events` with the placeholder `@ARC_EVENTS@`. `hooks/autoresearchclaw/on-start` substitutes it before emitting the rule, since the rule's Bash loop needs a real path (a context line is not an env var):
```bash
rule=$plugin_root/rules/autoresearchclaw.md
[ -f "$rule" ] || exit 0
sed "s#@ARC_EVENTS@#$plugin_root/tools/arc-events#g" "$rule" | jq -Rsc '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: .}}' 2>/dev/null
```
and the existing autoresearchclaw context test (suite ~1615, `ARC_RULE`) asserts the emitted text contains `$D/tools/arc-events` and no `@ARC_EVENTS@`.

`bin/claude-discord`, after `plugin=discord@claude-plugins-official` (line 62):
```bash
# This script lives at <plugin root>/bin/claude-discord; the plugin's tools
# and rules are named from here, resolved through any symlink to the real copy.
self_root=$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")/.." && pwd -P)
```
(`readlink -f` exists on macOS 12.3+; the fallback keeps older ones working when not linked.) In the prompt (line 1185) replace `~/.claude-discord/hooks/tools/thread start` with `$self_root/tools/thread start`.

- [ ] **Step 6: Run the whole suite**

Run: `./test-claude-discord.sh ./bin/claude-discord 2>&1 | tail -3`
Expected: `ALL PASS` (the install.sh block still passes until Task 7 replaces it; if it fails only on moved paths, fix its file list to the new paths).

- [ ] **Step 7: Commit** (bump `plugin.json` to `1.0.1`)

```bash
git commit -m "plugin layout: wrapper in bin/, tools/ and runtime/; hooks name tools by the resolved plugin root" -- bin tools runtime hooks rules .claude-plugin/plugin.json test-claude-discord.sh claude-discord discord-chunk.ts discord-proxy.ts
```

---

### Task 3: `claude-discord patch`

**Files:**
- Modify: `bin/claude-discord` (new `patch` verb before the launch; launch calls it; lines 1140-1171 removed)
- Test: `test-claude-discord.sh` (new block; the existing server.ts/bunfig assertions at ~545-580 updated to the runtime path)

**Interfaces:**
- Produces: `claude-discord patch` → exit 0 when every version dir is patched (silent when nothing changed, one line per changed file otherwise); exit 1 with `claude-discord: patch: <file>: <patch name> no longer matches` on stderr when a pattern is gone. Runtime copy at `$HOME/.claude-discord/runtime/discord-{chunk,proxy}.ts`.
- Consumes: `self_root` (Task 2).

- [ ] **Step 1: Write the failing tests**

```bash
# patch: every discord version dir in the cache, idempotent, the .mcp.json env
# line for the failure cache, a moved pattern reported with exit 1.
PC="$HOME/.claude/plugins/cache/claude-plugins-official/discord"
for v in 0.0.4 0.0.5; do
  mkdir -p "$PC/$v"
  cp "$HOME/fakeplugin/server.ts.orig" "$PC/$v/server.ts"
  printf '{"mcpServers":{"discord":{"command":"bun","args":["run","--cwd","${CLAUDE_PLUGIN_ROOT}","start"]}}}\n' > "$PC/$v/.mcp.json"
done
bash "$S" patch >/dev/null || { echo "FAIL: patch on two clean version dirs must exit 0"; exit 1; }
for v in 0.0.4 0.0.5; do
  grep -q 'msg.author.id === client.user?.id' "$PC/$v/server.ts" &&
  grep -q 'ignoreEveryone: true' "$PC/$v/server.ts" &&
  grep -qF "(await import(\"$HOME/.claude-discord/runtime/discord-chunk.ts\")).chunk(text, limit, mode)" "$PC/$v/server.ts" &&
  grep -qF "$HOME/.claude-discord/runtime/discord-proxy.ts" "$PC/$v/bunfig.toml" &&
  [ "$(jq -r '.mcpServers.discord.env.DISCORD_STATE_DIR' "$PC/$v/.mcp.json")" = '${DISCORD_STATE_DIR}' ] ||
  { echo "FAIL: patch must apply all five patches to $v"; exit 1; }
done
out=$(bash "$S" patch 2>&1) && [ -z "$out" ] || { echo "FAIL: a second patch run must be silent and exit 0: $out"; exit 1; }
[ -f "$HOME/.claude-discord/runtime/discord-chunk.ts" ] || { echo "FAIL: patch must keep the runtime copy"; exit 1; }
printf 'client.on(x, msg => {\n  if (msg.author.isBot()) return\n})\n' > "$PC/0.0.5/server.ts"
out=$(bash "$S" patch 2>&1) && { echo "FAIL: a pattern that no longer matches must exit 1"; exit 1; }
grep -q 'patch: .*0.0.5/server.ts: bot-authors no longer matches' <<<"$out" || { echo "FAIL: wrong no-match report: $out"; exit 1; }
rm -rf "$PC"
echo "ok: patch applies the five patches to every cached version, is idempotent and silent, and reports a moved pattern with exit 1"
```

Before this block, keep a pristine copy right after the fake plugin is created (top of the suite, after line 60): `cp "$HOME/fakeplugin/server.ts" "$HOME/fakeplugin/server.ts.orig"`.

- [ ] **Step 2: Run it**

Run: `./test-claude-discord.sh ./bin/claude-discord 2>&1 | grep -m1 -E 'FAIL|ok: patch'`
Expected: FAIL (no `patch` verb: it is taken as a bot name).

- [ ] **Step 3: Implement** — add before the `args=() name=""` launch parsing:

```bash
# Patches the official discord plugin's install(s) so bots can work together.
# Every version dir in the cache, not just the active one: an auto-update adds
# an unpatched dir while bots run on the old one, and the next start, respawn
# or config-changing /reload-plugins uses the new one (measured, 2.1.296).
# Five patches, each idempotent because its pattern is gone once applied:
#   bot-authors     let other bots reach access.json's allowFrom gate
#   ignore-everyone @everyone/@here wake no bot
#   chunk           fence-safe chunking, imported from the stable runtime copy
#   proxy           bunfig preload pinning fetch and WebSocket to HTTPS_PROXY
#   failure-cache   a per-bot env in .mcp.json, so Claude Code's 15-minute MCP
#                   failure cache (keyed on the config hashed after ${VAR}
#                   expansion) no longer blocks every bot for one bot's failure
# The runtime files are copied to ~/.claude-discord/runtime/ because the plugin
# cache is machine-wide while clones are per project. Exit 1 names the file and
# patch whose pattern moved; the others are still applied.
patch_official() {
  local rt=$HOME/.claude-discord/runtime d f rc=0 changed=""
  mkdir -p "$rt" && for f in discord-chunk.ts discord-proxy.ts; do
    cmp -s "$self_root/runtime/$f" "$rt/$f" || cp "$self_root/runtime/$f" "$rt/$f"
  done
  for d in "$HOME"/.claude/plugins/cache/claude-plugins-official/discord/*/; do
    f=$d/server.ts
    [ -f "$f" ] || continue
    if grep -q 'if (msg.author.bot) return' "$f"; then
      perl -pi -e 's/^(\s*)if \(msg\.author\.bot\) return$/$1if (msg.author.id === client.user?.id) return/' "$f"; changed="$changed $f"
    elif ! grep -qF 'msg.author.id === client.user?.id' "$f"; then
      echo "claude-discord: patch: $f: bot-authors no longer matches" >&2; rc=1
    fi
    if grep -q 'msg.mentions.has(client.user))' "$f"; then
      perl -pi -e 's/msg\.mentions\.has\(client\.user\)\)/msg.mentions.has(client.user, { ignoreEveryone: true }))/' "$f"; changed="$changed $f"
    elif ! grep -qF 'ignoreEveryone: true' "$f"; then
      echo "claude-discord: patch: $f: ignore-everyone no longer matches" >&2; rc=1
    fi
    if grep -qE '^[[:space:]]*const chunks = chunk\(text, limit, mode\);?[[:space:]]*$' "$f"; then
      CHUNK_TS=$rt/discord-chunk.ts perl -pi -e 's/^(\s*)const chunks = chunk\(text, limit, mode\)(;?\s*)$/$1const chunks = (await import("$ENV{CHUNK_TS}")).chunk(text, limit, mode)$2/' "$f"; changed="$changed $f"
    elif ! grep -qF '.chunk(text, limit, mode)' "$f"; then
      echo "claude-discord: patch: $f: chunk no longer matches" >&2; rc=1
    fi
    [ "$(cat "$d/bunfig.toml" 2>/dev/null)" = "preload = [\"$rt/discord-proxy.ts\"]" ] ||
      { printf 'preload = ["%s"]\n' "$rt/discord-proxy.ts" > "$d/bunfig.toml"; changed="$changed $d/bunfig.toml"; }
    if [ -f "$d/.mcp.json" ] && ! jq -e '.mcpServers.discord.env.DISCORD_STATE_DIR' "$d/.mcp.json" >/dev/null 2>&1; then
      jq_edit "$d/.mcp.json" '.mcpServers.discord.env = ((.mcpServers.discord.env // {}) + {DISCORD_STATE_DIR: "${DISCORD_STATE_DIR}"})'
      changed="$changed $d/.mcp.json"
    fi
  done
  [ -z "$changed" ] || echo "claude-discord: patched$changed"
  return "$rc"
}
if [ "${1:-}" = patch ]; then patch_official; exit $?; fi
```

In the launch path, delete lines 1140-1171 (the `install=$(jq ...)` block through the chunk patch) and put in their place:
```bash
# The official plugin must carry our patches before its server starts; a moved
# pattern is reported and the start goes on with whatever still applied.
patch_official >/dev/null || echo "claude-discord: some patches no longer apply (see above); the bot starts anyway" >&2
```

Update the existing assertions that expect `$HOME/.claude-discord/discord-proxy.ts` / `discord-chunk.ts` (suite ~545-580, 655) to the runtime path `$HOME/.claude-discord/runtime/...`, and point the suite's fake install at the cache layout: replace the `fakeplugin` setup (lines 58-60) so the fake plugin lives at `$HOME/.claude/plugins/cache/claude-plugins-official/discord/0.0.4/` and `$HOME/fakeplugin` is a symlink to it (assertions keep reading `$HOME/fakeplugin/server.ts`).

- [ ] **Step 4: Run the suite**

Run: `./test-claude-discord.sh ./bin/claude-discord 2>&1 | tail -2`
Expected: `ALL PASS`.

- [ ] **Step 5: Commit** (bump to `1.1.0`)

```bash
git commit -m "patch: one idempotent verb for every cached discord version, plus a per-bot .mcp.json env against the MCP failure cache" -- bin/claude-discord test-claude-discord.sh .claude-plugin/plugin.json
```

---

### Task 4: SessionStart injects the dev-manager rule, the tool path and re-patches

**Files:**
- Modify: `hooks/turn/on-session-start`
- Test: `test-claude-discord.sh` (block next to the on-session-start tests at ~330-350)

**Interfaces:**
- Consumes: `plugin_root`, `thread_tool` (Task 2), `claude-discord patch` (Task 3) via `$plugin_root/bin/claude-discord patch`.
- Produces: SessionStart JSON `{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"..."}}` for a dev-manager bot: the full `rules/dev-manager.md` plus one line `CLAUDE_DISCORD_TOOLS=<plugin_root>/tools`; for any other bot only that line; nothing without `DISCORD_STATE_DIR`.

- [ ] **Step 1: Write the failing test**

```bash
# SessionStart: a dev-manager bot gets the rule text and the tools path as
# context at every source; another mode only the tools path; a non-bot nothing.
echo dev-manager > "$DSD/mode"
for src in startup resume compact clear; do
  out=$(DISCORD_STATE_DIR="$DSD" bash "$H/on-session-start" <<<"{\"session_id\":\"sRule\",\"source\":\"$src\"}")
  ctx=$(jq -r '.hookSpecificOutput.additionalContext' <<<"$out") || { echo "FAIL: $src: not SessionStart JSON: $out"; exit 1; }
  grep -qF "$(head -1 "$D/rules/dev-manager.md")" <<<"$ctx" && grep -qF "CLAUDE_DISCORD_TOOLS=$D/tools" <<<"$ctx" ||
    { echo "FAIL: $src: a dev-manager bot needs the rule and the tools path: $ctx"; exit 1; }
done
echo none > "$DSD/mode"
ctx=$(DISCORD_STATE_DIR="$DSD" bash "$H/on-session-start" <<<'{"session_id":"sRule","source":"startup"}' | jq -r '.hookSpecificOutput.additionalContext')
[ "$ctx" = "CLAUDE_DISCORD_TOOLS=$D/tools" ] || { echo "FAIL: a plain bot gets only the tools path: $ctx"; exit 1; }
out=$(bash "$H/on-session-start" <<<'{"session_id":"sRule","source":"startup"}')
[ -z "$out" ] || { echo "FAIL: a non-bot session gets nothing: $out"; exit 1; }
echo "ok: SessionStart injects the dev-manager rule (dev-manager only) and the tools path, at every source"
```

(`$H` here must be the repo's `hooks/turn`, i.e. `H="$D/hooks/turn"` for this block, since tests no longer go through `~/.claude-discord/hooks`.)

- [ ] **Step 2: Run it** — Expected: FAIL (on-session-start prints nothing today).

- [ ] **Step 3: Implement** — in `hooks/turn/on-session-start`, after `read -r session_id source` and the `[ -n "$session_id" ] && [ -n "$bot_name" ] || exit 0` guard, BEFORE the `case $source` (whose compact|clear branch exits):

```bash
# The bot's standing context, at every source (a compaction or /clear drops
# it): where its tools are, and for a dev-manager bot the dev-manager rule.
# Context instead of a project rules file, so the project's other sessions do
# not read a bot's rules. The patch run covers a start that did not go through
# the wrapper (a daemon respawn, an auto-update since the last start).
"$plugin_root/bin/claude-discord" patch >/dev/null 2>&1 || :
ctx="CLAUDE_DISCORD_TOOLS=$plugin_root/tools"
[ "$bot_mode" != dev-manager ] || [ ! -f "$plugin_root/rules/dev-manager.md" ] ||
  ctx="$(cat "$plugin_root/rules/dev-manager.md")

$ctx"
jq -nc --arg c "$ctx" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $c}}' 2>/dev/null || :
```

The `patch` call must not print into the hook's stdout (redirected above) and must not fail the hook (`|| :`).

- [ ] **Step 4: Run the suite** — Expected: `ALL PASS`.

- [ ] **Step 5: Commit** (bump `1.2.0`)

```bash
git commit -m "on-session-start: inject the dev-manager rule and the tools path; re-patch the official plugin" -- hooks/turn/on-session-start test-claude-discord.sh .claude-plugin/plugin.json
```

---

### Task 5: The `~/.local/bin` shim

**Files:**
- Create: `shim/claude-discord`
- Test: `test-claude-discord.sh` (new block)

**Interfaces:**
- Produces: `shim/claude-discord`, installed by Task 6 as `~/.local/bin/claude-discord` (copied). Resolution: nearest ancestor of `$PWD` holding `.claude/skills/claude-discord/bin/claude-discord` or `.claude/discord-agents` → that project's clone if present; else `$HOME/.claude/skills/claude-discord/bin/claude-discord`; else exit 1 with the setup hint.

- [ ] **Step 1: Write the failing test**

```bash
# The shim runs the clone for the current project, else the global one.
SH="$D/shim/claude-discord"; SP="$HOME/shim test/proj"; mkdir -p "$SP/.claude/skills/claude-discord/bin" "$SP/sub"
printf '#!/bin/bash\necho project-copy "$@"\n' > "$SP/.claude/skills/claude-discord/bin/claude-discord"; chmod +x "$SP/.claude/skills/claude-discord/bin/claude-discord"
mkdir -p "$HOME/.claude/skills/claude-discord/bin"; printf '#!/bin/bash\necho global-copy "$@"\n' > "$HOME/.claude/skills/claude-discord/bin/claude-discord"; chmod +x "$HOME/.claude/skills/claude-discord/bin/claude-discord"
[ "$(cd "$SP/sub" && bash "$SH" --bg x)" = "project-copy --bg x" ] || { echo "FAIL: the shim must run the project's clone from a subdirectory"; exit 1; }
[ "$(cd "$HOME" && bash "$SH" health)" = "global-copy health" ] || { echo "FAIL: outside a project the shim runs the global clone"; exit 1; }
rm -rf "$HOME/.claude/skills/claude-discord"
out=$(cd "$HOME" && bash "$SH" 2>&1) && { echo "FAIL: with no clone the shim must fail"; exit 1; }
grep -q 'not set up' <<<"$out" || { echo "FAIL: the shim must say how to set up: $out"; exit 1; }
rm -rf "$HOME/shim test"
echo "ok: the shim runs the project's clone (path with a space, from a subdirectory), else the global one, else explains"
```

- [ ] **Step 2: Run it** — Expected: FAIL (`shim/claude-discord` missing).

- [ ] **Step 3: Implement** `shim/claude-discord` (mode 755):

```bash
#!/usr/bin/env bash
# ~/.local/bin/claude-discord: runs the claude-discord installed for the
# current project (<project>/.claude/skills/claude-discord), else the global
# one (~/.claude/skills/claude-discord). Copied there by `claude-discord setup`;
# kept tiny so it rarely needs replacing.
d=$PWD
while :; do
  if [ -x "$d/.claude/skills/claude-discord/bin/claude-discord" ]; then
    exec "$d/.claude/skills/claude-discord/bin/claude-discord" "$@"
  fi
  [ -d "$d/.claude/discord-agents" ] && break   # this project's root, with no project copy
  [ "$d" = / ] && break
  d=$(dirname "$d")
done
g=$HOME/.claude/skills/claude-discord/bin/claude-discord
[ -x "$g" ] && exec "$g" "$@"
echo "claude-discord: not set up here. Install it with:" >&2
echo "  git clone https://github.com/codeslake/claude-discord ~/.claude-discord/bootstrap && ~/.claude-discord/bootstrap/bin/claude-discord setup <bot>" >&2
exit 1
```

- [ ] **Step 4: Run it** — Expected: `ok: the shim runs ...`.

- [ ] **Step 5: Commit**

```bash
git add shim/claude-discord
git commit -m "shim: ~/.local/bin launcher that runs the project's clone, else the global one" -- shim/claude-discord test-claude-discord.sh
```

---

### Task 6: `setup` installs the plugin (`--scope project|global`)

**Files:**
- Modify: `bin/claude-discord` (setup block, lines 270-357)
- Test: `test-claude-discord.sh` (new block; the suite's first setup call at line 120 gets `--scope project` via stdin answer or flag)

**Interfaces:**
- Consumes: `CLAUDE_DISCORD_REPO` (default `https://github.com/codeslake/claude-discord`), `self_root`.
- Produces: `install_plugin <scope>` → clone at `$target` (`$PWD/.claude/skills/claude-discord` or `$HOME/.claude/skills/claude-discord`), `.git/info/exclude` entry, shim at `$HOME/.local/bin/claude-discord`, `$HOME/.claude-discord/records/installs` line, trust check. Setup flag `--scope project|global` (anywhere after the bot name); interactive default `project`.

- [ ] **Step 1: Write the failing tests**

```bash
# setup installs the plugin: a real clone (no link) at the chosen scope,
# excluded from the project's git, the shim on PATH, the install recorded;
# both scopes at once is refused; a re-run keeps the clone.
# A local stand-in for GitHub built from the WORKING TREE (a bare clone of $D
# would carry only committed HEAD, so a red-green cycle could not see the edit).
SRC="$HOME/src.git"; ST="$HOME/src-tree"; mkdir -p "$ST"
(cd "$D" && git ls-files -co --exclude-standard -z | xargs -0 -I{} cp --parents {} "$ST/")
(cd "$ST" && git init -q . && git add -A && git -c user.email=t@t -c user.name=t commit -qm stand-in) && git clone -q --bare "$ST" "$SRC" && rm -rf "$ST"
export CLAUDE_DISCORD_REPO=$SRC
SP="$HOME/scope proj"; mkdir -p "$SP"; (cd "$SP" && git init -q .)
jq -n --arg p "$SP" '{projects: {($p): {hasTrustDialogAccepted: true}}}' > "$HOME/.claude.json"
(cd "$SP" && printf '900\n111\n\ntokS\nn\n' | bash "$S" setup sbot --scope project >/dev/null) || { echo "FAIL: setup --scope project failed"; exit 1; }
[ -d "$SP/.claude/skills/claude-discord/.git" ] && [ ! -L "$SP/.claude/skills/claude-discord" ] || { echo "FAIL: project scope must be a real clone"; exit 1; }
grep -qxF '/.claude/skills/claude-discord/' "$SP/.git/info/exclude" || { echo "FAIL: the clone must be excluded from the project's git"; exit 1; }
cmp -s "$D/shim/claude-discord" "$HOME/.local/bin/claude-discord" || { echo "FAIL: setup must install the shim"; exit 1; }
grep -qxF "$SP/.claude/skills/claude-discord" "$HOME/.claude-discord/records/installs" || { echo "FAIL: setup must record the install"; exit 1; }
head=$(git -C "$SP/.claude/skills/claude-discord" rev-parse HEAD)
(cd "$SP" && printf '\nn\n' | bash "$S" setup sbot --scope project >/dev/null)
[ "$(git -C "$SP/.claude/skills/claude-discord" rev-parse HEAD)" = "$head" ] && [ "$(grep -c '/.claude/skills/claude-discord/' "$SP/.git/info/exclude")" = 1 ] || { echo "FAIL: a re-run must keep the clone and the single exclude line"; exit 1; }
mkdir -p "$HOME/.claude/skills/claude-discord"
out=$(cd "$SP" && printf '\nn\n' | bash "$S" setup sbot --scope project 2>&1) && { echo "FAIL: a global copy beside a project copy must be refused"; exit 1; }
grep -q "already installed globally" <<<"$out" || { echo "FAIL: wrong refusal: $out"; exit 1; }
rmdir "$HOME/.claude/skills/claude-discord"
jq -n '{projects: {}}' > "$HOME/.claude.json"
out=$(cd "$SP" && printf '\nn\n' | bash "$S" setup sbot --scope project 2>&1)
grep -q 'not trusted' <<<"$out" || { echo "FAIL: setup must say the project is not trusted: $out"; exit 1; }
[ "$(jq -r --arg p "$SP" '.projects[$p].hasTrustDialogAccepted // "unset"' "$HOME/.claude.json")" = unset ] || { echo "FAIL: setup must never write trust without asking"; exit 1; }
rm -rf "$SP"; unset CLAUDE_DISCORD_REPO
echo "ok: setup clones the plugin at project scope (path with a space), excludes it, installs the shim, records it, keeps it on re-run, refuses two scopes, and reports untrusted without writing"
```

The trust prompt reads one more line in a non-TTY run; with stdin exhausted it answers "no", so the assertion above holds.

- [ ] **Step 2: Run it** — Expected: FAIL (no `--scope`).

- [ ] **Step 3: Implement** — add before `if [ "${1:-}" = setup ]`:

```bash
# Installs the plugin by cloning this repo into the skills dir of the chosen
# scope: a real directory, never a link (a link makes ${CLAUDE_PLUGIN_ROOT}
# name the link and skips a .mcp.json outside the project; measured). A plugin
# in both scopes loads once with the global copy winning, so the other scope
# is refused. Re-running keeps an existing clone. Project scope loads only
# when ~/.claude.json trusts that exact path; setup asks before writing it.
install_plugin() {  # $1 = project|global
  local repo=${CLAUDE_DISCORD_REPO:-https://github.com/codeslake/claude-discord}
  local pdir=$PWD/.claude/skills/claude-discord gdir=$HOME/.claude/skills/claude-discord target other
  case $1 in project) target=$pdir other=$gdir;; global) target=$gdir other=$pdir;; esac
  if [ -e "$other" ]; then
    [ "$1" = project ] && echo "claude-discord: already installed globally at $other; remove it or use --scope global" >&2
    [ "$1" = global ] && echo "claude-discord: already installed for this project at $other; remove it or use --scope project" >&2
    return 2
  fi
  if [ ! -d "$target/.git" ]; then
    mkdir -p "$(dirname "$target")" && git clone -q "$repo" "$target" || { echo "claude-discord: could not clone $repo into $target" >&2; return 1; }
  fi
  if [ "$1" = project ] && [ -d "$PWD/.git" ]; then
    grep -qxF '/.claude/skills/claude-discord/' "$PWD/.git/info/exclude" 2>/dev/null ||
      printf '/.claude/skills/claude-discord/\n' >> "$PWD/.git/info/exclude"
  fi
  mkdir -p "$HOME/.local/bin" "$HOME/.claude-discord/records"
  cmp -s "$target/shim/claude-discord" "$HOME/.local/bin/claude-discord" ||
    install -m 755 "$target/shim/claude-discord" "$HOME/.local/bin/claude-discord"
  touch "$HOME/.claude-discord/records/installs"
  grep -qxF "$target" "$HOME/.claude-discord/records/installs" || printf '%s\n' "$target" >> "$HOME/.claude-discord/records/installs"
  if [ "$1" = project ] && [ "$(jq -r --arg p "$PWD" '.projects[$p].hasTrustDialogAccepted // false' "$HOME/.claude.json" 2>/dev/null)" != true ]; then
    echo "claude-discord: $PWD is not trusted in ~/.claude.json, so Claude Code will not load the plugin here." >&2
    read -rp "Mark this project trusted now? [y/N] " t || t=""
    case $t in y|Y) jq_edit "$HOME/.claude.json" --arg p "$PWD" '.projects[$p].hasTrustDialogAccepted = true';; esac
  fi
}
```

In the setup block: parse `--scope` out of `$3..$@` before the existing `${3:-}` checks (keep `--reset`/`--mode` working in any position):
```bash
  scope="" rest=()
  for a in "${@:3}"; do
    case $a in --scope=*) scope=${a#--scope=};; --scope) scope=__next;; *) [ "$scope" = __next ] && scope=$a || rest+=("$a");; esac
  done
  set -- "$1" "$2" ${rest[@]+"${rest[@]}"}
```
and, after the mode prompt (before `ensure_hooks_symlink`):
```bash
  if [ -z "$scope" ]; then
    scope=$(select_one Scope project "project  this project only (.claude/skills/claude-discord)" "global  every project (~/.claude/skills/claude-discord)")
  fi
  install_plugin "$scope" || exit $?
```
Near the top of the suite, mark the main project trusted so no setup asks: `jq -n --arg p "$P" '{projects: {($p): {hasTrustDialogAccepted: true}}}' > "$HOME/.claude.json"` (right after `P=` is set). The suite's earlier setup calls feed answers on stdin; add `--scope project` to each existing `setup` invocation in the suite (`grep -n 'setup ' test-claude-discord.sh`), with `CLAUDE_DISCORD_REPO` set once near the top to the bare stand-in so no call reaches the network.

- [ ] **Step 4: Run the suite** — Expected: `ALL PASS`.

- [ ] **Step 5: Commit** (bump `1.3.0`)

```bash
git commit -m "setup: install the plugin by git clone at project or global scope, with the shim and the install record" -- bin/claude-discord test-claude-discord.sh .claude-plugin/plugin.json
```

---

### Task 7: Migration cleanup (old hooks, rule file, old install)

**Files:**
- Modify: `bin/claude-discord` (`register_hooks` → `remove_old_hooks`; `sync_mode_drops`; `ensure_hooks_symlink`; new `remove_old_install`)
- Delete: `install.sh`
- Test: `test-claude-discord.sh` (replace the `has_hooks`/`mode_peers` assertions with "no entry left"; replace the install.sh block ~2446-2464)

**Interfaces:**
- Produces: after `setup` or a start, no settings entry whose command contains `/.claude/discord-agents/hooks/`; no `.claude/rules/claude-discord-*.md`; `~/.claude-discord/hooks/` reduced to the one compat link `hooks/tools/thread -> <clone>/tools/thread`; `~/.claude-discord/{rules,discord-chunk.ts,discord-proxy.ts}` gone; `scratch/`, `records/`, `runtime/` untouched.

- [ ] **Step 1: Write the failing test**

```bash
# A machine with the old install: setup leaves one plugin copy and nothing of
# the old registration, keeps bots' scratch, and leaves the compat link.
OP="$HOME/old proj"; mkdir -p "$OP/.claude/rules" "$OP/.claude/discord-agents" "$HOME/.claude-discord/scratch/b" "$HOME/.claude-discord/hooks/turn" "$HOME/.claude-discord/rules"
(cd "$OP" && git init -q .)
: > "$HOME/.claude-discord/scratch/b/note"; : > "$HOME/.claude-discord/hooks/turn/on-prompt"; : > "$HOME/.claude-discord/rules/dev-manager.md"; : > "$HOME/.claude-discord/discord-chunk.ts"
: > "$OP/.claude/rules/claude-discord-dev-manager.md"
printf '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":%s}]},{"hooks":[{"type":"command","command":"other"}]}]}}\n' "$(jq -Rn --arg c "$CMD_PROMPT" '$c')" > "$OP/.claude/settings.local.json"
cp "$OP/.claude/settings.local.json" "$OP/.claude/settings.json"
jq -n --arg p "$OP" '{projects: {($p): {hasTrustDialogAccepted: true}}}' > "$HOME/.claude.json"
(cd "$OP" && printf '900\n111\n\ntokO\nn\ndev-manager\n\n' | CLAUDE_DISCORD_REPO=$SRC bash "$S" setup obot --scope project >/dev/null)
for f in settings.json settings.local.json; do
  ! grep -q '/.claude/discord-agents/hooks/' "$OP/.claude/$f" && grep -q '"other"' "$OP/.claude/$f" || { echo "FAIL: $f must lose our entries and keep others"; exit 1; }
done
[ ! -e "$OP/.claude/rules/claude-discord-dev-manager.md" ] || { echo "FAIL: the old rule file must go"; exit 1; }
[ ! -e "$HOME/.claude-discord/rules" ] && [ ! -e "$HOME/.claude-discord/discord-chunk.ts" ] && [ ! -e "$HOME/.claude-discord/hooks/turn" ] || { echo "FAIL: the old install must go"; exit 1; }
[ -e "$HOME/.claude-discord/scratch/b/note" ] || { echo "FAIL: scratch must stay"; exit 1; }
[ "$(readlink "$HOME/.claude-discord/hooks/tools/thread")" = "$OP/.claude/skills/claude-discord/tools/thread" ] || { echo "FAIL: the compat thread link must point at the clone"; exit 1; }
rm -rf "$OP"
echo "ok: setup on an old install removes our settings entries (keeping others), the rule file and the old copies, keeps scratch, and leaves the compat thread link"
```

- [ ] **Step 2: Run it** — Expected: FAIL.

- [ ] **Step 3: Implement**

Replace the registration with removal by reusing `register_hooks`' proven filter: it already strips every entry of ours that `$want` does not hold (that is how `settings.json` is handled today), so an empty `$want` for BOTH files removes them all and nothing else. Give `register_hooks` a second argument and use it:
```bash
register_hooks() {  # $1 = the project's bot modes; $2 = "none": register nothing, remove every entry of ours
```
and inside the jq call add `--arg none "${2:-}"` and change the first line of the filter to
`(if $file == "settings.local.json" and $none != "none" then $all else [] end) as $want`. Then:
```bash
# The plugin's hooks.json registers every hook now; entries earlier versions
# wrote into the project's settings files would run each hook twice. Settings
# hooks apply live (measured), so a running bot drops them at once and picks
# up the plugin's on /reload-plugins.
remove_old_hooks() { register_hooks "" none; }
```
The existing stale-removal tests stay valid; the `has_hooks` assertions flip to "no entry of ours" (`! grep -q /.claude/discord-agents/hooks/ <file>`).

In `sync_mode_drops`, drop the rule-file copy (`keep`, `src`, the `cat` block); keep only the removal loop with `keep=""` (removes every `claude-discord-*.md`) and replace `register_hooks "$modes"` with `remove_old_hooks`.

`ensure_hooks_symlink`: keep this release (old peers' committed settings may point at it) but point the link at the clone's hooks: `ln -sfn "$self_root/hooks" "$link"`.

Add and call (from setup, after `install_plugin`):
```bash
# What install.sh used to put under ~/.claude-discord goes; scratch/, records/
# and runtime/ stay. tools/thread keeps a compat link for one release, so a
# session started by the old wrapper still finds the tool its prompt names.
remove_old_install() {
  local h=$HOME/.claude-discord
  rm -rf "$h/rules" "$h/hooks/turn" "$h/hooks/peers" "$h/hooks/lib" "$h/hooks/autoresearchclaw"
  rm -f "$h/discord-chunk.ts" "$h/discord-proxy.ts" "$h/hooks/tools/local-bots"
  mkdir -p "$h/hooks/tools" && ln -sfn "$self_root/tools/thread" "$h/hooks/tools/thread"
}
```
`install_plugin` leaves the clone path in the global `plugin_target` (add `plugin_target=$target` at its end). In setup, right after `install_plugin "$scope" || exit $?`:
```bash
  self_root=$plugin_target   # from here on, everything points at the real install
  remove_old_install
  # A first install runs from the bootstrap clone; it is not needed any more.
  case $0 in "$HOME/.claude-discord/bootstrap/"*) rm -rf "$HOME/.claude-discord/bootstrap";; esac
```
and extend the Step 1 test with: a bootstrap clone at `$HOME/.claude-discord/bootstrap` running setup is gone afterwards (run setup as `bash "$HOME/.claude-discord/bootstrap/bin/claude-discord" setup ...` after `git clone -q "$SRC" "$HOME/.claude-discord/bootstrap"`, then assert `[ ! -e "$HOME/.claude-discord/bootstrap" ]`).

Delete `install.sh` (`git rm install.sh`) and its `bash -n` line and test block in the suite.

- [ ] **Step 4: Run the suite** — Expected: `ALL PASS`.

- [ ] **Step 5: Commit** (bump `1.4.0`)

```bash
git commit -m "setup: remove the old settings hooks, rule file and install.sh copies; keep a compat thread link" -- bin/claude-discord test-claude-discord.sh install.sh .claude-plugin/plugin.json
```

---

### Task 8: CLI `--name`, `--resume` bot resolution, live-resume refusal, deprecation

**Files:**
- Modify: `bin/claude-discord` (launch arg parsing, lines 1104-1128; `--resume` block ~1229-1266)
- Test: `test-claude-discord.sh`

**Interfaces:**
- Consumes: job records `$HOME/.claude/jobs/*/state.json` (`respawnFlags`, `sessionId`, `resumeSessionId`), `claude agents --json`.
- Produces: `--name X`/`-n X`/`--name=X` set the bot; a positional name prints `claude-discord: 'claude-discord <bot> ...' is deprecated; use 'claude-discord --name <bot> ...'` on stderr and still works; `--resume <id>` with no name resolves the bot from the job whose `sessionId` or `resumeSessionId` starts with the id and whose `respawnFlags` name `DISCORD_STATE_DIR\": \"$root/<bot>\"`; a live match (`claude agents` row with that sessionId and state not stopped/done) is refused.

- [ ] **Step 1: Write the failing tests**

```bash
out=$(bash "$S" --name alpha 2>&1)
grep -q -- '-n alpha' <<<"$out" && ! grep -q deprecated <<<"$out" || { echo "FAIL: --name alpha must start bot alpha silently: $out"; exit 1; }
out=$(bash "$S" alpha 2>&1)
grep -q -- '-n alpha' <<<"$out" && grep -q "deprecated; use 'claude-discord --name alpha" <<<"$out" || { echo "FAIL: the positional form must work and warn: $out"; exit 1; }
# --resume with no name: the bot comes from the job record
mkdir -p "$HOME/.claude/jobs/j1"
jq -n --arg s "{\"env\": {\"DISCORD_STATE_DIR\": \"$R/alpha\"}}" '{sessionId: "aaaaaaaa-1111-2222-3333-444444444444", respawnFlags: ["--settings", $s]}' > "$HOME/.claude/jobs/j1/state.json"
printf '#!/bin/bash\ncase $1 in agents) echo "[]";; *) echo "PLAIN $*";; esac\n' > "$HOME/bin/claude"
out=$(CLAUDE_DISCORD_LAUNCHER= bash "$S" --bg --resume aaaaaaaa-1111-2222-3333-444444444444 2>&1)
grep -q -- '-n alpha' <<<"$out" || { echo "FAIL: --resume must find bot alpha from the job record: $out"; exit 1; }
# a live session is not resumed twice
printf '#!/bin/bash\ncase $1 in agents) echo %s;; *) echo "PLAIN $*";; esac\n' "'[{\"sessionId\":\"aaaaaaaa-1111-2222-3333-444444444444\",\"state\":\"working\",\"cwd\":\"$P\"}]'" > "$HOME/bin/claude"
out=$(CLAUDE_DISCORD_LAUNCHER= bash "$S" --bg --resume aaaaaaaa-1111-2222-3333-444444444444 2>&1) && { echo "FAIL: resuming a live session must be refused"; exit 1; }
grep -q 'refresh alpha' <<<"$out" && ! grep -q PLAIN <<<"$out" || { echo "FAIL: the refusal must point at refresh and start nothing: $out"; exit 1; }
rm -rf "$HOME/.claude/jobs/j1"; printf '#!/bin/bash\necho "PLAIN $*"\n' > "$HOME/bin/claude"
echo "ok: --name names the bot, the positional form warns, --resume finds the bot from its job record and refuses a live session"
```

- [ ] **Step 2: Run it** — Expected: FAIL (`--name` refused today).

- [ ] **Step 3: Implement** — in the launch parsing loop (line 1105-1115) replace the `-n|--name|--name=*)` refusal with:
```bash
    -n|--name) want_name=1;;
    --name=*) name=${a#--name=}; named=1;;
```
and at the loop top: `if [ "${want_name:-0}" = 1 ]; then name=$a; named=1; want_name=0; continue; fi`; in the bare-word branch, when it sets `name`, set `positional=1`. After the loop:
```bash
[ "${positional:-0}" = 1 ] && [ "${named:-0}" != 1 ] &&
  echo "claude-discord: 'claude-discord $name ...' is deprecated; use 'claude-discord --name $name ...'" >&2
```
Before the `if [ -z "$name" ]` single-bot fallback, resolve from `--resume`:
```bash
# --resume <id> with no name: the bot is the one whose job record carries its
# DISCORD_STATE_DIR (every launch passes it in --settings; the daemon keeps it).
rid=""
for i in "${!args[@]}"; do case ${args[i]} in --resume|-r) rid=${args[i+1]:-};; --resume=*) rid=${args[i]#--resume=};; esac; done
if [ -z "$name" ] && [ -n "$rid" ]; then
  for f in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/jobs/*/state.json; do
    jq -e --arg r "$rid" '((.sessionId // "") | startswith($r)) or ((.resumeSessionId // "") | startswith($r))' "$f" >/dev/null 2>&1 || continue
    # The raw file, as refresh reads it: inside state.json the --settings value
    # is a JSON string, so its quotes appear escaped as \".
    for d in "$root"/*/; do
      d=${d%/}
      grep -qF -- "DISCORD_STATE_DIR\\\": \\\"$d\\\"" "$f" && { name=${d##*/}; break 2; }
    done
  done
fi
```
After `resume_id` is computed (line ~1266), refuse a live one:
```bash
if [ -n "$resume_id" ] && agents=$("$bin" agents --json 2>/dev/null) &&
   printf '%s' "$agents" | jq -e --arg s "$resume_id" 'type == "array" and any(.[]; (.sessionId // "") == $s and ((.state // "") | IN("stopped","done") | not))' >/dev/null 2>&1; then
  echo "claude-discord: session $resume_id is running; use 'claude-discord refresh $name' to replace it" >&2
  exit 2
fi
```
(The `$bin` lookup at line 1278 must move above this check.) Keep `refresh` refusing `--name` (its own parser, lines ~941-952) unchanged, but change its relaunch (line 1095) from `"$self" --bg "$name" ...` to `"$self" --bg --name "$name" ...`, or every refresh prints the deprecation line; the refresh tests that grep the launch line (`-n alpha`) still pass.

- [ ] **Step 4: Run the suite** — Expected: `ALL PASS`.

- [ ] **Step 5: Commit** (bump `1.5.0`)

```bash
git commit -m "cli: --name names the bot, --resume finds it from the job record and refuses a live session; positional form deprecated" -- bin/claude-discord test-claude-discord.sh .claude-plugin/plugin.json
```

---

### Task 9: `update`, `--version`, README

**Files:**
- Modify: `bin/claude-discord` (verbs `update`, `--version`)
- Modify: `README.md` (Install, Usage, Hooks, Troubleshooting; bootstrap one-liner; migration steps)
- Test: `test-claude-discord.sh`

**Interfaces:**
- Consumes: `records/installs`, `patch_official`.
- Produces: `claude-discord update [--all]` → `git pull --ff-only` in the resolved clone (or every recorded one), patch, shim refresh, prints `claude-discord <old> -> <new>` and `run /reload-plugins in running sessions`; `claude-discord --version` → `claude-discord <version> (<short sha>)`.

- [ ] **Step 1: Write the failing tests**

```bash
UP="$HOME/up proj"; mkdir -p "$UP"; (cd "$UP" && git init -q .)
jq -n --arg p "$UP" '{projects: {($p): {hasTrustDialogAccepted: true}}}' > "$HOME/.claude.json"
(cd "$UP" && printf '900\n111\n\ntokU\nn\n' | CLAUDE_DISCORD_REPO=$SRC bash "$S" setup ubot --scope project >/dev/null)
C="$UP/.claude/skills/claude-discord"
v=$(cd "$UP" && bash "$C/bin/claude-discord" --version)
grep -qE '^claude-discord [0-9]+\.[0-9]+\.[0-9]+ \([0-9a-f]{7,}\)$' <<<"$v" || { echo "FAIL: --version: $v"; exit 1; }
W="$HOME/work"; git clone -q "$SRC" "$W"; jq '.version = "9.9.9"' "$W/.claude-plugin/plugin.json" > "$W/p" && mv "$W/p" "$W/.claude-plugin/plugin.json"
git -C "$W" -c user.email=t@t -c user.name=t commit -qam bump && git -C "$W" push -q origin HEAD
out=$(cd "$UP" && bash "$C/bin/claude-discord" update 2>&1)
grep -q -- '-> 9.9.9' <<<"$out" && grep -q '/reload-plugins' <<<"$out" || { echo "FAIL: update must pull and report the new version: $out"; exit 1; }
rm -rf "$UP" "$W"
echo "ok: --version prints version and sha; update pulls, reports old -> new and asks for /reload-plugins"
```

- [ ] **Step 2: Run it** — Expected: FAIL.

- [ ] **Step 3: Implement** — next to the `patch` verb:
```bash
plugin_version() { jq -r '.version // "?"' "$1/.claude-plugin/plugin.json" 2>/dev/null || echo "?"; }
if [ "${1:-}" = --version ]; then
  echo "claude-discord $(plugin_version "$self_root") ($(git -C "$self_root" rev-parse --short HEAD 2>/dev/null || echo nogit))"; exit 0
fi
# update: fast-forward the clone this command runs from (or every recorded one
# with --all), then re-patch and refresh the shim. Running sessions keep the
# code they loaded until /reload-plugins.
if [ "${1:-}" = update ]; then
  clones=("$self_root")
  [ "${2:-}" = --all ] && { clones=(); while IFS= read -r c; do [ -d "$c/.git" ] && clones+=("$c"); done < "$HOME/.claude-discord/records/installs"; }
  rc=0
  for c in "${clones[@]}"; do
    old=$(plugin_version "$c")
    git -C "$c" pull -q --ff-only || { echo "claude-discord: $c: pull failed (local changes or diverged)" >&2; rc=1; continue; }
    echo "claude-discord $c: $old -> $(plugin_version "$c")"
  done
  self_root=${clones[0]} patch_official || rc=1
  cmp -s "$self_root/shim/claude-discord" "$HOME/.local/bin/claude-discord" || install -m 755 "$self_root/shim/claude-discord" "$HOME/.local/bin/claude-discord"
  echo "claude-discord: run /reload-plugins in running sessions (a bot: the self-reload skill)"
  exit "$rc"
fi
```
Prune dead lines of `records/installs` in `install_plugin` (rewrite the file with only existing paths).

README: replace "Install" with the bootstrap one-liner and the `--scope` choice; replace every `~/.claude-discord/hooks/tools/...` with `$CLAUDE_DISCORD_TOOLS/...` (the context line); document `update`, `--version`, `patch`, the shim, the migration (setup, then `/reload-plugins` in each bot), and that install.sh is gone (rollback: check out the previous tag and run its `install.sh`).

- [ ] **Step 3b: Plugin load check outside the budget** (issue #1 C1 Q1). Create `scripts/validate-plugin.sh`:
```bash
#!/usr/bin/env bash
# Loads the repo as a plugin with the real claude, outside the 40 s stub suite.
set -euo pipefail
cd "$(dirname "$0")/.."
if claude plugin --help 2>/dev/null | grep -q validate; then
  claude plugin validate .
else
  echo "this claude has no 'plugin validate'; check by hand: a trusted project with this repo at .claude/skills/claude-discord lists claude-discord in /plugin" >&2
  exit 2
fi
```
Run it once and paste the result into the commit message.

- [ ] **Step 4: Run the suite, quiet** — `uptime` first (load < 4), then `time ./test-claude-discord.sh ./bin/claude-discord`
Expected: `ALL PASS`, real < 40 s.

- [ ] **Step 5: Commit** (bump `1.6.0`)

```bash
git add scripts/validate-plugin.sh
git commit -m "update and --version; README for the plugin install; plugin load check script" -- bin/claude-discord README.md test-claude-discord.sh .claude-plugin/plugin.json scripts/validate-plugin.sh
```

---

### Task 10: Live check on lmd42, review, merge, rollout

Not code. Each step ends on its proof.

- [ ] **Step 1:** Push the branch, post the diff summary in Discord thread 1557486992835608699 to dong-dev-bot, close every review finding (re-review each fix commit) before main.
- [ ] **Step 2:** On lmd42, with one non-critical bot: run `setup <bot> --scope project` from the branch, then `/reload-plugins` in that bot (self-reload skill). Proof: `jq` shows no `/.claude/discord-agents/hooks/` entry in either settings file; one mention to the bot gets an answer and ✅; `claude-discord --version` prints the branch version.
- [ ] **Step 3:** Merge to main (fast-forward), then migrate the rest on lmd42, wmac, pmac by the same two steps; tell each local bot session what changed (rule: the wrapper's behaviour and the rule text changed).
- [ ] **Step 4:** Ask dong-dev-bot to do the same on lmd79 and dongyong22's wmac.
- [ ] **Step 5:** Close the issue #1 sub-project 1 item with the version and the machines it landed on.
