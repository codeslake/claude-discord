#!/usr/bin/env bash
# The install half of the acceptance suite: patch, setup on an old install, compat, setup --mode and scopes, install and
# update. Same sandbox, stubs and first setup as test-claude-discord.sh (tests/suite-lib.sh). Usage: test-install.sh <script>
. "$(dirname "$0")/tests/suite-lib.sh"

# from the core file: the starts before this block had patched 0.0.4 (the fake plugin), so patch has nothing to report there.
bash "$S" --name alpha >/dev/null 2>&1 || { echo "FAIL: fixture: a start must patch the fake plugin"; exit 1; }
# patch: every discord version dir in the cache, idempotent, the .mcp.json env
# line for the failure cache, a moved pattern reported with exit 1. 0.0.4 is the
# fake plugin above, already patched by the starts; 0.0.5 and 0.0.6 are clean.
PCACHE="$HOME/.claude/plugins/cache/claude-plugins-official/discord"
for v in 0.0.5 0.0.6; do
  mkdir -p "$PCACHE/$v"
  cp "$HOME/server.ts.pristine" "$PCACHE/$v/server.ts"
  printf '{"mcpServers":{"discord":{"command":"bun","args":["run","--cwd","${CLAUDE_PLUGIN_ROOT}","start"]}}}\n' > "$PCACHE/$v/.mcp.json"
done
out=$(bash "$S" patch 2>&1) || { echo "FAIL: patch on clean and patched version dirs must exit 0: $out"; exit 1; }
for v in 0.0.5 0.0.6; do
  grep -q 'msg.author.id === client.user?.id' "$PCACHE/$v/server.ts" &&
  grep -q 'ignoreEveryone: true' "$PCACHE/$v/server.ts" &&
  grep -qF "(await import(\"$HOME/.claude-discord/runtime/discord-chunk.ts\")).chunk(text, limit, mode)" "$PCACHE/$v/server.ts" &&
  grep -qF "$HOME/.claude-discord/runtime/discord-proxy.ts" "$PCACHE/$v/bunfig.toml" &&
  [ "$(jq -c '.mcpServers.discord.env' "$PCACHE/$v/.mcp.json")" = '{"CLAUDE_DISCORD_BOT":"${DISCORD_STATE_DIR:-}"}' ] &&
  grep -qF "$PCACHE/$v/server.ts" <<<"$out" ||
  { echo "FAIL: patch must apply all five patches to $v and name its files: $out"; exit 1; }
done
! grep -qF "$PCACHE/0.0.4" <<<"$out" || { echo "FAIL: the already patched 0.0.4 must not be reported as changed: $out"; exit 1; }
out=$(bash "$S" patch 2>&1) && [ -z "$out" ] || { echo "FAIL: a second patch run must be silent and exit 0: $out"; exit 1; }
[ -f "$HOME/.claude-discord/runtime/discord-chunk.ts" ] && [ -f "$HOME/.claude-discord/runtime/discord-proxy.ts" ] || { echo "FAIL: patch must keep the runtime copy"; exit 1; }
# A .mcp.json an earlier release patched carries DISCORD_STATE_DIR: "${DISCORD_STATE_DIR}", which masks the
# server's own default for a user without claude-discord: it goes, our key comes, any other env key stays; once.
jq '.mcpServers.discord.env = {DISCORD_STATE_DIR: "${DISCORD_STATE_DIR}", KEEP: "1"}' "$PCACHE/0.0.5/.mcp.json" > "$HOME/m.tmp" && mv "$HOME/m.tmp" "$PCACHE/0.0.5/.mcp.json"
out=$(bash "$S" patch 2>&1) && [ "$(jq -c '.mcpServers.discord.env' "$PCACHE/0.0.5/.mcp.json")" = '{"KEEP":"1","CLAUDE_DISCORD_BOT":"${DISCORD_STATE_DIR:-}"}' ] && grep -qF "$PCACHE/0.0.5/.mcp.json" <<<"$out" || { echo "FAIL: patch must replace an earlier DISCORD_STATE_DIR env line by CLAUDE_DISCORD_BOT and keep other keys: $out $(<"$PCACHE/0.0.5/.mcp.json")"; exit 1; }
out=$(bash "$S" patch 2>&1) && [ -z "$out" ] || { echo "FAIL: the .mcp.json rewrite must be idempotent: $out"; exit 1; }
# runtime/VERSION: an older wrapper leaves a newer runtime and the cache alone, says so once, exits 0.
[ "$(<"$HOME/.claude-discord/runtime/VERSION")" = "$(jq -r .version "$PC/.claude-plugin/plugin.json")" ] || { echo "FAIL: patch must stamp runtime/VERSION with its plugin version"; exit 1; }
cp "$HOME/.claude-discord/runtime/VERSION" "$HOME/rtv.before"; echo 99.0.0 > "$HOME/.claude-discord/runtime/VERSION"
echo stale > "$HOME/.claude-discord/runtime/discord-chunk.ts"; cp "$HOME/server.ts.pristine" "$PCACHE/0.0.5/server.ts"
rc=0; out=$(bash "$S" patch 2>&1) || rc=$?
[ "$rc" = 0 ] && [ "$(grep -c 'newer than this' <<<"$out")" = 1 ] && [ "$(<"$HOME/.claude-discord/runtime/discord-chunk.ts")" = stale ] && cmp -s "$HOME/server.ts.pristine" "$PCACHE/0.0.5/server.ts" || { echo "FAIL: an older patch must leave a newer runtime and the cache alone and say so once (rc=$rc): $out"; exit 1; }
cp "$HOME/rtv.before" "$HOME/.claude-discord/runtime/VERSION"; mv "$HOME/rtv.before" "$HOME/rtv.ref"
bash "$S" patch >/dev/null 2>&1 && cmp -s "$PC/runtime/discord-chunk.ts" "$HOME/.claude-discord/runtime/discord-chunk.ts" && grep -q 'ignoreEveryone: true' "$PCACHE/0.0.5/server.ts" || { echo "FAIL: the same version must refill the runtime and patch again"; exit 1; }
for junk in junk 1.9.0.1 1.08.0; do   # garbled, four parts, a leading zero (not octal; 1.8.0 is older)
  echo "$junk" > "$HOME/.claude-discord/runtime/VERSION"; echo stale > "$HOME/.claude-discord/runtime/discord-chunk.ts"
  bash "$S" patch >/dev/null 2>&1 && cmp -s "$PC/runtime/discord-chunk.ts" "$HOME/.claude-discord/runtime/discord-chunk.ts" && cmp -s "$HOME/rtv.ref" "$HOME/.claude-discord/runtime/VERSION" || { echo "FAIL: runtime/VERSION '$junk' must not lock the runtime or crash patch: it is refilled and restamped"; exit 1; }
done
rm -f "$HOME/rtv.ref"
# A dir the previous release patched imports the chunk helper and preloads the proxy from the old compat paths; patch re-points both to runtime/, once.
perl -pi -e 's{import\("[^"]*"\)}{import("$ENV{HOME}/.claude-discord/discord-chunk.ts")}' "$PCACHE/0.0.6/server.ts"
printf 'preload = ["%s/.claude-discord/discord-proxy.ts"]\n' "$HOME" > "$PCACHE/0.0.6/bunfig.toml"
grep -qF "$HOME/.claude-discord/discord-chunk.ts" "$PCACHE/0.0.6/server.ts" || { echo "FAIL: the old-path fixture was not planted"; exit 1; }
out=$(bash "$S" patch 2>&1) || { echo "FAIL: patch over an old-path import must exit 0: $out"; exit 1; }
grep -qF "(await import(\"$HOME/.claude-discord/runtime/discord-chunk.ts\")).chunk(text, limit, mode)" "$PCACHE/0.0.6/server.ts" && ! grep -qF "$HOME/.claude-discord/discord-chunk.ts" "$PCACHE/0.0.6/server.ts" &&
  [ "$(<"$PCACHE/0.0.6/bunfig.toml")" = "preload = [\"$HOME/.claude-discord/runtime/discord-proxy.ts\"]" ] &&
  grep -qF "$PCACHE/0.0.6/server.ts" <<<"$out" && grep -qF "$PCACHE/0.0.6/bunfig.toml" <<<"$out" || { echo "FAIL: patch must re-point an old chunk import and proxy preload to runtime/: $out"; exit 1; }
out=$(bash "$S" patch 2>&1) && [ -z "$out" ] || { echo "FAIL: a second patch after the rewrite must change nothing: $out"; exit 1; }
echo "ok: patch rewrites a chunk import and a proxy preload left at the old paths to runtime/, and a second run is silent"

# A server.ts 1.9.3 patched (its guard line in, its login giving up on a refused token): only the login is replaced, once.
# So is the login of one patched by 1.9.4 to 1.13.x (0.0.2), which waited out a refused token only at the login.
OLD193='new Promise<string>(ok => { if (TOKEN) return ok(TOKEN); const t = setInterval(() => { let m; try { m = readFileSync(ENV_FILE, "utf8").match(/^DISCORD_BOT_TOKEN=(.+)$/m) } catch {} if (m?.[1].trim()) { clearInterval(t); ok(m[1].trim()) } }, 10000) }).then(t => client.login(t)).catch('
mkdir -p "$PCACHE/0.0.3"
CD_OLD=$OLD193 perl -0777 -pe 's/^  process\.exit\(1\)\n\}\n/  process.stderr.write("discord channel: no token yet; waiting for it (re-read every 10 s)\\n")\n}\n/m; s/^client\.login\(TOKEN\)\.catch\(/$ENV{CD_OLD}/m' "$HOME/server.ts.pristine" > "$PCACHE/0.0.3/server.ts"
grep -qF "$OLD193" "$PCACHE/0.0.3/server.ts" && [ "$(grep -c 'process.exit(1)' "$PCACHE/0.0.3/server.ts")" = 1 ] || { echo "FAIL: the 1.9.3-patched fixture was not planted: $(<"$PCACHE/0.0.3/server.ts")"; exit 1; }
OLD194=';(async () => { let bad = ""; const read = () => { let m; try { m = readFileSync(ENV_FILE, "utf8").match(/^DISCORD_BOT_TOKEN=(.+)$/m) } catch {} return m?.[1].trim() || "" }; const pick = () => { const v = bad ? read() : (TOKEN || read()); return v && v !== bad ? v : "" }; for (;;) { const t = await new Promise<string>(ok => { const v = pick(); if (v) return ok(v); const i = setInterval(() => { const w = pick(); if (w) { clearInterval(i); ok(w) } }, 10000) }); try { return await client.login(t) } catch (e) { if ((e as any)?.code !== "TokenInvalid") throw e; bad = t; process.stderr.write("discord channel: the token was refused; waiting for a new one in .env (re-read every 10 s)\n") } } })().catch('
mkdir -p "$PCACHE/0.0.2"
CD_OLD=$OLD194 perl -0777 -pe 's/^  process\.exit\(1\)\n\}\n/  process.stderr.write("discord channel: no token yet; waiting for it (re-read every 10 s)\\n")\n}\n/m; s/^client\.login\(TOKEN\)\.catch\(/$ENV{CD_OLD}/m' "$HOME/server.ts.pristine" > "$PCACHE/0.0.2/server.ts"
out=$(bash "$S" patch 2>&1) && grep -qF "$PCACHE/0.0.3/server.ts" <<<"$out" && ! grep -qF '.then(t => client.login(t))' "$PCACHE/0.0.3/server.ts" &&
  [ "$(grep -c 'code !== "TokenInvalid"' "$PCACHE/0.0.3/server.ts")" = 1 ] && grep -qF '})().catch(err => {' "$PCACHE/0.0.3/server.ts" &&
  [ "$(grep -c 'no token yet; waiting for it' "$PCACHE/0.0.3/server.ts")" = 1 ] && [ "$(grep -c 'process.exit(1)' "$PCACHE/0.0.3/server.ts")" = 1 ] || { echo "FAIL: patch must upgrade a 1.9.3 login to the refused-token loop: $out $(<"$PCACHE/0.0.3/server.ts")"; exit 1; }
grep -qF "$PCACHE/0.0.2/server.ts" <<<"$out" && ! grep -qF 'return await client.login(t)' "$PCACHE/0.0.2/server.ts" && [ "$(grep -c 'client.on("shardDisconnect", f)' "$PCACHE/0.0.2/server.ts")" = 1 ] &&
  [ "$(grep -c 'code !== "TokenInvalid"' "$PCACHE/0.0.2/server.ts")" = 1 ] && grep -qF '})().catch(err => {' "$PCACHE/0.0.2/server.ts" || { echo "FAIL: patch must upgrade a 1.9.4 login to the one that waits out a 4004 too: $out $(<"$PCACHE/0.0.2/server.ts")"; exit 1; }
