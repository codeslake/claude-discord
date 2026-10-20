# sourced by bin/claude-discord: sync_runtime patch_official; the patch verb

# The runtime files the patched official plugin imports live at a stable path,
# ~/.claude-discord/runtime/, because the plugin cache is machine-wide while
# clones are per project. setup and update copy them from the real clone.
# runtime/VERSION names the plugin version that wrote it. Two installs of
# different versions share runtime/ and the patched cache, so an older one
# leaves a newer copy alone (runtime_newer, said once per run; patch_official
# then leaves the cache alone too) instead of flipping it back at every start.
# Only a readable, strictly newer stamp wins: a garbled one is overwritten.
sync_runtime() {
  local rt=$HOME/.claude-discord/runtime f mine have=""
  mine=$(plugin_version "$self_root")
  [ -d "$rt" ] || mkdir -p "$rt" || return 1
  [ ! -f "$rt/VERSION" ] || IFS= read -r have < "$rt/VERSION" || :
  if [ -n "$have" ] && [ "$have" != "$mine" ] && ver_ge "$have" "$mine"; then
    [ -n "${runtime_newer:-}" ] || echo "claude-discord: ~/.claude-discord/runtime is from $have, newer than this $mine; left as it is, and so is the plugin cache until that newer version runs (its next start or update patches it)" >&2
    runtime_newer=$have; return 0
  fi
  for f in discord-chunk.ts discord-proxy.ts; do
    cmp -s "$self_root/runtime/$f" "$rt/$f" || cp "$self_root/runtime/$f" "$rt/$f" || return 1
  done
  [ "$have" = "$mine" ] || printf '%s\n' "$mine" > "$rt/VERSION"
}

