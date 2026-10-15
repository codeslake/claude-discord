# claude-discord TUI redesign, hosts and access editing (1.11.0 - 1.14.0)

Status: approved by dongyong22 2026-10-12 20:00Z and the owner (gpuvillain) 20:01Z,
thread 1559286847446982770. Mock: `mock.py` + `render.sh` beside this file
(`bash render.sh` writes mock-*.png). Builds on 1.10.3 (keeper: backend runs
on its own until `monitor --stop`; TUI only views; manager session only checks
and restarts).

Changed 2026-10-14 by the owner: 1.13.0 edits a bot's receive channels, receive
rules and mode, for bots on ledger hosts too; the token field and a bot's
rename move to 1.14.0. Plan: `docs/superpowers/plans/2026-10-14-access-1.13.0.md`.

Changed 2026-10-14 by the owner (1.13.1): `access set` asks one question for the
whole change set, naming how many of them widen (`Apply 3 changes, 2 of them
widening? [y/N]`), the widenings shown first, red, marked `!`; and the TUI's `s`
runs it on a pty the TUI holds and asks that question in a popup, instead of
handing the terminal over (kept only where no pty can be opened).

Changed 2026-10-14 by the owner (1.13.1, after review): in every popup with
buttons `←` `→` move the focus between the buttons and Enter presses the
focused one (so Enter on Yes applies an access change); popups still open on
the safe choice (No / Cancel) and `y` still answers directly. After a `y` the
run has no cap and is never killed (`esc` and closing wait for it);
`access.log` gets the `access.json` line right after the rename.

Changed 2026-10-14 by the owner (1.14.0): a bot's name is its Discord username
(`[A-Za-z0-9_-]`); the token, a rename and a new bot are written by one verb,
`claude-discord bot ... token | rename | add`, not by `access`. Renaming changes
Discord first, then everything here keyed by the name; a name that differs from
Discord's is shown `≠ Discord: <name>` with `=` to take Discord's. Plan:
`docs/superpowers/plans/2026-10-14-bot-1.14.0.md`.

1.14.1 (2026-10-15, plan `docs/superpowers/plans/2026-10-15-bot-1.14.1.md`):
the TUI's title names the claude-discord version (the wrapper hands it
`--version-line`); a bot renamed from the TUI shows its new name in the Bots
tab at once, from the CLI's `renamed: <old> -> <new>` line, the monitor's next
pass confirming it; `rename`'s plan line and the README say that a running
session's conversation is not carried over (the owner's option A: wording
only, no handoff asked). From the 1.14.0 review's minor items: M1 (that
wording), M2 (one of several sessions that will not stop: nothing is renamed
or started, the stopped ones are named), M3 (a scratch directory of the new
name already there: the bot's stays, said), M4 (`add` checks the name again
after its question), M5 (`health` writes `discord-name` only for the bot's own
id), M6b (`bot` turns xtrace off before the token is read), M6e (the pilot
pins the token zeroed after esc and Cancel), M8 (the popup shows up to 16
lines of the CLI's output, never its program line). Not done: M6a (`curl -q`
would change every curl argv and override the user's own `~/.curlrc`), M6c (a
`.env.cd.$$` left by SIGKILL between write and `mv`, mode 600, microseconds),
M6d (1.14.0's decision 2), M9 (bash 3.2's `read` after a trapped SIGINT: no
3.2 here beyond `bash -n`), M10 (jq 1.6: run here and on lmd42). **M7a
deferred** to the next plugin-patch release: attaching the 4004 listener before
`login` changes the patched `server.ts`, so every bot's plugin would be
re-patched and the suite's patch-upgrade cases would grow by one generation;
Discord rejects a reset token at `GET /gateway/bot` before any 4004 can
arrive, so the window is theoretical.

## Owners' requirements (quoted)

- dongyong22: "UI가 너무 구리다", "`host` 제목 행이 왜 둘인지", "`for 63m`,
  `servers 1`이 무슨 뜻인지", "봇마다 수신 허용 상태와 어느 Discord 채널에 있는지".
- dongyong22: cards are fine as a fixed band; what he disliked was cards
  stacking three lines per bot above the table. Table first.
- dongyong22: space expands a row; extra values go INTO their own columns,
  not as new label rows.
- dongyong22: channels and receives editable by key; channel list from the
  Discord server, space toggles; mention rule and allowed users editable.
