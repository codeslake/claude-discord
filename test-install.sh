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
# And one patched by 1.14.0 to 1.19.x (0.0.8), whose login rethrew any other error, which ended the server.
OLD1190=';(async () => { let bad = ""; const read = () => { let m; try { m = readFileSync(ENV_FILE, "utf8").match(/^DISCORD_BOT_TOKEN=(.+)$/m) } catch {} return m?.[1].trim() || "" }; const pick = () => { const v = bad ? read() : (TOKEN || read()); return v && v !== bad ? v : "" }; for (;;) { const t = await new Promise<string>(ok => { const v = pick(); if (v) return ok(v); const i = setInterval(() => { const w = pick(); if (w) { clearInterval(i); ok(w) } }, 10000) }); try { await client.login(t); await new Promise<void>(ok => { const f = (ev: any) => { if (ev?.code === 4004) { client.off("shardDisconnect", f); ok() } }; client.on("shardDisconnect", f) }); bad = t; process.stderr.write("discord channel: the gateway refused the token (4004); waiting for a new one in .env (re-read every 10 s)\n") } catch (e) { if ((e as any)?.code !== "TokenInvalid") throw e; bad = t; process.stderr.write("discord channel: the token was refused; waiting for a new one in .env (re-read every 10 s)\n") } } })().catch('
mkdir -p "$PCACHE/0.0.8"
CD_OLD=$OLD1190 perl -0777 -pe 's/^  process\.exit\(1\)\n\}\n/  process.stderr.write("discord channel: no token yet; waiting for it (re-read every 10 s)\\n")\n}\n/m; s/^client\.login\(TOKEN\)\.catch\(/$ENV{CD_OLD}/m' "$HOME/server.ts.pristine" > "$PCACHE/0.0.8/server.ts"
grep -qF 'TokenInvalid") throw e;' "$PCACHE/0.0.8/server.ts" || { echo "FAIL: the 1.14-1.19 fixture was not planted: $(<"$PCACHE/0.0.8/server.ts")"; exit 1; }
out=$(bash "$S" patch 2>&1) && grep -qF "$PCACHE/0.0.3/server.ts" <<<"$out" && ! grep -qF '.then(t => client.login(t))' "$PCACHE/0.0.3/server.ts" &&
  [ "$(grep -c 'code !== "TokenInvalid"' "$PCACHE/0.0.3/server.ts")" = 1 ] && grep -qF '})().catch(err => {' "$PCACHE/0.0.3/server.ts" &&
  [ "$(grep -c 'no token yet; waiting for it' "$PCACHE/0.0.3/server.ts")" = 1 ] && [ "$(grep -c 'process.exit(1)' "$PCACHE/0.0.3/server.ts")" = 1 ] || { echo "FAIL: patch must upgrade a 1.9.3 login to the refused-token loop: $out $(<"$PCACHE/0.0.3/server.ts")"; exit 1; }
grep -qF "$PCACHE/0.0.2/server.ts" <<<"$out" && ! grep -qF 'return await client.login(t)' "$PCACHE/0.0.2/server.ts" && [ "$(grep -c 'client.on("shardDisconnect", f)' "$PCACHE/0.0.2/server.ts")" = 1 ] &&
  [ "$(grep -c 'code !== "TokenInvalid"' "$PCACHE/0.0.2/server.ts")" = 1 ] && grep -qF '})().catch(err => {' "$PCACHE/0.0.2/server.ts" || { echo "FAIL: patch must upgrade a 1.9.4 login to the one that waits out a 4004 too: $out $(<"$PCACHE/0.0.2/server.ts")"; exit 1; }
grep -qF "$PCACHE/0.0.8/server.ts" <<<"$out" && ! grep -qF 'TokenInvalid") throw e;' "$PCACHE/0.0.8/server.ts" && [ "$(grep -c 'login failed (' "$PCACHE/0.0.8/server.ts")" = 1 ] &&
  [ "$(grep -c 'code !== "TokenInvalid"' "$PCACHE/0.0.8/server.ts")" = 1 ] && grep -qF '})().catch(err => {' "$PCACHE/0.0.8/server.ts" || { echo "FAIL: patch must upgrade a 1.14-1.19 login to the one that retries any other login error: $out $(<"$PCACHE/0.0.8/server.ts")"; exit 1; }
out=$(bash "$S" patch 2>&1) && [ -z "$out" ] || { echo "FAIL: a second patch after the 1.9.3 and 1.9.4 upgrades must change nothing: $out"; exit 1; }
rm -rf "$PCACHE/0.0.3" "$PCACHE/0.0.2" "$PCACHE/0.0.8"
echo "ok: patch upgrades a server.ts 1.9.3 patched to wait out a refused token, one 1.9.4 to 1.13.x patched to wait out a 4004 after the login too, and one 1.14 to 1.19.x patched to retry any other login error; a second run is silent"
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

# A machine with the 1.8-1.16 install (5b, 1.18.1): compat (every update) removes ~/.claude-discord/hooks (a directory of
# links into compat/, or the 1.8 copies), compat/ and its leftovers (compat.*) and the old rule copies; keeps
# discord-chunk.ts and discord-proxy.ts as links into runtime/ (a bun server patched before 1.9 imports the chunk module
# from there at its next long reply, and that running process cannot be re-patched), the bots' scratch, records, runtime
# and the source clone. A symlink at hooks/ (a dev checkout) goes as a link, its target untouched; a compat/ that holds a
# git tree (a clone put there by hand) is left, said. `patch --compat` (a 1.17 on-session-start from a stale clone still
# sends it) is plain patch: exit 0, silent.
OH="$HOME/.claude-discord"
rm -rf "$OH/hooks" "$OH/rules" "$OH/discord-chunk.ts" "$OH/discord-proxy.ts"
mkdir -p "$OH/scratch/b" "$OH/rules" "$OH/hooks/tools" "$OH/compat/hooks/turn" "$OH/compat.new.1/old" "$OH/compat.lock"
for t in turn peers lib autoresearchclaw; do mkdir -p "$OH/hooks/$t"; echo old > "$OH/hooks/$t/stale"; done
: > "$OH/scratch/b/note"; echo old > "$OH/hooks/tools/thread"; : > "$OH/rules/dev-manager.md"; echo old > "$OH/discord-chunk.ts"; echo old > "$OH/discord-proxy.ts"; echo old > "$OH/compat/hooks/turn/on-prompt"
out=$(cd "$HOME" && bash "$S" compat 2>&1) || { echo "FAIL: compat failed: $out"; exit 1; }
[ ! -e "$OH/hooks" ] && [ ! -L "$OH/hooks" ] && [ ! -e "$OH/compat" ] && [ ! -e "$OH/compat.new.1" ] && [ ! -e "$OH/compat.lock" ] && [ ! -e "$OH/rules" ] &&
  [ "$(readlink "$OH/discord-chunk.ts")" = "$OH/runtime/discord-chunk.ts" ] && [ "$(readlink "$OH/discord-proxy.ts")" = "$OH/runtime/discord-proxy.ts" ] &&
  cmp -s "$OH/discord-chunk.ts" "$PC/runtime/discord-chunk.ts" && cmp -s "$OH/discord-proxy.ts" "$PC/runtime/discord-proxy.ts" &&
  [ -e "$OH/scratch/b/note" ] && [ -d "$OH/source/.git" ] && [ -d "$OH/records" ] ||
  { echo "FAIL: compat removes the old install copies and keeps the runtime links: $out / $(ls -la "$OH" 2>&1)"; exit 1; }
mkdir -p "$HOME/old-target/hooks/turn" "$OH/compat/.git"; : > "$HOME/old-target/hooks/turn/on-prompt"; ln -s "$HOME/old-target/hooks" "$OH/hooks"
out=$(cd "$HOME" && bash "$S" compat 2>&1) || { echo "FAIL: compat failed: $out"; exit 1; }
[ ! -L "$OH/hooks" ] && [ ! -e "$OH/hooks" ] && [ -e "$HOME/old-target/hooks/turn/on-prompt" ] && [ -d "$OH/compat/.git" ] && grep -q 'compat holds a git tree' <<<"$out" ||
  { echo "FAIL: a symlinked hooks goes as a link, its target untouched, and a compat/ holding a git tree is left, said: $out / $(ls -la "$OH" "$HOME/old-target/hooks/turn" 2>&1)"; exit 1; }
rm -rf "$OH/compat" "$HOME/old-target"
out=$(bash "$S" patch --compat 2>&1) && [ -z "$out" ] || { echo "FAIL: patch --compat (a 1.17 on-session-start from a stale clone) is plain patch: exit 0, silent: $out"; exit 1; }
echo "ok: compat removes ~/.claude-discord/hooks, compat/ with its leftovers and the old rule copies (a symlinked hooks as a link, a compat/ holding a git tree left and said), keeps the two runtime links, scratch, records and the source clone; patch --compat is plain patch"

# setup --mode: changes only a set-up bot's mode. A fresh project, so these
# assertions are not entangled with any other bot's state.
P5="$HOME/project5"; mkdir -p "$P5"; cd "$P5"
jq -n --arg p5 "$PHOME/project5" '{projects: {($p5): {hasTrustDialogAccepted: true}}}' > "$HOME/.claude.json"
R5=$HOME/.claude-discord/projects/$(skey "$P5")/bots   # by hand, not broot: the first case asserts that nothing made the key dir
SL5="$P5/.claude/settings.local.json"

out=$(printf '' | bash "$S" setup nosetup --mode 2>&1) && { echo "FAIL: --mode on a bot that is not set up should refuse"; exit 1; }
rc=$?
[ "$rc" -eq 2 ] && grep -qF "run 'claude-discord setup nosetup' first" <<<"$out" || { echo "FAIL: --mode on an unset bot must exit 2 with a hint, got rc=$rc: $out"; exit 1; }
[ ! -e "$HOME/.claude-discord/projects/$(skey "$P5")" ] && [ ! -e "$P5/.claude/discord-agents" ] || { echo "FAIL: --mode on an unset bot must create nothing (no key dir, bot dir or config.env): $(find "$HOME/.claude-discord/projects/$(skey "$P5")" "$P5/.claude" 2>&1)"; exit 1; }
echo "ok: --mode on a bot that is not set up exits 2 with a hint and creates nothing"
# 1.18.4 (the peer's pmac report): `setup --help` read --help as the bot's name, installed, made the key dir and waited
# at the token prompt. --help/-h print the usage line; a name starting with - is refused (exit 2) before anything is
# installed or made, by setup and by a launch alike.
for a in --help -h; do
  rc=0; out=$(printf '' | bash "$S" setup $a 2>&1) || rc=$?
  [ "$rc" = 2 ] && [ "$out" = "usage: claude-discord setup <name> [--scope project|global] [--method link|clone] [--reset|--mode]" ] || { echo "FAIL: setup $a prints the usage line, exit 2: rc=$rc $out"; exit 1; }
done
rc=0; out=$(printf '' | bash "$S" setup -x 2>&1) || rc=$?
[ "$rc" = 2 ] && grep -q "bot name must be a plain directory name" <<<"$out" || { echo "FAIL: setup refuses a name starting with -, exit 2: rc=$rc $out"; exit 1; }
rc=0; out=$(bash "$S" --name -x 2>&1) || rc=$?
[ "$rc" = 2 ] && grep -q "bot name must be a plain directory name" <<<"$out" || { echo "FAIL: a launch refuses a name starting with -, exit 2: rc=$rc $out"; exit 1; }
[ ! -e "$HOME/.claude-discord/projects/$(skey "$P5")" ] && [ ! -e "$P5/.claude" ] && [ ! -e "$HOME/.claude-discord/projects/$(skey "$P5")/bots/--help" ] || { echo "FAIL: setup --help, -h and -x must create nothing: $(find "$HOME/.claude-discord/projects/$(skey "$P5")" "$P5/.claude" 2>&1 | head -5)"; exit 1; }
echo "ok: setup --help and -h print the usage line; a bot name starting with - is refused by setup and by a launch before anything is made"

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

# A group whose allowFrom is not a list (a hand edit) is left as it is: it must not stop the other groups from getting their peers
# (jq failed on it and "could not update ... leaving it alone" kept all of them from it). And the bot is left out of the peers by its
# bot-id when it is kept: a peer named five with another id (702) is a peer.
cp "$R5/five/access.json" "$P5/five.access.keep"; cp "$(pstate "$P5")/peers.json" "$P5/five.peers.keep"
jq -c '.groups["2"] = {allowFrom: "111 222"} | .groups["3"] = {allowFrom: ["222"]} | .groups["4"] = 7' "$P5/five.access.keep" > "$R5/five/access.json"
printf '900\n' > "$R5/five/bot-id"
out=$(printf 'dev-manager\nperty:701:801:host,five:702:802:host,perta:900:803:host\n' | bash "$S" setup five --mode 2>&1) || :
[ "$(jq -c '.groups["3"].allowFrom, .groups["1"].allowFrom, .groups["2"].allowFrom, .groups["4"]' "$R5/five/access.json" | tr '\n' ' ')" = '["222","700","701","702"] ["222","700","701","702"] "111 222" 7 ' ] ||
  { echo "FAIL: the peers (not the bot's own id 900) must go into every list group while a group whose allowFrom is a string or a number stays as it is: $(jq -c .groups "$R5/five/access.json") / $out"; exit 1; }
