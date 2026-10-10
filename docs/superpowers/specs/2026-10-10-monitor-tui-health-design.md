# claude-discord backend monitor, TUI and health alerts (sub-project 2)

Status: draft for the owner's review, 2026-10-10. Decisions come from
codeslake/tor-aic-research issue #1, comments 6047156555 to 6093066614 (all
posted from the codeslake account; quoted below where the owner's own words
are recorded).

Base: this spec sits on sub-project 1 (plugin packaging), which is built on
branch `impl/plugin-packaging` (6bf8ee6) and not yet on main. Every path
below uses that layout: the wrapper is `bin/claude-discord`, the SessionStart
hook is `hooks/turn/on-session-start`, `setup` records installs in
`~/.claude-discord/records/installs`, and `claude-discord patch` is the
extracted patch step (sub-project 1, "Patches on the official plugin").

## Owner decisions this spec relies on

- No OS scheduler; a resident process is fine when the plugin starts it and
  the owner can see it (6072299898): "What is banned is OS schedulers that
  run without his knowledge: launchd, systemd, OS cron". Health and its
  on/off switch belong to claude-discord itself (6047156555): "health
  check을 lanchd, cron에서 하고잇다고? ... mod자체에서 health채크 주기적으로
  보내주게. 그리고 이거 turnon/off할수있게 해줘."
- One shared channel, no threads, one message per finding with the owner
  mentioned, the session name, the reason and the recovery command
  (6091915116). Until then nothing alerts: "일단 이대로두고".
- The channel is `1558283274487341137` and only manager bots use it
  (6091949777): "이건 setup할때 매니지용 봇 (너랑 dong-dev-bot)만
  이용가능하게해".
- Coverage, alert set and patch upkeep (6092937121): `setup` in manager mode
  records ssh host names in `<manager bot>/hosts`, local machine included;
  each manager watches its own hosts only; alerts for "down, stale,
  duplicate, unreachable, nostate, patch failure; throttled/apierror only
  after 30 min; noreach logged only", "one message per state change + a
  recovery line", posted with the manager bot's token. That comment also
  said "claude-discord tui가 헬스체크하게 하자고"; the next one corrects it.
- The TUI only displays; a backend monitor does the work (6092947562): "A
  detached backend monitor (one per manager, single-instance lock) runs the
  health pass every 5 min ... `claude-discord tui` is only a graphical view
  of that state. Launching the TUI starts the monitor if it is not running
  ... The manager bot's mode hook ... also starts the monitor".
- Lifetime and footprint (6093066614): "쓰레기 파일/프로세스 안쌓이고
  가볍게". Holders are the TUI and the manager session; the monitor "exits
  within 30 s after the last one is gone (it checks the holder pids every
  30 s)"; one process whose only children are a pass's short ssh/curl calls;
  flock on a fixed path; "one state file and one size-capped log (one
  previous generation kept) under `~/.claude-discord/records/`; nothing in
  /tmp; exit removes its pid/holder records"; per pass "one ssh per host;
  Discord POST only on a state change".
- Router and relation armbands are later specs; our own MCP server is
  withdrawn (6092544397).

Two readings are reconciled here. 6092947562 says the monitor "outlives both
the TUI and the manager session", 6093066614 says it exits 30 s after the
last holder: the monitor outlives **either** holder and exits when **both**
are gone. And "one TUI per manager (lock)" (6092937121) was there because the
TUI did the work; after the correction the lock belongs to the monitor, so
the TUI takes no lock and two TUIs are two harmless readers of one file.

## Goal

A manager bot's machine notices, within one pass, any bot on its ledger hosts
that stopped answering, and tells that bot's owner in `#bot-health-check`
once, with a command that fixes it, without a human running anything and
without an OS scheduler.

Success means:

- With the TUI open or the manager session running, a bot stopped by hand on
  any ledger host yields exactly one message in `#bot-health-check` within
  10 minutes, mentioning its owner, and one recovery line after it is back.
- A pass that sees nothing new posts nothing; restarting the monitor does
  not repeat findings already posted.
- With the TUI closed and the manager session gone, no claude-discord
  monitor process exists 30 s later, and `~/.claude-discord/records/`
  holds only the fixed files listed below. Nothing is written to /tmp.
- The official plugin stays patched on every ledger host without a restart
  of anything, and a patch that no longer matches is one alert.
- No bot token appears in the state file, the log, the TUI or a message.
- The stub suite still runs serially within 40 s.

## Out of scope