out=$(bash "$S" patch 2>&1) && [ -z "$out" ] || { echo "FAIL: a second patch after the 1.9.3 and 1.9.4 upgrades must change nothing: $out"; exit 1; }
rm -rf "$PCACHE/0.0.3" "$PCACHE/0.0.2"
echo "ok: patch upgrades a server.ts 1.9.3 patched to wait out a refused token, and one 1.9.4 to 1.13.x patched to wait out a 4004 after the login too; a second run is silent"
# A moved pattern: exit 1 naming file and patch, the other patches still applied.
mkdir -p "$PCACHE/0.0.7"
printf 'client.on(x, msg => {\n  if (msg.author.isBot()) return\n})\nif (!TOKEN) {\n  process.exit(1)\n}\nclient.connect(TOKEN).catch(err => {})\n' > "$PCACHE/0.0.7/server.ts"
printf '{"mcpServers":{"discord":{"command":"bun"}}}\n' > "$PCACHE/0.0.7/.mcp.json"
out=$(bash "$S" patch 2>&1) && { echo "FAIL: a pattern that no longer matches must exit 1"; exit 1; }
grep -q 'patch: .*0.0.7/server.ts: bot-authors no longer matches' <<<"$out" || { echo "FAIL: wrong no-match report: $out"; exit 1; }
# One late-token anchor without the other (the login moved): reported, and the exit left in place.
grep -q 'patch: .*0.0.7/server.ts: late-token no longer matches' <<<"$out" && grep -q '^  process.exit(1)$' "$PCACHE/0.0.7/server.ts" || { echo "FAIL: a moved login must leave the no-token exit alone and be reported: $out"; exit 1; }
! grep -q '0.0.[456]/server.ts: ' <<<"$out" || { echo "FAIL: only the moved dir may be reported: $out"; exit 1; }
grep -qF "$HOME/.claude-discord/runtime/discord-proxy.ts" "$PCACHE/0.0.7/bunfig.toml" &&
  [ "$(jq -r '.mcpServers.discord.env.CLAUDE_DISCORD_BOT' "$PCACHE/0.0.7/.mcp.json")" = '${DISCORD_STATE_DIR:-}' ] || { echo "FAIL: the patches that still match must be applied beside the moved one"; exit 1; }
# failure-cache: a .mcp.json without the discord server's command, and one that
# is not JSON, are left byte-identical, named, exit 1; the file lists once.
rm -rf "$PCACHE/0.0.7"
for v in 0.0.8 0.0.9; do mkdir -p "$PCACHE/$v"; cp "$HOME/server.ts.pristine" "$PCACHE/$v/server.ts"; done
printf '{"mcpServers":{"other":{"command":"x"}}}\n' > "$PCACHE/0.0.8/.mcp.json"
printf '{"mcpServers": oops\n' > "$PCACHE/0.0.9/.mcp.json"
cp "$PCACHE/0.0.8/.mcp.json" "$HOME/mcp8.orig"; cp "$PCACHE/0.0.9/.mcp.json" "$HOME/mcp9.orig"
out=$(bash "$S" patch 2>&1) && { echo "FAIL: a .mcp.json the failure-cache patch cannot edit must exit 1: $out"; exit 1; }
for v in 0.0.8 0.0.9; do
  grep -q "patch: .*$v/.mcp.json: failure-cache no longer matches" <<<"$out" || { echo "FAIL: no failure-cache report for $v: $out"; exit 1; }
  cmp -s "$HOME/mcp${v#0.0.}.orig" "$PCACHE/$v/.mcp.json" || { echo "FAIL: $v/.mcp.json must be left byte-identical"; exit 1; }
  grep -q 'ignoreEveryone: true' "$PCACHE/$v/server.ts" || { echo "FAIL: the other patches must still be applied to $v"; exit 1; }
done
! grep '^claude-discord: patched' <<<"$out" | grep -q '\.mcp\.json' || { echo "FAIL: an unpatched .mcp.json must not be listed as patched: $out"; exit 1; }
[ "$(grep '^claude-discord: patched' <<<"$out" | grep -o "$PCACHE/0.0.8/server.ts" | wc -l)" = 1 ] || { echo "FAIL: a patched file must be listed once: $out"; exit 1; }
rm -f "$HOME/mcp8.orig" "$HOME/mcp9.orig"
rm -rf "$PCACHE/0.0.8" "$PCACHE/0.0.9"
rm -rf "$PCACHE/0.0.5" "$PCACHE/0.0.6"
echo "ok: patch applies the five patches to every cached version, is idempotent and silent, and reports a moved pattern with exit 1"
# The old single file moved the plugin cache aside after these cases; the install cases below ran with it aside.
mv "$HOME/.claude/plugins" "$HOME/.claude/plugins.off"

# A machine with the old install: setup replaces what install.sh put under
# ~/.claude-discord with links into a compat copy of the real plugin (a project set up by the
# previous release and not yet by this one still reaches its hooks through
# there), removes the old rule copies, keeps the bots' scratch, records, runtime
# and the source clone.
OP="$HOME/old proj"; OH="$HOME/.claude-discord"; UP="$HOME/unmigrated proj"
# Earlier setups in this suite already linked these paths; back to real copies first, so the fixture writes nowhere else.
rm -rf "$OH/hooks" "$OH/rules" "$OH/discord-chunk.ts" "$OH/discord-proxy.ts"
mkdir -p "$OP/.claude/rules" "$OP/.claude/discord-agents" "$OH/scratch/b" "$OH/rules" "$OH/runtime" "$OH/hooks/tools"
for t in turn peers lib autoresearchclaw; do mkdir -p "$OH/hooks/$t"; echo old > "$OH/hooks/$t/stale"; done
# The previous release's rule told an ARC bot to loop on ~/.claude-discord/hooks/autoresearchclaw/events.
printf '#!/bin/sh\necho old\n' > "$OH/hooks/autoresearchclaw/events"; chmod +x "$OH/hooks/autoresearchclaw/events"
(cd "$OP" && git init -q .)
: > "$OH/scratch/b/note"; : > "$OH/runtime/discord-proxy.ts"; echo old > "$OH/hooks/tools/local-bots"; echo old > "$OH/hooks/tools/old-tool"; : > "$OH/rules/dev-manager.md"; echo old > "$OH/discord-chunk.ts"; echo old > "$OH/discord-proxy.ts"
: > "$OP/.claude/rules/claude-discord-dev-manager.md"
# The previous release's project: its settings hook runs a script through .claude/discord-agents/hooks -> ~/.claude-discord/hooks.
mkdir -p "$UP/.claude/discord-agents"; ln -s "$OH/hooks" "$UP/.claude/discord-agents/hooks"
echo '{}' > "$UP/.claude/settings.local.json"; plant_old "$UP/.claude/settings.local.json"
jq -n --arg p "$OP" --arg p5 "$PHOME/project5" '{projects: {($p): {hasTrustDialogAccepted: true}, ($p5): {hasTrustDialogAccepted: true}}}' > "$HOME/.claude.json"
(cd "$OP" && printf '\n900\n111\n\ntokO\nn\ndev-manager\n\n' | bash "$S" setup obot --scope project >/dev/null)
[ ! -e "$OH/rules" ] || { echo "FAIL: the old rule copies must go"; exit 1; }
for f in hooks/turn/on-prompt hooks/turn/on-reply hooks/turn/on-stop hooks/turn/on-session-start hooks/peers/thread-guard hooks/peers/edit-gate hooks/autoresearchclaw/on-start hooks/autoresearchclaw/events hooks/lib/discord.sh hooks/tools/thread hooks/tools/local-bots hooks/tools/arc-events discord-chunk.ts discord-proxy.ts; do
  # The hooks and tools go through the compat copy of the plugin, the .ts links through the stable runtime copy.
  case $f in hooks/tools/*) want=$PHOME/.claude-discord/compat/tools/${f##*/}; src=$PC/tools/${f##*/};; hooks/autoresearchclaw/events) want=$PHOME/.claude-discord/compat/tools/arc-events; src=$PC/tools/arc-events;; hooks/*) want=$PHOME/.claude-discord/compat/$f; src=$PC/$f;; *) want=$PHOME/.claude-discord/runtime/$f; src=$PC/runtime/$f;; esac
  [ -f "$OH/$f" ] && [ "$(readlink -f "$OH/$f")" = "$want" ] && cmp -s "$OH/$f" "$src" || { echo "FAIL: ~/.claude-discord/$f must resolve to $want, a copy of the real plugin's file: $(readlink -f "$OH/$f")"; exit 1; }
done
[ ! -e "$OH/compat/.git" ] && [ ! -e "$OH/compat/bin" ] || { echo "FAIL: the compat copy must hold no git tree and no wrapper"; exit 1; }
cmp -s "$PC/runtime/discord-chunk.ts" "$OH/runtime/discord-chunk.ts" && cmp -s "$PC/runtime/discord-proxy.ts" "$OH/runtime/discord-proxy.ts" || { echo "FAIL: setup must fill ~/.claude-discord/runtime from the real plugin (the fixture's stale copy included)"; exit 1; }
for f in hooks/turn/on-prompt hooks/peers/thread-guard hooks/autoresearchclaw/on-start hooks/autoresearchclaw/events hooks/tools/thread hooks/tools/local-bots hooks/tools/arc-events; do
  [ -x "$OH/$f" ] || { echo "FAIL: ~/.claude-discord/$f must be an executable"; exit 1; }
done
for t in turn peers lib autoresearchclaw; do
  [ -L "$OH/hooks/$t" ] && [ ! -e "$OH/hooks/$t/stale" ] && [ ! -e "$PC/hooks/$t/stale" ] || { echo "FAIL: the old hooks/$t copy must be replaced by a link, not written through"; exit 1; }
done
[ ! -e "$OH/hooks/tools/old-tool" ] && [ ! -e "$PC/tools/old-tool" ] || { echo "FAIL: an old tool copy must go"; exit 1; }
# The unmigrated project's kept entry still names an executable file after another project's setup.
[ -x "$UP/.claude/discord-agents/hooks/peers/thread-guard" ] && [ -x "$UP/.claude/discord-agents/hooks/turn/on-prompt" ] && grep -q '/.claude/discord-agents/hooks/peers/thread-guard' "$UP/.claude/settings.local.json" || { echo "FAIL: another project's setup must not disable an unmigrated project's hooks"; exit 1; }
[ -e "$OH/scratch/b/note" ] && [ -e "$OH/runtime/discord-proxy.ts" ] && [ -d "$OH/source/.git" ] || { echo "FAIL: scratch, runtime and the source clone must stay"; exit 1; }
[ -e "$OP/.claude/rules/claude-discord-dev-manager.md" ] || { echo "FAIL: setup must leave the project's old rule file to the plugin's first run"; exit 1; }
# The previous release's install.sh writes through the links (install -m 755 into hooks/<topic>/ and hooks/tools/):
# the write lands in the compat copy, never in the source clone, so update can still pull; the next setup restores the copy.
install -m 755 "$OH/hooks/turn/on-stop" "$OH/hooks/turn/on-prompt"; echo old > "$OH/hooks/lib/discord.sh"; install -m 755 "$OH/hooks/turn/on-stop" "$OH/hooks/tools/thread"
[ -z "$(git -C "$PC" status --porcelain)" ] && cmp -s "$PC/hooks/turn/on-prompt" "$D/hooks/turn/on-prompt" || { echo "FAIL: a write through the compat links must not reach the source clone: $(git -C "$PC" status --porcelain)"; exit 1; }
(cd "$OP" && printf '\nn\n\n' | bash "$S" setup obot --scope project >/dev/null)
cmp -s "$OH/hooks/turn/on-prompt" "$PC/hooks/turn/on-prompt" && cmp -s "$OH/hooks/lib/discord.sh" "$PC/hooks/lib/discord.sh" && cmp -s "$OH/hooks/tools/thread" "$PC/tools/thread" && [ -z "$(ls -d "$OH"/compat.* 2>/dev/null)" ] || { echo "FAIL: the next setup must restore the compat copy and leave no temp dir"; exit 1; }
chmod -x "$OH/compat/hooks/turn/on-stop"   # the same bytes, no longer executable: an old entry's -x test would skip it
(cd "$OP" && printf '\nn\n\n' | bash "$S" setup obot --scope project >/dev/null)
[ -x "$OH/hooks/turn/on-stop" ] || { echo "FAIL: a mode-only difference must refresh the compat copy"; exit 1; }
rm -f "$OP/.claude/skills/claude-discord"
[ -x "$OH/hooks/tools/thread" ] && [ -x "$OH/hooks/turn/on-prompt" ] || { echo "FAIL: the compat links must outlive the project's install link"; exit 1; }
# A symlink at hooks/ or rules/ (a dev checkout) goes as a link; its target keeps its files and is not written through.
mkdir -p "$HOME/old-target/hooks/turn" "$HOME/old-target/rules"; : > "$HOME/old-target/hooks/turn/on-prompt"; : > "$HOME/old-target/rules/dev-manager.md"
rm -rf "$OH/hooks"; ln -s "$HOME/old-target/hooks" "$OH/hooks"; ln -s "$HOME/old-target/rules" "$OH/rules"
(cd "$OP" && printf '\nn\nnone\n' | bash "$S" setup obot --scope project >/dev/null)
[ ! -L "$OH/hooks" ] && [ ! -e "$OH/rules" ] && [ -e "$HOME/old-target/hooks/turn/on-prompt" ] && [ -e "$HOME/old-target/rules/dev-manager.md" ] || { echo "FAIL: a symlinked hooks or rules must be removed as a link, its target untouched"; exit 1; }
[ -x "$OH/hooks/tools/thread" ] && [ -x "$OH/hooks/turn/on-prompt" ] && [ -z "$(ls "$HOME/old-target/hooks/tools" 2>/dev/null)" ] && [ "$(ls "$HOME/old-target/hooks/turn")" = on-prompt ] || { echo "FAIL: the links must be made in a real hooks directory, not written through the old link"; exit 1; }
rm -rf "$OP" "$UP" "$HOME/old-target"
echo "ok: setup on an old install replaces the old hook, tool and runtime copies with links into the real plugin (an unmigrated project's hooks still resolve), removes the old rule copies (the project's rule file is the plugin's to remove), keeps scratch, runtime and the source clone, removes a symlinked hooks or rules as a link without touching its target, and an old install.sh writing through the links changes the compat copy, never the source clone"

# compat/VERSION: a bot's startup (on-session-start runs patch --compat) rebuilds a compat/ whose stamp is not the
# plugin's HEAD sha (a git pull by hand in the source clone) or that holds a file newer than the stamp (an old
# install.sh writing through a link); a compaction does not; a plugin that is not the source clone never does; bots
# starting together leave one complete copy and no temp dir.
CB=$(bdir "$HOME/cbproj" cb); mkdir -p "$CB"
cbs() { printf '{"session_id":"%s","source":"%s"}' "$1" "$2" | CLAUDE_PLUGIN_ROOT="$PC" CLAUDE_PROJECT_DIR="$HOME/cbproj" DISCORD_STATE_DIR="$CB" bash "$PC/hooks/turn/on-session-start" >/dev/null; }
[ "$(cat "$OH/compat/VERSION")" = "$(git -C "$PC" rev-parse HEAD)" ] || { echo "FAIL: setup must stamp compat/VERSION with the source's HEAD sha: $(cat "$OH/compat/VERSION")"; exit 1; }
git -C "$SRC" -c user.email=t@t -c user.name=t commit -q --allow-empty -m pulled-by-hand && git -C "$PC" pull -q --ff-only
: > "$OH/compat/stale"; touch -d '1 hour ago' "$OH/compat/stale"
cbs cb1 compact
[ -e "$OH/compat/stale" ] || { echo "FAIL: a compaction must not rebuild compat/"; exit 1; }
bash "$D/bin/claude-discord" patch --compat >/dev/null 2>&1 || :
[ -e "$OH/compat/stale" ] || { echo "FAIL: a plugin other than the source clone must not rebuild compat/"; exit 1; }
mv "$OH/source" "$OH/source.off"; bash "$D/bin/claude-discord" patch --compat >/dev/null 2>&1 || :; mv "$OH/source.off" "$OH/source"
[ -e "$OH/compat/stale" ] || { echo "FAIL: with no source clone, a bot start must not rebuild compat/ (setup and update do)"; exit 1; }
cbs cb1 startup
[ ! -e "$OH/compat/stale" ] && [ "$(cat "$OH/compat/VERSION")" = "$(git -C "$PC" rev-parse HEAD)" ] || { echo "FAIL: a startup must rebuild a compat/ stamped by another commit: $(cat "$OH/compat/VERSION")"; exit 1; }
touch -d '1 minute ago' "$OH/compat/VERSION"; echo old > "$OH/hooks/lib/discord.sh"
cbs cb2 resume
cmp -s "$OH/hooks/lib/discord.sh" "$PC/hooks/lib/discord.sh" || { echo "FAIL: a resume must rebuild a compat/ written through after its stamp"; exit 1; }
touch -d '1 minute ago' "$OH/compat/VERSION"; echo old > "$OH/hooks/lib/discord.sh"
for _ in 1 2 3 4 5 6; do bash "$S" patch --compat >/dev/null 2>&1 & done; wait
cmp -s "$OH/hooks/lib/discord.sh" "$PC/hooks/lib/discord.sh" && [ -x "$OH/hooks/turn/on-prompt" ] && [ -s "$OH/compat/VERSION" ] && [ -z "$(ls -d "$OH"/compat.* "$OH"/compat/compat.* 2>/dev/null)" ] ||
  { echo "FAIL: six parallel refreshes must leave one complete compat/ and no temp dir: $(ls -d "$OH"/compat* "$OH"/compat/compat.* 2>&1)"; exit 1; }
# Writers swap one at a time under compat.lock. A stale lock is broken by exactly one of two refreshes that both judged it
# stale: the stubs order both judgements before either break, and the second break after the first re-took the lock (its swap
# waits for that break); the second must leave that lock, wait, then find compat/ current (one swap). Both succeed.
SB="$HOME/swapfail-stubs"; mkdir -p "$SB"; RP=$(command -v perl); cp -R "$OH/compat" "$HOME/cur"
cat > "$SB/hook" <<'EOF'
#!/bin/sh
case ${0##*/} in mv) s=$1 d=$2 r=/bin/mv;; mkdir) case $TC:$1 in dual:*/compat.lock) "$TMK" -p "$1"; exit;; esac; exec "$TMK" "$@";; *) s=$3 d=$4 r=$TRP;; esac
w() { i=0; until [ -e "$TSB/$1" ] || [ $i = 1000 ]; do sleep 0.01; i=$((i+1)); done; [ -e "$TSB/$1" ] || : > "$TSB/capped.$1"; }   # a cap that ends a wait is said, never silent
case $TC:$s:$d in
  two:"$TOH/compat":*old) echo >> "$TSB/swaps"; w b2done;;   # compat/ going aside: a swap
  two:*:*/compat.lock.broken.*) mkdir "$TSB/b1" 2>/dev/null && { w b2; exec "$r" "$@"; }; : > "$TSB/b2"; i=0
    until { [ -s "$TOH/compat.lock/owner" ] && [ "$(cat "$TOH/compat.lock/owner")" != dead ]; } || [ $i = 1000 ]; do sleep 0.01; i=$((i+1)); done
    [ $i != 1000 ] || : > "$TSB/capped.owner"
    o=$(cat "$TOH/compat.lock/owner" 2>/dev/null); "$r" "$@"; x=$?; [ "$(cat "$TOH/compat.lock/owner" 2>/dev/null)" = "$o" ] || : > "$TSB/overlap"; : > "$TSB/b2done"; exit $x;;
  dual:"$TOH/compat":*old) case $d in */compat.new.*/old) ;; *) : > "$TSB/shared";; esac; mkdir "$TSB/a1" 2>/dev/null && { w at2; exec "$r" "$@"; }   # aside
    : > "$TSB/at2"; w landed; "$r" "$@"; x=$?; : > "$TSB/aside2"; exit $x;;
  dual:*/compat.new.*/compat:"$TOH/compat") mkdir "$TSB/l1" 2>/dev/null && { "$r" "$@"; x=$?; : > "$TSB/landed"; w aside2; exit $x; }; w done;;   # land
