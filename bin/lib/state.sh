# sourced by bin/claude-discord: sweep_list sweep_project (the start, the compat verb)

# The marker sweep. A hook leaves a file per session: <bot dir>/plugin-sessions/<sid> (plugin_gate), turns/<sid> and
# turns/<sid>.{replied,primed,pending} (the turn hooks), and the project's checkin/<sid> (on-reply). Nothing removed a
# session's files once the session was gone, and every `claude -p` run from a bot's Bash left one more (633 in one bot
# dir, 2026-10-16). A file goes when `claude agents --json --all` lists no row whose sessionId or id is the name's part
# before its first dot; stopped and done rows are listed, so theirs stay (no guess at liveness). Only in a bot dir this
# daemon can see, one the listing names by the bot's name or its pinned job: the other side of a shared home (a
# container and its host) lists none of the other's sessions, and a sweep from there would empty a running bot's turns/.

# sweep_list <listing JSON>: sw_keep (" id id ... "), sw_names and sw_jobs (newline-led and -ended) from the listing,
# with one jq. 1, and nothing set, when it is no array (a failed or empty call is unknown, never "nothing runs").
sweep_list() {
  local out
  out=$(printf '%s' "${1:-null}" | jq -r 'if type != "array" then error("no list") else [.[] | objects] as $r
    | ([$r[] | .sessionId, .id | strings | select(test("\\A[A-Za-z0-9_-]+\\z"))] | join(" ")),
      ([$r[] | .name | strings | gsub("[\t\n]"; " ")] | join("\t")),
      ([$r[] | .id | strings | select(test("\\A[A-Za-z0-9_-]+\\z"))] | join("\t")) end' 2>/dev/null) || return 1
  { IFS= read -r sw_keep; IFS= read -r sw_names; IFS= read -r sw_jobs; } <<<"$out"
  sw_keep=" $sw_keep " sw_names=$'\t'$sw_names$'\t' sw_jobs=$'\t'$sw_jobs$'\t'
}
# sweep_seen <bot dir>: the listing names this bot or its pinned job.
sweep_seen() {
  local pin=""
  case $sw_names in *$'\t'"${1##*/}"$'\t'*) return 0;; esac
  { IFS= read -r pin < "$1/pinned-job"; } 2>/dev/null || :
  [ -n "$pin" ] && case $sw_jobs in *$'\t'"$pin"$'\t'*) true;; *) false;; esac
}
# sweep_files <file>...: the ones whose session the listing does not name go, in one rm.
sweep_files() {
  local f x gone=()
  for f in "$@"; do
    [ -e "$f" ] || continue
    x=${f##*/}; x=${x%%.*}
    case $sw_keep in *" $x "*) ;; *) gone+=("$f");; esac
  done
  [ "${#gone[@]}" = 0 ] || rm -f "${gone[@]}" 2>/dev/null || :
}
# sweep_project <discord-agents dir> [<bot>]: that bot's markers (every bot's without one), then checkin/ when every
# bot of the project is seen. After sweep_list.
sweep_project() {
  local r=${1%/} d all=1
  for d in "$r"/*/; do
    d=${d%/}
    [ -f "$d/.env" ] || continue
    if sweep_seen "$d"; then
      [ -n "${2:-}" ] && [ "${d##*/}" != "$2" ] || sweep_files "$d"/plugin-sessions/* "$d"/turns/*
    else
      all=""
    fi
  done
  [ -z "$all" ] || sweep_files "$r"/checkin/*
}
