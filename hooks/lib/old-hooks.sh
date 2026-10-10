# The hook entries earlier releases wrote into settings files (a command under
# .claude/discord-agents/hooks/) and the rule copies they put in .claude/rules.
# Sourced by discord.sh on a plugin hook's first run in a bot session
# (plugin_gate), which takes this project's own copies out. Run as a script,
# `bash old-hooks.sh <settings file>...` removes the entries from the files
# named, symlinks included: the command setup prints for a file the hook never
# edits (a symlink into a dotfiles repo, the user-global settings.json).

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

# strip_old_hooks <file>: written only when the result differs. A regular file
# is replaced by a rename of a copy that keeps its mode, so Claude Code, which
# re-reads settings live, never sees it half written; a symlink is written
# through. Not JSON, not walkable or not writable: left alone, return 1. Silent.
strip_old_hooks() {
  local f=$1 out base t=$1.tmp.$$
  grep -qF /.claude/discord-agents/hooks/ "$f" 2>/dev/null || return 0   # nothing of ours: no jq forks
  [ -w "$f" ] || return 1
  base=$(jq . "$f" 2>/dev/null) && out=$(printf '%s' "$base" | jq "$old_hooks_filter" 2>/dev/null) && [ -n "$out" ] || return 1
  [ "$out" != "$base" ] || return 0
  if [ -L "$f" ]; then
    printf '%s\n' "$out" > "$f" 2>/dev/null || return 1
  else
    cp -p "$f" "$t" 2>/dev/null && printf '%s\n' "$out" > "$t" 2>/dev/null && mv -f "$t" "$f" 2>/dev/null || { rm -f "$t"; return 1; }
  fi
}

# migrate_project: this project's own regular settings files and rule copies.
# Never a symlinked settings file (it leads out of the project, often into a
# repo a hook auto-pushes) and never the user-global settings.json, which is
# what a bot in $HOME would call its project settings.
migrate_project() {
  local p=${CLAUDE_PROJECT_DIR:-} f
  [ -n "$p" ] || return 0
  for f in "$p/.claude/settings.json" "$p/.claude/settings.local.json"; do
    [ -f "$f" ] && [ ! -L "$f" ] && [ ! "$f" -ef "$HOME/.claude/settings.json" ] || continue
    strip_old_hooks "$f" || :
  done
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