esac; exec "$r" "$@"
EOF
chmod +x "$SB/hook"; for t in perl mv mkdir; do ln -s hook "$SB/$t"; done; export TSB="$SB" TOH="$OH" TRP="$RP" TMK="$(command -v mkdir)"
mkdir "$OH/compat.lock"; echo dead > "$OH/compat.lock/owner"; touch -d '1 minute ago' "$OH/compat.lock" "$OH/compat/VERSION"; echo old > "$OH/hooks/lib/discord.sh"
for k in 1 2; do { PATH="$SB:$PATH" TC=two bash "$S" patch --compat >/dev/null 2>"$SB/err.$k" || : > "$SB/failed"; } & done; wait
[ -z "$(ls "$SB"/capped.* 2>/dev/null)" ] || { echo "FAIL: two breakers: the stub lost its forced order (a wait ran out: $(ls "$SB"/capped.*)); this says nothing about the code"; exit 1; }
[ -e "$SB/b2done" ] && [ ! -e "$SB/overlap" ] && [ ! -e "$SB/failed" ] && [ "$(wc -l < "$SB/swaps")" -eq 1 ] && cmp -s "$OH/hooks/lib/discord.sh" "$PC/hooks/lib/discord.sh" && [ -x "$OH/hooks/turn/on-prompt" ] && [ -z "$(ls -d "$OH"/compat.* "$OH"/compat/compat* 2>/dev/null)" ] ||
  { echo "FAIL: of two breakers of one stale lock only one may break it, the other waits; one swap, both succeed, one complete compat/: swaps=$(wc -l < "$SB/swaps") current=$(cmp "$OH/hooks/lib/discord.sh" "$PC/hooks/lib/discord.sh" 2>&1 && echo yes) exec=$([ -x "$OH/hooks/turn/on-prompt" ] && echo yes; ls -ld "$OH/hooks/turn" "$OH/hooks/turn/on-prompt" 2>&1) stderr=$(cat "$SB"/err.* 2>&1) $(ls -d "$SB"/* "$OH"/compat* "$OH"/compat/compat* 2>&1)"; exit 1; }
# Two holders at once (a lock broken under a stalled holder; the stub lets both past it), worst order: A takes compat/ aside,
# lands, B takes that aside, A exits, B lands. Nothing nested, absent or old again; no old copy goes to a name writers share.
touch -d '1 minute ago' "$OH/compat/VERSION"; echo old > "$OH/hooks/lib/discord.sh"
for _ in 1 2; do { PATH="$SB:$PATH" TC=dual bash "$S" patch --compat >/dev/null 2>&1 || :; : > "$SB/done"; } & done; wait
[ -e "$SB/aside2" ] && [ ! -e "$SB/shared" ] && diff -r "$OH/compat" "$HOME/cur" >/dev/null && [ -z "$(ls -d "$OH"/compat.* 2>/dev/null)" ] ||
  { echo "FAIL: two holders at once must leave compat/ whole and current, nothing nested or left: $(ls -d "$SB"/* "$OH"/compat* "$OH"/compat/compat* "$OH"/compat/old 2>&1)"; exit 1; }
rm -r "$SB"/*
# Under the lock a dead writer's leftovers go: an old compat.new.* (its old copy too), compat.old.<pid> (1.9.4), compat.lock.broken.*
# (a breaker killed mid-break), a copy 1.9.4 nested in compat/; a compat.new.* under 10 minutes old may be a writer still building.
mkdir "$OH/compat.old.99999" "$OH/compat.new.99999" "$OH/compat.new.99999/old" "$OH/compat.lock.broken.x" "$OH/compat.new.fresh" "$OH/compat/compat.old.99998"
touch -d '1 hour ago' "$OH/compat.old.99999" "$OH/compat.new.99999" "$OH/compat.lock.broken.x"; touch -d '5 minutes ago' "$OH/compat.new.fresh"; touch -d '1 minute ago' "$OH/compat/VERSION"
rc=0; bash "$S" patch --compat >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] && [ "$(ls -d "$OH"/compat.* "$OH"/compat/compat* 2>/dev/null)" = "$OH/compat.new.fresh" ] ||
  { echo "FAIL: leftovers must be removed under the lock, a fresh compat.new.* kept (rc=$rc): $(ls -d "$OH"/compat* "$OH"/compat/compat* 2>&1)"; exit 1; }
rmdir "$OH/compat.new.fresh"
# A failed swap: perl's rename of our copy fails after compat/ went aside (a non-race failure) -> the old copy goes
# back, the run fails, the lock is released. Only that rename fails; the restore reaches the real perl.
printf '#!/bin/sh\ncase $3 in */compat.new.*/compat) exit 1;; esac\nexec "%s" "$@"\n' "$RP" > "$SB/perl"; chmod +x "$SB/perl"
touch -d '1 minute ago' "$OH/compat/VERSION"; echo old > "$OH/hooks/lib/discord.sh"
rc=0; PATH="$SB:$PATH" bash "$S" patch --compat >/dev/null 2>&1 || rc=$?
[ "$rc" != 0 ] && [ -x "$OH/compat/hooks/turn/on-prompt" ] && [ -s "$OH/compat/VERSION" ] && [ -z "$(ls -d "$OH"/compat.* 2>/dev/null)" ] ||
  { echo "FAIL: a failed rename must put the old compat/ back, fail and release the lock (rc=$rc): $(ls -d "$OH"/compat* 2>&1)"; exit 1; }
# The restore fails too: ours goes if another writer landed meanwhile, else the run fails and our compat.new.*/old stays.
printf '#!/bin/sh\ncase $3 in */compat.new.*/compat) exit 1;; */compat.new.*/old) [ ! -e "%s/mw" ] || cp -R "%s/cur" "$4"; exit 1;; esac\nexec "%s" "$@"\n' "$SB" "$HOME" "$RP" > "$SB/perl"
: > "$SB/mw"; touch -d '1 minute ago' "$OH/compat/VERSION"; echo old > "$OH/hooks/lib/discord.sh"; PATH="$SB:$PATH" bash "$S" patch --compat >/dev/null 2>&1 || :
diff -r "$OH/compat" "$HOME/cur" >/dev/null && [ -z "$(ls -d "$OH"/compat.* 2>/dev/null)" ] || { echo "FAIL: a restore beaten by another writer's landing must drop ours: $(ls -d "$OH"/compat* "$OH"/compat.*/* 2>&1)"; exit 1; }
rm "$SB/mw"; touch -d '1 minute ago' "$OH/compat/VERSION"; echo old > "$OH/hooks/lib/discord.sh"; rc=0; PATH="$SB:$PATH" bash "$S" patch --compat >/dev/null 2>&1 || rc=$?
j=$(ls -d "$OH"/compat.* 2>/dev/null || :); [ "$rc" != 0 ] && [ ! -e "$OH/compat" ] && [ -d "$j/old" ] ||
  { echo "FAIL: a failed restore must keep its compat.new.*/old and still release the lock (rc=$rc): $(ls -d "$OH"/compat* "$OH"/compat.*/* 2>&1)"; exit 1; }
# A writer killed between its two renames leaves the same. A bot start puts the newest old copy back under the lock before
# the sweep, which then removes the older one (a current copy stays: same inode); the emptied one is fresh again, and stays.
rm -r "$j" "$SB/perl"; mkdir "$OH/compat.new.a" "$OH/compat.new.b"; cp -R "$HOME/cur" "$OH/compat.new.a/old"; cp -R "$HOME/cur" "$OH/compat.new.b/old"
touch -d '2 hours ago' "$OH/compat.new.a"; touch -d '1 hour ago' "$OH/compat.new.b"; i=$(ls -di "$OH/compat.new.b/old"); bash "$S" patch --compat >/dev/null 2>&1 || :
j=$(ls -di "$OH/compat" 2>/dev/null || :); [ "${j%% *}" = "${i%% *}" ] && [ "$(ls -d "$OH"/compat.* 2>/dev/null)" = "$OH/compat.new.b" ] ||
  { echo "FAIL: a bot start must put back the newest old copy a killed writer left ($i): $(ls -di "$OH"/compat* "$OH"/compat.*/* 2>&1)"; exit 1; }
