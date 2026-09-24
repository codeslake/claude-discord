# claude-discord

Run a Claude Code session behind its own Discord bot, so several sessions can
sit in one Discord channel. The human talks to each session by @mentioning its
bot. It is a bash wrapper around the official
`discord@claude-plugins-official` channel plugin; the session is an ordinary
`claude` REPL with a Discord channel attached, so `--resume`, `/rename`, your
settings, hooks and skills all work as usual.

Origin: written by d.kim4, extended here.

## Prerequisites

| Need | Why |
|---|---|
| Claude Code 2.1.x with channels support | `--channels` flag |
| `bun` | the plugin's runtime (`curl -fsSL https://bun.sh/install \| bash`) |
| `jq` | writes `access.json` and the settings files, reads the plugin's install path; every hook needs it too, and without it they silently do nothing |
| the plugin | `claude plugin install discord@claude-plugins-official` then `claude plugin disable discord@claude-plugins-official` (see below) |
| `curl` (optional) | the ✅ reaction on a finished reply, and the `tools/thread` helper; without it no reaction is sent and no thread can be opened, everything else still works |
| `python3` (optional, stdlib only) | `thread-guard` rewrites a markdown table in a reply into an aligned code block; without it a reply with a table is denied instead |
| `perl` | patches the plugin at every start, and detaches a `refresh` in its own session (macOS has no `setsid`) |

Disable the plugin globally after installing it: enabled globally, every
session without a bot token tries to start a Discord server. The wrapper
enables it per session with `--settings`.

## Glossary

- **session name**: the argument to `claude-discord <name>`. It becomes the
  Claude session's `--name`, the directory the bot's token lives in, and the
  identity in the system prompt. Not the Discord bot's display name; pick the
  same string for both so `@name` in the channel is unambiguous.
- **channel**: one Discord text channel shared by all your bots. Its snowflake
  ID is asked once and reused.
- **access.json**: the plugin's allowlist. Written at setup time; the plugin
  re-reads it on every inbound message, so hand edits apply without a restart.
- **project**: the directory you run `claude-discord` from. All state lives in
  `./.claude/discord-agents/` there, so a bot belongs to a project. With exactly
  one bot set up, naming it is optional; with several, the name is required.

## Discord side, once

1. Create a server and a text channel. Enable *User Settings → Advanced →
   Developer Mode*, right-click the channel → *Copy Channel ID*, right-click
   your avatar → *Copy User ID*. (Without developer mode, *Copy Link* on the
   channel gives `discord.com/channels/<server>/<channel>`; the last number is
   the channel ID.)
2. For each session you want, create an application at
   <https://discord.com/developers/applications>. *Bot* tab: *Reset Token* and
   copy it; turn **Message Content Intent** on (without it the bot cannot read
   messages); turn *Public Bot* off.
3. *OAuth2 → URL Generator*: scope `bot`; permissions *View Channels*, *Send
   Messages*, *Read Message History*, *Add Reactions*. Open the URL and invite
   the bot to your server.

## Install

```
./install.sh
```

puts `claude-discord` in `~/.local/bin/` and the helpers (`discord-proxy.ts`,
`hooks/`, `rules/`) in `~/.claude-discord/`. Re-run it after a pull. It also
removes every file under `~/.claude-discord/hooks/<topic>/` and
`~/.claude-discord/rules/` that the repo no longer ships (an earlier
version's `autoresearchclaw/watch` or `turn/on-compact`; `hooks/tools/` is
swept like any other topic directory); nothing else there
is touched.

## Usage

Run everything from the project directory; that is where the state goes.

```
cd ~/work/my-project
claude-discord setup alpha            # channel ID, your user ID, allowed IDs, alpha's token, mention policy
claude-discord setup beta             # only beta's token and mention policy: the IDs are shared
claude-discord alpha                  # start the session; the bot is online while it runs
claude-discord alpha --resume         # any claude argument passes through
claude-discord --bg alpha             # the name may sit before the flags too
claude-discord --bg --resume my-bot   # with one bot in the project, its name may be left out
claude-discord alpha --resume my-bot  # a session NAME or a short id also works, see below
claude-discord setup alpha --reset    # forget alpha's token and policy AND the shared IDs; ask everything again
claude-discord setup alpha --mode     # change only alpha's mode (and, for dev-manager, its peers); needs alpha already set up
claude-discord refresh alpha          # replace the running session with a fresh one, from its handoff
```

