# claude-discord backend monitor, TUI and health alerts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A manager bot's machine notices, within one pass, any bot on its ledger hosts that stopped answering and tells that bot's owner in `#bot-health-check` once, with a command that fixes it, through a backend monitor that lives only while the TUI or the manager session holds it, with no OS scheduler.

**Architecture:** `claude-discord health --all --json --patch` becomes the one command a pass runs per host (locally, or over `ssh -o BatchMode=yes`); `stale` becomes a delivery check against `<bot>/delivered`, which `on-prompt` writes; macOS counts plugin servers through `ps -axww` then `ps -Eww -p` (Ruling T3-1). A new `monitor/monitor.sh` (bash 3.2, run by the wrapper verb `claude-discord monitor`) holds a perl `flock` on fd 9, folds each pass into `state.json` through one jq reducer, and posts one message per state change with the manager bot's token. `setup` writes the ledger `<bot>/hosts` in dev-manager mode; the SessionStart hook and `claude-discord tui` (Python + Textual via `uv run --script`) register holders and ensure the monitor.

**Tech Stack:** bash (3.2-compatible: macOS `/bin/bash`), perl (`flock`, `setsid`), jq (1.6 on lmd42), curl, ssh, Python 3.9+ with Textual `>=8.2.8,<9` through uv (TUI only), the stub-only suite `test-claude-discord.sh`.

**Spec:** `docs/superpowers/specs/2026-10-10-monitor-tui-health-design.md` (branch `spec/monitor-tui`). Read it before Task 2; it quotes the owner's decisions. Plan against `origin/main` (fa3719f, 1.9.2): cut `impl/monitor-tui` from `origin/main` and merge `spec/monitor-tui` into it first, so the spec and this plan travel with the code.

Every piece of code below was run before this plan was written: the full suite passed with all of it (144 `ok:` lines, `ALL PASS`), the TUI pilot test passed, the monitor ran under macOS `/bin/bash` 3.2 on wmac, and each task's mutation check below was executed and failed as stated.

**Deviations from the spec, each deliberate (say them in the review thread):**
1. `state.json` has no `monitor.exiting`. The exit race is covered by `--ensure`'s 5 s wait for the lock (spec "Exit race"), which a test proves; a flag would add a second protocol for the same window.
2. `hostdown` is ssh's own failure, exit 255 twice (the second with `-o ControlPath=none`), or a `laptop` that hangs past the per-host cap. Any other non-zero exit, or a non-laptop past the cap, without a document is `blind`: over ssh, "claude-discord missing" (exit 127) is non-zero too, and the spec files that under `blind`.
3. `health --all --json` exits 0 whenever it printed its document, findings or not, so over ssh a non-zero status means transport only.
4. The holder record's start time comes from `/proc/<pid>/stat` (field 22, no fork) on Linux and from `ps -o lstart=` elsewhere: the check runs every tick and `ps` costs 22 ms a call on lmd42.
5. `pass.out` (one host's answer, removed at the end of each pass) joins the spec's fixed file list: a command substitution cannot be polled every tick, and an ssh ControlMaster could hold its pipe open.
6. A fourth interval override, `CLAUDE_DISCORD_MONITOR_LOCK_WAIT` (default 5 s), lets the suite test the lock wait in 0.15 s; `CLAUDE_DISCORD_PROC` and `CLAUDE_DISCORD_UV` exist only so the suite can exercise the macOS count on Linux and a missing uv.
7. The suite grows by more than the spec's ~3 s: measured 28.3 s after Task 0b and 35.3 s at f3a0cec (main's merge in between), 36.5 s after the final fix round (35.2 to 35.5 s for f3a0cec in the same alternating runs), serial at load 15 to 17; R3's end-state cap is 37 s.
8. A `no-holders` exit keeps `holders/*`: every record left was found dead and removed by the check just before, so one that is there at exit belongs to a holder whose `--ensure` is waiting for the lock (the exit race), and it must stay for the monitor that wait starts. The next start's first holder check, before its first pass, prunes any stale record. A signal exit still removes them all.
9. `session_pid` takes `$CLAUDE_PID` first (Claude Code sets it to its own pid for its children) when that pid's argv[0] is a Claude Code CLI and its argv[1] is not `daemon`; else it looks three ancestor levels up at most, not for the nearest claude at any depth (Ruling P5): a `CLAUDE_CODE_SHELL_PREFIX` runs a hook as claude -> sh -c "<prefix> ..." -> sh -c -> hook, and dash does not exec the last command, so the 1.10.0 cap of two levels found no session there (1.10.1, measured live on lmd42). A claude four levels up is not this hook's session. Both match argv[0] only: a `bash .../claude-proxied .../claude/versions/x` wrapper is no session. No session found is logged in the bot's `health.log`.
10. A `stale` candidate is also cleared by a later message of the bot in the same chat (channel or thread) in the fetched page (Ruling T2-1): a message lost in a refresh or handoff gap and answered by catch-up stops alerting, while one stuck thread still alerts.
11. `claude-discord install` ends with one `patch_official` run (idempotent; Ruling R4, dong 02:16Z), so install plus `/reload-plugins` without a restart leaves the official cache patched. The spec does not ask for it.
12. A running monitor picks up a changed `monitor.sh` (after `claude-discord update`) by exec'ing it at a pass start, same pid and lock, but only once the file's signature (mtime to the sub-second, size, inode) has held for a whole pass and it parses: a file caught mid-write can be cut off at a line end and still parse (dong finding 1, Ruling D1). A monitor that dies anyway (kill -9, OOM) is started again by the manager's next prompt: on-prompt checks state.json's `monitor.pid` and ensures the monitor as SessionStart does: the pid's command line must be `bash <root>/monitor/monitor.sh <wrapper> --locked <bot>` (Linux: /proc/<pid>/cmdline, no fork; macOS: one `ps -p <pid> -o command=` per prompt, since `kill -0` reads a reused pid as alive). The TUI's `alive()` makes the same check on both OSes.
13. `health --all` never prunes `records/projects`: a project whose `<root>/.claude/discord-agents` is missing (a volume mounted late, the other side of a shared home) is reported as `{project, bots: [], error: "project folder missing: ..."}`, which the monitor reads as `blind`, and text mode exits 1. The owner deletes the line by hand once the project is gone for good (dong finding 2).
14. A host taken out of the ledger keeps its entry, its bots and their `posted` for a day (`left_s`), frozen and never due, so a host missing for a pass and back posts nothing it already posted; then it is dropped with its bots. setup writes the ledger by temp file and `mv` (dong finding 6).
15. The lock file holds the running monitor's pid, checked every tick and before each post with no fork; a lock file removed or replaced under a running monitor (which let a second one start) ends it, logged `exit reason=lock-lost`, without the holder records or `monitor.pid`. What that pass already posted is written to state.json first, but only while the file is gone or empty, before any successor has read state.json. `[ /dev/fd/9 -ef lock ]` was measured false on macOS (another st_dev), hence the pid (dong finding 7).
16. thread-guard's jq fold takes each field's own first line (`line`), where the old code used two `read`s that a newline in `tool_name` shifted by one: a reply whose `tool_name` is `mcp__plugin_discord_discord__reply` plus a newline and more is now denied when it answers a bot without its mention (the old code let it through). Claude Code sets `tool_name` to the registered tool name and never sends a newline; the new reading is the correct one (dong round review, minor 1: the only difference in 1538 replayed inputs).
17. A third holder kind, `keeper` (1.10.3, owner 2026-10-12: "launchd 아니면 상관없어. tui 실행하면 상시 실행되게 하던가."): `claude-discord monitor --keep <bot>` runs in the foreground, registers `holders/keeper-<pid>` (start time as the others) and runs `--ensure` every 60 s (`CLAUDE_DISCORD_KEEP_INTERVAL`, read only there, for the suite), so the monitor no longer needs a TUI or session. It exits 1 for no ledger or a bot not in dev-manager mode, 0 when a live keeper exists; TERM/INT removes its record. A signal exit of the monitor keeps keeper records (the keeper starts the next one). `tui` starts one detached (`--detach`: perl setsid, stdio to monitor.log), so quitting the TUI leaves the monitor up; `monitor --stop <bot>` TERMs the keepers, waits for them, then TERMs the monitor. Shared home (dong-dev-bot): `--keep` refuses, exit 1, when the lock is held and the pid the lock file names is no `monitor.sh ... --locked <bot>` visible on this side (checked twice, a lock wait apart); a refusal only, never a takeover. Still no OS scheduler: tmux, a container entrypoint or a user's own systemd unit run the keeper.
18. Alerts are grouped per host within one pass (1.10.3): two or more due `down` findings of bots on one host are one message (`[down] N bots on <host>`, a block per bot, each distinct owner mentioned once), and two or more recoveries from `down` there are one `[recovered] N bots on <host>` message. The O line's key field carries the keys RS-separated; `apply` splits them, so `posted` and `alerts` stay per bot and a bot that recovers alone gets its own line. Other kinds and host-level findings are unchanged; the 1900-character cut applies to the grouped message.
19. The backend runs on its own (1.10.3, owner 2026-10-12 19:48Z; amends 9 and 17): a manager bot's backend is its keeper and the monitor, running until `monitor --stop`. SessionStart and on-prompt of a dev-manager no longer register the session as a holder: they start the keeper detached when `keeper_alive` (a holders/keeper-<pid> record whose pid runs `monitor.sh ... --keep <bot>`; /proc with no fork on Linux, one ps elsewhere) finds none, so `session_pid`, `ensure_monitor`, `monitor_alive`, the `session` holder kind and the suite's re-exec away from a claude parent are gone (old `session-*` records are still read until their session ends). `setup <bot> --mode` in dev-manager mode with a ledger starts it too and says so in one line. `--stop` leaves `records/monitor/<bot>/stopped` and sets `monitor.stopped_by_user` in state.json: no automatic start (setup, the TUI without a yes at a terminal, the hooks, `--ensure`) until `monitor --start <bot>`, which clears it; the TUI's red bar says `stopped by you`. The keeper re-execs itself, same pid, when monitor.sh changed and held still for an interval (as the monitor does at a pass). `CLAUDE_DISCORD_NO_AUTOSTART=1` turns every automatic start off on a machine: the other side of a shared home, and the suite, where every dev-manager setup would otherwise start one; the tests of those starts unset it for the one call. Then (option A, decided 2026-10-12): not only the manager session but every claude-discord bot's SessionStart and prompt run `revive_backends`, which walks records/projects (as tui does) for dev-manager bots with a ledger and starts each one's keeper when `keeper_alive` finds none and no marker stands; builtins only on Linux. The TUI asks at launch when the marker stands (Yes: `monitor --start`; No: read-only, `stopped by you`) and `Q` quits and stops the backend after a yes; both dialogs default to No; the wrapper no longer asks itself.

## Global Constraints

- HARD HOME RULE, repeated verbatim in every task: "any probe outside the test suite sets a literal sandbox HOME in the SAME Bash call, chained with &&; never write the real ~/.claude.json, ~/.claude, ~/.claude-discord or ~/.local/bin; run hand-run hooks/tools with env -u DISCORD_STATE_DIR."
- Suite: `./test-claude-discord.sh ./bin/claude-discord` passes serially on stubs only (no real claude, network, Discord, `--bg`), within 40 s wall, per `CLAUDE.md`. Measured while writing this plan on lmd42: origin/main 33.6 to 34.3 s; with this plan's tests 38.3 to 39.7 s at load 2 to 10, 41 to 43 s at load above 8. Measure quiet (`uptime` load below 4) before the last commit of Task 9; over 40 s is a stop-and-report, not a pass.
- Shell is bash 3.2-compatible everywhere a Mac runs it (wrapper, hooks, `monitor/monitor.sh`): no `declare -A`, no `${x,,}`, no `mapfile` outside the Linux-only path, no fractional `read -t`, no `&>>`. `monitor/monitor.sh` has no here-document or here-string at all (bash 3.2 writes both to TMPDIR); the suite greps for `<<`.
- No OS scheduler: no launchd, systemd or cron. The monitor lives while a holder lives and exits within one tick (30 s) of the last.
- macOS server count: candidates from `ps -axww -o pid=,command=` (argv only: argv[0] `bun`, last word `start`, an argument under `.../discord/`), then `ps -Eww -o pid=,command= -p <pids>` for those pids only, WITHOUT `-ax`: on real BSD ps `-ax` ORs with `-p` and prints the whole table (836 lines, measured on wmac 2026-10-12), so every shell of the session would count. `-p` alone finds tty-less pids; only the candidate list needs `-ax`.
- `stale` = an addressed message unanswered 15 min, no live turn, and its id NOT in `<bot>/delivered`, which `on-prompt` writes (the last 200 lines).
- A ledger `laptop` host never posts `hostdown`.
- `ALERT_LANG=ko|en` in the manager project's `.claude/discord-agents/config.env`, default `ko`; `en` in any case is English, any other value is `ko`. Only the labels change.
- `#bot-health-check` is channel `1558283274487341137`, a constant in `monitor/monitor.sh`, write-only (in no bot's `access.json`).
- The TUI runs through `uv run --script` with Textual `>=8.2.8,<9`; uv is required for the TUI only, with a clear message when missing.
- The monitor's intervals: `CLAUDE_DISCORD_MONITOR_TICK` (30), `_PASS` (300; health's `unknown_cap=6` assumes it), `_HOST_CAP` (90), `_LOCK_WAIT` (5), seconds, fractions allowed.
- No token in `state.json`, `monitor.log`, the TUI, argv or a message: the token is read from `.env` at POST time and sent on curl's stdin.
- Code and comments in English; match the wrapper's comment density (a why per non-obvious line). No em-dashes in new text.
- Every task's tests fail when its fix is reverted (the SDD loop runs mutations; each task lists the one run while writing this plan).
- Commit by path only (`git commit -m ... -- <paths>`, `git add` new files first), each message ending with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`. dong-dev-bot reviews every diff before main (project rule).

## Review Focus

1. **A project path with a space, a quote or a `$`** (`/home/u/it's $x here`): the recovery command in an alert must survive both the local shell and ssh's remote shell, and `health --all` must walk such a project. Pinned in Task 7 ("FAIL: a project path with a space, a quote and a $ must be quoted for both shells") and Task 4 (the walked project is `$HOME/single project`).
2. **A ledger saved with CRLF line endings** (edited on Windows or pasted): every host must still be read, its env words without a trailing `\r`. Pinned in Task 6 (the first ledger is written with `\r\n`; "FAIL: local runs the shim's health ... with the local line's env").
3. **A laptop asleep behind its reverse tunnel**: ssh connects to the jump and the forward hangs past the cap instead of failing; that must read as an unposted `hostdown`, never a posted `blind`. Pinned in Task 7 ("FAIL: a laptop silent past the cap is hostdown (asleep), never a posted blind").
4. **The manager's `.env` without its token at POST time** (rotated, hand-edited): the post fails before any curl, is retried next pass, and the log says why. Pinned in Task 7 ("FAIL: a POST with no token in the manager's .env must fail before curl, logged with the reason").
5. **`claude-discord tui` run from a subdirectory of the project**: it must find the project above it, as the shim does. Pinned in Task 9 ("FAIL: tui from a subdirectory of the project must find the project above it").

---
### Task 1: Measurements the plan relies on (done 2026-10-11)

Not code; recorded here so no implementer repeats them. Every probe ran with a sandbox HOME (`/home/j.lee8/.claude/jobs/3bf66a89/tmp/anc/home` on lmd42, `/tmp/cd-probe-3bf66a89/home` on wmac) and removed what it created; the probe `--bg` sessions were stopped and `claude rm`-ed and their sandbox daemons killed by captured pid.

HARD HOME RULE: any probe outside the test suite sets a literal sandbox HOME in the SAME Bash call, chained with &&; never write the real ~/.claude.json, ~/.claude, ~/.claude-discord or ~/.local/bin; run hand-run hooks/tools with env -u DISCORD_STATE_DIR.