# Our compat/ refused to go aside for a non-race reason (permissions): it stays unreplaced, so the run fails.
rmdir "$OH/compat.new.b"; printf '#!/bin/sh\ncase $4 in */compat.new.*/old) exit 1;; esac\nexec "%s" "$@"\n' "$RP" > "$SB/perl"; chmod +x "$SB/perl"; echo other-sha > "$OH/compat/VERSION"
rc=0; PATH="$SB:$PATH" bash "$S" patch --compat >/dev/null 2>&1 || rc=$?
[ "$rc" != 0 ] && [ "$(cat "$OH/compat/VERSION")" = other-sha ] && [ -z "$(ls -d "$OH"/compat.* 2>/dev/null)" ] || { echo "FAIL: a refused mv that leaves compat/ unreplaced must fail (rc=$rc): $(ls -d "$OH"/compat* 2>&1)"; exit 1; }
# A lockless writer (1.9.4, or a holder stalled past the bound whose lock we broke) lands its copy right after ours went aside: our rename(2)
# fails instead of nesting ours in it, and the run succeeds; the stub also re-takes the lock (owner next), which our release must leave.
printf '#!/bin/sh\ncase $4 in */compat.new.*/old) "%s" "$@" && cp -R "%s/cur" "$3" && rm -r "$3.lock" && mkdir "$3.lock" && echo next > "$3.lock/owner" && : > "%s/fired"; exit;; esac\nexec "%s" "$@"\n' "$RP" "$HOME" "$SB" "$RP" > "$SB/perl"
mkdir "$OH/compat.lock"; touch -d '1 minute ago' "$OH/compat.lock" "$OH/compat/VERSION"; echo old > "$OH/hooks/lib/discord.sh"
rc=0; PATH="$SB:$PATH" bash "$S" patch --compat >/dev/null 2>&1 || rc=$?
[ "$(cat "$OH/compat.lock/owner" 2>/dev/null)" = next ] || { echo "FAIL: a writer whose lock was broken while it stalled must not release the next holder's lock: $(ls -d "$OH"/compat* 2>&1)"; exit 1; }
rm -r "$OH/compat.lock"
[ -e "$SB/fired" ] && [ "$rc" = 0 ] && cmp -s "$OH/hooks/lib/discord.sh" "$PC/hooks/lib/discord.sh" && [ -z "$(ls -d "$OH"/compat.* "$OH"/compat/compat* 2>/dev/null)" ] ||
  { echo "FAIL: a copy landed by a lockless writer must stay whole, ours neither inside nor beside it (rc=$rc): $(ls -d "$OH"/compat* "$OH"/compat/compat* 2>&1)"; exit 1; }
rm -rf "$HOME/cur"
rm -rf "$SB"
bash "$S" patch --compat >/dev/null 2>&1   # leave a fresh compat/
rm -rf "$HOME/cbproj"
echo "ok: a startup or resume rebuilds a compat/ stamped by another commit or written through after its stamp, a compaction or a non-source plugin does not, parallel refreshes leave one complete copy, writers swap one at a time under a lock (a held one is waited for, a stale one broken by exactly one breaker, a dead writer's leftovers removed), two holders at once leave one whole current copy, a failed swap restores the old copy (drops it if another writer landed meanwhile), a killed writer's old copy goes back at a bot start, a refused move aside fails, a lockless writer's copy landing at our swap stays whole, a writer whose lock was broken leaves the next holder's, and with no source clone no bot start rebuilds it"

# setup --mode: changes only a set-up bot's mode. A fresh project, so these
# assertions are not entangled with any other bot's state.
P5="$HOME/project5"; mkdir -p "$P5"; cd "$P5"
R5=$HOME/.claude-discord/projects/$(skey "$P5")/bots   # by hand, not broot: the first case asserts that nothing made the key dir
SL5="$P5/.claude/settings.local.json"

out=$(printf '' | bash "$S" setup nosetup --mode 2>&1) && { echo "FAIL: --mode on a bot that is not set up should refuse"; exit 1; }
rc=$?
[ "$rc" -eq 2 ] && grep -qF "run 'claude-discord setup nosetup' first" <<<"$out" || { echo "FAIL: --mode on an unset bot must exit 2 with a hint, got rc=$rc: $out"; exit 1; }
[ ! -e "$HOME/.claude-discord/projects/$(skey "$P5")" ] && [ ! -e "$P5/.claude/discord-agents" ] || { echo "FAIL: --mode on an unset bot must create nothing (no key dir, bot dir or config.env): $(find "$HOME/.claude-discord/projects/$(skey "$P5")" "$P5/.claude" 2>&1)"; exit 1; }
echo "ok: --mode on a bot that is not set up exits 2 with a hint and creates nothing"

printf '\n1\n222\n\ntokF\nn\n' | bash "$S" setup five --scope project >/dev/null   # mode kept at its default, none
cp "$R5/five/.env" "$P5/five.env.before"; cp "$R5/five/access.json" "$P5/five.access.before"
printf 'autoresearchclaw\n' | bash "$S" setup five --mode >/dev/null
[ "$(<"$R5/five/mode")" = autoresearchclaw ] || { echo "FAIL: --mode fed only the mode answer did not switch the mode"; exit 1; }
! grep -qs '/.claude/discord-agents/hooks/' "$SL5" || { echo "FAIL: --mode must register no settings hook: $(cat "$SL5" 2>&1)"; exit 1; }
cmp -s "$R5/five/.env" "$P5/five.env.before" || { echo "FAIL: --mode must not touch the token file"; exit 1; }
cmp -s "$R5/five/access.json" "$P5/five.access.before" || { echo "FAIL: --mode must not touch access.json"; exit 1; }
printf 'none\n' | bash "$S" setup five --mode >/dev/null
[ "$(<"$R5/five/mode")" = none ] || { echo "FAIL: --mode did not switch back to none"; exit 1; }
cmp -s "$R5/five/.env" "$P5/five.env.before" || { echo "FAIL: --mode must not touch the token file (second run)"; exit 1; }
cmp -s "$R5/five/access.json" "$P5/five.access.before" || { echo "FAIL: --mode must not touch access.json (second run)"; exit 1; }
echo "ok: --mode fed only the mode answer switches a set-up bot's mode, writes no settings hook, and leaves the token file and access.json byte-identical"

printf 'dev-manager\npeerx:700:800:host\n' | bash "$S" setup five --mode >/dev/null
[ "$(<"$R5/five/mode")" = dev-manager ] || { echo "FAIL: --mode to dev-manager did not switch the mode"; exit 1; }
[ "$(jq -c '.peers' "$(pstate "$P5")/peers.json" 2>/dev/null)" = '[{"name":"peerx","bot_id":"700","owner_id":"800","machine":"host"}]' ] || { echo "FAIL: --mode to dev-manager must record the peer: $(cat "$(pstate "$P5")/peers.json" 2>&1)"; exit 1; }
[ "$(jq -c '.groups["1"].allowFrom' "$R5/five/access.json")" = '["222","700"]' ] || { echo "FAIL: the peer must reach access.json's allowFrom: $(jq -c . "$R5/five/access.json")"; exit 1; }
echo "ok: --mode to dev-manager also asks the peers question and records a peer in peers.json and access.json's allowFrom"

# setup installs the plugin. Fixtures: XP (git, path with a space, trusted), refusals leave the bot untouched.
XP="$HOME/scope proj"; XR=$(broot "$XP"); XL="$XP/.claude/skills/claude-discord"; GL="$HOME/.claude/skills/claude-discord"
mkdir -p "$XP"; (cd "$XP" && git init -q .)
jq -n --arg p "$PHOME/scope proj" '{projects: {($p): {hasTrustDialogAccepted: true}}, other: 1}' > "$HOME/.claude.json"
# link: the project path is a symlink to the one source; second project shares it; the install stays out of git status, is recorded, and the shim is installed.
(cd "$XP" && printf '900\n111\n\ntokS\nn\n' | bash "$S" setup xbot --scope project --method link >/dev/null) || { echo "FAIL: setup --scope project --method link failed"; exit 1; }
[ "$(readlink "$XL")" = "$HOME/.claude-discord/source" ] || { echo "FAIL: link method must link to the source clone"; exit 1; }
[ "$(git -C "$XP" status --porcelain --untracked-files=all | grep -c 'skills/claude-discord')" = 0 ] && grep -qxF '/.claude/skills/claude-discord' "$XP/.git/info/exclude" || { echo "FAIL: the link must be excluded from the project's git"; exit 1; }
cmp -s "$D/shim/claude-discord" "$HOME/.local/bin/claude-discord" || { echo "FAIL: setup must install the shim"; exit 1; }
grep -qxF "$XL" "$HOME/.claude-discord/records/installs" || { echo "FAIL: setup must record the install"; exit 1; }
# A re-run with no flags keeps the link and asks nothing (the extra 'global' line would be taken by a scope question), refreshes a stale shim, keeps one exclude line.
echo stale > "$HOME/.local/bin/claude-discord"
out=$(cd "$XP" && printf '\nn\n\nglobal\n' | bash "$S" setup xbot 2>&1) || { echo "FAIL: a re-run in an installed project must succeed without a question: $out"; exit 1; }
[ "$(readlink "$XL")" = "$HOME/.claude-discord/source" ] && grep -q 'already installed at' <<<"$out" && [ ! -e "$GL" ] || { echo "FAIL: a re-run must keep the install and ask nothing: $out"; exit 1; }
cmp -s "$D/shim/claude-discord" "$HOME/.local/bin/claude-discord" && [ "$(grep -c 'skills/claude-discord' "$XP/.git/info/exclude")" = 1 ] || { echo "FAIL: a re-run must refresh the shim and keep a single exclude line"; exit 1; }
# Refusals and bad flags decide before anything is written: no new bot dir, and --reset deletes nothing.
mkdir -p "$GL"
out=$(cd "$XP" && printf '\nn\n' | bash "$S" setup rbot --scope project 2>&1) && { echo "FAIL: a global copy beside a project copy must be refused"; exit 1; }
grep -q "already installed globally" <<<"$out" && [ ! -e "$XR/rbot" ] || { echo "FAIL: wrong or late refusal ($(ls "$XR")): $out"; exit 1; }
rmdir "$GL"
out=$(cd "$XP" && printf '\nn\n' | bash "$S" setup xbot --reset --scope global --method clone 2>&1) && { echo "FAIL: a global clone beside a project copy must be refused"; exit 1; }
grep -q "already installed for this project" <<<"$out" && [ -f "$XR/xbot/.env" ] || { echo "FAIL: wrong or late refusal, --reset must not run: $out"; exit 1; }
# A new global copy would shadow every recorded project install (the global one wins), so it is refused naming one.
mkdir -p "$HOME/gr proj"
out=$(cd "$HOME/gr proj" && printf '\nn\n' | bash "$S" setup grbot --scope global --method clone 2>&1) && { echo "FAIL: a global clone beside another project's install must be refused"; exit 1; }
grep -q "a project install exists at .*claude/skills/claude-discord" <<<"$out" && [ ! -e "$HOME/gr proj/.claude/discord-agents/grbot" ] && [ ! -e "$GL" ] || { echo "FAIL: wrong or late refusal: $out"; exit 1; }
rm -rf "$HOME/gr proj"
rc=0; (cd "$XP" && printf 'dev-manager\n\n' | bash "$S" setup xbot --mode --scope project >/dev/null 2>&1) || rc=$?
[ "$rc" = 2 ] && [ "$(<"$XR/xbot/mode")" = none ] || { echo "FAIL: --mode with --scope must be refused before the mode is written, rc=$rc"; exit 1; }
for bad in "--scope bogus" "--method bogus" "--scope" "--method"; do
  # shellcheck disable=SC2086
  rc=0; (cd "$XP" && printf '\nn\n' | bash "$S" setup rbot $bad >/dev/null 2>&1) || rc=$?
  [ "$rc" = 2 ] && [ ! -e "$XR/rbot" ] || { echo "FAIL: 'setup rbot $bad' must exit 2 and write nothing, rc=$rc"; exit 1; }