The setup prompts:

| Prompt | Stored in | Notes |
|---|---|---|
| Discord channel ID | `config.env` (shared) | also written as the channel group of each bot's `access.json` the first time it is set up. A running bot's channel is that group: to move one bot, edit its `access.json` (the plugin, the hooks' identity text and the start prompt all follow it; `config.env` is the fallback when the file has no single group). A setup re-run keeps `access.json` as it is, wherever its group has moved to, and only updates `requireMention` there; `setup ... --reset` (which deletes the bot's directory first) writes `config.env`'s channel into a fresh one |
| Your Discord user ID | `config.env` (shared) | the only user allowed to DM the bot |
| Other user or bot IDs | `config.env` (shared) | comma-separated; may be empty. These can trigger the bot in the channel |
| Bot token | `<name>/.env` | input is hidden, like a password. On a re-run, empty keeps the current token |
| Respond without an @mention? | `<name>/access.json` | default N. With Y the bot answers every channel message |
| Mode | `<name>/mode` | `none` (default), `dev-manager` or `autoresearchclaw`; see Modes below. On a re-run the picker starts at the current mode |
| Peer dev bots (dev-manager only) | `peers.json` (shared), `<name>/access.json` | `name:bot_id:owner_id:machine`, comma-separated; empty keeps the current list |

Everything lives under `./.claude/discord-agents/` in the project, mode 0700.
Setup writes a `*` `.gitignore` inside that directory, so the token can never
be staged even with `git add -A`; your project's own `.gitignore` is untouched.
A second project gets its own setup and its own bots.

## Modes

`setup` asks for the bot's mode with a picker (↑/↓ or k/j, Enter). Without a
terminal on stdin it reads one line instead: the mode's name or its number,
empty for the default (the current mode on a re-run).

| Mode | What it installs |
|---|---|
| `none` | nothing beyond the hooks every bot gets (the Discord-turn hooks and `thread-guard`) |
| `dev-manager` | for bots that change claude-discord together with peer bots on other machines: the rule `.claude/rules/claude-discord-dev-manager.md` (from `rules/dev-manager.md`) and the three dev-manager peers hooks below |
| `autoresearchclaw` | for a bot next to AutoResearchClaw runs in the project: the `autoresearchclaw/on-start` hook, which gives the bot's session `rules/autoresearchclaw.md`, so it reports each research iteration to the channel (see AutoResearchClaw reports below). No rule file in the project: every session under the project loads one, the pipeline's own agent sessions included. Give it to one bot per project: two such bots each report every iteration |

A dev-manager's setup also asks for its peers as
`name:bot_id:owner_id:machine`, comma-separated. They are merged by `bot_id`
into `.claude/discord-agents/peers.json` (one file per project, so the same
list can be pasted on every machine: each bot skips itself by name), and
every peer's `bot_id` is added to every group's `allowFrom` in this bot's
`access.json` (not the DM one). Peers need this bot's id in their own
`allowFrom` too; ask their owners.

What a project gets is the union over its bots' modes, re-synced by `setup`
and by every start: one dev-manager bot keeps the rule and the peers hooks in
place. Once no bot needs them they are removed: every
`.claude/rules/claude-discord-*.md` that no mode produces (that prefix belongs
to claude-discord; name your own rules differently), and every mode hook
entry (see Hooks: which file holds what) from both settings files, along
with a matcher group or an event left empty by that. Nothing else in either
place is touched.

The dev-manager rule file is loaded by every session in the project (subdirectory
sessions and plain `claude` sessions included), so it opens by telling a
session to ignore it unless its Discord-turn context has the `Dev manager:`
line, which `on-prompt` adds for a dev-manager bot only.

