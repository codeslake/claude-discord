# sourced by bin/claude-discord: the refresh verb
if [ "${1:-}" = refresh ]; then
  shift
  # The name is kept out of the claude args so the launch below can be given
  # it explicitly, whether it came from the command line or from the
  # environment: with two bots in the project the launcher cannot guess.
  force=no; fresh=() name="" skip=0
  for a in "$@"; do
    # A flag's value never starts with "-": after one whose value is optional
    # (--debug, --worktree) the next word may be the next flag.
    if [ "$skip" = 1 ]; then skip=0; case $a in -*) ;; *) fresh+=("$a"); continue;; esac; fi
    case $a in
      --force) force=yes;;
      -n|--name|--name=*) echo "claude-discord: the session is named after the bot; drop $a" >&2; exit 2;;
      -*) fresh+=("$a"); takes_value "$a" && skip=1 || :;;
      *)  if [ -z "$name" ]; then name=$a; else fresh+=("$a"); fi;;
    esac
  done
  # This script is re-run twice below (the detached child, then the launch),
  # and the cd that follows would break a relative `./claude-discord`.
  case $0 in /*) self=$0;; *) self=$PWD/$0;; esac
  # The session runs this from its own Bash, whose cwd has usually wandered
  # off the project by now. Its environment still says where the state is
  # (DISCORD_STATE_DIR is set at launch), so go back to that project; a shell
  # outside any session gives the directory the usual way, by standing in it.
  if [ -n "${DISCORD_STATE_DIR:-}" ]; then
    [ -n "$name" ] || name=$(basename "$DISCORD_STATE_DIR")
    proj_of_state_dir "$DISCORD_STATE_DIR"   # either shape, a link the move left too
    [ -n "$pd_project" ] && cd "$pd_project" 2>/dev/null || { echo "claude-discord: cannot tell the project of $DISCORD_STATE_DIR" >&2; exit 1; }
    proj_cwd; root=$pd_root
  fi
  [ -n "$name" ] || { echo "usage: claude-discord refresh <name> [--force] [claude args]" >&2; exit 2; }
  case $name in ''|.|..|*/*) echo "claude-discord: bot name must be a plain directory name, got '$name'" >&2; exit 2;; esac
  dir=$root/$name
  [ -f "$dir/.env" ] || { echo "claude-discord: no bot '$name' under $root" >&2; exit 1; }
  if [ "$force" = no ] && [ ! -s "$dir/handoff.md" ]; then
    echo "claude-discord: $dir/handoff.md is missing or empty; write it first, or pass --force to replace the session without one" >&2
    exit 1
  fi
  # `claude --bg` refuses to start in a workspace whose trust has never been
  # accepted, and the foreground path does not: measured 2026-09-25, a --bg
  # start in an unregistered directory exits 1 with "Workspace not trusted".
  # A bot started in a terminal and moved to the background with /bg
  # therefore never meets that gate, and can run for weeks with the trust
  # unaccepted -- until a refresh stops it and cannot start its replacement.
  # That is how a bot here was down for 22 hours. So the trust flag is read
  # BEFORE anything is stopped. Fail-OPEN on purpose: anything but an
  # explicit `false` (no file, no jq, no such project key, a future Claude
  # Code that keeps trust elsewhere) proceeds exactly as before, because a
  # check that misreads would otherwise block a refresh that would have
  # worked. --force says "do it anyway", here as everywhere else.
  # `// "unset"` would be wrong here: jq's `//` treats FALSE as empty, so
  # `false // "unset"` is "unset" and the one value this checks for could
  # never be seen (measured). An explicit null test is the only correct form.
  if [ "$force" = no ] && untrusted; then
    echo "claude-discord: $PWD is not a trusted workspace, so the fresh --bg session would refuse to start and $name would be left down." >&2
    echo "claude-discord: run 'claude' here once and accept the trust prompt, then retry; --force refreshes anyway." >&2
    exit 1
  fi
  if [ "${CLAUDE_DISCORD_REFRESH_CHILD:-}" != 1 ]; then
    # Re-run this same command detached: `claude stop` below kills the session
    # that is very likely running us, and its whole process group with it.
    # perl's setsid rather than setsid(1): macOS ships perl but no setsid.
    export CLAUDE_DISCORD_REFRESH_CHILD=1
    # One generation of the log kept aside, as handoff.prev.md is. The child's
    # `>` truncates refresh.log, and an outage is usually met with a second
    # refresh minutes after the first: that run would erase the only record of
    # what the first one did, which is the question this log exists to answer
    # afterwards (measured on DY-DevBot, 2026-10-07: a 21:14 --force left
    # nothing of the 21:12 attempt).
    [ ! -f "$dir/refresh.log" ] || mv -f "$dir/refresh.log" "$dir/refresh.prev.log" 2>/dev/null || :
    perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' -- nohup "$self" refresh "$@" > "$dir/refresh.log" 2>&1 < /dev/null &
    echo "claude-discord: refreshing $name in the background; progress in $dir/refresh.log"
    exit 0
  fi
  # Sessions are registered under the name the wrapper gave them (-n) and the
  # directory they were started in; another project's bot of the same name is
  # not ours. A renamed one (/rename) is still found by its job record: every
  # background launch passes --settings naming this bot's DISCORD_STATE_DIR,
  # and the daemon keeps that in jobs/<id>/state.json's respawnFlags. A child
  # session started from the bot's shell only inherits the variable, so it
  # is never matched this way. Every live match is stopped, not one: a copy
  # left running is the two-sessions-on-one-token this exists to prevent. A background session has an id for `claude stop` (its pid may be
  # null while it is blocked, so the id decides); a foreground one has only a
  # pid, and SIGTERM is what closing its terminal would send. A listing that
  # fails or is not an array says nothing about what is running, which is not
  # the same as "nothing is": --force may not paper over it.
  if ! live=$(live_sessions "$name" "$dir"); then
    echo "claude-discord: 'claude agents --json' failed, so what is running is unknown; refusing to start a second session" >&2
    exit 1
  fi
  if [ -z "$live" ]; then
    # Nothing to stop means either the bot is down or it is running somewhere
    # this cannot see (started under another name, or from another directory).
    # Starting a second session in the latter case puts two on one token, so
    # refuse unless told otherwise.
    if [ "$force" = no ]; then
      echo "claude-discord: no running session of $name (by name or by its job record) started in $PWD; it may be down, or running under another name. 'claude agents' lists them; pass --force to start a fresh one anyway" >&2
      exit 1
    fi
    echo "claude-discord: no running session named $name found; starting a fresh one (--force)"
  fi
  if ! stop_sessions "$name" "$live"; then
    echo "claude-discord: session $name still running after stop (pid ${alive[*]}); not starting another. Stop it by hand, then run 'claude-discord refresh $name --force'" >&2
    exit 1
  fi
  echo "claude-discord: starting $name"
  unset CLAUDE_DISCORD_REFRESH_CHILD   # the fresh session's own refresh must fork again
  # A first turn, or the fresh session sits idle until the next message and
  # whoever asked for the refresh sees nothing happen. A prompt given on the
  # command line (a bare word after the name) is that first turn instead.
  kickoff=("Catch up on the channel and continue from your handoff.")
  skip=0
  for a in ${fresh[@]+"${fresh[@]}"}; do
    if [ "$skip" = 1 ]; then skip=0; case $a in -*) ;; *) continue;; esac; fi
    case $a in -*) takes_value "$a" && skip=1 || :;; *) kickoff=();; esac
  done
  # NOT exec: the launch path below consumes handoff.md (it folds it into the
  # system prompt and renames it handoff.prev.md) BEFORE it starts claude, so
  # a start that fails leaves the handoff gone from the path a retry looks at
  # -- and a retry without --force then refuses because handoff.md is
  # missing. That happened here: a --bg start refused on workspace trust and
  # took the handoff with it. Running it as a child instead means there is
  # still a shell to put the file back. `claude --bg` returns as soon as the
  # session is backgrounded (measured: 0 s), so waiting for it costs nothing
  # and a non-zero status is a real launch failure.
  rc=0; start_fresh "$self" "$name" "$dir" ${fresh[@]+"${fresh[@]}"} ${kickoff[@]+"${kickoff[@]}"} || rc=$?
  [ -z "$put_back" ] || echo "claude-discord: start failed, so $name's handoff was put back; fix the error above and run 'claude-discord refresh $name'" >&2
  exit "$rc"
fi