done
# Trust: reported, never written unasked, written (other keys kept) on an explicit y. Answered n, the plugin
# will not load, so the old settings hooks and rule file must stay (setup never removes them).
jq -n '{projects: {}, other: 1}' > "$HOME/.claude.json"
mkdir -p "$XP/.claude/rules"; : > "$XP/.claude/rules/claude-discord-dev-manager.md"; echo '{}' > "$XP/.claude/settings.local.json"; plant_old "$XP/.claude/settings.local.json"; cp "$XP/.claude/settings.local.json" "$HOME/xsl.before"
out=$(cd "$XP" && printf '\n\nn\n' | bash "$S" setup xbot 2>&1)
grep -q 'not trusted' <<<"$out" && [ "$(jq -r --arg p "$PHOME/scope proj" '.projects[$p] | if . == null then "unset" else "set" end' "$HOME/.claude.json")" = unset ] || { echo "FAIL: setup must say the project is not trusted and write nothing: $out"; exit 1; }
cmp -s "$XP/.claude/settings.local.json" "$HOME/xsl.before" && [ -e "$XP/.claude/rules/claude-discord-dev-manager.md" ] || { echo "FAIL: with trust answered n, setup must remove no old hook and no rule file"; exit 1; }
rm -rf "$XP/.claude/rules" "$XP/.claude/settings.local.json" "$HOME/xsl.before"
(cd "$XP" && printf 'y\n\nn\n' | bash "$S" setup xbot >/dev/null 2>&1)
[ "$(jq -r --arg p "$PHOME/scope proj" '.projects[$p].hasTrustDialogAccepted' "$HOME/.claude.json")" = true ] && [ "$(jq -r .other "$HOME/.claude.json")" = 1 ] || { echo "FAIL: an explicit y must write trust and keep other keys"; exit 1; }
# Reached through a symlink, the project is trusted by its physical path; a dangling install link is replaced.
ln -s "$XP" "$HOME/xp link"; ln -sfn "$HOME/nowhere" "$XL"
out=$(cd "$HOME/xp link" && printf '\n\nn\n\n' | bash "$S" setup xbot 2>&1)
! grep -q 'not trusted' <<<"$out" || { echo "FAIL: trust must be read by the physical path: $out"; exit 1; }
[ "$(readlink "$XL")" = "$HOME/.claude-discord/source" ] || { echo "FAIL: a dangling install link must be replaced: $out"; exit 1; }
rm -f "$HOME/xp link"
# clone + global, then a second bot elsewhere uses the global install on Enter (no refusal, no project copy); --mode installs nothing.
rm -rf "$XP"
GP="$HOME/g proj"; GP2="$HOME/g proj2"; mkdir -p "$GP" "$GP2"
# A global install is refused while a project install is recorded: park the records for this part, put them back after.
RECS=$HOME/.claude-discord/records/installs; cp "$RECS" "$HOME/installs.parked"; : > "$RECS"
(cd "$GP" && printf '900\n111\n\ntokG\nn\n' | bash "$S" setup gbot --scope global --method clone >/dev/null) || { echo "FAIL: setup --scope global --method clone failed"; exit 1; }
[ -d "$GL/.git" ] && [ ! -L "$GL" ] && [ ! -e "$GP/.claude/skills" ] || { echo "FAIL: global clone must be a real clone at ~/.claude/skills and leave the project alone"; exit 1; }
# The machine-wide compat links stay on the source clone, not on this clone-method install (it may be pinned, and may go). Run the clone's own wrapper: it is the one whose self_root is the clone.
(cd "$GP" && printf '\nn\n' | bash "$GL/bin/claude-discord" setup gbot >/dev/null 2>&1) || { echo "FAIL: a re-run of the global clone's own wrapper failed"; exit 1; }
[ "$(readlink "$HOME/.claude-discord/hooks/tools/thread")" = "$HOME/.claude-discord/compat/tools/thread" ] && [ "$(readlink "$HOME/.claude-discord/hooks/turn")" = "$HOME/.claude-discord/compat/hooks/turn" ] || { echo "FAIL: a clone-method setup must keep the compat links on the compat copy: $(readlink "$HOME/.claude-discord/hooks/tools/thread")"; exit 1; }
(cd "$GP2" && printf '900\n111\n\ntokG2\nn\n\nproject\n' | bash "$S" setup gbot2 >/dev/null 2>&1) || { echo "FAIL: a second bot on a globally installed machine must not be refused"; exit 1; }
[ ! -e "$GP2/.claude/skills" ] || { echo "FAIL: with a global install the project must get no copy"; exit 1; }
rm -rf "$GL"
{ cat "$HOME/installs.parked" "$RECS"; } | awk '!seen[$0]++' > "$RECS.new" && mv "$RECS.new" "$RECS" && rm -f "$HOME/installs.parked"
(cd "$GP2" && printf 'none\n' | bash "$S" setup gbot2 --mode >/dev/null)
[ ! -e "$GL" ] && [ ! -e "$GP2/.claude/skills" ] || { echo "FAIL: setup --mode must install nothing"; exit 1; }
# A project in a subdirectory of a repo, and in a git worktree of it, is excluded with the right path.
SG="$HOME/sg repo"; mkdir -p "$SG/sub"; (cd "$SG" && git init -q . && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m e && git worktree add -q -b sgwt "$HOME/sg wt")
for w in "$SG/sub" "$HOME/sg wt"; do
  (cd "$w" && printf '\n900\n111\n\ntokW\nn\n' | bash "$S" setup wb --scope project --method link >/dev/null 2>&1) || { echo "FAIL: setup in $w failed"; exit 1; }
  [ "$(git -C "$w" status --porcelain --untracked-files=all | grep -c 'skills/claude-discord')" = 0 ] || { echo "FAIL: the install in $w must be ignored by git"; exit 1; }
done
grep -qxF '/sub/.claude/skills/claude-discord' "$SG/.git/info/exclude" || { echo "FAIL: a subdirectory project needs its prefix in the exclude pattern"; exit 1; }
echo "ok: setup installs the plugin as a link or a clone at project or global scope, asks nothing when an install exists, refuses the other scope and bad flags before writing, excludes it in subdirectories and worktrees, records it, and writes trust only on y"

# install: the plugin, shim, runtime and compat copy, asking nothing (stdin is left unread) and writing no bot
# file; a re-run is the same. A setup whose clone fails writes no bot file: the install comes before the questions.
IP="$HOME/inst proj"; FP="$HOME/fail proj"; mkdir -p "$IP" "$FP"
jq --arg p "$PHOME/inst proj" '.projects[$p].hasTrustDialogAccepted = true' "$HOME/.claude.json" > "$HOME/cj.tmp" && mv "$HOME/cj.tmp" "$HOME/.claude.json"
for _ in 1 2; do
  rc=0; left=$(printf 'leftover\n' | { (cd "$IP" && bash "$S" install --scope project --method link >"$HOME/inst.out" 2>&1) || rc=$?; cat; })
  [ "$rc" = 0 ] && [ "$left" = leftover ] && [ "$(readlink "$IP/.claude/skills/claude-discord")" = "$HOME/.claude-discord/source" ] && [ ! -e "$IP/.claude/discord-agents" ] || { echo "FAIL: install must install, read nothing from stdin and write no bot file (rc=$rc, left=$left): $(<"$HOME/inst.out")"; exit 1; }
done
grep -qxF "$IP/.claude/skills/claude-discord" "$HOME/.claude-discord/records/installs" && cmp -s "$D/shim/claude-discord" "$HOME/.local/bin/claude-discord" && [ -d "$HOME/.claude-discord/compat/hooks/turn" ] || { echo "FAIL: install must record the install and refresh the shim and compat copy"; exit 1; }
# install ends with one patch of the official plugin cache: an install then /reload-plugins with no bot start must
# find .mcp.json and server.ts patched. A version dir whose pattern moved warns on stderr and leaves the install at rc 0.
for v in 0.0.20 0.0.21; do mkdir -p "$PCACHE/$v"; done
cp "$HOME/server.ts.pristine" "$PCACHE/0.0.20/server.ts"; printf 'nothing to patch here\n' > "$PCACHE/0.0.21/server.ts"
printf '{"mcpServers":{"discord":{"command":"bun"}}}\n' > "$PCACHE/0.0.20/.mcp.json"
rc=0; (cd "$IP" && bash "$S" install >"$HOME/inst.out" 2>"$HOME/inst.err") || rc=$?
[ "$rc" = 0 ] && [ "$(jq -r '.mcpServers.discord.env.CLAUDE_DISCORD_BOT' "$PCACHE/0.0.20/.mcp.json")" = '${DISCORD_STATE_DIR:-}' ] && grep -q 'ignoreEveryone: true' "$PCACHE/0.0.20/server.ts" && grep -qF "$PCACHE/0.0.20/.mcp.json" "$HOME/inst.out" &&
  grep -q '^claude-discord: some patches no longer apply' "$HOME/inst.err" || { echo "FAIL: install must patch the official plugin cache and survive a patch that no longer applies (rc=$rc): $(<"$HOME/inst.out") $(<"$HOME/inst.err")"; exit 1; }
rm -rf "$PCACHE/0.0.20" "$PCACHE/0.0.21" "$HOME/inst.err"
# No flags, an untrusted project: still no stdin read (no scope, method or trust question), a hint instead; </dev/null too.
UI="$HOME/untrusted inst"; mkdir -p "$UI"
rc=0; left=$(printf 'l1\nl2\nl3\nl4\n' | { (cd "$UI" && bash "$S" install >"$HOME/inst.out" 2>&1) || rc=$?; cat; })
[ "$rc" = 0 ] && [ "$left" = "$(printf 'l1\nl2\nl3\nl4')" ] && [ "$(readlink "$UI/.claude/skills/claude-discord")" = "$HOME/.claude-discord/source" ] && grep -q 'not trusted' "$HOME/inst.out" && grep -q "answer y in 'claude-discord setup <bot>'" "$HOME/inst.out" ||
  { echo "FAIL: install with no flags in an untrusted project must read none of 4 piped lines and print the trust hint (rc=$rc, left=$left): $(<"$HOME/inst.out")"; exit 1; }
[ "$(jq -r --arg p "$PHOME/untrusted inst" '.projects[$p] | if . == null then "unset" else "set" end' "$HOME/.claude.json")" = unset ] || { echo "FAIL: install must not write trust"; exit 1; }
rc=0; (cd "$UI" && bash "$S" install </dev/null >/dev/null 2>&1) || rc=$?
[ "$rc" = 0 ] || { echo "FAIL: install </dev/null must succeed, rc=$rc"; exit 1; }
rm -rf "$UI"
rc=0; (cd "$IP" && bash "$S" install bogus >/dev/null 2>&1) || rc=$?
[ "$rc" = 2 ] || { echo "FAIL: install takes only --scope and --method, rc=$rc"; exit 1; }
GW="$HOME/gitwrap"; mkdir -p "$GW"
printf '#!/bin/bash\necho "${GIT_TERMINAL_PROMPT:-unset} $(ps -o comm= -p $PPID) $1" >> "%s/log"\nexec %s "$@"\n' "$GW" "$(command -v git)" > "$GW/git"; chmod +x "$GW/git"
rc=0; out=$(cd "$FP" && printf '900\n111\n\ntokF\nn\n' | PATH="$GW:$PATH" CLAUDE_DISCORD_REPO="$HOME/no such repo" bash "$S" setup fbot --scope project --method clone 2>&1) || rc=$?
[ "$rc" != 0 ] && grep -q 'could not clone' <<<"$out" && [ ! -e "$FP/.claude/discord-agents" ] || { echo "FAIL: a failed clone must stop setup before any bot file (rc=$rc): $out $(find "$FP")"; exit 1; }
! command -v timeout >/dev/null || grep -q '^0 timeout clone$' "$GW/log" || { echo "FAIL: a clone must run with GIT_TERMINAL_PROMPT=0 under timeout: $(<"$GW/log")"; exit 1; }
rm -rf "$GW"
rm -rf "$IP" "$FP" "$HOME/inst.out"
echo "ok: install installs and refreshes (twice), patches the official plugin cache once (a patch that no longer applies only warns), reading no stdin at all (no flags and untrusted too: a trust hint instead) and writing no bot file, refuses other words; a setup whose clone fails writes no bot file, and git runs with no prompt under a timeout"

# Scopes: a bot in $HOME is a global install (its .claude is ~/.claude); a project link and the global link to
# the one source coexist (one code, loaded once); a clone on either side beside another install is refused.
mkdir -p "$HOME/.claude"
rc=0; out=$(cd "$HOME" && printf '900\n111\n\ntokH\nn\n' | bash "$S" setup hbot --method link 2>&1) || rc=$?
[ "$rc" = 0 ] && grep -q 'this project is \$HOME' <<<"$out" && [ "$(readlink "$GL")" = "$HOME/.claude-discord/source" ] && [ -f "$(bdir "$HOME" "hbot")/.env" ] || { echo "FAIL: a bot in \$HOME must install globally, saying so (rc=$rc): $out"; exit 1; }
CO="$HOME/co proj"; mkdir -p "$CO"
jq --arg p "$PHOME/co proj" '.projects[$p].hasTrustDialogAccepted = true' "$HOME/.claude.json" > "$HOME/cj.tmp" && mv "$HOME/cj.tmp" "$HOME/.claude.json"
rc=0; out=$(cd "$CO" && printf '900\n111\n\ntokC\nn\n' | bash "$S" setup cobot --scope project 2>&1) || rc=$?
[ "$rc" = 0 ] && [ "$(readlink "$CO/.claude/skills/claude-discord")" = "$HOME/.claude-discord/source" ] && [ -L "$GL" ] || { echo "FAIL: a project link beside the global link must be allowed, as a link (rc=$rc): $out"; exit 1; }
rm -f "$CO/.claude/skills/claude-discord"
rc=0; out=$(cd "$CO" && printf '\nn\n' | bash "$S" setup cobot --scope project --method clone 2>&1) || rc=$?
[ "$rc" = 2 ] && grep -q 'already installed globally' <<<"$out" && [ ! -e "$CO/.claude/skills/claude-discord" ] || { echo "FAIL: a project clone beside the global link must be refused (rc=$rc): $out"; exit 1; }
rm -f "$GL"; rm -rf "$CO" "$(pstate "$HOME")"
echo "ok: a bot in \$HOME installs globally and says so; a project link and the global link coexist; a clone beside another install is refused"

