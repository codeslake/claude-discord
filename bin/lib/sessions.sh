# sourced by bin/claude-discord: live_sessions stop_sessions start_fresh (refresh, bot)
# live_sessions <name> <bot dir>: "<job id or -> <pid or ->" for each session of the bot started in this project, by its
# name or by its job record (refresh, below, says why both). Exit 1 when `claude agents --json` fails or gives no list:
# what runs is then unknown, which is not "nothing runs".
live_sessions() {
  local jobs agents old
  # A job respawned on the path before the move (1.18.0) names <project>/.claude/discord-agents/<bot>, as it was written
  # then (the logical cwd; the physical one too, for a project reached through a link).
  old="$PWD/.claude/discord-agents/$1"
  jobs=$(grep -lF -e "DISCORD_STATE_DIR\\\": \\\"$2\\\"" -e "DISCORD_STATE_DIR\\\": \\\"$old\\\"" -e "DISCORD_STATE_DIR\\\": \\\"$(pwd -P)/.claude/discord-agents/$1\\\"" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/jobs/*/state.json 2>/dev/null) || jobs=""
  jobs=$(printf '%s\n' "$jobs" | sed -n 's#.*/\([^/]*\)/state\.json$#\1#p')
  agents=$(claude agents --json 2>/dev/null) && printf '%s' "${agents:-null}" | jq -r --arg n "$1" --arg jobs "$jobs" --arg cwd "$(pwd -P)" '
      ($jobs | split("\n")) as $j |
      if type != "array" then error("not a list") else
        .[] | select((.name == $n or (.id as $i | any($j[]; . == $i))) and .cwd == $cwd and (.id != null or .pid != null))
        | "\(.id // "-") \(.pid // "-")" end' 2>/dev/null
}
# stop_sessions <name> <live_sessions' lines> [<bot dir>]: each stopped, a background one by `claude stop <id>`, a foreground one by
# TERM (what closing its terminal sends); then up to 10 s for their pids to go, then 3 s for the gateway to let the token
# go. Exit 1, the pids still running in `alive`, when one would not die: a start then would put two sessions on one token;
# `stopped_ids` then names the ones that did stop (their job ids; `pid <n>` for a foreground one), in the order stopped,
# so the caller can say what it leaves stopped (1.14.1). With the bot dir (1.19.4), its held is removed once every pid
# is gone, and each job id is recorded in <bot dir>/own-stop (1.19.7: person_stopped ignores it, so health does not read
# these stops as a person's; the next session start clears it): these stops are for a restart, so a start that then
# fails must leave the bot down (recovered), never held.
stop_sessions() {
  local id pid i
  pids=() ids=() stopped_ids=""
  while read -r id pid; do
    [ -n "$id" ] || continue
    echo "claude-discord: stopping $1 ($id, pid $pid)"
    if [ "$id" != - ]; then
      [ -z "${3:-}" ] || printf '%s\n' "$id" 2>/dev/null >> "$3/own-stop"   # ours, for a restart: not a person's stop (person_stopped)
      claude stop "$id" || echo "claude-discord: stop $id failed (already gone?)" >&2
    else
      kill -TERM "$pid" 2>/dev/null || :
    fi
    [ "$pid" = - ] || { pids+=("$pid"); ids+=("$id"); }
  done <<<"$2"
  # A stop that did not take leaves two sessions on one token, so wait for
  # every old pid to go before starting anything; a session that will not die
  # is reported, not raced.
  for _ in $(seq 20); do
    alive=()
    for pid in ${pids[@]+"${pids[@]}"}; do kill -0 "$pid" 2>/dev/null && alive+=("$pid") || :; done
    [ ${#alive[@]} -gt 0 ] || break
    sleep 0.5
  done
  i=0
  for pid in ${pids[@]+"${pids[@]}"}; do
    kill -0 "$pid" 2>/dev/null || { id=${ids[$i]}; [ "$id" != - ] || id="pid $pid"; stopped_ids="$stopped_ids${stopped_ids:+ }$id"; }
    i=$((i + 1))
  done
  [ ${#alive[@]} = 0 ] || return 1
  [ -z "${3:-}" ] || rm -f "$3/held" 2>/dev/null
  # The stopped session's channel server needs a moment to release the token;
  # a fresh gateway login while the old one is still up gets both dropped.
  [ -z "$2" ] || sleep 3
}
# start_fresh <wrapper> <name> <bot dir> <claude args>...: the bot started in the background (`--bg --name`), from this
# project; the launch folds handoff.md into its prompt and moves it to handoff.prev.md BEFORE claude starts, so a start
# that fails puts it back (a retry would else find none): only a handoff THIS start had, never one an earlier start left
# in handoff.prev.md, which would hand the next session a stale one. Its exit status is the start's; put_back=1 when the
# handoff was put back.
start_fresh() {
  local had=no rc=0
  put_back=""
  [ ! -s "$3/handoff.md" ] || had=yes
  "$1" --bg --name "$2" "${@:4}" || rc=$?
  if [ "$rc" != 0 ] && [ "$had" = yes ] && [ ! -s "$3/handoff.md" ] && [ -s "$3/handoff.prev.md" ]; then
    mv "$3/handoff.prev.md" "$3/handoff.md" && put_back=1 || :
  fi
  return "$rc"
}

# A long-running session answers worse as its context fills, and the automatic
# compaction near the limit summarises at the point the model is least able to
# judge what matters. `refresh` replaces the session on purpose while it can
# still choose well: the session writes handoff.md (the hook tells it how), then
# runs this. A session cannot replace itself, so the work is handed to a
# detached child that outlives the session's own shell:
#   1. refuse unless handoff.md is there (--force skips that, for a wedged session)
#   2. stop the running session(s) registered under this bot's name
#   3. start a fresh one in the background; the launch path below folds
#      handoff.md into its system prompt and moves it aside
# Stop before start, never the reverse: two sessions on one token both answer.
# The gap between them loses whatever arrives in it; the fresh session is told
# to catch up from the channel history.