rm -f "$R5/five/bot-id"; cp "$P5/five.access.keep" "$R5/five/access.json"; cp "$P5/five.peers.keep" "$(pstate "$P5")/peers.json"; rm -f "$P5/five.access.keep" "$P5/five.peers.keep"
echo "ok: setup's peer merge skips a group whose allowFrom is no list and still adds the peers to the others, and leaves the bot out by its bot-id"

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
# Run the clone's own wrapper: it is the one whose self_root is the clone.
(cd "$GP" && printf '\nn\n' | bash "$GL/bin/claude-discord" setup gbot >/dev/null 2>&1) || { echo "FAIL: a re-run of the global clone's own wrapper failed"; exit 1; }
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

# install: the plugin, shim and runtime, asking nothing (stdin is left unread) and writing no bot
# file; a re-run is the same. A setup whose clone fails writes no bot file: the install comes before the questions.
IP="$HOME/inst proj"; FP="$HOME/fail proj"; mkdir -p "$IP" "$FP"
jq --arg p "$PHOME/inst proj" '.projects[$p].hasTrustDialogAccepted = true' "$HOME/.claude.json" > "$HOME/cj.tmp" && mv "$HOME/cj.tmp" "$HOME/.claude.json"
for _ in 1 2; do
  rc=0; left=$(printf 'leftover\n' | { (cd "$IP" && bash "$S" install --scope project --method link >"$HOME/inst.out" 2>&1) || rc=$?; cat; })
  [ "$rc" = 0 ] && [ "$left" = leftover ] && [ "$(readlink "$IP/.claude/skills/claude-discord")" = "$HOME/.claude-discord/source" ] && [ ! -e "$IP/.claude/discord-agents" ] || { echo "FAIL: install must install, read nothing from stdin and write no bot file (rc=$rc, left=$left): $(<"$HOME/inst.out")"; exit 1; }
done
grep -qxF "$IP/.claude/skills/claude-discord" "$HOME/.claude-discord/records/installs" && cmp -s "$D/shim/claude-discord" "$HOME/.local/bin/claude-discord" && [ ! -e "$HOME/.claude-discord/compat" ] && [ ! -e "$HOME/.claude-discord/hooks" ] || { echo "FAIL: install must record the install, refresh the shim and leave no compat copy"; exit 1; }
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
rm -rf "$HOME/.claude-discord/runtime"; echo stale > "$HOME/.local/bin/claude-discord"
out=$(cd "$UP" && bash "$C/bin/claude-discord" update 2>&1) || { echo "FAIL: update failed: $out"; exit 1; }
grep -q PATCH-CODE-V2 <<<"$out" || { echo "FAIL: update must run the patch step from the code it just pulled: $out"; exit 1; }
grep -q -- '-> 9.9.9' <<<"$out" && grep -q '/reload-plugins' <<<"$out" && [ "$(grep -c -- "$PC" <<<"$out")" = 1 ] || { echo "FAIL: update must pull the source behind the link once and ask for /reload-plugins: $out"; exit 1; }
# 1.18.5: the advice works on a machine without the owner's dotfiles: the self-reload skill ships in the plugin
# (skills/self-reload, SKILL.md + scripts/self_cmd.py executable) and the line also names the no-skill ways.
[ -f "$PC/skills/self-reload/SKILL.md" ] && [ -x "$PC/skills/self-reload/scripts/self_cmd.py" ] || { echo "FAIL: the plugin ships the self-reload skill (skills/self-reload/SKILL.md, scripts/self_cmd.py executable): $(ls -R "$PC/skills" 2>&1 | head -5)"; exit 1; }
grep -q "run /reload-plugins in running sessions (a bot: the plugin's self-reload skill; by hand: type /reload-plugins in that session, or claude-discord bot <bot> recover from another shell)" <<<"$out" || { echo "FAIL: update's last line names the shipped skill and the by-hand ways: $out"; exit 1; }
[ "$(jq -r .version "$PC/.claude-plugin/plugin.json")" = 9.9.9 ] && [ "$(jq -r .version "$CC/.claude-plugin/plugin.json")" != 9.9.9 ] || { echo "FAIL: update must pull the source and only the source"; exit 1; }
[ -s "$HOME/.claude-discord/runtime/discord-chunk.ts" ] && [ -s "$HOME/.claude-discord/runtime/discord-proxy.ts" ] && cmp -s "$D/shim/claude-discord" "$HOME/.local/bin/claude-discord" || { echo "FAIL: update must refill the runtime copy and refresh the shim"; exit 1; }
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
[ "$rc" = 0 ] && grep -q 'before the compat step (1.8.0)' <<<"$out" && [ ! -e "$HOME/.claude-discord/compat" ] || { echo "FAIL: update must skip compat from code before 1.8.0, with a line (rc=$rc): $out"; exit 1; }
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
# hooks link gone, the .gitignore kept, a manager's records/monitor and scratch moved under the key (1.18.1; the backend
# stopped by its owner stays stopped; scratch/ob1 left as a link, which nothing removes), the
# records/projects list renamed .1.16 (its one line has a key dir now), and a second run changing nothing.
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
OPF=$HOME/.claude-discord/records/projects; printf '%s\n' "$OLDP" > "$OPF"   # the 1.16 list (nothing writes it since 1.18.1)
cp "$HOME/bin/claude" "$HOME/claude.before-move"; printf '#!/bin/bash\ncase $1 in agents) echo "[]";; *) echo "PLAIN $*";; esac\n' > "$HOME/bin/claude"   # no session of any bot runs
out=$(cd "$HOME" && bash "$S" compat 2>&1) || { echo "FAIL: compat failed: $out"; exit 1; }
OS="$HOME/.claude-discord/projects/$(skey "$OLDP")"
[ "$(cat "$OS/project" 2>/dev/null)" = "$OLDP" ] && diff -r "$HOME/old-shape.ref/ob1" "$OS/bots/ob1" >/dev/null 2>&1 && diff -r "$HOME/old-shape.ref/ob2" "$OS/bots/ob2" >/dev/null 2>&1 &&
  [ "$(stat -c %i "$OS/bots/ob1")" = "$i1" ] && [ "$(stat -c %i "$OS/bots/ob2")" = "$i2" ] && [ "$(stat -c %a "$OS/bots/ob1/.env")" = 600 ] &&
  cmp -s "$HOME/old-shape.ref/config.env" "$OS/config.env" && cmp -s "$HOME/old-shape.ref/peers.json" "$OS/peers.json" && [ -e "$OS/checkin/s1" ] &&
  [ "$(readlink "$OR/ob1")" = "$OS/bots/ob1" ] && [ "$(readlink "$OR/ob2")" = "$OS/bots/ob2" ] && [ ! -e "$OR/hooks" ] && [ ! -L "$OR/hooks" ] &&
  [ "$(<"$OR/.gitignore")" = "*" ] && [ ! -e "$OR/config.env" ] && [ ! -e "$OR/peers.json" ] && [ ! -e "$OR/checkin" ] &&
  [ "$(stat -c %a "$OS")" = 700 ] && [ "$(stat -c %a "$OS/bots")" = 700 ] && [ ! -e "$MON1" ] && [ -e "$HOME/.claude-discord/records/monitor/$(skey "$OLDP")/ob1/stopped" ] &&
  [ -f "$HOME/.claude-discord/scratch/$(skey "$OLDP")/ob1/f" ] && [ "$(readlink "$SCR1")" = "$HOME/.claude-discord/scratch/$(skey "$OLDP")/ob1" ] && [ ! -e "$OPF" ] && grep -qxF "$OLDP" "$OPF.1.16" ||
  { echo "FAIL: compat moves a project's state by rename, leaves a link per bot, and is idempotent: $out / $(find "$OR" "$OS" 2>&1)"; exit 1; }
snap=$(find "$OR" "$OS" -printf '%p %y %m %i\n' | sort)
out2=$(cd "$HOME" && bash "$S" compat 2>&1) || { echo "FAIL: a second compat failed: $out2"; exit 1; }
[ "$(find "$OR" "$OS" -printf '%p %y %m %i\n' | sort)" = "$snap" ] || { echo "FAIL: compat moves a project's state by rename, leaves a link per bot, and is idempotent: the second run changed something: $out2"; exit 1; }
echo "ok: compat moves a 1.16 project's bots, config.env, peers.json and checkin/ into ~/.claude-discord/projects/<key>/ by rename, leaves a link per bot a job record names, drops the hooks link, keeps the .gitignore, moves a stopped manager's records/monitor and scratch under the key, retires the 1.16 list, and a second run changes nothing"
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
rm -f "$OPF" "$OPF.1.16"
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
RPF="$HOME/.claude-discord/records/projects"; printf '%s\n' "$(cd "$RP" && pwd -P)" > "$RPF"   # the 1.16 list: this project is not moved yet
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
rm -rf "$RPF" "$RPF.1.16" "$HOME/.claude/jobs/lk000001" "$HOME/link" "$HOME/real"
echo "ok: a job record and a server environ naming the old path in the start's logical spelling (the project through a link) keep the link at compat, count in health and resolve --resume"
# health --all names a stale session (1.19.0): a plugin server whose DISCORD_STATE_DIR no longer exists (a session of a
# bot from before the 1.18 move, revived from the agent view: it has no token and never logs in), with the job of the
# session above it (~/.claude/sessions/<pid>.json); one on a path that exists only through a link is a bot's, not listed.
# Its own HOME with no project: --all is then the scan alone (the suite's shell is the server's parent here).
BH=$HOME/stalebox; mkdir -p "$BH/.claude/sessions"; jq -n '{jobId: "old00001", sessionId: "0ld00001-1111-2222-3333-444444444444"}' > "$BH/.claude/sessions/$$.json"
mkdir -p "$HOME/lk"; ln -s "$SD" "$HOME/lk/sbot"; start_server "$HOME/gone/x"; start_server "$HOME/lk/sbot"
out=$(HOME=$BH bash "$S" health --all --json 2>/dev/null) || :
txt=$(HOME=$BH bash "$S" health --all 2>/dev/null) || :
[ "$(jq -c --arg d "$HOME/gone/x" '[.stale_sessions[] | select(.state_dir == $d) | {job, state_dir}]' <<<"$out")" = "[{\"job\":\"old00001\",\"state_dir\":\"$HOME/gone/x\"}]" ] &&
  [ "$(jq --arg d "$HOME/lk/sbot" '[.stale_sessions[] | select(.state_dir == $d)] | length' <<<"$out")" = 0 ] &&
  grep -qF "stale session: plugin server pid " <<<"$txt" && grep -qF "runs for $HOME/gone/x, which no longer exists: it holds no token and never logs in; claude stop old00001" <<<"$txt" ||
  { echo "FAIL: health --all lists a server whose state dir is gone, with its session's job, and not one on a linked path: $out / $txt"; exit 1; }
stop_one_server "$HOME/lk/sbot"; stop_one_server "$HOME/gone/x"; rm -rf "${BH:?}" "$HOME/lk"
# 1.19.4: a live bot job that is not in pins.json (the daemon retires it after 8 h idle) is pinned by health --all
# --patch (the monitor's run), with a line in the bot's health.log, and only said without --patch. A live job of no bot
# (no DISCORD_STATE_DIR in its record) and one already pinned are left alone.
BH=$HOME/pinbox; mkdir -p "$BH/bin" "$BH/.claude/jobs/a1000001" "$BH/.claude/jobs/b2000002" "$BH/.claude/jobs/c3000003" "$BH/bd"
printf 'DISCORD_BOT_TOKEN=x\n' > "$BH/bd/.env"
for j in a1000001 c3000003; do jq -n --arg s "{\"env\": {\"DISCORD_STATE_DIR\": \"$BH/bd\"}}" '{respawnFlags: ["--settings", $s]}' > "$BH/.claude/jobs/$j/state.json"; done
echo '{"respawnFlags": []}' > "$BH/.claude/jobs/b2000002/state.json"; printf '["c3000003"]' > "$BH/.claude/jobs/pins.json"
printf '#!/bin/bash\n[ "$1" = agents ] && echo %s\n' "'[{\"id\":\"a1000001\",\"pid\":11},{\"id\":\"b2000002\",\"pid\":12},{\"id\":\"c3000003\",\"pid\":13},{\"id\":\"d4000004\"}]'" > "$BH/bin/claude"; chmod +x "$BH/bin/claude"
txt=$(HOME=$BH PATH=$BH/bin:$PATH bash "$S" health --all 2>/dev/null) || :
p1=$(<"$BH/.claude/jobs/pins.json")
out=$(HOME=$BH PATH=$BH/bin:$PATH bash "$S" health --all --json --patch 2>/dev/null) || :
grep -qF "not pinned: job a1000001 of $BH/bd is not in pins.json" <<<"$txt" && [ "$p1" = '["c3000003"]' ] &&
  [ "$(jq -c '.unpinned' <<<"$out")" = "[{\"job\":\"a1000001\",\"state_dir\":\"$BH/bd\",\"pinned_now\":true}]" ] &&
  [ "$(jq -c . "$BH/.claude/jobs/pins.json")" = '["c3000003","a1000001"]' ] && grep -q 'health: pinned job a1000001' "$BH/bd/health.log" ||
  { echo "FAIL: health --all says a live unpinned bot job and --patch pins it (health.log line), leaving a job of no bot and a pinned one alone: $txt / $p1 / $(jq -c .unpinned <<<"$out") / $(cat "$BH/.claude/jobs/pins.json" "$BH/bd/health.log" 2>&1)"; exit 1; }