Every bot keeps one request per Discord thread (see Expected behaviour
below). The dev-manager rule adds what is its own: an item is a defect, a
feature, a measurement or a review, its back-and-forth with peers goes inside
its thread, and a decision only a human can make is one channel line naming
the thread. Scratch files belong
under `~/.claude-discord/scratch/<bot name>/` when they must survive, in
`/tmp` under a session-unique name when they need not -- never under
`~/.claude`, and `$CLAUDE_JOB_DIR` exists only in a background session.

Once a change to claude-discord itself is on main and installed here, that
same rule has a dev-manager tell the machine's OTHER claude-discord bots --
not its peers, its machine's other bots, in whatever other project runs one
-- `~/.claude-discord/hooks/tools/local-bots` prints them: every other live
bot session on this machine, one line per session as `<name><TAB><project
dir>`, sorted by name. Discovery is `claude agents --json` (active sessions
only: `--all` would add completed ones, retired bots among them; no filter on
the state, since a live bot can show `done`) filtered to
a session whose project has a `.claude/discord-agents/<name>` directory,
this bot's own session excluded by state dir; it prints nothing, never
fails, and is never registered as a hook.

## AutoResearchClaw reports

An `autoresearchclaw` bot posts one report per research iteration of the
AutoResearchClaw runs in its project, written by the bot's own session; nothing
in the channel steers a run, and gates are answered in the run's terminal.

- **Trigger.** An iteration ends when a run (`artifacts/rc-*/`) writes a new
  `stage-15/decision.md` (PROCEED, PIVOT or REFINE); a run ends when it
  writes `pipeline_summary.json`, aborted and failed runs included.
- **`hooks/autoresearchclaw/events`** prints one line per new event,
  `iteration-end <path>` or `run-end <path>` (relative to the project), and
  nothing otherwise. What it has seen is `.claude/discord-agents/<bot>/arc-seen`,
  one `<path> <cksum>` line per file and content: a relaunch that rewrites
  `decision.md` with other content is a new event, an identical rewrite is
  not. Its first call ever (no `arc-seen` yet) records what is there and
  prints nothing, so a project's history is not reported. It records before
  it prints, so to one caller at a time (one standing watch) no event is
  printed twice; two watches running at once can both print it. An empty
  file, or one written less than 2 s ago, waits for a later call
  (AutoResearchClaw writes both files non-atomically). Outside a bot session
  (no `DISCORD_STATE_DIR`) it exits 2.
- **Waking the session.** The session keeps one standing watch that runs
  `events` and wakes it when a line comes out: the machine's watch daemon if
  it has one, otherwise a background loop (`until e=$(events); [ -n "$e" ];
  do sleep 60; done`) it starts on its first turn and again after every
  report. It then reads the run's hypotheses (`stage-08/hypotheses.md`),
  that iteration's `stage-13` to `stage-15` files and the debate files, and
  posts one short Korean report with the reply tool: what was tried, the key
  numbers labeled measured or proposed, the decision and why, the next step.
  A run-end report adds the gist of `stage-18/reviews.md` when the run
  reached peer review.
- **Discussion.** Only when an owner asks does it talk to other research
  bots: one digest of its recent iterations, critique both ways, at most
  three messages each, then one summary for both owners.
- **Why SessionStart context, not a project rule.** The rules
  (`rules/autoresearchclaw.md`, installed to `~/.claude-discord/rules/`) reach
  the session through `on-start` as SessionStart context, at startup, resume,
  compact and clear. A `.claude/rules/` file would be loaded by every session
  under the project, AutoResearchClaw's own backend `claude` calls included,
  and they are not the bot. A `claude` started from the bot session's own
  Bash inherits its `DISCORD_STATE_DIR` and gets the context too.

## Resuming by name

`claude --resume` takes a full session id; a name only reaches its interactive
picker, which cannot appear under `--bg`. So the wrapper resolves the value
first, against the transcripts of the project you are in: a session name (what
`-n` set, or `/rename`) or a short id as `claude agents` prints it becomes the
full id, and it says so on stderr. A full id, or a name it cannot find, is
passed through and claude decides.

## Dead sessions in the agent view

