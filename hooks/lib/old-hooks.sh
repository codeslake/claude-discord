# The hook entries earlier releases wrote into settings files (a command under
# .claude/discord-agents/hooks/) and the rule copies they put in .claude/rules.
# Sourced by discord.sh on a plugin hook's first run in a bot session
# (plugin_gate), which takes this project's own copies out. Run as a script,
# `bash old-hooks.sh <settings file>...` removes the entries from the files
# named, symlinks included (their target is edited): the command setup prints
# for a file the hook never edits (a symlink into a dotfiles repo, the
# user-global settings.json). Those entries serve every bot not yet running the
# plugin, on this machine and on any machine sharing the file: run it only once
# each of them has a <bot dir>/plugin-sessions/ marker.

# Drops every entry whose command is ours, then a matcher group or an event left
# empty by that, then a hooks key we emptied; every other entry stays.
old_hooks_filter='
  ((.hooks | type) == "object" and (.hooks | tostring | contains("/.claude/discord-agents/hooks/"))) as $ours
  | def stale: (.command? // "" | tostring | contains("/.claude/discord-agents/hooks/"));
  (if (.hooks | type) != "object" then . else
    .hooks |= with_entries(
      if (.value | type) == "array" and any(.value[]; any(.hooks?[]?; stale)) then
        .value |= map(if any(.hooks?[]?; stale) then (.hooks |= map(select(stale | not))) | select(.hooks | length > 0) else . end)
        | select(.value | length > 0)
      else . end)
  end)
  | if $ours and .hooks == {} then del(.hooks) else . end'

# strip_old_hooks <file>: written only when the result differs, by renaming a
# copy that keeps the mode over the file (a symlink's target, so the link
# stays), so Claude Code, which re-reads settings live, never sees it half
# written. Not JSON, not walkable or not writable: left alone, return 1. Silent.
strip_old_hooks() {
  local f=$1 out base t l n=0
  grep -qF /.claude/discord-agents/hooks/ "$f" 2>/dev/null || return 0   # nothing of ours: no jq forks
  while [ -L "$f" ] && [ "$n" -lt 40 ]; do   # the target, by hand: readlink -f is missing on older macOS
    l=$(readlink "$f") || return 1
    case $l in /*) f=$l;; *) f=${f%/*}/$l;; esac
    n=$((n + 1))
  done
  t=$f.tmp.$$
  [ -f "$f" ] && [ -w "$f" ] || return 1
  base=$(jq . "$f" 2>/dev/null) && out=$(printf '%s' "$base" | jq "$old_hooks_filter" 2>/dev/null) && [ -n "$out" ] || return 1
  [ "$out" != "$base" ] || return 0
  cp -p "$f" "$t" 2>/dev/null && printf '%s\n' "$out" > "$t" 2>/dev/null && mv -f "$t" "$f" 2>/dev/null || { rm -f "$t"; return 1; }
}

# migrate_project: this project's own regular settings files and rule copies.
# Never a symlinked settings file (it leads out of the project, often into a
# repo a hook auto-pushes) and never the user-global settings.json, which is
# what a bot in $HOME would call its project settings.
migrate_project() {
  local p=${CLAUDE_PROJECT_DIR:-} f d
  [ -n "$p" ] || return 0
  # Every component under the project, not only the file: a .claude that is
  # itself a link (into a dotfiles tree, say) is not the project's own.
  d=$(cd -P "$p/.claude" 2>/dev/null && pwd) && [ "$d" = "$(cd -P "$p" && pwd)/.claude" ] || return 0
  for f in "$p/.claude/settings.json" "$p/.claude/settings.local.json"; do
    [ -f "$f" ] && [ ! -L "$f" ] && [ ! "$f" -ef "$HOME/.claude/settings.json" ] || continue
    strip_old_hooks "$f" || :
  done
  [ ! -d "$p/.claude/rules" ] || [ "$(cd -P "$p/.claude/rules" && pwd)" = "$d/rules" ] || return 0
  for f in "$p"/.claude/rules/claude-discord-*.md; do
    [ -e "$f" ] || [ -L "$f" ] || continue   # an unmatched glob stays literal
    rm -f "$f" 2>/dev/null || :
  done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  rc=0
  for f in "$@"; do
    strip_old_hooks "$f" || { echo "old-hooks: $f left as it was (not JSON, or not writable)" >&2; rc=1; }
  done
  exit "$rc"
fi