rm -rf "${BH:?}"
echo "ok: health --all pins a live bot job missing from pins.json under --patch (the monitor's run) and only says so without it"
# 1.19.7: a bot whose live job is ALREADY in pins.json is not pinned again, but its pinned-job (what person_stopped, boot and
# recover read) is set under --patch when it is missing, empty, or names a job that is not running (that old id leaves
# pins.json, as pin_job does); one naming a running job, and the case without --patch, are left alone.
BH=$HOME/pinbox2; mkdir -p "$BH/bin" "$BH/.claude/jobs"
for x in m e k l d; do
  mkdir -p "$BH/b$x"; printf 'DISCORD_BOT_TOKEN=x\n' > "$BH/b$x/.env"
done
for j in a1000001:m e2000002:e c3000003:k b4000004:l f5000005:l d6000006:d; do
  mkdir -p "$BH/.claude/jobs/${j%%:*}"
  jq -n --arg s "{\"env\": {\"DISCORD_STATE_DIR\": \"$BH/b${j##*:}\"}}" '{respawnFlags: ["--settings", $s]}' > "$BH/.claude/jobs/${j%%:*}/state.json"
done
: > "$BH/be/pinned-job"; echo c3000003 > "$BH/bk/pinned-job"; echo f5000005 > "$BH/bl/pinned-job"; echo dead0007 > "$BH/bd/pinned-job"
printf '["a1000001","e2000002","c3000003","b4000004","f5000005","d6000006","dead0007"]' > "$BH/.claude/jobs/pins.json"
printf '#!/bin/bash\n[ "$1" = agents ] && echo %s\n' "'[{\"id\":\"a1000001\",\"pid\":1},{\"id\":\"e2000002\",\"pid\":2},{\"id\":\"c3000003\",\"pid\":3},{\"id\":\"b4000004\",\"pid\":4},{\"id\":\"f5000005\",\"pid\":5},{\"id\":\"d6000006\",\"pid\":6}]'" > "$BH/bin/claude"; chmod +x "$BH/bin/claude"
HOME=$BH PATH=$BH/bin:$PATH bash "$S" health --all >/dev/null 2>&1 || :
[ ! -e "$BH/bm/pinned-job" ] && [ ! -s "$BH/be/pinned-job" ] && [ "$(<"$BH/bd/pinned-job")" = dead0007 ] ||
  { echo "FAIL: health --all without --patch changes no pinned-job"; exit 1; }
HOME=$BH PATH=$BH/bin:$PATH bash "$S" health --all --patch >/dev/null 2>&1 || :
[ "$(<"$BH/bm/pinned-job")" = a1000001 ] && [ ! -e "$BH/bm/pin-foreign" ] ||
  { echo "FAIL: --patch writes a missing pinned-job for a job already in pins.json, and the bot's own job (by its state dir) is not recorded in pin-foreign: $(cat "$BH/bm/pinned-job" "$BH/bm/pin-foreign" 2>&1)"; exit 1; }
[ "$(<"$BH/be/pinned-job")" = e2000002 ] && [ ! -e "$BH/be/pin-foreign" ] || { echo "FAIL: --patch writes an empty pinned-job: $(cat "$BH/be/pinned-job")"; exit 1; }
[ "$(<"$BH/bk/pinned-job")" = c3000003 ] && [ ! -e "$BH/bk/health.log" ] && [ ! -e "$BH/bk/pin-foreign" ] ||
  { echo "FAIL: --patch leaves a pinned-job that is already right alone"; exit 1; }
[ "$(<"$BH/bl/pinned-job")" = f5000005 ] && [ ! -e "$BH/bl/health.log" ] ||
  { echo "FAIL: --patch never overwrites a pinned-job that names a running job: $(cat "$BH/bl/pinned-job")"; exit 1; }
[ "$(<"$BH/bd/pinned-job")" = d6000006 ] && grep -q 'pinned-job set to d6000006 (it was dead0007)' "$BH/bd/health.log" &&
  [ "$(jq -c . "$BH/.claude/jobs/pins.json")" = '["a1000001","e2000002","c3000003","b4000004","f5000005","d6000006"]' ] ||
  { echo "FAIL: --patch replaces a pinned-job naming a job that is not running (the old id leaves pins.json): $(cat "$BH/bd/pinned-job" "$BH/.claude/jobs/pins.json" 2>&1)"; exit 1; }
# A job in pin-foreign that the bot has moved on from (pinned-job names another) and that no longer runs leaves pins.json and
# pin-foreign under --patch; one that still runs (a person's pin of a live job), and the bot's current job, stay.
jq -c '. + ["dead0009","dead000a"]' "$BH/.claude/jobs/pins.json" > "$BH/pins.new" && mv "$BH/pins.new" "$BH/.claude/jobs/pins.json"
# bq is a bot of a recorded project (the sweep walks those): its job is c3000003, and it has recorded four foreign ids.
mkdir -p "$BH/pq"; kq="$BH/.claude-discord/projects/$(skey "$BH/pq")"; mkdir -p "$kq/bots/bq"
printf '%s\n' "$(cd -P "$BH/pq" && pwd)" > "$kq/project"; printf 'DISCORD_BOT_TOKEN=x\n' > "$kq/bots/bq/.env"; echo c3000003 > "$kq/bots/bq/pinned-job"
printf 'dead0009\ne2000002\ndead000a\nc3000003\n' > "$kq/bots/bq/pin-foreign"
HOME=$BH PATH=$BH/bin:$PATH bash "$S" health --all --patch >/dev/null 2>&1 || :
[ "$(jq -c . "$BH/.claude/jobs/pins.json")" = '["a1000001","e2000002","c3000003","b4000004","f5000005","d6000006"]' ] && [ "$(<"$kq/bots/bq/pin-foreign")" = $'e2000002\nc3000003' ] ||
  { echo "FAIL: --patch drops a pin-foreign job that no longer runs from pins.json and pin-foreign, never a running one or the bot's own: $(cat "$BH/.claude/jobs/pins.json" "$kq/bots/bq/pin-foreign" 2>&1)"; exit 1; }
rm -rf "${BH:?}"
echo "ok: health --all --patch sets a missing, empty or dead pinned-job for a job already in pins.json (not as pin-foreign when it is the bot's own), leaves a running or right one, and drops a dead pin-foreign job"
# held (1.19.1): sbot's own server is the last one up; with it stopped and bot sbot hold, health reads held, not down.
stop_one_server "$SD"; : > "$SD/held"; queue "200 $NONE" '200 {"threads":[]}'
out=$(cd "$SP" && bash "$S" health --json 2>/dev/null) || :
[ "$(field_of sbot verdict "$out")" = held ] || { echo "FAIL: a bot held on purpose with no server reads held, not down: $out"; exit 1; }
rm -f "$SD/held"
# A bot its person stopped (1.19.7, person_stopped): the job in pinned-job has "bg settled <id> (killed)" as the LAST line of
# its life in daemon.log (claude stop and claude rm; the SessionEnd hook cannot tell them from a SIGTERM), and health
# writes held and reads it held, so the monitor never recovers it. Each case with its opposite: a (done) last, a later start of
# the same id, the daemon's own shutdown or start just before (a kill 90 s after a start is a person's), a line older than the
# newest session marker, an id in own-stop, no pinned-job, another job's line, an unreadable time; a held file already there
# is kept as it is. A big log after the kill and many markers must not change a verdict (pipefail with head: SIGPIPE).
DLOG="$HOME/.claude/daemon.log"; SDM="$SD/plugin-sessions"
dts() { date -u -d "$1" +%Y-%m-%dT%H:%M:%S.000Z; }
hv() {  # <log lines>: health's verdict for sbot, then the held file's first two words when health wrote one
  printf '%s\n' "$1" > "$DLOG"; rm -f "$SD/held"; queue "200 $NONE" '200 {"threads":[]}'
  out=$(cd "$SP" && bash "$S" health --json 2>/dev/null) || :
  printf '%s' "$(field_of sbot verdict "$out")"; [ ! -f "$SD/held" ] || printf ' %s' "$(cut -d' ' -f1-2 "$SD/held")"
}
echo ee0000ff > "$SD/pinned-job"; rm -rf "$SDM" "$SD/own-stop"
SP1="[$(dts '10 minutes ago')] [bg] bg spawned ee0000ff (spare)"; KL="[$(dts '1 minute ago')] [bg] bg settled ee0000ff (killed)"
R1=$(hv "$SP1"$'\n'"$KL")
R2=$(hv "$SP1"$'\n'"[$(dts '1 minute ago')] [bg] bg retire ee0000ff: idle-prompt, idle 60m"$'\n'"[$(dts '1 minute ago')] [bg] bg settled ee0000ff (done)")
R3=$(hv "$KL"$'\n'"[$(dts '30 seconds ago')] [bg] bg claimed-spare ee0000ff (slash)")
SD1="[$(dts '5 minutes ago')] [supervisor] shutting down (cause=upgrade, uptime=9s, leases=1, live_workers=1)"
R6=$(hv "$SD1"$'\n'"$KL")
R7=$(hv "[$(dts '1 minute ago')] [bg] bg settled ee0000ff (done)"$'\n'"[$(dts '30 seconds ago')] [bg] bg settled 99999999 (killed)")
R8=$(hv "[not-a-time] [bg] bg settled ee0000ff (killed)")
R14=$(hv "[$(dts '90 seconds ago')] [supervisor] shutting down (cause=signal, uptime=9s, leases=1, live_workers=1)"$'\n'"$KL")
DS="[$(dts '70 seconds ago')] [supervisor] shutting down (cause=upgrade, uptime=9s, leases=1, live_workers=1)"
DN="[$(dts '150 seconds ago')] [supervisor] ─── daemon start ─── version=2.1.207 pid=1 origin=transient"
R16=$(hv "$DN"$'\n'"$KL")   # the kill 90 s after a daemon start, no shutdown: a person's
R20=$(hv "[$(dts '80 seconds ago')] [supervisor] ─── daemon start ─── version=2.1.207 pid=1 origin=transient"$'\n'"$KL")   # 20 s after a start: the new daemon's clean-up
FILL=$(awk 'BEGIN { for (i = 0; i < 1500; i++) print "[2026-10-30T20:00:00.000Z] [bg] bg spare spawned host pid=" i " ................................" }')
R17=$(hv "$DS"$'\n'"$KL"$'\n'"$FILL")   # 100 KB of log after the kill must not drop the shutdown line before it
cp "$SD/.env" "$SD/.env.keep"; : > "$SD/.env"; R15=$(hv "$KL"); mv "$SD/.env.keep" "$SD/.env"   # no token: unknown, nothing to hold
mkdir -p "$SDM"; : > "$SDM/s1"; touch -d '10 minutes ago' "$SDM/s1"
R9=$(hv "$KL")
touch "$SDM/s1"
R10=$(hv "[$(dts '5 minutes ago')] [bg] bg settled ee0000ff (killed)")
rm -rf "$SDM"; mkdir -p "$SDM"; LONG=$(printf 'm%.0s' {1..240}); for i in $(seq 1 3000); do : > "$SDM/$LONG$i"; done; touch -d '10 minutes ago' "$SDM"/*
R18=$(hv "$KL")   # 3000 markers (720 KB of names), all older than the line: held
: > "$SDM/new1"; R19=$(hv "[$(dts '5 minutes ago')] [bg] bg settled ee0000ff (killed)")   # one newer among them: not
rm -rf "$SDM"; echo ee0000ff > "$SD/own-stop"
R11=$(hv "$KL"); rm -f "$SD/own-stop"
rm -f "$SD/pinned-job"; R12=$(hv "$KL"); echo ee0000ff > "$SD/pinned-job"
printf '%s\n' "$KL" > "$DLOG"; echo "by hand" > "$SD/held"; queue "200 $NONE" '200 {"threads":[]}'; out=$(cd "$SP" && bash "$S" health --json 2>/dev/null) || :
R13="$(field_of sbot verdict "$out") $(<"$SD/held")"
K1="session-end killed"
[ "$R1" = "held $K1" ] && [ "$R2" = down ] && [ "$R3" = down ] && [ "$R6" = "held $K1" ] && [ "$R7" = down ] &&
  [ "$R8" = down ] && [ "$R9" = "held $K1" ] && [ "$R10" = down ] && [ "$R11" = down ] && [ "$R12" = down ] && [ "$R13" = "held by hand" ] && [ "$R14" = down ] && [ "$R15" = unknown ] &&
  [ "$R16" = "held $K1" ] && [ "$R17" = down ] && [ "$R18" = "held $K1" ] && [ "$R19" = down ] && [ "$R20" = down ] ||
  { echo "FAIL: health holds a bot whose pinned job's last daemon.log line is a (killed) and nothing else: $R1 | $R2 | $R3 | $R6 | $R7 | $R8 | $R9 | $R10 | $R11 | $R12 | $R13 | $R14 | $R15 | $R16 | $R17 | $R18 | $R19 | $R20"; exit 1; }
# An inferred hold (session-end killed <time>) counts only while no session marker is newer than <time> (health race 1.19.7:
# a bot restarted during the pass, its hold written after on-session-start removed it): dropped, the bot reads down.
: > "$DLOG"; mkdir -p "$SDM"; touch -d '10 minutes ago' "$SDM"; : > "$SDM/s1"; touch -d '10 minutes ago' "$SDM/s1"
hh() {  # <held content>: health's verdict for sbot, then "kept" when the held file is still there
  printf '%s\n' "$1" > "$SD/held"; queue "200 $NONE" '200 {"threads":[]}'
  out=$(cd "$SP" && bash "$S" health --json 2>/dev/null) || :
  printf '%s' "$(field_of sbot verdict "$out")"; [ ! -f "$SD/held" ] || printf ' kept'
}
H1=$(hh "session-end killed $(dts '5 minutes ago')")   # the marker is older than the line: kept
touch "$SDM/s1"; H2=$(hh "session-end killed $(dts '5 minutes ago')")   # a session started after the line: dropped
H3=$(hh "session-end prompt_input_exit $(dts '5 minutes ago')")   # the hook's own hold is not inferred: kept
rm -rf "$SDM"
[ "$H1" = "held kept" ] && [ "$H2" = down ] && [ "$H3" = "held kept" ] || { echo "FAIL: an inferred hold is dropped once a session marker is newer than its line, the hook's hold is not: $H1 | $H2 | $H3"; exit 1; }
rm -f "$SD/held" "$SD/pinned-job" "$DLOG"
echo "ok: health --all lists stale sessions (a plugin server whose state dir is gone) with the job to stop, and leaves a server on a linked path alone"
stop_servers

# --- many bots per project (1.18.1, Task 4): nothing is keyed by a bot's name alone ----------------------------------
# (a, d) Two projects each with a manager named mgr: setup of the second succeeds (1.18.0 refused it), records/managers
# lists both keys, a missing file is rebuilt from projects/*/bots/*/hosts by the hooks, and revive_backends starts two
# keepers (monitor --keep mgr --detach from each project), each with its own records/monitor/<key>/mgr.
M2A="$HOME/mgr one"; M2B="$HOME/mgr two"; mkdir -p "$M2A" "$M2B"
jq --arg a "$M2A" --arg b "$M2B" '.projects[$a].hasTrustDialogAccepted = true | .projects[$b].hasTrustDialogAccepted = true' "$HOME/.claude.json" > "$HOME/cj.tmp" && mv "$HOME/cj.tmp" "$HOME/.claude.json"
for p in "$M2A" "$M2B"; do
  rc=0; out=$(cd "$p" && printf '900\n111\n\ntokM\nn\ndev-manager\n\n\n' | CLAUDE_DISCORD_SETUP_NOASK=1 bash "$S" setup mgr --scope project 2>&1) || rc=$?
  [ "$rc" = 0 ] && [ -f "$(bdir "$p" mgr)/hosts" ] && [ "$(<"$(bdir "$p" mgr)/mode")" = dev-manager ] || { echo "FAIL: two managers of one name in two projects are two backends: setup of mgr in $p (rc=$rc): $out"; exit 1; }
done
KA=$(skey "$M2A") KB=$(skey "$M2B"); MGRS="$HOME/.claude-discord/records/managers"
grep -qxF -- "$KA mgr" "$MGRS" && grep -qxF -- "$KB mgr" "$MGRS" || { echo "FAIL: two managers of one name in two projects are two backends: records/managers must list both keys: $(cat "$MGRS" 2>&1)"; exit 1; }
FX="$HOME/fxroot"; mkdir -p "$FX/bin/lib" "$FX/hooks/turn" "$FX/hooks/lib"; cp "$D/hooks/turn/on-prompt" "$FX/hooks/turn/"; cp "$D/hooks/lib/discord.sh" "$FX/hooks/lib/"; cp "$D/bin/lib/state.sh" "$FX/bin/lib/"
printf '#!/bin/sh\nprintf "%%s %%s\\n" "$PWD" "$*" >> "$HOME/fx.rec"\n' > "$FX/bin/claude-discord"; chmod +x "$FX/bin/claude-discord"
FXR=$(cd -P "$FX" && pwd -P); printf '{"session_id":"sM2","prompt":"hi"}' > "$HOME/up.json"
fxhook() { rm -f "$HOME/fx.rec" "$HOME"/.claude-discord/records/monitor/*/mgr/last-start* "$HOME"/.claude-discord/records/monitor/mgr/last-start*; env -u CLAUDE_DISCORD_NO_AUTOSTART CLAUDE_PLUGIN_ROOT="$FXR" CLAUDE_PROJECT_DIR="$M2A" DISCORD_STATE_DIR="$(bdir "$M2A" mgr)" bash "$FXR/hooks/turn/on-prompt" < "$HOME/up.json" >/dev/null 2>&1; nap 0.1; }
rm -f "$MGRS"; fxhook
grep -qxF -- "$KA mgr" "$MGRS" 2>/dev/null && grep -qxF -- "$KB mgr" "$MGRS" || { echo "FAIL: a missing records/managers is rebuilt by the hooks from projects/*/bots/*/hosts: $(cat "$MGRS" 2>&1)"; exit 1; }
printf '%s mgr\n%s mgr\n%s mgr\n' "$KA" "$KB" "$KA" > "$MGRS"; fxhook   # a line twice: one keeper
[ "$(sort "$HOME/fx.rec" 2>/dev/null)" = "$(printf '%s monitor --keep mgr --detach\n%s monitor --keep mgr --detach\n' "$M2A" "$M2B" | sort)" ] &&
  [ -s "$HOME/.claude-discord/records/monitor/$KA/mgr/last-start"* ] && [ -s "$HOME/.claude-discord/records/monitor/$KB/mgr/last-start"* ] && [ ! -e "$HOME/.claude-discord/records/monitor/mgr" ] ||
  { echo "FAIL: two managers of one name in two projects are two backends: revive_backends must start a keeper per manager (key and name) from its project, each with its own records/monitor/<key>/mgr: $(cat "$HOME/fx.rec" 2>&1) / $(ls -R "$HOME/.claude-discord/records/monitor" 2>&1)"; exit 1; }