Claude Code's daemon retires an idle background session after about an hour,
and nothing here ever removed the retired one (`refresh` stops a session, it
never `rm`s it), so the agent view grew by one dead entry per start: measured
2026-09-19, 7 rows for 2 bots, 4 of them dead. Every start now reaps its own
dead sessions first, with `claude rm`, which deletes the session and, if it
had one, its worktree. An entry goes only when all three hold: the name is
this bot's, the `cwd` is this project directory, and the state is `stopped` or
`done`. A live one (`idle`, `busy`, `waiting`, `working`, `blocked`), an
interactive entry with no state, another bot's entry and this bot's entry in
another checkout are all left alone, and so is the session a `--resume` on the
same command line points at, which is usually `done` and is exactly what the
start is about to reopen.

It is housekeeping, so it never costs the start. The listing gets 5 seconds
where `timeout` exists, and a missing `jq`, an answer that is not JSON, an
empty list or a failing call all skip the step with at most one line on
stderr. At most 20 sessions go per start, the oldest by `startedAt` first, so
a first run against a long-neglected daemon cannot turn a start into a minute
of `rm` calls; the next start takes the next 20. Both `claude agents --json
--all` and the `rm` calls run the `claude` binary itself rather than
`CLAUDE_DISCORD_LAUNCHER`: they are local daemon bookkeeping and start no
session.

## Expected behaviour

- In the channel, `@alpha do X` reaches session alpha only. A reply to one of
  the bot's messages also counts as a mention.
- Tool-permission prompts arrive as buttons in your DM with the bot.
- The bot is online exactly while `claude-discord alpha` runs. Registering
  alone shows nothing.
- With several bots in one channel, keep the default mention policy: with
  "respond without mention" on every bot, one human message gets one reply
  per bot.