# Patches the official discord plugin's install(s) so bots can work together.
# Every version dir in the cache, not just the active one: an auto-update adds
# an unpatched dir while bots run on the old one, and the next start, respawn
# or config-changing /reload-plugins uses the new one (measured, 2.1.296).
# Six patches, each idempotent because its pattern is gone once applied:
#   bot-authors     let other bots reach access.json's allowFrom gate
#   ignore-everyone @everyone/@here wake no bot
#   chunk           fence-safe chunking, imported from the stable runtime copy
#                   (an import of any other path is rewritten to it)
#   late-token      no token at start waits instead of exiting (Claude Code would
#                   mark the server failed): .env is re-read every 10 s and the
#                   client logs in once a token is there, so a bot started before
#                   its Discord bot existed needs no restart; a token Discord
#                   refuses (TokenInvalid) is waited out the same way until .env
#                   holds a different one, and so, since 1.14.0, is a token the
#                   gateway refuses after the login (close 4004: it was reset),
#                   so a token replaced with `bot <name> token` needs no restart;
#                   any other login error (network down, proxy refusing) is
#                   logged and retried, forever, 10 s doubling to 5 min (an error
#                   past the gateway costs an identify, 1000 a day): rethrown, it
#                   ended the server, and Claude Code never restarts a dead MCP server
#   proxy           bunfig preload pinning fetch and WebSocket to HTTPS_PROXY
#   failure-cache   a per-bot env in .mcp.json, so Claude Code's 15-minute MCP
#                   failure cache (keyed on the config hashed after ${VAR}
#                   expansion) no longer blocks every bot for one bot's failure
# The runtime files are copied to ~/.claude-discord/runtime/ because the plugin
# cache is machine-wide while clones are per project. Exit 1 names the file and
# patch whose pattern moved; the others are still applied.
patch_official() {
  local rt=$HOME/.claude-discord/runtime d f rc=0 changed=""
  mark() { case " $changed " in *" $1 "*) ;; *) changed="$changed $1";; esac; }   # list a file once
  sync_runtime || return 1
  [ -z "${runtime_newer:-}" ] || return 0   # a newer version's runtime: that code patches the cache
  for d in "$HOME"/.claude/plugins/cache/claude-plugins-official/discord/*/; do
    d=${d%/}; f=$d/server.ts   # no trailing slash, so messages name the file cleanly
    [ -f "$f" ] || continue
    if grep -q 'if (msg.author.bot) return' "$f"; then
      perl -pi -e 's/^(\s*)if \(msg\.author\.bot\) return$/$1if (msg.author.id === client.user?.id) return/' "$f"; mark "$f"
    elif ! grep -qF 'msg.author.id === client.user?.id' "$f"; then
      echo "claude-discord: patch: $f: bot-authors no longer matches" >&2; rc=1
    fi
    if grep -q 'msg.mentions.has(client.user))' "$f"; then
      perl -pi -e 's/msg\.mentions\.has\(client\.user\)\)/msg.mentions.has(client.user, { ignoreEveryone: true }))/' "$f"; mark "$f"
    elif ! grep -qF 'ignoreEveryone: true' "$f"; then
      echo "claude-discord: patch: $f: ignore-everyone no longer matches" >&2; rc=1
    fi
    if grep -qE '^[[:space:]]*const chunks = chunk\(text, limit, mode\);?[[:space:]]*$' "$f"; then
      CHUNK_TS=$rt/discord-chunk.ts perl -pi -e 's/^(\s*)const chunks = chunk\(text, limit, mode\)(;?\s*)$/$1const chunks = (await import("$ENV{CHUNK_TS}")).chunk(text, limit, mode)$2/' "$f"; mark "$f"
    elif grep -qF "import(\"$rt/discord-chunk.ts\")).chunk(text, limit, mode)" "$f"; then :
    elif grep -qE 'import\("[^"]*"\)\)\.chunk\(text, limit, mode\)' "$f"; then
      # An earlier release imported it from another path (~/.claude-discord/discord-chunk.ts, a compat link that goes in a later release).
      CHUNK_TS=$rt/discord-chunk.ts perl -pi -e 's/import\("[^"]*"\)\)\.chunk\(text, limit, mode\)/import("$ENV{CHUNK_TS}")).chunk(text, limit, mode)/' "$f"; mark "$f"
    else
      echo "claude-discord: patch: $f: chunk no longer matches" >&2; rc=1
    fi
    # Both anchors in one perl run, so a server.ts gets both edits or neither;
    # the replacement text comes in through env, so perl interpolates none of it.
    # The leading ; stops ASI from calling the line above (the real file ends client.once(...) with no ;) with this function.
    cd_login=';(async () => { let bad = "", wait = 10000; const read = () => { let m; try { m = readFileSync(ENV_FILE, "utf8").match(/^DISCORD_BOT_TOKEN=(.+)$/m) } catch {} return m?.[1].trim() || "" }; const pick = () => { const v = bad ? read() : (TOKEN || read()); return v && v !== bad ? v : "" }; for (;;) { const t = await new Promise<string>(ok => { const v = pick(); if (v) return ok(v); const i = setInterval(() => { const w = pick(); if (w) { clearInterval(i); ok(w) } }, 10000) }); try { await client.login(t); wait = 10000; await new Promise<void>(ok => { const f = (ev: any) => { if (ev?.code === 4004) { client.off("shardDisconnect", f); ok() } }; client.on("shardDisconnect", f) }); bad = t; process.stderr.write("discord channel: the gateway refused the token (4004); waiting for a new one in .env (re-read every 10 s)\n") } catch (e) { if ((e as any)?.code !== "TokenInvalid") { process.stderr.write("discord channel: login failed (" + String((e as any)?.message ?? e).replace(/\/\/[^@\/\s]*@/g, "//") + "); retrying in " + wait / 1000 + " s\n"); await new Promise(r => setTimeout(r, wait)); wait = Math.min(wait * 2, 300000); continue } bad = t; process.stderr.write("discord channel: the token was refused; waiting for a new one in .env (re-read every 10 s)\n") } } })().catch('
    if grep -qF 'login failed (' "$f"; then :
    elif grep -qF 'code !== "TokenInvalid"' "$f"; then
      # 1.9.4 to 1.19.x: the login loop is replaced, once. 1.9.4 to 1.13.x waited out a refused token only at the login (not a 4004
      # after it); every one rethrew any other login error (network down), which ended the server.
      if CD_LOGIN=$cd_login perl -0777 -pi -e 's/^;\(async \(\) => \{ let bad = ""[;,][^\n]*?\}\)\(\)\.catch\(/$ENV{CD_LOGIN}/m and $ok = 1; END { exit !$ok }' "$f"; then mark "$f"
      else echo "claude-discord: patch: $f: late-token no longer matches" >&2; rc=1
      fi
    elif grep -qF 'no token yet; waiting for it' "$f"; then
      # 1.9.3 patched the exit already but its login gave up on a refused token: only the login is replaced.
      if CD_LOGIN=$cd_login perl -0777 -pi -e 's/^new Promise<string>\(ok => \{ if \(TOKEN\) return ok\(TOKEN\);[^\n]*?\}\)\.then\(t => client\.login\(t\)\)\.catch\(/$ENV{CD_LOGIN}/m and $ok = 1; END { exit !$ok }' "$f"; then mark "$f"
      else echo "claude-discord: patch: $f: late-token no longer matches" >&2; rc=1
      fi
    elif CD_WAIT='process.stderr.write("discord channel: no token yet; waiting for it (re-read every 10 s)\n")' CD_LOGIN=$cd_login \
         perl -0777 -pi -e 'if (/^if \(!TOKEN\) \{\n(?:[ \t].*\n)*?[ \t]+process\.exit\(1\)$/m && /^client\.login\(TOKEN\)\.catch\(/m) {
             s/^(if \(!TOKEN\) \{\n(?:[ \t].*\n)*?[ \t]+)process\.exit\(1\)$/$1$ENV{CD_WAIT}/m; s/^client\.login\(TOKEN\)\.catch\(/$ENV{CD_LOGIN}/m; $ok = 1 }
           END { exit !$ok }' "$f"; then mark "$f"
    else
      echo "claude-discord: patch: $f: late-token no longer matches" >&2; rc=1
    fi
    [ "$(cat "$d/bunfig.toml" 2>/dev/null)" = "preload = [\"$rt/discord-proxy.ts\"]" ] ||
      { printf 'preload = ["%s"]\n' "$rt/discord-proxy.ts" > "$d/bunfig.toml"; mark "$d/bunfig.toml"; }
    # The key is ours, not the server's DISCORD_STATE_DIR: unset, "${DISCORD_STATE_DIR}"
    # would stay a literal string and mask the server's own default state dir for
    # a user of the official plugin without claude-discord; "${VAR:-}" expands to
    # "" (measured, 2.1.296). An earlier release's DISCORD_STATE_DIR line is removed.
    if [ -f "$d/.mcp.json" ] && ! jq -e '(.mcpServers.discord.env.CLAUDE_DISCORD_BOT == "${DISCORD_STATE_DIR:-}") and (.mcpServers.discord.env.DISCORD_STATE_DIR != "${DISCORD_STATE_DIR}")' "$d/.mcp.json" >/dev/null 2>&1; then
      # Only a file that already defines the discord server is edited (jq would
      # otherwise create a command-less one); jq_edit leaves bad JSON alone and
      # returns 0, so the result is verified, not assumed.
      jq -e '.mcpServers.discord.command' "$d/.mcp.json" >/dev/null 2>&1 &&
        jq_edit "$d/.mcp.json" '.mcpServers.discord.env = ((.mcpServers.discord.env // {}) + {CLAUDE_DISCORD_BOT: "${DISCORD_STATE_DIR:-}"})
          | if .mcpServers.discord.env.DISCORD_STATE_DIR == "${DISCORD_STATE_DIR}" then del(.mcpServers.discord.env.DISCORD_STATE_DIR) else . end'
      if jq -e '(.mcpServers.discord.env.CLAUDE_DISCORD_BOT == "${DISCORD_STATE_DIR:-}") and (.mcpServers.discord.env.DISCORD_STATE_DIR != "${DISCORD_STATE_DIR}")' "$d/.mcp.json" >/dev/null 2>&1; then
        mark "$d/.mcp.json"
      else
        echo "claude-discord: patch: $d/.mcp.json: failure-cache no longer matches" >&2; rc=1
      fi
    fi
  done
  [ -z "$changed" ] || echo "claude-discord: patched$changed"
  return "$rc"
}
# install: the plugin and what goes with it (the bootstrap's command): it reads
# no stdin at all, so a script's stdin is left alone. An install already there
# decides the scope, else project; the method is link unless --method says
# otherwise; an untrusted project gets a hint, never a question. Safe to re-run.

if [ "${1:-}" = patch ]; then
  # --compat (1.9-1.18.0: the compat copy's rebuild) is accepted and ignored for one release: a 1.17 on-session-start
  # from a stale clone still sends it.
  patch_official || exit 1; exit 0
fi