# --version and update. UP is a project linked to the source (so are the earlier projects the records still hold), UC a clone-method install.
UP="$HOME/up proj"; UC="$HOME/up clone"; mkdir -p "$UP" "$UC"; for w in "$UP" "$UC"; do (cd "$w" && git init -q .); done
jq -n --arg a "$PHOME/up proj" --arg c "$PHOME/up clone" '{projects: {($a): {hasTrustDialogAccepted: true}, ($c): {hasTrustDialogAccepted: true}}}' > "$HOME/.claude.json"
(cd "$UP" && printf '\n900\n111\n\ntokU\nn\n' | bash "$S" setup ubot --scope project >/dev/null)
(cd "$UC" && printf '900\n111\n\ntokU\nn\n' | bash "$S" setup ubot --scope project --method clone >/dev/null)
C="$UP/.claude/skills/claude-discord"; CC="$UC/.claude/skills/claude-discord"
[ -L "$C" ] && [ ! -L "$CC" ] || { echo "FAIL: fixture: the default method links, --method clone does not"; exit 1; }
v=$(cd "$UP" && bash "$C/bin/claude-discord" --version)
grep -qE '^claude-discord [0-9]+\.[0-9]+\.[0-9]+ \([0-9a-f]{7,}\)$' <<<"$v" && [[ $v == *"($(git -C "$PC" rev-parse --short HEAD))" ]] || { echo "FAIL: --version through a link must print the version and the source's sha: $v"; exit 1; }
# The upstream moves: a new commit in the stand-in repo, with a new plugin version.
# The pulled commit also changes what the patch verb prints, so the test can tell the pulled patch code from the code update was started with.
jq '.version = "9.9.9"' "$SRC/.claude-plugin/plugin.json" > "$SRC/p.json" && mv "$SRC/p.json" "$SRC/.claude-plugin/plugin.json" &&
  sed -i 's/^if \[ "\${1:-}" = patch \]; then$/& echo PATCH-CODE-V2 >\&2/' "$SRC/bin/lib/patch.sh" && grep -q PATCH-CODE-V2 "$SRC/bin/lib/patch.sh" &&
  git -C "$SRC" -c user.email=t@t -c user.name=t commit -qam bump || { echo "FAIL: could not bump the stand-in repo"; exit 1; }
rm -rf "$HOME/.claude-discord/runtime" "$HOME/.claude-discord/compat"; echo stale > "$HOME/.local/bin/claude-discord"
out=$(cd "$UP" && bash "$C/bin/claude-discord" update 2>&1) || { echo "FAIL: update failed: $out"; exit 1; }
grep -q PATCH-CODE-V2 <<<"$out" || { echo "FAIL: update must run the patch step from the code it just pulled: $out"; exit 1; }
grep -q -- '-> 9.9.9' <<<"$out" && grep -q '/reload-plugins' <<<"$out" && [ "$(grep -c -- "$PC" <<<"$out")" = 1 ] || { echo "FAIL: update must pull the source behind the link once and ask for /reload-plugins: $out"; exit 1; }
[ "$(jq -r .version "$PC/.claude-plugin/plugin.json")" = 9.9.9 ] && [ "$(jq -r .version "$CC/.claude-plugin/plugin.json")" != 9.9.9 ] || { echo "FAIL: update must pull the source and only the source"; exit 1; }
[ -s "$HOME/.claude-discord/runtime/discord-chunk.ts" ] && [ -s "$HOME/.claude-discord/runtime/discord-proxy.ts" ] && cmp -s "$D/shim/claude-discord" "$HOME/.local/bin/claude-discord" && [ -x "$HOME/.claude-discord/compat/hooks/turn/on-prompt" ] || { echo "FAIL: update must refill the runtime copy and the compat copy and refresh the shim"; exit 1; }
# --all: every recorded link and the clone, the source pulled once, a project removed since setup pruned, live records kept.
git -C "$SRC" -c user.email=t@t -c user.name=t commit -q --allow-empty -m again
printf '%s\n' "$HOME/gone proj/.claude/skills/claude-discord" >> "$HOME/.claude-discord/records/installs"
links=0; while IFS= read -r r; do [ "$(cd -P "$r" 2>/dev/null && pwd -P)" != "$PC" ] || links=$((links + 1)); done < "$HOME/.claude-discord/records/installs"
[ "$links" -ge 3 ] || { echo "FAIL: fixture: the records should hold several links to the source, got $links"; exit 1; }
out=$(cd "$UP" && bash "$C/bin/claude-discord" update --all 2>&1) || { echo "FAIL: update --all failed: $out"; exit 1; }
[ "$(grep -c -- "$PC" <<<"$out")" = 1 ] && [ "$(grep -c -- "$CC" <<<"$out")" = 1 ] && [ "$(grep -c -- ' -> ' <<<"$out")" = 2 ] || { echo "FAIL: update --all must pull each real clone once: $out"; exit 1; }
[ "$(git -C "$CC" rev-parse HEAD)" = "$(git -C "$SRC" rev-parse HEAD)" ] && ! grep -qF 'gone proj' "$HOME/.claude-discord/records/installs" && [ "$(wc -l < "$HOME/.claude-discord/records/installs" | tr -d ' ')" = "$((links + 1))" ] || { echo "FAIL: update --all must update the clone install, prune the removed project and keep the others"; exit 1; }
# A clone that cannot fast-forward is reported with exit 1 and does not stop the others.
git -C "$CC" -c user.email=t@t -c user.name=t commit -q --allow-empty -m local
git -C "$SRC" -c user.email=t@t -c user.name=t commit -q --allow-empty -m remote
div=$(git -C "$CC" rev-parse HEAD)
rc=0; out=$(cd "$UP" && bash "$C/bin/claude-discord" update --all 2>&1) || rc=$?
[ "$(git -C "$CC" rev-parse HEAD)" = "$div" ] && [ -z "$(git -C "$CC" status --porcelain)" ] || { echo "FAIL: a failed pull must leave the clone as it was"; exit 1; }
[ "$rc" = 1 ] && grep -q "$CC: pull failed" <<<"$out" && [ "$(git -C "$PC" rev-parse HEAD)" = "$(git -C "$SRC" rev-parse HEAD)" ] || { echo "FAIL: a diverged clone must exit 1, named, after the others were pulled (rc=$rc): $out"; exit 1; }
# A shim that cannot be refreshed is reported with exit 1 on its own.
git -C "$CC" reset -q --hard '@{u}'
echo stale > "$HOME/.local/bin/claude-discord"; chmod 555 "$HOME/.local/bin"
rc=0; out=$(cd "$UP" && bash "$C/bin/claude-discord" update --all 2>&1) || rc=$?
chmod 755 "$HOME/.local/bin"
[ "$rc" = 1 ] && grep -q 'could not install the shim' <<<"$out" && ! grep -q 'pull failed' <<<"$out" || { echo "FAIL: an unwritable shim must exit 1 with a message (rc=$rc): $out"; exit 1; }
# A clone pinned to a tag or sha (detached HEAD) is skipped by name and is not a failure; the others are still pulled.
git -C "$CC" checkout -q --detach; pin=$(git -C "$CC" rev-parse HEAD)
git -C "$SRC" -c user.email=t@t -c user.name=t commit -q --allow-empty -m after-pin
rc=0; out=$(cd "$UP" && bash "$C/bin/claude-discord" update --all 2>&1) || rc=$?
[ "$rc" = 0 ] && grep -q "$CC: pinned at ${pin:0:7}, skipped" <<<"$out" && [ "$(git -C "$CC" rev-parse HEAD)" = "$pin" ] && [ "$(git -C "$PC" rev-parse HEAD)" = "$(git -C "$SRC" rev-parse HEAD)" ] || { echo "FAIL: a detached clone must be skipped without failing the run (rc=$rc): $out"; exit 1; }
bash "$C/bin/claude-discord" update --bogus >/dev/null 2>&1 && { echo "FAIL: update takes only --all"; exit 1; }
# Pulled code older than the compat copy (1.8.0) would read 'compat' as a bot name: skipped with a line.
jq '.version = "1.7.9"' "$SRC/.claude-plugin/plugin.json" > "$SRC/p.json" && mv "$SRC/p.json" "$SRC/.claude-plugin/plugin.json" && git -C "$SRC" -c user.email=t@t -c user.name=t commit -qam old-version
rm -rf "$HOME/.claude-discord/compat"
rc=0; out=$(cd "$UP" && bash "$C/bin/claude-discord" update 2>&1) || rc=$?
[ "$rc" = 0 ] && grep -q 'before the compat copy (1.8.0)' <<<"$out" && [ ! -e "$HOME/.claude-discord/compat" ] || { echo "FAIL: update must skip compat from code before 1.8.0, with a line (rc=$rc): $out"; exit 1; }
rm -rf "$UP" "$UC"
echo "ok: --version prints the version and the clone's sha (a link's is the source's); update pulls the source behind a link once, runs the pulled commit's patch step, refills the runtime copy and the shim and asks for /reload-plugins; --all pulls each real clone once, prunes a removed project, skips a detached (pinned) clone without failing, and exits 1 on a diverged clone (left as it was) or an unwritable shim"

# --- the state move (1.18.0): a project's state lives in ~/.claude-discord/projects/<key>/ ------------------------------
# (a) the key is Claude Code's project folder name: every non-alphanumeric byte a dash, in the C locale (a table from lmd79).
pk() { bash -c '. "$1/bin/lib/state.sh"; proj_key "$2"' _ "$PC" "$1" 2>/dev/null; }
[ "$(pk /home/d.kim4)" = -home-d-kim4 ] && [ "$(pk /home/d.kim4/projects/my_dotfiles)" = -home-d-kim4-projects-my-dotfiles ] &&
  [ "$(pk /home/d.kim4/projects/hoi_trigger_codebase/.claude/worktrees/hoi-v2-pr)" = -home-d-kim4-projects-hoi-trigger-codebase--claude-worktrees-hoi-v2-pr ] &&
  [ "$(pk /home/d.kim4/projects/RobustAlwaysOn)" = -home-d-kim4-projects-RobustAlwaysOn ] && [ "$(pk /tmp)" = -tmp ] && [ "$(pk '/a b/c.d')" = -a-b-c-d ] &&
  [ "$(pk /x/a_b)" = -x-a-b ] && [ "$(pk /x/a.b)" = -x-a-b ] && [ "$(skey '/a b/c.d')" = -a-b-c-d ] ||
  { echo "FAIL: the key is Claude Code's folder encoding: every non-alphanumeric byte a dash: '$(pk /home/d.kim4)' '$(pk '/a b/c.d')' '$(pk /x/a_b)'"; exit 1; }
echo "ok: proj_key (bin/lib/state.sh) is Claude Code's project folder name: every non-alphanumeric byte a dash, in the C locale; a_b and a.b share one"
# (b) setup in a fresh project: the new layout, modes 700, nothing under the project's .claude but the install; the
# launcher's --settings names the new state dir.
NPJ="$HOME/new proj"; CA="$HOME/x/a_b"; CB2="$HOME/x/a.b"; mkdir -p "$NPJ" "$CA" "$CB2"
jq --arg a "$NPJ" --arg b "$CA" '.projects[$a].hasTrustDialogAccepted = true | .projects[$b].hasTrustDialogAccepted = true' "$HOME/.claude.json" > "$HOME/cj.tmp" && mv "$HOME/cj.tmp" "$HOME/.claude.json"
NS="$HOME/.claude-discord/projects/$(skey "$NPJ")"
(cd "$NPJ" && printf '\n4242\n111\n\ntokN\nn\n' | bash "$S" setup nbot --scope project >/dev/null 2>&1) || { echo "FAIL: setup in a fresh project failed"; exit 1; }
[ "$(cat "$NS/project" 2>/dev/null)" = "$NPJ" ] && grep -q "^DISCORD_CHANNEL_ID='4242'$" "$NS/config.env" && grep -q '^DISCORD_BOT_TOKEN=tokN$' "$NS/bots/nbot/.env" &&
  [ "$(jq -r '.groups["4242"].requireMention' "$NS/bots/nbot/access.json")" = true ] && [ "$(<"$NS/bots/nbot/mode")" = none ] &&
  [ "$(stat -c %a "$NS")" = 700 ] && [ "$(stat -c %a "$NS/bots")" = 700 ] && [ "$(stat -c %a "$NS/bots/nbot")" = 700 ] &&
  [ ! -e "$NPJ/.claude/discord-agents" ] && [ "$(ls -A "$NPJ/.claude")" = skills ] ||
  { echo "FAIL: setup and the start keep every bot file under ~/.claude-discord/projects/<key>, none under the project's .claude: $(find "$NPJ/.claude" "$NS" 2>&1)"; exit 1; }
out=$(cd "$NPJ" && bash "$S" --name nbot 2>&1)
grep -qF -- "\"DISCORD_STATE_DIR\": \"$NS/bots/nbot\"" <<<"$out" && [ ! -e "$NPJ/.claude/discord-agents" ] ||
  { echo "FAIL: setup and the start keep every bot file under ~/.claude-discord/projects/<key>, none under the project's .claude: the launcher must name the new state dir: $out"; exit 1; }
echo "ok: setup in a fresh project writes ~/.claude-discord/projects/<key>/{project,config.env,bots/<bot>} (700) and nothing under the project's .claude but the install; the start's --settings names it"
# (c) two paths with one key (a_b and a.b): the second setup is refused, naming both, and writes no bot file.
CK="$HOME/.claude-discord/projects/$(skey "$CB2")"; mkdir -p "$CK"; printf '%s\n' "$CB2" > "$CK/project"
rc=0; out=$(cd "$CA" && printf '\n1\n2\n\nt\nn\n' | bash "$S" setup cbot --scope project 2>&1) || rc=$?
[ "$rc" = 1 ] && grep -qF "$CA" <<<"$out" && grep -qF "$CB2" <<<"$out" && grep -q 'share one' <<<"$out" && [ "$(ls -A "$CK")" = project ] && [ ! -e "$CA/.claude/discord-agents" ] ||
  { echo "FAIL: two paths with one key: setup refuses the second (rc=$rc): $out / $(ls -A "$CK")"; exit 1; }