- owner: tabs like slack4agents (Dashboard/config feel), clear sections.
- owner: hosts searchable from ssh config (fuzzy) and addable; Enter on a host
  opens a per-host settings popup (stop monitoring, configure).
- owner: bot token registration in the TUI.
- owner: each manager shows only its own owner's ledger hosts.
- owner: plan, tasks, SDD one task at a time, no parallel, save tokens.

## 1.11.0: read-only redesign

House style: slack4agents pane (`hooks/pane.tsx` T palette: brand #5fd7ff,
warn #ffaf00, ok #87d787, alert #ff5f87, bar #3a3a3a, tab #585858, cursor
#4e4e4e; title bar `◆ claude-discord  <manager>` with the backend status on
the right; a tab row whose active tab is filled and underlined `━` in brand;
rule headings: name in brand, dim count, rule to the edge, dim note right).
Nothing saturated but an alert. Labels English. Status is always
symbol + word + colour.

- Title right: `● live  keeper · checked 1m ago · next 4m`; when now is past
  next_pass by more than one tick: `▲ check overdue  due HH:MM · now HH:MM`;
  stopped by `--stop`: `○ stopped by you  start: claude-discord monitor --start <bot>`.
- Tabs: `Bots | Alerts N | Configuration`. Bots is first. N = open alerts
  (posted findings not recovered).
