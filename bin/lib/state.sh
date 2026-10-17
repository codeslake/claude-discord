# sourced by bin/claude-discord (every call), and monitor/monitor.sh (a pass: proj_cwd, sweep_recorded). No here-string
# or here-document: monitor.sh leaves nothing in /tmp, and bash 3.2 backs both with a temp file.
: "${helpers:=$HOME/.claude-discord}"

# The layout (1.18.0). A project's state is ~/.claude-discord/projects/<key>/: `project` (the project's physical path, one
# line), config.env, peers.json, checkin/, and bots/<bot>/ (everything that was <project>/.claude/discord-agents/<bot>/:
# .env, access.json, mode, turns/, plugin-sessions/, handoff*.md, ...). <key> is proj_key of the path. The shape before
# it, <project>/.claude/discord-agents/ holding all of that, is still read everywhere ("not moved yet") until compat
# (every update), setup or a start moves the project (move_project). Never a hook: a hook may not rename the state dir it
# runs under. The 1.18.0 variables below are pd_*: proj_dirs sets them, and a caller keeps its own root/proj_state.

# proj_key <absolute physical path>: Claude Code's folder for the project under ~/.claude/projects, where its transcripts
# are: every non-alphanumeric byte a dash (1.17.1; the C locale keeps the ranges ASCII, as c_match's). Known to differ
# from Claude Code's for a non-ASCII path (one byte a dash here, one UTF-16 unit there) and past 200 characters
# (truncated and hashed there): the key only has to be stable, and `project` is the authority; transcript_moved then
# does not find the transcript, which reads as "not moving".
proj_key() { local LC_ALL=C; printf '%s\n' "${1//[^A-Za-z0-9]/-}"; }
# proj_list: every project with a state dir (projects/*/project), one a line. Unused until Task 4 retires records/projects.
proj_list() { local f p; for f in "$helpers"/projects/*/project; do p=""; { IFS= read -r p < "$f"; } 2>/dev/null || :; [ -z "$p" ] || printf '%s\n' "$p"; done; }
# proj_dirs <project, physical path>: pd_key; pd_state (config.env, peers.json, checkin/); pd_root (the bot dirs' parent);
# pd_new (1 for the 1.18.0 shape: that key's `project` names the path; empty for the old shape, both dirs the old one).
# Builtins only: the wrapper's every call and the hooks' revive come through here.
proj_dirs() {
  local LC_ALL=C p=""
  pd_key=${1//[^A-Za-z0-9]/-} pd_new=""
  { IFS= read -r p < "$helpers/projects/$pd_key/project"; } 2>/dev/null || :
  if [ -n "$p" ] && [ "$p" = "$1" ]; then pd_state=$helpers/projects/$pd_key pd_root=$helpers/projects/$pd_key/bots pd_new=1
  else pd_state=$1/.claude/discord-agents pd_root=$pd_state; fi
}
# proj_cwd: proj_dirs of the physical cwd (pd_project), the logical $PWD left as it was. cd and back, no fork.
proj_cwd() {
  local here=$PWD
  { cd -P -- "$PWD" 2>/dev/null && pd_project=$PWD; } || pd_project=$PWD
  cd -- "$here" 2>/dev/null || :
  proj_dirs "$pd_project"
}
# find_proj [<bot>]: the project at or above the cwd that has bots [that bot], either shape: pd_project and proj_dirs'
# variables. 1 when none, with pd_project the cwd and the old-shape dirs under it (a caller's "no bot set up in <dir>").
find_proj() {
  local a
  proj_cwd; a=$pd_project
  while [ -n "$a" ]; do
    proj_dirs "$a"
    if [ -d "$pd_root/${1:-}" ]; then pd_project=$a; return 0; fi
    a=${a%/*}
  done
  proj_dirs "$pd_project"; return 1
}
# proj_of_state_dir <a bot's DISCORD_STATE_DIR>: the project and its dirs from the path a session runs on, either shape:
# pd_project (empty when the path says nothing), pd_state, pd_root, pd_new. The wrapper's copy of the hooks' three lines
# (hooks/lib/discord.sh), for refresh and health run from inside a session.
proj_of_state_dir() {
  local sd=${1%/} here=$PWD
  pd_project="" pd_state="" pd_root="" pd_new=""
  case $sd in
    */.claude/discord-agents/*)
      pd_project=${sd%/.claude/discord-agents/*} pd_state=${sd%/*}; pd_root=$pd_state
      # A link the move left for a session respawned on the old path: its target is the state.
      [ ! -L "$sd" ] || { { cd -P -- "$sd" 2>/dev/null && sd=$PWD; } || :; cd -- "$here" 2>/dev/null || :; }
      case $sd in */bots/*) pd_state=${sd%/bots/*} pd_new=1; pd_root=$pd_state/bots;; esac;;
    */bots/*)
      pd_state=${sd%/bots/*} pd_new=1; pd_root=$pd_state/bots
      { IFS= read -r pd_project < "$pd_state/project"; } 2>/dev/null || :;;
    ?*) pd_state=${sd%/*} pd_root=${sd%/*};;
  esac
}
# proj_init <project, physical path>: the project's key dir, 700, with its `project` file (temp + rename) and bots/; then
# proj_dirs of it. 1, both paths said, when the key is another project's (a_b and a.b): nothing is written then.
proj_init() {
  local d p=""
  proj_dirs "$1"; d=$helpers/projects/$pd_key
  { IFS= read -r p < "$d/project"; } 2>/dev/null || :
  if [ -n "$p" ] && [ "$p" != "$1" ]; then
    echo "claude-discord: $1 and $p share one state key ($pd_key: every non-alphanumeric character a dash), and claude-discord keeps one project per key; rename one of the two" >&2
    return 1
  fi
  (umask 077; mkdir -p "$d/bots" && { [ -n "$p" ] || { printf '%s\n' "$1" > "$d/.project.$$" && mv -f "$d/.project.$$" "$d/project"; }; }) ||
    { rm -f "$d/.project.$$"; echo "claude-discord: could not write $d" >&2; return 1; }
  proj_dirs "$1"
}
# pmv <from> <to>: rename(2) and nothing else (mv would copy across filesystems), through perl as bot rename does.
pmv() { perl -e 'rename $ARGV[0], $ARGV[1] or exit 1' "$1" "$2"; }
# move_project <project, physical path>: its state from <project>/.claude/discord-agents/ into ~/.claude-discord/projects/
# <key>/, under <key>.lock (mkdir; held: 10 s, then skipped and said). config.env, peers.json and checkin/ go in when
# the key has none (a second machine sharing the home moved first: left, said). Each bot dir is renamed, and at once a
# link <project>/.claude/discord-agents/<bot> -> bots/<bot> put where it was: a session respawned on the old path (the
# job's respawnFlags froze it) finds its state through it, and a hook that runs between the two finds no state dir and
# exits 0, as for a non-bot. rename(2) refused (another filesystem): copied, compared (diff -r), the source removed and
# the link made, but only when no session of the bot runs (live_sessions; unknown counts as running), else left for the
# bot's next start or update, said. The 1.8-1.16 hooks link goes; the .gitignore stays while the directory does
# (unlink_old). records/monitor/<bot> and scratch/<bot> stay: Task 4 moves them with their readers. 1 for a refusal
# (the key is another project's); 0 otherwise, whatever was left and said.
move_project() {
  local p=$1 src=$1/.claude/discord-agents dst n rc=0
  [ -d "$src" ] && [ ! -L "$src" ] || return 0
  # The lock before anything is written: a move cut short after `project` would read as the new shape with no bots.
  proj_dirs "$p"; dst=$helpers/projects/$pd_key
  (umask 077; mkdir -p "$helpers/projects") 2>/dev/null || :
  for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    mkdir "$dst.lock" 2>/dev/null && break
    [ "$n" -lt 20 ] || { echo "claude-discord: $dst.lock is held (another claude-discord is moving $p? else rmdir it); $p left for the next update" >&2; return 0; }
    sleep 0.5
  done
  proj_init "$p" || { rmdir "$dst.lock" 2>/dev/null; return 1; }
  type live_sessions >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/sessions.sh"
  (
    trap 'rmdir "$dst.lock" 2>/dev/null' EXIT; set +e
    cd "$p" 2>/dev/null || exit 1   # live_sessions keys on the cwd
    for f in config.env peers.json checkin; do
      [ -e "$src/$f" ] || continue
      if [ -e "$dst/$f" ]; then echo "claude-discord: $src/$f left: $dst/$f is there already" >&2; continue; fi
      pmv "$src/$f" "$dst/$f" && continue
      rm -rf "$dst/.$f.part"
      cp -pR "$src/$f" "$dst/.$f.part" && mv -f "$dst/.$f.part" "$dst/$f" && rm -rf "${src:?}/$f" || { rm -rf "$dst/.$f.part"; echo "claude-discord: could not move $src/$f to $dst" >&2; }
    done
    for b in "$src"/*/; do
      b=${b%/}; n=${b##*/}
      [ -f "$b/.env" ] && [ ! -L "$b" ] || continue
      if [ -e "$dst/bots/$n" ]; then echo "claude-discord: $b left: $dst/bots/$n is there already" >&2; continue; fi
      if ! pmv "$b" "$dst/bots/$n"; then
        live=$(live_sessions "$n" "$b") || live=unknown
        if [ -n "$live" ]; then
          echo "claude-discord: $b cannot be renamed into $dst/bots/ (another filesystem?), and a session of $n runs (${live%%$'\n'*}): left there until the bot's next start or update" >&2
          continue
        fi
        rm -rf "$dst/bots/.$n.part"
        if cp -pR "$b" "$dst/bots/.$n.part" && diff -r "$b" "$dst/bots/.$n.part" >/dev/null 2>&1 && mv -f "$dst/bots/.$n.part" "$dst/bots/$n"; then rm -rf "${b:?}"
        else rm -rf "$dst/bots/.$n.part"; echo "claude-discord: $b could not be copied into $dst/bots/ (the copy or its comparison failed): left there" >&2; continue
        fi
      fi
      ln -s "$dst/bots/$n" "$b" 2>/dev/null || echo "claude-discord: could not link $b to $dst/bots/$n: a session respawned on the old path finds no state until it is" >&2
      echo "claude-discord: $n moved to $dst/bots/$n"
    done
    [ ! -L "$src/hooks" ] || rm -f "$src/hooks"
    exit 0
  ) || rc=1
  [ "$rc" = 0 ] || echo "claude-discord: could not enter $p; its state was not moved" >&2
  return 0
}
# unlink_old <project, physical path> [say]: each link <project>/.claude/discord-agents/<bot> the move left goes once no
# ${CLAUDE_CONFIG_DIR:-~/.claude}/jobs/*/state.json names a path ending in /.claude/discord-agents/<bot> (a respawn, a
# daemon restart or a fleet claim comes back on the frozen path; a stopped job keeps its record, and so the link, until
# `claude rm <id>` or the bot's next start prunes it: said, with `say`). The record holds the start's LOGICAL $PWD (a 1.17
# `root=$PWD/...`), so only the path's last part is compared: a same-named bot of another project keeps a harmless link
# longer. With `say` (compat, setup) a link whose bot has a session with no job record (a foreground one; `claude agents`
# not answering counts) stays too. A link missing for a bot a record names (a move cut between its rename and its
# link) is made again. Then the directory itself with its .gitignore, once it holds nothing else.
unlink_old() {
  local src=$1/.claude/discord-agents b n j live rest="" jobs="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/jobs"
  [ -d "$src" ] && [ ! -L "$src" ] || return 0
  proj_dirs "$1"
  if [ -n "$pd_new" ]; then
    for b in "$pd_root"/*/; do
      b=${b%/}; n=${b##*/}
      [ -f "$b/.env" ] && [ ! -e "$src/$n" ] && [ ! -L "$src/$n" ] || continue
      grep -qF -- "/.claude/discord-agents/$n\\\"" "$jobs"/*/state.json 2>/dev/null || continue
      ln -s "$b" "$src/$n" 2>/dev/null && echo "claude-discord: $src/$n linked to $b again: a job record names the old path and the move's link was missing" || :
    done
  fi
  for b in "$src"/*; do
    [ -L "$b" ] || { { [ -e "$b" ] || [ -L "$b" ]; } && rest=1; continue; }
    case $(readlink "$b") in "$helpers"/projects/*/bots/*) ;; *) rest=1; continue;; esac
    n=${b##*/}
    j=$(grep -lF -- "/.claude/discord-agents/$n\\\"" "$jobs"/*/state.json 2>/dev/null) || j=""
    if [ -n "$j" ]; then
      rest=1
      [ "${2:-}" != say ] || { j=$(printf '%s\n' "$j" | sed -n 's#.*/\([^/]*\)/state\.json$#\1#p' | tr '\n' ' '); echo "claude-discord: $b stays a link to its moved state: job ${j% } names the old path (a respawn comes back on it; claude rm <id>, or the bot's next start, lets the link go)"; }
      continue
    fi
    if [ "${2:-}" = say ]; then
      type live_sessions >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/sessions.sh"
      live=$(cd "$1" && live_sessions "$n" "$b" </dev/null) || live=unknown
      if [ -n "$live" ]; then
        rest=1
        if [ "$live" = unknown ]; then echo "claude-discord: $b stays a link to its moved state: 'claude agents --json' did not answer, so whether a session of $n runs on the old path is unknown"
        else echo "claude-discord: $b stays a link to its moved state: a session of $n runs with no job record (${live%%$'\n'*}; a foreground one), and may still read the old path"; fi
        continue
      fi
    fi
    rm -f "$b"
  done
  [ -z "$rest" ] || return 0
  for b in "$src"/.[!.]* "$src"/..?*; do { [ -e "$b" ] || [ -L "$b" ]; } && [ "${b##*/}" != .gitignore ] && return 0; done
  rm -f "$src/.gitignore"; rmdir "$src" 2>/dev/null || :
}

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
  sw_keep=${out%%$'\n'*} out=${out#*$'\n'}
  sw_names=${out%%$'\n'*} sw_jobs=${out#*$'\n'}
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
# sweep_project <bots root> <state dir> [<bot>]: that bot's markers (every bot's without one), then checkin/ when every
# bot of the project is seen. After sweep_list.
sweep_project() {
  local r=${1%/} d all=1
  for d in "$r"/*/; do
    d=${d%/}
    [ -f "$d/.env" ] || continue
    if sweep_seen "$d"; then
      [ -n "${3:-}" ] && [ "${d##*/}" != "$3" ] || sweep_files "$d"/plugin-sessions/* "$d"/turns/*
    else
      all=""
    fi
  done
  [ -z "$all" ] || sweep_files "${2%/}"/checkin/*
}
# sweep_recorded <projects file>: every bot of every project the file lists (records/projects), either shape, from one
# listing. Optional: no claude, no jq, a listing that fails, hangs past 5 s or is no array sweeps nothing, silently.
sweep_recorded() {
  local l p t=()
  command -v jq >/dev/null 2>&1 && command -v claude >/dev/null 2>&1 && [ -f "$1" ] || return 0
  if command -v timeout >/dev/null 2>&1; then t=(timeout 5); else t=(perl -e 'alarm 5; exec @ARGV or exit 127'); fi   # macOS: no timeout(1)
  l=$(${t[@]+"${t[@]}"} claude agents --json --all 2>/dev/null) && sweep_list "$l" || return 0
  while IFS= read -r p || [ -n "$p" ]; do
    p=${p%$'\r'}
    [ -n "$p" ] || continue
    proj_dirs "$p"
    [ ! -d "$pd_root" ] || sweep_project "$pd_root" "$pd_state" 2>/dev/null || :
  done < "$1"
  return 0
}