echo "ok: two projects whose paths share one key: setup refuses the second, naming both, and writes no bot file"
# (M-3) The collision must not keep a bot of the second project down: a start there says it and launches on the old path.
mkdir -p "$CA/.claude/discord-agents/cbot"; printf 'DISCORD_BOT_TOKEN=tc\n' > "$CA/.claude/discord-agents/cbot/.env"; echo none > "$CA/.claude/discord-agents/cbot/mode"; echo '{}' > "$CA/.claude/discord-agents/cbot/access.json"
printf "DISCORD_CHANNEL_ID='7'\nDISCORD_USER_ID='8'\nDISCORD_ALLOW_IDS=''\n" > "$CA/.claude/discord-agents/config.env"
out=$(cd "$CA" && bash "$S" --name cbot 2>&1) || :
grep -q 'share one' <<<"$out" && grep -qF -- "\"DISCORD_STATE_DIR\": \"$CA/.claude/discord-agents/cbot\"" <<<"$out" && [ -d "$CA/.claude/discord-agents/cbot" ] && [ ! -L "$CA/.claude/discord-agents/cbot" ] ||
  { echo "FAIL: a key collision must not stop a bot of the second project: the start says it and launches on the old path: $out"; exit 1; }
echo "ok: a start in a project whose key another project holds says so and launches on the old path (setup alone refuses)"
# (d) a project of the old shape (<project>/.claude/discord-agents/) with two bots, moved by compat: every bot dir by
# rename (same inode), config.env, peers.json and checkin/ with it, a link per bot whose old path a job record names, the
# hooks link gone, the .gitignore kept, a manager's records/monitor and scratch left where they are (Task 4 moves them
# with their readers), the records/projects line kept, and a second run changing nothing.
OLDP="$HOME/old shape"; OR="$OLDP/.claude/discord-agents"; mkdir -p "$OR/ob1/turns" "$OR/ob2/plugin-sessions" "$OR/checkin"
printf "DISCORD_CHANNEL_ID='7'\nDISCORD_USER_ID='8'\nDISCORD_ALLOW_IDS=''\n" > "$OR/config.env"; echo '{"peers":[]}' > "$OR/peers.json"; : > "$OR/checkin/s1"
printf 'DISCORD_BOT_TOKEN=t1\n' > "$OR/ob1/.env"; echo dev-manager > "$OR/ob1/mode"; printf '# ledger\nlocal\n' > "$OR/ob1/hosts"; echo '{}' > "$OR/ob1/access.json"; : > "$OR/ob1/turns/t1"
printf 'DISCORD_BOT_TOKEN=t2\n' > "$OR/ob2/.env"; echo none > "$OR/ob2/mode"; : > "$OR/ob2/plugin-sessions/p1"; printf '*\n' > "$OR/.gitignore"; ln -s "$PC/hooks" "$OR/hooks"
chmod 700 "$OR" "$OR/ob1" "$OR/ob2"; chmod 600 "$OR/ob1/.env" "$OR/ob2/.env"
MON1="$HOME/.claude-discord/records/monitor/ob1" SCR1="$HOME/.claude-discord/scratch/ob1"; mkdir -p "$MON1" "$SCR1"; : > "$SCR1/f"; : > "$MON1/stopped"
cp -a "$OR" "$HOME/old-shape.ref"; i1=$(stat -c %i "$OR/ob1"); i2=$(stat -c %i "$OR/ob2")
JOBS="$HOME/.claude/jobs"; mkdir -p "$JOBS/mv000001" "$JOBS/mv000002"
jq -n --arg s "{\"env\": {\"DISCORD_STATE_DIR\": \"$OR/ob1\"}}" '{sessionId: "0b100000-1111-2222-3333-444444444444", respawnFlags: ["--settings", $s]}' > "$JOBS/mv000001/state.json"
jq -n --arg s "{\"env\": {\"DISCORD_STATE_DIR\": \"$OR/ob2\"}}" '{sessionId: "0b200000-1111-2222-3333-444444444444", respawnFlags: ["--settings", $s]}' > "$JOBS/mv000002/state.json"
OPF=$HOME/.claude-discord/records/projects; OPFK=$(cat "$OPF" 2>/dev/null || :); printf '%s\n' "$OLDP" > "$OPF"
cp "$HOME/bin/claude" "$HOME/claude.before-move"; printf '#!/bin/bash\ncase $1 in agents) echo "[]";; *) echo "PLAIN $*";; esac\n' > "$HOME/bin/claude"   # no session of any bot runs
out=$(cd "$HOME" && bash "$S" compat 2>&1) || { echo "FAIL: compat failed: $out"; exit 1; }
OS="$HOME/.claude-discord/projects/$(skey "$OLDP")"
[ "$(cat "$OS/project" 2>/dev/null)" = "$OLDP" ] && diff -r "$HOME/old-shape.ref/ob1" "$OS/bots/ob1" >/dev/null 2>&1 && diff -r "$HOME/old-shape.ref/ob2" "$OS/bots/ob2" >/dev/null 2>&1 &&
  [ "$(stat -c %i "$OS/bots/ob1")" = "$i1" ] && [ "$(stat -c %i "$OS/bots/ob2")" = "$i2" ] && [ "$(stat -c %a "$OS/bots/ob1/.env")" = 600 ] &&
  cmp -s "$HOME/old-shape.ref/config.env" "$OS/config.env" && cmp -s "$HOME/old-shape.ref/peers.json" "$OS/peers.json" && [ -e "$OS/checkin/s1" ] &&
  [ "$(readlink "$OR/ob1")" = "$OS/bots/ob1" ] && [ "$(readlink "$OR/ob2")" = "$OS/bots/ob2" ] && [ ! -e "$OR/hooks" ] && [ ! -L "$OR/hooks" ] &&
  [ "$(<"$OR/.gitignore")" = "*" ] && [ ! -e "$OR/config.env" ] && [ ! -e "$OR/peers.json" ] && [ ! -e "$OR/checkin" ] &&
  [ "$(stat -c %a "$OS")" = 700 ] && [ "$(stat -c %a "$OS/bots")" = 700 ] && [ -e "$MON1/stopped" ] && [ -f "$SCR1/f" ] && grep -qxF "$OLDP" "$OPF" ||
  { echo "FAIL: compat moves a project's state by rename, leaves a link per bot, and is idempotent: $out / $(find "$OR" "$OS" 2>&1)"; exit 1; }
snap=$(find "$OR" "$OS" -printf '%p %y %m %i\n' | sort)
out2=$(cd "$HOME" && bash "$S" compat 2>&1) || { echo "FAIL: a second compat failed: $out2"; exit 1; }
[ "$(find "$OR" "$OS" -printf '%p %y %m %i\n' | sort)" = "$snap" ] || { echo "FAIL: compat moves a project's state by rename, leaves a link per bot, and is idempotent: the second run changed something: $out2"; exit 1; }
echo "ok: compat moves a 1.16 project's bots, config.env, peers.json and checkin/ into ~/.claude-discord/projects/<key>/ by rename, leaves a link per bot a job record names, drops the hooks link, keeps the .gitignore, touches no records/monitor or scratch, and a second run changes nothing"
# (g) the link goes only when no jobs/<id>/state.json names its old path; after the last, discord-agents/ and its .gitignore.
rm -rf "$JOBS/mv000002"
# (M-4) No job record, but a foreground session of ob2 on the old path (`claude agents` lists it with a pid, no id): kept, said.
printf '#!/bin/bash\ncase $1 in agents) echo %s;; *) echo "PLAIN $*";; esac\n' "'[{\"name\":\"ob2\",\"pid\":4242,\"cwd\":\"$(cd "$OLDP" && pwd -P)\"}]'" > "$HOME/bin/claude"
out=$(cd "$HOME" && bash "$S" compat 2>&1) || { echo "FAIL: compat failed: $out"; exit 1; }
[ "$(readlink "$OR/ob2")" = "$OS/bots/ob2" ] && grep -qF "$OR/ob2" <<<"$out" && grep -q 'a foreground session of ob2' <<<"$out" ||
  { echo "FAIL: a foreground session on the old path (no job record) keeps its link at compat, said: $out / $(ls -la "$OR" 2>&1)"; exit 1; }
# A row WITH a job id whose record names the NEW path (lmd79 after the live move: photo-bot's a890d472) is a background
# session on the new place already, found by its name: no reason to keep the link.
mkdir -p "$JOBS/ob200002"; jq -n --arg s "{\"env\": {\"DISCORD_STATE_DIR\": \"$OS/bots/ob2\"}}" '{sessionId: "0b500000-1111-2222-3333-444444444444", respawnFlags: ["--settings", $s]}' > "$JOBS/ob200002/state.json"
printf '#!/bin/bash\ncase $1 in agents) echo %s;; *) echo "PLAIN $*";; esac\n' "'[{\"name\":\"ob2\",\"id\":\"ob200002\",\"pid\":4242,\"cwd\":\"$(cd "$OLDP" && pwd -P)\"}]'" > "$HOME/bin/claude"
out=$(cd "$HOME" && bash "$S" compat 2>&1) || { echo "FAIL: compat failed: $out"; exit 1; }
[ ! -L "$OR/ob2" ] && [ ! -e "$OR/ob2" ] && ! grep -q 'foreground' <<<"$out" || { echo "FAIL: a live row with a job id whose record names the new path is no reason to keep the link: $out / $(ls -la "$OR" 2>&1)"; exit 1; }
rm -rf "$JOBS/ob200002"
printf '#!/bin/bash\ncase $1 in agents) echo "[]";; *) echo "PLAIN $*";; esac\n' > "$HOME/bin/claude"
out=$(cd "$HOME" && bash "$S" compat 2>&1) || { echo "FAIL: compat failed: $out"; exit 1; }
[ ! -L "$OR/ob2" ] && [ ! -e "$OR/ob2" ] && [ "$(readlink "$OR/ob1")" = "$OS/bots/ob1" ] && [ -d "$OS/bots/ob2" ] && grep -q mv000001 <<<"$out" && grep -qF "$OR/ob1" <<<"$out" ||
  { echo "FAIL: the old path goes only when no job record names it: $out / $(ls -la "$OR" 2>&1)"; exit 1; }
rm -rf "$JOBS/mv000001"
out=$(cd "$HOME" && bash "$S" compat 2>&1) || { echo "FAIL: compat failed: $out"; exit 1; }
[ ! -e "$OR" ] && [ ! -L "$OR" ] && [ -d "$OLDP/.claude" ] && [ -d "$OS/bots/ob1" ] || { echo "FAIL: the old path goes only when no job record names it: with none left, discord-agents/ and its .gitignore go: $(ls -la "$OLDP/.claude" 2>&1)"; exit 1; }
echo "ok: a bot's old-path link stays while a jobs/<id>/state.json names it (compat says which job), goes when none does, and the empty discord-agents/ with its .gitignore after the last"
# (M-2) A move cut between the rename and the link (bots/ob2 there, no link) is repaired by the next compat when a job record
# names the old path; (I-1) the record holds the start's LOGICAL $PWD, here the project through a link: the path's last
# part decides, not its spelling.
mkdir -p "$OR" "$HOME/lnk"; printf '*\n' > "$OR/.gitignore"; ln -s "$OLDP" "$HOME/lnk/old"
mkdir -p "$JOBS/mv000003"; jq -n --arg s "{\"env\": {\"DISCORD_STATE_DIR\": \"$HOME/lnk/old/.claude/discord-agents/ob2\"}}" '{sessionId: "0b400000-1111-2222-3333-444444444444", respawnFlags: ["--settings", $s]}' > "$JOBS/mv000003/state.json"
out=$(cd "$HOME" && bash "$S" compat 2>&1) || { echo "FAIL: compat failed: $out"; exit 1; }
[ "$(readlink "$OR/ob2")" = "$OS/bots/ob2" ] && grep -qF "$OR/ob2" <<<"$out" && [ ! -e "$OR/ob1" ] ||
  { echo "FAIL: a move cut before its link is repaired by compat when a job record (in any spelling of the project path) names the old path, said: $out / $(ls -la "$OR" 2>&1)"; exit 1; }
rm -rf "$JOBS/mv000003"
out=$(cd "$HOME" && bash "$S" compat 2>&1) || { echo "FAIL: compat failed: $out"; exit 1; }
[ ! -e "$OR" ] && [ ! -L "$OR" ] || { echo "FAIL: the repaired link goes as any other once its record is gone: $(ls -la "$OR" 2>&1)"; exit 1; }
echo "ok: compat makes the per-bot link again when a move was cut before it and a job record names the old path in any spelling of the project path; it goes with the record"
# (M-1) The lock is taken before anything is written: a held lock leaves the old shape whole, the start says so and runs on it.
OLDL="$HOME/old lock"; LR="$OLDL/.claude/discord-agents"; mkdir -p "$LR/lb"; printf 'DISCORD_BOT_TOKEN=tl\n' > "$LR/lb/.env"; echo none > "$LR/lb/mode"; echo '{}' > "$LR/lb/access.json"
printf "DISCORD_CHANNEL_ID='7'\nDISCORD_USER_ID='8'\nDISCORD_ALLOW_IDS=''\n" > "$LR/config.env"
LS="$HOME/.claude-discord/projects/$(skey "$OLDL")"; mkdir -p "$LS.lock"
out=$(cd "$OLDL" && bash "$S" --name lb 2>&1) || :
grep -q 'lock is held' <<<"$out" && grep -qF -- "\"DISCORD_STATE_DIR\": \"$LR/lb\"" <<<"$out" && [ ! -e "$LS/project" ] && [ -d "$LR/lb" ] && [ ! -L "$LR/lb" ] && [ -f "$LR/config.env" ] ||
  { echo "FAIL: a held <key>.lock must leave the old shape whole (no project file written) and the start say it and run on the old path: $out / $(find "$LS" "$LR" 2>&1)"; exit 1; }
