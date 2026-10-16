# sourced by bin/claude-discord: select_one git_net src_link prune_installs install_plugin remove_old_install, the compat verb, strip_settings write_hosts parse_install_flags check_install_scope coexist install_all; the install, setup and update verbs

# select_one <label> <default> <option>...: prints the chosen option's first
# word (an option is "<name>  <hint>"). On a terminal, an @clack-style picker
# drawn on /dev/tty: ◆ while active, ● on the cursor row, ○ on the others;
# ↑/↓ or k/j move, Enter picks, the default starts under the cursor; it
# collapses to "◇ <label> — <choice>". Without a terminal on stdin, one line
# is read: an option name or its 1-based number; empty means the default,
# anything else too, with a warning. A subshell, so the stty change and the
# traps that undo it (Ctrl-C included) never leak into setup.
select_one() (
  label=$1 def=$2
  shift 2
  opts=("$@") cur=0
  for i in "${!opts[@]}"; do [ "${opts[i]%% *}" != "$def" ] || cur=$i; done
  if [ ! -t 0 ]; then
    IFS= read -r ans || :
    ans=${ans//[[:space:]]/} pick=-1
    for i in "${!opts[@]}"; do [ "$ans" != "${opts[i]%% *}" ] && [ "$ans" != "$((i + 1))" ] || pick=$i; done
    if [ "$pick" = -1 ]; then
      [ -z "$ans" ] || echo "claude-discord: no $label '$ans', using ${opts[cur]%% *}" >&2
      pick=$cur
    fi
    echo "${opts[pick]%% *}"
    exit 0
  fi
  exec 3<>/dev/tty
  saved=$(stty -g <&3)
  trap 'stty "$saved" <&3; printf "\e[?25h" >&3' EXIT
  trap 'exit 130' INT TERM
  stty -echo -icanon <&3
  cols=$(stty size <&3) cols=${cols#* }
  [ "$cols" -gt 20 ] 2>/dev/null || cols=80
  printf '\e[?25l' >&3
  n=0
  while :; do
    [ "$n" = 0 ] || printf '\e[%dF\e[J' "$n" >&3
    printf '\e[36m◆\e[0m  %s  \e[2m↑/↓ · enter\e[0m\n' "$label" >&3
    for i in "${!opts[@]}"; do
      if [ "$i" = "$cur" ]; then printf '\e[2m│\e[0m  \e[32m●\e[0m \e[36m%s\e[0m\n' "${opts[i]:0:cols-6}"
      else printf '\e[2m│\e[0m  ○ %s\n' "${opts[i]:0:cols-6}"; fi >&3
    done
    n=$((${#opts[@]} + 1))
    IFS= read -rn1 key <&3 || key=""
    [ "$key" != $'\e' ] || read -rn2 -t 1 key <&3 || key=x   # an arrow is ESC [ A/B, or ESC O A/B in application mode; a lone ESC does nothing
    case $key in
      k|'[A'|OA) cur=$(((cur + ${#opts[@]} - 1) % ${#opts[@]}));;
      j|'[B'|OB) cur=$(((cur + 1) % ${#opts[@]}));;
      '') break;;
    esac
  done
  printf '\e[%dF\e[J\e[32m◇\e[0m  %s — %s\n' "$n" "$label" "${opts[cur]%% *}" >&3
  echo "${opts[cur]%% *}"
)

# Installs the plugin at the chosen scope (setup has validated $scope, $method
# and the other scope's absence by now). method clone: this repo cloned into
# the skills dir, so a project can pin its own version. method link: a symlink
# to the machine's one source clone, ~/.claude-discord/source, so one update
# moves every bot; the hooks and tools resolve their real directory rather
# than trust ${CLAUDE_PLUGIN_ROOT}, and the plugin declares no .mcp.json, so
# the measured problems of a link do not bite. An existing install of either
# kind is kept as it is. Project scope loads only when ~/.claude.json trusts
# that exact path; setup asks before writing it.
git_net() {
  if command -v timeout >/dev/null 2>&1; then GIT_TERMINAL_PROMPT=0 timeout 120 git "$@"; else GIT_TERMINAL_PROMPT=0 git "$@"; fi
}
# A link to the machine's source clone: two of them run the same code.
src_link() { [ -L "$1" ] && [ "$1" -ef "$HOME/.claude-discord/source" ]; }
prune_installs() {
  local f=$HOME/.claude-discord/records/installs p keep=""
  [ -f "$f" ] || return 0
  while IFS= read -r p || [ -n "$p" ]; do
    [ -z "$p" ] || [ ! -e "$p" ] || keep="$keep$p"$'\n'
  done < "$f"
  printf '%s' "$keep" > "$f.tmp.$$" && { cmp -s "$f.tmp.$$" "$f" || cat "$f.tmp.$$" > "$f"; }
  rm -f "$f.tmp.$$"
}
# record_project: this project's root (physical) into records/projects, once.
# `health --all` walks that list; setup and a health run in a project add to it.
install_plugin() {  # uses $scope $method $pdir $gdir
  local repo=${CLAUDE_DISCORD_REPO:-https://github.com/codeslake/claude-discord}
  local src=$HOME/.claude-discord/source target ex pat here t
  case $scope in project) target=$pdir;; *) target=$gdir;; esac
  # A dangling link (its source removed) is a broken install, not one to keep.
  [ -L "$target" ] && [ ! -e "$target" ] && rm -f "$target"
  if [ -e "$target" ]; then
    echo "claude-discord: plugin already installed at $target, kept as it is"
  else
    if [ -z "$method" ]; then
      if [ -n "${noask:-}" ]; then method=link; else method=$(select_one Method link "link   the machine's one source clone, ~/.claude-discord/source (one update for every bot)" "clone  its own copy, so this install can pin a version"); fi
    fi
    mkdir -p "$(dirname "$target")"
    if [ "$method" = link ]; then
      has_path "$src" || git_net clone -q "$repo" "$src" || { echo "claude-discord: could not clone $repo into $src" >&2; return 1; }
      ln -s "$src" "$target"
    else
      git_net clone -q "$repo" "$target" || { echo "claude-discord: could not clone $repo into $target" >&2; return 1; }
    fi
  fi
  # A git-tracked project (worktree, submodule or subdirectory too) keeps the
  # install out of git status; no trailing slash, so it matches a link as well.
  if [ "$scope" = project ] && { read -r t && read -r ex && read -r here; } < <(git -C "$PWD" rev-parse --is-inside-work-tree --git-path info/exclude --show-prefix 2>/dev/null) && [ "$t" = true ]; then   # one git call: inside a work tree?, the exclude file, the prefix
    case $ex in /*) ;; *) ex=$PWD/$ex;; esac
    pat=/${here}.claude/skills/claude-discord
    grep -qxF "$pat" "$ex" 2>/dev/null || { mkdir -p "$(dirname "$ex")" && printf '%s\n' "$pat" >> "$ex"; }
  fi
  mkdir -p "$HOME/.local/bin" "$HOME/.claude-discord/records"
  cmp -s "$target/shim/claude-discord" "$HOME/.local/bin/claude-discord" ||
    install -m 755 "$target/shim/claude-discord" "$HOME/.local/bin/claude-discord" ||
    { echo "claude-discord: could not install the shim from $target" >&2; return 1; }
  touch "$HOME/.claude-discord/records/installs"
  grep -qxF "$target" "$HOME/.claude-discord/records/installs" || printf '%s\n' "$target" >> "$HOME/.claude-discord/records/installs"
  prune_installs
  # The real directory behind a link, for what must outlive this project's link.
  plugin_target=$(cd -P "$target" && pwd -P) || return 1
  # Keyed by the physical path, like refresh's check.
  if [ "$scope" = project ] && [ "$(jq -r --arg p "$(pwd -P)" '.projects[$p].hasTrustDialogAccepted | if . == true then "yes" else "no" end' "$HOME/.claude.json" 2>/dev/null)" != yes ]; then
    echo "claude-discord: $PWD is not trusted in ~/.claude.json, so Claude Code will not load the plugin here." >&2
    if [ -n "${noask:-}" ]; then
      echo "claude-discord: accept the trust dialog in a claude session here, or answer y in 'claude-discord setup <bot>' at a terminal" >&2
    else
      read -rp "Mark this project trusted now? [y/N] " t || t=""
      case $t in y|Y) jq_edit "$HOME/.claude.json" --arg p "$(pwd -P)" '.projects[$p].hasTrustDialogAccepted = true';; esac
    fi
  fi
}

# What install.sh used to put under ~/.claude-discord becomes links into
# ~/.claude-discord/compat, a plain copy (no git) of the real plugin's hooks,
# tools and rules (the source clone when there is one, else $self_root, the
# resolved install, not one project's link): hooks/{turn,peers,lib,autoresearchclaw},
# every tool under hooks/tools, and the two runtime .ts files (the bunfig preload
# an old bot's MCP server names; they link to the stable runtime/ copy, which
# sync_runtime fills, so they never dangle). A copy, not the clone (R16): the
# previous release's install.sh writes through these links, and a write into a
# clone would leave `update` refusing to pull for good.
# Links stay for one release, because a project set up by the previous release
# and not yet by this one keeps its settings hooks, and those resolve through
# .claude/discord-agents/hooks -> ~/.claude-discord/hooks; deleting the copies
# would silently turn every one of them into a no-op. The next release removes
# the links. rules/ goes (only the old rule copies read it); scratch/, records/,
# source/ are not touched (runtime/ and compat/ are refreshed). A symlink at hooks/ itself is removed as
# a link (R2): it leads somewhere that is not ours to empty. The other paths
# are removed with rm -rf, which on a link removes only the link.
remove_old_install() {
  local h=$helpers real=$self_root c=$helpers/compat t f bad=0
  # The machine-wide source clone when there is one: a clone-method (possibly pinned) project must not pull every unmigrated project onto its version.
  [ ! -d "$h/source/hooks" ] || real=$h/source
  [ ! -L "$h/hooks" ] || rm -f "$h/hooks"
  [ ! -e "$h/rules" ] && [ ! -L "$h/rules" ] || rm -rf "$h/rules"
  [ -d "$h/hooks/tools" ] && [ ! -L "$h/hooks/tools" ] || { rm -rf "$h/hooks/tools"; mkdir -p "$h/hooks/tools" || bad=1; }
  sync_runtime || bad=1
  sync_compat "$real" || bad=1
  for f in "$h"/hooks/tools/* "$h"/hooks/tools/.[!.]*; do   # an old copy, a link into a clone, or a link to a tool the plugin no longer ships goes
    { [ -e "$f" ] || [ -L "$f" ]; } && ! { [ -L "$f" ] && [ "$f" -ef "$c/tools/${f##*/}" ]; } && { rm -rf "$f" || bad=1; }
  done
  for t in turn peers lib autoresearchclaw; do
    [ -L "$h/hooks/$t" ] && [ "$(readlink "$h/hooks/$t")" = "$c/hooks/$t" ] && continue   # already linked (every setup after the first)
    rm -rf "${h:?}/hooks/$t" && ln -s "$c/hooks/$t" "$h/hooks/$t" || bad=1
  done
  for f in "$c"/tools/*; do
    [ -L "$h/hooks/tools/${f##*/}" ] && [ "$h/hooks/tools/${f##*/}" -ef "$f" ] && continue
    ln -sfn "$f" "$h/hooks/tools/${f##*/}" || bad=1
  done
  for f in discord-chunk.ts discord-proxy.ts; do
    [ -L "$h/$f" ] && [ "$h/$f" -ef "$h/runtime/$f" ] && continue
    ln -sfn "$h/runtime/$f" "$h/$f" || bad=1
  done
  [ "$bad" = 0 ] || { echo "claude-discord: could not link the old install paths under $h to $c" >&2; return 1; }
}

# same_tree <a> <b>: same files and the same executables (diff -r ignores modes,
# and an old settings entry skips a hook that is not -x).

# strip_settings: the hook entries releases before 1.9 wrote (a command under .claude/discord-agents/hooks/) taken out
# of the files the plugin's first hook run never edits: the user-global settings.json, and a symlinked
# .claude/settings.json or settings.local.json (often into a dotfiles repo) in this project or a recorded one, through
# the link (strip_old_hooks renames a new target in; the link stays). They kept running beside the plugin's hooks
# (lmd79's five global entries ran on-session-start twice at every start, 2026-10-16), and they go on every machine
# sharing the file too: there they ran only through a per-project hooks link to the compat copy. A project's own
# regular files are still left to that first hook run (R15: setup cannot know the plugin will load there). Run by
# setup and by compat (every update), and only once every bot of every recorded project here has run with the plugin
# (a plugin-sessions/ marker): until then one line says why they stay. A file left as it was (not JSON, not
# writable) is named, and fails nothing.
strip_one() { strip_old_hooks "$1" || echo "claude-discord: old claude-discord hook entries left in '$1' (not JSON, or not writable); remove them by hand" >&2; }
strip_settings() {
  local p f b targets=() miss="" scanned="" ps=("$PWD")
  . "$self_root/hooks/lib/old-hooks.sh" 2>/dev/null || return 0
  # Builtins only (every setup runs this): the records read by read, a file's text by $(<), no cat, no grep.
  if [ -f "$helpers/records/projects" ]; then
    while IFS= read -r p || [ -n "$p" ]; do ps+=("$p"); done < "$helpers/records/projects"
  fi
  for p in "${ps[@]}"; do
    p=${p%$'\r'}; [ -n "$p" ] || continue
    for f in "$p/.claude/settings.json" "$p/.claude/settings.local.json"; do [ ! -L "$f" ] || targets+=("$f"); done
  done
  targets=("$HOME/.claude/settings.json" ${targets[@]+"${targets[@]}"})
  for f in "${targets[@]}"; do
    [ -f "$f" ] || continue
    { case $(<"$f") in */.claude/discord-agents/hooks/*) ;; *) continue;; esac; } 2>/dev/null   # 2>: bash warns of a NUL byte
    # Those files serve every bot here (and on every machine sharing them): a bot set up but never run with the plugin
    # (no plugin-sessions/ marker) still runs on these entries, as migrate_project weighs a project's own files. Looked
    # for once, and only when a file has entries to strip.
    if [ -z "$scanned" ]; then
      scanned=1
      for p in "${ps[@]}"; do
        p=${p%$'\r'}; [ -n "$p" ] || continue
        for b in "$p"/.claude/discord-agents/*/; do
          [ -f "$b.env" ] || continue
          set -- "$b"plugin-sessions/*
          [ -e "$1" ] || miss="$miss ${b%/}"
        done
      done
    fi
    if [ -n "$miss" ]; then
      echo "claude-discord: old claude-discord hook entries left in the user-global or a symlinked settings file: they still serve bots that have not run with the plugin yet:$miss (a session of each removes the need; the next setup or update strips them)" >&2
      return 0
    fi
    strip_one "$f"
  done
  return 0
}

# Run by update from the freshly pulled code (this process holds the old functions).
if [ "${1:-}" = compat ]; then
  crc=0; remove_old_install || crc=1
  strip_settings
  { . "$self_root/bin/lib/state.sh" && sweep_recorded "$helpers/records/projects"; } || :
  exit "$crc"
fi

# write_hosts <bot dir>: the manager's host ledger (<bot dir>/hosts), which
# the backend monitor reads and which is also its on/off switch. One line per
# host: the ssh host name, an optional `laptop` word (its own unreachability
# is never posted: a closed lid is not an outage), then optional KEY=VALUE env
# for the remote command. `local` (this machine, no ssh) is always there. An
# empty answer keeps the current list; a host already listed keeps its line as
# the owner left it. Each new host is probed once (the same ssh call also asks
# `uname -s` and the battery, so no second ssh), its answer printed, and
# written whatever the answer (a laptop may be asleep); a Darwin host with a
# battery is marked laptop, a host that did not answer is not and is said so.
write_hosts() {
  local f=$1/hosts ans h line out old="" new="" probe
  [ ! -f "$f" ] || old=$(cat "$f")
  read -rp "ssh hosts to check, comma-separated (this machine is always included): " ans || ans=""
  ans=${ans//[[:space:]]/}
  new="# ssh host names this manager checks; \"local\" is this machine (no ssh)"$'\n'
  line=$(printf '%s\n' "$old" | awk '$1 == "local"' | head -1)
  if [ -z "$line" ]; then
    line=local
    [ "$(uname -s)" != Darwin ] || ! pmset -g batt 2>/dev/null | grep -q InternalBattery || line="local laptop"
  fi
  new="$new$line"$'\n'
  if [ -z "$ans" ]; then
    new="$new$(printf '%s\n' "$old" | awk 'NF && $1 !~ /^#/ && $1 != "local"')"
  else
    set -f; set -- ${ans//,/ }; set +f   # split on commas, never glob
    for h in "$@"; do
      [ "$h" != local ] || continue
      case $h in -*|*[!A-Za-z0-9._@-]*) echo "claude-discord: skipping host '$h': not a plain ssh host name" >&2; continue;; esac
      line=$(printf '%s\n' "$old" | awk -v h="$h" '$1 == h' | head -1)
      # </dev/null: ssh would otherwise eat the rest of setup's piped answers.
      out=$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$h" 'uname -s; pmset -g batt 2>/dev/null | grep -q InternalBattery && echo battery; ~/.local/bin/claude-discord --version' </dev/null 2>&1) || :
      probe=$(printf '%s\n' "$out" | grep -m1 '^claude-discord ' || printf '%s\n' "$out" | tail -1)
      echo "  $h: ${probe:-no answer}"
      if [ -z "$line" ]; then
        line=$h
        if printf '%s\n' "$out" | grep -qxE 'Darwin|Linux'; then
          printf '%s\n' "$out" | grep -qx Darwin && printf '%s\n' "$out" | grep -qx battery && line="$h laptop"
        else
          echo "  $h: could not tell whether it is a laptop; written without the laptop word (add it by hand)"
        fi
      fi
      new="$new$line"$'\n'
    done
  fi
  ledger_write "$f" "$new" || :
}

# ledger_write <ledger> <text>: the ledger replaced by <text> (one newline at its end, whether <text> has it or not).
# A temp file moved in: a running monitor reads the ledger every pass and must never see it half written. It takes
# the ledger's own mode (an owner's chmod survives), 600 when new, never the caller's umask (perl: stat's flags differ by OS).
# Returns 1 when it could not, the ledger as it was. Used by setup (write_hosts) and by `hosts`.
parse_install_flags() {
  local a want=""
  scope="" method="" rest=()
  for a in "$@"; do
    if [ -n "$want" ]; then
      case $want in scope) scope=$a;; method) method=$a;; esac
      want=""
      continue
    fi
    case $a in
      --scope=*) scope=${a#--scope=};;
      --method=*) method=${a#--method=};;
      --scope) want=scope;;
      --method) want=method;;
      *) rest+=("$a");;
    esac
  done
  [ -z "$want" ] || { echo "claude-discord: --$want needs a value" >&2; exit 2; }
}

# Everything about the install that can be refused is decided here, before a
# prompt or a write: a bad flag or a copy at the other scope must leave the
# bot's files (and --reset's deletion) alone.
check_install_scope() {
  local p
  case $scope in ''|project|global) ;; *) echo "claude-discord: --scope must be project or global, got '$scope'" >&2; exit 2;; esac
  case $method in ''|link|clone) ;; *) echo "claude-discord: --method must be link or clone, got '$method'" >&2; exit 2;; esac
  # A bot in $HOME: its project's .claude IS ~/.claude, so its install is the global one.
  if [ "$(pwd -P)" = "$(cd -P "$HOME" && pwd)" ]; then
    [ "$scope" = global ] || echo "claude-discord: this project is \$HOME, whose .claude is ~/.claude: installing at global scope ($gdir)" >&2
    scope=global pdir=""
  fi
  # Asked once per project: an install already there decides the scope.
  if [ -z "$scope" ]; then
    if has_path "$pdir"; then scope=project; elif has_path "$gdir"; then scope=global; fi
  fi
  if [ "$scope" = project ] && has_path "$gdir"; then
    coexist "$pdir" "$gdir" "claude-discord: already installed globally at $gdir, and both scopes may hold an install only as links to ~/.claude-discord/source; remove it or use --scope global"
  elif [ "$scope" = global ] && has_path "$pdir"; then
    coexist "$gdir" "$pdir" "claude-discord: already installed for this project at $pdir, and both scopes may hold an install only as links to ~/.claude-discord/source; remove it or use --scope project"
  fi
  if [ "$scope" = global ] && ! has_path "$gdir"; then
    # A new global copy would shadow every project install the machine records (the global one wins).
    while IFS= read -r p || [ -n "$p" ]; do
      [ -z "$p" ] || [ ! -e "$p" ] || coexist "$gdir" "$p" "claude-discord: a project install exists at $p, which a global install would shadow (allowed only when both are links to ~/.claude-discord/source); remove it or use --scope project"
    done < <(cat "$HOME/.claude-discord/records/installs" 2>/dev/null)
  fi
}
# coexist <own path> <other install> <refusal>: a plugin present at both scopes
# loads once (measured), so two installs are fine when both are links to the
# source clone (one code); a clone on either side would run another version
# beside it, so that is refused before anything is written. An own install not
# made yet becomes a link.
coexist() {
  if src_link "$2" && { src_link "$1" || { ! has_path "$1" && [ "$method" != clone ]; }; }; then
    has_path "$1" || method=link
    return 0
  fi
  echo "$3" >&2; exit 2
}

# The plugin, the shim, runtime/, compat/ and the install record; before any
# bot question (R17), so a failed clone leaves no bot file behind.
install_all() {
  if [ -z "$scope" ]; then
    if [ -n "${noask:-}" ]; then scope=project; else scope=$(select_one Scope project "project  this project only (.claude/skills/claude-discord)" "global  every project (~/.claude/skills/claude-discord)"); fi
  fi
  install_plugin || return $?
  self_root=$plugin_target   # from here on, everything points at the real install
  remove_old_install || return $?
  strip_settings
}
pdir=$PWD/.claude/skills/claude-discord gdir=$HOME/.claude/skills/claude-discord
if [ "${1:-}" = install ]; then
  noask=1
  parse_install_flags "${@:2}"
  [ "${#rest[@]}" = 0 ] || { echo "usage: claude-discord install [--scope project|global] [--method link|clone]" >&2; exit 2; }
  check_install_scope
  install_all || exit $?
  # A bot's start patches the cache, but install then /reload-plugins with no restart would leave it unpatched (measured on lmd79). A failed patch must not fail the install.
  patch_official || echo "claude-discord: some patches no longer apply (see above); the install is done anyway" >&2
  echo "claude-discord: installed at $plugin_target; set up a bot with: claude-discord setup <name>"
  exit 0
fi
if [ "${1:-}" = setup ]; then
  [ -n "${2:-}" ] || { echo "usage: claude-discord setup <name> [--scope project|global] [--method link|clone] [--reset|--mode]" >&2; exit 2; }
  name=$2
  # --scope and --method may sit anywhere after the name; the rest keeps its place so ${3:-} still sees --reset/--mode.
  parse_install_flags "${@:3}"
  # `bot add` runs setup with its answers on stdin: the install's own questions (scope, method, trust) are not asked
  # then, as `install` asks none, so they cannot take one of those answers.
  [ -z "${CLAUDE_DISCORD_SETUP_NOASK:-}" ] || noask=1
  set -- "$1" "$2" ${rest[@]+"${rest[@]}"}
  case $name in
    ''|.|..|*/*) echo "claude-discord: bot name must be a plain directory name, got '$name'" >&2; exit 2;;
    hooks|checkin) echo "claude-discord: bot name '$name' is reserved for the $name directory" >&2; exit 2;;
  esac
  ! reserved_name "$name" || { echo "claude-discord: bot name '$name' is reserved: 'claude-discord ${name/#add/bot add}' is a subcommand" >&2; exit 2; }
  if [ "${3:-}" = --mode ]; then
    [ -z "$scope$method" ] || { echo "claude-discord: --mode changes only the mode and installs nothing; --scope and --method do not apply" >&2; exit 2; }
  else
    check_install_scope
    install_all || exit $?
  fi
  umask 077
  if [ "${3:-}" = --mode ]; then
    # --mode changes only an already set-up bot's mode, so re-picking a mode
    # never re-asks the token or the mention question. It creates nothing:
    # a bot without both files gets neither a directory nor config.env.
    [ -f "$root/$name/.env" ] && [ -f "$root/$name/access.json" ] || {
      echo "claude-discord: bot '$name' is not set up; run 'claude-discord setup $name' first" >&2
      exit 2
    }
  else
    # --reset forgets this bot's token and access policy AND the shared IDs, so
    # every prompt is asked again; other bots keep their own files.
    [ "${3:-}" = --reset ] && rm -rf "$root/$name" "$root/config.env"
    mkdir -p "$root/$name"
    printf '*\n' > "$root/.gitignore"
    # A project set up before its Discord channel existed (Enter at these
    # prompts) is asked again, so a later setup run fills the IDs in.
    if [ ! -f "$root/config.env" ] || grep -qxE "DISCORD_(CHANNEL|USER)_ID=('')?" "$root/config.env"; then
      ask channel "Discord channel ID: "
      ask user "Your Discord user ID: "
      # Shown only at a terminal, like read -p's own prompt.
      [ -t 0 ] && cat >&2 <<'EOT'
Other user or bot IDs allowed to trigger bots there: comma-separated, empty for none,
or 'all' for everyone in the channel -- anyone who can post there could then drive this
session, which runs with shell access on this machine. Other bots in the channel count too, and
a reply to this bot counts as a mention, so two open bots can answer each other without end;
with 'respond without an @mention' on, they will.
EOT
      ask others "IDs: "
      others=${others//[[:space:]]/}   # the file is sourced: a stray space would run an ID as a command
      # "all" applies to THIS bot only and is not persisted: config.env is
      # shared by every bot in the project, so storing it would quietly open
      # up each bot set up here later. Mixing it with ids is refused rather
      # than guessed: taking the wider reading would open the channel on a
      # typo, and the narrower one would store a literal "all" as an ID.
      case $(printf '%s' "$others" | tr '[:upper:]' '[:lower:]') in   # tr, not the ,, expansion: macOS /bin/bash is 3.2
        all) allow_all=yes; others=;;
        *,all|all,*|*,all,*)
          echo "claude-discord: answer either 'all' or a list of IDs, not both" >&2; exit 2;;
      esac
      printf "DISCORD_CHANNEL_ID='%s'\nDISCORD_USER_ID='%s'\nDISCORD_ALLOW_IDS='%s'\n" "$channel" "$user" "$others" > "$root/config.env"
    fi
  fi
  [ -f "$root/config.env" ] && . "$root/config.env"   # sourced whenever present: later code (write_access) reads its variables
  if [ "${3:-}" != --mode ]; then
    keep=""
    [ -f "$root/$name/.env" ] && keep=" (empty keeps the current one)"
    ask token "Bot token for $name$keep: " -s
    echo
    [ -z "$token" ] && [ -n "$keep" ] || printf 'DISCORD_BOT_TOKEN=%s\n' "$token" > "$root/$name/.env"
    # Every bot in one channel answering every message means N replies per human
    # message, so the default stays mention-only; opt in per bot. Enter keeps
    # what the bot has now (its first group's requireMention).
    mention=true q='[y/N]'
    if [ "$(jq -r '[.groups[]?.requireMention][0]' "$root/$name/access.json" 2>/dev/null)" = false ]; then mention=false q='[Y/n]'; fi
    ask nomention "Respond to every message in the channel without an @mention? $q "
    case $nomention in y|Y) mention=false;; n|N) mention=true;; esac
    # access.json is the bot's LIVE policy: the plugin re-reads it on every
    # message, and its groups may have been hand-edited since the last setup
    # (moved to another channel, allowFrom trimmed, ackReaction silenced). A
    # re-run must not clobber that; only a bot with none yet (new, or just
    # after --reset, which deletes the bot dir first) gets one written fresh.
    # The one exception: a bot set up with no channel or user ID yet has a
    # group keyed "" and "" in allowFrom. Once the IDs are known, that group
    # takes the channel as key and each "" becomes the user (plus the other
    # IDs, or [] for "all", as write_access builds it); every other field stays.
    if [ -f "$root/$name/access.json" ]; then
      jq_edit "$root/$name/access.json" --argjson mention "$mention" --arg ch "${DISCORD_CHANNEL_ID:-}" --arg me "${DISCORD_USER_ID:-}" \
          --arg others "${DISCORD_ALLOW_IDS:-}" --arg open "${allow_all:+yes}" '
        def fill($ids): if (.allowFrom | type) == "array" then .allowFrom |= map(if . == "" then $ids[] else . end) else . end;
        if (.groups | type) == "object" then .groups |= map_values(.requireMention = $mention) else . end
        | if $me == "" then . else
            fill([$me])
            | if $ch != "" and (.groups | type) == "object" and (.groups | has("") and (has($ch) | not)) then
                .groups[$ch] = (.groups[""] | if $open == "yes" then .allowFrom = []
                  else fill([$me] + ($others | split(",") | map(gsub("\\s";"")) | map(select(. != "")))) end)
                | del(.groups[""])
              else . end
            # A group whose channel was known but whose allowFrom still holds "" (user ID answered later).
            | if (.groups | type) == "object" then .groups |= map_values(if $open == "yes" then (if (.allowFrom | type) == "array" then .allowFrom |= map(select(. != "")) else . end)
                else fill([$me] + ($others | split(",") | map(gsub("\\s";"")) | map(select(. != "")))) end) else . end
          end'
    else
      # allow_all is set only by the answer above, so it reaches this bot and
      # no other: a bot set up later in the same project inherits config.env's
      # ids, which never carry "all", and stays closed unless asked again with
      # --reset.
      write_access "$root/$name" "$mention" "${allow_all:+all}"
    fi
  fi
  mode=$(cat "$root/$name/mode" 2>/dev/null) || mode=none
  mode=$(select_one Mode "$mode" \
    "none  a plain bot" \
    "dev-manager  coordinates claude-discord changes with peer bots" \
    "autoresearchclaw  reports each AutoResearchClaw iteration to the channel")
  if [ "$mode" = dev-manager ] && [ -f "$helpers/records/projects" ]; then
    # One backend (state dir, keeper, monitor) per manager bot NAME on a machine: a second project's manager of the same
    # name would share it, and two ledgers would be followed by whichever monitor started first.
    here=$(pwd -P)
    while IFS= read -r p || [ -n "$p" ]; do
      p=${p%$'\r'}
      [ -n "$p" ] && [ "$p" != "$here" ] && [ -f "$p/.claude/discord-agents/$name/hosts" ] && [ "$(cat "$p/.claude/discord-agents/$name/mode" 2>/dev/null)" = dev-manager ] || continue
      echo "claude-discord: '$name' is already a dev-manager with a hosts ledger in $p; one backend serves one manager name per machine, so pick another bot name here" >&2
      exit 2
    done < "$helpers/records/projects"
  fi
  printf '%s\n' "$mode" > "$root/$name/mode"
  if [ "$mode" = dev-manager ]; then
    read -rp "Peer dev bots as name:bot_id:owner_id:machine, comma-separated (empty keeps the current list): " peers || :
    peers=${peers//[[:space:]]/}
    entry='^[^:]+:[0-9]+:[0-9]+:[^:]+$'
    bad=$(jq -rn --arg in "$peers" --arg re "$entry" '$in | split(",")[] | select(. != "" and (test($re) | not))')
    [ -z "$bad" ] || echo "claude-discord: skipping peers not shaped name:bot_id:owner_id:machine: ${bad//$'\n'/ }" >&2
    jq_edit "$root/peers.json" --arg in "$peers" --arg re "$entry" '
      reduce ($in | split(",")[] | select(test($re)) | split(":") | {name: .[0], bot_id: .[1], owner_id: .[2], machine: .[3]}) as $p
        (.; if any(.peers[]?; .bot_id == $p.bot_id) then .peers |= map(if .bot_id == $p.bot_id then $p else . end)
            else .peers = (.peers // []) + [$p] end)'
    # access.json's groups are kept as they are (see above), so peers go into
    # every existing group's allowFrom, wherever the bot's channel actually
    # is, not only the one keyed by config.env's channel; this bot itself is
    # skipped by name, and $a + ($ids - $a) keeps it additive, as before.
    ids=$(jq -c --arg self "$name" '[.peers[]? | select((.name // "" | tostring | ascii_downcase) != ($self | ascii_downcase)) | .bot_id | tostring]' "$root/peers.json" 2>/dev/null) || ids='[]'
    # An EMPTY allowFrom already lets every author through, peers included, and
    # adding ids to it would narrow the group to just those ids -- turning
    # "everyone" into "peers only" without saying so. Such a group is left as
    # it is. `access set mode=dev-manager` (CLAUDE_DISCORD_ACCESS_PEERS=written) has done this already, shown it and
    # written it under its lock: done again here it would be a write outside that lock, of peers nobody was shown.
    [ "${CLAUDE_DISCORD_ACCESS_PEERS:-}" = written ] ||
    jq_edit "$root/$name/access.json" --argjson ids "${ids:-[]}" \
      'if (.groups | type) == "object"
       then .groups |= map_values(if (.allowFrom // []) == [] then .
                                  else .allowFrom = (.allowFrom as $a | $a + ($ids - $a)) end)
       else . end'
    echo "Ask each peer's owner to add this bot's id to their allowFrom; both directions are needed."
    write_hosts "$root/$name"
  else
    # Only a manager posts to #bot-health-check: any other mode has no ledger, so no monitor.
    rm -f "$root/$name/hosts"
  fi
  ensure_hooks_symlink
  record_project
  # A manager's backend runs with no session and no TUI: started here, detached, unless one runs or its owner stopped
  # it (the front says which, in one line).
  if [ "$mode" = dev-manager ] && [ -f "$root/$name/hosts" ]; then
    bash "$self_root/monitor/monitor.sh" "$self_path" --keep "$name" --detach </dev/null || :
  fi
  if [ "${3:-}" = --mode ]; then
    echo "claude-discord: $root/$name/mode set to $mode"
  else
    echo "claude-discord: $root/$name/access.json written (requireMention=$mention, mode=$mode)"
  fi
  exit 0
fi

# update: fast-forwards the clone this command runs from, or with --all every
# recorded install, then re-patches the official plugin and refreshes the shim.
# A link resolves to the clone behind it (cd -P), so the clones that many links
# share are pulled once. Running sessions keep the code they loaded until
# /reload-plugins.
if [ "${1:-}" = update ]; then
  case ${2:-} in ''|--all) ;; *) echo "usage: claude-discord update [--all]" >&2; exit 2;; esac
  clones=("$self_root") rc=0
  if [ "${2:-}" = --all ]; then
    clones=() seen=$'\n'
    prune_installs   # a project removed since setup drops out here
    if [ -f "$helpers/records/installs" ]; then
      while IFS= read -r c || [ -n "$c" ]; do
        c=$(cd -P "$c" 2>/dev/null && pwd -P) || continue
        case $seen in *$'\n'"$c"$'\n'*) continue;; esac
        seen="$seen$c"$'\n'
        clones+=("$c")
      done < "$helpers/records/installs"
    fi
    [ "${#clones[@]}" -gt 0 ] || echo "claude-discord: no recorded install to update"
  fi
  for c in ${clones[@]+"${clones[@]}"}; do
    # A clone checked out at a tag or sha is pinned on purpose: skipped, not a failure.
    git -C "$c" symbolic-ref -q HEAD >/dev/null 2>&1 || { echo "claude-discord: $c: pinned at $(git -C "$c" rev-parse --short HEAD 2>/dev/null || echo '?'), skipped"; continue; }
    old=$(plugin_version "$c")
    git_net -C "$c" pull -q --ff-only || { echo "claude-discord: $c: pull failed (local changes, diverged, or no network)" >&2; rc=1; continue; }
    echo "claude-discord $c: $old -> $(plugin_version "$c")"
  done
  # The patch step and the shim come from the freshly pulled code, run as a
  # new process (this one still holds the old functions). runtime/ and the
  # patched cache are machine-wide, so the machine's source clone owns them;
  # without one, the first clone pulled (or this one).
  new=$self_root
  [ -x "$helpers/source/bin/claude-discord" ] && new=$helpers/source || { [ "${#clones[@]}" -eq 0 ] || new=${clones[0]}; }
  "$new/bin/claude-discord" patch || rc=1
  # compat arrived in 1.8.0: older code would read the word as a bot name.
  if ver_ge "$(plugin_version "$new")" 1.8.0; then
    "$new/bin/claude-discord" compat || rc=1
  else
    echo "claude-discord: $new is at $(plugin_version "$new"), before the compat copy (1.8.0); ~/.claude-discord/hooks left as it is"
  fi
  mkdir -p "$HOME/.local/bin"
  cmp -s "$new/shim/claude-discord" "$HOME/.local/bin/claude-discord" ||
    install -m 755 "$new/shim/claude-discord" "$HOME/.local/bin/claude-discord" ||
    { echo "claude-discord: could not install the shim from $new" >&2; rc=1; }
  echo "claude-discord: run /reload-plugins in running sessions (a bot: the self-reload skill)"
  exit "$rc"
fi
