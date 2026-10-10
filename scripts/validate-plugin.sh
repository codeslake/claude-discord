#!/usr/bin/env bash
# Loads the repo as a plugin with the real claude, outside the 40 s stub suite.
set -euo pipefail
cd "$(dirname "$0")/.."
if ! claude plugin --help 2>/dev/null | grep -q validate; then
  echo "this claude has no 'plugin validate'; check by hand: a trusted project with this repo at .claude/skills/claude-discord lists discord-agents in /plugin" >&2
  exit 2
fi
claude plugin validate .