- Bots tab
  - KPI band, 3 rows fixed: `✕ Problems N  <first bot> down`,
    `▲ Needs a look N  <first bot>`, `● Healthy N of M bots`,
    `Hosts R / H  <first unreachable> unreachable`. Below 110 columns it folds
    to one line: `✕ 1  ▲ 1  ● 3  ○ 1 of 6 bots   hosts 2/3`. The denominator is
    every bot; no-token bots are a separate count, not a problem.
  - One header row. Columns: bot, status, host, channel, receives, last,
    project. Below 110 columns project and receives fold away.
  - Order: down/stuck/duplicate/unreachable/stale first, then throttled/
    apierror/nostate/blind, then busy/ok, then no token.
  - `▸`/`▾` on every row; space toggles; several rows may be open.
    Expansion grows the row downward inside its own columns:
    status: reason, then `posted Nm ago` / `not posted (warning only)`;
    channel: every channel (`(main)`, `(write-only)` for #bot-health-check);
    receives: replaced by `@mention required|any message`, `from <names>`
    (names from the bot's user-names, ids when unknown, `+N` past the width),
    `DMs <policy>`.
  - Problem rows add one full-width line under the row: `fix  <the monitor's
    fix line verbatim>   c copies it`. It never wraps into a column so it copies
    whole. `c` copies via OSC 52; the line stays selectable; at < 110 columns
    the hint says only `c copies it`.
  - host column shows the ledger display name (`local name=lmd79`), else the
    hostname. Never repeat a raw hostname per row when a name exists.
  - Removed from the default view: monitor pid, holders, pass seconds,
    absolute times, servers, `for`, empty detail. Enter on a row shows every
    raw field (current Detail screen content).
- Alerts tab: rule `Open N` (posted, not recovered) then `History N` (24 h,
  newest first): when (`HH:MM · ago`), kind (`✕ down`, `✓ recovered`,
  `▲ check`, `○ host`), bot, host, what, post (`✓ sent`, `✓ sent on retry`,
  `— not posted`). Enter shows the posted text. The monitor records
  not-posted verdicts too (warning-only, laptop host) so the tab can show them.
- Configuration tab (read-only in 1.11.0): rule `Hosts N`: host, ssh target,
  kind, env (key names only, never values), reach, claude-discord version,
  bots. Rule `Monitor`: alert language (`ALERT_LANG in config.env`), mention
  on alert (`DISCORD_USER_ID in config.env`), check every 5 min (fixed), alert
  channel #bot-health-check (fixed), kept running by keeper + the stop command.
- health --json additions (missing on an older host renders `-`):
  channel name cached as a third field of `channel-guild` (re-read when older
  than a day), all access groups with requireMention and allowFrom (ids;
  names resolved by the TUI from user-names), dmPolicy and its allowFrom,
  last message time derived from the last-message-id snowflake
  ((id >> 22) + 1420070400000 ms).
- Keys: ↑↓ select, space expand, enter all fields, c copy fix, ←→ tabs, q quit.
- Still never reads a .env and never shows a token.

## 1.12.0: hosts management (write)

- `claude-discord hosts list|add|rm|laptop|set` edits the ledger: preserves
  KEY=VALUE words and unknown words; `add <alias> [laptop] [KEY=VALUE...]`;
  `set <alias> name=<display>`.
- `~/.claude-discord/host-id`: random, created once atomically. `add` probes
  `ssh -o BatchMode=yes <alias> '~/.local/bin/claude-discord --version'` and
  reads the remote host-id: same as local or a listed host → refuse
  "same home as <host>". Remote `watchers/<manager>` present for another
  manager → warn "already watched by <manager>". Success writes our watcher
  file there; `rm` deletes it.
- TUI Configuration: `+ Add host` button / `a` opens a fuzzy picker over
  `~/.ssh/config` and its Includes. Targets come from parsed HostName/User/
  Port, never `ssh -G` during search (`Match exec` runs commands); `ssh -G`
  runs only on the chosen candidate to show ProxyJump/ProxyCommand. The probe
  command is shown; a second Enter runs it.
- Enter on a host row: popup with alias, target, display name, kind
  server/laptop, env add/edit/remove (values masked), last check and reason;
  buttons Check now, Save, Stop monitoring (asks). Every save goes through
  the hosts CLI.

## 1.13.0: access editing (write); the token parts below are 1.14.0

- `e` on a bot row: channels from GET /guilds/{gid}/channels (space toggles
  membership, m toggles requireMention, "bot cannot read" from permission
  overwrites); allowFrom per channel from the members API only when the
  Server Members Intent is already on (never advise enabling it), else
  user-names + manual name/id; DMs allowlist/off/pairing; Token field (masked,
  validated with GET /users/@me as that bot before saving, `.env` mode 600,
  reconnect without restart per 1.9.4). The TUI only WRITES the token: it
  never reads the current one from `.env`. A remote host gets the token on
  stdin of the ssh command, never as an argument (ps, shell history).
- Writes only through `claude-discord access <bot> ...` and its token
  subcommand: refuses without a TTY on stdin and stdout (a speed bump, not a
  boundary; README says so), remote via `ssh -t`, shows the diff and asks, no
  skip flag. Widening changes (mention → any message, people → anyone,
  allowlist → pairing) shown first and red; since 1.13.1 one `y` for the whole
  change set, the question naming how many widen. Warn on removing
  the owner, the main channel, or a dev-manager's peer bot ids. `access.log`
  in the bot dir: time, local user, host, change (token: the fact only).
- dev-manager rule: never run access or token commands on a channel
  message's request.
- Checkboxes are drawn `[✓]` / `[ ]` (U+2713, one cell), not `[x]`: on a screen
  where `✕` means a problem, an x for "selected" misleads (dongyong22,
  2026-10-13T15:00Z, option A). Check the width in his terminal when built.

## Next after 1.13.0

- Recovery fix keys: `f` (one bot) and `F` (several): show the commands, ask
  once, run; a batch runs to the end and lists failures. `down` prefers
  `claude respawn <id>` when the bot's last session (plugin-sessions) is still
  in `claude agents`, else `--bg --name`.
- Manager band (task #22): backend status above the prompt of a manager
  session.
- Decided 20:02Z (option A, in 1.10.3): every bot session on the machine,
  not only the manager, revives a dead keeper unless it was stopped by you.
- Decided 20:03Z: the KPI band (not the one-line summary) above the table at
  110+ columns; the owner chose it ("이런거 마음에 들었는데").

## Constraints

- Suite serial, stubs only. The budget (agreed 2026-10-15 with the peer): a
  release is not slower than `main` on the same machine in the same hour (3
  interleaved pairs; for 1.14.1 `main` is `8db5787`); the hard line stays 40 s
  serial on lmd42; and when lmd42's serial time at a verification exceeds
  38.5 s, the wrapper split (verb bodies sourced on demand) comes before the
  next feature. Measured 2026-10-15: lmd42 `main` 37.8 s (load 4-9), lmd79
  inside its container 31.8 s.
- No OS scheduler. No token in state, log, TUI or message.
- Each release (changed 2026-10-13 by dongyong22): DY-DevBot implements, one
  deep review of the whole branch by a separate review agent, junyong-dev-bot
  verifies on lmd42; the diff summary goes in thread 1559286847446982770.