- The per-token router (shared bot token) and relation armbands: later specs
  (6092544397).
- Our own Discord MCP server: withdrawn (6092544397).
- The mod/band: still on hold; the TUI is the visible surface for now.
- Any automatic restart or stop of a bot. The monitor's one automatic action
  is `claude-discord patch`, which is idempotent and touches no session. This
  keeps dong-dev-bot's review point (6050286852): automatic action only on
  `down`, never on `stale`; here there is none at all. Recovery commands are
  printed for a human.
- Managers watching each other (6092937121: "no mutual watch"). If a manager
  machine is off, its hosts are unwatched; that is the stated limit.

## Components and process model

1. **`claude-discord monitor <bot>`** (wrapper verb, bash; not in `--help`).
   One process per manager bot. Its only children are one ssh (or local
   `health`) at a time and the occasional curl POST, each bounded.
2. **`claude-discord health --all [--json] [--patch]`** (extends `health`).
   Runs the existing per-project check in every project listed in
   `~/.claude-discord/records/projects`; `--patch` runs `claude-discord
   patch` first and reports its result in the same document. This is the
   one command a pass runs per host, locally or over ssh.
3. **`claude-discord tui [<bot>]`** (wrapper verb). Registers itself as a
   holder, ensures the monitor, and shows the state file. Python + Textual,
   a single file `tui/claude_discord_tui.py` with PEP 723 inline metadata
   (`textual>=8.2.8,<9`, the range cswap's TUI uses), run by
   `uv run --script`.
4. **SessionStart hook** (`hooks/turn/on-session-start`). For a
   `dev-manager` bot whose `<bot>/hosts` exists: registers the session as a
   holder and ensures the monitor, detached, never blocking the hook.
5. **`setup`** in dev-manager mode asks for the ledger hosts and writes
   `<bot>/hosts`.

The monitor is bash for the same reason `health` and `patch` are: it runs on
Linux and macOS with what is already there (bash, perl, curl, jq, ssh), and
the manager session's hook must not depend on Python or Textual. Only the TUI
needs Python.

### Lock

The single-instance lock is `flock` on a fixed file, taken through perl
(`perl -MFcntl=:flock`) because `flock(1)` is util-linux and dong-dev-bot's
manager runs on a Mac; the wrapper already relies on perl for `setsid`. The
perl stub opens the lock file, takes `LOCK_EX|LOCK_NB`, clears close-on-exec
on that fd and execs `claude-discord monitor <bot>`, so the lock lives exactly
as long as the monitor process and the kernel drops it on any death.
Children of a pass are started with that fd closed, so an ssh still running
after a crash cannot hold the lock.

`monitor --ensure <bot>` is what the TUI and the hook call: it detaches
(`setsid`, stdio to the log) and tries the lock for up to 5 s. Winning it
makes it the monitor; losing it means one is running, and it exits 0. The
5 s wait closes the race with a monitor that is exiting at that moment (see
lifecycle).

### Environment

The monitor's Discord calls use the env written on the ledger's `local` line
when there is one (for example `HTTPS_PROXY=http://127.0.0.1:8118`), else the
env of whoever started it. So a TUI started from a bare shell and a monitor
started by the manager session behave the same. A POST that fails is never
silent: it is kept pending, retried next pass, shown in the TUI and logged.

## Files and formats

All under `~/.claude-discord/records/monitor/<bot>/`, mode 0700 directory,
0600 files:

| path | written by | lifetime |
|---|---|---|
| `lock` | created once (empty) | fixed; the flock target |
| `state.json` | monitor only, via `state.json.tmp` (same dir, fixed name) and rename | kept after exit so the TUI shows the last state |
| `monitor.log`, `monitor.log.1` | monitor | capped at 256 KiB; on overflow `.log` replaces `.log.1` |
| `holders/<kind>-<pid>` | the TUI and the hook | removed by their owner on exit, by the monitor when dead, all of them by the monitor on exit |

Plus one machine-wide record, `~/.claude-discord/records/projects`: one
project root per line, written by `setup` and by a `health` run in a project
(so a project migrated by sub-project 1 gets in at its confirming `health`
run), pruned by `health --all` when `<root>/.claude/discord-agents` is gone.
`records/installs` cannot serve: a global install names no project.

Per bot, the monitor path writes nothing new. `health --all` does not append
to `<bot>/health.log` and does not call `logger`: at a 5-minute cadence those
grow without bound, which is what 6093066614 rules out. A `health` run by
hand keeps both, at human cadence. The existing caches (`bot-id`,
`channel-guild`, `health-unknown`) stay as they are: fixed files, one each.

### Ledger: `<project>/.claude/discord-agents/<bot>/hosts`

```
# ssh host names this manager checks; "local" is this machine (no ssh)
local HTTPS_PROXY=http://127.0.0.1:8118
wmac  HTTPS_PROXY=http://127.0.0.1:8118
pmac
```

One host per line, then optional `KEY=VALUE` env for the remote command
(a non-interactive ssh shell may lack the proxy that the bots' launcher
had; a missing one shows up as `noreach`). `local` is always present; setup
adds it. The file is also the on/off switch the owner asked for in
6047156555: no `hosts` file, no monitor.

### `health --all --json --patch` (one document per host)

```json
{ "host": "lambda-docker", "version": "1.8.0 (abc1234)",
  "patch": { "rc": 0, "output": "" },
  "projects": [ { "project": "/home/u/workspace/tor-aic-research",
                  "bots": [ { "bot": "RVP", "verdict": "ok", "detail": "",
                              "owner_id": "1528...", "servers": "1", "...": "..." } ] } ] }
```

Each bot object is today's `health --json` object plus `owner_id`, read from
the project's `config.env` `DISCORD_USER_ID` (the owner the README already
calls "config.env's owner"). That answers 6091915116's open question on where
the owner id comes from. `patch.output` is the patch step's stderr, file and
patch name, nothing else.