rmdir "$LS.lock"
out=$(cd "$OLDL" && bash "$S" --name lb 2>&1)
grep -qF -- "\"DISCORD_STATE_DIR\": \"$LS/bots/lb\"" <<<"$out" && [ -f "$LS/bots/lb/.env" ] || { echo "FAIL: with the lock gone the next start moves the project: $out"; exit 1; }
echo "ok: a held <key>.lock leaves a 1.16 project whole (nothing written under the key), the start says it and runs on the old path; the next start moves it"
# (h) another filesystem (rename(2) refused; a perl stub refuses the move's rename): a bot with a live session is left in
# place and said; with none, copied, compared, the source removed and the link made.
OLDX="$HOME/old xdev"; XR="$OLDX/.claude/discord-agents"; mkdir -p "$XR/xb"; printf 'DISCORD_BOT_TOKEN=tx\n' > "$XR/xb/.env"; echo none > "$XR/xb/mode"; printf 'a\nb\n' > "$XR/xb/handoff.md"
printf "DISCORD_CHANNEL_ID='7'\nDISCORD_USER_ID='8'\n" > "$XR/config.env"
REALPERL=$(command -v perl); printf '#!/bin/bash\ncase "$*" in *"rename \\$ARGV[0], \\$ARGV[1]"*) exit 1;; esac\nexec %q "$@"\n' "$REALPERL" > "$HOME/bin/perl"; chmod +x "$HOME/bin/perl"
cp "$HOME/bin/claude" "$HOME/claude.before-xdev"
printf '#!/bin/bash\ncase $1 in agents) echo %s;; *) echo "PLAIN $*";; esac\n' "'[{\"name\":\"xb\",\"id\":\"xb000001\",\"pid\":1,\"cwd\":\"$OLDX\",\"state\":\"working\"}]'" > "$HOME/bin/claude"
printf '%s\n' "$OLDX" > "$OPF"
out=$(cd "$HOME" && bash "$S" compat 2>&1) || { echo "FAIL: compat failed: $out"; exit 1; }
XS="$HOME/.claude-discord/projects/$(skey "$OLDX")"
[ -d "$XR/xb" ] && [ ! -L "$XR/xb" ] && [ ! -e "$XS/bots/xb" ] && [ "$(cat "$XS/project" 2>/dev/null)" = "$OLDX" ] && [ -f "$XS/config.env" ] && grep -qF "$XR/xb" <<<"$out" && grep -q 'session' <<<"$out" ||
  { echo "FAIL: a cross-filesystem move of a running bot waits: $out / $(find "$XR" "$XS" 2>&1)"; exit 1; }
printf '#!/bin/bash\ncase $1 in agents) echo "[]";; *) echo "PLAIN $*";; esac\n' > "$HOME/bin/claude"
mkdir -p "$JOBS/xb000001"; jq -n --arg s "{\"env\": {\"DISCORD_STATE_DIR\": \"$XR/xb\"}}" '{sessionId: "0b300000-1111-2222-3333-444444444444", respawnFlags: ["--settings", $s]}' > "$JOBS/xb000001/state.json"
out=$(cd "$HOME" && bash "$S" compat 2>&1) || { echo "FAIL: compat failed: $out"; exit 1; }
[ "$(readlink "$XR/xb")" = "$XS/bots/xb" ] && [ "$(<"$XS/bots/xb/handoff.md")" = $'a\nb' ] && [ "$(<"$XS/bots/xb/.env")" = DISCORD_BOT_TOKEN=tx ] && [ -z "$(ls -A "$XS/bots" | command grep '^\.')" ] ||
  { echo "FAIL: with no live session a bot on another filesystem is copied, compared and replaced by a link: $out / $(find "$XR" "$XS" 2>&1)"; exit 1; }
rm -f "$HOME/bin/perl"; cp "$HOME/claude.before-move" "$HOME/bin/claude"; rm -f "$HOME/claude.before-xdev" "$HOME/claude.before-move"; rm -rf "$JOBS/xb000001"
echo "ok: a bot whose directory cannot be renamed (another filesystem) is left in place and said while a session of it runs, and copied, compared and linked once none does"
# A start in a project of the old shape moves it first (no job record names the bot: no link is left) and launches on the new path.
OLDS="$HOME/old start"; SR2="$OLDS/.claude/discord-agents"; mkdir -p "$SR2/sb"; printf 'DISCORD_BOT_TOKEN=ts\n' > "$SR2/sb/.env"; echo none > "$SR2/sb/mode"; echo '{}' > "$SR2/sb/access.json"
printf "DISCORD_CHANNEL_ID='7'\nDISCORD_USER_ID='8'\nDISCORD_ALLOW_IDS=''\n" > "$SR2/config.env"
out=$(cd "$OLDS" && bash "$S" --name sb 2>&1)
SS="$HOME/.claude-discord/projects/$(skey "$OLDS")"
grep -qF -- "\"DISCORD_STATE_DIR\": \"$SS/bots/sb\"" <<<"$out" && [ -f "$SS/bots/sb/.env" ] && [ -f "$SS/config.env" ] && [ ! -e "$OLDS/.claude/discord-agents" ] ||
  { echo "FAIL: a start in a project of the old shape moves it first and starts on the new path: $out / $(find "$OLDS" "$SS" 2>&1)"; exit 1; }
printf '%s\n' "$OPFK" > "$OPF"
echo "ok: a start in a 1.16-shaped project moves its state first and launches on the new path"


# --- the two cases of the state move that start a plugin server (moved here from the core file, 1.18.0) ---------------
# A project with one bot, as the core file's single-project (the install questions skipped: this file's earlier cases
# leave the trust and install state in another place than the core's); the health run below reads it from its root.
SP="$HOME/single-project"; mkdir -p "$SP"; cd "$SP"
printf '900\n111\n222\ntokS\nn\n' | CLAUDE_DISCORD_SETUP_NOASK=1 bash "$S" setup sbot --scope project >/dev/null 2>&1 || { echo "FAIL: fixture: the setup of single-project failed"; exit 1; }
SD="$(bdir "$SP" "sbot")"
echo "$ID_SEEN" > "$SD/last-message-id"; seed_id "$SD"; seed_guild "$SD"
start_server "$SD"   # as in the core file: the case below counts this one too
# 1.18.0: a server whose environ names the bot's path before the move (<project>/.claude/discord-agents/<bot>: a job
# respawned on it) counts as one on the path after it does: a moved bot never reads as down.
NEWSD="$HOME/.claude-discord/projects/$(skey "$SP")/bots/sbot" OLDSD="$SP/.claude/discord-agents/sbot"
mkdir -p "${OLDSD%/*}"; ln -s "$NEWSD" "$OLDSD"   # the link the move leaves while a job record names the old path; without it such a server reads as down (accepted)
start_server "$OLDSD"; start_server "$NEWSD"
queue "200 $NONE" '200 {"threads":[]}'
out=$(bash "$S" health --json 2>/dev/null) || :
[ "$(field_of sbot servers "$out")" = 3 ] || { echo "FAIL: health counts a server under either path: $(field_of sbot servers "$out") servers: $out"; exit 1; }
stop_one_server "$NEWSD"; stop_one_server "$OLDSD"; rm -rf "$SP/.claude/discord-agents"
echo "ok: health counts a bun server whose DISCORD_STATE_DIR is the bot's path before the move (through the link the move left) as well as one on its path after it"
# (I-1) A 1.17 job record and a server's environ hold the start's LOGICAL $PWD: a project reached through a link is recorded
# (records/projects, pwd -P) as the real path, while the record and the environ name the link's. compat keeps the per-bot
# link, health counts the server, --resume finds the bot: the path's last part and what it resolves to decide, not its spelling.
RP="$HOME/real/p3"; LP="$HOME/link/p3"; RB="$RP/.claude/discord-agents/b"; mkdir -p "$RB" "$HOME/link"; ln -s "$RP" "$LP"
jq --arg p "$(cd "$RP" && pwd -P)" '.projects[$p].hasTrustDialogAccepted = true' "$HOME/.claude.json" > "$HOME/cj.tmp" && mv "$HOME/cj.tmp" "$HOME/.claude.json"   # a --bg start checks the trust
printf "DISCORD_CHANNEL_ID='900'\nDISCORD_USER_ID='111'\nDISCORD_ALLOW_IDS=''\n" > "$RP/.claude/discord-agents/config.env"
printf 'DISCORD_BOT_TOKEN=tokP3\n' > "$RB/.env"; echo none > "$RB/mode"; jq -n '{dmPolicy:"allowlist", allowFrom:["111"], groups:{"900":{requireMention:true, allowFrom:["111"]}}}' > "$RB/access.json"
echo "$ID_SEEN" > "$RB/last-message-id"; seed_id "$RB"; seed_guild "$RB"
mkdir -p "$HOME/.claude/jobs/lk000001"; jq -n --arg s "{\"env\": {\"DISCORD_STATE_DIR\": \"$LP/.claude/discord-agents/b\"}}" '{sessionId: "1111aaaa-2222-3333-4444-555555555555", respawnFlags: ["--settings", $s]}' > "$HOME/.claude/jobs/lk000001/state.json"
RPF="$HOME/.claude-discord/records/projects"; cp "$RPF" "$HOME/rpf.keep"; printf '%s\n' "$(cd "$RP" && pwd -P)" >> "$RPF"
out=$(cd "$HOME" && bash "$S" compat 2>&1) || { echo "FAIL: compat failed: $out"; exit 1; }
RBN="$HOME/.claude-discord/projects/$(skey "$RP")/bots/b"
[ "$(readlink "$RB")" = "$RBN" ] && grep -q lk000001 <<<"$out" || { echo "FAIL: a job record naming the old path through a link of the project must keep the bot's link: $out / $(ls -la "$RP/.claude/discord-agents" 2>&1)"; exit 1; }
start_server "$LP/.claude/discord-agents/b"
queue "200 $NONE" '200 {"threads":[]}'
out=$(cd "$RP" && bash "$S" health --json 2>"$HOME/health.err") || :
[ "$(field_of b servers "$out")" = 1 ] || { echo "FAIL: health must count a server whose environ names the old path through a link of the project: $out"; exit 1; }
# A real server's environ is NUL-separated: the one grep that reads it must leave nothing on stderr (1.18.0 on lmd42:
# "warning: command substitution: ignored null byte in input", once per server per bot per run).
[ ! -s "$HOME/health.err" ] || { echo "FAIL: health must say nothing on stderr while counting a real server's environ: $(head -c 300 "$HOME/health.err")"; exit 1; }
stop_one_server "$LP/.claude/discord-agents/b"
mkdir -p "${RBN%/b}/c"; printf 'DISCORD_BOT_TOKEN=tokC\n' > "${RBN%/b}/c/.env"; echo none > "${RBN%/b}/c/mode"   # a second bot: with one, a start picks it with no record at all
out=$(cd "$RP" && bash "$S" --bg --resume 1111aaaa-2222-3333-4444-555555555555 2>&1) || :   # the launcher stub prints the exec line; the claude stub here refuses a launch
grep -q -- '-n b' <<<"$out" || { echo "FAIL: --resume must find the bot from a job record naming the old path through a link of the project: $out"; exit 1; }
cp "$HOME/rpf.keep" "$RPF"; rm -rf "$HOME/rpf.keep" "$HOME/.claude/jobs/lk000001" "$HOME/link" "$HOME/real"
echo "ok: a job record and a server environ naming the old path in the start's logical spelling (the project through a link) keep the link at compat, count in health and resolve --resume"
stop_servers

# Nothing this suite started is still running at the end: a case that detached a keeper or a monitor and did not stop it fails
# here, by name of the process (sandbox_pids: the sandbox in its argv or as its HOME; an orphaned
# `/bin/sleep 30` names no path of the suite's). Then the reaping itself, which every exit path runs (the EXIT trap): a decoy
# detached the way a keeper is (a subshell that exits, so init adopts it; the sandbox in its argv) must be seen first, or the
# last check could not fail, and reap_sandbox must take it down. Without the reaping that check fails.
strays() { local p; for p in $(sandbox_pids); do ps -o pid=,ppid=,args= -p "$p" || :; done; }
kill $KILL_AT_EXIT 2>/dev/null || :; KILL_AT_EXIT=""
for _ in $(seq 20); do left=$(strays); [ -z "$left" ] && break; nap 0.1; done
[ -z "$left" ] || { echo "FAIL: processes left behind: $(strays)"; exit 1; }
printf '/bin/sleep 3.%s; :\n' $$ > "$HOME/reapme.sh"
( bash "$HOME/reapme.sh" </dev/null >/dev/null 2>&1 & )
for _ in $(seq 20); do [ -z "$(sandbox_pids)" ] || break; nap 0.05; done
[ -n "$(strays)" ] || { echo "FAIL: a detached decoy with the sandbox in its argv is not seen, so the check below proves nothing"; exit 1; }
reap_sandbox
[ -z "$(strays)" ] || { echo "FAIL: reap_sandbox left behind: $(strays)"; exit 1; }
echo "ok: no process is left behind"

echo "ALL PASS"