echo none > "$(bdir "$M2B" mgr)/mode"; fxhook   # a listed line whose mode is no longer dev-manager: nothing forked for it
[ "$(cat "$HOME/fx.rec" 2>/dev/null)" = "$M2A monitor --keep mgr --detach" ] || { echo "FAIL: revive_backends starts nothing for a listed manager whose mode is no longer dev-manager: $(cat "$HOME/fx.rec" 2>&1)"; exit 1; }
echo dev-manager > "$(bdir "$M2B" mgr)/mode"
rm -rf "$FX" "$HOME/fx.rec" "$HOME/up.json" "$HOME/.claude-discord/records/monitor"
echo "ok: two projects may each have a manager named mgr: setup accepts the second, records/managers lists both keys (rebuilt by the hooks when missing), and revive_backends starts one keeper per key and name, from its project, with records/monitor/<key>/<bot> each"

# (e) The hooks read the channel and the people from the bot's own access.json, never from config.env: a config.env
# naming another channel and owner changes nothing in on-prompt's identity and People line, and a removed one neither;
# with none or several groups there is no channel (the identity says so).
SD2="$(bdir "$SP" sbot)"; cp "$SD2/access.json" "$HOME/acc.keep"; cp "$(pstate "$SP")/config.env" "$HOME/cfg.keep"
ehook() { printf '{"session_id":"%s","prompt":"<channel source=\\"plugin:discord:discord\\" chat_id=\\"900\\" message_id=\\"%s\\" user=\\"u\\" user_id=\\"111\\" ts=\\"t\\">\\nhi\\n</channel>"}' "$1" "$2" | CLAUDE_PLUGIN_ROOT="$PC" CLAUDE_PROJECT_DIR="$SP" DISCORD_STATE_DIR="$SD2" bash "$PC/hooks/turn/on-prompt" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null; }
printf "DISCORD_CHANNEL_ID='7777'\nDISCORD_USER_ID='8888'\nDISCORD_ALLOW_IDS=''\n" > "$(pstate "$SP")/config.env"
c1=$(ehook e1 901); rm -f "$(pstate "$SP")/config.env"; c2=$(ehook e2 902)
grep -q ' in channel 900\. ' <<<"$c1" && grep -q '^People in this channel (mention one as <@id> to reach them): u <@111>, <@222>$' <<<"$c1" && [ "$c1" = "$c2" ] ||
  { echo "FAIL: the hooks read the channel and the people from access.json only: $c1 /// $c2"; exit 1; }
# Several groups (1.18.2): config.env's DISCORD_CHANNEL_ID is the home channel when it is one of them (1.18.1 read
# nothing from config.env and left such a bot with no channel: junyong-dev-bot and RVP on lmd42 could not `thread start`);
# a home that is none of the groups, or no config.env, is no channel, as before.
jq '.groups["901"] = .groups["900"]' "$HOME/acc.keep" > "$SD2/access.json"; printf "DISCORD_CHANNEL_ID='901'\nDISCORD_USER_ID='111'\nDISCORD_ALLOW_IDS=''\n" > "$(pstate "$SP")/config.env"
c3=$(ehook e3 903)
grep -q ' in channel 901\. ' <<<"$c3" && ! grep -q 'no channel' <<<"$c3" || { echo "FAIL: with several groups config.env's channel, when it is one of them, is the home channel: $c3"; exit 1; }
: > "$CURL_LOG"; printf '200 {"id":"5551"}\n200 {"id":"5552"}\n' > "$CURL_REPLIES"   # the two POSTs' replies, no gateway line: the tool asks for none
tout=$(cd "$SP" && DISCORD_STATE_DIR=$SD2 bash "$PC/tools/thread" start "[t] home" 2>&1) || { echo "FAIL: thread start must work for a bot with several groups and a home channel: $tout"; exit 1; }
grep -q 'channels/901/messages' "$CURL_LOG" || { echo "FAIL: thread start posts the channel line to the home channel: $(cat "$CURL_LOG")"; exit 1; }
printf "DISCORD_CHANNEL_ID='7777'\nDISCORD_USER_ID='111'\nDISCORD_ALLOW_IDS=''\n" > "$(pstate "$SP")/config.env"; c4=$(ehook e4 904)
grep -q ' with no channel (its access.json names no single channel)\. ' <<<"$c4" && ! grep -q 'in channel' <<<"$c4" || { echo "FAIL: with several groups and a config.env channel that is none of them there is no channel: $c4"; exit 1; }
rm -f "$(pstate "$SP")/config.env"; c5=$(ehook e5 905)
grep -q ' with no channel (its access.json names no single channel)\. ' <<<"$c5" || { echo "FAIL: with several groups and no config.env there is no channel: $c5"; exit 1; }
printf '' > "$SD2/access.json"
(DISCORD_STATE_DIR=$SD2; . "$PC/hooks/lib/discord.sh"; resolve_channel; [ -z "$bot_channel" ] && [ -z "$bot_access_ids" ]) || { echo "FAIL: an empty access.json leaves no channel (config.env is not read): '$(DISCORD_STATE_DIR=$SD2; . "$PC/hooks/lib/discord.sh"; resolve_channel; echo "$bot_channel")'"; exit 1; }
cp "$HOME/acc.keep" "$SD2/access.json"; cp "$HOME/cfg.keep" "$(pstate "$SP")/config.env"; rm -f "$HOME/acc.keep" "$HOME/cfg.keep" "$SD2"/turns/e[12345]*
echo "ok: on-prompt's identity and People line come from access.json alone (config.env naming another channel and owner, or removed, changes nothing); none is no channel; several groups take config.env's channel as home when it is one of them (thread start posts there), else no channel"

# (f) peers.json is written under peers.json.lock (mkdir, 5 s): held, the writer says the file was not changed and goes
# on (exit status as without the lock); released, the next write lands.
PJ="$(pstate "$M2A")/peers.json"; cp "$PJ" "$HOME/pj.keep" 2>/dev/null || : > "$HOME/pj.keep"; mkdir "$PJ.lock"
rc=0; out=$(cd "$M2A" && printf 'dev-manager\npeerz:700:800:host\n\n' | bash "$S" setup mgr --mode 2>&1) || rc=$?
[ "$rc" = 0 ] && grep -q "$PJ.lock is held" <<<"$out" && grep -q 'not changed' <<<"$out" && ! grep -q peerz "$PJ" 2>/dev/null || { echo "FAIL: peers.json is written under its lock (rc=$rc): $out / $(cat "$PJ" 2>&1)"; exit 1; }
rmdir "$PJ.lock"
rc=0; out=$(cd "$M2A" && printf 'dev-manager\npeerz:700:800:host\n\n' | bash "$S" setup mgr --mode 2>&1) || rc=$?
[ "$rc" = 0 ] && grep -q peerz "$PJ" && [ ! -e "$PJ.lock" ] || { echo "FAIL: with the lock released the peers line is written and the lock left clean (rc=$rc): $out / $(cat "$PJ" 2>&1)"; exit 1; }
echo "ok: a held peers.json.lock makes setup --mode (the peers writer) say the file was not changed and go on; released, the write lands and the lock is released"