### `state.json`

```json
{ "version": 1, "manager": "junyong-dev-bot",
  "monitor": { "pid": 123, "started": "2026-10-10T12:00:00Z",
               "last_pass": "...", "next_pass": "...", "pass_s": 6.1,
               "holders": [ { "kind": "tui", "pid": 456 } ], "exiting": false },
  "hosts": { "wmac": { "reach": "ok", "since": "...", "patch": "ok",
                        "version": "1.8.0 (abc1234)", "checked": "..." } },
  "bots": { "wmac|/Users/u/workspace/x|RVP": {
              "verdict": "stale", "detail": "...", "since": "...",
              "posted": "stale", "posted_at": "...", "owner_id": "..." } },
  "alerts": [ { "ts": "...", "key": "...", "kind": "finding", "verdict": "stale",
                "status": "sent" } ] }
```

`alerts` keeps the last 50. `posted` is what the channel was last told about
that key, which is what makes a restart quiet.

### `monitor.log`

One line per event, UTC: `start`, `exit reason=no-holders`, `pass hosts=3
bots=9 findings=1 posted=1 6.1s`, `transition <key> ok->stale`, `post <key>
stale 200`, `post <key> stale failed 429 retry_after=2.5`, `host wmac
ssh-failed rc=255 (retried with ControlPath=none)`. No message bodies, no
headers, never a token.

## Start and stop lifecycle

- **Start.** The TUI writes `holders/tui-<pid>`, then runs `monitor --ensure`.
  The hook writes `holders/session-<pid>`, then runs `monitor --ensure` in
  the background and returns. Either way at most one monitor holds the lock.
- **Holder record.** `<pid> <start time> <kind>`, the start time from `ps -o
  lstart= -p <pid>` so a reused pid does not count as alive. The TUI's pid is
  its own. The session's pid is the hook's **nearest** ancestor that is a
  Claude Code CLI process: argv[0] is `.../claude` or under
  `.../claude/versions/`, and argv[1] is not `daemon`. Nearest matters:
  measured on lmd42 (2.1.296), a `--bg` session process has comm `2.1.296`,
  its parent is the `--bg-pty-host` process and above that is `claude
  daemon`, which never dies; a hook that walked up to "a process named
  claude" would pin the monitor for ever. The plan must measure a real
  SessionStart hook's ancestry on lmd42 (background and foreground) and on a
  Mac before relying on this rule.
- **The 30 s rule.** The monitor's loop wakes every 30 s, also while a pass
  is running (it polls its ssh child with 1 s sleeps rather than blocking on
  it). Each wake checks every holder record with `kill -0` and the start
  time; dead ones are removed. When none is alive it re-reads `holders/` once
  (a holder may have just registered), and if still none it kills the
  running pass child, writes `state.json` with `monitor.pid` set to null and
  a `stopped_at` time (so the only pid record left reads as stopped),
  removes `holders/*`, logs `exit` and exits. Worst case: 30 s after the
  last holder dies.
- **Exit race.** An `--ensure` that arrives while the old monitor is exiting
  waits up to 5 s for the lock and then becomes the new monitor, so a holder
  registered in that window is never left without one.
