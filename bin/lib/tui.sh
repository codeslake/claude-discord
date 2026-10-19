# sourced by bin/claude-discord: the tui verb

# tui: a view of the monitor's state.json, and the hosts ledger's editor through `hosts` (tui/claude_discord_tui.py,
# Python + Textual through `uv run --script`; uv is needed for this verb only).
# The bot is the project's one dev-manager bot with a hosts ledger unless named. Outside any project: the manager bots
# of the projects with a state dir (proj_arr), and the cwd becomes the chosen project's root.
if [ "${1:-}" = tui ]; then
  bot=${2:-}
  # From anywhere inside the project, like the shim: up to the project that has bots (either shape, state.sh).
  here=$PWD
  ! find_proj || cd "$pd_project"
  root=$pd_root
  # A project above with no manager bot (or not the one named), e.g. a plain bot's project, counts as none; a bot named
  # that lives here stays here, so its own refusal (no ledger) is the one said.
  mgr_here=""
  [ -z "$bot" ] || [ ! -d "$root/$bot" ] || mgr_here=1
  for d in "$root"/*/; do
    d=${d%/}
    [ -f "$d/hosts" ] && [ "$(cat "$d/mode" 2>/dev/null)" = dev-manager ] && { [ -z "$bot" ] || [ "$bot" = "${d##*/}" ]; } && { mgr_here=1; break; }
  done
  if [ -z "$mgr_here" ]; then
    # No manager project above: the projects with a state dir (as health --all walks them), the manager bots with a ledger.
    cands="" n=0; proj_arr
    for p in ${pl[@]+"${pl[@]}"}; do
      proj_dirs "$p"
      for d in "$pd_root"/*/; do
        d=${d%/}; b=${d##*/}
        [ -f "$d/hosts" ] && [ "$(cat "$d/mode" 2>/dev/null)" = dev-manager ] || continue
        [ -z "$bot" ] || [ "$bot" = "$b" ] || continue
        c=$b$'\t'$p$'\n'
        case $'\n'$cands in *$'\n'"$c"*) continue;; esac
        cands=$cands$c; n=$((n + 1))
      done
    done
    [ "$n" -gt 0 ] || { echo "claude-discord: tui: no project above $here with a manager bot, and no recorded project has a dev-manager bot${bot:+ '$bot'} with a hosts ledger (claude-discord setup <bot> --mode writes one)" >&2; exit 1; }
    if [ "$n" = 1 ]; then
      pick=${cands%$'\n'}
    else
      [ -t 0 ] || { echo "claude-discord: tui: more than one recorded manager bot; run it in a project, or at a terminal to choose:" >&2; while IFS=$'\t' read -r b p; do [ -z "$b" ] || echo "  $b  $p" >&2; done <<<"$cands"; exit 2; }
      # The replacement in a variable: bash 3.2 prints quotes inside ${p/#..} literally ("~"/x, measured on wmac).
      t='~' i=0; while IFS=$'\t' read -r b p; do [ -z "$b" ] || { i=$((i + 1)); echo "$i) $b  ${p/#"$HOME"/$t}"; }; done <<<"$cands"
      read -rp "Number: " i || i=""
      case $i in ''|*[!0-9]*|0*) echo "claude-discord: tui: not a number: '$i'" >&2; exit 2;; esac
      pick=$(sed -n "${i}p" <<<"$cands")
      [ -n "$pick" ] || { echo "claude-discord: tui: no entry $i" >&2; exit 2; }
    fi
    bot=${pick%%$'\t'*}; cd "${pick#*$'\t'}"
  fi
  proj_cwd; root=$pd_root   # pd_key too: the backend's records are records/monitor/<key>/<bot> (1.18.1)
  if [ -z "$bot" ]; then
    n=0
    for d in "$root"/*/; do
      d=${d%/}
      [ -f "$d/hosts" ] && [ "$(cat "$d/mode" 2>/dev/null)" = dev-manager ] || continue
      bot=${d##*/}; n=$((n + 1))
    done
    if [ "$n" != 1 ]; then
      # Not exactly one: ask at a terminal, else say what to type.
      [ -t 0 ] || { echo "claude-discord: tui: name the manager bot (claude-discord tui <bot>); this project has $n dev-manager bots with a hosts ledger" >&2; exit 2; }
      read -rp "Manager bot: " bot || bot=""
    fi
  fi
  case $bot in ''|.|..|*/*|-*) echo "claude-discord: bot name must be a plain directory name, got '$bot'" >&2; exit 2;; esac
  [ -f "$root/$bot/hosts" ] || { echo "claude-discord: tui: $root/$bot has no hosts ledger (claude-discord setup $bot --mode writes one)" >&2; exit 1; }
  uv=${CLAUDE_DISCORD_UV:-uv}
  command -v "$uv" >/dev/null 2>&1 || { echo "claude-discord: tui needs uv (https://docs.astral.sh/uv/); nothing else in claude-discord does" >&2; exit 1; }
  # The backend's keeper, detached, so the monitor outlives the TUI (none is started when one runs; monitor.log says
  # why). Stopped by its owner (monitor --stop): the TUI asks whether to start it again.
  [ -e "$HOME/.claude-discord/records/monitor/$pd_key/$bot/stopped" ] ||
    bash "$self_root/monitor/monitor.sh" "$self_path" --keep "$bot" --detach </dev/null >/dev/null || :
  # The cwd stays the project root: the TUI's `monitor --ensure` call reads the ledger from there.
  exec "$uv" run --script "$self_root/tui/claude_discord_tui.py" --bot "$bot" \
    --state-dir "$HOME/.claude-discord/records/monitor/$pd_key/$bot" --claude-discord "$self_path" --version-line "$(version_line)"
fi