# (b, c) The backend records of a manager, records/monitor/<bot> before 1.18.1, move to records/monitor/<key>/<bot> at
# compat with the backend stopped before and started after (as bot rename does): the holder lock and state.json are at
# the new path, the alerts continue (one appended after the move follows the ones before it), the next pass writes to
# the new path; scratch/<bot> goes to scratch/<key>/<bot> with a link in its place, which nothing removes (a session
# started before 1.18.1 may write there, and whether one runs cannot be judged from every side of a shared home). A
# backend a hook or a TUI started at the new path meanwhile (its own keeper and monitor, no history) is stopped too and
# its records replaced by the old path's: one backend after, with the history. A start at the new path that fails (a
# --keep that fails once) puts the records back and starts the backend at the old path again: compat exits 1 with the
# reason. A backend this side cannot see (the other side of a shared home holds the lock) is not moved: compat exits 1
# saying where to run it, and leaves no stopped marker.
export CLAUDE_DISCORD_MONITOR_TICK=0.01 CLAUDE_DISCORD_MONITOR_PASS=60 CLAUDE_DISCORD_MONITOR_HOST_CAP=0.03 CLAUDE_DISCORD_MONITOR_LOCK_WAIT=0.10
mv "$HOME/.local/bin/claude-discord" "$HOME/shim.real"; mkdir -p "$HOME/mon"
printf '#!/bin/bash\ncat "$HOME/mon/local.out"\n' > "$HOME/.local/bin/claude-discord"; chmod +x "$HOME/.local/bin/claude-discord"
mdoc2() { local b bots=""; for b in "$@"; do bots="$bots${bots:+,}{\"bot\":\"$b\",\"verdict\":\"stale\",\"detail\":\"why stale\",\"owner_id\":\"222\",\"servers\":\"1\"}"; done; printf '{"host":"h1","version":"1.18.1 (abc1234)","home":"/home/u","patch":{"rc":0,"output":""},"projects":[{"project":"/home/u/ws/p","bots":[%s]}]}\n' "$bots" > "$HOME/mon/local.out"; }
OLDM="$HOME/.claude-discord/records/monitor/mgr" NEWM="$HOME/.claude-discord/records/monitor/$KA/mgr"
alerts() { jq -r '[.alerts[] | .key] | join(" ")' "$1/state.json" 2>/dev/null || :; }
wait_alerts() { local n=0; while [ "$(alerts "$1")" != "$2" ] && [ "$n" -lt 7500 ]; do nap 0.002; n=$((n + 1)); done; [ "$(alerts "$1")" = "$2" ]; }
mon_pid() { local l=""; { read -r l < "$1/lock"; } 2>/dev/null || :; case $l in ''|*[!0-9]*) return 1;; esac; [[ $(tr '\0' ' ' < "/proc/$l/cmdline" 2>/dev/null) == *"--locked mgr "* ]] && echo "$l"; }
wait_mon() { local n=0; while ! mon_pid "$1" >/dev/null && [ "$n" -lt 7500 ]; do nap 0.002; n=$((n + 1)); done; mon_pid "$1" >/dev/null; }
keepers() { local f; for f in "$1"/holders/keeper-*; do [ ! -f "$f" ] || { kill -0 "${f##*-}" 2>/dev/null && echo "${f##*-}"; }; done; }   # the live keeper pids a records dir names
wait_keeper() { local n=0 k; while :; do k=$(keepers "$1"); [ -n "$k" ] && [ "$k" != "${2:-}" ] && break; [ "$n" -lt 7500 ] || break; nap 0.002; n=$((n + 1)); done; keepers "$1"; }
mdoc2 b1; : > "$CURL_REPLIES"; : > "$CURL_LOG"
mkdir -p "$HOME/.claude-discord/scratch/mgr"; : > "$HOME/.claude-discord/scratch/mgr/f"
(cd "$M2A" && CLAUDE_DISCORD_MONITOR_DIR=$OLDM bash "$S" monitor --start mgr >/dev/null 2>&1) || { echo "FAIL: fixture: the backend of mgr did not start at the old path"; exit 1; }
wait_alerts "$OLDM" 'local|/home/u/ws/p|b1' || { echo "FAIL: fixture: the backend at the old path ran no pass: $(cat "$OLDM/monitor.log" 2>&1)"; exit 1; }
# (M-1) A backend at the new path too, as a hook's revive_backends or a TUI starts one between the pull and the move.
(cd "$M2A" && bash "$S" monitor --start mgr >/dev/null 2>&1) || { echo "FAIL: fixture: the backend of mgr did not start at the new path"; exit 1; }
wait_mon "$NEWM" && NKP=$(wait_keeper "$NEWM") && [ -n "$NKP" ] || { echo "FAIL: fixture: no backend at the new path: $(ls -R "$NEWM" 2>&1)"; exit 1; }
mdoc2 b1 b2
rc=0; out=$(cd "$HOME" && bash "$S" compat 2>&1) || rc=$?
KP2=$(wait_keeper "$NEWM" "$NKP")
[ "$rc" = 0 ] && [ ! -e "$OLDM" ] && [ -f "$NEWM/state.json" ] && wait_mon "$NEWM" && wait_alerts "$NEWM" 'local|/home/u/ws/p|b1 local|/home/u/ws/p|b2' && grep -qF "$NEWM" <<<"$out" &&
  [ "$(wc -l <<<"$KP2")" = 1 ] && [ "$KP2" != "$NKP" ] && ! kill -0 "$NKP" 2>/dev/null && [ "$(ps -eo args= | command grep -c "[m]onitor/monitor.sh .* --locked mgr")" = 1 ] ||
  { echo "FAIL: the records move with the backend stopped and started: the lock and state.json at the new path, the alerts continuous, the next pass there, and a backend started at the new path meanwhile stopped (one keeper, one monitor after; its holder gone) (rc=$rc): $out / keepers=$KP2 nkp=$NKP / $(ls -R "$HOME/.claude-discord/records/monitor" 2>&1) / $(cat "$NEWM/monitor.log" "$OLDM/monitor.log" 2>&1 | tail -n 20)"; exit 1; }
[ -f "$HOME/.claude-discord/scratch/$KA/mgr/f" ] && [ "$(readlink "$HOME/.claude-discord/scratch/mgr")" = "$HOME/.claude-discord/scratch/$KA/mgr" ] ||
  { echo "FAIL: scratch/<bot> moves to scratch/<key>/<bot> with a link in its place: $out / $(ls -la "$HOME/.claude-discord/scratch" 2>&1)"; exit 1; }
(cd "$M2A" && bash "$S" monitor --stop mgr >/dev/null 2>&1) || :
n=0; while mon_pid "$NEWM" >/dev/null && [ "$n" -lt 1500 ]; do nap 0.002; n=$((n + 1)); done
cp "$HOME/bin/claude" "$HOME/claude.keep"; printf '#!/bin/bash\ncase $1 in agents) echo "[]";; *) echo "PLAIN $*";; esac\n' > "$HOME/bin/claude"   # a listing with no session of mgr
out=$(cd "$HOME" && bash "$S" compat 2>&1) || { echo "FAIL: compat failed: $out"; exit 1; }
[ "$(readlink "$HOME/.claude-discord/scratch/mgr")" = "$HOME/.claude-discord/scratch/$KA/mgr" ] && [ -f "$HOME/.claude-discord/scratch/$KA/mgr/f" ] || { echo "FAIL: the scratch link stays (a session started before 1.18.1 may write there, and a listing cannot see every side): $out / $(ls -la "$HOME/.claude-discord/scratch" 2>&1)"; exit 1; }
cp "$HOME/claude.keep" "$HOME/bin/claude"; rm -f "$HOME/claude.keep"
echo "ok: compat moves a manager's records/monitor/<bot> to records/monitor/<key>/<bot> with the backend stopped before and started after (lock and state at the new path, the alerts continuous, the next pass there; a backend started at the new path meanwhile stopped: one backend after), and scratch/<bot> to scratch/<key>/<bot> behind a link that stays"
# The rollback: the backend at the old path again, a --keep that fails once at the new path.
rm -rf "$NEWM"; mdoc2 b1
(cd "$M2A" && CLAUDE_DISCORD_MONITOR_DIR=$OLDM bash "$S" monitor --start mgr >/dev/null 2>&1) || { echo "FAIL: fixture: the backend of mgr did not start at the old path again"; exit 1; }
wait_alerts "$OLDM" 'local|/home/u/ws/p|b1' || { echo "FAIL: fixture: the backend at the old path ran no pass (second start): $(cat "$OLDM/monitor.log" 2>&1)"; exit 1; }
printf '#!/bin/bash\nif [ -e "$HOME/keep.fail" ]; then case "$*" in *" --kept"*) rm -f "$HOME/keep.fail"; exit 1;; esac; fi\nexec %q "$@"\n' "$REALPERL" > "$HOME/bin/perl"; chmod +x "$HOME/bin/perl"; : > "$HOME/keep.fail"
rc=0; out=$(cd "$HOME" && bash "$S" compat 2>&1) || rc=$?
[ "$rc" = 1 ] && [ ! -e "$NEWM" ] && [ -f "$OLDM/state.json" ] && wait_mon "$OLDM" && [ ! -e "$HOME/keep.fail" ] && grep -q "did not start at $NEWM" <<<"$out" && grep -qF "back at $OLDM" <<<"$out" ||
  { echo "FAIL: a failed restart at the new path puts the records back at the old one and starts the backend there again, compat exit 1 with the reason (rc=$rc): $out / $(ls -R "$HOME/.claude-discord/records/monitor" 2>&1) / $(cat "$OLDM/monitor.log" 2>&1 | tail -n 20)"; exit 1; }
rm -f "$HOME/bin/perl"
(cd "$M2A" && CLAUDE_DISCORD_MONITOR_DIR=$OLDM bash "$S" monitor --stop mgr >/dev/null 2>&1) || :
n=0; while mon_pid "$OLDM" >/dev/null && [ "$n" -lt 1500 ]; do nap 0.002; n=$((n + 1)); done
rm -rf "$OLDM"
echo "ok: a records move whose restart fails puts the records back at the old path and starts the backend there again; compat exits 1 and says why"
# (I-1) The old path's lock held by a monitor this side cannot see (the other side of a shared home: its pid reads as
# another process here, so --stop stops nothing): the records are not moved, no stopped marker is left, compat exits 1
# naming where to run it.
mkdir -p "$OLDM"; printf '{"version":1,"manager":"mgr","monitor":{},"hosts":{},"bots":{},"alerts":[]}\n' > "$OLDM/state.json"
perl -MFcntl=:flock -e 'open(my $l, ">>", $ARGV[0]) or die; flock($l, LOCK_EX) or die; open(my $w, ">", $ARGV[0]) or die; print $w "$$\n"; close $w; sleep 30' "$OLDM/lock" & LP=$!
KILL_AT_EXIT="$KILL_AT_EXIT $LP"; n=0; l=""; until [ "$l" = "$LP" ] || [ "$n" -ge 1000 ]; do nap 0.002; n=$((n + 1)); { read -r l < "$OLDM/lock"; } 2>/dev/null || :; done
rc=0; out=$(cd "$HOME" && bash "$S" compat 2>&1) || rc=$?
[ "$rc" = 1 ] && [ -f "$OLDM/state.json" ] && [ ! -e "$OLDM/stopped" ] && [ ! -e "$NEWM" ] && grep -q 'runs where this side cannot see it: run update there' <<<"$out" ||
  { echo "FAIL: a backend this side cannot see (its lock held) is not moved, no stopped marker is left, compat exit 1 saying to run update there (rc=$rc): $out / $(ls -R "$HOME/.claude-discord/records/monitor" 2>&1)"; exit 1; }
kill "$LP" 2>/dev/null || :; wait "$LP" 2>/dev/null || :; rm -rf "$OLDM"
echo "ok: a backend whose lock this side cannot see is not moved: no stopped marker, compat exits 1 and says to run update where it runs"
# (M-2) A manager whose project compat does not know (no key dir, no 1.16 line: never set up or started since 1.18.0):
# its first start moves its records too, the backend stopped before and started after, and the start goes on.
UNK="$HOME/unknown mgr"; UR="$UNK/.claude/discord-agents"; mkdir -p "$UR/umgr"
printf 'DISCORD_BOT_TOKEN=tu\n' > "$UR/umgr/.env"; echo dev-manager > "$UR/umgr/mode"; printf '# ledger\nlocal\n' > "$UR/umgr/hosts"; echo '{}' > "$UR/umgr/access.json"
printf "DISCORD_CHANNEL_ID='7'\nDISCORD_USER_ID='8'\nDISCORD_ALLOW_IDS=''\n" > "$UR/config.env"
OLDU="$HOME/.claude-discord/records/monitor/umgr" NEWU="$HOME/.claude-discord/records/monitor/$(skey "$UNK")/umgr"
mon_pid_u() { local l=""; { read -r l < "$1/lock"; } 2>/dev/null || :; case $l in ''|*[!0-9]*) return 1;; esac; [[ $(tr '\0' ' ' < "/proc/$l/cmdline" 2>/dev/null) == *"--locked umgr "* ]] && echo "$l"; }
mdoc2 b1
(cd "$UNK" && CLAUDE_DISCORD_MONITOR_DIR=$OLDU bash "$S" monitor --start umgr >/dev/null 2>&1) || { echo "FAIL: fixture: the backend of umgr did not start at the old path"; exit 1; }
wait_alerts "$OLDU" 'local|/home/u/ws/p|b1' || { echo "FAIL: fixture: umgr's backend at the old path ran no pass: $(cat "$OLDU/monitor.log" 2>&1)"; exit 1; }
out=$(cd "$UNK" && bash "$S" --name umgr 2>&1) || :
n=0; while ! mon_pid_u "$NEWU" >/dev/null && [ "$n" -lt 1500 ]; do nap 0.002; n=$((n + 1)); done
grep -qF -- "\"DISCORD_STATE_DIR\": \"$HOME/.claude-discord/projects/$(skey "$UNK")/bots/umgr\"" <<<"$out" && [ ! -e "$OLDU" ] && [ "$(alerts "$NEWU")" = 'local|/home/u/ws/p|b1' ] && mon_pid_u "$NEWU" >/dev/null && grep -qF "$NEWU" <<<"$out" ||
  { echo "FAIL: a start in a project compat never saw moves a manager's old-path records (backend stopped and started) and launches: $out / $(ls -R "$HOME/.claude-discord/records/monitor" 2>&1)"; exit 1; }