- **Refresh of the manager bot.** With no TUI open, a `refresh` leaves the
  manager session gone for a few seconds; the monitor may exit in that gap
  and the new session's SessionStart starts it again. `state.json` keeps
  `posted`, so nothing is re-sent.
- **Pass cadence.** A pass starts at most every 300 s (the first right after
  start). `health`'s `unknown_cap=6` ("30 min at 5 min") assumes this
  cadence: changing the interval alone changes when `nostate` fires.
- **Per-host cap.** 90 s per host, enforced by the monitor's own poll loop
  (no `timeout(1)` on macOS). Hosts run one after another; a pass never
  overlaps the next.

## What counts as a real failure

A finding is posted when it has held continuously for its hold time; a
change to a different finding that holds for its own hold time is a new
message; the first pass back at `ok` (or `busy`) after a posted finding
posts the recovery line. A finding that clears before its hold time is only
logged. The key is `host|project|bot` for a bot, `host|-` for a host.

| finding | from | probe | hold |
|---|---|---|---|
| `down` | health | no plugin server for the bot, nothing unanswered | 5 min (two passes): a pass that lands inside a `refresh` sees `down` for seconds |
| `stale` | health | oldest addressed message unanswered 15 min, no live turn (health's own filters: allowFrom, requireMention, replies, turn-file and `claude agents` holds) | none: the 15 min is already in the probe |
| `duplicate` | health | more than one plugin server on the bot's token | 5 min |
| `unreachable` | health | Discord answered 401/403 for the bot's token or channel | 5 min |
| `nostate` | health | unanswered and `claude agents` silent for 6 runs | none: already 30 min |
| `throttled`, `apierror` | health | 429, 000 or 5xx for that bot | 30 min (6092937121) |
| `noreach` | health | that host's unauthenticated `GET /gateway` fails | never posted; logged and shown (6092937121) |
| `patchfail` | `--patch` | `patch` exit 1 (a pattern no longer matches) | none: deterministic |
| `hostdown` | monitor | ssh exit non-zero, and again with `-o ControlPath=none` (a stale master refuses falsely) | 30 min: the Macs are laptops and sleep |
| `blind` | monitor | ssh ran but no valid document (claude-discord missing or too old for `--all`, health crashed) | 5 min |

`busy` is not a finding. While a host is `noreach`, `hostdown` or `blind`,
its bots' states are frozen: such a pass says nothing about them, so it
neither posts nor recovers them. A bot that leaves the list (its `.env`
removed, its project gone) is dropped and logged, not announced. `health`'s
own `unreachable` means a refused token; an unreachable host is `hostdown`,
so the two never share a name. ssh is called as `ssh -o BatchMode=yes -o
ConnectTimeout=8 <host> ...` and judged by exit status, never by output.

Coverage gap: without `/proc` (macOS) `health` counts servers as `unknown`,
so `down` and `duplicate` cannot be seen on the Macs today; `stale` still
can. This spec adds a macOS count through `ps -Eww -o pid,command` (macOS
`ps -E` prints the environment of the user's processes) matching the same
argv and `DISCORD_STATE_DIR` rule, to be measured on wmac before it is
trusted. Until it is, a Mac row reads `servers: unknown` in the TUI.

## Alert message format

Posted by the monitor with the manager bot's token (read from its `.env` at
POST time, sent to curl on stdin as `health` does, never argv) to
`POST /channels/1558283274487341137/messages`. The channel id is a constant
in the wrapper: both owners' managers share it (6091915116). 429 is honoured
(`retry_after` under 10 s waits in the pass, longer waits for the next
pass). Labels follow the project's Discord language rule (Korean), as
recommended in open question 5 and pending the owner's answer; the detail
and the command stay as produced (English).

Finding (pings the bot's owner, `allowed_mentions: {users: [owner_id]}`):

```
<@1528219406872739933> [stale] RVP on lmd42 (~/workspace/tor-aic-research)
사유: unanswered for 22m -- the plugin server is up, so its hooks or its turn are stuck
복구: ssh lmd42 'cd ~/workspace/tor-aic-research && ~/.local/bin/claude-discord refresh RVP --force'
```

Recovery line (no ping, `allowed_mentions: {parse: []}`):

```
[recovered] RVP on lmd42 (~/workspace/tor-aic-research): answering again after 35m (was stale)
```

The session name is the bot name (sub-project 1: `--name` is both). For a
local host the `ssh <host> '...'` wrapper is left out. Host-level findings
(`patchfail`, `hostdown`, `blind`) mention the manager's own owner (the
manager project's `DISCORD_USER_ID`). A message is cut to 1900 characters.
Recovery commands, from the README's troubleshooting rows:

| finding | command |
|---|---|
| `down` | `cd <project> && claude-discord --bg --name <bot>` |
| `stale` | `cd <project> && claude-discord refresh <bot> --force` |
| `duplicate` | `claude agents`, then `claude stop <id>` for the copy that is not the bot's |
| `unreachable` | check `DISCORD_BOT_TOKEN` in `<project>/.claude/discord-agents/<bot>/.env` and the bot's channel permissions |
| `nostate` | `claude agents` by hand; the daemon is unwell |
| `throttled`, `apierror` | `cd <project> && claude-discord health` |
| `patchfail` | `claude-discord update`; still failing means the patch needs a claude-discord fix |
| `hostdown` | `ssh -o BatchMode=yes -o ConnectTimeout=8 -o ControlPath=none <host> 'echo up'` |
| `blind` | `ssh <host> '~/.local/bin/claude-discord --version'`, then `setup` or `update` there |

What "only manager bots may post there" (6091949777) means in code: setup
asks the hosts question, and so starts a monitor, only in dev-manager mode;
no other bot's state dir ever holds a `hosts` file. Posting needs only the
token and the guild permission the owner set on the channel. Setup does not
add the channel to the manager's `access.json`, so a message in
`#bot-health-check` does not wake the manager session (open question 3).

## Host ledger and remote checks

- `setup <bot>` and `setup <bot> --mode`, in dev-manager mode, ask after the
  peers: `ssh hosts to check, comma-separated (this machine is always
  included)`; the current list is the default on Enter. For each host it
  probes `ssh -o BatchMode=yes -o ConnectTimeout=8 <host>
  '~/.local/bin/claude-discord --version'` and prints the answer, and writes
  the host whatever the answer (a laptop may be asleep).
- A pass runs, per host, `ssh -o BatchMode=yes -o ConnectTimeout=8 <host>
  'env <KEY=VALUE...> ~/.local/bin/claude-discord health --all --json
  --patch'`, the absolute shim path because a non-interactive shell's PATH
  may lack `~/.local/bin`. `local` runs the same command without ssh. On a
  non-zero exit the call is repeated once with `-o ControlPath=none` before
  the host counts as failed for that pass.
- The remote side is a one-shot command: nothing stays running on a watched
  host, and patch upkeep happens there through the same call.
- The two managers' ledgers must not share a host, or a bot is reported
  twice. Nothing enforces it across owners; the README says so.

## TUI screens

`claude-discord tui [<bot>]` (default: the project's single dev-manager bot
with a `hosts` file; else it asks for the name). It never reads a `.env`,
so it cannot display a token. It re-reads `state.json` when its mtime
changes (checked every 2 s). It changes nothing: no restart, no post, no
patch.

- **Overview** (the only screen at start). Header: manager, monitor pid and
  holders, last and next pass, a red bar when the last POST failed or the
  monitor is not running ("monitor stopped at T", from the kept state).
  Hosts table: host, reach, patch, claude-discord version, bots ok/total,
  checked at. Bots table: host, project (short), bot, verdict, for how long,
  detail; findings first.
- **Detail** (Enter on a row, Esc back): full detail, the recovery command
  as selectable text, the key's transitions from `alerts`.
- **Alerts** (`a`): the last 50 posts with time, key, verdict and status.
- Keys: `q` quit (removes its holder record), `a`, Enter, Esc.

## Testing

- **Stub suite** (`./test-claude-discord.sh ./bin/claude-discord`, Linux,
  serial, 40 s, stubs only). Interval overrides (`CLAUDE_DISCORD_MONITOR_TICK`,
  `_PASS`, `_HOST_CAP`, fractional seconds) make each case sub-second;
  thresholds are tested by seeding `state.json` with old `since` times, not
  by waiting. ssh and curl are stubs that record argv and stdin. Cases:
  - single instance: two `--ensure` calls, one monitor pid; the ensure that
    meets an exiting monitor takes over;
  - exit rule: holder killed, monitor gone within one tick; a reused pid
    (start time differs) counts as dead; `holders/` empty after exit;
  - each row of the failure table: posted after its hold, not before;
    `noreach` never posted; frozen bot states under `hostdown`/`blind`;
  - one message per change: a second pass posts nothing; a monitor restart
    with a posted finding posts nothing; recovery line once;
  - ssh retried with `ControlPath=none` before `hostdown` counts;
  - POST failure stays pending and is retried; 429 `retry_after` honoured;
  - message text: owner mention, session, reason, recovery command, no ping
    on recovery, 1900-character cut;
  - `health --all --json --patch`: document shape, `owner_id`,
    `records/projects` written by setup and by `health`, pruned by `--all`;
    no `health.log` line and no `logger` call under `--all`;
  - footprint: a sandbox `HOME` and an unwritable `TMPDIR`; after a run
    only the files in the table exist under `records/monitor/<bot>/`; the
    stub token's text appears in no file under the sandbox except `.env`;
  - log cap: rotation at the cap keeps one generation;
  - setup writes `hosts` only in dev-manager mode, `local` always present;
  - the hook's ancestor rule against a stub process tree (a fake
    `.../claude/versions/9.9.9` parent under a fake `claude daemon`).
  Expected addition: about 3 s of wall time.
- **Outside the budget.** `tests/tui/test_tui.py`, Textual pilot tests over
  fixture state files (all ok, findings, monitor stopped, failed POST, a
  Mac row with `servers: unknown`), run with `uv run`, like the plugin load
  check in sub-project 1.
- **Measurements before relying on them** (the plan's first tasks): a real
  SessionStart hook's ancestry on lmd42 (`--bg` and foreground) and on a
  Mac; `ps -Eww` server counting on wmac; perl flock and fd inheritance on
  macOS bash 3.2.
- **Live check before main:** on lmd42 with ledger `local, wmac, pmac`, stop
  a non-critical bot; one `[down]` message within 10 min, one recovery line
  after `claude-discord --bg --name <bot>`; quit the TUI with a stub holder
  only, monitor gone within 30 s; `ls ~/.claude-discord/records/monitor/*`
  shows only the fixed files.

## Migration

1. Requires sub-project 1 on every ledger host: the shim at
   `~/.local/bin/claude-discord` and a version with `health --all`. An older
   host reads as `blind` with its version in the TUI, not as a bot failure.
2. On each host, `update` to this release, then one `claude-discord health`
   in each bot project (sub-project 1's step 3 already does this), which
   enters the project in `records/projects`.
3. Each manager: `claude-discord setup <manager> --mode`, answer the hosts
   question. junyong-dev-bot: `local, wmac, pmac`; dong-dev-bot: its own
   machines (lmd79, dongyong22's wmac, the personal Mac). A running manager
   session runs no SessionStart on `/reload-plugins`, so the monitor starts
   when the TUI is first opened, or at the session's next start, compact or
   clear. No bot restarts.
4. Old per-bot `health.log` files stay as they are; the README says they can
   be deleted. `health --uninstall-timer` stays for timers from old releases.
5. Off switch and rollback: delete `<bot>/hosts` and kill the pid shown in
   the TUI; the hook then starts nothing. Rolling back the release removes
   the hook and verbs; `rm -r ~/.claude-discord/records/monitor` and
   `~/.claude-discord/records/projects` remove what this release wrote.

## Open questions for the owner

1. **Host down on laptops.** wmac and pmac sleep and move; `hostdown` after
   30 min will fire on an ordinary night. Recommendation: keep the 30 min
   hold but post `hostdown` only for hosts marked always-on in the ledger
   (`lmd42`, `lmd79`); a laptop's unreachability is shown in the TUI only.
2. **macOS `down`/`duplicate`.** Until `ps -Eww` counting is measured on
   wmac, Macs get `stale` only. Recommendation: ship with the gap stated in
   the TUI and the README, and add the macOS count in the same release once
   measured, rather than blocking the release on it.
3. **Inbound on `#bot-health-check`.** Should a message there (an owner
   replying to an alert) wake the manager session? Recommendation: no; the
   channel stays write-only for the monitor, and humans talk to the manager
   in its own channel.
4. **TUI dependencies.** `uv run --script` with inline metadata needs `uv`
   on the manager machine (present on lmd42; not verified on the Macs).
   Recommendation: require `uv` for the TUI only, with a clear message when
   it is missing; the monitor and alerts do not depend on it.
5. **Alert language.** Recommendation: Korean labels (`사유`, `복구`) per the
   project's Discord rule, with `health`'s detail and the command left in
   English as produced, so the text a human copies is exact.

## Review

junyong-dev-bot implements; dong-dev-bot reviews every diff before main and
sets up its own ledger and installs on its machines after main.