- One request, one thread, for every bot whatever its mode. The session
  prompt (and `on-prompt`'s context, which survives `/bg`) tells it:
  `~/.claude-discord/hooks/tools/thread start "[<area>] <short title>"` posts
  that one short line in the channel, opens a thread on it
  (`auto_archive_duration` 1440) and prints the thread id; the full answer
  goes inside, with that id as `chat_id`. The line comes first on purpose:
  Discord opens a thread only from a message already in the channel, so
  starting one from the long answer would leave the long answer in the
  channel. When the request lands, one closing line goes in the channel and
  `thread close <thread_id>` archives the thread, which takes it out of the
  sidebar. The helper needs `DISCORD_STATE_DIR` (every hook and the bot's own
  session have it); `thread-guard` (see Hooks) keeps the channel to short
  lines.
- The session is an orchestrator, unless its mode's rules say otherwise:
  it answers a quick request itself and dispatches one that needs more than
  a few tool calls to a background subagent whose brief names the request's
  thread id, then posts the subagent's result in that thread. The session
  stays free for the next message, and requests from different people never
  share a context.

## Hooks

A message that arrives over Discord should be answered through the discord
reply tool only, not also typed into the CLI (that would waste a reply on a
channel nobody types into). Four hooks handle that, plus identity, a
"refresh" handoff trigger, and a ✅ reaction once a turn actually replies.
Each entry in the project's settings (see below for which file) execs the script directly
(`h="$CLAUDE_PROJECT_DIR/.claude/discord-agents/hooks/<topic>/<name>"; [ ! -x "$h" ] || "$h"`),
so a machine without the hooks installed simply runs nothing. Scripts live
under `hooks/<topic>/<name>` (paths below are relative to `hooks/`);
`lib/discord.sh` and `tools/thread`/`tools/local-bots` are not registered:
the first is sourced by every script below, the other two are run by the
session (see Modes and Expected behaviour above).

| Event | Matcher | Script | What |
|---|---|---|---|
| UserPromptSubmit | | `turn/on-prompt` | On a Discord turn (a prompt that opens with the plugin's `<channel source="plugin:discord:discord" ...>` tag), records that tag's chat_id/message_id/user_id for `on-stop` and `mention-guard` (only the leading tag is trusted: the plugin does not escape `<` in message text, so anything after it could be forged; a message arriving mid-turn comes as a prompt of its own and is appended) and, once per session (see below), adds an additionalContext entry with the bot's identity, the mention rule, the thread rule and the orchestrator rule; silent on a plain CLI turn and on a second-or-later turn in an already-primed session. A message that is exactly "refresh" (case-insensitive, mentions stripped, trimmed) also appends handoff instructions pointing at `claude-discord refresh <bot>` -- every time, primed or not. |
| PostToolUse | `mcp__plugin_discord_discord__reply` | `turn/on-reply` | Marks that this turn actually sent a Discord reply. |
| Stop | | `turn/on-stop` | If the turn sent a reply, reacts ✅ on every message `on-prompt` recorded for it; always clears the per-turn files either way. |
| SessionStart | `startup\|resume\|compact\|clear` | `turn/on-session-start` | After a compact or `/clear`, clears the per-session "primed" flag, so the next Discord turn injects the identity context again. At a startup or resume, clears the per-turn files a turn whose Stop never ran (an interrupt, a kill) left behind, keeping the primed flag (a resumed conversation still holds that context), then pins a background session's job (see Background sessions below). An `on-compact` entry an earlier version registered is replaced. |
| PreToolUse | `mcp__plugin_discord_discord__reply` | `peers/mention-guard` | dev-manager only. Denies a reply that names a peer (a whole word, case-insensitive) without its `<@bot_id>` or `<@!bot_id>`, or that answers a peer without mentioning it: the author of the message in `reply_to` when that is set, else of the turn's last message. A bot only receives messages that mention it. |
| PostToolUse | `mcp__plugin_discord_discord__reply` | `peers/checkin` | dev-manager only. A reply that mentions a peer (`<@bot_id>` or `<@!bot_id>`) touches `.claude/discord-agents/checkin/<session_id>`. |
| PreToolUse | `mcp__plugin_discord_discord__reply` | `peers/thread-guard` | Every bot (it reads no peer). Discord renders no markdown table, so a table outside a fenced code block is rewritten into a fenced code block with its columns aligned by display width (a Korean character counts 2), alignment colons honoured and `**`, `__` and backticks stripped from the cells; a table with a line over 72 columns (a guess at a phone's code-block width) becomes one `header: value · ...` line per row instead. The reply goes out through `updatedInput`, the whole input with only `text` changed. Then, for every bot but autoresearchclaw, whose rule posts one report per iteration in the channel: denies a reply to the CHANNEL (a `chat_id` equal to the bot's channel; a thread has an id of its own) longer than 500 characters once converted, counted in characters and not bytes, so the long text goes in the request's thread and the channel keeps one line. |
| PreToolUse | `Edit\|Write\|MultiEdit` | `peers/edit-gate` | dev-manager only. Denies an edit under a path whose realpath contains `/claude-discord/` unless the session checked in within the last 60 minutes; an allowed edit renews the check-in. Paths git ignores (a bot's state such as the refresh `handoff.md`, `.superpowers/`) pass. Bash and git edits are not seen; the rule asks for the same announcement by hand. |
| SessionStart | `startup\|resume\|compact\|clear` | `autoresearchclaw/on-start` | autoresearchclaw only. Prints the installed `rules/autoresearchclaw.md` as the session's additionalContext (nothing when the file is missing); starts no process. An entry an earlier version registered with `startup\|resume` is replaced. See AutoResearchClaw reports above. |

Which file holds what:

- The four `turn/` hooks and `peers/thread-guard` go into
  `.claude/settings.json`. Every bot on every machine gets the same five, so
  this file can be committed and shared.
- Every mode hook (the other three `peers/` hooks while some bot in the project is
  a dev-manager, `autoresearchclaw/on-start` while one is autoresearchclaw;
  see Modes) goes into
  `.claude/settings.local.json`. Which modes a project has depends on the
  bots THIS machine runs; in a committed `settings.json` these entries would
  flip on every start of a machine with other bots. `settings.local.json`
  is Claude Code's per-machine settings file; keep it out of git. Cleanup
  removes stale mode entries from both files, so the ones an earlier
  version put into `settings.json` move over on the next start, and a
  `thread-guard` entry in `settings.local.json` moves to `settings.json`.

Both `setup` and the start path register them, so a bot set up before this
existed gets them on its next start too. `mention-guard`, `checkin` and
`edit-gate` do nothing in a session whose bot is not a dev-manager, and also
nothing without `peers.json`; `thread-guard` guards every channel reply but an autoresearchclaw bot's;
`autoresearchclaw/on-start` does nothing for a bot in another mode. `on-prompt`
also records each message's sender (`user_id`) for `mention-guard`, and
gives a dev-manager its peers' mentions and the working rule once per
session. Registration is idempotent per entry,
leaves every other key in either file alone, and writes a file only when it
changes (Claude Code keeps its permission grants in `settings.local.json`); a
session already running picks up a hook added to its settings files without
a restart. To remove them, delete their entries from `.hooks` in those
files.

The identity/mention-rule context is long, so `on-prompt` injects it once per
session (a `turns/<session_id>.primed` marker holding the bot's mode and a
checksum of the context text), not on every turn -- a compaction or `/clear`
drops it from the transcript, which is what `on-session-start` is for, and a
changed mode or a changed text injects it again. So after `./install.sh`
changes the context, a running bot re-primes by itself on its next Discord
turn, once. The session prompt (`--append-system-prompt`) is fixed when the
session starts and still needs a restart (`claude-discord refresh <bot>`, or
stop and start). The "refresh" handoff still fires on every matching
message regardless of the primed state, since it is a specific command, not
boilerplate.

Both also make `.claude/discord-agents/hooks` in the project a symlink to
`~/.claude-discord/hooks/` (only when that path is absent or already a
symlink; a real directory there is left alone with a warning), so
`./install.sh` after a pull reaches a session that is already running too --
no restart needed there either.

The 👀 reaction on receipt is not a hook: it is the plugin's own
`ackReaction` in `access.json`, added the same never-overwrite-when-present
way (an explicit `""` means the owner disabled it, and is kept).

## Bots hearing each other

The upstream plugin ignores every message whose author is a bot
(`server.ts`: `if (msg.author.bot) return`). At each start the wrapper patches
that one line to ignore only the bot's own messages, so other bots reach the
allowlist like anyone else: add their IDs at setup or in `access.json`, and
they must @mention your bot unless you turned the mention policy off. The
patch is idempotent and re-applied every start because a plugin update replaces
the plugin directory. If upstream changes that line, the patch silently no-ops
and bots go back to ignoring each other.

`on-prompt` (see Hooks above) tells the session to mention a bot only when it
needs that bot to act or answer, and to stay silent if it was mentioned but
nothing was asked of it, so two bots don't @mention each other into a loop.

A second one-line patch, applied the same way, stops `@everyone` and `@here`
from counting as a mention of every bot (discord.js's default), so one
broadcast in the channel does not wake every session.

## Background sessions

`/bg` inside the session, or `claude-discord alpha --bg` from the start, moves
the session under Claude's background daemon; the bot stays online and
@mentions keep arriving. The daemon restarts a session from its command-line
flags alone and drops the shell environment, so the wrapper passes the state
directory (where the token lives) inside `--settings` as well as in the
environment; measured 2026-09-18, a fork made by `/bg` had no
`DISCORD_STATE_DIR` and its plugin server died silently. Three things to know:

- The `/bg` fork does not carry `--append-system-prompt`, so the identity
  paragraph from the system prompt is gone after `/bg`. `on-prompt` re-adds
  identity, the mention rule and the thread and orchestrator rules on the
  next Discord turn regardless (once per
  session, see Hooks above), so this only matters for a turn typed straight
  into the CLI after `/bg`. The transcript still holds everything said so far.
- One token, one session. After `/bg` the foreground REPL exits; do not start
  `claude-discord alpha` again while the background copy runs, or both answer
  every mention.
- Every start also sets `worktree.bgIsolation: "none"` in `--settings`,
  turning off Claude Code's background-isolation guard for claude-discord
  sessions only: measured on two machines, a session started with `--bg` was
  otherwise refused Edit/Write in the project checkout by that guard, while a
  session moved to the background with `/bg` from the foreground was not --
  this makes a `--bg` start behave the same way `/bg` does, without any
  change to the project's own settings.json. Edits land in the working copy
  instead of an isolated worktree, which is the point for a bot editing its
  own project. It is inert for a foreground start, and a session already
  running keeps whatever flags it started with until relaunched.

### Pinned, so the daemon keeps it

The daemon retires a background session about 60 minutes after its last
input, so a bot nobody talked to for an hour went offline. A pinned job is
exempt: measured 2026-09-19, of identical idle probes the unpinned one died on
its predicted sweep and the pinned one survived. So `on-session-start` pins
every background bot at startup and resume: it adds the session's job id (the
basename of `$CLAUDE_JOB_DIR`) to `~/.claude/jobs/pins.json`, the file the
agent view's `ctrl+t` writes, and removes the id this bot pinned last time
(kept in `.claude/discord-agents/<bot>/pinned-job`). No other entry is
touched, a file that is not a JSON array of strings is left alone, and the
write takes the CLI's own lock (the directory `pins.json.lock`), skipping the
start when another process holds it. A foreground bot has no job and pins
nothing, and neither does a session that merely inherited `$CLAUDE_JOB_DIR`
from a background session's shell: the job's `state.json` must name this
session. To undo: `ctrl+t` on the bot in the agent view (`claude agents`), or
delete its id from `pins.json`; the bot's next start pins it again. An id
already in the file is left there and is not recorded as the bot's, so a pin
a human added is never removed later.

Where the CLI stores pins in its v5 backend instead, they live under a
storage key and the CLI may not read `pins.json` at all, so the pin does
nothing there and nothing in the hook can tell. To check by hand: while a bot
is pinned, `grep "bg retire <its job id>" ~/.claude/daemon.log`. A line there
means pins do not work on that machine.

## Refreshing a session

A long-running session answers worse as its context fills, and the automatic
compaction that Claude Code does when the window is nearly full summarises at
exactly the point the model is least able to judge what matters.
`claude-discord refresh alpha` replaces the session on purpose instead, while
it can still choose well:

1. The session writes `handoff.md` in its own state directory — unanswered
   requests first (someone is waiting), then work in flight with each claim
   marked `[verified]` or `[assumed]`, decisions with their reasoning, and what
   to do next. A channel message that is exactly `refresh` triggers this
   through the hooks, which also give the exact format.
2. It runs `claude-discord refresh` (from its own shell, wherever that shell
   has wandered: the state directory is in the session's environment, so the
   name may be left out). The wrapper refuses without a handoff (`--force`
   skips that, for a session too wedged to write one), then hands the rest to
   a detached child, because the next step kills the session that ran the
   command.
3. The child stops the live session registered under the bot's name and this
   project directory (a background one through `claude stop`, a foreground one
   with SIGTERM), waits until its process is gone and a moment more for the
   token to be released, and starts a fresh `--bg` session with a first turn
   that tells it to catch up. A prompt given to `refresh` (a bare word after
   the name, as in `claude-discord refresh alpha "summarize the last hour"`)
   is that first turn instead of the default one; claude flags pass through. That launch folds `handoff.md` into the system
   prompt and moves the file to `handoff.prev.md`, so a later start through the
   wrapper does not resume a conversation that has moved on. (A crash respawn
   by Claude's daemon reuses the flags of the launch, handoff included.)

Stop before start, never the reverse: two sessions on one token both answer.
So a session that is still running ten seconds after its stop is reported and
nothing is started; and a refresh that finds no live session to stop refuses
rather than start one (the bot may be running under another name or from
another directory); `--force` overrides that too, but not a `claude agents`
listing that failed outright, which says nothing about what is running.
Messages that arrive in the
gap are not redelivered, so the fresh session is told the id of the last
message its predecessor saw (the hooks keep it in `last-message-id`) and to
read the channel from there before doing anything else.

A crash is handled by Claude's own daemon (it restarts a `--bg` session from
its flags), not by the wrapper, so the plugin patches the wrapper applies at
launch are not re-applied there. After a plugin update, start the session
through the wrapper once more.

## Behind a corporate proxy

bun's `fetch` honours `HTTPS_PROXY`; bun's `WebSocket` does not, so the Discord
gateway connection alone goes direct and dies on TLS interception.
`~/.claude-discord/discord-proxy.ts` is a bun preload that pins both to
`HTTPS_PROXY`. It does nothing when the variable is unset, so it is safe
everywhere; the wrapper only wires it in (via the plugin's `bunfig.toml`) when
the file exists. Your proxy must forward `discord.com` and `discord.gg`; the
CDN domains carry real certificates and can stay direct.

## If your `claude` is wrapped

`claude-discord` is bash: it runs the `claude` binary on `PATH`, never a shell
function or alias. If your shell wraps `claude` in a process wrapper (a proxy
chain, a version pin), the session is started as
`<wrapper> <claude-bin> <args>`, the same way your shell would. The wrapper is
`CLAUDE_DISCORD_LAUNCHER` if you set it, otherwise Claude Code's own
`CLAUDE_CODE_PROCESS_WRAPPER`, read from the environment or, failing that, from
`.env.CLAUDE_CODE_PROCESS_WRAPPER` in `~/.claude/settings.json` (the same file
Claude Code itself reads it from). Between the two, most setups already have
`CLAUDE_CODE_PROCESS_WRAPPER` set one way or the other, so `CLAUDE_DISCORD_LAUNCHER`
is only needed when `claude-discord` should use a different wrapper than the
rest of Claude Code.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Bot online but silent when a teammate @mentions it | their user ID is not in the group `allowFrom`; add it at setup or in `access.json` |
| Bot cannot read message text | Message Content Intent is off in the Developer Portal |
| Gateway connection fails behind a proxy | `discord-proxy.ts` missing from `~/.claude-discord/`, or `HTTPS_PROXY` unset in the shell that ran `claude-discord` |
| Bot answers in the foreground, silent after `/bg` | wrapper older than 2026-09-18 (state dir not in `--settings`); reinstall |
| Every bot in the channel answers one message | someone wrote `@everyone`/`@here` with a wrapper older than 2026-09-18, or the mention policy is off on all of them |
| `no bot '<name>' under ./.claude/discord-agents` | no setup in THIS directory; `cd` to the project you set it up in, or run setup here |
| `bot name must be a plain directory name` | the name contained `/`, or was `.`/`..` |
| `bot name 'hooks'` (or `'checkin'`) `is reserved` | those names are claude-discord's own directories under `.claude/discord-agents/`; pick another |
| Two bots answer each other forever | the mention policy is off on both; turn it back on for at least one |
| `Over 500 characters in the channel: start a thread ...` | the bot tried to put a long answer in the channel; `thread start "[<area>] <short title>"`, then post it inside the thread |
| `Discord does not render markdown tables: rewrite it as a list, ...` | `thread-guard` found a table it would not rewrite: the reply has an odd number of ``` marks (a lone ``` in prose, or a fence that never closes), or `python3` is missing or failed. Close every fence or drop the stray mark; put `python3` on the bot's PATH |
| `Before changing claude-discord, announce on Discord ...` | a dev-manager edited claude-discord without mentioning a peer in the last 60 minutes; announce the change, then edit |
| `claude-discord: ~/.claude-discord/rules/dev-manager.md is missing` | wrapper newer than the installed helpers; re-run `./install.sh` |
| `refresh` says `handoff.md is missing or empty` | the session did not write it; ask it to, or pass `--force` |
| `refresh` says `no running session named <name> started in <dir>` | the session was renamed (`/rename`) or started elsewhere; `claude agents` shows it, stop it by hand, then `refresh --force` |
| The agent view still lists dead sessions of my bot | a start removes only its own (the session and, if it had one, its worktree): another name's, another project's and the one a `--resume` names are left alone on purpose, and only 20 go per start (oldest first), so start again for the next 20. Otherwise the wrapper predates 2026-09-19 (reinstall), or `claude agents --json --all` is not answering: run it by hand |
| No report after an iteration | the bot's `mode` is not `autoresearchclaw`; the session has no standing watch running `events` (ask it to start one); the session started before the mode was set (the rules arrive at session start: restart or `/clear` it); or the runs are not under `artifacts/rc-*/` of the project the bot was set up in. `<bot>/arc-seen` lists what `events` has already reported (running `events` by hand records what it prints, so the watch will not see it again) |

## Test

`./test-claude-discord.sh ./claude-discord` runs the wrapper against a
throwaway HOME with a stub plugin and stub `claude`; it touches nothing real
and prints `ALL PASS`.