(cd "$UNK" && bash "$S" monitor --stop umgr >/dev/null 2>&1) || :
n=0; while mon_pid_u "$NEWU" >/dev/null && [ "$n" -lt 1500 ]; do nap 0.002; n=$((n + 1)); done
rm -rf "$UNK" "$HOME/mon" "$HOME/pj.keep"; mv "$HOME/shim.real" "$HOME/.local/bin/claude-discord"
unset CLAUDE_DISCORD_MONITOR_TICK CLAUDE_DISCORD_MONITOR_PASS CLAUDE_DISCORD_MONITOR_HOST_CAP CLAUDE_DISCORD_MONITOR_LOCK_WAIT
echo "ok: a manager's first start in a project compat never saw moves its old-path records with the backend stopped and started, then launches"

# (g) records/projects retires: compat reads the union of the file and projects/*/project, and renames the file to
# records/projects.1.16 only once every line of it has a key dir; health --all, tui and the monitor verbs walk
# projects/*/project (a project that never started a bot after 1.18.0 is found once it does).
G1="$HOME/g one"; mkdir -p "$G1/.claude/discord-agents/gb"; printf 'DISCORD_BOT_TOKEN=tg\n' > "$G1/.claude/discord-agents/gb/.env"; echo none > "$G1/.claude/discord-agents/gb/mode"
printf "DISCORD_CHANNEL_ID='7'\nDISCORD_USER_ID='8'\nDISCORD_ALLOW_IDS=''\n" > "$G1/.claude/discord-agents/config.env"
GPF="$HOME/.claude-discord/records/projects"; printf '%s\n%s\n' "$G1" "$HOME/gone forever" > "$GPF"
out=$(cd "$HOME" && bash "$S" compat 2>&1) || { echo "FAIL: compat failed: $out"; exit 1; }
GS="$HOME/.claude-discord/projects/$(skey "$G1")"
[ -f "$GS/bots/gb/.env" ] && [ -f "$GPF" ] && [ ! -e "$GPF.1.16" ] || { echo "FAIL: compat moves a project the 1.16 list names and keeps the list while a line of it (a missing folder) has no key dir: $out / $(ls "$HOME/.claude-discord/records" 2>&1)"; exit 1; }
printf '%s\n' "$G1" > "$GPF"
out=$(cd "$HOME" && bash "$S" compat 2>&1) || { echo "FAIL: compat failed: $out"; exit 1; }
[ ! -e "$GPF" ] && [ -f "$GPF.1.16" ] && [ "$(<"$GPF.1.16")" = "$G1" ] || { echo "FAIL: the 1.16 list is renamed records/projects.1.16 once every line of it has a key dir: $out / $(ls "$HOME/.claude-discord/records" 2>&1)"; exit 1; }
doc=$(cd "$HOME" && bash "$S" health --all --json 2>/dev/null) || :
jq -e --arg p "$G1" --arg a "$M2A" 'any(.projects[]; .project == $p and (.bots | length) == 1 and .bots[0].bot == "gb") and any(.projects[]; .project == $a)' <<<"$doc" >/dev/null ||
  { echo "FAIL: health --all walks projects/*/project (the 1.16 list retired): $doc"; exit 1; }
rm -f "$GPF.1.16"; rm -rf "$G1"
echo "ok: compat reads the union of records/projects and projects/*/project, renames the file to records/projects.1.16 once every line has a key dir, and health --all walks the key dirs"
rm -rf "$M2A" "$M2B"

# boot (1.19.0): every bot of every recorded project, once. A bot `claude agents` lists with a pid (its pinned job or its
# name, started in its project) is skipped; one listed with no pid is recovered (bot recover --yes: its pinned job
# respawned); a failed recover is said and makes the exit 1. Its own HOME: boot walks every project of the machine.
BH=$HOME/bootbox; mkdir -p "$BH/pa" "$BH/pb" "$BH/bin"
for x in a b; do
  k=$(skey "$BH/p$x"); bd="$BH/.claude-discord/projects/$k/bots/b$x"; mkdir -p "$bd"
  printf '%s\n' "$(cd -P "$BH/p$x" && pwd)" > "$BH/.claude-discord/projects/$k/project"
  printf 'DISCORD_BOT_TOKEN=x\n' > "$bd/.env"; printf 'b%s000001\n' "$x" > "$bd/pinned-job"
done
# 1.19.1: a held bot (bot hold) and one with no token in its .env are skipped, nothing asked of them.
kb="$BH/.claude-discord/projects/$(skey "$BH/pb")/bots"; mkdir -p "$kb/bh" "$kb/bn"; printf 'DISCORD_BOT_TOKEN=x\n' > "$kb/bh/.env"; : > "$kb/bh/held"
printf 'DISCORD_CHANNEL_ID=1\n' > "$kb/bn/.env"
# 1.19.7: bx holds an inferred hold (session-end killed <time>) older than its newest session marker: stale (it has run since,
# then crashed), dropped, and bx is recovered; by holds the same with the marker older than the line: kept, skipped.
for x in bx by; do mkdir -p "$kb/$x/plugin-sessions"; printf 'DISCORD_BOT_TOKEN=x\n' > "$kb/$x/.env"; printf 'session-end killed %s\n' "$(dts '1 hour ago')" > "$kb/$x/held"; done
echo bx000001 > "$kb/bx/pinned-job"; : > "$kb/bx/plugin-sessions/s1"; : > "$kb/by/plugin-sessions/s1"; touch -d '2 hours ago' "$kb/by/plugin-sessions/s1" "$kb/by/plugin-sessions"
# 1.19.7: bs was stopped by a person (its pinned job's last daemon.log line is a (killed), the job no longer listed) just
# before the host went down: held is written and it is skipped; bb's last line is a (done): recovered as before.
mkdir -p "$kb/bs" "$BH/.claude"; printf 'DISCORD_BOT_TOKEN=x\n' > "$kb/bs/.env"; echo b5000001 > "$kb/bs/pinned-job"
printf '[2026-10-30T10:00:00.000Z] [bg] bg settled bb000001 (done)\n[2026-10-30T10:00:01.000Z] [bg] bg settled b5000001 (killed)\n' > "$BH/.claude/daemon.log"
printf '#!/bin/bash\ncase $1 in agents) echo %s;; respawn) echo "RESPAWN $2" >> "$HOME/calls"; [ ! -e "$KBDIR/bb/auto-start" ] || echo "PRE $2" >> "$HOME/pre"; [ ! -e "$HOME/fail" ] || exit 7;; *) echo "PLAIN $*";; esac\n' \
  "'[{\"name\":\"ba\",\"id\":\"ba000001\",\"pid\":4242,\"cwd\":\"$(cd -P "$BH/pa" && pwd)\"},{\"name\":\"bb\",\"id\":\"bb000001\",\"cwd\":\"$(cd -P "$BH/pb" && pwd)\",\"state\":\"done\"},{\"name\":\"bx\",\"id\":\"bx000001\",\"cwd\":\"$(cd -P "$BH/pb" && pwd)\",\"state\":\"done\"}]'" > "$BH/bin/claude"
chmod +x "$BH/bin/claude"
rc=0; out=$(cd "$BH" && KBDIR=$kb HOME=$BH PATH=$BH/bin:$PATH bash "$S" boot 2>&1) || rc=$?
# recover --yes: the respawn's job is in own-stop before the respawn; auto-start is there while the respawn runs (its SessionStart
# can come before the command returns) and stays after a successful one.
[ "$(<"$kb/bb/own-stop")" = bb000001 ] && [ -e "$kb/bb/auto-start" ] && grep -qx 'PRE bb000001' "$BH/pre" || { echo "FAIL: recover --yes records the respawned job in own-stop and touches auto-start before a respawn that succeeds: $(cat "$kb/bb/own-stop" "$BH/pre" 2>&1) $(ls "$kb/bb" 2>&1)"; exit 1; }
rm -f "$kb/bb/auto-start"
: > "$BH/fail"; rc2=0; out2=$(cd "$BH" && KBDIR=$kb HOME=$BH PATH=$BH/bin:$PATH bash "$S" boot 2>&1) || rc2=$?
[ "$rc $rc2" = "0 1" ] && grep -qE "^boot: .*/pa ba: running \(pid 4242\), skipped$" <<<"$out" && grep -qE "^boot: .*/pb bb: recovered$" <<<"$out" &&
  grep -qE "^boot: .*/pb bb: failed \(exit 1\): .*claude respawn bb000001 \(exit 7\)" <<<"$out2" && [ "$(<"$BH/calls")" = $'RESPAWN bb000001\nRESPAWN bx000001\nRESPAWN bb000001\nRESPAWN bx000001' ] && [ ! -e "$kb/bb/auto-start" ] && [ ! -e "$kb/bx/held" ] &&
  grep -qE "^boot: .*/pb bx: recovered$" <<<"$out" && grep -qE "^boot: .*/pb by: held \(bot by hold\), skipped$" <<<"$out" && [ -f "$kb/by/held" ] &&
  grep -qE "^boot: .*/pb bs: stopped by a person \(daemon.log, 2026-10-30T10:00:01.000Z\), held, skipped$" <<<"$out" && [ "$(cut -d' ' -f1-2 "$kb/bs/held")" = "session-end killed" ] &&
  grep -qE "^boot: .*/pb bh: held \(bot bh hold\), skipped$" <<<"$out" && grep -qE "^boot: .*/pb bn: no token, skipped$" <<<"$out" ||
  { echo "FAIL: boot skips a bot listed with a pid or stopped by a person (held written), recovers one listed without, says a failure (exit 1): rc=$rc $rc2 / $out / $out2 / $(cat "$BH/calls" 2>&1)"; exit 1; }
rm -rf "${BH:?}"
# The SessionEnd hook and person_stopped describe one order of the daemon's killed line and the hook (measured, 2.1.314: the
# line comes about 0.6 s AFTER the hook starts): neither says the hook runs behind it.
grep -q 'AFTER it starts' "$D/bin/lib/state.sh" && grep -q '0\.6 s ahead' "$D/hooks/turn/on-session-end" && ! grep -q '0\.6 s behind' "$D/hooks/turn/on-session-end" ||
  { echo "FAIL: on-session-end and state.sh agree on the order of the hook and the killed line (0.6 s ahead, not behind)"; exit 1; }
echo "ok: boot recovers every bot of the machine that runs no session (bot recover --yes), skips one that does, and exits 1 when one failed"

# access set with no terminal writes with no question when nothing in it widens who can drive the bot: no W, N or E
# line, no mode change, and every channel it adds is in the bot's own server (its main channel's, as Discord says). Else it
# prints the changes and exits 3 as before. The bot: 900 (the main channel) and 901 (open to anyone) listed; 111 (the owner)
# and 222 on 900, 333 on the DM allowlist only; 902, 903 and 950 are channels of the server (950 is not, in the stub).
NP="$HOME/ntproj"; NR=$(broot "$NP"); NS=$(pstate "$NP"); ND="$NR/nt"; mkdir -p "$ND"
printf "DISCORD_CHANNEL_ID='900'\nDISCORD_USER_ID='111'\n" > "$NS/config.env"; echo none > "$ND/mode"; printf 'DISCORD_BOT_TOKEN=tokNtUnique\n' > "$ND/.env"
NF='{"dmPolicy":"allowlist","allowFrom":["333"],"groups":{"900":{"requireMention":true,"allowFrom":["111","222"]},"901":{"requireMention":true,"allowFrom":[]}}}'
NCH='[{"id":"900","type":0},{"id":"901","type":0},{"id":"902","type":0},{"id":"903","type":5},{"id":"904","type":2}]'
# nt <words>: the call with no terminal (the $(...) takes stdout); nt_reset: the bot as it was, the guild known, curl's log and queue empty.
nt() { ARC=0; AO=$(cd "$NP" && bash "$S" access nt set "$@" 2>"$HOME/nt.err") || ARC=$?; AE=$(<"$HOME/nt.err"); }
nt_reset() { printf '%s\n' "$NF" > "$ND/access.json"; rm -f "$ND/access.log" "$ND/access.json.lock"; echo none > "$ND/mode"; printf '900 5 dev-bots %s\n' "$(date +%s)" > "$ND/channel-guild"
  : > "$CURL_LOG"; : > "$CURL_STDIN_LOG"; : > "$CURL_REPLIES"; }
