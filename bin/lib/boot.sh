# sourced by bin/claude-discord: the boot verb

# boot (1.19.0): every bot of this machine's recorded projects brought back once, for a machine or container that just
# started (nothing respawns a bot by itself after a reboot or a daemon's death: 2026-10-20 on lmd79). A bot that
# `claude agents` lists with a pid, by its pinned job or its name, started in its project, runs: skipped, so a session a
# person just started from the agents view gets no twin. Every other bot: `bot <bot> recover --yes`, one at a time, in
# the foreground, which decides respawn, takeover or a fresh start and refuses two listed sessions as it always does.
# A held bot (bot <bot> hold, 1.19.1) and one with no token in its .env are skipped too.
# One line per bot; exit 0, or 1 when `claude agents` failed or a recover did.
if [ "${1:-}" = boot ]; then
  [ $# = 1 ] || { echo "usage: claude-discord boot" >&2; exit 2; }
  command -v jq >/dev/null 2>&1 || { echo "claude-discord: boot needs jq" >&2; exit 1; }
  bt_agents=$(claude agents --json 2>/dev/null) && printf '%s' "${bt_agents:-null}" | jq -e 'type == "array"' >/dev/null 2>&1 ||
    { echo "claude-discord: boot: 'claude agents --json' failed, so what runs is unknown; nothing was run" >&2; exit 1; }
  bt_rc=0
  proj_arr
  for p in ${pl[@]+"${pl[@]}"}; do
    proj_dirs "$p"
    [ -n "$pd_new" ] && [ -d "$p" ] || continue
    for bd in "$pd_root"/*/; do
      bd=${bd%/}; b=${bd##*/}
      [ -f "$bd/.env" ] || continue
      if [ -f "$bd/held" ]; then echo "boot: $p $b: held (bot $b hold), skipped"; continue; fi
      grep -q '^DISCORD_BOT_TOKEN=.' "$bd/.env" 2>/dev/null || { echo "boot: $p $b: no token, skipped"; continue; }
      pin=""; { read -r pin < "$bd/pinned-job"; } 2>/dev/null || :
      pid=$(printf '%s' "$bt_agents" | jq -r --arg n "$b" --arg pin "$pin" --arg cwd "$(cd -P "$p" && pwd)" \
        'first(.[] | objects | select((.name == $n or ($pin != "" and .id == $pin)) and .cwd == $cwd and .pid != null) | .pid) // ""' 2>/dev/null) || pid=""
      if [ -n "$pid" ]; then echo "boot: $p $b: running (pid $pid), skipped"; continue; fi
      rc=0; out=$("$self_path" bot --project "$p" "$b" recover --yes 2>&1 </dev/null) || rc=$?
      if [ "$rc" = 0 ]; then echo "boot: $p $b: recovered"
      else bt_rc=1; echo "boot: $p $b: failed (exit $rc): ${out##*$'\n'}"; fi
    done
  done
  exit "$bt_rc"
fi
