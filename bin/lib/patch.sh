# sourced by bin/claude-discord: sync_runtime same_tree sync_compat compat_if_stale patch_official; the patch verb

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

# Drops recorded installs whose path is gone (a dangling link counts as gone).
same_tree() {
  diff -r "$1" "$2" >/dev/null 2>&1 &&
    [ "$(cd "$1" && find . -type f -perm -100 | sort)" = "$(cd "$2" && find . -type f -perm -100 | sort)" ]
}
# sync_compat <plugin>: rebuilds ~/.claude-discord/compat from that plugin when
# it differs (a write through a link included), in a new directory swapped in by
# rename, so a hook already running from the old copy keeps its open file.
# compat/VERSION holds the plugin's HEAD sha (head_sha), written last.
# rename(2) cannot replace a non-empty directory, hence two renames; a settings
# hook started between them finds no file and its entry's -x test skips it.
# Writers (bots starting at once, on a host and in its containers, or natively
# and in Docker Desktop on one Mac) swap one at a time under compat.lock, taken
# by mkdir: atomic on every filesystem they share, across containers and
# kernels, where pids collide and flock may not reach. The copy is built first,
# in a random-named directory (no pid: unique across kernels), so the lock
# covers only a re-check and the renames. The lock holds an owner token (the
# random suffix of that directory), and a writer releases only a lock holding
# its own. A lock older than 5 s is taken for a dead writer's (a bot start must
# not wait long, and a live holder past it is harmless, see below): it is broken by
# renaming it to a name of our own, which exactly one breaker wins, and dropped
# only if it is still the lock judged stale (same inode and token). The lock
# only saves work: two holders at once (a holder stalled past the stale bound, a
# break racing a re-take) can only fail one refresh (rc 1, retried at the next
# start), never nest or leave compat/ absent: both renames are perl's rename(2),
# never mv (which moves a copy INTO a compat/ another writer, or an older
# release's taking no lock, just put in place), and our old compat/ goes aside
# into our own random directory, never to a shared name. A subshell, so its
# traps (our old copy back if compat/ is gone, the lock released) stay out of
# the caller. The bounds are read only here, so the suite can shrink them.
sync_compat() (
  c=$helpers/compat l=$helpers/compat.lock t0=$SECONDS
  st=${CLAUDE_DISCORD_COMPAT_STALE_S:-5} gu=${CLAUDE_DISCORD_COMPAT_WAIT_S:-10} ps=${CLAUDE_DISCORD_COMPAT_STEP_S:-0.1}
  n=$(mktemp -d "$c.new.XXXXXX") || return 1
  b=$n/compat o=$n/old tok=${n##*.}   # unique among writers while $n exists (mktemp -d), and no pid
  trap 'rm -rf "$n"' EXIT; trap 'exit 1' INT TERM HUP
  mkdir "$b" "$b/hooks" || return 1
  for t in turn peers lib autoresearchclaw; do cp -R "$1/hooks/$t" "$b/hooks/" || return 1; done
  cp -R "$1/tools" "$1/rules" "$b/" && head_sha "$1" > "$b/VERSION" || return 1
  until mkdir "$l" 2>/dev/null; do
    # Judged stale: the lock's inode and token, so the break can tell it from a newer lock at the same path.
    id=$(perl -e '@s = lstat $ARGV[0] or exit; $s[9] < time - $ARGV[1] or exit; open F, "<", "$ARGV[0]/owner"; chomp($t = <F> // ""); print "$s[1] $t"' "$l" "$st")
    [ -n "$id" ] && perl -e 'use File::Path "rmtree"; ($l, $k, $id) = @ARGV; rename $l, $k or exit 1; @s = lstat $k; open F, "<", "$k/owner"; chomp($t = <F> // "");
      if ("$s[1] $t" eq $id) { rmtree $k; exit 0 } rename $k, $l; exit 1' "$l" "$l.broken.$tok" "$id" && continue
    # The give-up bound is past the stale bound, so a dead holder's lock is broken before a waiter gives up.
    [ "$SECONDS" -lt $((t0 + gu)) ] || { echo "claude-discord: $l stays held; compat/ not refreshed" >&2; return 1; }
    sleep "$ps"
  done
  # compat/ gone: our old copy (unless we landed) goes back; $n holding it stays if that fails with compat/ still gone.
  # set -e is back on inside a trap: a failing command would skip the rest (the lock release) and set our status, hence || :.
  trap '{ has_path "$c" || [ ! -d "$o" ] || perl -e "rename shift, shift or exit 1" "$o" "$c" || has_path "$c"; } && rm -rf "$n" || :; IFS= read -r t 2>/dev/null < "$l/owner" && [ "$t" = "$tok" ] && rm -rf "$l" || :' EXIT
  printf '%s\n' "$tok" > "$l/owner" || { rm -rf "$l"; return 1; }   # an ownerless lock would hold every writer off until stale
  # compat/ gone: a writer killed between its renames left the only copy in its compat.new.*/old; the newest goes back.
  has_path "$c" || perl -e '$c = shift; ($o) = sort { (lstat "$b/..")[9] <=> (lstat "$a/..")[9] } grep { -d } @ARGV; rename $o, $c if $o' "$c" "$c".new.*/old || :
  # An old compat.new.* (its old/ too), compat.old.* or compat.lock.broken.* is a dead writer's or an older release's
  # (a fresh compat.new.* may be a writer still building); perl only when there is one besides ours.
  for t in "$c".new.* "$c".old.* "$l".broken.*; do
    [ "$t" = "$n" ] || ! has_path "$t" || { perl -MFile::Path=rmtree -e 'for (@ARGV) { @s = lstat; rmtree $_ if @s && $s[9] < time - 600 }' "$c".new.* "$c".old.* "$l".broken.*; break; }
  done
  [ -d "$c" ] && [ ! -L "$c" ] && same_tree "$c" "$b" && return 0   # current already (another writer's swap while we built or waited)
  { ! has_path "$c" || perl -e 'rename shift, shift or exit 1' "$c" "$o"; } && perl -e 'rename shift, shift or exit 1' "$b" "$c" && { rm -rf "$o"; return 0; }
  [ -d "$c" ] && same_tree "$c" "$b"   # another writer's copy landed first: fine if it is ours; else the trap restores
)
# compat_if_stale: run at a bot's startup and resume (on-session-start runs
# `patch --compat`). A compat/ whose VERSION is not this plugin's HEAD sha (a
# `git pull` by hand in the source clone, a copy older than the stamp) or
# that holds a file newer than its VERSION (the previous release's install.sh
# writing through the links) is rebuilt; none at all is left to setup (unless
# a killed writer left it in a compat.new.*/old, which goes back). Only by
# the source clone compat/ is built from (as in remove_old_install): with no
# source clone, compat/ is built by setup and update only, else two clones of
# different versions would flip it back and forth at each bot start.
compat_if_stale() {
  local c=$helpers/compat have=""
  [ -d "$c" ] && [ ! -L "$c" ] || { ! has_path "$c" && [ -n "$(ls -d "$c".new.*/old 2>/dev/null)" ]; } || return 0
  [ "$helpers/source" -ef "$self_root" ] || return 0
  IFS= read -r have 2>/dev/null < "$c/VERSION" || :
  [ "$have" != "$(head_sha "$self_root")" ] || [ -n "$(find "$c" -type f -newer "$c/VERSION" 2>/dev/null)" ] || return 0
  sync_compat "$self_root" && { touch "$c/VERSION" 2>/dev/null || :; }   # an identical rebuild is not redone at every start
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
#                   so a token replaced with `bot <name> token` needs no restart
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
    cd_login=';(async () => { let bad = ""; const read = () => { let m; try { m = readFileSync(ENV_FILE, "utf8").match(/^DISCORD_BOT_TOKEN=(.+)$/m) } catch {} return m?.[1].trim() || "" }; const pick = () => { const v = bad ? read() : (TOKEN || read()); return v && v !== bad ? v : "" }; for (;;) { const t = await new Promise<string>(ok => { const v = pick(); if (v) return ok(v); const i = setInterval(() => { const w = pick(); if (w) { clearInterval(i); ok(w) } }, 10000) }); try { await client.login(t); await new Promise<void>(ok => { const f = (ev: any) => { if (ev?.code === 4004) { client.off("shardDisconnect", f); ok() } }; client.on("shardDisconnect", f) }); bad = t; process.stderr.write("discord channel: the gateway refused the token (4004); waiting for a new one in .env (re-read every 10 s)\n") } catch (e) { if ((e as any)?.code !== "TokenInvalid") throw e; bad = t; process.stderr.write("discord channel: the token was refused; waiting for a new one in .env (re-read every 10 s)\n") } } })().catch('
    if grep -qF '"shardDisconnect"' "$f"; then :
    elif grep -qF 'code !== "TokenInvalid"' "$f"; then
      # 1.9.4 to 1.13.x waited out a refused token only at the login: the login loop is replaced by one that also waits
      # after a 4004, once.
      if CD_LOGIN=$cd_login perl -0777 -pi -e 's/^;\(async \(\) => \{ let bad = "";[^\n]*?\}\)\(\)\.catch\(/$ENV{CD_LOGIN}/m and $ok = 1; END { exit !$ok }' "$f"; then mark "$f"
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
  crc=0; [ "${2:-}" != --compat ] || compat_if_stale || crc=1
  patch_official || crc=1; exit "$crc"
fi