# nt_refused <what> <pattern> [<reason>]: exit 3, the changes were printed (a line matching the pattern among them), the reason said on stderr
# (a line "why: <reason>" matching the third word, when given), nothing written, no log line, no post.
nt_refused() { grep -q -- "$2" <<<"$AO" && [ "$ARC" = 3 ] && grep -q -- "^claude-discord: access: why: ${3:-.}" <<<"$AE" && grep -q 'not a terminal (stdin and stdout), so nothing was changed' <<<"$AE" && [ "$(<"$ND/access.json")" = "$NF" ] && [ ! -e "$ND/access.log" ] && ! grep -q '/messages' "$CURL_LOG" ||
  { echo "FAIL: access set with no terminal must refuse (exit 3, nothing written or posted) $1: rc=$ARC $AO / $AE / $(cat "$ND/access.log" "$CURL_LOG" 2>&1)"; exit 1; }; }
# A channel of the server whose senders are all listed already (222 on 900, 333 on the DM allowlist, the owner): written, logged, one post.
nt_reset; queue_line "200 $NCH"; queue_line '200 {"id":"1"}'
nt channel+902 allow:902+222 allow:902+333
[ "$ARC" = 0 ] && grep -q '^    #902: + listens here: an @mention required, from 111, 222, 333$' <<<"$AO" && grep -q 'written without a question: no terminal here, and nothing in it widens who can drive nt' <<<"$AO" &&
  [ "$(jq -c '.groups["902"]' "$ND/access.json")" = '{"requireMention":true,"allowFrom":["111","222","333"]}' ] &&
  [[ $(<"$ND/access.log") =~ ^20[0-9-]{8}T[0-9:]{8}Z\ $(id -un)\ $(uname -n | cut -d. -f1)\ access.json:\ channel\+902\ allow:902\+222\ allow:902\+333\ \(no\ terminal,\ no\ widening\)$ ]] &&
  [ "$(wc -l < "$CURL_LOG")" = 2 ] && [ "$(grep -c 'channels/902/messages$' "$CURL_LOG")" = 1 ] && grep -q 'guilds/5/channels$' "$CURL_LOG" &&
  [ "$(sort -u "$CURL_STDIN_LOG")" = "Authorization: Bot tokNtUnique" ] && [[ $AO$AE$(<"$CURL_LOG") != *tokNt* ]] &&
  grep -q '"content":"[^"]*claude-discord access[^"]*"' "$CURL_LOG" ||
  { echo "FAIL: a channel of the bot's server whose senders are all listed already is written with no terminal: exit 0, access.log marked, one post in it: rc=$ARC $AO / $AE / $(cat "$ND/access.log" "$CURL_LOG" 2>&1)"; exit 1; }
# The server is asked for once when it is not cached: the main channel's guild, then its channels. A forum or a news channel counts; a post that fails
# is logged and is no failure; the same call with 903 (an announcement channel).
nt_reset; rm -f "$ND/channel-guild"; queue_line '200 {"id":"900","guild_id":"5"}'; queue_line "200 $NCH"; queue_line '403 {"message":"Missing Access"}'
nt channel+903 allow:903+333
[ "$ARC" = 0 ] && [ "$(jq -c '.groups["903"].allowFrom' "$ND/access.json")" = '["111","333"]' ] && [ "$(grep -c 'api/v10/' "$CURL_LOG")" = 3 ] && grep -q 'channels/900$' "$CURL_LOG" &&
  [ "$(tail -n 1 "$ND/access.log" | cut -d' ' -f4-)" = "the post in 903 failed (HTTP 403)" ] ||
  { echo "FAIL: an uncached server is asked for (channels/<main>, then its channels), a refused post is logged and the command still exits 0: rc=$ARC $AO / $AE / $(cat "$ND/access.log" "$CURL_LOG" 2>&1)"; exit 1; }
# A change with no new channel asks Discord nothing and posts nothing (a sender off a channel, one off the DM allowlist).
nt_reset; nt allow:900-222 dm-333
[ "$ARC" = 0 ] && [ "$(jq -c '.groups["900"].allowFrom' "$ND/access.json")" = '["111"]' ] && [ ! -s "$CURL_LOG" ] && grep -q '(no terminal, no widening)$' "$ND/access.log" ||
  { echo "FAIL: a change that adds no channel is written with no terminal and asks Discord nothing: rc=$ARC $AO / $AE / $(cat "$CURL_LOG" 2>&1)"; exit 1; }
# The opposites. A sender the bot lists nowhere (444), also one it has a name for but lists nowhere (555; 901, open to anyone,
# lists nobody: it makes nobody known): new to this bot, a widening. Nothing is asked of Discord for it.
printf '555 nobody\n' > "$ND/user-names"
for w in allow:902+444 allow:902+555; do
  nt_reset; queue_line "200 $NCH"; nt channel+902 "$w"
  nt_refused "for $w (a sender new to this bot)" '^  ! [^:]*: new to this bot: may write to it in #902$' 'it widens who can drive nt (the lines marked !)$'
done
[ ! -s "$CURL_LOG" ] || { echo "FAIL: a widening is refused before Discord is asked: $(<"$CURL_LOG")"; exit 1; }
nt_reset; nt channel+902 allow:902=any
nt_refused "for allow:=any on a new channel" '^  ! #902: anyone in the channel may write to it$'
nt_reset; nt channel+902 mention:902=off
nt_refused "for a new channel with no @mention required" '^  ! #902: answers every message there, with no @mention$'
nt_reset; nt allow:900=any
nt_refused "for words that widen an existing channel" '^  ! #900: from 111, 222 -> from anyone in the channel$'
# A channel that is not in the bot's server; a server nobody can name (no cache and no answer, a refusal, no token).
nt_reset; queue_line "200 $NCH"; nt channel+950
nt_refused "for a channel of another server" '^    #950: + listens here: an @mention required, from 111$' "channel not in the bot's server: 950\$" && grep -q 'guilds/5/channels$' "$CURL_LOG" || { echo "FAIL: the server's channels were not asked for"; exit 1; }
nt_reset; rm -f "$ND/channel-guild"; nt channel+902
nt_refused "when the server is not known (Discord does not answer)" '^    #902: + listens here' 'server unknown: Discord did not say which server the main channel 900 is in (HTTP 000)$'
nt_reset; queue_line '200 {"id":"900","guild_id":"5"}'; queue_line '500 {}'; rm -f "$ND/channel-guild"; nt channel+902
nt_refused "when the server's channels are refused (HTTP 500)" '^    #902: + listens here' "server unknown: the server's channels: HTTP 500\$"
nt_reset; mv "$ND/.env" "$ND/.env.off"; nt channel+902
mv "$ND/.env.off" "$ND/.env"; nt_refused "when the bot has no token" '^    #902: + listens here' 'server unknown: no token in '
# A mode change in the words, a warning in the result, an owner-less bot: each keeps the question.
nt_reset; nt allow:900-222 mode=dev-manager
nt_refused "for a change of mode" '^    mode: none -> dev-manager: it gets a hosts ledger' 'it changes the mode$' && [ "$(<"$ND/mode")" = none ] || { echo "FAIL: the mode changed"; exit 1; }
nt_reset; nt allow:900-111
nt_refused "for a change that warns (the owner taken off a channel)" '^warning: 111 is the owner of this bot' 'it has a warning (above)$'
# A list in which no entry is an id (junk, or a number: the plugin compares strings) is not "anyone" (the plugin filters on a
# non-empty list by exact element), and holds nobody known: a sender added to it is new to this bot. An id that is a string counts.
NFA=$NF
nt_with() { NF=$(jq -c --argjson l "$1" '.groups["901"].allowFrom = $l' <<<"$NFA"); nt_reset; }
nt_with '["abc"]'; nt allow:901+444
nt_refused "for a sender added to a list with no id in it" '^  ! 444: new to this bot: may write to it in #901$' 'it widens who can drive nt'
! grep -q 'from anyone' <<<"$AO" || { echo "FAIL: a list with no id in it is not read as anyone: $AO"; exit 1; }
nt_with '["abc"]'; nt allow:901=any
nt_refused "for opening a list with no id in it to anyone" '^  ! #901: from entries that are no id (nobody) -> from anyone in the channel$'
nt_with '["abc"]'; nt allow:901+222
[ "$ARC" = 0 ] && [ "$(jq -c '.groups["901"].allowFrom' "$ND/access.json")" = '["abc","222"]' ] ||
  { echo "FAIL: a sender the bot lists already goes onto a list with no id in it, which keeps its entry: rc=$ARC $AO / $AE"; exit 1; }
nt_with '[444]'; nt allow:900+444
nt_refused "for a number in another list (it never matches)" '^  ! 444: new to this bot: may write to it in #900$'
nt_with '[444]'; nt allow:901+444
nt_refused "for the number itself added as an id" '^  ! 444: new to this bot: may write to it in #901$'
nt_with '["444"]'; nt allow:900+444
[ "$ARC" = 0 ] && [ "$(jq -c '.groups["900"].allowFrom' "$ND/access.json")" = '["111","222","444"]' ] ||
  { echo "FAIL: a string id in another list is known: rc=$ARC $AO / $AE"; exit 1; }
# What the plugin does with allowFrom (server.ts: `allowFrom ?? []`, filtered only when .length > 0, with .includes(id)): a list
# filters by exact element, a non-empty STRING by substring ("111 222" lets 111 and 222 in), and a number, a boolean, an object,
# null, "" and {} have no positive .length, so they let ANYONE in. A number, a boolean or an object reads as anyone here too: a
# sender put on it narrows it (and the owner is warned when that locks them out); a removal never empties it. Only null (and an
# absent key) is a canonical shape, though: every other value that is not a list of strings gets an N line, so a call with no
# terminal never writes while one exists (the plugin's reading of it is not modelled, it is asked about at a terminal).
nt_with 'null'; nt allow:901+222
[ "$ARC" = 0 ] && grep -q '^    #901: from anyone -> from 222$' <<<"$AO" && [ "$(jq -c '.groups["901"].allowFrom' "$ND/access.json")" = '["222"]' ] ||
  { echo "FAIL: an allowFrom that is null is anyone, a sender put on it narrows it: rc=$ARC $AO / $AE"; exit 1; }
for nt_v in '7' 'true' 'false' '{"a":1}' 'null' '""' '{}' '{"length":1}' '[1]' '["a",2]'; do
  nt_t=$(jq -r type <<<"$nt_v")
  if [ "$nt_v" != null ]; then
    for nt_w in allow:901+222 allow:901+444 channel-901 allow:900-222; do
      nt_with "$nt_v"; nt $nt_w
      nt_refused "for $nt_w with an allowFrom that is $nt_v" "^warning: #901: allowFrom ($nt_t) is not what claude-discord writes: set it at a terminal\$"
    done
  fi
  case $nt_v in '{"length":1}'|'[1]'|'["a",2]') continue;; esac
  nt_with "$nt_v"; nt allow:901=any
  [ "$ARC" = 0 ] && [[ $AO == *"already so; nothing to change"* ]] || { echo "FAIL: allow:901=any on an allowFrom that is $nt_v (already anyone) changes nothing: rc=$ARC $AO / $AE"; exit 1; }
done
# A non-empty string is a substring filter in the plugin: read as a list with no id (nobody known), and the N line asks for a terminal,
# so a no-terminal call never writes while one exists (the plugin's "111 222" lets 111 and 222 in, which no id test here can say).
for nt_v in '"111"' '"111 222"' '"x111x"'; do
  for nt_w in allow:900-222 channel-901 allow:901+222; do
    nt_with "$nt_v"; nt $nt_w
    nt_refused "for $nt_w with an allowFrom that is the string $nt_v" '^warning: #901: allowFrom (string) is not what claude-discord writes: set it at a terminal$' 'it has a warning (above)$'
  done
done
nt_with '"111"'; nt allow:901-999
[ "$ARC" = 2 ] && grep -q '^claude-discord: access: allow:901: that would leave no sender' <<<"$AE" && [ "$(<"$ND/access.json")" = "$NF" ] ||
  { echo "FAIL: a removal on a string allowFrom would leave no sender and is refused (exit 2): rc=$ARC $AO / $AE"; exit 1; }
# The owner (111) locked out by a narrowing or a removal while 900 lists only 222 and 901 holds a value: the open readings (a number,
# a boolean, an object) warn of the owner; the controls ([] and ["111"]) still do; strings are caught by the N line above.
NFL=$(jq -c '.groups["900"].allowFrom = ["222"]' <<<"$NFA")
for nt_v in '[]' '["111"]' '7' 'true' '{"a":1}'; do
  for nt_w in channel-901 allow:901+222; do
    [ "$nt_v $nt_w" != '["111"] allow:901+222' ] || continue   # 111 stays on the list: the owner is not cut off
    NFA_SAVE=$NFA; NFA=$NFL; nt_with "$nt_v"; NFA=$NFA_SAVE; nt $nt_w
    nt_refused "for $nt_w with 111 the owner and 901 holding $nt_v" "^warning: 111 is the owner of this bot (DISCORD_USER_ID) and no channel it listens in lets them write to it any more\$" 'it has a warning (above)$'
  done