- [x] **A real SessionStart hook's ancestry, lmd42 (Claude Code 2.1.296), foreground** (`claude -p` in a sandbox HOME; the hook fires before the login check). Nearest first:
  `/bin/bash <hook>` < `/bin/sh -c <hook>` < `claude -p hi --settings ...` < (the caller's shells) < `.../claude/versions/2.1.296 --bg-spare ...` < `--bg-pty-host` < `claude daemon run`.
- [x] **lmd42, `--bg`:** `/bin/bash <hook>` < `/bin/sh -c <hook>` < `.../claude/versions/2.1.296 --session-id ... --name anc-probe` < `claude bg-pty-host --bg-pty-host ...` < `.../versions/2.1.296 daemon run --origin transient`.
- [x] **wmac (macOS 15.7.4, 2.1.296), foreground:** `/bin/bash <hook>` < `/Users/j.lee8/.local/bin/claude -p hi ...` (no `sh -c` in between).
- [x] **wmac, `--bg`:** `/bin/bash <hook>` < `.../claude/versions/2.1.296 --session-id ...` < `.../versions/2.1.296 --bg-pty-host ...` < `.../versions/2.1.296 daemon run ...`.
  So the session is the nearest ancestor within **two** levels whose argv[0] is `claude`, `.../claude` or under `.../claude/versions/`, and whose argv[1] is not `daemon` (the `--bg-pty-host` above a `--bg` session is never reached). A third level would reach the shell of whoever ran a hook by hand, which inside a Claude session is that session's own claude.
- [x] **perl flock on wmac, `/bin/bash` 3.2.57:** the lock taken by perl, `dup2`'d to fd 9 and `exec`'d into bash is held while that bash lives; after `kill -9` of it, with its child started with `9>&-` still alive, a new `LOCK_NB` attempt wins (`0 yes`).
- [x] **`ps` on wmac:** `ps -o lstart= -p` prints `Sun Oct 11 19:13:37 2026` (trailing spaces; collapse whitespace); `ps -o ppid= -o args= -p` prints `<ppid> <argv>`; `ps -axww -o pid=,command=` lists a tty-less bun-shaped process started from ssh, and `ps -axEww -o pid=,command= -p <pid>` shows its ` DISCORD_STATE_DIR=<dir>` token.
- [x] **The whole monitor under `/bin/bash` 3.2 on wmac** (stub ssh, curl and shim, unwritable TMPDIR): one start for two `--ensure` calls, a stale finding posted once with English labels under `ALERT_LANG='en'`, ssh 255 retried with `ControlPath=none`, exit 3 s after the holder died, no holder record left, nothing in TMPDIR, token on stdin only; `on-prompt` kept 200 `delivered` lines.

---
### Task 2: `delivered` in on-prompt; `stale` becomes a delivery check

**Files:**
- Modify: `hooks/turn/on-prompt` (after the `last-message-id` write, inside the `if [ -n "$session_id" ] ...` block)
- Modify: `bin/claude-discord` (health: the comment block above the primary signal, `addressed_ids`, the per-bot loop after `is_id "$last_seen" || last_seen=0`, the thread filter)
- Test: `test-claude-discord.sh` (two new blocks)

**Interfaces:**
- Produces: `<bot>/delivered`, one Discord message id per line, newest last, at most 200 lines, written only by `on-prompt` (through a rename once full). In health: `$floor` (the lower bound for candidate ids) and `$delivered` (the ids, newline-separated); `addressed_ids` drops ids listed in `$delivered`.
- Consumes: nothing new.

HARD HOME RULE (repeat verbatim in this task's dispatch prompt): any probe outside the test suite sets a literal sandbox HOME in the SAME Bash call, chained with &&; never write the real ~/.claude.json, ~/.claude, ~/.claude-discord or ~/.local/bin; run hand-run hooks/tools with env -u DISCORD_STATE_DIR.

- [ ] **Step 1: Write the failing tests.** Insert after the line `echo "ok: a second tag in one prompt is body text: only the leading tag is recorded and reacted to"`:

```bash
# delivered: on-prompt appends every message id the session is handed, newest last, the last 200 kept. health's stale
# check reads it: a message listed there reached the session.
seq 1 250 > "$DSD/delivered"
DISCORD_STATE_DIR="$DSD" bash "$H/on-prompt" <<<'{"session_id":"sDel","prompt":"<channel source=\"plugin:discord:discord\" chat_id=\"1\" message_id=\"4242\" user=\"u\" user_id=\"9\" ts=\"t\">\nhi\n</channel>"}' >/dev/null
[ "$(wc -l < "$DSD/delivered" | tr -d ' ')" = 200 ] && [ "$(tail -n 1 "$DSD/delivered")" = 4242 ] && [ "$(head -n 1 "$DSD/delivered")" = 52 ] ||
  { echo "FAIL: on-prompt must append the delivered id and keep the last 200: $(wc -l < "$DSD/delivered") lines, last $(tail -n 1 "$DSD/delivered")"; exit 1; }
rm -rf "$DSD/turns/sDel" "$DSD/turns/sDel.pending" "$DSD/turns/sDel.primed" "$DSD/delivered"
echo "ok: on-prompt appends each delivered message id to delivered, newest last, 200 kept"
```

Insert after the line that begins `echo "ok: health reads a thread only when its last_message_id`:

```bash
# stale is a delivery check (<bot>/delivered, written by on-prompt). A message the session was handed is not stale
# however long its answer takes (a mention that asks nothing gets no reply by rule); one never handed to it is stale
# even while the bot answers in another thread, where last-message-id has already moved past it.
# The delivered case is dong-dev-bot's (lmd79, 2026-10-09): message 1557522558478454878 reached session 4cde6d3a 0.35 s
# after Discord's timestamp and was answered 88 min later; the old check called it stale at 62 min.
DONG=1557522558478454878
printf '%s\n%s\n' "$(( DONG - (1000 << 22) ))" "$DONG" > "$SD/delivered"; echo 0 > "$SD/last-message-id"
queue "200 [{\"id\":\"$DONG\",\"author\":{\"id\":\"111\"},\"mentions\":[{\"id\":\"777\"}]}]" '200 {"threads":[]}'
out=$(bash "$S" health --json 2>/dev/null) || :
[ "$(verdict_of sbot "$out")" = ok ] || { echo "FAIL: a delivered message left unanswered (dong-dev-bot's 62-min case) must read ok: $out"; exit 1; }
ID_B=$(snowflake_for 20)   # answered in another thread after the stuck message arrived
printf '%s\n%s\n' "$ID_SEEN" "$ID_B" > "$SD/delivered"; echo "$ID_B" > "$SD/last-message-id"
queue "200 $NONE" "200 {\"threads\":[{\"id\":\"34\",\"parent_id\":\"900\",\"last_message_id\":\"$ID_STALE\"}]}" "200 $MENTION"
out=$(bash "$S" health --json 2>/dev/null) || :
[ "$(verdict_of sbot "$out")" = stale ] || { echo "FAIL: a message never delivered, in a thread older than the last one answered elsewhere, must be stale: $out"; exit 1; }
rm -f "$SD/delivered"; echo "$ID_SEEN" > "$SD/last-message-id"
echo "ok: stale needs a message never delivered to the session: delivered-and-unanswered is ok (dong-dev-bot's 62-min case too), undelivered in one thread while another is answered is stale"
```

- [ ] **Step 2: Run them**

Run: `./test-claude-discord.sh ./bin/claude-discord 2>&1 | grep -m1 -E 'FAIL|ok: on-prompt appends'`
Expected: `FAIL: on-prompt must append the delivered id and keep the last 200: 250 lines, last 250`.

- [ ] **Step 3: Implement.** In `hooks/turn/on-prompt`, after the line `  printf '%s\n' "$message_id" > "$DISCORD_STATE_DIR/last-message-id" 2>/dev/null || :` add:

```bash
  # delivered: every message id this session was handed, newest last, the
  # last 200 kept. health reads it: a message listed here reached the session,
  # so it is not `stale` however long the answer takes (or if none is owed).
  # No fork below 200 lines (an append); from there one mv per message, a
  # rename so health never reads half a file.
  dl=$DISCORD_STATE_DIR/delivered n=0 keep=""
  while IFS= read -r l; do n=$((n + 1)); keep="$keep$l"$'\n'; done 2>/dev/null < "$dl"
  if [ "$n" -lt 200 ]; then
    printf '%s\n' "$message_id" >> "$dl" 2>/dev/null || :
  else
    while [ "$n" -gt 199 ]; do keep=${keep#*$'\n'}; n=$((n - 1)); done
    printf '%s%s\n' "$keep" "$message_id" > "$dl.$$" 2>/dev/null && mv -f "$dl.$$" "$dl" 2>/dev/null || rm -f "$dl.$$" 2>/dev/null
  fi
```

In `bin/claude-discord`, in the comment above `if [ "${1:-}" = health ]; then`, replace

```bash
#   a message that addressed this bot, newer than the last one its hooks
#   recorded ($dir/last-message-id, written by turn/on-prompt), and older
#   than $stale_min minutes
```

with

```bash
#   a message that addressed this bot, never handed to its session (its id
#   is not in $dir/delivered, written by turn/on-prompt; with no such file,
#   newer than $dir/last-message-id), and older than $stale_min minutes
```

Replace the head of `addressed_ids`:

```bash
  addressed_ids() {  # $1 = messages JSON; ids newer than $last_seen, oldest first
    printf '%s' "$1" | jq -r --arg me "$me" --argjson allow "$allow" \
      --argjson mention "$mention" --arg seen "$last_seen" '
```

with

```bash
  addressed_ids() {  # $1 = messages JSON; ids newer than $floor and not in $delivered, oldest first
    printf '%s' "$1" | jq -r --arg me "$me" --argjson allow "$allow" \
      --argjson mention "$mention" --arg seen "$floor" --arg delivered "$delivered" '
      ($delivered | split("\n")) as $dl |
```

and its last filter

```bash
          | select((. | length) > ($seen | length)
                   or ((. | length) == ($seen | length) and . > $seen)) ]
```

with

```bash
          | select((. | length) > ($seen | length)
                   or ((. | length) == ($seen | length) and . > $seen))
          | select(. as $i | ($dl | index($i)) == null) ]
```

In the per-bot loop, after `    is_id "$last_seen" || last_seen=0` add:

```bash
    # What "unanswered" is measured against. With a delivered log (on-prompt
    # appends every message id the session was handed, 200 kept) a message is
    # a candidate when it is newer than the OLDEST id in that log and is not
    # in it: it never reached the session. last-message-id cannot be the
    # bound there, since it moves past a message stuck in one thread as soon
    # as the bot answers in another. Without the log (a bot whose hooks have
    # not run since this release) the bound stays last-message-id, as before.
    floor=$last_seen delivered=""
    if [ -s "$d/delivered" ]; then
      floor=""
      while IFS= read -r id || [ -n "$id" ]; do
        is_id "$id" || continue
        delivered="$delivered$id"$'\n'
        if [ -z "$floor" ] || id_newer "$floor" "$id"; then floor=$id; fi
      done < "$d/delivered"
      [ -n "$floor" ] || floor=$last_seen
    fi
```

In the thread filter replace `id_newer "$tlast" "$last_seen" && printf '%s\n' "$tid"` with `id_newer "$tlast" "$floor" && printf '%s\n' "$tid"`.

- [ ] **Step 4: Run the suite**

Run: `./test-claude-discord.sh ./bin/claude-discord 2>&1 | tail -1`
Expected: `ALL PASS`, with `ok: on-prompt appends each delivered message id ...` and `ok: stale needs a message never delivered to the session ...` in the output.

- [ ] **Step 5: Mutation check** (run while writing this plan). Each revert alone makes the suite fail with:
  - on-prompt without the appended id: `FAIL: on-prompt must append the delivered id and keep the last 200: 199 lines, last 250`
  - `if [ "$n" -lt 200 ]` made `if true` (no cap): `FAIL: ... 251 lines, last 4242`
  - the `select(. as $i | ($dl | index($i)) == null)` line removed: `FAIL: a delivered message left unanswered (dong-dev-bot's 62-min case) must read ok`
  - `$floor` left at `$last_seen`: `FAIL: a message never delivered, in a thread older than the last one answered elsewhere, must be stale`

- [ ] **Step 6: Commit**

```bash
git commit -m "stale is a delivery check: on-prompt keeps the last 200 delivered ids in <bot>/delivered; health counts only messages never handed to the session (a stuck thread still alerts, dong's 62-min case reads ok)" -m "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>" -- hooks/turn/on-prompt bin/claude-discord test-claude-discord.sh
```

---
### Task 3: macOS server count through `ps -ax`

**Files:**
- Modify: `bin/claude-discord` (health: the `server_cands` block and the head of `count_servers`)
- Test: `test-claude-discord.sh` (one new block)

**Interfaces:**
- Produces: `count_servers` prints a number on macOS too, `unknown` only when `ps -axww` itself fails. `$proc` (`${CLAUDE_DISCORD_PROC:-/proc}`) replaces the literal `/proc` in health.
- Consumes: Task 2's block position (the new test goes after Task 2's `ok:` line).

HARD HOME RULE (repeat verbatim in this task's dispatch prompt): any probe outside the test suite sets a literal sandbox HOME in the SAME Bash call, chained with &&; never write the real ~/.claude.json, ~/.claude, ~/.claude-discord or ~/.local/bin; run hand-run hooks/tools with env -u DISCORD_STATE_DIR.

- [ ] **Step 1: Write the failing test.** Insert after the line that begins `echo "ok: stale needs a message never delivered to the session`:

```bash
# macOS has no /proc: the servers are counted from ps, argv first (ps -axww: bun, a .../discord/ argument, last word
# start), then the environment of only those pids (ps -Eww -p). A shell of the session carries the same
# DISCORD_STATE_DIR and must not count; neither may sbot2's server. CLAUDE_DISCORD_PROC points health at a missing
# /proc; the ps stub sits on PATH for these runs only.
mkdir -p "$HOME/psbin"
cat > "$HOME/psbin/ps" <<'STUB'
#!/bin/bash
case "$*" in
  "-axww -o pid=,command=") [ ! -f "$HOME/ps.fail" ] || exit 1; cat "$HOME/ps.argv";;
  "-Eww -o pid=,command= -p "*) printf '%s\n' "$*" >> "$HOME/ps.calls"; cat "$HOME/ps.env";;
  *) exec /bin/ps "$@";;
esac
STUB
chmod +x "$HOME/psbin/ps"
BUNS='/opt/bun/bin/bun run --cwd /Users/u/.claude/plugins/cache/claude-plugins-official/discord/0.0.4 --shell=bun --silent start'
printf '  101 %s\n  102 %s\n  103 /bin/zsh -c sleep 1\n  104 %s\n' "$BUNS" "$BUNS" "$BUNS" > "$HOME/ps.argv"
printf '  101 %s TERM=x DISCORD_STATE_DIR=%s HOME=/Users/u\n  102 %s DISCORD_STATE_DIR=%s2\n  104 %s PATH=/bin DISCORD_STATE_DIR=%s\n' \
  "$BUNS" "$SD" "$BUNS" "$SD" "$BUNS" "$SD" > "$HOME/ps.env"
rm -f "$HOME/ps.calls"
macrun() { queue "200 $NONE" '200 {"threads":[]}'; PATH="$HOME/psbin:$PATH" CLAUDE_DISCORD_PROC=/nonexistent bash "$S" health --json 2>/dev/null || :; }
out=$(macrun)
[ "$(verdict_of sbot "$out")" = duplicate ] && [ "$(field_of sbot servers "$out")" = 2 ] || { echo "FAIL: two bun servers carrying sbot's DISCORD_STATE_DIR must read as a duplicate: $out"; exit 1; }
[ "$(<"$HOME/ps.calls")" = "-Eww -o pid=,command= -p 101,102,104" ] || { echo "FAIL: only the bun servers' environment may be read: $(<"$HOME/ps.calls")"; exit 1; }
: > "$HOME/ps.fail"
out=$(macrun)
[ "$(field_of sbot servers "$out")" = unknown ] && [ "$(verdict_of sbot "$out")" = ok ] || { echo "FAIL: a ps that fails is unknown, never down: $out"; exit 1; }
rm -rf "$HOME/psbin" "$HOME/ps.argv" "$HOME/ps.env" "$HOME/ps.calls" "$HOME/ps.fail"
echo "ok: without /proc the servers are counted from ps -axww argv first, then ps -Eww for those pids only; another bot's server and a shell with the same state dir do not count; a failing ps is unknown"
```

- [ ] **Step 2: Run it**

Run: `./test-claude-discord.sh ./bin/claude-discord 2>&1 | grep -m1 -E 'FAIL|ok: without /proc'`
Expected: `FAIL: two bun servers carrying sbot's DISCORD_STATE_DIR must read as a duplicate: [` (servers read `unknown`).

- [ ] **Step 3: Implement.** In health replace

```bash
  server_cands=""
  if [ -d /proc ]; then
    if command -v pgrep >/dev/null 2>&1 && server_cands=$(pgrep -x bun 2>/dev/null); then
      server_cands=$(printf '/proc/%s/cmdline ' $server_cands)
    else
      server_cands=$(printf '%s ' /proc/[0-9]*/cmdline)
    fi
  fi
```

with

```bash
  server_cands="" mac_env="" mac_pids="" mac_ok=no
  proc=${CLAUDE_DISCORD_PROC:-/proc}   # the suite points this at a missing path to exercise the macOS count on Linux
  if [ ! -d "$proc" ]; then
    # macOS: argv first here too. -ax, because without it ps lists only
    # processes with a terminal and a --bg server has none (measured on wmac,
    # 2026-10-10: 0 of 1). The argv test on the one-line command: the first
    # word is bun, the last is start, a word sits under .../discord/. Then one
    # more ps with -E for those pids: each line is "<pid> <argv> <environment>".
    mac_ok=no mac_pids=""
    if mac_ps=$(ps -axww -o pid=,command= 2>/dev/null) && [ -n "$mac_ps" ]; then
      mac_ok=yes
      mac_pids=$(printf '%s\n' "$mac_ps" | awk '{ a0 = $2; sub(/.*\//, "", a0) } a0 == "bun" && $NF == "start" && /\/discord\// { printf "%s%s", (n++ ? "," : ""), $1 }') || mac_pids=""
      [ -z "$mac_pids" ] || mac_env=$(ps -Eww -o pid=,command= -p "$mac_pids" 2>/dev/null) || mac_ok=no
    fi
  fi
  if [ -d "$proc" ]; then
    if command -v pgrep >/dev/null 2>&1 && server_cands=$(pgrep -x bun 2>/dev/null); then
      server_cands=$(printf "$proc/%s/cmdline " $server_cands)
    else
      server_cands=$(printf '%s ' "$proc"/[0-9]*/cmdline)
    fi
  fi
```

In `count_servers` replace

```bash
    local n=0 c pid args a hit
    [ -d /proc ] || { printf 'unknown'; return 0; }
```

with

```bash
    local n=0 c pid args a hit l
    if [ ! -d "$proc" ]; then
      [ "$mac_ok" = yes ] || { printf 'unknown'; return 0; }   # ps itself failed: cannot tell, never zero
      # The token after the argv text: " DISCORD_STATE_DIR=<dir>" ending the
      # line or followed by a space, so "hbot" never counts "hbot2"'s server.
      # shortcut: a state dir with a space in its path is not counted here; quote-aware parsing if a Mac project ever has one.
      local IFS=$'\n'; set -f   # one ps line at a time (a subshell: neither leaks), with no here-string (bash 3.2 writes those to TMPDIR)
      for l in $mac_env; do
        case "$l " in *" DISCORD_STATE_DIR=$1 "*) n=$((n + 1));; esac
      done
      printf '%s' "$n"; return 0
    fi
```

and in the same function replace `pid=${c#/proc/}; pid=${pid%/cmdline}` with `pid=${c#"$proc"/}; pid=${pid%/cmdline}`, and `"/proc/$pid/environ"` with `"$proc/$pid/environ"`.

- [ ] **Step 4: Run the suite.** Expected: `ALL PASS` with `ok: without /proc the servers are counted from ps -axww argv first ...`.

- [ ] **Step 5: Mutation check.** `[ "$mac_ok" = yes ] || { printf 'unknown'; return 0; }` replaced by `printf 'unknown'; return 0` fails with `FAIL: two bun servers carrying sbot's DISCORD_STATE_DIR must read as a duplicate`.

- [ ] **Step 6: Commit**

```bash
git commit -m "health on macOS: plugin servers counted from ps -axww argv first, then ps -Eww for those pids (down and duplicate visible on the Macs)" -m "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>" -- bin/claude-discord test-claude-discord.sh
```

---
### Task 4: `health --all --json --patch`, `records/projects`, `owner_id`; 1.10.0

**Files:**
- Modify: `bin/claude-discord` (`record_project` after `prune_installs`; the call at the end of setup and in health; health's argument loop and the `--all` branch; `--nolog` around the `health.log`/`logger` lines; `owner_id` in the JSON; the header usage lines)
- Modify: `.claude-plugin/plugin.json` (`"version": "1.10.0"`: `blind` in Task 7 means "older than `health --all`")
- Test: `test-claude-discord.sh` (one new block)

**Interfaces:**
- Produces: `claude-discord health --all [--json] [--patch]`. With `--json` it prints one document and exits 0:
  `{"host": "<uname -n, short>", "version": "<x.y.z> (<sha>)", "home": "$HOME", "patch": null | {"rc": N, "output": "<patch's stderr>"}, "projects": [{"project": "<physical root>", "bots": [<health --json objects, each with "owner_id">]}]}`.
  Without `--json`: each project's lines under `== <project>`, exit 1 on any finding. `--patch` without `--all` is refused (exit 2). `~/.claude-discord/records/projects`: one physical project root per line, added by `setup` and by every `health` run in a project, pruned by `--all` when `<root>/.claude/discord-agents` is gone. Internal flag `--nolog`.
- Consumes: Task 2 and 3 (the per-project run).

HARD HOME RULE (repeat verbatim in this task's dispatch prompt): any probe outside the test suite sets a literal sandbox HOME in the SAME Bash call, chained with &&; never write the real ~/.claude.json, ~/.claude, ~/.claude-discord or ~/.local/bin; run hand-run hooks/tools with env -u DISCORD_STATE_DIR.

- [ ] **Step 1: Write the failing test.** Insert after the line that begins `echo "ok: health installs no timer`:

```bash
# health --all: every project in records/projects, one document (host, version, home, patch, projects[].bots[] with
# owner_id), exit 0 whenever it printed it (over ssh a non-zero exit means "no answer"). --patch runs the patch step
# first and carries its rc and stderr. A project whose .claude/discord-agents is gone is pruned. Neither health.log nor
# logger is written at a monitor's cadence; a health run by hand keeps both.
PF="$HOME/.claude-discord/records/projects"
# project-upper was set up above and never ran health: only setup can have recorded it.
grep -qxF "$(cd "$PU" && pwd -P)" "$PF" || { echo "FAIL: setup must record its project in records/projects: $(cat "$PF" 2>&1)"; exit 1; }
mv "$PF" "$PF.suite"
# The project --all walks has a space in its path (a copy of single-project); the gone one too.
SPS="$HOME/single project"; cp -a "$SP" "$SPS"; SDS="$SPS/.claude/discord-agents/sbot"
printf '%s\n' "$HOME/gone project" > "$PF"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$HOME/logger.calls"\n' > "$HOME/bin/logger"; chmod +x "$HOME/bin/logger"
rm -f "$HOME/logger.calls" "$SDS/health.log"
(cd "$SPS" && queue "200 $NONE" '200 {"threads":[]}' && bash "$S" health >/dev/null 2>&1) || :
grep -qxF "$(cd "$SPS" && pwd -P)" "$PF" || { echo "FAIL: a health run in a project must record it: $(<"$PF")"; exit 1; }
[ -s "$SDS/health.log" ] && [ -s "$HOME/logger.calls" ] || { echo "FAIL: control: a health run by hand keeps health.log and the journal line"; exit 1; }
rm -f "$HOME/logger.calls" "$SDS/health.log"
PCACHE=$HOME/.claude/plugins/cache/claude-plugins-official/discord
mkdir -p "$PCACHE/0.0.98"; printf 'nothing to patch here\n' > "$PCACHE/0.0.98/server.ts"
queue "200 $MENTION" '200 {"threads":[]}'
rc=0; doc=$(cd "$HOME" && bash "$S" health --all --json --patch 2>/dev/null) || rc=$?
[ "$rc" = 0 ] || { echo "FAIL: health --all --json must exit 0 when it printed the document, a finding or not (rc=$rc): $doc"; exit 1; }
jq -e --arg home "$HOME" --arg p "$(cd "$SPS" && pwd -P)" '
  (.host | length > 0) and (.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+ \\(")) and .home == $home
  and .patch.rc == 1 and (.patch.output | test("0.0.98/server.ts: bot-authors no longer matches"))
  and (.projects | length) == 1 and .projects[0].project == $p
  and .projects[0].bots[0].bot == "sbot" and .projects[0].bots[0].verdict == "stale" and .projects[0].bots[0].owner_id == "111"' <<<"$doc" >/dev/null ||
  { echo "FAIL: health --all --json --patch: wrong document: $doc"; exit 1; }
[ ! -e "$SDS/health.log" ] && [ ! -e "$HOME/logger.calls" ] || { echo "FAIL: health --all must write no health.log line and call no logger"; exit 1; }
grep -qF 'gone project' "$PF" && { echo "FAIL: --all must prune a project whose discord-agents is gone: $(<"$PF")"; exit 1; }
rm -rf "$PCACHE/0.0.98" "$HOME/bin/logger" "$HOME/logger.calls" "$SPS"; mv "$PF.suite" "$PF"
echo "ok: health --all --json --patch prints one document (host, version, home, the patch step's rc and stderr, each project's bots with owner_id; a project path with a space), exits 0 with a finding, prunes a gone project, and writes no health.log or journal line; setup and a health run record their project"
```

- [ ] **Step 2: Run it**

Run: `./test-claude-discord.sh ./bin/claude-discord 2>&1 | grep -m1 -E 'FAIL|ok: health --all'`
Expected: `FAIL: setup must record its project in records/projects: cat: ...: No such file or directory`.

- [ ] **Step 3: Implement.** After the `prune_installs` function add:

```bash
# record_project: this project's root (physical) into records/projects, once.
# `health --all` walks that list; setup and a health run in a project add to it.
record_project() {
  local f=$helpers/records/projects p l
  p=$(pwd -P) || return 0
  # Already listed (every health run after the first): found with no fork.
  if [ -f "$f" ]; then while IFS= read -r l || [ -n "$l" ]; do [ "$l" != "$p" ] || return 0; done < "$f"; fi
  mkdir -p "$helpers/records" 2>/dev/null && printf '%s\n' "$p" >> "$f" 2>/dev/null || :
}
```

In setup, after the `ensure_hooks_symlink` line that follows the mode block (just before `if [ "${3:-}" = --mode ]; then echo "claude-discord: $root/$name/mode set to $mode"`), add `  record_project`.

In health replace the argument loop

```bash
  as_json=no timer=""
  for a in "$@"; do
    case $a in
      --json) as_json=yes;;
      --uninstall-timer) timer=uninstall;;
      *) echo "usage: claude-discord health [--json] | health --uninstall-timer" >&2; exit 2;;
    esac
  done
```

with

```bash
  as_json=no timer="" all=no do_patch=no nolog=no
  for a in "$@"; do
    case $a in
      --json) as_json=yes;;
      --all) all=yes;;
      --patch) do_patch=yes;;
      --nolog) nolog=yes;;   # internal: --all's per-project runs write no health.log line and no journal line
      --uninstall-timer) timer=uninstall;;
      *) echo "usage: claude-discord health [--json] | health --all [--json] [--patch] | health --uninstall-timer" >&2; exit 2;;
    esac
  done
  [ "$do_patch" = no ] || [ "$all" = yes ] || { echo "claude-discord: health --patch needs --all" >&2; exit 2; }
  # --all: every project in ~/.claude-discord/records/projects, one document.
  # This is the one command a monitor pass runs per host (locally or over
  # ssh), so with --json it exits 0 whenever it printed the document: over
  # ssh a non-zero status means "no answer from that host", never "a bot has
  # a finding". Each project is judged by this same script run there with
  # --nolog; a project whose .claude/discord-agents is gone is pruned.
  if [ "$all" = yes ]; then
    command -v jq >/dev/null 2>&1 || { echo "claude-discord: health needs jq" >&2; exit 1; }
    pf=$helpers/records/projects keep="" docs="" prc=null pout="" any=0
    if [ "$do_patch" = yes ]; then
      prc=0; pout=$("$self_path" patch 2>&1 >/dev/null) || prc=$?   # stderr only: file and patch name
    fi
    while IFS= read -r p || [ -n "$p" ]; do
      [ -n "$p" ] && [ -d "$p/.claude/discord-agents" ] || continue
      keep="$keep$p"$'\n'
      if [ "$as_json" = yes ]; then
        one=$(cd "$p" 2>/dev/null && "$self_path" health --json --nolog 2>/dev/null) || :
        # Two plain assignments: bash 3.2 misreads a quoted jq program inside "$( )" inside double quotes.
        one=$(printf '%s' "${one:-[]}" | jq -c --arg p "$p" '{project: $p, bots: (if type == "array" then . else [] end)}' 2>/dev/null) || one=$(jq -nc --arg p "$p" '{project: $p, bots: []}')
        docs=$docs$one$'\n'
      else
        echo "== $p"
        (cd "$p" 2>/dev/null && "$self_path" health --nolog) || any=1
      fi
    done < <(cat "$pf" 2>/dev/null)
    if [ -f "$pf" ] && printf '%s' "$keep" > "$pf.tmp.$$" 2>/dev/null; then cmp -s "$pf.tmp.$$" "$pf" || cat "$pf.tmp.$$" > "$pf" 2>/dev/null || :; fi
    rm -f "$pf.tmp.$$"
    [ "$as_json" = yes ] || exit "$any"
    h=$(uname -n); h=${h%%.*}
    printf '%s' "$docs" | jq -s --arg host "$h" --arg home "$HOME" --argjson prc "$prc" --arg pout "$pout" \
      --arg ver "$(plugin_version "$self_root") ($(git -C "$self_root" rev-parse --short HEAD 2>/dev/null || echo nogit))" \
      '{host: $host, version: $ver, home: $home, patch: (if $prc == null then null else {rc: $prc, output: $pout} end), projects: .}'
    exit 0
  fi
```

After `  [ -d "$root" ] || { echo "claude-discord: no bot set up in $root" >&2; exit 1; }` add `  record_project`.

Replace

```bash
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$line" >> "$d/health.log" 2>/dev/null || :
    # journal too, because the log above lives in the state dir of a bot
    # whose whole problem may be that nobody is looking at it.
    ! command -v logger >/dev/null 2>&1 || logger -t claude-discord-health -- "$line" 2>/dev/null || :
```

with

```bash
    # Not under --all (--nolog): at a monitor's 5-minute cadence both would grow without bound.
    if [ "$nolog" = no ]; then
      printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$line" >> "$d/health.log" 2>/dev/null || :
      # journal too, because the log above lives in the state dir of a bot
      # whose whole problem may be that nobody is looking at it.
      ! command -v logger >/dev/null 2>&1 || logger -t claude-discord-health -- "$line" 2>/dev/null || :
    fi
```

In the final jq: add `--arg owner "${DISCORD_USER_ID:-}"` after `--argjson show "$(...)"`, and replace `trusted: .[$i+9] } ]` with `trusted: .[$i+9], owner_id: $owner } ]`.

In the header usage, after the three `health [--json]` lines add

```bash
#   claude-discord health --all [--json] [--patch]
#                                        every project recorded on this machine,
#                                        one document; --patch runs `patch`
#                                        first (what a monitor pass runs)
```

and in health's own comment block, after `#   claude-discord health [--json]`, add `#   claude-discord health --all [--json] [--patch]`. Set `"version": "1.10.0"` in `.claude-plugin/plugin.json`.

- [ ] **Step 4: Run the suite.** Expected: `ALL PASS` with `ok: health --all --json --patch prints one document ...`.

- [ ] **Step 5: Mutation check.** Each revert alone fails with:
  - `exit 0` after the document replaced by `exit 1`: `FAIL: health --all --json must exit 0 when it printed the document, a finding or not (rc=1)`
  - `if [ "$nolog" = no ]` replaced by `if true`: `FAIL: health --all must write no health.log line and call no logger`
  - the `record_project` call in health removed: `FAIL: a health run in a project must record it`
  - the `record_project` call in setup removed: `FAIL: setup must record its project in records/projects`
  - `keep=` taken before the `.claude/discord-agents` test (no prune): `FAIL: --all must prune a project whose discord-agents is gone`
  - `owner_id: $owner` removed, or `--patch` not running `patch`: `FAIL: health --all --json --patch: wrong document`
  - `cd "$p"` unquoted in the `--all` loop: `FAIL: health --all --json --patch: wrong document` (the walked project has a space)

- [ ] **Step 6: Commit**

```bash
git commit -m "1.10.0: health --all [--json] [--patch]: every recorded project in one document (owner_id per bot, the patch step's rc and stderr), exit 0 when printed; records/projects written by setup and health, pruned by --all; no health.log or journal line under --all" -m "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>" -- bin/claude-discord .claude-plugin/plugin.json test-claude-discord.sh
```

---
### Task 5: setup writes the hosts ledger (dev-manager only)

**Files:**
- Modify: `bin/claude-discord` (`write_hosts` before `parse_install_flags`; called after the peers question; `rm -f <bot>/hosts` for every other mode; `monitor` and `tui` reserved as bot names)
- Test: `test-claude-discord.sh` (the start of the ledger and monitor section, before `# A machine with the old install`)

**Interfaces:**
- Produces: `<project>/.claude/discord-agents/<bot>/hosts`: a `#` header line, `local[ KEY=VALUE...]`, then `<host>[ laptop][ KEY=VALUE...]` per host. The suite fixtures later tasks use: the ssh stub `$HOME/bin/ssh` (per host `$HOME/mon/<host>.{out,rc,rc2,sleep}`, argv to `$HOME/ssh.log`), `MON`, `MP` (`$HOME/monproj`), `MR`, the manager bot `mgr` (token `tokMgrUnique`, owner `111`), and the line `cd "$P"   # back to the main project after the ledger and monitor cases` that ends the section.
- Consumes: Task 4's `record_project` (setup still calls it after this).

HARD HOME RULE (repeat verbatim in this task's dispatch prompt): any probe outside the test suite sets a literal sandbox HOME in the SAME Bash call, chained with &&; never write the real ~/.claude.json, ~/.claude, ~/.claude-discord or ~/.local/bin; run hand-run hooks/tools with env -u DISCORD_STATE_DIR.

- [ ] **Step 1: Write the failing test.** Insert immediately before the line `# A machine with the old install: setup replaces what install.sh put under`:

```bash
# --- backend monitor ------------------------------------------------------
# ssh, stubbed for setup's host probe and the monitor's passes: argv to ssh.log; per host, $HOME/mon/<host>.out is
# printed, .rc is the exit status (.rc2 instead on the ControlPath=none retry), .sleep delays it; a byte left on
# stdin is reported as "ATE" (a probe must never eat setup's piped answers).
MON="$HOME/mon"; mkdir -p "$MON"
cat > "$HOME/bin/ssh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$HOME/ssh.log"
IFS= read -r -t 0.05 l && printf 'ATE %s\n' "$l" >> "$HOME/ssh.log"
host="" none=""
for a in "$@"; do [ "$a" != ControlPath=none ] || none=1; done
while [ $# -gt 0 ]; do case $1 in -o) shift 2;; *) host=$1; break;; esac; done
d=$HOME/mon
if [ -f "$d/$host.sleep" ]; then echo $$ > "$d/$host.pid"; /bin/sleep "$(<"$d/$host.sleep")"; fi
rc=0; [ ! -f "$d/$host.rc" ] || rc=$(<"$d/$host.rc")
[ -z "$none" ] || [ ! -f "$d/$host.rc2" ] || rc=$(<"$d/$host.rc2")
[ "$rc" != 0 ] || cat "$d/$host.out" 2>/dev/null
exit "$rc"
STUB
chmod +x "$HOME/bin/ssh"; rm -f "$HOME/ssh.log"

# setup asks for the ledger in dev-manager mode only: local always, each new host probed once (stdin left alone), a
# Darwin host with a battery marked laptop, a host that is not a plain ssh name skipped, an empty answer keeps the
# list (and the owner's hand edits), and leaving dev-manager removes the ledger.
MP="$HOME/monproj"; mkdir -p "$MP"; cd "$MP"; MR="$MP/.claude/discord-agents"
jq --arg p "$(pwd -P)" '.projects[$p].hasTrustDialogAccepted = true' "$HOME/.claude.json" > "$HOME/.claude.json.t" && mv "$HOME/.claude.json.t" "$HOME/.claude.json"
printf 'Linux\nclaude-discord 1.10.0 (abc1234)\n' > "$MON/h1.out"
printf 'Darwin\nbattery\nclaude-discord 1.10.0 (abc1234)\n' > "$MON/lap.out"
out=$(printf '\n900\n111\n\ntokMgrUnique\nn\ndev-manager\n\nh1, lap,-oProxyCommand=x\nEXTRA\n' | bash "$S" setup mgr --scope project 2>&1)
[ "$(<"$MR/mgr/hosts")" = "$(printf '# ssh host names this manager checks; "local" is this machine (no ssh)\nlocal\nh1\nlap laptop')" ] ||
  { echo "FAIL: setup must write the ledger: local, h1, lap marked laptop: $(cat "$MR/mgr/hosts" 2>&1) / $out"; exit 1; }
grep -q 'h1: claude-discord 1.10.0' <<<"$out" && grep -q "skipping host '-oProxyCommand=x'" <<<"$out" || { echo "FAIL: setup must print each probe's answer and skip a host that is not a plain name: $out"; exit 1; }
! grep -q '^ATE' "$HOME/ssh.log" && [ "$(grep -c BatchMode=yes "$HOME/ssh.log")" = 2 ] || { echo "FAIL: one probe per host, with stdin closed: $(<"$HOME/ssh.log")"; exit 1; }
printf '# mine\nlocal HTTPS_PROXY=http://127.0.0.1:8118\nh1 X=1\nlap laptop\n' > "$MR/mgr/hosts"
printf 'dev-manager\n\n\n' | bash "$S" setup mgr --mode >/dev/null 2>&1
[ "$(sed 1d "$MR/mgr/hosts")" = "$(printf 'local HTTPS_PROXY=http://127.0.0.1:8118\nh1 X=1\nlap laptop')" ] || { echo "FAIL: an empty answer keeps the ledger and its hand edits: $(<"$MR/mgr/hosts")"; exit 1; }
printf 'none\n' | bash "$S" setup mgr --mode >/dev/null 2>&1
[ ! -e "$MR/mgr/hosts" ] || { echo "FAIL: a bot that is not a dev-manager keeps no ledger"; exit 1; }
rm -f "$HOME/ssh.log" "$MON"/*
echo "ok: setup writes the hosts ledger in dev-manager mode only (local always, each new host probed with stdin closed, a Darwin laptop marked, a bad name skipped, an empty answer keeps hand edits, another mode removes it)"
cd "$P"   # back to the main project after the ledger and monitor cases
```

- [ ] **Step 2: Run it**

Run: `./test-claude-discord.sh ./bin/claude-discord 2>&1 | grep -m1 -E 'FAIL|ok: setup writes the hosts'`
Expected: `FAIL: setup must write the ledger: local, h1, lap marked laptop: cat: .../mgr/hosts: No such file or directory`.

- [ ] **Step 3: Implement.** Before the comment `# --scope and --method, anywhere and in the = form too, for setup and install;` add:

```bash
# write_hosts <bot dir>: the manager's host ledger (<bot dir>/hosts), which
# the backend monitor reads and which is also its on/off switch. One line per
# host: the ssh host name, an optional `laptop` word (its own unreachability
# is never posted: a closed lid is not an outage), then optional KEY=VALUE env
# for the remote command. `local` (this machine, no ssh) is always there. An
# empty answer keeps the current list; a host already listed keeps its line as
# the owner left it. Each new host is probed once, its answer printed, and
# written whatever the answer (a laptop may be asleep); a Darwin host with a
# battery is marked laptop.
write_hosts() {
  local f=$1/hosts ans h line out old="" new="" probe
  [ ! -f "$f" ] || old=$(cat "$f")
  read -rp "ssh hosts to check, comma-separated (this machine is always included): " ans || ans=""
  ans=${ans//[[:space:]]/}
  new="# ssh host names this manager checks; \"local\" is this machine (no ssh)"$'\n'
  line=$(printf '%s\n' "$old" | awk '$1 == "local"' | head -1)
  new="$new${line:-local}"$'\n'
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
        printf '%s\n' "$out" | grep -qx Darwin && printf '%s\n' "$out" | grep -qx battery && line="$h laptop"
      fi
      new="$new$line"$'\n'
    done
  fi
  printf '%s\n' "${new%$'\n'}" > "$f"
}
```

In setup, replace

```bash
    echo "Ask each peer's owner to add this bot's id to their allowFrom; both directions are needed."
  fi
```

with

```bash
    echo "Ask each peer's owner to add this bot's id to their allowFrom; both directions are needed."
    write_hosts "$root/$name"
  else
    # Only a manager posts to #bot-health-check: any other mode has no ledger, so no monitor.
    rm -f "$root/$name/hosts"
  fi
```

and in the reserved-name `case` replace `setup|install|update|patch|compat|refresh|health)` with `setup|install|update|patch|compat|refresh|health|monitor|tui)`.

- [ ] **Step 4: Run the suite.** Expected: `ALL PASS` with `ok: setup writes the hosts ledger in dev-manager mode only ...`. Existing dev-manager setups pipe no hosts line: `read` hits end of input, which keeps the list (`local` only), so they still pass.

- [ ] **Step 5: Mutation check.** Each revert alone fails with:
  - the `write_hosts` call removed: `FAIL: setup must write the ledger: local, h1, lap marked laptop: cat: ...: No such file or directory`
  - `</dev/null` dropped from the probe: `FAIL: one probe per host, with stdin closed`
  - `rm -f "$root/$name/hosts"` dropped: `FAIL: a bot that is not a dev-manager keeps no ledger`
  - the `laptop` marking dropped: `FAIL: setup must write the ledger: local, h1, lap marked laptop`

- [ ] **Step 6: Commit**

```bash
git commit -m "setup in dev-manager mode asks for the ssh hosts the monitor checks and writes <bot>/hosts (local always; each new host probed once with stdin closed; a Darwin host with a battery marked laptop); other modes keep no ledger; monitor and tui are reserved names" -m "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>" -- bin/claude-discord test-claude-discord.sh
```

---
### Task 6: the monitor: lock, holders, passes, exit (`monitor/monitor.sh`, no posting yet)

**Files:**
- Create: `monitor/monitor.sh` (the content below; Task 7 replaces it with the posting version)
- Modify: `bin/claude-discord` (the `monitor` verb, before `args=() name="" skip=0 ...`)
- Modify: `test-claude-discord.sh` (`bash -n`, the bash 4 lint and the no-heredoc check for `monitor/monitor.sh`; the lifecycle block and the section's cleanup)

**Interfaces:**
- Produces: `claude-discord monitor [--ensure] <bot> [--holder tui|session <pid>]`, run from the manager's project directory. It writes `holders/<kind>-<pid>` as `<pid> <start time> <kind>` when `--holder` is given, then returns at once; a detached child takes the lock (fd 9) within `CLAUDE_DISCORD_MONITOR_LOCK_WAIT` seconds or leaves. Files under `~/.claude-discord/records/monitor/<bot>/`: `lock`, `state.json` (`{"version": 1, "manager": "<bot>", "monitor": {"pid", "started", "holders": [{"kind", "pid"}], "last_pass", "next_pass", "pass_s", "stopped_at"}, "hosts": {"<host>": {"host", "name", "laptop", "reach", "verdict", "detail", "since", "since_s", "owner_id", "checked", "version", "patch"}}, "bots": {"<host>|<project>|<bot>": {"host", "name", "project", "bot", "home", "owner_id", "servers", "verdict", "detail", "since", "since_s"}}, "alerts": []}`), `monitor.log` (+ `.1`), `holders/`, `pass.out` (during a pass only). Log lines: `start`, `exit reason=no-holders|no-ledger|signal`, `pass hosts=N bots=N Ns`, `transition <key> <old>-><new>`, `drop <key>`, `host <h> ssh-failed rc=255 (retried with ControlPath=none)`, `host <h> no answer within <cap>s`, `ledger: ...`, `state unreadable, starting empty`.
- Consumes: Task 4's `health --all --json --patch` document (the shim runs it locally, ssh remotely); Task 5's ledger and fixtures.

HARD HOME RULE (repeat verbatim in this task's dispatch prompt): any probe outside the test suite sets a literal sandbox HOME in the SAME Bash call, chained with &&; never write the real ~/.claude.json, ~/.claude, ~/.claude-discord or ~/.local/bin; run hand-run hooks/tools with env -u DISCORD_STATE_DIR.

- [ ] **Step 1: Write the failing tests.** In the syntax block near the top, after `bash -n "$D/shim/claude-discord"` add:

```bash
bash -n "$D/monitor/monitor.sh"
# The monitor writes nothing to /tmp, and bash 3.2 backs every here-document and here-string with a temp file there.
! command grep -n '<<' "$D/monitor/monitor.sh" || { echo "FAIL: no here-document or here-string in monitor/monitor.sh (bash 3.2 writes them to TMPDIR)"; exit 1; }
```

In the bash 4 lint call replace `"$D"/hooks/*/* "$D"/tools/*; then` with `"$D"/hooks/*/* "$D"/tools/* "$D/monitor/monitor.sh"; then` and its message's `wrapper, shim, hooks or tools` with `wrapper, shim, hooks, tools or monitor`.

Insert immediately before the line `cd "$P"   # back to the main project after the ledger and monitor cases`:

```bash
# The monitor runs fast here: a 0.01 s tick with a pass at every tick, a 0.1 s cap per host, 0.15 s for the lock. Thresholds are tested by seeding
# state.json with old `since` times, never by waiting. The local host's command is the shim, stubbed to print
# $HOME/mon/local.out; ssh is the stub above. MB is the monitor's state dir.
export CLAUDE_DISCORD_MONITOR_TICK=0.01 CLAUDE_DISCORD_MONITOR_PASS=0.01 CLAUDE_DISCORD_MONITOR_HOST_CAP=0.1 CLAUDE_DISCORD_MONITOR_LOCK_WAIT=0.15
MB="$HOME/.claude-discord/records/monitor/mgr"
mv "$HOME/.local/bin/claude-discord" "$HOME/shim.real"
printf '#!/bin/bash\nprintf "%%s|%%s\\n" "$*" "${HTTPS_PROXY:-}" >> "$HOME/local.calls"\ncat "$HOME/mon/local.out" 2>/dev/null\n' > "$HOME/.local/bin/claude-discord"
chmod +x "$HOME/.local/bin/claude-discord"
# mdoc <host> <patch rc> <bot:verdict>...: a health --all document with those bots in project /home/u/ws/p, owner 222.
mdoc() {
  local h=$1 prc=$2; shift 2
  printf '%s\n' "$@" | jq -Rsc --arg h "$h" --argjson prc "$prc" '{host: $h, version: "1.10.0 (abc1234)", home: "/home/u",
    patch: {rc: $prc, output: (if $prc == 0 then "" else "claude-discord: patch: /x/server.ts: chunk no longer matches" end)},
    projects: [{project: "/home/u/ws/p", bots: [split("\n")[] | select(. != "") | split(":")
      | {bot: .[0], verdict: .[1], detail: (if .[1] == "nostate" then ("d" * 3000) else "why \(.[1])" end), owner_id: "222", servers: "1"}]}]}'
}
mstate() { jq -c "$@" "$MB/state.json" > "$MB/state.json.t" && mv "$MB/state.json.t" "$MB/state.json"; }
mpid() { jq -r '.monitor.pid // empty' "$MB/state.json" 2>/dev/null || :; }
# wait_log <n> <regex>: until monitor.log holds n lines matching it (3 s at most).
wait_log() {
  local n=0 c=0
  while [ "$n" -lt 300 ]; do
    c=$(command grep -cE -- "$2" "$MB/monitor.log" 2>/dev/null) || :
    [ "${c:-0}" -lt "$1" ] || return 0
    nap 0.01; n=$((n + 1))
  done
  echo "FAIL: the monitor never logged '$2' $1 time(s): $(tail -5 "$MB/monitor.log" 2>&1)"; exit 1
}
passes() { local c; c=$(command grep -c ' pass hosts=' "$MB/monitor.log" 2>/dev/null) || :; echo "${c:-0}"; }
starts() { local c; c=$(command grep -c 'Z start$' "$MB/monitor.log" 2>/dev/null) || :; echo "${c:-0}"; }
next_pass() { wait_log $(( $(passes) + 1 )) ' pass hosts='; }
holder() { sleep 30 & HPID=$!; KILL_AT_EXIT="$KILL_AT_EXIT $HPID"; }
# A monitor is detached (setsid), so its exit may leave a zombie until something reaps it: a zombie counts as gone.
running() { local st=""; { read -r st < "/proc/$1/stat"; } 2>/dev/null || return 1; st=${st##*) }; [ "${st%% *}" != Z ]; }
mstop() {  # kill the holder; the monitor must be gone within a few ticks
  local p n=0; p=$(mpid)
  kill "$HPID" 2>/dev/null || :; wait "$HPID" 2>/dev/null || :
  while [ -n "$p" ] && running "$p" && [ "$n" -lt 100 ]; do nap 0.01; n=$((n + 1)); done
  [ -z "$p" ] || ! running "$p" || { echo "FAIL: the monitor must exit within a tick of its last holder: $(tail -3 "$MB/monitor.log")"; exit 1; }
}
mstart() {  # a holder, then --ensure; returns after the first pass of this start
  local want=$(( $(passes) + 1 ))
  holder
  (cd "$MP" && bash "$S" monitor --ensure mgr --holder tui "$HPID")
  wait_log "$want" ' pass hosts='
}
posts() { sed -n 's/.* --data-binary \(.*\) https:\/\/discord.com\/api\/v10\/channels\/1558283274487341137\/messages$/\1/p' "$CURL_LOG"; }

# Single instance, the exit rule and the footprint, with every host answering ok. TMPDIR is unwritable: nothing may
# land in /tmp. The start meets a state.json that is
# not valid (it starts empty and says so) and a log past its cap (256 KiB: it becomes monitor.log.1, one generation).
printf '# mine\r\nlocal HTTPS_PROXY=http://127.0.0.1:8118\r\nh1\r\n' > "$MR/mgr/hosts"   # saved with CRLF line endings
mdoc lambda 0 "r1:ok" > "$MON/local.out"; mdoc h1 0 "r2:ok" > "$MON/h1.out"
mkdir -p "$HOME/ro"; chmod 555 "$HOME/ro"
: > "$CURL_LOG"; : > "$CURL_REPLIES"
mkdir -p "$MB"; echo '{"version":1,"manager":"mg' > "$MB/state.json"; head -c 262200 /dev/zero | tr '\0' x > "$MB/monitor.log"
# Two --ensure calls back to back: the first takes the lock before it returns, so the second loses its first try and
# leaves a waiter (0.15 s here) that must give up, never start a second monitor.
holder
(cd "$MP" && TMPDIR=$HOME/ro bash "$S" monitor --ensure mgr --holder tui "$HPID" && TMPDIR=$HOME/ro bash "$S" monitor --ensure mgr)
wait_log 1 ' pass hosts='
[ "$(cut -d' ' -f1 "$MB/holders/tui-$HPID" 2>/dev/null)" = "$HPID" ] || { echo "FAIL: --holder must write <pid> <start time> <kind>"; exit 1; }
grep -q '^health --all --json --patch|http://127.0.0.1:8118$' "$HOME/local.calls" || { echo "FAIL: local runs the shim's health --all --json --patch with the local line's env: $(cat "$HOME/local.calls")"; exit 1; }
grep -q '^-o BatchMode=yes -o ConnectTimeout=8 h1 env ~/.local/bin/claude-discord health --all --json --patch$' "$HOME/ssh.log" || { echo "FAIL: a remote host runs the shim over ssh: $(<"$HOME/ssh.log")"; exit 1; }
[ -z "$(posts)" ] || { echo "FAIL: nothing to say, nothing posted: $(posts)"; exit 1; }
# A holder record whose pid lives but started at another time is a reused pid: dead. Were it counted, the monitor
# would outlive the real holder below.
printf '%s %s tui\n' "$$" "Thu Jan  1 00:00:00 1970" > "$MB/holders/tui-$$"
n=0; while pgrep -f "Fcntl=:flock.*$MB/lock" >/dev/null && [ "$n" -lt 100 ]; do nap 0.02; n=$((n + 1)); done
nap 0.05
[ "$(starts)" = 1 ] && [ "$n" -lt 100 ] || { echo "FAIL: two --ensure calls must leave one monitor, the loser gone after its wait: $(<"$MB/monitor.log")"; exit 1; }
mstop
[ -z "$(ls -A "$MB/holders")" ] && [ "$(jq -r '.monitor.pid' "$MB/state.json")" = null ] && jq -e '.monitor.stopped_at | length > 0' "$MB/state.json" >/dev/null ||
  { echo "FAIL: an exit leaves no holder record and a state that reads as stopped: $(jq -c .monitor "$MB/state.json")"; exit 1; }
grep -q 'exit reason=no-holders$' "$MB/monitor.log" || { echo "FAIL: the exit must be logged"; exit 1; }
[ "$(cd "$MB" && find . | sort | tr '\n' ' ')" = ". ./holders ./lock ./monitor.log ./monitor.log.1 ./state.json " ] || { echo "FAIL: only the fixed files may stay: $(cd "$MB" && find . | sort)"; exit 1; }
[ "$(wc -c < "$MB/monitor.log.1")" -ge 262144 ] && [ "$(wc -c < "$MB/monitor.log")" -lt 4096 ] || { echo "FAIL: a log past 256 KiB must become monitor.log.1"; exit 1; }
grep -q 'state unreadable, starting empty$' "$MB/monitor.log" || { echo "FAIL: a state.json that is not valid must be said and replaced: $(<"$MB/monitor.log")"; exit 1; }
[ -z "$(ls -A "$HOME/ro")" ] || { echo "FAIL: nothing may be written to TMPDIR"; exit 1; }
chmod 755 "$HOME/ro"
echo "ok: monitor: one instance for two --ensure calls, holder records with start times, local through the shim with the ledger's env, ssh for the rest (a CRLF ledger read as plain lines), nothing posted when all is well; it exits within a tick of its last holder (a reused pid counts as dead), leaving only lock, state.json (stopped), monitor.log (rotated at 256 KiB, one generation) and an empty holders/, nothing in TMPDIR; a broken state.json starts empty"

# A crash leaves no lock behind: the pass's ssh is started without the lock's fd, so a new --ensure takes over while an
# orphaned ssh still runs. The exit race: an --ensure that meets a monitor exiting at that moment (the lock still
# held) waits for the lock and becomes the next monitor. And a signal takes the monitor down cleanly: state stopped,
# no holder record left, even with its holder alive.
echo 5 > "$MON/h1.sleep"; rm -f "$MON/h1.pid"; holder
(cd "$MP" && bash "$S" monitor --ensure mgr --holder tui "$HPID")
wait_for_file "$MON/h1.pid"
old=$(mpid); kill -9 "$old"; rm -f "$MON/h1.sleep"; KILL_AT_EXIT="$KILL_AT_EXIT $(<"$MON/h1.pid")"
(cd "$MP" && bash "$S" monitor --ensure mgr --holder tui "$HPID")
n=0; while { [ -z "$(mpid)" ] || [ "$(mpid)" = "$old" ]; } && [ "$n" -lt 100 ]; do nap 0.01; n=$((n + 1)); done
[ -n "$(mpid)" ] && [ "$(mpid)" != "$old" ] || { echo "FAIL: an orphaned ssh must not hold the lock: a new monitor must start within 1 s"; exit 1; }
pkill -P "$(<"$MON/h1.pid")" 2>/dev/null || :; kill "$(<"$MON/h1.pid")" 2>/dev/null || :; mstop
perl -MFcntl=:flock -e 'open(my $l, ">>", $ARGV[0]) or die; flock($l, LOCK_EX); select(undef, undef, undef, 0.06)' "$MB/lock" & LP=$!
nap 0.03; want=$(( $(starts) + 1 )); holder
(cd "$MP" && bash "$S" monitor --ensure mgr --holder tui "$HPID")
wait "$LP"; wait_log "$want" 'Z start$'
kill -TERM "$(mpid)"; wait_log 1 'exit reason=signal$'
[ -z "$(ls -A "$MB/holders")" ] && [ "$(jq -r '.monitor.pid' "$MB/state.json")" = null ] || { echo "FAIL: a signalled monitor must leave no holder record and a stopped state: $(ls "$MB/holders")"; exit 1; }
kill "$HPID" 2>/dev/null || :; wait "$HPID" 2>/dev/null || :
echo "ok: monitor: a crashed monitor's orphaned ssh holds no lock, an --ensure meeting an exiting monitor waits and takes over, and a signal stops it cleanly"

# The monitor blocks end here: the real shim back, the stubs and fixtures gone.
mv "$HOME/shim.real" "$HOME/.local/bin/claude-discord"
rm -rf "$MON" "$HOME/ssh.log" "$HOME/local.calls" "$HOME/ro" "$HOME/bin/ssh"; : > "$CURL_REPLIES"
unset CLAUDE_DISCORD_MONITOR_TICK CLAUDE_DISCORD_MONITOR_PASS CLAUDE_DISCORD_MONITOR_HOST_CAP CLAUDE_DISCORD_MONITOR_LOCK_WAIT
```

- [ ] **Step 2: Run them**

Run: `./test-claude-discord.sh ./bin/claude-discord 2>&1 | grep -m1 -E 'FAIL|^bash: '`
Expected: `bash: .../monitor/monitor.sh: No such file or directory` from the `bash -n` line (the suite stops there).

- [ ] **Step 3: Implement.** Create `monitor/monitor.sh` (mode 755) with exactly:

```bash
#!/usr/bin/env bash
# claude-discord's backend monitor: one process per manager bot. Every 5 min
# it runs `claude-discord health --all --json --patch` on each host of the
# bot's ledger (<project>/.claude/discord-agents/<bot>/hosts; `local` is this
# machine, the rest go over ssh), folds the answers into state.json and posts
# one message per state change to #bot-health-check with the manager bot's
# token. It never restarts or stops anything.
#
# Run by the wrapper only:
#   claude-discord monitor [--ensure] <bot> [--holder tui|session <pid>]
# registers the holder (when given), then starts the monitor detached unless
# one already holds the lock. The monitor lives while a holder lives (the TUI,
# the manager session) and exits within one tick (30 s) of the last one.
#
# Everything it keeps is under ~/.claude-discord/records/monitor/<bot>/:
#   lock                       the flock target (fd 9 of the monitor)
#   state.json (+ .tmp)        what the TUI shows; `posted` makes a restart quiet
#   monitor.log, monitor.log.1 256 KiB each at most
#   holders/<kind>-<pid>       "<pid> <start time> <kind>"
#   pass.out                   one host's answer, only during a pass
# Nothing in /tmp: no mktemp and no here-document or here-string anywhere in
# this file (bash 3.2 backs both with a temp file).
# Runs under macOS /bin/bash 3.2: no associative arrays, no fractional read -t.
set -u
self=${1:?wrapper path}; shift
locked=no kind="" hpid="" bot=""
while [ $# -gt 0 ]; do
  case $1 in
    --ensure) ;;
    --locked) locked=yes;;   # internal: this process holds the lock on fd 9
    --holder) kind=${2:-} hpid=${3:-}; shift 3 2>/dev/null || shift $#; continue;;
    -*) echo "usage: claude-discord monitor [--ensure] <bot> [--holder tui|session <pid>]" >&2; exit 2;;
    *) bot=$1;;
  esac
  shift
done
case $bot in ''|.|..|*/*) echo "usage: claude-discord monitor [--ensure] <bot> [--holder tui|session <pid>]" >&2; exit 2;; esac
dir=$PWD/.claude/discord-agents/$bot
# The ledger is the on/off switch: no hosts file, no monitor.
[ -f "$dir/hosts" ] && [ -f "$dir/.env" ] || { echo "claude-discord: monitor: $dir has no hosts ledger (claude-discord setup $bot --mode writes one)" >&2; exit 1; }
M=$HOME/.claude-discord/records/monitor/$bot
umask 077
mkdir -p "$M/holders" || exit 1

# lstart <pid>: the process's start time. A pid alone can be reused; a pid
# with its start time cannot. Linux: field 22 of /proc/<pid>/stat, read with
# no fork (this runs every tick); elsewhere `ps -o lstart=`, whitespace
# collapsed ("Oct  1" has two spaces). Prints nothing for no such process
# (or, on Linux, for a zombie no parent has reaped yet).
lstart() {
  local st
  if [ -r "/proc/$1/stat" ]; then
    { read -r st < "/proc/$1/stat"; } 2>/dev/null || return 0
    set -f; set -- ${st##*) }; set +f   # after "<pid> (<comm>) ", which may hold spaces: field 3 on
    [ "${1:-}" = Z ] || echo "${20:-}"   # a zombie is dead, whatever kill -0 says
  else
    set -- $(ps -o lstart= -p "$1" 2>/dev/null); echo "$*"
  fi
}

if [ -n "$kind$hpid" ]; then
  case $kind in tui|session) ;; *) echo "claude-discord: monitor: --holder takes tui or session, got '$kind'" >&2; exit 2;; esac
  case $hpid in ''|*[!0-9]*) echo "claude-discord: monitor: --holder needs a pid, got '$hpid'" >&2; exit 2;; esac
  st=$(lstart "$hpid")
  [ -n "$st" ] || { echo "claude-discord: monitor: no process $hpid to hold for" >&2; exit 1; }
  printf '%s %s %s\n' "$hpid" "$st" "$kind" > "$M/holders/$kind-$hpid"
fi

if [ "$locked" = no ]; then
  # flock through perl: flock(1) is util-linux and a manager may be a Mac.
  # One try at once, then perl forks and this returns, so a caller never
  # waits. The child (setsid, stdin closed, output appended to monitor.log,
  # the only trace a crash leaves) keeps trying for up to 5 s:
  # winning makes it the monitor, losing means one is running. The wait is the
  # exit race's cover: a holder that registers just as the old monitor leaves
  # (it saw no holder a moment earlier) gets the lock when that one is gone and
  # starts the next. The lock is dup'd to fd 9 (no close-on-exec), so it lives
  # exactly as long as the monitor process; the kernel drops it on any death.
  : >> "$M/lock"
  perl -MPOSIX -MFcntl=:flock -e '
    my $tries = int(shift(@ARGV) * 10 + 0.5);
    open(my $l, ">>", shift @ARGV) or exit 1;
    my $won = flock($l, LOCK_EX | LOCK_NB);
    defined(my $pid = fork()) or exit 1;
    exit 0 if $pid;
    POSIX::setsid();
    until ($won) { exit 0 if --$tries < 0; select(undef, undef, undef, 0.1); $won = flock($l, LOCK_EX | LOCK_NB); }
    POSIX::dup2(fileno($l), 9) == 9 or exit 1;
    exec @ARGV;' "${CLAUDE_DISCORD_MONITOR_LOCK_WAIT:-5}" "$M/lock" bash "$0" "$self" --locked "$bot" </dev/null >>"$M/monitor.log" 2>&1
  exit 0
fi

# ---- the monitor itself (fd 9 holds the lock) ------------------------------
# Every child that can outlive a moment (sleep, ssh, the local health)
# is started with 9>&-: a child that survived a crash would otherwise keep the
# lock and no new monitor could start.
# CLAUDE_DISCORD_MONITOR_LOCK_WAIT (above; 5) is the fourth interval the suite shortens.
tick=${CLAUDE_DISCORD_MONITOR_TICK:-30}        # holder check, seconds
pass=${CLAUDE_DISCORD_MONITOR_PASS:-300}       # a pass at most this often; health's unknown_cap=6 assumes 300
cap=${CLAUDE_DISCORD_MONITOR_HOST_CAP:-90}     # per host, enforced here (no timeout(1) on macOS)
# Fractional values are for the suite; bash counts in whole steps. A running
# host is polled every step (1 s, or a fifth of a tick shorter than 5 s).
read -r step pass_n cap_n tick_n < <(awk -v t="$tick" -v p="$pass" -v c="$cap" 'BEGIN {
  s = (t < 5 ? t / 5 : 1); printf "%s %d %d %d\n", s, (p / t < 1 ? 1 : int(p / t + 0.5)), int(c / s + 0.5), int(t / s + 0.5) }')
child="" state="" h_rc=0

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
# One line per event; never a message body, a header or a token. $ts, when set, stamps a burst of lines with one date.
log() { printf '%s %s\n' "${ts:-$(now)}" "$*" >> "$M/monitor.log" 2>/dev/null || :; }
# The cap, checked once per pass and at start: past 256 KiB the log becomes monitor.log.1, replacing the one before.
rotate() {
  local sz
  sz=$(wc -c < "$M/monitor.log" 2>/dev/null) || sz=0
  [ "${sz:-0}" -lt 262144 ] || mv -f "$M/monitor.log" "$M/monitor.log.1" 2>/dev/null || :
}
write_state() { printf '%s\n' "$state" > "$M/state.json.tmp" 2>/dev/null && mv -f "$M/state.json.tmp" "$M/state.json" 2>/dev/null || :; }
# read_cfg: mowner from the manager project's config.env (KEY='value' or
# KEY=value), with no fork: DISCORD_USER_ID, the manager's own owner.
read_cfg() {
  local l v
  mowner=""
  while IFS= read -r l || [ -n "$l" ]; do
    v=${l#*=}; v=${v#\'}; v=${v%\'}
    case $l in DISCORD_USER_ID=*) mowner=$v;; esac
  done < "$dir/../config.env" 2>/dev/null
}

# holders_alive: removes the records of dead holders; 0 when one still lives.
holders_alive() {
  local f p rest alive=1
  for f in "$M"/holders/*; do
    [ -f "$f" ] || continue
    p="" rest=""
    read -r p rest < "$f" 2>/dev/null || :
    case $p in ''|*[!0-9]*) rm -f "$f"; continue;; esac
    if kill -0 "$p" 2>/dev/null && [ "$(lstart "$p")" = "${rest% *}" ]; then alive=0; else rm -f "$f"; fi
  done
  return $alive
}
# Read twice before giving up: a holder may have registered just now.
no_holders() { holders_alive && return 1; holders_alive && return 1; return 0; }
holders_json() {  # sets hj: the holder records as a JSON array, with no fork
  local f b
  hj=""
  for f in "$M"/holders/*; do
    [ -f "$f" ] || continue
    b=${f##*/}; hj="$hj${hj:+,}{\"kind\":\"${b%%-*}\",\"pid\":${b##*-}}"
  done
  hj="[$hj]"
}
finish() {  # $1 = reason: kill the pass child, leave a state that reads as stopped, drop the holder records
  [ -z "$child" ] || kill "$child" 2>/dev/null
  rm -f "$M/pass.out"
  state=$(printf '%s' "$state" | jq -c --arg now "$(now)" '.monitor.pid = null | .monitor.holders = [] | .monitor.stopped_at = $now' 2>/dev/null) && write_state
  # On no-holders every record left was dead and is already gone; a record
  # that appears now belongs to a holder whose --ensure is waiting for this
  # lock, so it stays for the monitor that ensure starts. On a signal the
  # monitor is being taken down, and no record may outlive it.
  [ "$1" = no-holders ] || rm -f "$M"/holders/* 2>/dev/null
  log "exit reason=$1"
  exit 0
}
trap 'finish signal' TERM INT HUP

# run_host: one host's health document into $M/pass.out, its exit status in
# h_rc (124 = the per-host cap). The child is polled, never waited on: the
# holder check keeps running every tick while a host is slow. ssh's own
# failure is exit 255, and only that is retried, once, with ControlPath=none
# (a stale master refuses falsely) and counts as hostdown. Any other status
# without a document is the remote command's (claude-discord missing or too
# old), which is blind; so is the cap, since ConnectTimeout=8 already bounds
# the connection: a host that reaches the cap connected and never finished.
# Except a laptop's: one asleep behind its reverse tunnel can hang the forward
# past the cap, and a laptop's unreachability is never posted (hostdown).
run_host() {  # uses $host $remote and the envs array
  local t k
  for t in first retry; do
    if [ "$host" = local ]; then
      env ${envs[@]+"${envs[@]}"} "$HOME/.local/bin/claude-discord" health --all --json --patch > "$M/pass.out" 2>/dev/null < /dev/null 9>&- &
    elif [ "$t" = first ]; then
      ssh -o BatchMode=yes -o ConnectTimeout=8 "$host" "$remote" > "$M/pass.out" 2>/dev/null < /dev/null 9>&- &
    else
      ssh -o BatchMode=yes -o ConnectTimeout=8 -o ControlPath=none "$host" "$remote" > "$M/pass.out" 2>/dev/null < /dev/null 9>&- &
    fi
    child=$! k=0
    while kill -0 "$child" 2>/dev/null; do
      k=$((k + 1))
      if [ "$k" -gt "$cap_n" ]; then
        kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; child="" h_rc=124
        log "host $host no answer within ${cap}s"
        return 0
      fi
      [ $((k % tick_n)) != 0 ] || ! no_holders || finish no-holders
      sleep "$step" 9>&-
    done
    wait "$child" 2>/dev/null; h_rc=$?; child=""
    [ "$h_rc" = 255 ] && [ "$host" != local ] && [ "$t" = first ] || return 0
    log "host $host ssh-failed rc=255 (retried with ControlPath=none)"
  done
}

# The reducer: (state, this pass's host results) -> the new state and the log
# events. One jq program, so every rule of "what a pass saw" is in one place:
#   - a verdict that changes restarts its `since`;
#   - while a host is noreach, hostdown or blind its bots are frozen;
#   - a bot that left its host's answer is dropped, not announced.
# Input, raw lines: the state JSON, then two lines per host, "<host> US <laptop> US <exit status>" and the host's
# answer with its newlines made spaces (still valid JSON when it was).
# Output lines: "S<state JSON>", "N<bot count>", "E<event>".
reduce='
def good: . == "ok" or . == "busy";
# observe: fold one observation into an entry; `since` moves only when the verdict changes.
def observe($v; $d; $meta): (. // {}) as $o
  | $o + $meta + {verdict: $v, detail: $d}
  | if ($o.verdict // null) != $v then . + {since: $now, since_s: $now_s} else . end;

[inputs] as $in
| ($in[0] | fromjson) as $old
| [range(1; $in | length - 1; 2) as $i | ($in[$i] | split("\u001f")) as $h
   | {host: $h[0], laptop: ($h[1] == "true"), rc: ($h[2] | tonumber), doc: ($in[$i + 1] | try fromjson catch null)}] as $res
| reduce $res[] as $r ({state: $old, events: [], frozen: []};
    ($r.doc | if type == "object" and (.projects | type) == "array" then . else null end) as $doc
    | ([$doc.projects[]? | .project as $p | .bots[]? | . + {project: $p}]) as $bots
    | (if $r.rc == 255 or ($r.rc == 124 and $r.laptop) then "hostdown"
       elif $doc == null then "blind"
       elif ($bots | length) > 0 and all($bots[]; .verdict == "noreach") then "noreach"
       else "ok" end) as $reach
    | (if $reach == "hostdown" or $reach == "blind" then $reach
       elif ($doc.patch.rc // 0) != 0 then "patchfail"
       else $reach end) as $hv
    | (if $hv == "hostdown" and $r.rc == 124 then "no answer from \($r.host) within the per-host limit (a laptop: asleep behind its tunnel?)"
       elif $hv == "hostdown" then "ssh to \($r.host) failed (exit 255), also with ControlPath=none"
       elif $hv == "blind" and $r.rc == 124 then "\($r.host) connected but health --all did not finish within the per-host limit"
       elif $hv == "blind" then "\($r.host) answered without a health document (exit \($r.rc)): claude-discord is missing there or older than health --all"
       elif $hv == "patchfail" then (($doc.patch.output // "") | gsub("\n"; " | "))
       elif $hv == "noreach" then "\($r.host) cannot reach Discord"
       else "" end) as $hd
    | (.state.hosts[$r.host].verdict // null) as $was
    | .state.hosts[$r.host] |= observe($hv; $hd;
        {host: $r.host, name: (if $r.host == "local" then ($doc.host // (.name // "local")) else $r.host end),
         laptop: $r.laptop, reach: $reach, owner_id: $mowner, checked: $now}
        + (if $doc != null then {version: ($doc.version // "?"), patch: (if $doc.patch == null then "-" elif ($doc.patch.rc // 0) == 0 then "ok" else "fail" end)} else {} end))
    | (if $was != $hv and ($was != null or ($hv | good | not)) then .events += ["transition \($r.host)|- \($was // "new")->\($hv)"] else . end)
    | if $reach != "ok" then .frozen += [$r.host]
      else
        ($bots | map("\($r.host)|\(.project)|\(.bot)")) as $present
        | reduce $bots[] as $b (.;
            "\($r.host)|\($b.project)|\($b.bot)" as $k
            | (.state.bots[$k].verdict // null) as $bw
            | .state.bots[$k] |= observe($b.verdict; ($b.detail // "");
                {host: $r.host, name: (if $r.host == "local" then ($doc.host // "local") else $r.host end),
                 project: $b.project, bot: $b.bot, home: ($doc.home // ""), owner_id: ($b.owner_id // ""), servers: ($b.servers // "")})
            | if $bw != $b.verdict and ($bw != null or ($b.verdict | good | not)) then .events += ["transition \($k) \($bw // "new")->\($b.verdict)"] else . end)
        | ([.state.bots | to_entries[] | select(.value.host == $r.host and ((.key as $k | $present | index($k)) == null)) | .key]) as $gone
        | .events += ($gone | map("drop \(.)"))
        | .state.bots |= with_entries(select(.key as $k | ($gone | index($k)) == null))
      end)
| .state.monitor += {last_pass: $now, next_pass: (($now_s + $every) | floor | todate), pass_s: $pass_s, holders: $holders}
| .state as $s | .events as $ev
| "S" + ($s | tojson), "N\($s.bots | length)",
  ($ev[] | "E" + .)
'
run_pass() {
  local t0=$SECONDS now_s line w host laptop remote doc results="" out l rest hosts=0 nb=0 mowner ts="" hj
  local envs=()
  rotate
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}   # a ledger saved with CRLF line endings
    set -f; set -- $line; set +f
    host=${1:-}; [ $# = 0 ] || shift
    case $host in ''|'#'*) continue;; esac
    # An ssh host name, never an option: the ledger is the owner's file, but a leading "-" would be read by ssh as a flag.
    case $host in -*|*[!A-Za-z0-9._@-]*) log "ledger: host skipped (not a plain ssh host name)"; continue;; esac
    laptop=false; [ "${1:-}" != laptop ] || { laptop=true; shift; }
    envs=()
    for w in "$@"; do
      if [[ $w =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then envs+=("$w"); else log "ledger: $host: a word that is not KEY=VALUE was skipped"; fi
    done
    remote="env $([ ${#envs[@]} = 0 ] || printf '%q ' "${envs[@]}")~/.local/bin/claude-discord health --all --json --patch"
    run_host
    doc=$(< "$M/pass.out") 2>/dev/null || doc=""
    results="$results$host"$'\x1f'"$laptop"$'\x1f'"$h_rc"$'\n'"${doc//$'\n'/ }"$'\n'
    hosts=$((hosts + 1))
  done < "$dir/hosts"
  rm -f "$M/pass.out"
  read_cfg; holders_json
  read -r now_s ts < <(date -u '+%s %Y-%m-%dT%H:%M:%SZ')
  out=$(printf '%s\n%s' "$state" "$results" | jq -nrR --arg now "$ts" --argjson now_s "$now_s" --arg mowner "$mowner" \
    --argjson every "$pass" --argjson pass_s "$(( SECONDS - t0 ))" --argjson holders "$hj" "$reduce" 2>/dev/null) ||
    { log "pass failed: the reducer rejected its input"; return 0; }
  while IFS= read -r l; do
    rest=${l#?}
    case $l in
      S*) state=$rest;;
      N*) nb=$rest;;
      E*) log "$rest";;
    esac
  done < <(printf '%s\n' "$out")
  write_state
  log "pass hosts=$hosts bots=$nb $(( SECONDS - t0 ))s"
}

rotate
# Start from the kept state (its `posted` is what keeps a restart quiet). A
# state file that is not ours (truncated, another version, another manager)
# starts empty and says so: findings still standing are then posted once more.
state=$(jq -c --arg bot "$bot" 'if type == "object" and .version == 1 and .manager == $bot then . else error("no") end' "$M/state.json" 2>/dev/null) || {
  [ ! -s "$M/state.json" ] || log "state unreadable, starting empty"
  state=$(jq -nc --arg bot "$bot" '{version: 1, manager: $bot, monitor: {}, hosts: {}, bots: {}, alerts: []}')
}
holders_json
state=$(printf '%s' "$state" | jq -c --argjson pid "$$" --arg now "$(now)" --argjson holders "$hj" \
  '.monitor = ((.monitor // {}) + {pid: $pid, started: $now, holders: $holders}) | del(.monitor.stopped_at)')
write_state
log start
n=$pass_n   # the first pass right after start
while :; do
  [ -f "$dir/hosts" ] || finish no-ledger
  ! no_holders || finish no-holders
  if [ "$n" -ge "$pass_n" ]; then run_pass; n=0; fi
  sleep "$tick" 9>&-
  n=$((n + 1))
done
```

In `bin/claude-discord`, before the line `args=() name="" skip=0 want_name=0 named=0 positional=0 has_name=0 bare=0`, add:

```bash
# monitor: the backend health monitor of a manager bot (monitor/monitor.sh has
# the whole story). Not in --help: the TUI and the SessionStart hook run it.
if [ "${1:-}" = monitor ]; then
  shift
  exec bash "$self_root/monitor/monitor.sh" "$self_path" "$@"
fi
```

- [ ] **Step 4: Run the suite.** Expected: `ALL PASS` with `ok: monitor: one instance for two --ensure calls, ...` and `ok: monitor: a crashed monitor's orphaned ssh holds no lock, ...`; `ok: no process is left behind` still last before `ALL PASS`.

- [ ] **Step 5: Mutation check** (each against the file above). Each revert alone fails with:
  - `9>&-` dropped from the first ssh: `FAIL: an orphaned ssh must not hold the lock: a new monitor must start within 1 s`
  - the start-time comparison dropped from `holders_alive`: `FAIL: the monitor must exit within a tick of its last holder`
  - the lock wait loop removed (no lock at all): `FAIL: two --ensure calls must leave one monitor, the loser gone after its wait`
  - `exit 0 if --$tries < 0` made `exit 0` (no wait): `FAIL: the monitor never logged 'Z start$' ...` (the exit race)
  - `rm -f "$M"/holders/*` on a signal dropped: `FAIL: a signalled monitor must leave no holder record and a stopped state`
  - `.monitor.pid = null` dropped from `finish`: `FAIL: an exit leaves no holder record and a state that reads as stopped`
  - `mv` in `rotate` disabled: `FAIL: only the fixed files may stay`
  - the CRLF strip dropped: `FAIL: local runs the shim's health --all --json --patch with the local line's env`
  - the `state unreadable` log line dropped: `FAIL: a state.json that is not valid must be said and replaced`

- [ ] **Step 6: Commit**

```bash
git add monitor/monitor.sh
git commit -m "monitor: one process per manager bot (perl flock on fd 9, holders with start times, exit within a tick of the last); a pass runs health --all --json --patch per ledger host, ssh 255 retried with ControlPath=none, a per-host cap, state.json and a capped log; nothing in /tmp" -m "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>" -- monitor/monitor.sh bin/claude-discord test-claude-discord.sh
```

---
### Task 7: findings, holds and posts (`monitor/monitor.sh` final)

**Files:**
- Modify: `monitor/monitor.sh` (replace the whole file with the content below)
- Modify: `test-claude-discord.sh` (one line in the curl stub; two blocks before the section's cleanup)

**Interfaces:**
- Produces: posts to `POST /channels/1558283274487341137/messages`. Finding: `{"content": "<@owner> [verdict] <bot> on <host> (<~/project>)\n<reason label>: <detail>\n<fix label>: <command>", "allowed_mentions": {"users": [owner]}}` (no owner: no mention and `{"parse": []}`); host-level: `<@manager owner> [verdict] <host>`. Recovery: `[recovered] <subject>: answering again after Nm (was <verdict>)`, `{"parse": []}`. Cut to 1900 characters. Labels `사유`/`복구`, or `reason`/`fix` under `ALERT_LANG=en`. Holds: `down`, `duplicate`, `unreachable`, `blind` 300 s; `throttled`, `apierror`, `hostdown` 1800 s; `stale`, `nostate`, `patchfail` 0; `noreach` never; `hostdown` never for a `laptop`. State fields added: `posted`, `posted_at`, `posted_since_s`, `fix` per entry; `monitor.post_failed`; `alerts` (last 50: `ts`, `key`, `kind`, `verdict`, `status`). Log lines added: `post <key> <verdict> <code>`, `post <key> <verdict> failed <code>[ retry_after=N]`, and the pass line becomes `pass hosts=N bots=N findings=N posted=N Ns`.
- Consumes: Task 6's state, holders and passes.

HARD HOME RULE (repeat verbatim in this task's dispatch prompt): any probe outside the test suite sets a literal sandbox HOME in the SAME Bash call, chained with &&; never write the real ~/.claude.json, ~/.claude, ~/.claude-discord or ~/.local/bin; run hand-run hooks/tools with env -u DISCORD_STATE_DIR.

- [ ] **Step 1: Write the failing tests.** In the curl stub, after its line `printf '%s\n' "$*" >> "$CURL_LOG"` add

```bash
[ -z "${HTTPS_PROXY:-}" ] || printf '%s\n' "$HTTPS_PROXY" >> "$HOME/curl.proxy"   # the env a call ran with (the monitor's POST)
```

Insert immediately before the line `# The monitor blocks end here: the real shim back, the stubs and fixtures gone.`:

```bash
# Every row of the failure table in one pass. Seeded: since times old enough (or not) for each hold, and what the
# channel was last told. Expected posts, 15:
#   h1|- patchfail (no hold); h1's bots d1 down (seeded 301 s), st stale (new, no hold), du duplicate (301 s),
#   un unreachable (301 s), ns nostate (new; a 3000-character detail, cut to 1900), t2 throttled (1801 s),
#   ap apierror (1801 s), bu busy after a posted stale (recovery), ok ok after a down posted 35 min ago (recovery);
#   h3|- hostdown (1801 s; ssh 255 twice); h4|- blind (301 s; no document); ch stale after a posted down (a new
#   finding is a new message); nm stale with no owner_id (an older host's document): no mention, nobody pinged.
#   h2's bot sp stale, in a project whose path holds a space, a quote and a $: the recovery command must survive both
#   shells (h2 itself answered 255, then ok with ControlPath=none).
# Not posted: d2 down (new), rc down after an ok seeded 1000 s ago (since restarts on the change, so the hold starts
# over), t1 throttled (301 s), qu stale already posted, a ledger line that is not a plain host name (skipped, never
# passed to ssh), lap hostdown (a laptop), local noreach and
# its bot l1 frozen (no recovery for its posted down), h3's bot frozen, h5 (connected, then silent past the cap: blind,
# not hostdown, and new, so held), lap2 (a laptop silent past the cap, seeded blind 301 s: a sleeping laptop is
# hostdown, never posted).
printf 'local HTTPS_PROXY=http://127.0.0.1:8118\nh1\nh2\n-oProxyCommand=x\nh3\nh4\nh5\nlap laptop\nlap2 laptop\n' > "$MR/mgr/hosts"; echo 1 > "$MON/h5.sleep"; echo 1 > "$MON/lap2.sleep"
mdoc lambda 0 "l1:noreach" > "$MON/local.out"
mdoc h1 1 d1:down d2:down st:stale du:duplicate un:unreachable ns:nostate t1:throttled t2:throttled ap:apierror bu:busy ok:ok qu:stale ch:stale nm:stale rc:down |
  jq -c '.projects[0].bots |= map(if .bot == "nm" then del(.owner_id) else . end)' > "$MON/h1.out"
mdoc h2 0 sp:stale | jq -c '.projects[0].project = "/home/u/it\u0027s $x here"' > "$MON/h2.out"; echo 255 > "$MON/h2.rc"; echo 0 > "$MON/h2.rc2"
echo 255 > "$MON/h3.rc"; echo 255 > "$MON/lap.rc"; echo 'not json' > "$MON/h4.out"
mstate --argjson n "$(date +%s)" '
  def at($s): {since: ($s | todate), since_s: $s};
  def b($k; $v; $s): .bots["h1|/home/u/ws/p|" + $k] = ({host: "h1", verdict: $v} + at($n - $s));
  b("d1"; "down"; 301) | b("du"; "duplicate"; 301) | b("un"; "unreachable"; 301) | b("t1"; "throttled"; 301)
  | b("t2"; "throttled"; 1801) | b("ap"; "apierror"; 1801)
  | b("bu"; "stale"; 600) | .bots["h1|/home/u/ws/p|bu"] += {posted: "stale", posted_since_s: ($n - 600)}
  | b("ok"; "down"; 2100) | .bots["h1|/home/u/ws/p|ok"] += {posted: "down", posted_since_s: ($n - 2100)}
  | b("qu"; "stale"; 900) | .bots["h1|/home/u/ws/p|qu"] += {posted: "stale", posted_since_s: ($n - 900)}
  | b("ch"; "down"; 900) | .bots["h1|/home/u/ws/p|ch"] += {posted: "down", posted_since_s: ($n - 900)} | b("rc"; "ok"; 1000)
  | .bots["local|/home/u/ws/p|l1"] = ({host: "local", verdict: "down", posted: "down", posted_since_s: ($n - 900)} + at($n - 900))
  | .bots["h3|/home/u/ws/p|z"] = ({host: "h3", verdict: "stale", posted: "stale", posted_since_s: ($n - 900)} + at($n - 900))
  | .hosts.h3 = ({host: "h3", verdict: "hostdown"} + at($n - 1801)) | .hosts.lap = ({host: "lap", laptop: true, verdict: "hostdown"} + at($n - 1801))
  | .hosts.h4 = ({host: "h4", verdict: "blind"} + at($n - 301)) | .hosts.lap2 = ({host: "lap2", laptop: true, verdict: "blind"} + at($n - 301))'
: > "$CURL_LOG"; : > "$CURL_STDIN_LOG"; rm -f "$HOME/ssh.log" "$HOME/curl.proxy"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do printf '200 {}\n'; done > "$CURL_REPLIES"
mstart; rm -f "$MON/h5.sleep" "$MON/lap2.sleep"; echo 124 > "$MON/h5.rc"; echo 255 > "$MON/lap2.rc"   # later passes: no cap wait, same verdicts
P1=$(posts)
[ "$(printf '%s\n' "$P1" | grep -c .)" = 15 ] || { echo "FAIL: one pass must post exactly the 15 due findings and recoveries: $P1"; exit 1; }
C1=$(printf '%s\n' "$P1" | jq -r .content)
for want in '<@111> [patchfail] h1' '<@222> [down] d1 on h1 (~/ws/p)' '<@222> [stale] st on h1' '<@222> [duplicate] du on h1' \
            '<@222> [unreachable] un on h1' '<@222> [nostate] ns on h1' '<@222> [throttled] t2 on h1' '<@222> [apierror] ap on h1' \
            '[recovered] bu on h1 (~/ws/p): answering again after 10m (was stale)' '[recovered] ok on h1 (~/ws/p): answering again after 35m (was down)' \
            '<@111> [hostdown] h3' '<@111> [blind] h4' '<@222> [stale] ch on h1'; do
  grep -qF -- "$want" <<<"$C1" || { echo "FAIL: missing post '$want': $C1"; exit 1; }
done
st=$(printf '%s\n' "$P1" | jq -c 'select(.content | startswith("<@222> [stale] st "))')
[ "$(jq -r .content <<<"$st")" = "$(printf "<@222> [stale] st on h1 (~/ws/p)\n사유: why stale\n복구: ssh h1 'cd ~/ws/p && ~/.local/bin/claude-discord refresh st --force'")" ] &&
  [ "$(jq -c .allowed_mentions <<<"$st")" = '{"users":["222"]}' ] || { echo "FAIL: a finding names owner, session, reason and recovery command, and pings only the owner: $st"; exit 1; }
[ "$(printf '%s\n' "$P1" | jq -c 'select(.content | startswith("[recovered]")) | .allowed_mentions' | sort -u)" = '{"parse":[]}' ] || { echo "FAIL: a recovery line pings nobody"; exit 1; }
[ "$(printf '%s\n' "$P1" | jq -c 'select(.content | contains("] nm on ")) | [(.content | startswith("[stale] nm on h1")), .allowed_mentions]')" = '[true,{"parse":[]}]' ] || { echo "FAIL: a bot with no owner_id is posted with no mention and pings nobody: $(grep '] nm on' <<<"$C1")"; exit 1; }
grep -q 'ledger: host skipped' "$MB/monitor.log" && ! grep -q ProxyCommand "$HOME/ssh.log" || { echo "FAIL: a ledger line that is not a plain host name must be skipped, never passed to ssh"; exit 1; }
[ "$(printf '%s\n' "$P1" | jq -r 'select(.content | contains("[nostate]")) | .content | length')" = 1900 ] || { echo "FAIL: a message is cut to 1900 characters"; exit 1; }
grep -q 'ControlPath=none h2 ' "$HOME/ssh.log" && grep -q 'host h2 ssh-failed rc=255 (retried with ControlPath=none)' "$MB/monitor.log" &&
  [ "$(jq -r '.hosts.h2.verdict' "$MB/state.json")" = ok ] || { echo "FAIL: ssh exit 255 is retried with ControlPath=none before the host counts as down"; exit 1; }
grep -qxF "복구: ssh h2 'cd \"/home/u/it'\\''s \\\$x here\" && ~/.local/bin/claude-discord refresh sp --force'" <<<"$C1" || { echo "FAIL: a project path with a space, a quote and a \$ must be quoted for both shells: $(grep 'refresh sp' <<<"$C1")"; exit 1; }
[ "$(jq -r '.hosts.h5.verdict' "$MB/state.json")" = blind ] && grep -q 'host h5 no answer within' "$MB/monitor.log" || { echo "FAIL: a host that connected and went silent past the cap is blind, not hostdown: $(jq -c .hosts.h5 "$MB/state.json")"; exit 1; }
[ "$(jq -r '.hosts.lap2.verdict' "$MB/state.json")" = hostdown ] || { echo "FAIL: a laptop silent past the cap is hostdown (asleep), never a posted blind: $(jq -c .hosts.lap2 "$MB/state.json")"; exit 1; }
jq -e '.bots["h3|/home/u/ws/p|z"].posted == "stale" and .bots["local|/home/u/ws/p|l1"].posted == "down" and .hosts.local.verdict == "noreach"' "$MB/state.json" >/dev/null ||
  { echo "FAIL: a hostdown or noreach host's bots are frozen: $(jq -c '.bots["h3|/home/u/ws/p|z"], .bots["local|/home/u/ws/p|l1"]' "$MB/state.json")"; exit 1; }
grep -q 'Authorization: Bot tokMgrUnique' "$CURL_STDIN_LOG" && ! grep -q tokMgrUnique "$CURL_LOG" || { echo "FAIL: the manager's token goes on curl's stdin, never argv"; exit 1; }
[ "$(sort -u "$HOME/curl.proxy" 2>/dev/null)" = http://127.0.0.1:8118 ] || { echo "FAIL: a POST runs with the ledger's local env (the proxy): $(cat "$HOME/curl.proxy" 2>&1)"; exit 1; }
rm -f "$HOME/curl.proxy"
leak=$(command grep -rlF tokMgrUnique "$HOME/.claude-discord/records" "$MP" | command grep -v '/mgr/\.env$' || :)
[ -z "$leak" ] || { echo "FAIL: the token may appear in no file but the bot's .env: $leak"; exit 1; }
[ "$(jq -r '[.alerts[].status] | "\(length) \(unique | join(","))"' "$MB/state.json")" = "15 sent" ] || { echo "FAIL: alerts keeps each post: $(jq -c .alerts "$MB/state.json")"; exit 1; }
echo "ok: monitor: every row of the failure table posts after its hold and not before (a new finding after a posted one too; a finding that cleared starts its hold over) (noreach and a laptop's hostdown never), frozen bots under hostdown and noreach, ssh 255 retried with ControlPath=none, a host silent past the cap is blind (a laptop's is hostdown, unposted), POSTs with the local line's env, recovery lines ping nobody, a path with a space and a quote survives both shells, 1900-character cut, token on stdin only"

# A failed POST stays pending: logged, shown (post_failed, an alert with status failed), retried next pass; a 429 under
# 10 s is waited out in the pass (so that pass ends on the 500 behind it), a longer one is left for the next pass.
# Restarted on a ledger of h1 alone: h1 keeps its patchfail (already posted: a restart repeats nothing, since
# state.json's `posted` is what the channel was last told), its other bots leave the answer (dropped, not announced)
# and nf is new. With nothing queued the curl stub answers nothing, a failure too. The first pass meets the manager's
# .env without its token (read at POST time): the post fails before any curl, and the log says why.
mstop
printf '%s\n' '429 {"retry_after": 0.01}' '500 {}' '429 {"retry_after": 60}' > "$CURL_REPLIES"; : > "$CURL_LOG"
mdoc h1 1 nf:stale > "$MON/h1.out"; printf 'h1\n' > "$MR/mgr/hosts"
printf "ALERT_LANG='EN'\n" >> "$MR/config.env"   # labels in English from here on; any case of en, anything else is ko
cp "$MR/mgr/.env" "$MR/mgr/.env.keep"; : > "$MR/mgr/.env"
mstart
grep -q 'post h1|/home/u/ws/p|nf stale failed 000 (no DISCORD_BOT_TOKEN in .*/mgr/\.env)$' "$MB/monitor.log" && [ -z "$(posts)" ] || { echo "FAIL: a POST with no token in the manager's .env must fail before curl, logged with the reason: $(grep ' post ' "$MB/monitor.log")"; exit 1; }
mv "$MR/mgr/.env.keep" "$MR/mgr/.env"; next_pass
[ "$(posts | grep -c .)" = 2 ] && [ "$(posts | grep -c '\[stale\] nf')" = 2 ] || { echo "FAIL: the restart must post only what is new (nf, twice: the 429 then its retry), never the patchfail already posted: $(posts)"; exit 1; }
wait_log 1 'post h1\|/home/u/ws/p\|nf stale failed 500$'; wait_log 1 'post h1\|/home/u/ws/p\|nf stale failed 429 retry_after=60$'; next_pass
! grep -q 'retry_after=0.01' "$MB/monitor.log" || { echo "FAIL: a 429 with retry_after under 10 s must be waited out and retried in the same pass: $(grep ' post ' "$MB/monitor.log")"; exit 1; }
[ "$(jq -r '.bots["h1|/home/u/ws/p|nf"].posted // "none"' "$MB/state.json")" = none ] && jq -e '.monitor.post_failed and (.alerts[-1].status == "failed")' "$MB/state.json" >/dev/null ||
  { echo "FAIL: a failed POST leaves the finding unposted and shows the failure: $(jq -c .monitor "$MB/state.json")"; exit 1; }
printf '200 {}\n' > "$CURL_REPLIES"
wait_log 1 'post h1\|/home/u/ws/p\|nf stale 200$'; next_pass; next_pass
[ "$(jq -r '.bots["h1|/home/u/ws/p|nf"].posted' "$MB/state.json")" = stale ] && [ "$(grep -c 'nf stale 200' "$MB/monitor.log")" = 1 ] && [ "$(jq -r .monitor.post_failed "$MB/state.json")" = false ] &&
  ! posts | grep -qv '\[stale\] nf' || { echo "FAIL: the pending post must be sent on a later pass, once, and nothing else posted: $(posts)"; exit 1; }
[ "$(posts | tail -n 1 | jq -r .content)" = "$(printf "<@222> [stale] nf on h1 (~/ws/p)\nreason: why stale\nfix: ssh h1 'cd ~/ws/p && ~/.local/bin/claude-discord refresh nf --force'")" ] || { echo "FAIL: ALERT_LANG=EN must give English labels: $(posts | tail -n 1)"; exit 1; }
[ "$(jq -c '[(.hosts | keys), (.bots | keys)]' "$MB/state.json")" = '[["h1"],["h1|/home/u/ws/p|nf"]]' ] || { echo "FAIL: hosts left out of the ledger, and bots gone from an answer, are dropped from the state: $(jq -c '[(.hosts | keys), (.bots | keys)]' "$MB/state.json")"; exit 1; }
mstop
echo "ok: monitor: a failed POST is logged, shown and retried next pass (a 429 under 10 s waited in the pass), sent once when it goes through; a pass that sees nothing new posts nothing and neither does a restart; a missing token is logged as the reason; hosts and bots that left are dropped; ALERT_LANG=EN gives English labels"
```

- [ ] **Step 2: Run them**

Run: `./test-claude-discord.sh ./bin/claude-discord 2>&1 | grep -m1 -E 'FAIL|ok: monitor: every row'`
Expected: `FAIL: one pass must post exactly the 15 due findings and recoveries: ` (nothing is posted yet).

- [ ] **Step 3: Implement.** Replace `monitor/monitor.sh` with exactly:

```bash
#!/usr/bin/env bash
# claude-discord's backend monitor: one process per manager bot. Every 5 min
# it runs `claude-discord health --all --json --patch` on each host of the
# bot's ledger (<project>/.claude/discord-agents/<bot>/hosts; `local` is this
# machine, the rest go over ssh), folds the answers into state.json and posts
# one message per state change to #bot-health-check with the manager bot's
# token. It never restarts or stops anything.
#
# Run by the wrapper only:
#   claude-discord monitor [--ensure] <bot> [--holder tui|session <pid>]
# registers the holder (when given), then starts the monitor detached unless
# one already holds the lock. The monitor lives while a holder lives (the TUI,
# the manager session) and exits within one tick (30 s) of the last one.
#
# Everything it keeps is under ~/.claude-discord/records/monitor/<bot>/:
#   lock                       the flock target (fd 9 of the monitor)
#   state.json (+ .tmp)        what the TUI shows; `posted` makes a restart quiet
#   monitor.log, monitor.log.1 256 KiB each at most
#   holders/<kind>-<pid>       "<pid> <start time> <kind>"
#   pass.out                   one host's answer, only during a pass
# Nothing in /tmp: no mktemp and no here-document or here-string anywhere in
# this file (bash 3.2 backs both with a temp file).
# Runs under macOS /bin/bash 3.2: no associative arrays, no fractional read -t.
set -u
self=${1:?wrapper path}; shift
alert_channel=1558283274487341137   # #bot-health-check: both owners' managers post here; write-only
locked=no kind="" hpid="" bot=""
while [ $# -gt 0 ]; do
  case $1 in
    --ensure) ;;
    --locked) locked=yes;;   # internal: this process holds the lock on fd 9
    --holder) kind=${2:-} hpid=${3:-}; shift 3 2>/dev/null || shift $#; continue;;
    -*) echo "usage: claude-discord monitor [--ensure] <bot> [--holder tui|session <pid>]" >&2; exit 2;;
    *) bot=$1;;
  esac
  shift
done
case $bot in ''|.|..|*/*) echo "usage: claude-discord monitor [--ensure] <bot> [--holder tui|session <pid>]" >&2; exit 2;; esac
dir=$PWD/.claude/discord-agents/$bot
# The ledger is the on/off switch: no hosts file, no monitor.
[ -f "$dir/hosts" ] && [ -f "$dir/.env" ] || { echo "claude-discord: monitor: $dir has no hosts ledger (claude-discord setup $bot --mode writes one)" >&2; exit 1; }
M=$HOME/.claude-discord/records/monitor/$bot
umask 077
mkdir -p "$M/holders" || exit 1

# lstart <pid>: the process's start time. A pid alone can be reused; a pid
# with its start time cannot. Linux: field 22 of /proc/<pid>/stat, read with
# no fork (this runs every tick); elsewhere `ps -o lstart=`, whitespace
# collapsed ("Oct  1" has two spaces). Prints nothing for no such process
# (or, on Linux, for a zombie no parent has reaped yet).
lstart() {
  local st
  if [ -r "/proc/$1/stat" ]; then
    { read -r st < "/proc/$1/stat"; } 2>/dev/null || return 0
    set -f; set -- ${st##*) }; set +f   # after "<pid> (<comm>) ", which may hold spaces: field 3 on
    [ "${1:-}" = Z ] || echo "${20:-}"   # a zombie is dead, whatever kill -0 says
  else
    set -- $(ps -o lstart= -p "$1" 2>/dev/null); echo "$*"
  fi
}

if [ -n "$kind$hpid" ]; then
  case $kind in tui|session) ;; *) echo "claude-discord: monitor: --holder takes tui or session, got '$kind'" >&2; exit 2;; esac
  case $hpid in ''|*[!0-9]*) echo "claude-discord: monitor: --holder needs a pid, got '$hpid'" >&2; exit 2;; esac
  st=$(lstart "$hpid")
  [ -n "$st" ] || { echo "claude-discord: monitor: no process $hpid to hold for" >&2; exit 1; }
  printf '%s %s %s\n' "$hpid" "$st" "$kind" > "$M/holders/$kind-$hpid"
fi

if [ "$locked" = no ]; then
  # flock through perl: flock(1) is util-linux and a manager may be a Mac.
  # One try at once, then perl forks and this returns, so a caller never
  # waits. The child (setsid, stdin closed, output appended to monitor.log,
  # the only trace a crash leaves) keeps trying for up to 5 s:
  # winning makes it the monitor, losing means one is running. The wait is the
  # exit race's cover: a holder that registers just as the old monitor leaves
  # (it saw no holder a moment earlier) gets the lock when that one is gone and
  # starts the next. The lock is dup'd to fd 9 (no close-on-exec), so it lives
  # exactly as long as the monitor process; the kernel drops it on any death.
  : >> "$M/lock"
  perl -MPOSIX -MFcntl=:flock -e '
    my $tries = int(shift(@ARGV) * 10 + 0.5);
    open(my $l, ">>", shift @ARGV) or exit 1;
    my $won = flock($l, LOCK_EX | LOCK_NB);
    defined(my $pid = fork()) or exit 1;
    exit 0 if $pid;
    POSIX::setsid();
    until ($won) { exit 0 if --$tries < 0; select(undef, undef, undef, 0.1); $won = flock($l, LOCK_EX | LOCK_NB); }
    POSIX::dup2(fileno($l), 9) == 9 or exit 1;
    exec @ARGV;' "${CLAUDE_DISCORD_MONITOR_LOCK_WAIT:-5}" "$M/lock" bash "$0" "$self" --locked "$bot" </dev/null >>"$M/monitor.log" 2>&1
  exit 0
fi

# ---- the monitor itself (fd 9 holds the lock) ------------------------------
# Every child that can outlive a moment (sleep, ssh, the local health, curl)
# is started with 9>&-: a child that survived a crash would otherwise keep the
# lock and no new monitor could start.
# CLAUDE_DISCORD_MONITOR_LOCK_WAIT (above; 5) is the fourth interval the suite shortens.
tick=${CLAUDE_DISCORD_MONITOR_TICK:-30}        # holder check, seconds
pass=${CLAUDE_DISCORD_MONITOR_PASS:-300}       # a pass at most this often; health's unknown_cap=6 assumes 300
cap=${CLAUDE_DISCORD_MONITOR_HOST_CAP:-90}     # per host, enforced here (no timeout(1) on macOS)
# Fractional values are for the suite; bash counts in whole steps. A running
# host is polled every step (1 s, or a fifth of a tick shorter than 5 s).
read -r step pass_n cap_n tick_n < <(awk -v t="$tick" -v p="$pass" -v c="$cap" 'BEGIN {
  s = (t < 5 ? t / 5 : 1); printf "%s %d %d %d\n", s, (p / t < 1 ? 1 : int(p / t + 0.5)), int(c / s + 0.5), int(t / s + 0.5) }')
child="" state="" local_env=() h_rc=0 p_code=000 p_retry=""

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
# One line per event; never a message body, a header or a token. $ts, when set, stamps a burst of lines with one date.
log() { printf '%s %s\n' "${ts:-$(now)}" "$*" >> "$M/monitor.log" 2>/dev/null || :; }
# The cap, checked once per pass and at start: past 256 KiB the log becomes monitor.log.1, replacing the one before.
rotate() {
  local sz
  sz=$(wc -c < "$M/monitor.log" 2>/dev/null) || sz=0
  [ "${sz:-0}" -lt 262144 ] || mv -f "$M/monitor.log" "$M/monitor.log.1" 2>/dev/null || :
}
write_state() { printf '%s\n' "$state" > "$M/state.json.tmp" 2>/dev/null && mv -f "$M/state.json.tmp" "$M/state.json" 2>/dev/null || :; }
# read_cfg: lang and mowner from the manager project's config.env (KEY='value'
# or KEY=value), with no fork: ALERT_LANG (en in any case, anything else ko)
# and DISCORD_USER_ID, the owner a host-level finding mentions.
read_cfg() {
  local l v
  lang=ko mowner=""
  while IFS= read -r l || [ -n "$l" ]; do
    v=${l#*=}; v=${v#\'}; v=${v%\'}
    case $l in
      ALERT_LANG=*) case $v in [eE][nN]) lang=en;; *) lang=ko;; esac;;
      DISCORD_USER_ID=*) mowner=$v;;
    esac
  done < "$dir/../config.env" 2>/dev/null
}

# holders_alive: removes the records of dead holders; 0 when one still lives.
holders_alive() {
  local f p rest alive=1
  for f in "$M"/holders/*; do
    [ -f "$f" ] || continue
    p="" rest=""
    read -r p rest < "$f" 2>/dev/null || :
    case $p in ''|*[!0-9]*) rm -f "$f"; continue;; esac
    if kill -0 "$p" 2>/dev/null && [ "$(lstart "$p")" = "${rest% *}" ]; then alive=0; else rm -f "$f"; fi
  done
  return $alive
}
# Read twice before giving up: a holder may have registered just now.
no_holders() { holders_alive && return 1; holders_alive && return 1; return 0; }
holders_json() {  # sets hj: the holder records as a JSON array, with no fork
  local f b
  hj=""
  for f in "$M"/holders/*; do
    [ -f "$f" ] || continue
    b=${f##*/}; hj="$hj${hj:+,}{\"kind\":\"${b%%-*}\",\"pid\":${b##*-}}"
  done
  hj="[$hj]"
}
finish() {  # $1 = reason: kill the pass child, leave a state that reads as stopped, drop the holder records
  [ -z "$child" ] || kill "$child" 2>/dev/null
  rm -f "$M/pass.out"
  state=$(printf '%s' "$state" | jq -c --arg now "$(now)" '.monitor.pid = null | .monitor.holders = [] | .monitor.stopped_at = $now' 2>/dev/null) && write_state
  # On no-holders every record left was dead and is already gone; a record
  # that appears now belongs to a holder whose --ensure is waiting for this
  # lock, so it stays for the monitor that ensure starts. On a signal the
  # monitor is being taken down, and no record may outlive it.
  [ "$1" = no-holders ] || rm -f "$M"/holders/* 2>/dev/null
  log "exit reason=$1"
  exit 0
}
trap 'finish signal' TERM INT HUP

# post <payload JSON>: one message to the alert channel with the manager
# bot's token, read at POST time and sent on stdin, never argv. Sets p_code.
# A 429 with retry_after under 10 s is waited out once; anything else failed
# is left for the next pass (the caller keeps `posted` as it was).
post() {
  local tok="" line out try ra
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in DISCORD_BOT_TOKEN=*) tok=${line#DISCORD_BOT_TOKEN=}; break;; esac
  done < "$dir/.env"
  [ -n "$tok" ] || { p_code="000 (no DISCORD_BOT_TOKEN in $dir/.env)" p_retry=""; return 1; }
  for try in 1 2; do
    p_retry=""
    out=$(printf 'Authorization: Bot %s\n' "$tok" | env ${local_env[@]+"${local_env[@]}"} curl -s --max-time 10 -w '\n%{http_code}' \
      -X POST -H @- -H 'Content-Type: application/json' --data-binary "$1" \
      "https://discord.com/api/v10/channels/$alert_channel/messages" 2>/dev/null 9>&-) || out=""
    p_code=${out##*$'\n'}
    case $p_code in ''|*[!0-9]*) p_code=000;; esac
    case $p_code in 2*) return 0;; esac
    [ "$p_code" = 429 ] || return 1
    ra=$(printf '%s' "${out%$'\n'*}" | jq -r '.retry_after // 99' 2>/dev/null) || ra=99
    p_retry=$ra
    [ "$try" = 1 ] && awk -v r="$ra" 'BEGIN { exit !(r + 0 < 10) }' || return 1
    sleep "$ra" 9>&-
  done
  return 1
}

# run_host: one host's health document into $M/pass.out, its exit status in
# h_rc (124 = the per-host cap). The child is polled, never waited on: the
# holder check keeps running every tick while a host is slow. ssh's own
# failure is exit 255, and only that is retried, once, with ControlPath=none
# (a stale master refuses falsely) and counts as hostdown. Any other status
# without a document is the remote command's (claude-discord missing or too
# old), which is blind; so is the cap, since ConnectTimeout=8 already bounds
# the connection: a host that reaches the cap connected and never finished.
# Except a laptop's: one asleep behind its reverse tunnel can hang the forward
# past the cap, and a laptop's unreachability is never posted (hostdown).
run_host() {  # uses $host $remote and the envs array
  local t k
  for t in first retry; do
    if [ "$host" = local ]; then
      env ${envs[@]+"${envs[@]}"} "$HOME/.local/bin/claude-discord" health --all --json --patch > "$M/pass.out" 2>/dev/null < /dev/null 9>&- &
    elif [ "$t" = first ]; then
      ssh -o BatchMode=yes -o ConnectTimeout=8 "$host" "$remote" > "$M/pass.out" 2>/dev/null < /dev/null 9>&- &
    else
      ssh -o BatchMode=yes -o ConnectTimeout=8 -o ControlPath=none "$host" "$remote" > "$M/pass.out" 2>/dev/null < /dev/null 9>&- &
    fi
    child=$! k=0
    while kill -0 "$child" 2>/dev/null; do
      k=$((k + 1))
      if [ "$k" -gt "$cap_n" ]; then
        kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; child="" h_rc=124
        log "host $host no answer within ${cap}s"
        return 0
      fi
      [ $((k % tick_n)) != 0 ] || ! no_holders || finish no-holders
      sleep "$step" 9>&-
    done
    wait "$child" 2>/dev/null; h_rc=$?; child=""
    [ "$h_rc" = 255 ] && [ "$host" != local ] && [ "$t" = first ] || return 0
    log "host $host ssh-failed rc=255 (retried with ControlPath=none)"
  done
}

# The reducer: (state, this pass's host results) -> the new state, the log
# events and the messages to post. One jq program, so every rule of "what
# counts as a real failure" is in one place:
#   - a finding is posted once it has held for its hold time and differs
#     from what the channel was last told (`posted`);
#   - the first ok or busy after a posted finding posts the recovery line;
#   - noreach is never posted; a laptop's hostdown is never posted;
#   - while a host is noreach, hostdown or blind its bots are frozen;
#   - a bot or a host that left the answer is dropped, not announced.
# Input, raw lines: the state JSON, then two lines per host, "<host> US <laptop> US <exit status>" and the host's
# answer with its newlines made spaces (still valid JSON when it was).
# Output lines: "S<state JSON>", "N<bot count>", "E<event>", "O<scope US key US kind US verdict US payload JSON>".
reduce='
def hold: {"down": 300, "duplicate": 300, "unreachable": 300, "throttled": 1800, "apierror": 1800,
           "stale": 0, "nostate": 0, "patchfail": 0, "hostdown": 1800, "blind": 300};
def good: . == "ok" or . == "busy";
def short($home): if $home != "" and startswith($home + "/") then "~" + .[($home | length):] else . end;
# A path with anything but plain characters goes in double quotes, with what the shell would still expand escaped.
def cdp: (.home // "") as $h | (.project | short($h)) as $s
  | if ($s | test("^[A-Za-z0-9._/~+-]+$")) then $s else "\"" + (.project | gsub("(?<c>[\\\\\"$`])"; "\\\(.c)")) + "\"" end;
def cd: if .host == "local" then "claude-discord" else "~/.local/bin/claude-discord" end;
def wrap($e): if $e.host == "local" then . else "ssh \($e.host) \u0027\(gsub("\u0027"; "\u0027\\\u0027\u0027"))\u0027" end;
def fix: . as $e
  | if   .verdict == "down"        then ("cd \(cdp) && \(cd) --bg --name \(.bot)" | wrap($e))
    elif .verdict == "stale"       then ("cd \(cdp) && \(cd) refresh \(.bot) --force" | wrap($e))
    elif .verdict == "duplicate"   then (if .host == "local" then "" else "on \(.host): " end) + "claude agents, then claude stop <id> for the copy that is not the bot\u0027s"
    elif .verdict == "unreachable" then "check DISCORD_BOT_TOKEN in \(.project)/.claude/discord-agents/\(.bot)/.env and the bot\u0027s channel permissions"
    elif .verdict == "nostate"     then (if .host == "local" then "" else "on \(.host): " end) + "claude agents by hand; the daemon is unwell"
    elif .verdict == "throttled" or .verdict == "apierror" then ("cd \(cdp) && \(cd) health" | wrap($e))
    elif .verdict == "patchfail"   then ("\(cd) update" | wrap($e)) + "; still failing means the patch needs a claude-discord fix"
    elif .verdict == "hostdown"    then "ssh -o BatchMode=yes -o ConnectTimeout=8 -o ControlPath=none \(.host) \u0027echo up\u0027"
    elif .verdict == "blind"       then "ssh \(.host) \u0027~/.local/bin/claude-discord --version\u0027, then setup or update there"
    else "" end;
def labels: if $lang == "en" then {reason: "reason", fix: "fix"} else {reason: "사유", fix: "복구"} end;
def subject: (.home // "") as $h | if .bot then "\(.bot) on \(.name) (\(.project | short($h)))" else .name end;
def finding_text: labels as $l
  | ((if (.owner_id // "") != "" then "<@\(.owner_id)> " else "" end)
     + "[\(.verdict)] \(subject)\n\($l.reason): \(.detail)\n\($l.fix): \(.fix)") | .[0:1900];
# The recovery line has no label, so it reads the same in both languages.
def recovery_text: ((($now_s - (.posted_since_s // $now_s)) / 60) | floor) as $m
  | "[recovered] \(subject): answering again after \($m)m (was \(.posted))" | .[0:1900];
def payload($kind): if $kind == "finding"
  then {content: finding_text, allowed_mentions: (if (.owner_id // "") != "" then {users: [.owner_id]} else {parse: []} end)}
  else {content: recovery_text, allowed_mentions: {parse: []}} end;
# observe: fold one observation into an entry; `since` moves only when the verdict changes.
def observe($v; $d; $meta): (. // {}) as $o
  | $o + $meta + {verdict: $v, detail: $d}
  | if ($o.verdict // null) != $v then . + {since: $now, since_s: $now_s} else . end
  | . + {fix: fix};
def due: . as $e
  | if (.verdict | good) and (.posted // null) != null then "recovery"
    elif (hold[.verdict] != null) and ((.verdict == "hostdown" and .laptop == true) | not)
         and (.posted // null) != .verdict and ($now_s - .since_s) >= hold[.verdict] then "finding"
    else null end;

[inputs] as $in
| ($in[0] | fromjson) as $old
| [range(1; $in | length - 1; 2) as $i | ($in[$i] | split("\u001f")) as $h
   | {host: $h[0], laptop: ($h[1] == "true"), rc: ($h[2] | tonumber), doc: ($in[$i + 1] | try fromjson catch null)}] as $res
| ($res | map(.host)) as $ledger
| reduce $res[] as $r ({state: $old, events: [], frozen: []};
    ($r.doc | if type == "object" and (.projects | type) == "array" then . else null end) as $doc
    | ([$doc.projects[]? | .project as $p | .bots[]? | . + {project: $p}]) as $bots
    | (if $r.rc == 255 or ($r.rc == 124 and $r.laptop) then "hostdown"
       elif $doc == null then "blind"
       elif ($bots | length) > 0 and all($bots[]; .verdict == "noreach") then "noreach"
       else "ok" end) as $reach
    | (if $reach == "hostdown" or $reach == "blind" then $reach
       elif ($doc.patch.rc // 0) != 0 then "patchfail"
       else $reach end) as $hv
    | (if $hv == "hostdown" and $r.rc == 124 then "no answer from \($r.host) within the per-host limit (a laptop: asleep behind its tunnel?)"
       elif $hv == "hostdown" then "ssh to \($r.host) failed (exit 255), also with ControlPath=none"
       elif $hv == "blind" and $r.rc == 124 then "\($r.host) connected but health --all did not finish within the per-host limit"
       elif $hv == "blind" then "\($r.host) answered without a health document (exit \($r.rc)): claude-discord is missing there or older than health --all"
       elif $hv == "patchfail" then (($doc.patch.output // "") | gsub("\n"; " | "))
       elif $hv == "noreach" then "\($r.host) cannot reach Discord"
       else "" end) as $hd
    | (.state.hosts[$r.host].verdict // null) as $was
    | .state.hosts[$r.host] |= observe($hv; $hd;
        {host: $r.host, name: (if $r.host == "local" then ($doc.host // (.name // "local")) else $r.host end),
         laptop: $r.laptop, reach: $reach, owner_id: $mowner, checked: $now}
        + (if $doc != null then {version: ($doc.version // "?"), patch: (if $doc.patch == null then "-" elif ($doc.patch.rc // 0) == 0 then "ok" else "fail" end)} else {} end))
    | (if $was != $hv and ($was != null or ($hv | good | not)) then .events += ["transition \($r.host)|- \($was // "new")->\($hv)"] else . end)
    | if $reach != "ok" then .frozen += [$r.host]
      else
        ($bots | map("\($r.host)|\(.project)|\(.bot)")) as $present
        | reduce $bots[] as $b (.;
            "\($r.host)|\($b.project)|\($b.bot)" as $k
            | (.state.bots[$k].verdict // null) as $bw
            | .state.bots[$k] |= observe($b.verdict; ($b.detail // "");
                {host: $r.host, name: (if $r.host == "local" then ($doc.host // "local") else $r.host end),
                 project: $b.project, bot: $b.bot, home: ($doc.home // ""), owner_id: ($b.owner_id // ""), servers: ($b.servers // "")})
            | if $bw != $b.verdict and ($bw != null or ($b.verdict | good | not)) then .events += ["transition \($k) \($bw // "new")->\($b.verdict)"] else . end)
        | ([.state.bots | to_entries[] | select(.value.host == $r.host and ((.key as $k | $present | index($k)) == null)) | .key]) as $gone
        | .events += ($gone | map("drop \(.)"))
        | .state.bots |= with_entries(select(.key as $k | ($gone | index($k)) == null))
      end)
| .frozen as $frozen
# a host that left the ledger takes its entry and its bots with it
| .state.hosts |= with_entries(select(.key as $k | ($ledger | index($k)) != null))
| .state.bots |= with_entries(select(.value.host as $h | ($ledger | index($h)) != null))
| .state.monitor += {last_pass: $now, next_pass: (($now_s + $every) | floor | todate), pass_s: $pass_s, holders: $holders, post_failed: false}
| .state as $s | .events as $ev
| ([$s.hosts | to_entries[] | {scope: "hosts", key: .key, e: .value}]
   + [$s.bots | to_entries[] | select(.value.host as $h | ($frozen | index($h)) == null) | {scope: "bots", key: .key, e: .value}]) as $all
| "S" + ($s | tojson), "N\($s.bots | length)",
  ($ev[] | "E" + .),
  ($all[] | . as $x | ($x.e | due) as $kind | select($kind != null)
   | "O" + ([$x.scope, $x.key, $kind, (if $kind == "finding" then $x.e.verdict else $x.e.posted end), ($x.e | payload($kind) | tojson)] | join("\u001f")))
'
# apply: the POST results back into the state. A sent finding sets `posted`
# (what makes a restart, and the next pass, quiet); a sent recovery clears it;
# a failed one changes nothing, so the next pass tries again.
apply='
($results | split("\n") | map(select(. != "") | split("\u001f") | {scope: .[0], key: .[1], kind: .[2], verdict: .[3], status: .[4]})) as $rs
| reduce $rs[] as $r (.;
    (if $r.status != "sent" then .
     elif $r.kind == "finding" then .[$r.scope][$r.key] |= (. + {posted: .verdict, posted_at: $now, posted_since_s: .since_s})
     else .[$r.scope][$r.key] |= del(.posted, .posted_at, .posted_since_s) end)
    | .alerts += [{ts: $now, key: (if $r.scope == "hosts" then $r.key + "|-" else $r.key end), kind: $r.kind, verdict: $r.verdict, status: $r.status}])
| .alerts |= .[-50:]
| .monitor.post_failed = any($rs[]; .status == "failed")
'

run_pass() {
  local t0=$SECONDS now_s line w host laptop remote doc results="" out l rest scope key knd verdict payload posts="" hosts=0 nb=0 findings=0 posted=0 lang mowner ts="" hj
  local envs=()
  rotate
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}   # a ledger saved with CRLF line endings
    set -f; set -- $line; set +f
    host=${1:-}; [ $# = 0 ] || shift
    case $host in ''|'#'*) continue;; esac
    # An ssh host name, never an option: the ledger is the owner's file, but a leading "-" would be read by ssh as a flag.
    case $host in -*|*[!A-Za-z0-9._@-]*) log "ledger: host skipped (not a plain ssh host name)"; continue;; esac
    laptop=false; [ "${1:-}" != laptop ] || { laptop=true; shift; }
    envs=()
    for w in "$@"; do
      if [[ $w =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then envs+=("$w"); else log "ledger: $host: a word that is not KEY=VALUE was skipped"; fi
    done
    [ "$host" != local ] || local_env=(${envs[@]+"${envs[@]}"})
    remote="env $([ ${#envs[@]} = 0 ] || printf '%q ' "${envs[@]}")~/.local/bin/claude-discord health --all --json --patch"
    run_host
    doc=$(< "$M/pass.out") 2>/dev/null || doc=""
    results="$results$host"$'\x1f'"$laptop"$'\x1f'"$h_rc"$'\n'"${doc//$'\n'/ }"$'\n'
    hosts=$((hosts + 1))
  done < "$dir/hosts"
  rm -f "$M/pass.out"
  read_cfg; holders_json
  read -r now_s ts < <(date -u '+%s %Y-%m-%dT%H:%M:%SZ')
  out=$(printf '%s\n%s' "$state" "$results" | jq -nrR --arg now "$ts" --argjson now_s "$now_s" --arg lang "$lang" --arg mowner "$mowner" \
    --argjson every "$pass" --argjson pass_s "$(( SECONDS - t0 ))" --argjson holders "$hj" "$reduce" 2>/dev/null) ||
    { log "pass failed: the reducer rejected its input"; return 0; }
  while IFS= read -r l; do
    rest=${l#?}
    case $l in
      S*) state=$rest;;
      N*) nb=$rest;;
      E*) log "$rest";;
      O*) IFS=$'\x1f' read -r scope key knd verdict payload < <(printf '%s\n' "$rest")
          [ "$knd" != finding ] || findings=$((findings + 1))
          [ "$scope" != hosts ] || key="$key|-"
          if post "$payload"; then
            posted=$((posted + 1)); log "post $key $verdict $p_code"
            posts="$posts$scope"$'\x1f'"${key%|-}"$'\x1f'"$knd"$'\x1f'"$verdict"$'\x1f'sent$'\n'
          else
            log "post $key $verdict failed $p_code${p_retry:+ retry_after=$p_retry}"
            posts="$posts$scope"$'\x1f'"${key%|-}"$'\x1f'"$knd"$'\x1f'"$verdict"$'\x1f'failed$'\n'
          fi;;
    esac
  done < <(printf '%s\n' "$out")
  if [ -n "$posts" ]; then
    state=$(printf '%s' "$state" | jq -c --arg results "$posts" --arg now "$ts" "$apply" 2>/dev/null) || { log "pass failed: could not apply the results"; return 0; }
  fi
  write_state
  log "pass hosts=$hosts bots=$nb findings=$findings posted=$posted $(( SECONDS - t0 ))s"
}

rotate
# Start from the kept state (its `posted` is what keeps a restart quiet). A
# state file that is not ours (truncated, another version, another manager)
# starts empty and says so: findings still standing are then posted once more.
state=$(jq -c --arg bot "$bot" 'if type == "object" and .version == 1 and .manager == $bot then . else error("no") end' "$M/state.json" 2>/dev/null) || {
  [ ! -s "$M/state.json" ] || log "state unreadable, starting empty"
  state=$(jq -nc --arg bot "$bot" '{version: 1, manager: $bot, monitor: {}, hosts: {}, bots: {}, alerts: []}')
}
holders_json
state=$(printf '%s' "$state" | jq -c --argjson pid "$$" --arg now "$(now)" --argjson holders "$hj" \
  '.monitor = ((.monitor // {}) + {pid: $pid, started: $now, holders: $holders}) | del(.monitor.stopped_at)')
write_state
log start
n=$pass_n   # the first pass right after start
while :; do
  [ -f "$dir/hosts" ] || finish no-ledger
  ! no_holders || finish no-holders
  if [ "$n" -ge "$pass_n" ]; then run_pass; n=0; fi
  sleep "$tick" 9>&-
  n=$((n + 1))
done
```

- [ ] **Step 4: Run the suite.** Expected: `ALL PASS` with `ok: monitor: every row of the failure table ...` and `ok: monitor: a failed POST is logged, ...`.

- [ ] **Step 5: Mutation check.** Each revert alone fails with:
  - the laptop exception in `due` dropped, a hold set to 0, `due`'s recovery branch disabled, `noreach` given a hold, or the frozen-host filter dropped: `FAIL: one pass must post exactly the 15 due findings and recoveries` (or, for the frozen filter, `FAIL: a hostdown or noreach host's bots are frozen`)
  - `since` kept across a verdict change: `FAIL: one pass must post exactly the 15 due findings and recoveries`
  - the `posted` update in `apply` dropped: `FAIL: the restart must post only what is new ...`
  - the 1900 cut dropped: `FAIL: a message is cut to 1900 characters`
  - a recovery that mentions the owner: `FAIL: a recovery line pings nobody`
  - a finding that always mentions: `FAIL: a bot with no owner_id is posted with no mention and pings nobody`
  - the token as a `-H` argument: `FAIL: the manager's token goes on curl's stdin, never argv`
  - `post()` without the ledger's local env: `FAIL: a POST runs with the ledger's local env (the proxy)`
  - the quoting in `cdp` or `wrap` dropped: `FAIL: a project path with a space, a quote and a $ must be quoted for both shells`
  - `rc == 124` counted as hostdown for every host: `FAIL: a host that connected and went silent past the cap is blind, not hostdown`; the laptop part dropped: `FAIL: one pass must post exactly the 15 ...`
  - the 429 wait dropped: `FAIL: the restart must post only what is new (nf, twice: the 429 then its retry) ...`
  - `post_failed` dropped: `FAIL: a failed POST leaves the finding unposted and shows the failure`
  - the ledger filter on hosts dropped: `FAIL: hosts left out of the ledger, and bots gone from an answer, are dropped from the state`
  - `[eE][nN]` made `en`: `FAIL: ALERT_LANG=EN must give English labels`
  - the no-token reason dropped: `FAIL: a POST with no token in the manager's .env must fail before curl, logged with the reason`
  - the ledger host-name check dropped: `FAIL: a ledger line that is not a plain host name must be skipped, never passed to ssh`

- [ ] **Step 6: Commit**

```bash
git commit -m "monitor posts: one message per state change to #bot-health-check with the manager's token on stdin (owner mention, reason, recovery command; recovery line pings nobody; 1900-character cut), holds per finding, laptops never post hostdown, frozen hosts, a failed POST retried next pass (429 under 10 s waited), ALERT_LANG ko|en" -m "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>" -- monitor/monitor.sh test-claude-discord.sh
```

---
### Task 8: the manager session holds the monitor (SessionStart)

**Files:**
- Modify: `hooks/lib/discord.sh` (append `session_pid`)
- Modify: `hooks/turn/on-session-start` (after the line that prints the SessionStart context)
- Test: `test-claude-discord.sh` (two blocks before the section's cleanup)

**Interfaces:**
- Produces: `session_pid` (in `hooks/lib/discord.sh`): prints the pid of the nearest ancestor within two levels whose argv[0] is `claude`, `*/claude` or `*/claude/versions/*` and whose argv[1] is not `daemon`; prints nothing otherwise. The hook: for a `dev-manager` bot with `<bot>/hosts`, at every source, `claude-discord monitor --ensure <bot> --holder session <pid>`, detached with stdio closed.
- Consumes: Task 6's `monitor --ensure ... --holder`.

HARD HOME RULE (repeat verbatim in this task's dispatch prompt): any probe outside the test suite sets a literal sandbox HOME in the SAME Bash call, chained with &&; never write the real ~/.claude.json, ~/.claude, ~/.claude-discord or ~/.local/bin; run hand-run hooks/tools with env -u DISCORD_STATE_DIR.

- [ ] **Step 1: Write the failing tests.** Insert immediately before the line `# The monitor blocks end here: the real shim back, the stubs and fixtures gone.`:

```bash
# The session a SessionStart hook belongs to: the nearest ancestor, two levels at most, whose argv[0] is .../claude or
# under .../claude/versions/ and whose argv[1] is not daemon. Process chains are built with perl's $0 (what ps shows),
# outermost first; the innermost runs session_pid in a bash child and prints the title of what it found.
FK="$HOME/fk"
chain() {
  perl -e '
    my ($lib, @titles) = @ARGV;
    for my $t (@titles) { my $pid = fork(); if ($pid) { waitpid($pid, 0); exit 0; } $0 = $t; }
    system("bash", "-c", ". \"\$1\"; p=\$(session_pid); t=none; [ -z \"\$p\" ] || IFS= read -r -d \"\" t < /proc/\$p/cmdline; echo \"\$t\"", "x", $lib);' "$D/hooks/lib/discord.sh" "$@"
}
[ "$(chain "$FK/bin/claude daemon" "$FK/claude/versions/9.9.9")" = "$FK/claude/versions/9.9.9" ] || { echo "FAIL: the nearest claude process, not the daemon above it: $(chain "$FK/bin/claude daemon" "$FK/claude/versions/9.9.9")"; exit 1; }
[ "$(chain "$FK/bin/claude daemon")" = none ] || { echo "FAIL: claude daemon is never the session"; exit 1; }
[ "$(chain "claude --name x" "sh -c hook")" = "claude --name x" ] || { echo "FAIL: a foreground claude through sh -c is the session"; exit 1; }
[ "$(chain "$FK/claude/versions/9.9.9" "sh -c a" "sh -c b")" = none ] || { echo "FAIL: a claude three levels up is not this hook's session"; exit 1; }
echo "ok: session_pid finds the nearest claude process within two levels, never claude daemon"

# The manager session's SessionStart (any source; compact here, which runs no patch) registers the session, its
# nearest claude ancestor, as a holder and ensures the monitor, detached; the monitor ends with that session. The
# session is a perl process titled .../claude/versions/9.9.9 that runs the hook as its child.
printf '{"session_id":"sMon","source":"compact"}' > "$HOME/ss.json"; echo dev-manager > "$MR/mgr/mode"   # the mode case above left it at none
want=$(( $(starts) + 1 ))
perl -e '$0 = shift @ARGV; open(STDIN, "<", shift @ARGV) or die; system(@ARGV); sleep 30' "$HOME/fk/claude/versions/9.9.9" "$HOME/ss.json" \
  env CLAUDE_PLUGIN_ROOT="$PC" CLAUDE_PROJECT_DIR="$MP" DISCORD_STATE_DIR="$MR/mgr" bash "$PC/hooks/turn/on-session-start" >/dev/null 2>&1 &
HPID=$!; KILL_AT_EXIT="$KILL_AT_EXIT $HPID"
wait_log "$want" 'Z start$'
[ -f "$MB/holders/session-$HPID" ] || { echo "FAIL: the manager's SessionStart must register its session as a holder: $(ls "$MB/holders")"; exit 1; }
mstop; rm -f "$HOME/ss.json"
echo "ok: a dev-manager's SessionStart registers its session (the nearest claude process) as a holder and starts the monitor, which exits with that session"
```

- [ ] **Step 2: Run them**

Run: `./test-claude-discord.sh ./bin/claude-discord 2>&1 | grep -m1 -E 'FAIL|ok: session_pid'`
Expected: `FAIL: the nearest claude process, not the daemon above it: ` (`session_pid` is not defined yet).

- [ ] **Step 3: Implement.** Append to `hooks/lib/discord.sh`:

```bash

# session_pid: the pid of the Claude Code CLI process this hook runs under: the
# nearest ancestor (two levels at most: Claude Code runs a hook directly or
# through sh -c) whose argv[0] is .../claude or lies under .../claude/versions/,
# and whose argv[1] is not `daemon`. Nearest, and capped: above a --bg session
# sit its --bg-pty-host and `claude daemon`, which never exits, and a
# terminal's own claude may sit above a script that runs a hook by hand.
# Prints nothing when there is none.
session_pid() {
  local p=$PPID n=0
  while [ "$n" -lt 2 ] && [ "${p:-0}" -gt 1 ]; do
    set -f; set -- $(ps -o ppid= -o args= -p "$p" 2>/dev/null); set +f   # ppid, argv[0], argv[1], ...
    [ $# -ge 2 ] || return 0
    case $2 in claude|*/claude|*/claude/versions/*)
      [ "${3:-}" = daemon ] || { printf '%s' "$p"; return 0; };;
    esac
    p=$1 n=$((n + 1))
  done
}
```

In `hooks/turn/on-session-start`, after the line `jq -nc --arg c "$ctx" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $c}}' 2>/dev/null || :` add:

```bash

# A manager bot with a hosts ledger holds its backend monitor open (every
# source: the session is alive at a compaction too): this session's pid goes
# in as a holder and the monitor is started if none runs. Detached, stdio
# closed, so the hook returns at once and leaves nothing on Claude Code's pipe.
if [ "$bot_mode" = dev-manager ] && [ -f "$DISCORD_STATE_DIR/hosts" ] && [ -x "$plugin_root/bin/claude-discord" ]; then
  spid=$(session_pid)
  [ -z "$spid" ] || (cd "$bot_project" && "$plugin_root/bin/claude-discord" monitor --ensure "$bot_name" --holder session "$spid") </dev/null >/dev/null 2>&1 &
fi
```

- [ ] **Step 4: Run the suite.** Expected: `ALL PASS` with `ok: session_pid finds the nearest claude process ...` and `ok: a dev-manager's SessionStart registers its session ...`. Hooks run by hand from the suite never reach a real claude: two levels above them are the suite's own shells.

- [ ] **Step 5: Mutation check.** Each revert alone fails with:
  - the `daemon` exclusion dropped: `FAIL: claude daemon is never the session`
  - the walk widened to three levels: `FAIL: a claude three levels up is not this hook's session`
  - the hook's `[ -z "$spid" ] ||` inverted: `FAIL: the monitor never logged 'Z start$' ...`

- [ ] **Step 6: Commit**

```bash
git commit -m "a dev-manager session with a hosts ledger holds its monitor: SessionStart registers the nearest claude process (two levels, never claude daemon; measured on lmd42 and wmac, foreground and --bg) and ensures the monitor, detached" -m "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>" -- hooks/lib/discord.sh hooks/turn/on-session-start test-claude-discord.sh
```

---
### Task 9: `claude-discord tui`, the README, the suite's time

**Files:**
- Create: `tui/claude_discord_tui.py`, `tests/tui/test_tui.py`
- Modify: `bin/claude-discord` (the `tui` verb after the `monitor` verb; one header usage entry)
- Modify: `README.md`
- Test: `test-claude-discord.sh` (one block before the section's cleanup)

**Interfaces:**
- Produces: `claude-discord tui [<bot>]`: from anywhere in the project; the bot defaults to the project's one dev-manager bot with a `hosts` file, asks at a terminal otherwise, exits 2 without one; exit 1 for a bot with no ledger or no uv (`CLAUDE_DISCORD_UV` overrides the uv command, for the suite). It execs `uv run --script <plugin>/tui/claude_discord_tui.py --bot <bot> --state-dir ~/.claude-discord/records/monitor/<bot> --claude-discord <wrapper>`. The TUI registers `holders/tui-<its pid>` through `monitor --ensure --holder tui`, re-reads `state.json` on an mtime change (every 2 s), and removes its record on quit.
- Consumes: Task 6's state file and verb, Task 7's fields (`posted`, `fix`, `alerts`, `post_failed`).

HARD HOME RULE (repeat verbatim in this task's dispatch prompt): any probe outside the test suite sets a literal sandbox HOME in the SAME Bash call, chained with &&; never write the real ~/.claude.json, ~/.claude, ~/.claude-discord or ~/.local/bin; run hand-run hooks/tools with env -u DISCORD_STATE_DIR.

- [ ] **Step 1: Write the failing tests.** Insert immediately before the line `# The monitor blocks end here: the real shim back, the stubs and fixtures gone.`:

```bash
# claude-discord tui: the project's one dev-manager bot with a ledger unless named; it hands the bot, the monitor's
# state dir and the wrapper to the TUI script through `uv run --script`. uv is needed for this verb only and its
# absence is said. The script itself is exercised outside the budget (tests/tui/test_tui.py).
echo dev-manager > "$MR/mgr/mode"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" > "$HOME/uv.args"\n' > "$HOME/bin/uv"; chmod +x "$HOME/bin/uv"
mkdir -p "$MP/sub/dir"   # from a subdirectory: the project is found above it
(cd "$MP/sub/dir" && bash "$S" tui 2>/dev/null) || { echo "FAIL: tui from a subdirectory of the project must find the project above it"; exit 1; }
[ "$(<"$HOME/uv.args")" = "run --script $PC/tui/claude_discord_tui.py --bot mgr --state-dir $MB --claude-discord $PC/bin/claude-discord" ] || { echo "FAIL: tui must run the script through uv with the bot, the state dir and the wrapper: $(cat "$HOME/uv.args" 2>&1)"; exit 1; }
rc=0; out=$(cd "$MP" && CLAUDE_DISCORD_UV=/nonexistent/uv bash "$S" tui mgr 2>&1) || rc=$?
[ "$rc" = 1 ] && grep -q 'tui needs uv' <<<"$out" || { echo "FAIL: without uv, tui must say so (rc=$rc): $out"; exit 1; }
rc=0; out=$(cd "$P" && bash "$S" tui alpha 2>&1) || rc=$?
[ "$rc" = 1 ] && grep -q 'no hosts ledger' <<<"$out" || { echo "FAIL: tui for a bot without a ledger must refuse (rc=$rc): $out"; exit 1; }
rc=0; out=$(cd "$P" && bash "$S" tui </dev/null 2>&1) || rc=$?
[ "$rc" = 2 ] && grep -q 'name the manager bot' <<<"$out" || { echo "FAIL: with no single manager bot and no terminal, tui must ask for the name (rc=$rc): $out"; exit 1; }
rm -f "$HOME/bin/uv" "$HOME/uv.args"
echo "ok: tui runs the script through uv for the project's one manager bot (or the named one, from a subdirectory too), says when uv is missing, refuses a bot without a ledger, and asks for the name when it cannot tell"
```

Create `tests/tui/test_tui.py` with exactly:

```python
# /// script
# requires-python = ">=3.9"
# dependencies = ["textual>=8.2.8,<9"]
# ///
"""Pilot tests for tui/claude_discord_tui.py over fixture state files. Outside
the 40 s stub suite (it needs uv and the Textual wheel):
    uv run --script tests/tui/test_tui.py
Exit 0 and one "ok:" line per case, or the first failure."""
import asyncio
import importlib.util
import json
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("tui", ROOT / "tui" / "claude_discord_tui.py")
tui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tui)

NOW = "2026-10-11T12:00:00Z"
BASE = {"version": 1, "manager": "mgr",
        "monitor": {"pid": 123, "started": NOW, "last_pass": NOW, "next_pass": NOW, "pass_s": 2,
                    "holders": [{"kind": "tui", "pid": 456}], "post_failed": False},
        "hosts": {"local": {"host": "local", "name": "lambda", "reach": "ok", "patch": "ok", "version": "1.10.0 (abc)",
                            "verdict": "ok", "checked": NOW, "laptop": False},
                  "wmac": {"host": "wmac", "name": "wmac", "reach": "ok", "patch": "ok", "version": "1.10.0 (abc)",
                           "verdict": "ok", "checked": NOW, "laptop": True}},
        "bots": {"local|/home/u/p|RVP": {"host": "local", "name": "lambda", "project": "/home/u/p", "home": "/home/u",
                                         "bot": "RVP", "verdict": "ok", "since": NOW, "detail": ""},
                 "wmac|/Users/u/p|MAC": {"host": "wmac", "name": "wmac", "project": "/Users/u/p", "home": "/Users/u",
                                         "bot": "MAC", "verdict": "ok", "since": NOW, "detail": "", "servers": "1"}},
        "alerts": []}


def variant(name):
    s = json.loads(json.dumps(BASE))
    if name == "findings":
        s["bots"]["wmac|/Users/u/p|MAC"].update(verdict="down", detail="no plugin server for this bot",
                                                fix="ssh wmac 'cd ~/p && ~/.local/bin/claude-discord --bg --name MAC'")
        s["alerts"] = [{"ts": NOW, "key": "wmac|/Users/u/p|MAC", "kind": "finding", "verdict": "down", "status": "sent"}]
    elif name == "stopped":
        s["monitor"].update(pid=None, stopped_at=NOW, holders=[])
    elif name == "post_failed":
        s["monitor"]["post_failed"] = True
    return s


async def case(name, check):
    with tempfile.TemporaryDirectory() as d:
        (Path(d) / "holders").mkdir()
        (Path(d) / "state.json").write_text(json.dumps(variant(name)))
        app = tui.MonitorTUI(Path(d), "mgr", None)
        async with app.run_test() as pilot:
            await pilot.pause()
            await check(app, pilot)
    print(f"ok: {name}")


def text(app, sel):
    return str(app.query_one(sel).render())


async def all_ok(app, pilot):
    assert "monitor pid 123" in text(app, "#head"), text(app, "#head")
    assert app.query_one("#bar").has_class("hidden")
    hosts = app.query_one("#hosts")
    assert hosts.row_count == 2
    # the Mac row: its bot counted from a ps -ax server count, so 1/1 ok
    assert [str(c) for c in hosts.get_row("wmac")][4] == "1/1"


async def findings(app, pilot):
    bots = app.query_one("#bots")
    assert [str(c) for c in bots.get_row_at(0)][3] == "down", "findings first"
    bots.focus()
    bots.move_cursor(row=0)
    await pilot.press("enter")
    await pilot.pause()
    assert isinstance(app.screen, tui.Detail)
    assert "claude-discord --bg --name MAC" in str(app.screen.query_one("#fix").render())
    await pilot.press("escape")
    await pilot.press("a")
    await pilot.pause()
    assert isinstance(app.screen, tui.Alerts) and app.screen.query_one("#alerts").row_count == 1


async def stopped(app, pilot):
    assert not app.query_one("#bar").has_class("hidden")
    assert f"monitor stopped at {NOW}" in text(app, "#bar")


async def post_failed(app, pilot):
    assert "POST" in text(app, "#bar")


async def main():
    await case("all_ok", all_ok)
    await case("findings", findings)
    await case("stopped", stopped)
    await case("post_failed", post_failed)
    # q removes the holder record
    with tempfile.TemporaryDirectory() as d:
        (Path(d) / "holders").mkdir()
        (Path(d) / "state.json").write_text(json.dumps(BASE))
        app = tui.MonitorTUI(Path(d), "mgr", None)
        app.holder.write_text("x")
        async with app.run_test() as pilot:
            await pilot.press("q")
        assert not app.holder.exists(), "quit must remove the holder record"
    print("ok: quit removes its holder record")


asyncio.run(main())
```

- [ ] **Step 2: Run them**

Run: `./test-claude-discord.sh ./bin/claude-discord 2>&1 | grep -m1 -E 'FAIL|ok: tui runs'`
Expected: `FAIL: tui from a subdirectory of the project must find the project above it` (`tui` is read as a bot name).

- [ ] **Step 3: Implement.** Create `tui/claude_discord_tui.py` with exactly:

```python
# /// script
# requires-python = ">=3.9"
# dependencies = ["textual>=8.2.8,<9"]
# ///
"""claude-discord tui: a read-only view of a manager bot's backend monitor.

Started by `claude-discord tui [<bot>]` through `uv run --script`. It registers
itself as a holder of the monitor (which starts the monitor if none runs),
re-reads state.json when its mtime changes (checked every 2 s) and removes its
holder record on quit. It changes nothing else: no restart, no post, no patch,
and it never reads a .env, so it cannot show a token.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import VerticalScroll
from textual.screen import Screen
from textual.widgets import DataTable, Footer, Static

GOOD = ("ok", "busy")


def load(path: Path) -> dict:
    try:
        data = json.loads(path.read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def ago(iso: str | None) -> str:
    """'12m', '3h', '2d' since an ISO time; '' when unknown."""
    if not iso:
        return ""
    try:
        t = datetime.strptime(iso, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return ""
    s = max(0, int(time.time() - t.timestamp()))
    return f"{s // 60}m" if s < 7200 else (f"{s // 3600}h" if s < 172800 else f"{s // 86400}d")


def short(project: str, home: str) -> str:
    return "~" + project[len(home):] if home and project.startswith(home + "/") else project


def header_lines(state: dict) -> tuple[str, str | None]:
    """The header text and the red bar's text (None when there is nothing to warn about)."""
    m = state.get("monitor") or {}
    holders = ", ".join(f"{h.get('kind')} {h.get('pid')}" for h in m.get("holders") or []) or "none"
    pid = m.get("pid")
    text = (f"manager {state.get('manager', '?')}   monitor pid {pid if pid else '-'}   holders {holders}\n"
            f"last pass {m.get('last_pass') or '-'}   next pass {m.get('next_pass') or '-'}   pass took {m.get('pass_s', '-')}s")
    bar = None
    if not state:
        bar = "no state yet: the monitor has not written state.json"
    elif not pid:
        bar = f"monitor stopped at {m.get('stopped_at') or '?'}"
    elif m.get("post_failed"):
        bar = "the last POST to #bot-health-check failed; it is retried next pass"
    return text, bar


def bot_rows(state: dict) -> list[tuple[str, tuple]]:
    """(key, row) for the bots table, findings first, then by key."""
    bots = state.get("bots") or {}
    def order(item):
        key, b = item
        return (b.get("verdict") in GOOD, key)
    rows = []
    for key, b in sorted(bots.items(), key=order):
        rows.append((key, (b.get("name") or b.get("host", ""), short(b.get("project", ""), b.get("home", "")),
                           b.get("bot", ""), b.get("verdict", ""), ago(b.get("since")), b.get("detail", ""))))
    return rows


def host_rows(state: dict) -> list[tuple[str, tuple]]:
    bots = state.get("bots") or {}
    rows = []
    for key, h in sorted((state.get("hosts") or {}).items()):
        mine = [b for b in bots.values() if b.get("host") == key]
        ok = sum(1 for b in mine if b.get("verdict") in GOOD)
        label = h.get("name") or key
        if h.get("laptop"):
            label += " (laptop)"
        rows.append((key, (label, h.get("reach", ""), h.get("patch", ""), h.get("version", ""),
                           f"{ok}/{len(mine)}", h.get("checked", ""))))
    return rows


class Detail(Screen):
    BINDINGS = [Binding("escape", "app.pop_screen", "back")]

    def __init__(self, key: str, alert_key: str, entry: dict, alerts: list) -> None:
        super().__init__()
        self.key, self.alert_key, self.entry, self.alerts = key, alert_key, entry, alerts

    def compose(self) -> ComposeResult:
        e = self.entry
        lines = [f"{self.key}", "", f"verdict  {e.get('verdict', '')} (since {e.get('since', '?')})",
                 f"detail   {e.get('detail', '')}", f"posted   {e.get('posted') or '-'}", "", "recovery command:"]
        with VerticalScroll():
            yield Static("\n".join(lines))
            yield Static(e.get("fix") or "(none)", id="fix")   # its own widget so the text can be selected and copied
            mine = [a for a in self.alerts if a.get("key") == self.alert_key]
            yield Static("\nposts for this key:\n" + ("\n".join(
                f"{a.get('ts')}  {a.get('kind')}  {a.get('verdict')}  {a.get('status')}" for a in mine) or "(none)"))
        yield Footer()


class Alerts(Screen):
    BINDINGS = [Binding("escape", "app.pop_screen", "back"), Binding("a", "app.pop_screen", "back")]

    def __init__(self, alerts: list) -> None:
        super().__init__()
        self.alerts = alerts

    def compose(self) -> ComposeResult:
        t = DataTable(id="alerts")
        t.add_columns("time", "key", "kind", "verdict", "status")
        for a in reversed(self.alerts):
            t.add_row(a.get("ts", ""), a.get("key", ""), a.get("kind", ""), a.get("verdict", ""), a.get("status", ""))
        yield t
        yield Footer()


class MonitorTUI(App):
    TITLE = "claude-discord monitor"
    CSS = "#bar { background: darkred; color: white; } #bar.hidden { display: none; }"
    BINDINGS = [Binding("q", "quit", "quit"), Binding("a", "alerts", "alerts")]

    def __init__(self, state_dir: Path, bot: str, wrapper: str | None) -> None:
        super().__init__()
        self.state_dir, self.bot, self.wrapper = state_dir, bot, wrapper
        self.state: dict = {}
        self.mtime: float | None = None
        self.holder = state_dir / "holders" / f"tui-{os.getpid()}"

    def compose(self) -> ComposeResult:
        yield Static("", id="head")
        yield Static("", id="bar", classes="hidden")
        hosts = DataTable(id="hosts", cursor_type="row")
        hosts.add_columns("host", "reach", "patch", "claude-discord", "bots ok", "checked")
        bots = DataTable(id="bots", cursor_type="row")
        bots.add_columns("host", "project", "bot", "verdict", "for", "detail")
        yield hosts
        yield bots
        yield Footer()

    def on_mount(self) -> None:
        if self.wrapper:   # the holder record and the monitor: one wrapper call, which returns at once
            subprocess.run([self.wrapper, "monitor", "--ensure", self.bot, "--holder", "tui", str(os.getpid())],
                           stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        self.refresh_state()
        self.set_interval(2, self.refresh_state)

    def refresh_state(self) -> None:
        path = self.state_dir / "state.json"
        try:
            mtime = path.stat().st_mtime
        except OSError:
            mtime = None
        if mtime is not None and mtime == self.mtime:
            return
        self.mtime = mtime
        self.state = load(path)
        text, bar = header_lines(self.state)
        self.query_one("#head", Static).update(text)
        b = self.query_one("#bar", Static)
        b.update(bar or "")
        b.set_class(bar is None, "hidden")
        for table_id, rows in (("#hosts", host_rows(self.state)), ("#bots", bot_rows(self.state))):
            t = self.query_one(table_id, DataTable)
            t.clear()
            for key, row in rows:
                t.add_row(*row, key=key)

    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        key = event.row_key.value
        scope = "hosts" if event.data_table.id == "hosts" else "bots"
        entry = (self.state.get(scope) or {}).get(key) or {}
        self.push_screen(Detail(key, key + "|-" if scope == "hosts" else key, entry, self.state.get("alerts") or []))

    def action_alerts(self) -> None:
        self.push_screen(Alerts(self.state.get("alerts") or []))

    def on_unmount(self) -> None:
        try:
            self.holder.unlink()
        except OSError:
            pass


def main() -> None:
    p = argparse.ArgumentParser(prog="claude-discord tui")
    p.add_argument("--bot", required=True)
    p.add_argument("--state-dir", required=True, type=Path)
    p.add_argument("--claude-discord", default=None, help="the wrapper, for the holder record and --ensure")
    a = p.parse_args()
    MonitorTUI(a.state_dir, a.bot, a.claude_discord).run()


if __name__ == "__main__":
    main()
```

In `bin/claude-discord`, after the `monitor` verb add:

```bash
# tui: a read-only view of the monitor's state.json (tui/claude_discord_tui.py,
# Python + Textual through `uv run --script`; uv is needed for this verb only).
# The bot is the project's one dev-manager bot with a hosts ledger unless named.
if [ "${1:-}" = tui ]; then
  bot=${2:-}
  # From anywhere inside the project, like the shim: up to the directory that holds .claude/discord-agents.
  while [ ! -d "$PWD/.claude/discord-agents" ] && [ "$PWD" != / ]; do cd ..; done
  root=$PWD/.claude/discord-agents
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
  case $bot in ''|.|..|*/*) echo "claude-discord: bot name must be a plain directory name, got '$bot'" >&2; exit 2;; esac
  [ -f "$root/$bot/hosts" ] || { echo "claude-discord: tui: $root/$bot has no hosts ledger (claude-discord setup $bot --mode writes one)" >&2; exit 1; }
  uv=${CLAUDE_DISCORD_UV:-uv}
  command -v "$uv" >/dev/null 2>&1 || { echo "claude-discord: tui needs uv (https://docs.astral.sh/uv/); nothing else in claude-discord does" >&2; exit 1; }
  exec "$uv" run --script "$self_root/tui/claude_discord_tui.py" --bot "$bot" \
    --state-dir "$HOME/.claude-discord/records/monitor/$bot" --claude-discord "$self_path"
fi
```

In the header usage, after the `health --uninstall-timer` entry add

```bash
#   claude-discord tui [<name>]          a read-only view of a manager bot's
#                                        backend monitor (needs uv); starts the
#                                        monitor if none runs
```

README.md, exactly these replacements:

Prerequisites: after the `git` row. Replace

```markdown
| `git` | `setup` clones claude-discord, `update` pulls it |
```

with

```markdown
| `git` | `setup` clones claude-discord, `update` pulls it |
| `ssh` (manager bots only) | the backend monitor runs `health --all` on each ledger host over it, with `BatchMode=yes` |
| `uv` (the TUI only) | `claude-discord tui` runs a Python + Textual script through `uv run --script`; nothing else needs it |
```

Glossary: before the **project** entry. Replace

```markdown
- **project**: the directory you run `claude-discord` from.
```

with

```markdown
- **ledger**: `<project>/.claude/discord-agents/<manager bot>/hosts`, the ssh
  hosts a manager bot's monitor checks. Its existence is the monitor's on/off
  switch.
- **holder**: a process the monitor lives for: an open TUI or the manager
  session. The monitor exits within 30 s of the last one.
- **finding**: a verdict that needs a human (`down`, `stale`, `duplicate`,
  `unreachable`, `nostate`, `throttled`, `apierror`, `patchfail`, `hostdown`,
  `blind`). `ok` and `busy` are not findings; `noreach` is logged, never posted.
- **project**: the directory you run `claude-discord` from.
```

the `health` usage block. Replace

```markdown
claude-discord health --json           # the same as data, for a script
```

with

```markdown
claude-discord health --json           # the same as data, for a script
claude-discord health --all [--json] [--patch]   # every project on this machine (what a monitor pass runs)
```

the primary signal (section "Is the bot still there?"). Replace

```markdown
> the **oldest** message that addressed this bot, newer than the last one its
> hooks recorded in `last-message-id`, and more than 15 minutes old
```

with

```markdown
> the **oldest** message that addressed this bot, never handed to its session
> (its id is not in `<bot>/delivered`), and more than 15 minutes old

`on-prompt` appends every message id the session receives to `<bot>/delivered`
(the last 200 are kept). So `stale` is a delivery check: `ok` means the
session received the message, not that it answered. A mention that asks
nothing gets no reply by rule, and a turn may take an hour; neither is a
fault. A message stuck in one thread still reads `stale` while the bot answers
in another, which `last-message-id` alone could not see. A bot whose hooks
have not run since 1.10.0 has no `delivered` yet and is judged by
`last-message-id`, as before.
```

the health.log sentence. Replace

```markdown
Every run also appends to `<bot>/health.log` and to the journal.
```

with

```markdown
Every run by hand also appends to `<bot>/health.log` and to the journal;
`health --all` (the monitor's run, every five minutes) writes neither. Old
`health.log` files can be deleted.
```

a new section before "## Behind a corporate proxy". Replace

```markdown
## Behind a corporate proxy
```

with

````markdown
## The monitor and the TUI (manager bots)

A dev-manager bot can watch every bot on its own machines and tell each
bot's owner in `#bot-health-check` when one stops answering. Nothing is
installed in the OS: no launchd, systemd or cron.

```
claude-discord setup <manager> --mode    # dev-manager, then: ssh hosts to check
claude-discord tui [<manager>]           # a read-only view; starts the monitor if none runs
```

**Ledger.** `setup` in dev-manager mode asks `ssh hosts to check` and writes
`<manager>/hosts`: one host per line, an optional `laptop` word, then optional
`KEY=VALUE` words (no spaces in a value) that become the remote command's
environment. `local` is this machine and is always there; its `KEY=VALUE`
words are also the environment of the monitor's own Discord calls.

```
# ssh host names this manager checks; "local" is this machine (no ssh)
local HTTPS_PROXY=http://127.0.0.1:8118
wmac  laptop HTTPS_PROXY=http://127.0.0.1:8118
pmac  laptop
```

A `laptop` host is checked like any other, but its own unreachability is
never posted (a closed lid is not an outage). Setup marks a host `laptop`
when it answers `Darwin` and has a battery; edit the word by hand to change
it. Deleting the file turns the monitor off. Two managers must not list the
same host, or its bots are reported twice; nothing enforces that across
owners.

**Monitor.** One process per manager bot, started by the TUI or by the
manager session's SessionStart hook, and alive only while one of them is: it
exits within 30 s of the last. Every 5 minutes it runs, per host,
`ssh -o BatchMode=yes -o ConnectTimeout=8 <host> 'env <KEY=VALUE...>
~/.local/bin/claude-discord health --all --json --patch'` (`local`: the same
command without ssh), so every ledger host needs the shim and claude-discord
1.10.0 or later, and one `claude-discord health` run in each bot project to
enter it in `~/.claude-discord/records/projects`. The same call keeps the
official plugin patched on that host. It restarts and stops nothing.

Everything it keeps is in `~/.claude-discord/records/monitor/<manager>/`:

| file | what |
|---|---|
| `lock` | the single-instance lock (`flock` through perl) |
| `state.json` | what the TUI shows; kept after exit, and what keeps a restart from repeating a finding |
| `monitor.log`, `monitor.log.1` | one line per event, 256 KiB each at most |
| `holders/<kind>-<pid>` | one record per open TUI or manager session |
| `pass.out` | one host's answer, only during a pass |

**Alerts.** One message per change, posted with the manager bot's token to
channel `1558283274487341137`, and one `[recovered]` line when the bot is
back. The channel is write-only: it is not in any bot's `access.json`, so a
message there wakes no session.

```
<@owner id> [stale] RVP on lmd42 (~/workspace/tor-aic-research)
사유: unanswered for 22m -- the plugin server is up, so its hooks or its turn are stuck
복구: ssh lmd42 'cd ~/workspace/tor-aic-research && ~/.local/bin/claude-discord refresh RVP --force'
```

| finding | posted after | means |
|---|---|---|
| `stale`, `nostate`, `patchfail` | at once | see the troubleshooting rows; `patchfail` is a patch whose pattern moved |
| `down`, `duplicate`, `unreachable`, `blind` | 5 min | `blind`: the host answered ssh but gave no health document (no claude-discord there, or one before 1.10.0) |
| `throttled`, `apierror`, `hostdown` | 30 min | `hostdown`: ssh itself failed, also with `-o ControlPath=none`; never posted for a `laptop` |
| `noreach` | never | that host cannot reach Discord; logged and shown |

While a host is `noreach`, `hostdown` or `blind`, nothing is said about its
bots. A bot's owner is `DISCORD_USER_ID` of its project's `config.env`; a
host-level finding mentions the manager project's. Labels are Korean by
default; `ALERT_LANG='en'` in the manager project's `config.env` makes them
English (any other value is Korean). The reason and the command are never
translated.

**TUI.** `claude-discord tui` shows the monitor's state: hosts, bots
(findings first), `Enter` for a row's detail and recovery command, `a` for
the last 50 posts, `q` to quit. A red bar says when the monitor is stopped or
the last post failed. It changes nothing and never reads a token.

**Expected.** With the TUI open, stopping a bot by hand gives one `[down]`
message within 10 minutes and one `[recovered]` line after it is started
again. A pass that sees nothing new posts nothing. With the TUI closed and
the manager session gone, no monitor process is left 30 s later.

**Rollback.** Delete `<manager>/hosts`; `rm -r
~/.claude-discord/records/monitor ~/.claude-discord/records/projects` removes
everything this feature wrote.

## Behind a corporate proxy
````

Troubleshooting: the reserved-name row. Replace

```markdown
`setup`, `install`, `update`, `patch`, `compat`, `refresh`, `health`) is reserved too |
```

with

```markdown
`setup`, `install`, `update`, `patch`, `compat`, `refresh`, `health`, `monitor`, `tui`) is reserved too |
```

Troubleshooting: after the "cannot count plugin servers" row. Replace

```markdown
| `health` says `cannot count plugin servers on this machine` | no `/proc` (macOS); the behavioural signal still works, only the cause cannot be named |
```

with

```markdown
| `health` says `cannot count plugin servers on this machine` | neither `/proc` nor a working `ps -axww` (macOS counts through `ps`); the behavioural signal still works, only the cause cannot be named |
| `[hostdown] <host>` in `#bot-health-check` | ssh to that host failed twice. Run the command in the message; `up` means a stale ControlMaster or a tunnel that was reconnecting |
| `[blind] <host>` | ssh works but `health --all` gave no document: `~/.local/bin/claude-discord` is missing there or older than 1.10.0. Run `setup` or `update` on that host |
| `[patchfail] <host>` | the official plugin changed and a patch no longer matches; `claude-discord update` there, and if it still fails the patch needs a claude-discord fix |
| The TUI says `monitor stopped` | no holder is alive; opening the TUI starts it. If it stops again at once, `<manager>/hosts` is missing or `monitor.log` says why |
| No alert for a bot on a ledger host | its project is not in that host's `~/.claude-discord/records/projects` (run `claude-discord health` there once), or the host is `noreach`/`hostdown`/`blind` (the TUI shows it) |
| `claude-discord: tui needs uv` | install uv (https://docs.astral.sh/uv/); only the TUI needs it |
```

Test section. Replace

```markdown
symlink, none of which hold on macOS.
```

with

```markdown
symlink, none of which hold on macOS.

`uv run --script tests/tui/test_tui.py` drives the TUI over fixture state
files (Textual's pilot). It needs uv and the Textual wheel, so it sits
outside the stub suite and its 40 s budget.
```

- [ ] **Step 4: Run both test sets, quiet**

Run: `uptime` (load below 4), then `time ./test-claude-discord.sh ./bin/claude-discord`, then `uv run --script tests/tui/test_tui.py` (needs network once to fetch the Textual wheel; the stub suite never does).
Expected: `ALL PASS` under 40 s real (measured while writing this plan: 38.3 to 39.7 s), and `ok: all_ok`, `ok: findings`, `ok: stopped`, `ok: post_failed`, `ok: quit removes its holder record`. Over 40 s quiet: stop and report the measurement; do not drop a case.

- [ ] **Step 5: Mutation check.** Each revert alone fails with:
  - the walk up to the project dropped: `FAIL: tui from a subdirectory of the project must find the project above it`
  - the uv check dropped: `FAIL: without uv, tui must say so (rc=127)`

- [ ] **Step 6: Commit**

```bash
git add tui/claude_discord_tui.py tests/tui/test_tui.py
git commit -m "claude-discord tui: a read-only Textual view of the monitor's state (uv run --script; holds the monitor while open; hosts, bots, detail with the recovery command, the last 50 posts); README for the monitor, the ledger, the alerts and delivered" -m "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>" -- tui/claude_discord_tui.py tests/tui/test_tui.py bin/claude-discord README.md test-claude-discord.sh
```

---
### Task 10: Live check on lmd42, review, merge, rollout

Not subagent work: the lead runs it, and dong-dev-bot reviews before main (project rule). This is the one place that writes the real `~/.claude-discord/records/monitor/<bot>/` and the real ledger on purpose (the spec's live check); every probe besides those commands still follows the rule.

HARD HOME RULE (repeat verbatim in any dispatch prompt here): any probe outside the test suite sets a literal sandbox HOME in the SAME Bash call, chained with &&; never write the real ~/.claude.json, ~/.claude, ~/.claude-discord or ~/.local/bin; run hand-run hooks/tools with env -u DISCORD_STATE_DIR.

- [ ] **Step 1:** Push `impl/monitor-tui`, post the diff summary in the item's Discord thread to dong-dev-bot with the eleven deviations above, close every review finding (re-review each fix commit) before main.
- [ ] **Step 2:** On lmd42, `claude-discord update` from the branch, one `claude-discord health` in each bot project, then `claude-discord setup junyong-dev-bot --mode` answering `wmac, pmac`; `claude-discord tui`. Proof: the hosts table lists `local`, `wmac`, `pmac` with versions; `ls ~/.claude-discord/records/monitor/junyong-dev-bot` shows only `holders lock monitor.log state.json`.
- [ ] **Step 3:** Stop one non-critical bot by hand (`claude stop <id>`). Proof: one `[down]` message in `#bot-health-check` within 10 minutes mentioning its owner; after `claude-discord --bg --name <bot>`, one `[recovered]` line; nothing else posted.
- [ ] **Step 4:** Quit the TUI with no manager session holding: `ps` shows no `monitor/monitor.sh` process 30 s later; `state.json` reads `"pid": null` with `stopped_at`.
- [ ] **Step 5:** Merge to main, `claude-discord update` on lmd42, wmac, pmac; tell each local bot session what changed (the hooks and the wrapper's behaviour did); ask dong-dev-bot to set up its own ledger (lmd79, dongyong22's wmac, the personal Mac) after main.
- [ ] **Step 6:** Close the sub-project 2 item in codeslake/tor-aic-research issue #1 with the version and the machines it landed on.