done
# The sentinel is no person: "abc" stays on the list when 222 is added, so nobody is shown leaving, and a list is told as entries that are no id.
nt_with '["abc"]'; nt allow:901+222
! grep -q 'not-an-id' <<<"$AO" || { echo "FAIL: the sentinel of a list with no id is shown as a person: $AO"; exit 1; }
# The DM allowlist is guarded the same way: a top-level allowFrom that is not a list of strings (here the string "111 222", which the
# plugin matches by substring) is warned of, a no-terminal call is refused, and it reads as a list nobody is on: dm=off and dm-222
# are changes (an allowlist -> off), not "already so" (dm_allow read [] and said nothing changed), and the sentinel is no person.
for nt_v in '"111 222"' '7' '{"length":1}'; do
  nt_t=$(jq -r type <<<"$nt_v")
  for nt_w in dm=off dm-222 dm+444 allow:900-222; do
    [ "$nt_v" != 7 ] || case $nt_w in dm=off|dm-222) continue;; esac   # a number is no filter (anyone, "off" already): those change nothing
    NF=$(jq -c --argjson l "$nt_v" '.allowFrom = $l' <<<"$NFA"); nt_reset; nt $nt_w
    nt_refused "for $nt_w with a top-level allowFrom that is $nt_v" "^warning: DMs: allowFrom ($nt_t) is not what claude-discord writes: set it at a terminal\$"
  done
done
NF=$(jq -c '.allowFrom = "111 222"' <<<"$NFA"); nt_reset; nt dm=off
! grep -q 'already so' <<<"$AO" && grep -q '^    DMs: allowlist -> off$' <<<"$AO" || { echo "FAIL: dm=off on a top-level allowFrom \"111 222\" is a change, not already so: rc=$ARC $AO / $AE"; exit 1; }
nt_reset; nt dm-222
! grep -q 'already so' <<<"$AO" && ! grep -q 'not-an-id' <<<"$AO" || { echo "FAIL: dm-222 on a top-level allowFrom \"111 222\" is no 'already so' and shows no sentinel person: rc=$ARC $AO / $AE"; exit 1; }
# The rest of the shape claude-discord writes. The plugin reads a group of 7 or "x" as a channel that listens (anyone, with an @mention),
# a requireMention of "no" as true and of 0 as false, an unknown dmPolicy as pairing, and groups as [] as a server listening nowhere:
# none of that is modelled, so each gets an N line and a legitimate add with no terminal is refused.
nt_odd() { NF=$(jq -c "$1" <<<"$NFA"); nt_reset; queue_line "200 $NCH"; queue_line '200 {"id":"1"}'; nt channel+902 allow:902+222
  nt_refused "for an add with $1" "$2" "${3:-it has a warning (above)\$}"; }   # groups=[]: no group to keep, so the add widens and says so first
nt_odd '.groups["901"] = 7' '^warning: #901: the group (number) is not what claude-discord writes: set it at a terminal$'
nt_odd '.groups["901"] = "x"' '^warning: #901: the group (string) is not what claude-discord writes: set it at a terminal$'
nt_odd '.groups["901"] = {"requireMention":"no"}' '^warning: #901: requireMention (string) is not what claude-discord writes: set it at a terminal$'
nt_odd '.groups["901"].requireMention = 0' '^warning: #901: requireMention (number) is not what claude-discord writes: set it at a terminal$'
nt_odd '.groups = []' '^warning: groups (array) is not what claude-discord writes: set it at a terminal$' 'it widens who can drive nt'
nt_odd '.dmPolicy = "closed"' '^warning: DMs: dmPolicy (string) is not what claude-discord writes: set it at a terminal$'
nt_odd '.dmPolicy = 7' '^warning: DMs: dmPolicy (number) is not what claude-discord writes: set it at a terminal$'
nt_odd '.mentionPatterns = [""]' '^warning: mentionPatterns (array) is not what claude-discord writes: set it at a terminal$'
# The opposite: a canonical file (arrays of strings, absent keys, no top-level allowFrom) still writes a same-guild add with no terminal.
NF='{"dmPolicy":"allowlist","groups":{"900":{"requireMention":true,"allowFrom":["111","222"]},"901":{"requireMention":true}}}'
nt_reset; queue_line "200 $NCH"; queue_line '200 {"id":"1"}'; nt channel+902 allow:902+222
[ "$ARC" = 0 ] && [ "$(jq -c '.groups["902"].allowFrom' "$ND/access.json")" = '["111","222"]' ] && ! grep -q 'allowFrom is not a list' <<<"$AO" ||
  { echo "FAIL: a canonical file (absent keys, arrays of strings) still takes a same-guild add with no terminal: rc=$ARC $AO / $AE"; exit 1; }
NF=$NFA
# peers.json is shared: it lists this bot too (nt, 555). The dev-manager peer warning is about the peers that go onto the lists
# (pb, 666), never the bot itself (nt, 555), so narrowing an open channel while entering dev-manager names no peer line for 555.
printf '{"peers":[{"name":"nt","bot_id":"555"},{"name":"pb","bot_id":"666"}]}\n' > "$NS/peers.json"
nt_reset; nt mode=dev-manager allow:901+111
[ "$ARC" = 3 ] || { echo "FAIL: entering dev-manager with a peer is refused with no terminal: rc=$ARC $AO / $AE"; exit 1; }
! grep -q '555.*is a peer dev bot' <<<"$AO" || { echo "FAIL: the bot itself (nt, 555 in the shared peers.json) is named as a peer it cuts off: $AO"; exit 1; }
printf '{"peers":[{"name":"nt","bot_id":"555"}]}\n' > "$NS/peers.json"
nt_reset; nt mode=dev-manager allow:901+111
nt_refused "for entering dev-manager (the mode)" '^    mode: none -> dev-manager' 'it changes the mode$'
! grep -q 'peer dev bot' <<<"$AO" || { echo "FAIL: peers.json listing only the bot gives a peer warning: $AO"; exit 1; }
# Entering dev-manager with an allowFrom that is no list (a string, a number): the peer merge leaves that group as it is, the diff
# is made, and it is not "not valid JSON".
printf '{"peers":[{"name":"pb","bot_id":"666"}]}\n' > "$NS/peers.json"
for nt_v in '"111"' '7' '{"a":1}'; do
  nt_with "$nt_v"; nt mode=dev-manager
  [ "$ARC" = 3 ] && ! grep -q 'not valid JSON' <<<"$AE" && grep -q '^    mode: none -> dev-manager' <<<"$AO" && [ "$(<"$ND/access.json")" = "$NF" ] ||
    { echo "FAIL: entering dev-manager with an allowFrom that is $nt_v must give a diff, not the JSON error: rc=$ARC $AO / $AE"; exit 1; }
done
# The bot is left out of the peers by its bot-id when it is kept (bot-id 555), else by name: a peer of the bot's own name and another id
# (666) is a peer and goes onto the lists (new to this bot), while the peer with the bot's id (555, whatever its name) does not.
printf '{"peers":[{"name":"nt","bot_id":"666"},{"name":"other","bot_id":"555"}]}\n' > "$NS/peers.json"
NF=$NFA; printf '555\n' > "$ND/bot-id"; nt_reset; nt mode=dev-manager
grep -q '^  ! nt (666): new to this bot: may write to it in #900$' <<<"$AO" && ! grep -q '555.*new to this bot' <<<"$AO" ||
  { echo "FAIL: with bot-id 555, the peer named like the bot (666) goes onto the lists and the one with its id (555) does not: rc=$ARC $AO / $AE"; exit 1; }
rm -f "$ND/bot-id"; nt_reset; nt mode=dev-manager
! grep -q '666.*new to this bot' <<<"$AO" && grep -q '555.*new to this bot' <<<"$AO" ||
  { echo "FAIL: with no bot-id the bot is left out by name (666 not added, 555 added): rc=$ARC $AO / $AE"; exit 1; }
printf '{"peers":[]}\n' > "$NS/peers.json"
NF=$NFA
# The owner (111) can no longer write anywhere: a removal of the channels that listed them, when no channel left lets them
# (an open channel does). The main channel (900, config.env) no longer listened in is warned of by itself.
NFB='{"dmPolicy":"allowlist","allowFrom":["333"],"groups":{"900":{"requireMention":true,"allowFrom":["222"]},"905":{"requireMention":true,"allowFrom":["111"]},"906":{"requireMention":true,"allowFrom":[]}}}'
NFO='warning: 111 is the owner of this bot (DISCORD_USER_ID) and no channel it listens in lets them write to it any more$'
NFM='warning: the main channel of the bot, #900, is no longer one it listens in: its session prompt, its hooks and health still use it$'
NF=$NFB; nt_reset; nt channel-905 channel-906
nt_refused "for the owner's last channels removed" "^$NFO" 'it has a warning (above)$'
! grep -q 'main channel' <<<"$AO" || { echo "FAIL: the main channel is still listened in: $AO"; exit 1; }
NF=$NFB; nt_reset; nt channel-900
nt_refused "for the main channel removed while others stay" "^$NFM"
! grep -q 'owner of this bot' <<<"$AO" || { echo "FAIL: the owner can still write: $AO"; exit 1; }
NF=$NFB; nt_reset; nt channel-905
[ "$ARC" = 0 ] && [ "$(jq -c '.groups | keys' "$ND/access.json")" = '["900","906"]' ] && [ ! -s "$CURL_LOG" ] ||
  { echo "FAIL: the owner's channel removed while an open one stays is no warning: rc=$ARC $AO / $AE"; exit 1; }
NF=$(jq -c '.groups["900"].allowFrom = ["111","222"]' <<<"$NFB"); nt_reset; nt channel-905
[ "$ARC" = 0 ] || { echo "FAIL: the owner's channel removed while another lists them is no warning: rc=$ARC $AO / $AE"; exit 1; }
# Narrowing counts as removal: the open channel the owner had is cut down to others, or removed, and none lets them write.
NFN='{"dmPolicy":"allowlist","allowFrom":["333"],"groups":{"900":{"requireMention":true,"allowFrom":["222"]},"906":{"requireMention":true,"allowFrom":[]}}}'
NF=$NFN; nt_reset; nt channel-906
nt_refused "for the owner's only open channel removed" "^$NFO" 'it has a warning (above)$'
NF=$NFN; nt_reset; nt allow:906+222
nt_refused "for the owner's open channel narrowed to others" "^$NFO" 'it has a warning (above)$'
NF=$(jq -c '.groups["900"].allowFrom = ["111","222"]' <<<"$NFN"); nt_reset; nt allow:906+222
[ "$ARC" = 0 ] && ! grep -q 'owner of this bot' <<<"$AO" || { echo "FAIL: an open channel narrowed while another still lists the owner is no warning: rc=$ARC $AO / $AE"; exit 1; }
NF=$NFA; nt_reset; nt channel-900 channel-901
nt_refused "for every channel removed" "^$NFO" && grep -q "^$NFM" <<<"$AO" || { echo "FAIL: every channel removed warns of the owner and of the main channel: $AO"; exit 1; }
NF=$NFA
# The Discord calls share the one budget a_own began (12 s; here 2): a post past it is not sent and is logged as failed.
nt_reset; queue_line "200 $NCH"; queue_line '200 {"id":"1"}'; echo 3 > "$HOME/curl.delay"
CLAUDE_DISCORD_ACCESS_BUDGET=2 nt channel+902 allow:902+222
rm -f "$HOME/curl.delay"
[ "$ARC" = 0 ] && grep -q 'guilds/5/channels$' "$CURL_LOG" && ! grep -q 'channels/902/messages' "$CURL_LOG" && [ "$(jq -c '.groups["902"].allowFrom' "$ND/access.json")" = '["111","222"]' ] &&
  [ "$(tail -n 1 "$ND/access.log" | cut -d' ' -f4-)" = "the post in 902 failed (HTTP 000)" ] ||
  { echo "FAIL: a post past the budget the channel check began is not sent, is logged as failed, and the change stays written: rc=$ARC $AO / $AE / $(cat "$ND/access.log" "$CURL_LOG" 2>&1)"; exit 1; }
nt_reset
# With a terminal nothing changes: the same words are asked about, and no is no.
nt_reset; queue_line "200 $NCH"
ARC=0; AO=$(printf 'n\nn\n' | python3 -c 'import os, pty, sys; sys.exit(os.waitstatus_to_exitcode(pty.spawn(sys.argv[1:])))' bash -c 'cd "$1" && exec bash "$2" access nt set channel+902 allow:902+222' x "$NP" "$S" 2>&1) || ARC=$?
[ "$ARC" = 4 ] && grep -q '^Apply this change? \[y/N\]' <<<"$AO" && [ "$(<"$ND/access.json")" = "$NF" ] && [ ! -s "$CURL_LOG" ] && [ ! -e "$ND/access.log" ] ||
  { echo "FAIL: at a terminal a change that widens nothing is still asked about: rc=$ARC $AO"; exit 1; }
nt_reset; rm -rf "${ND:?}" "${NP:?}"
echo "ok: access set with no terminal writes with no question when nothing widens (no new sender, no open channel, no @mention dropped, no mode, no warning) and every added channel is in the bot's own server: logged as such, one post in each new channel (a refused post is logged, not a failure); a new sender, an open or mention-free channel, a mode, a warning, another server or one nobody can name keep exit 3 with nothing written; at a terminal the question is still asked"

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
