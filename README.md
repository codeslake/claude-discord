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
| `jq` | writes `access.json` and the settings files, reads the plugin's install path; every hook needs it too, and without it they silently do nothing. 1.7 or newer is recommended: jq 1.6 (still `/usr/bin/jq` on Ubuntu 22.04) takes about 10 ms to start against 2 ms, and a prompt runs it two or three times (the suite: 40 s against 31.5 s on one machine). The official static `jq-linux-amd64` in `~/.local/bin` needs no root |
| the plugin | `claude plugin install discord@claude-plugins-official` then `claude plugin disable discord@claude-plugins-official` (see below) |
| `curl` (optional) | the ✅ and ☑️ reactions at the end of a turn, and the `tools/thread` helper; without it no reaction is sent and no thread can be opened, everything else still works |
| `python3` (optional, stdlib only) | `thread-guard` rewrites a markdown table in a reply into an aligned code block; without it a reply with a table is denied instead |
| `perl` | patches the plugin at every start, and detaches a `refresh` in its own session (macOS has no `setsid`) |
| `git` | `setup` clones claude-discord, `update` pulls it |
| `ssh` (manager bots only) | the backend monitor runs `health --all` on each ledger host over it, with `BatchMode=yes` |
| `uv` (the TUI only) | `claude-discord tui` runs a Python + Textual script through `uv run --script`; nothing else needs it |

Disable the plugin globally after installing it: enabled globally, every
session without a bot token tries to start a Discord server. The wrapper
enables it per session with `--settings`.

## Glossary

- **session name**: the argument to `claude-discord --name <name>`. It becomes the
  Claude session's `--name`, the directory the bot's token lives in, and the
  identity in the system prompt. Not the Discord bot's display name; pick the
  same string for both so `@name` in the channel is unambiguous.
- **channel**: one Discord text channel shared by all your bots. Its snowflake
  ID is asked once and reused.
- **access.json**: the plugin's allowlist. Written at setup time; the plugin
  re-reads it on every inbound message, so a change applies without a restart.
  Changed with `claude-discord access` (Who may drive a bot), or by hand.
- **`$CLAUDE_DISCORD_TOOLS`**: the plugin's `tools/` directory (`thread`,
  `local-bots`, `arc-events`). Not a shell variable: the plugin's SessionStart
  hook states `CLAUDE_DISCORD_TOOLS=<path>` in a bot session's context, and the
  commands in this README are run with that path. From a terminal use
  `<clone>/tools`, e.g. `~/.claude-discord/source/tools`.
- **ledger**: `<project>/.claude/discord-agents/<manager bot>/hosts`, the ssh
  hosts a manager bot's monitor checks. Its existence is the monitor's on/off
  switch.
- **backend**: a manager bot's keeper and the monitor it keeps up. It runs
  on its own, with no session and no TUI, until `claude-discord monitor --stop`.
- **holder**: a process recorded next to the monitor: its keeper, or an open
  TUI. The record is what the TUI shows and a hint that saves a fork;
  `keeper.lock` decides whether a keeper runs. The monitor does not exit for
  want of one.
- **keeper**: `claude-discord monitor --keep <manager>`: it keeps the monitor
  up with nothing else open. setup, the TUI and a manager session start one.
- **finding**: a verdict that needs a human (`down`, `stale`, `duplicate`,
  `unreachable`, `nostate`, `throttled`, `apierror`, `patchfail`, `hostdown`,
  `blind`). `ok` and `busy` are not findings; `noreach` is logged, never posted.
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

claude-discord is a Claude Code plugin: the repo itself is the plugin (hooks,
rules, tools and the launcher), and `install` (or `setup`, which runs it
first) puts one copy of it where Claude Code loads it. A machine's first
install, from the project directory:

```
git clone https://github.com/codeslake/claude-discord ~/.claude-discord/source && ~/.claude-discord/source/bin/claude-discord install
```

then `claude-discord setup <bot>` there for each bot. `install` reads no stdin
at all and is safe to re-run (a bootstrap script calls it); it installs or
refreshes the plugin, the shim, `~/.claude-discord/runtime/`, the compat copy
(see Migrating) and the install record, and it ends by patching the official
discord plugin's cache (as `claude-discord patch` does). Without flags it takes the install
already there, else scope project and method link, and in an untrusted
project it prints a one-line hint instead of asking. `~/.claude-discord/source`
is the machine's **source clone**; nothing is removed from it afterwards.
`setup` asks two questions once per project, before any bot question, so a
failed clone writes no bot file (Enter takes the default; `--scope` and
`--method` answer them for a script):

| Question | Choices |
|---|---|
| scope (`--scope project\|global`) | **project** (default): the plugin at `<project>/.claude/skills/claude-discord`, loaded only there. **global**: `~/.claude/skills/claude-discord`, loaded in every project. A plugin present at both scopes loads once (the global copy wins), so both scopes may hold an install only when both are links to the source clone (the same code); with a clone on either side `setup` and `install` refuse and name the existing path. A bot in `$HOME` gets the global install (its project `.claude` is `~/.claude`), and setup says so |
| method (`--method link\|clone`) | **link** (default): that path is a symlink to the source clone, so one `claude-discord update` moves every bot on the machine. **clone**: its own git clone, so this install can pin a version (`git -C <path> checkout <tag>`) and `update` moves it separately |

A project that already has an install at either scope uses it and asks
nothing; re-running `setup` keeps an existing link or clone as it is. In a git
repository the project install is added to the repo's `info/exclude`, so it
never shows in `git status`. Project scope loads only when
`~/.claude.json` has `projects[<path>].hasTrustDialogAccepted = true` for that
exact path: `setup` says so when it is missing and offers to write it (it never
does silently); `install` only says so.

`setup` also installs the launcher, a short shim at
`~/.local/bin/claude-discord`. It finds the wrapper for the current directory:
`<project>/.claude/skills/claude-discord/bin/claude-discord` (the nearest
ancestor holding `.claude/discord-agents` or that install), else
`~/.claude/skills/claude-discord/bin/claude-discord`, else the machine's source
clone, `~/.claude-discord/source/bin/claude-discord`, else it says claude-discord
is not set up on this machine and how to clone it. Each project therefore runs
the version installed for it, and a project with no install of its own (a new
one, or one not yet migrated) still reaches `setup`, a launch, `update` and
`--version` through the source clone. Put `~/.local/bin` on your `PATH`.

### Update, version, patch

```
claude-discord install         # the plugin, shim, runtime and compat copy for this project; no bot questions; safe to re-run
claude-discord update          # git pull --ff-only the clone this runs from (a link resolves to the source clone), re-patch, refresh the compat copy and the shim
claude-discord update --all    # every recorded install, each real clone once however many links point at it; a removed project is pruned
claude-discord --version       # claude-discord <version> (<short sha>) of that clone
claude-discord patch           # patch every cached copy of the official discord plugin (also done at each start and by update)
```

`update` prints `claude-discord <clone>: <old> -> <new>` and exits 1 when a
clone cannot fast-forward (local changes, a diverged branch, no network), the
patches no longer match or the shim cannot be written, after trying the rest.
A clone checked out at a tag or sha is pinned on purpose: it is reported as
`pinned at <sha>, skipped` and is not a failure. The patch step and the shim come
from the source clone's code when there is one (it is the machine's default and
owns the shared `~/.claude-discord/runtime/`), else from the clone just pulled;
so run `update --all` to move the source and a project's own clone together.
The hook scripts and tools run from the clone on disk, so a running bot uses the
new ones at its next hook call. What waits for `/reload-plugins` is the plugin's
manifest and `hooks/hooks.json` (which hooks are registered) and, in a bot, the
session prompt (`claude-discord refresh <bot>`); a bot runs `/reload-plugins`
through the self-reload skill. `~/.claude-discord/runtime/` holds the
two runtime files the patched official plugin imports (`discord-chunk.ts`,
`discord-proxy.ts`), copied there from the clone by `setup` and `update`, because
the official plugin's cache is machine-wide while clones are per project.
`runtime/VERSION` names the version that wrote them: an older wrapper (a
pinned clone, say) leaves a newer runtime and the patched cache alone and says
so, instead of flipping them back at its every start.

### Migrating from the previous release

On each machine, once:

1. `git clone` the source (above), then run `claude-discord setup <bot>` in each
   project (the shim reaches the source clone from a project that has no install
   yet, so a project not yet migrated can still be set up, launched and
   refreshed; Enter keeps each of the bot's current answers, `requireMention`
   included, so only the install questions are new). It installs the plugin and
   replaces the old `~/.claude-discord/hooks`, `rules` and `discord-*.ts` copies.
   It removes nothing from the project: the old settings hook entries and the
   `.claude/rules/claude-discord-*.md` file keep the bot working until the
   plugin's hooks run.
2. Run `/reload-plugins` in each running bot (the self-reload skill). On the
   plugin's first hook run in that session, it records the session
   (`<bot dir>/plugin-sessions/<session id>`) and removes this project's own old
   entries from `.claude/settings.json` and `.claude/settings.local.json` (each
   only when it is a regular file) and the `.claude/rules/claude-discord-*.md`
   files. That one event may run both the old and the plugin's hook once (a
   doubled turn record, a doubled ✅ attempt); from the next one, an old hook in
   a recorded session exits at once. A bot whose plugin never loads (an
   untrusted project, a `/reload-plugins` not yet run) keeps its old hooks.
3. `claude-discord --version` and `claude-discord health` confirm.

A settings file the plugin never edits keeps its old entries: a symlinked
`settings.json` (a dotfiles repo, say) and the user-global
`~/.claude/settings.json`. In a session the plugin runs in they exit at once,
but the first event of every new session still runs them once beside the
plugin's. `setup` names such a file with the command that removes the entries
by hand (`bash <plugin>/hooks/lib/old-hooks.sh <file>...`; for a symlink it
renames a new copy over the target, so the link stays); commit the change
where that file lives. **Those entries still serve every bot on this machine,
and on every machine sharing that file (a dotfiles repo), whose plugin is not
loaded yet:** removing them early silently takes ✅, mention-guard, edit-gate
and thread-guard from those bots. Run the command only once each of them has a
`<bot dir>/plugin-sessions/` marker.

For this release `~/.claude-discord/hooks/{turn,peers,lib,autoresearchclaw}`,
`hooks/tools/*` and the two `.ts` files stay as links, so a project not yet
migrated keeps working through them; they go in the next release. The hooks and
tools links lead into `~/.claude-discord/compat/`, a plain copy (no git) of the
plugin's hooks, tools and rules that `setup`, `install` and `update` refresh, so
the previous release's `install.sh` writing through them never reaches a git
clone; the `.ts` links lead into the runtime copy. `~/.claude-discord/rules/` is
removed. `compat/VERSION` holds the HEAD sha of the clone it was copied from;
a bot's startup or resume (its `on-session-start` hook, run from the source
clone when the machine has one) rebuilds `compat/` when that sha is not its
own (a `git pull` by hand in `~/.claude-discord/source`) or a
file there is newer than `VERSION` (`install.sh` wrote through a link). The new
copy is built beside it and renamed into place, so bots starting together never
see a half-written one.

Rollback: remove the plugin installs (or they keep loading next to the
re-registered settings hooks) and the links above (`./install.sh` would write
through them into the compat copy) first:

```
while IFS= read -r p; do if [ -L "$p" ]; then rm -f "$p"; elif [ -d "$p/.git" ]; then rm -rf "$p"; fi; done < ~/.claude-discord/records/installs
rm -rf ~/.claude-discord/hooks ~/.claude-discord/discord-chunk.ts ~/.claude-discord/discord-proxy.ts   # only links remain there
cd ~/.claude-discord/source && git checkout 2d22fca && ./install.sh   # 2d22fca: the last release before the plugin
```

(`rm -rf` on a link removes the link, not its target.) The sessions' `plugin-sessions/` markers need no cleanup: with no plugin install left, an old-path hook runs again even in a marked session.

## Usage

Run everything from the project directory; that is where the state goes.

```
cd ~/work/my-project
claude-discord setup alpha            # channel ID, your user ID, allowed IDs, alpha's token, mention policy
claude-discord setup beta             # only beta's token and mention policy: the IDs are shared
claude-discord --name alpha           # start the session; the bot is online while it runs
claude-discord --name alpha --resume  # any claude argument passes through
claude-discord --bg --name alpha      # -n alpha and --name=alpha work too
claude-discord --bg --resume 3bf66a89 # the bot comes from that session's job record (8+ hex), else a value naming a bot (--resume alpha), else the one bot in the project
claude-discord --name alpha --resume my-bot  # a session NAME or a short id also works, see below
                                      # (the positional "claude-discord alpha" still works and warns; a live session is not resumed, use refresh)
claude-discord setup alpha --reset    # forget alpha's token and policy AND the shared IDs; ask everything again
claude-discord setup alpha --mode     # change only alpha's mode (and, for dev-manager, its peers); needs alpha already set up
claude-discord refresh alpha          # replace the running session with a fresh one, from its handoff
claude-discord health                 # is every bot in this project still answering? see below
claude-discord tui [<manager>]        # the manager bot's monitor, its hosts and its bots' access, from any directory; see The monitor and the TUI
claude-discord access <bot> --json | set <change>...   # who may drive a bot: its channels, senders, DM policy and mode; see Who may drive a bot
claude-discord monitor --stop <manager>   # stop the manager's backend (keeper and monitor) until --start <manager>
claude-discord update [--all]         # see Install
```

The launch mirrors `claude`: `--name`/`-n` IS the bot and the session name, and
every other argument passes through to `claude` unchanged. `--resume <id|name>`
finds the bot from that session's job record (else a value naming a bot, else
the project's only bot, else it asks for `--name`) and refuses a live session,
naming both ways out: `claude-discord refresh <bot>` to replace it, or, when
that session is dead but `claude agents` still lists it as done,
`claude stop <job id>` (the id the refusal prints) and then the same
`--resume`. The positional form `claude-discord alpha ...` still works this
release and prints one deprecation line; beside `--name`
(`claude-discord alpha --name beta`) it is refused, naming both forms. The subcommands (`setup`, `refresh`, `health`,
`update`, `patch`) keep the bot positional.

The setup prompts (piped answers are one line per prompt; stdin ending before
a required answer exits 2 with a message, while the mode and peers prompts take
their default):

| Prompt | Stored in | Notes |
|---|---|---|
| Discord channel ID | `config.env` (shared) | also written as the channel group of each bot's `access.json` the first time it is set up. A running bot's channel is that group: to move one bot, edit its `access.json` (the plugin, the hooks' identity text and the start prompt all follow it; `config.env` is the fallback when the file has no single group). A setup re-run keeps `access.json` as it is, wherever its group has moved to, and only updates `requireMention` there (a channel left empty at setup is filled in, see "Start now, register the bot later"); `setup ... --reset` (which deletes the bot's directory first) writes `config.env`'s channel into a fresh one |
| Your Discord user ID | `config.env` (shared) | the only user allowed to DM the bot |
| Other user or bot IDs | `config.env` (shared) | comma-separated; may be empty. These can trigger the bot in the channel. Answer `all` instead to let **everyone who can post in that channel** trigger it — the group's `allowFrom` is written empty, which is how the plugin spells "no filter". Anyone who can post there can then drive a session that has shell access on that machine, and that includes every other bot in the channel (the wrapper patches the plugin to let bot authors reach this gate). The plugin counts a reply to one of the bot's own messages as a mention, so two open bots can answer each other without end even with the mention requirement on; with "Respond without an @mention" set to Y they will. `all` is **not** stored in the shared `config.env`, so it applies to the bot being set up and no other; a bot set up later inherits the stored IDs and stays closed, and `setup <name> --reset` is how you answer again (it clears the token and shared IDs too); to open a bot that already exists without re-answering, set its channel group `allowFrom` to `[]` in `access.json` by hand. `all` cannot be mixed with IDs, and DMs stay owner-only either way |
| Bot token | `<name>/.env` | input is hidden, like a password. On a re-run, empty keeps the current token |
| Respond without an @mention? | `<name>/access.json` | default N for a new bot; on a re-run Enter keeps the bot's current `requireMention`. With Y the bot answers every channel message |
| Mode | `<name>/mode` | `none` (default), `dev-manager` or `autoresearchclaw`; see Modes below. On a re-run the picker starts at the current mode |
| Peer dev bots (dev-manager only) | `peers.json` (shared), `<name>/access.json` | `name:bot_id:owner_id:machine`, comma-separated; empty keeps the current list |

### Start now, register the bot later

A session can start before its Discord bot and channel exist, and pick them
up later without a restart:

```
claude-discord setup alpha        # Enter at the channel, user ID, other IDs and token prompts
claude-discord --bg --name alpha  # runs now; its Discord server waits for a token instead of failing
# ... later, once the bot and channel exist:
claude-discord setup alpha        # asks the IDs again (they are empty) and the token: give the real ones
claude-discord health             # the bot should answer
```

The running session's Discord server re-reads `<name>/.env` every 10 s and logs
in once a token is there (`claude-discord patch` makes the official server wait
for a missing token instead of exiting, which Claude Code would mark failed and
not retry for 15 minutes). A token Discord refuses is waited out the same way: the server says so once on stderr and logs in again when `.env` holds a different token. The second setup
replaces the empty IDs in `config.env` and turns `access.json`'s empty group key
and allowFrom entries into the channel and IDs, keeping any other field. The
session's start prompt still names no channel until its next start; replies go
where each message came from, so nothing depends on it. A tool called before
the login fails with discord.js's error instead of reaching Discord.

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
| `dev-manager` | for bots that change claude-discord together with peer bots on other machines: the rule `rules/dev-manager.md`, which the plugin's SessionStart hook gives this bot's session as context, and the three dev-manager peers hooks below |
| `autoresearchclaw` | for a bot next to AutoResearchClaw runs in the project: the `autoresearchclaw/on-start` hook, which gives the bot's session `rules/autoresearchclaw.md`, so it reports each research iteration to the channel (see AutoResearchClaw reports below). No rule file in the project: every session under the project loads one, the pipeline's own agent sessions included. Give it to one bot per project: two such bots each report every iteration |

A dev-manager's setup also asks for its peers as
`name:bot_id:owner_id:machine`, comma-separated. They are merged by `bot_id`
into `.claude/discord-agents/peers.json` (one file per project, so the same
list can be pasted on every machine: each bot skips itself by name), and
every peer's `bot_id` is added to every group's `allowFrom` in this bot's
`access.json` (not the DM one). A group whose `allowFrom` is empty is left
alone: it already admits every author, peers included, and adding ids to it
would narrow "everyone" down to "peers only" without saying so. Peers need
this bot's id in their own `allowFrom` too; ask their owners.

All of the plugin's hooks are registered unconditionally by its `hooks/hooks.json`;
each script exits at once unless the session is a bot (`DISCORD_STATE_DIR` set) whose
mode matches, so a mode takes effect on the next event and a non-bot session in the
project pays two execve (`env`, then `bash`) and no fork per event. The plugin's first hook run in a bot session removes what the previous
release wrote in that bot's project: the hook entries under `.claude/discord-agents/hooks/` in
both settings files (with a matcher group or an event left empty by that) and every
`.claude/rules/claude-discord-*.md` (that prefix belongs to claude-discord; name your
own rules differently), only in a project that has a plugin install. Nothing else in
either place is touched.

The dev-manager rule reaches only a dev-manager bot's session, as SessionStart
`additionalContext` (startup, resume, compact and clear). It is not a project rule
file because every session in the project loads those, subdirectory and plain
`claude` sessions included.

Every bot keeps one request per Discord thread (see Expected behaviour
below). The dev-manager rule adds what is its own: an item is a defect, a
feature, a measurement or a review, its back-and-forth with peers goes inside
its thread, and a decision only a human can make is one channel line naming
the thread. Discord carries only what a peer must act on (a review, a test
on its machine, a split, a heads-up, the diff summary before a push) or what
the human asks it to send, and nothing is echoed either way. Scratch files belong
under `~/.claude-discord/scratch/<bot name>/` when they must survive, in
`/tmp` under a session-unique name when they need not -- never under
`~/.claude`, and `$CLAUDE_JOB_DIR` exists only in a background session.

Once a change to claude-discord itself is on main and installed here, that
same rule has a dev-manager tell the machine's OTHER claude-discord bots --
not its peers, its machine's other bots, in whatever other project runs one
-- `$CLAUDE_DISCORD_TOOLS/local-bots` prints them: every other live
bot session on this machine, one line per session as `<name><TAB><project
dir>`, sorted by name. Discovery is `claude agents --json` (active sessions
only: `--all` would add completed ones, retired bots among them; no filter on
the state, since a live bot can show `done`) filtered to
a session whose project has a `.claude/discord-agents/<name>` directory,
this bot's own session excluded by state dir; it prints nothing, never
fails, and is never registered as a hook.

## Who may drive a bot: `access`

Which channels a bot listens in, who may write to it there, whether it needs an
@mention, who may DM it, and its mode are read and changed with one verb
(1.13.0). The TUI's access editor (`e` on a bot row) is a front for it and
changes nothing any other way.

```sh
claude-discord access <bot> --json            # the policy, the server's channels, the people known: one line of JSON
claude-discord access <bot> set <change>...   # shows what would change, asks once, writes
```

| change | does |
|---|---|
| `channel+<channel id>` | the bot listens there: an @mention required, from the owner (`DISCORD_USER_ID`) alone |
| `channel-<channel id>` | it stops listening there |
| `mention:<channel id>=on\|off` | an @mention is required / every message is answered |
| `allow:<channel id>+<user id>`, `allow:<channel id>-<user id>` | a sender is added to, or taken off, that channel's list |
| `allow:<channel id>=any` | anyone in the channel may write to it (an empty `allowFrom`) |
| `dm=allowlist\|pairing\|off` | the DM policy. `off` is an allowlist with nobody on it; the plugin's own `disabled` is not offered, because it drops every message, in the channels too |
| `dm+<user id>`, `dm-<user id>` | the DM allowlist: whoever is on it also answers the bot's permission prompts |
| `mode=none\|dev-manager\|autoresearchclaw` | the bot's mode, through `setup <bot> --mode` with its questions answered by Enter (peers and hosts kept) |

A change is a word of lower-case letters, digits and `: + = -`; ids, never
names. The words are applied in order to the file as it is, so every key the
verb does not know (the plugin's `pending` pairings, `ackReaction`, anything
else) stays. `set` prints each change, names resolved from what this machine
keeps (`channel-names`, `user-names`, `peers.json`; a person is shown with the
id, since a display name is the sender's to choose: `name (id)`), then asks. A
person this machine keeps no name for is shown as `id (name)` with the name the
server's member list gave at the bot's last `--json` (`<bot dir>/member-names`):
that name is whatever the person chose, so read the id.

- **a change that widens who can drive the bot** is marked `!`, red at a
  terminal, and shown before the others: an @mention no longer required; a
  channel opened to anyone; DMs to `pairing`, or back from `disabled`; a
  person added to the DM allowlist; a person the bot listed nowhere until now;
  leaving dev-manager when that deletes a hosts ledger (its monitor stops);
- **one question for the whole change set** (1.13.1), naming the count and
  the widenings among it: `Apply 3 changes, 2 of them widening? [y/N]`
  (`Apply this change?`, `Apply these 2 widening changes?`, ...);
- **anything but `y` writes nothing** (exit 4): `n`, the end of input, any
  other answer. The file is what was shown and agreed to, or as it was;
- warnings, which ask nothing more: the owner taken off a list, the bot's main
  channel changing, a dev-manager's peer bot taken off a channel.

`set` refuses to write unless stdin and stdout are a terminal, and has no flag
to skip its question. That is a speed bump, not a boundary: whoever can run
it can edit `access.json` with an editor. It is there so that no script and no
session writes a bot's access without a person reading the change. Without a
terminal it prints the changes and exits 3, which is also how to see what a
set of words would do. A removal never empties a sender list (an empty list is
everyone): say `allow:<id>=any` to mean that.

The write is by rename under a lock (`access.json.lock`), mode 600. The
official plugin reads `access.json` at every message, so **a change applies at
the next message, with no restart**; a file it cannot parse it moves aside and
replaces with its defaults (pairing, no channel), which is why the file is
never written in place. The plugin rewrites the file itself, with no lock,
when a DM asks for a pairing code or a code expires: the new file is made from
the file as it is at the moment of the write, and the write is given up (exit
1) when the policy changed while the question was open. `<bot dir>/access.log`
gets a line for each thing done, each with the time, the local account and the
machine: `access.json: <the change words>` right after the rename (before the
mode is set, so a run stopped there still has its write logged), then
`mode: <old> -> <new>`, or the same followed by `failed (...)` when
`setup --mode` failed. A mode change reaches the hooks at their next call; the
dev-manager rule text reaches, or leaves, a running session at its next start,
compact or clear.

`--json` asks Discord, with the bot's own token and on the bot's own machine,
for the server's channels, its roles, the bot's roles and the member list
(four calls; six when this machine does not know the bot's id or its server
yet, which it then asks first; five seconds each at most, none started past 12
seconds), and prints one line: `policy` (as
`health --json`'s `access`), `channels` (text, announcement and forum
channels: `id`, `name`, `kind`, `read`), `people` (`id`, `name`, `kept`: the
name this machine keeps, or empty, and `bot`),
`members` (`api` when the member list answered, which it does only with the
Server Members Intent already on; `names` otherwise: the people are then the
ones this machine has names for), `owner`, `main`, `peers`, `mode`, `guild`
and `errors`. `read` says whether the bot can read the channel: `VIEW_CHANNEL`
and `READ_MESSAGE_HISTORY` after its roles and the channel's overwrites. It is
`null` (the TUI's `?`) whenever that cannot be told: a call that failed, a
permission that is no number. Never a guess. Only the server of the bot's main
channel is asked.

A bot on another machine, for a manager that checks that host:

```sh
claude-discord access --host <alias> [--manager <bot>] --project <dir> <bot> --json | set <change>...
```

`<alias>` is a line of the manager's hosts ledger (`local` too: then it runs
here, with that line's env words, as the monitor's own Discord calls do).
Over ssh the call goes as a pass does (`BatchMode`, `ConnectTimeout=8`, the
line's env words); `set` at a terminal runs under `ssh -t`, so the question
is asked on the bot's machine, of your terminal. Into the remote command go
only hex digits (the project and the bot's name), the action and the change
words. The remote host needs claude-discord 1.13.0: an older one is said so
(exit 5) and is never sent a change. `--json` over ssh is given 30 s (the
connection, then Discord's calls on the host), or `CLAUDE_DISCORD_PROBE_CAP`
when that is more; every other call that asks no question, that cap (20 s).

A bot named `access`, set up before 1.13.0, is no longer launched by
`claude-discord access`, which is this verb now: launch it with
`claude-discord --name access` (`setup` refuses the name for a new bot).

| exit | means |
|---|---|
| 0 | done, or nothing to change |
| 1 | it could not: no such bot, `access.json` unreadable or changed meanwhile, a failed write, the lock held 5 s, no manager's ledger for `--host`, a `DISCORD_CHANNEL_ID` in `config.env` that is no id, a mode `setup --mode` did not set |
| 2 | usage, a word that is not a change, a change that cannot be made, `--host` with several managers' ledgers and no `--manager` |
| 3 | no terminal: the changes were printed, nothing written |
| 4 | answered no: nothing written |
| 5 | `--host`: the host did not answer, or its claude-discord is older than 1.13.0 |

## A bot's token and name: `bot`

A bot's name here is its Discord username (1.14.0): 2 to 32 of `A-Z a-z 0-9 _ -`,
not starting with `-`, and none of claude-discord's own words (`setup`, `access`,
`bot`, `add`, `hooks`, ...; `setup` refuses the same ones). Its
token, its name and a new bot are written by one verb, at a terminal, as
`access set` is (that is a speed bump, not a boundary):

```sh
claude-discord bot <bot> token          # a new token for the bot; the current one is never read
claude-discord bot <bot> rename <new>   # Discord first, then everything here keyed by the name
claude-discord bot add [--mode none|dev-manager|autoresearchclaw] [--start]   # a new bot, named by its token
```

- **token** reads the token with the terminal's echo off (`Token (hidden): `),
  asks Discord who it is (`GET /users/@me`, the token on curl's stdin), and
  refuses a token of another bot: its id must be the one kept in
  `<bot dir>/bot-id`, or, with none kept, the one Discord gives for the token
  in `.env` now (never a username: two bots may share one). When neither can be
  had (no `bot-id`, and the token in `.env` was reset), a token of a bot set up
  on this machine is refused, and any other is shown in red as `this bot's id
  could not be checked`. It shows what it will do and asks once; `y` writes
  `.env` by rename (mode 600, its other lines kept) and the id to `bot-id`. A running session logs in with the new token within 10 s: the
  plugin's login loop re-reads `.env` by its path, and since 1.14.0 it also
  waits for a new token when Discord closes the gateway with 4004 (a token
  reset in the Developer Portal), which discord.js never retries. A session
  started before 1.14.0 has the old loop: `claude-discord refresh <bot> --force`.
  `access.log` gets `token: replaced (bot <id>)`, never the token.
- **rename** changes the username on Discord (`PATCH /users/@me`; Discord
  allows about two changes an hour) and only then the name here: if Discord
  refuses, nothing here changes. Then, in this order: a running session is
  stopped; a manager's keeper and monitor are stopped; the bot's directory
  (token, `access.json`, mode, ledger, logs, handoff) is renamed in one step;
  its line in every project's `peers.json` on this machine is renamed, found
  by its id; `~/.claude-discord/scratch/<bot>` is moved; a manager's
  `records/monitor/<bot>` is moved and its `state.json` names the new manager,
  its backend starts again (unless you had stopped it) and its watcher record
  on each ledger host is renamed over ssh; the session starts again under the
  new name from its `handoff.md`. A failure before the directory moves
  starts again what was stopped and changes nothing here; after it, what
  failed is said with the command that finishes it. Peers on other machines
  keep the old name in their `peers.json` and still reach the bot by its id;
  their owner runs `setup <their bot> --mode` to show the new name. A session
  cannot rename its own bot (it would be stopped on the way): run it from a
  terminal outside that session.
- **add** needs a project whose channel and owner are set (`config.env`): its
  name is the token's Discord username. A username that is no name here is
  refused, with the advice to rename the bot in the Developer Portal first; a
  bot already set up on this machine (its id in some `bot-id`) is refused.
  `y` runs `setup <name>` with its answers on its stdin (the mode, Enter for
  the rest), keeps the id, and `--start` starts it (`--bg --name`).
- `--host <alias> [--manager <bot>] --project <dir>` runs any of them on a
  host of a manager's ledger, under `ssh -t`, as `access --host` does: the
  token is typed into that terminal and read there, never put in a command
  line. The host needs claude-discord 1.14.0 (exit 5 otherwise).

`health --json` gives each bot's `discord_name`, Discord's username for it,
asked once a day (kept in `<bot dir>/discord-name`). The TUI shows a bot whose
two names differ with `≠ Discord: <name>`; `=` on that row renames it here to
Discord's name (Discord is not asked to change). In the TUI, `n` renames,
`t` replaces the token and `a` on the Bots tab adds a bot, each through this
verb on a pseudo-terminal the TUI holds: the token goes from a masked field
(never copied, emptied when taken) to the command's hidden prompt only.

| exit | means |
|---|---|
| 0 | done, or nothing to change |
| 1 | it could not: Discord refused the token or the name, another bot's token, a name taken, a failed write; or a step after the rename failed (said, with its command) |
| 2 | usage, a name that is no name, a session renaming its own bot |
| 3 | no terminal: nothing was read or changed |
| 4 | answered no: nothing was changed |
| 5 | `--host`: the host did not answer, or its claude-discord is older than 1.14.0 |

## AutoResearchClaw reports

An `autoresearchclaw` bot posts one report per research iteration of the
AutoResearchClaw runs in its project, written by the bot's own session; nothing
in the channel steers a run, and gates are answered in the run's terminal.

- **Trigger.** An iteration ends when a run (`artifacts/rc-*/`) writes a new
  `stage-15/decision.md` (PROCEED, PIVOT or REFINE); a run ends when it
  writes `pipeline_summary.json`, aborted and failed runs included.
- **`tools/arc-events`** prints one line per new event,
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
  (`rules/autoresearchclaw.md`, read from the plugin) reach
  the session through `on-start` as SessionStart context, at startup, resume,
  compact and clear. A `.claude/rules/` file would be loaded by every session
  under the project, AutoResearchClaw's own backend `claude` calls included,
  and they are not the bot. A `claude` started from the bot session's own
  Bash inherits its `DISCORD_STATE_DIR` and, in the same project, gets the
  context too; in another project it is not the bot.

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
- The bot is online exactly while `claude-discord --name alpha` runs. Registering
  alone shows nothing.
- With several bots in one channel, keep the default mention policy: with
  "respond without mention" on every bot, one human message gets one reply
  per bot.
- Each turn is answered where it came from. A turn with no Discord message
  in it (typed in the terminal, or woken by a peer, a timer or a watch) is
  answered in the terminal and posts to Discord only what the human asks the
  session to send or what another bot must act on, never a copy of the
  terminal conversation; that is the session's rule, not a hook (until
  2026-10-07 `thread-guard` denied every such post, which also kept the
  session silent when the human asked it to speak). A Discord message that
  arrives while you are talking to the session in the terminal is answered on
  Discord, and your question in the terminal, each where it came from; a
  turn that ends with its Discord message unanswered gets ☑️ on it, never
  sent back. A request's thread is listed in `open-threads` from
  `thread start` until `thread close` (`open-threads` drops what is over a
  week old, since a thread left to archive itself is never closed), so the
  background subagent working that request, and the turn its result wakes,
  report there and land it; `report-threads` (one id a line) is kept for a
  thread a timer reports to. A turn interrupted with Esc never reaches its Stop,
  so the next prompt typed in the terminal drops what it left when the
  transcript shows the interrupt came after its last Discord message (and
  over 3 s before the prompt: a prompt submitted while a turn runs writes
  the same marker just before itself).
  `thread start` itself refuses
  a session turn with no Discord message, except a dev-manager's (see
  Modes), whose thread is listed as `<id> terminal`: `thread close` takes its
  closing line, but posts there still need a peer's mention. A title and a
  closing line are one line of 500 characters at most. An autoresearchclaw bot's reports
  are exempt from all of this.
- One request, one thread, for every bot whatever its mode. The session
  prompt (and `on-prompt`'s context, which survives `/bg`) tells it:
  `$CLAUDE_DISCORD_TOOLS/thread start "[<area>] <short title>"` posts
  that one short line in the channel, opens a thread on it
  (`auto_archive_duration` 1440) and prints the thread id; the full answer
  goes inside, with that id as `chat_id`. The line comes first on purpose:
  Discord opens a thread only from a message already in the channel, so
  starting one from the long answer would leave the long answer in the
  channel. When the request lands, `thread close <thread_id> "<closing
  line>"` posts that one line (no newline, 500 characters at most) inside the
  thread, never in the channel, where it sat with no context, and archives the thread, which takes it out of the sidebar. A thread started,
  or a closing line posted, in a Discord turn answers its message as a reply
  would. The helper needs `DISCORD_STATE_DIR` (every hook and the bot's own
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
"refresh" handoff trigger, and a ✅ (replied) or ☑️ (no reply) reaction at the end of a turn.
The plugin's `hooks/hooks.json` registers all nine, each as
`"${CLAUDE_PLUGIN_ROOT}/hooks/<topic>/<name>"` with no shell wrapper; no hook
entry is written into a project's settings files. Scripts live
under `hooks/<topic>/<name>` (paths below are relative to `hooks/`);
`lib/discord.sh` and the scripts in `tools/` are not registered:
the first is sourced by every script below, the others are run by the
session (see Modes and Expected behaviour above).

| Event | Matcher | Script | What |
|---|---|---|---|
| UserPromptSubmit | | `turn/on-prompt` | On a Discord turn (a prompt that opens with the plugin's `<channel source="plugin:discord:discord" ...>` tag), records that tag's chat_id/message_id/user_id for `on-stop` and `mention-guard` and the sender's display name per id in `user-names` (it labels that id in the People line) (only the leading tag is trusted: the plugin does not escape `<` in message text, so anything after it could be forged; a message arriving mid-turn comes as a prompt of its own and is appended) and, once per session (see below), adds an additionalContext entry with the bot's identity, the mention rule, the thread rule, the orchestrator rule and a People line (every id the channel lets in, from `access.json`, config.env's owner and the 20 who wrote here most recently (`user-names`), as `<@id>`, named once that id has written), so a bot can call a person who is not in the turn; silent on a plain CLI turn and on a second-or-later turn in an already-primed session. A message that is exactly "refresh" (case-insensitive, mentions stripped, trimmed) also appends handoff instructions pointing at `claude-discord refresh <bot>` -- every time, primed or not. |
| PostToolUse | `mcp__plugin_discord_discord__reply` | `turn/on-reply` | Marks that this turn actually sent a Discord reply. |
| Stop | | `turn/on-stop` | Never blocks a turn: a session has read a Discord message the moment it receives it. Reacts on every message `on-prompt` recorded for the turn: ✅ if the turn sent a reply (`thread start` or a closing line counts) after the message was recorded, else ☑️ (read, no reply; `on-reply` writes the turn's message count into `.replied`, so a message that arrived after the last reply gets ☑️). ☑️ cannot tell "nothing was owed" from "the answer went only to the terminal", so a person who sees ☑️ and expected an answer should ask again. Then clears the per-turn files. |
| SessionStart | `startup\|resume\|compact\|clear` | `turn/on-session-start` | Runs `claude-discord patch` (a respawn, or an auto-update of the official plugin since the last start, is covered), and gives the session `CLAUDE_DISCORD_TOOLS=<path>` as additionalContext, plus `rules/dev-manager.md` for a dev-manager bot. After a compact or `/clear`, clears the per-session "primed" flag, so the next Discord turn injects the identity context again. At a startup or resume, clears the per-turn files a turn whose Stop never ran (an interrupt, a kill) left behind, keeping the primed flag (a resumed conversation still holds that context), then pins a background session's job (see Background sessions below). |
| PreToolUse | `mcp__plugin_discord_discord__reply` | `peers/mention-guard` | dev-manager only. Denies a reply that names a peer (a whole word, case-insensitive) without its `<@bot_id>` or `<@!bot_id>`, or that answers a peer without mentioning it: the author of the message in `reply_to` when that is set, else of the turn's last message. A bot only receives messages that mention it. |
| PostToolUse | `mcp__plugin_discord_discord__reply` | `peers/checkin` | dev-manager only. A reply that mentions a peer (`<@bot_id>` or `<@!bot_id>`) touches `.claude/discord-agents/checkin/<session_id>`. |
| PreToolUse | `mcp__plugin_discord_discord__reply\|mcp__plugin_discord_discord__edit_message` | `peers/thread-guard` | Every bot; an edit is checked like a reply, since it puts text in Discord too. A turn with no Discord message in it may post (it was denied until 2026-10-07). First denies a mirror line that opens with an arrow and a session or bot name (`-> name:`, `<- name:`; a Korean label such as `-> 수정:` is prose), every bot: it says `[sent to name]` or `[received from name]`. No bare ids: a 17-20 digit number outside code, a mention, a URL or a word (a file name) denies the reply, naming each one, with no lookup: the bot that wrote it knows what it is and rewrites it as `<#id>` (a channel or thread, its name linked), plain `@name` (a user or bot it only names; it pings nobody), `<@id>` (one who must answer or decide) or the number in backticks (shown as is). Discord renders no markdown table, so a table outside a fenced code block is rewritten into a fenced code block with its columns aligned by display width (a Korean character counts 2), alignment colons honoured and `**`, `__` and backticks stripped from the cells; a table with a line over 72 columns (a guess at a phone's code-block width) becomes one `header: value · ...` line per row instead, also in a fenced code block. The reply goes out through `updatedInput`, the whole input with only `text` changed. Then, for every bot but autoresearchclaw, whose rule posts one report per iteration in the channel: denies a reply to the CHANNEL (a `chat_id` equal to the bot's channel; a thread has an id of its own) longer than 500 characters once converted, counted in characters and not bytes, so the long text goes in the request's thread and the channel keeps one line. |
| PreToolUse | `Edit\|Write\|MultiEdit` | `peers/edit-gate` | dev-manager only. Denies an edit under a path whose realpath contains `/claude-discord/` unless the session checked in within the last 60 minutes; an allowed edit renews the check-in. Paths git ignores (a bot's state such as the refresh `handoff.md`, `.superpowers/`) pass. Bash and git edits are not seen; the rule asks for the same announcement by hand. |
| SessionStart | `startup\|resume\|compact\|clear` | `autoresearchclaw/on-start` | autoresearchclaw only. Prints the plugin's `rules/autoresearchclaw.md` as the session's additionalContext (nothing when the file is missing); starts no process. See AutoResearchClaw reports above. |

Which plugin runs them:

- A hook is in effect once the plugin loads: at the project's
  `.claude/skills/claude-discord` (scope project, trusted project only) or
  `~/.claude/skills/claude-discord` (scope global); see Install. A newly
  installed plugin loads in a running session on `/reload-plugins`, and its
  `UserPromptSubmit` hook fires from the next prompt.
- Every script's first line exits 0 when `DISCORD_STATE_DIR` is unset (no
  fork, nothing sourced), and `edit-gate` also exits there for a bot that is
  not a dev-manager, so a session that is not a bot pays two execve and no fork per event.
  A session inheriting `DISCORD_STATE_DIR` in another project is not the bot,
  and neither is one in a subdirectory of the bot's project; one in a git
  worktree of that project (a bot started with `--worktree`) is. Only then
  does a hook run `git worktree list`: a session in the project itself forks
  nothing for this, and a `git` that fails (a `$HOME` project that is no repo)
  means not the bot. The
  four `turn/` hooks and `peers/thread-guard` are for every bot; `mention-guard`,
  `checkin` and `edit-gate` do nothing in a session whose bot is not a
  dev-manager, and also nothing without `peers.json`; `thread-guard` guards
  every channel reply but an autoresearchclaw bot's; `autoresearchclaw/on-start`
  does nothing for a bot in another mode. `on-prompt` also records each
  message's sender (`user_id`) for `mention-guard`, and gives a dev-manager its
  peers' mentions and the working rule once per session.
- Hooks, tools and the launcher resolve their real directory (`cd -P`,
  `readlink -f`) instead of trusting `${CLAUDE_PLUGIN_ROOT}`, which is why the
  link method works.
- The plugin's first hook run in a bot session removes what the previous
  release registered in the project (the entries under
  `.claude/discord-agents/hooks/` in a regular `settings.json` and
  `settings.local.json`, and the `claude-discord-*.md` rule files); `setup` and
  a start remove nothing (see Migrating). Every other key and hook in either
  file stays, and a `hooks` key left empty is dropped. `.claude/discord-agents/hooks` in the project stays a symlink to the
  plugin's `hooks/` for this release (a peer's committed settings may still
  name it; the next release removes it). To switch the hooks off, uninstall the
  plugin (delete its install path) or disable it in `/plugin`, where it is
  listed as `discord-agents`. In a session that already ran the plugin,
  disabling it (or revoking the project's trust) leaves that session with no
  claude-discord hooks at all: its `plugin-sessions/` marker makes the old
  settings entries exit at once. A new session has no marker for its id and
  runs the old entries while they remain. Enable the plugin again to give
  the first session its hooks back.
- A bot that is set up but has not run the plugin since (idle, so no
  `plugin-sessions/` marker) keeps the project's old settings entries in
  place: no migration removes them until every bot of the project has a
  marker. That is harmless: in a session the plugin runs in, the gate makes
  each of them exit at once.

The identity/mention-rule context is long, so `on-prompt` injects it once per
session (a `turns/<session_id>.primed` marker holding the bot's mode and
the context text), not on every turn -- a compaction or `/clear`
drops it from the transcript, which is what `on-session-start` is for, and a
changed mode or a changed text injects it again. So after `claude-discord update`
changes the context (hook scripts run from the clone on disk), a running bot re-primes by itself on its next Discord
turn, once. The session prompt (`--append-system-prompt`) is fixed when the
session starts and still needs a restart (`claude-discord refresh <bot>`, or
stop and start). The "refresh" handoff still fires on every matching
message regardless of the primed state, since it is a specific command, not
boilerplate.

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

`/bg` inside the session, or `claude-discord --name alpha --bg` from the start, moves
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
  `claude-discord --name alpha` again while the background copy runs, or both answer
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
   command. The child's whole output is `refresh.log` in the state directory,
   and the run before it is kept as `refresh.prev.log`: an outage is usually
   met with a second refresh minutes after the first, and that run would
   otherwise erase the only record of what the first one did.
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
nothing is started. The bot's sessions are found by name or, for a renamed
one, by its job record (each launch passes `--settings` naming the bot's state
dir, and the daemon keeps it), and every live match is stopped. `-n`/`--name`
is refused: the wrapper names the session after the bot. A refresh that finds
no live session to stop refuses rather than start one (the bot may be running
from another directory); `--force` overrides that too, but not a `claude agents`
listing that failed outright, which says nothing about what is running.
Messages that arrive in the
gap are not redelivered, so the fresh session is told the id of the last
message its predecessor saw (the hooks keep it in `last-message-id`) and to
read the channel from there before doing anything else.

A crash is handled by Claude's own daemon (it restarts a `--bg` session from
its flags), not by the wrapper, so the plugin patches the wrapper applies at
launch are not re-applied there. After a plugin update, start the session
through the wrapper once more.

## Is the bot still there?

A bot can stop answering with nothing failing loudly, and twice here nobody
found out for most of a day:

- A worker that came back from a Claude Code self-upgrade ran **no hooks at
  all** for 21 hours — the project's and the user's own — with no error
  anywhere. Its session, its plugin server and its gateway connection were
  all up, so every process-level check said "fine".
- A `refresh` stopped the old session and its `--bg` start then failed on
  workspace trust, leaving the bot down for 22 hours with the error only in
  `refresh.log`.

`claude-discord health` is the outside check for exactly this. It is run by
hand from outside the session, so it still speaks when the session is the
thing that died.

```
claude-discord health                  # one line per bot; exit 1 if anything needs a human
claude-discord health --json           # the same as data, for a script
claude-discord health --all [--json] [--patch]   # every project on this machine (what a monitor pass runs)
claude-discord health --uninstall-timer  # remove the timer an older version installed
```

**What it judges by.** Not `claude agents`' `.state`: measured on two
machines, a fully live bot shows `state: done, status: idle` while its pid and
its gateway are both up — `state` tracks whether a turn is running. Not the
process count either, on its own, for the upgrade reason above. The primary
signal is behavioural:

> the **oldest** message that addressed this bot, never handed to its session
> (its id is not in `<bot>/delivered`), and more than 15 minutes old, with no
> later message from the bot in the same chat (channel or thread)

`on-prompt` appends every message id the session receives to `<bot>/delivered`
(the last 200 are kept). So `stale` is a delivery check: `ok` means the
session received the message, not that it answered. A mention that asks
nothing gets no reply by rule, and a turn may take an hour; neither is a
fault. Any later message the bot posted in the same chat also clears it, so a
message lost in a refresh and then answered by the catch-up stops counting.
A message stuck in one thread still reads `stale` while the bot answers
in another, which `last-message-id` alone could not see. A bot whose hooks
have not run since 1.10.0 has no `delivered` yet and is judged by
`last-message-id`, as before.

Oldest, not newest: the age being measured is how long the bot has been
failing to answer, and with the newest every fresh message resets the clock —
so a wedged bot that people keep calling, which is exactly the case this is
for, would never be reported.

Ids are compared as strings throughout, never converted to numbers. jq 1.6
(still `/usr/bin/jq` on some machines) holds numbers as doubles, and a
19-digit snowflake does not fit: `"1553056881315025049"` comes back as
`1553056881315025200` — *larger* than the original, which sails past
`last-message-id` and invents a finding for a bot that is perfectly idle.

which catches a dead process, dead hooks and a wedged turn alike. The process
count only names the cause afterwards: none means the bot is down, more than
one means two sessions share its token.

Three things would make that signal cry wolf, and each is filtered:

- An author outside the channel's `allowFrom` is dropped by the plugin before
  any hook runs, so `last-message-id` could never catch up to such a message.
  An EMPTY `allowFrom` drops nobody, there and here alike.
  `health` applies the same `allowFrom` and the same `requireMention`, and
  counts a reply to one of the bot's own messages as addressing it, exactly as
  the plugin does.
- A long turn legitimately takes minutes, so a turn in flight (`turns/<session
  id>`, written by `on-prompt` and removed by `on-stop`) holds the finding back
  — but only while that file is under an hour old, because a turn whose hooks
  died leaves it behind for ever and would otherwise silence the very failure
  this exists to catch. Past the hour the daemon gets the last word: if it
  says a session of this bot in this project is `working`, the turn is
  running, not wedged. That check is needed because `on-prompt` touches the
  turn file only when a *message* arrives, so a turn that runs for hours off
  a single message looks stale while it works — measured, a live mid-turn
  session was reported stale with a `--force` refresh as the suggested fix.
  Anything unknown there (no `claude`, a listing that fails) counts as
  working: a missed finding is recoverable, one telling someone to
  force-refresh a busy session is not. That hold is capped at six runs in a
  row and 25 minutes since the first of them (both: a pass can be asked for,
  so six runs may be seconds apart), because `claude agents` failing repeatedly means the
  daemon itself is unwell — exactly when a bot breaks — and holding for ever
  would hide it; past the cap the not-knowing is reported as `nostate`. One
  run that *can* tell resets the count.
- Threads carry their own messages. One request for the guild's active threads
  answers with every thread's `last_message_id`, so a thread is read only when
  it holds something newer than the hooks recorded; the usual run is two calls.

Known gap: the plugin also treats a mention of the bot's managed **role** as
addressing it, and the REST payload carries those separately from user
mentions. Such a message is not counted, so `health` under-reports there
rather than crying wolf.

`health` also asks Discord one unauthenticated question first (`GET
/gateway`). Without it, a machine that cannot reach Discord at all looks
exactly like every bot's token having been refused — measured, a run with no
`HTTPS_PROXY` reported precisely that, which would have sent every owner to
check a credential that was fine. When the network is down that is the single
finding (`noreach`) and no token is blamed.

Two facts that cannot change are asked for once and kept in the bot's state
dir rather than fetched every run: its own user id (`bot-id`) and its
channel's guild (`channel-guild`, stored with the channel it was learned for,
since a bot's channel *can* be moved by editing its `access.json`). That is
two fewer HTTP calls and two fewer `jq` per bot per run. A cached value that does not look like an id is
re-fetched, so a truncated file heals itself instead of poisoning every later
run.

`health --json` also carries, per bot, what the TUI shows (1.11.0):
`channel` and `channel_name`, `last_message_at` (the time inside the
`last-message-id` snowflake: when the session was last handed a message) and
`access` (`dm`, `dm_allow` and, per channel of `access.json`, `groups[].id`,
`mention` and `allow`: user ids only, never a token). The channel's name
is kept in `channel-guild` as a third field, with the second it was read as a
fourth, and is read again once that is a day old (one call a day per bot); a
read that fails keeps the line. No `jq` start was added for any of it.

Since 1.11.1 each bot also has `mode` (the first line of its `mode` file,
`none` when there is none) and each element of `access.groups` a `name` (`""`
when unknown). The daily read is the guild's channel list
(`guilds/<gid>/channels`) instead of the channel: still one call a day per
bot, two the first time ever (the channel for its guild, then the list), none
on any other run. From that list the names of the bot's access groups, the
main channel included, go to `<bot dir>/channel-names`, one `<id> <name>` line
each, cleaned as the main name is; `channel-guild` keeps its four fields. A
group the guild has not (another guild's channel, a deleted one) has no line
and `name: ""`; one added to `access.json` gets its name at the next daily
read. A list that fails or is no array falls back to the channel for the main
name, as in 1.11.0, and the names already kept stay.

**It never restarts and never stops anything.** A misjudged restart is what
puts two sessions on one token, and a health check is the thing most likely to
misjudge. It posts nothing to Discord either: it prints, and a human decides.
Every run by hand also appends to `<bot>/health.log` and to the journal;
`health --all` (the monitor's run, every five minutes) writes neither. Old
`health.log` files can be deleted.

**No timer.** Older versions offered `health --install-timer`, a
systemd `--user` timer running `health --notify` every five minutes, which
posted alerts in a `[health] <bot>` thread. Both are gone: an OS
scheduler outlives every session and brings a stopped setup back on the next
boot without anyone seeing it. `health --uninstall-timer` removes one an older
version installed. Alerts now come from a manager bot's monitor (next
section), which runs on its own until `claude-discord monitor --stop`.

## The monitor and the TUI (manager bots)

A dev-manager bot can watch every bot on its own machines and tell each
bot's owner in `#bot-health-check` when one stops answering. Nothing is
installed in the OS: no launchd, systemd or cron.

```
claude-discord setup <manager> --mode    # dev-manager, then: ssh hosts to check
claude-discord tui [<manager>]           # the view, and where hosts are added and set; starts the backend if none runs; works outside a project
claude-discord hosts list                # the ledger: add, set, laptop, rm change it (below)
claude-discord monitor --stop <manager>  # stop the backend; nothing starts it again but:
claude-discord monitor --start <manager> # start it again (detached)
claude-discord monitor --keep <manager>  # the keeper in the foreground (tmux, a container entrypoint, systemd)
claude-discord monitor --check <manager> # ask the running monitor for a pass now, not in up to 5 minutes
```

**The backend.** A manager bot's backend is a keeper and the monitor it
keeps up. It runs on its own: no manager session and no TUI is needed, and
it runs until `claude-discord monitor --stop <manager>`. It is started by
`claude-discord setup <manager> --mode` (dev-manager with a ledger; setup
says so in one line, with the stop command), by `claude-discord tui`, and by
the session start or prompt of **any** claude-discord bot on the machine
that finds it dead (every dev-manager with a ledger in the projects
`claude-discord` has recorded; a check with no fork while all keepers run).
A container or machine restart kills it, and the next of those starts it
again. `--stop` leaves a `stopped` marker: then none of them starts it (the
TUI asks first, and shows `stopped by you`) until
`claude-discord monitor --start <manager>`.

**Taking a machine down (maintenance, a server move).** Run
`claude-discord monitor --stop <manager>` first: its marker keeps every bot
session from reviving the backend. Then stop the bots. The monitor never
restarts a bot, it only alerts, so stopping the bots first would only post
`[down]` alerts. `claude-discord monitor --start <manager>` brings the
backend back afterwards. `CLAUDE_DISCORD_NO_AUTOSTART=1`
in the environment keeps setup, the TUI and the hooks from starting one at
all on that machine (the other side of a shared home, below); `--start` and
`--keep` still work there.

```
```

**Ledger.** `setup` in dev-manager mode asks `ssh hosts to check` and writes
`<manager>/hosts`: one host per line, an optional `laptop` word, then optional
`KEY=VALUE` words (no spaces in a value) that become the remote command's
environment. `local` is this machine and is always there; its `KEY=VALUE`
words are also the environment of the monitor's own Discord calls. A proxy
word (`HTTPS_PROXY`, `HTTP_PROXY`, `ALL_PROXY`, `NO_PROXY`, in either case)
is set in both cases, since curl prefers the lowercase one. A `name=<display>`
word (lower case) is no environment word: it is what the TUI calls that host
(`local name=lmd79`); with none the TUI shows this machine's hostname for
`local` and the ssh name for the others. Of the `KEY=VALUE` words
`state.json` and the TUI keep the key names only, never a value.

```
# ssh host names this manager checks; "local" is this machine (no ssh)
local name=lmd79 HTTPS_PROXY=http://127.0.0.1:8118
wmac  laptop HTTPS_PROXY=http://127.0.0.1:8118
pmac  laptop
```

A `laptop` host is checked like any other, but its own unreachability is
never posted (a closed lid is not an outage). Setup marks a host `laptop`
when it answers `Darwin` and has a battery; `claude-discord hosts laptop
<alias> on|off` changes it. Deleting the file turns the monitor off. Two
managers should not list the same host, or its bots are reported twice;
`hosts add` warns when another manager already watches a host, and refuses
a second line for a home it already checks.

**Changing the ledger: `claude-discord hosts`.** The ledger can still be
edited by hand; this verb and the TUI's Configuration tab (which only ever
runs this verb) do it checked, under a lock, and by rename, so a running
monitor never reads half a file.

```
claude-discord hosts [--bot <manager>] list [--json]
claude-discord hosts [--bot <manager>] add [--no-probe|--dry-run] <alias> [laptop] [KEY=VALUE...]
claude-discord hosts [--bot <manager>] set <alias> name=<display>|KEY=VALUE|KEY=...
claude-discord hosts [--bot <manager>] set <alias> --stdin
claude-discord hosts [--bot <manager>] laptop <alias> on|off
claude-discord hosts [--bot <manager>] rm [--no-probe] <alias>
```

The manager is the one dev-manager bot with a ledger in the project above
the current directory, else in a recorded project (as `tui` finds it);
`--bot` names it when there are several (else exit 2 naming them). So from
another bot's project on a machine with one manager, it changes that
manager's ledger: each change prints the ledger's path. A change takes
effect at the monitor's next pass (5 minutes at most; `claude-discord
monitor --check <manager>` asks for one now, and the TUI does that itself
after each change it makes). A pass that was asked for starts a minute after
the last pass began at the earliest, and requests made before then are one
pass: findings are held for so many passes, and those must stay minutes.

- `list` prints a line per host line as the monitor reads it: alias, kind,
  display name and the KEY NAMES of its env words. `--json` gives the same
  as `{manager, ledger, ignored, hosts: [{alias, laptop, name, env, skipped}]}`
  (`ignored`: lines whose first word is no host name; `skipped`: words the
  monitor skips). Neither ever prints a value.
- `add` appends a line. An alias is ASCII letters, digits and `. _ @ -`, not
  starting with `-` (ssh would read that as an option), 255 at most: what
  the monitor accepts as a host. A value holds no space, control character
  or quote (the ledger has no quoting: write `HTTPS_PROXY=http://h:8118`,
  not `"http://…"`); `#`, `$` and `\` are fine. `laptop` is the word right
  after the alias or absent, and a KEY (ASCII letters, digits and `_`) comes
  once.
- `set` replaces a `KEY=` word where it stands or adds it last, `KEY=`
  removes it, `name=<display>` (no spaces, 40 characters at most, any
  script) is what the TUI calls the host.
  `set <alias> --stdin` reads the same words from stdin, one a line, and
  `laptop on` / `laptop off` among them: every change in one write, and a
  value in no argument list. On a command line the value is in your shell's
  history and, while the command runs, in `ps`; for a proxy URL with a
  password use `--stdin`.
- `laptop <alias> on|off` sets or removes the `laptop` word.
- `rm` removes the host's line(s). The monitor keeps the host a day as
  "left the ledger", then drops it; nothing is posted. `local` cannot be
  removed, and neither can the last host of a ledger that has no `local`
  line (the monitor needs one host).
- Lines that are not changed keep their bytes (comments, blank lines,
  spacing, CRLF, words the monitor skips). An alias with two lines is one
  host: `set`, `laptop` and `rm` act on both.
- A flag is taken only by the verb it is listed with above: any other is a
  usage error (`rm --dry-run` removes nothing).

| exit | means |
|---|---|
| 0 | done; a warning, if any, is on stderr |
| 1 | it could not: no manager bot with a ledger here, a failed write, or the ledger locked by another `hosts` for 5 s |
| 2 | usage, or a word that is not allowed. Nothing of the word is echoed, an alias and a KEY included: the message says where it stands (`argument 3`, `line 2 of stdin`) and the rule, as it may be a secret in the wrong place |
| 3 | the alias is already in the ledger (`add`) or is not in it (`set`, `laptop`, `rm`) |
| 4 | `add` refused: the host is the same home as one already checked |
| 5 | not added: the host did not answer or has no claude-discord (`--no-probe` adds it unchecked) |

**What `add` asks first.** `hosts add <alias>` runs `ssh -o BatchMode=yes -o
ConnectTimeout=8 -- <alias> '~/.local/bin/claude-discord --version
--host-id'` (`--dry-run` prints that line, and under it what the add writes
on that machine, and runs nothing; an exit 255 is
tried once more with `-o ControlPath=none`, as a monitor pass does; the
whole call is ended after 20 s, whatever ssh leaves behind holding its
output open: `CLAUDE_DISCORD_PROBE_CAP`, 1 to 300 s). The answer is another
machine's output: at most 65536 bytes of it are read, and of those what
counts is the last line that reads as a version line and what follows it
(so a banner before it does not), 4096 bytes at most. Each line is stripped
of control characters (C0, C1, the bidi overrides and isolates, bytes that
are no UTF-8) and cut at 200, and it is only matched, never run. Then:

- **the same home: refused (exit 4).** Each home has an id,
  `~/.claude-discord/host-id` (32 hex digits, made once). A host that
  answers with this home's id, or that this manager already checks under
  another alias still in the ledger, is `the same home as <host>`: a second
  line for it would report every bot twice. The id names a home, not a
  machine: a container and its host that share `$HOME` (below) have one id,
  which is exactly the pair that must not both be listed. Asking is what
  makes the id: the check writes `~/.claude-discord/host-id` on that host
  when it has none. A host that answers as 1.12.0 or later with no id could
  not create it: added, with a warning that says so.
- **watched by another manager: a warning.** A host keeps
  `~/.claude-discord/watchers/<manager>` (`<host-id of that manager's home>
  <its alias for this host> <time>`), written by that manager's `hosts add`
  and removed by its `hosts rm`. `add` says `already watched by <manager>`
  and adds the host all the same. A record can be stale (an `rm` while the
  host was unreachable says so and how to remove it later); it only warns.
  A line written by `setup` or by hand leaves no record, so neither check
  sees it.
- **no answer, or no claude-discord there: not added (exit 5).** A host
  without claude-discord would be reported `blind` five minutes later.
  `--no-probe` adds any alias unchecked: a laptop that is asleep, a host
  still being set up.
- **an older claude-discord (before 1.12.0): added, with a warning** that
  the same-home check could not be made.

**Monitor.** One process per manager bot, started by its keeper (or an open
TUI), and alive only while one of them is: it exits within 30 s of the last. Every 5 minutes it runs, per host,
`ssh -o BatchMode=yes -o ConnectTimeout=8 <host> 'env <KEY=VALUE...>
~/.local/bin/claude-discord health --all --json --patch'` (`local`: the same
command without ssh), so every ledger host needs the shim and claude-discord
1.10.0 or later (a host before 1.11.0 is checked the same; the TUI shows `-`
for its bots' channel, receives and last), and one `claude-discord health`
run in each bot project to
enter it in `~/.claude-discord/records/projects`. A project listed there
whose folder is missing (a volume not mounted yet) alerts as `blind` and is
never dropped from the list; delete its line by hand once it is gone for
good. The same call keeps the
official plugin patched on that host. It restarts and stops nothing.
Passes start 5 minutes apart however long the hosts take (a longer pass is
followed at once by the next). After `claude-discord update` a running
monitor goes on as the new version once the new file has held still for a
pass, as the same process, and posts nothing it already posted; the keeper
does the same within two minutes. A monitor killed without cleaning up
(`kill -9`, out of memory) is started again by its keeper within a minute; a
killed keeper by the monitor within a minute (30 s tick, at most one start a
minute), or by any bot's next prompt or the next TUI. The monitor itself ends
only on `monitor --stop`, a deleted ledger or a signal.

**Keeper.** `claude-discord monitor --keep <manager>` runs in the
foreground, registers itself as a holder of kind `keeper` and runs
`monitor --ensure` every 60 s, so a dead monitor comes back. It exits 1 with
the reason for a bot with no ledger or not in dev-manager mode, exits 0 when
a keeper already runs for that bot (one per bot: it holds `keeper.lock` for
its whole life, so starters that race leave one) or the bot was stopped with
`--stop`, leaves when the ledger is deleted, and removes its record on TERM or
INT. setup, the TUI and the hooks start it detached, in a session of its own
(why one did not start is in `monitor.log`), so **quitting the TUI or ending
the manager session leaves the backend running**; the TUI's header shows
`keeper <pid>` among the holders and the stop command.
`claude-discord monitor --stop <manager>` TERMs the keeper, then the monitor.
claude-discord installs no OS scheduler (no launchd, cron or systemd unit).
To run the keeper in the foreground under something that already keeps
processes, e.g. a tmux window or a container's entrypoint:

```
# entry.sh (lmd79 style): from the manager's project, before the main process
cd ~/workspace/my-project && claude-discord monitor --keep <manager> &
```

A systemd unit you write yourself works the same (`ExecStart=` the command,
`WorkingDirectory=` the project).

A host and a container that share `$HOME` share `~/.claude-discord` but not
their process ids: run the TUI, the keeper and the manager session on the
side where the bots run (set `CLAUDE_DISCORD_NO_AUTOSTART=1` on the other),
and list that machine once in the ledger (`hosts add` refuses the other
side: one home, one `host-id`). Otherwise
each side reads the other's holder as dead (a monitor there starts a keeper of
its own), and a second ledger entry for the other side reports every bot twice,
one side as `down`. A keeper on the wrong side would keep a monitor there that
reads every bot as down and posts false alerts, so `--keep` (and the TUI's
keeper) refuses, exit 1, when the lock is held and the pid the lock file names
is no monitor of that bot this side can see: "the monitor lock is held by a
monitor this side cannot see; run --keep where the bots run". It refuses only;
it never takes the lock over.

A monitor verb works from any directory: it finds the project above the
current one that has the bot, else the one `records/projects` lists. One
manager bot name is one backend per machine (its state dir is keyed by the
name), so `setup --mode dev-manager` refuses a name that another recorded
project already runs as a manager.

Everything it keeps is in `~/.claude-discord/records/monitor/<manager>/`:

| file | what |
|---|---|
| `lock` | the single-instance lock (`flock` through perl); holds the running monitor's pid, and a monitor whose lock file was removed or replaced exits at its next tick |
| `state.json` | what the TUI shows; kept after exit, and what keeps a restart from repeating a finding. Its `alerts` holds the last 100 records: every post with its reason and text, and every finding the channel was not told when it appeared (`not_posted`) |
| `monitor.log`, `monitor.log.1` | one line per event, 256 KiB each at most |
| `holders/<kind>-<pid>` | one record per keeper (`keeper`) or open TUI (`tui`): `<pid> <start time> <kind>` (a `session` record from 1.10.2 is read until its session ends) |
| `stopped` | `monitor --stop` was run: nothing starts the backend until `monitor --start` |
| `pass-now` | `monitor --check` was run: the monitor removes it at a tick and runs a pass, a minute after its last pass began at the earliest (one pass, however many requests). One it cannot remove is logged once and no request is served until the monitor is started again |
| `keeper.lock` | the keeper's `flock` target, held on fd 8 for its whole life: the one-keeper rule |
| `refused.<id>` | a detached start met a monitor this side cannot see: this side's hooks start nothing until `monitor --start` or a start that gets through (`<id>` is the digits of `readlink /proc/self/ns/pid`, so the other side of a shared home is not stopped by it; plain `refused` where there is no `/proc`, a Mac). The TUI says `auto-start refused here` |
| `last-start.<id>` | the epoch second of this side's last automatic start (a hook, not `monitor --start` or the TUI): a prompt within 60 s of it starts nothing, so a keeper that dies at once is not forked again on every prompt of every bot (`<id>` as for `refused.<id>`) |
| `pass.out` | one host's answer, only during a pass |
| `post.out` | one post's answer and status, only during a pass |

Outside that directory: `<manager>/hosts.lock` beside the ledger (the
`flock` target of `claude-discord hosts`, empty), `~/.claude-discord/host-id`
(this home's id) and, on a host a manager added with `hosts add`,
`~/.claude-discord/watchers/<manager>`.

**Alerts.** One message per change, posted with the manager bot's token to
channel `1558283274487341137`, and one `[recovered]` line when the bot is
back. Two or more bots of one host found `down` in one pass are one
message listing them (each owner mentioned once), and so are two or more of
them back from `down`; what was posted is still kept per bot, so a bot that
comes back alone gets its own `[recovered]` line. The channel is write-only: it is not in any bot's `access.json`, so a
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

A finding the channel is not told when it appears (`noreach`, a laptop's
`hostdown`, and `throttled`, `apierror` and `hostdown` until their 30 minutes
are up) is recorded all the same, as `not_posted`: the TUI's Alerts tab shows
it. One such record per bot (or host) and verdict a day: a bot that goes
between `throttled` and `ok` every few minutes does not push the real posts
out of the 100 records. A post that keeps failing is one record, and the one
that finally goes out is marked as sent on a retry.

While a host is `noreach`, `hostdown` or `blind`, nothing is said about its
bots. A bot's owner is `DISCORD_USER_ID` of its project's `config.env`; a
host-level finding mentions the manager project's. Labels are Korean by
default; `ALERT_LANG='en'` in the manager project's `config.env` makes them
English (any other value is Korean). The reason and the command are never
translated.

**TUI.** `claude-discord tui` shows the monitor's state (outside a project it
picks among the manager bots of the projects `claude-discord` has recorded:
the one, or a numbered list at a terminal, else exit 2 naming them;
`tui <bot>` picks the project that has it). The title line names the manager
and, on the right, the backend: `● live  keeper · checked 1m ago · next 4m`;
`▲ check overdue  due HH:MM · now HH:MM` once no pass has ended 30 s after
the time one may take past its due time (twice the last pass, 2 minutes at
least: a pass under way is not overdue);
`○ stopped by you  start: claude-discord monitor --start <manager>` after
`--stop`; `○ not running` otherwise. Under it three tabs, changed with `←`
`→`: Bots, Alerts N (N findings posted and not recovered) and Configuration.
`↑` `↓` move the row cursor, `q` quits (the backend keeps running), `Q` quits
and stops the backend (after a yes; the same as `monitor --stop`). Opened
after `--stop`, it asks whether to start the backend again (No by default:
then it only shows the state). In every popup with buttons `←` `→` move the
focus from one button to the next and Enter presses the focused one; a
question opens with the focus on its safe choice (No, Cancel). A red bar under the tabs says what the title
cannot: `no state yet`, `monitor stopped at <time>`, `auto-start refused
here: another side holds the monitor lock`, `monitor pid <pid> is gone`
(killed without cleaning up; the TUI starts it again, once per 30 s at
most), the last pass failed (the state could not be updated; `monitor.log`
has the line) or the last post failed. The TUI changes one thing, the
manager's hosts ledger (Configuration tab), and only by running
`claude-discord hosts`; it never reads a `.env`, never shows a token, and
never shows or reads the value of a ledger env word. Text that came from
another machine, from Discord or from `~/.ssh/config` (names, reasons,
commands, posted texts, what `ssh -G` and the hosts CLI print) is drawn and
copied without its control, bidi and zero-width characters, a tab or line
break as one space: an escape sequence in it never reaches the terminal.

*Bots tab.* A band of counts first (`✕ Problems`, `▲ Needs a look`,
`● Healthy N of M bots`, `Hosts R / H`; one line below 110 columns). M is
every bot; a bot with no token is counted apart, never as a problem. Then one
row per bot: bot, status, host (the ledger's `name=`, else the hostname),
channel, receives, last (since its session was last handed a message),
project. A mode other than `none` follows the bot's name, dim (`DY-DevBot
dev-manager`), at 110 columns and more. There the status column is as wide
as the widest status a closed row shows (15 to 25 cells: `● ok` needs
little) and the bot column takes what that leaves, up to 45 cells, so a
name and its mode are whole (`StreamForQuestion  autoresearchclaw` at 118
columns); beyond that it takes up to 13 cells from channel, receives and
project. An opened row's reason wraps inside the status column. Problems come first (`down`, `stale` shown as `STUCK`, `duplicate`,
`unreachable`), then what needs a look (`throttled` shown as `rate-limited`,
`apierror`, `nostate`, `blind`), then the bots of a host the last pass could
not reach (`○ host unreachable`, dim, whatever they were last seen as: the
monitor keeps their last verdict, which is not a current one, so they are in
none of the counts; opened, the row says `last seen <status> <N> ago`), then
`working` and `ok`, then `no token`; by bot name, then host, within each.
A problem row has its recovery command on a line of its own under it, and `c`
copies it (OSC 52, so over ssh too, in a terminal that allows it; no other
row has one to copy). `space` opens a row, and several may be
open: the status column gains the reason and `posted Nm ago`, `not posted
yet` or `not posted (warning only)`; the channel column every channel of the
bot's `access.json` (by name, `#<id>` for one health has no name for; the manager's own row adds
`#bot-health-check (write-only)`); the receives column the mention rule, who
may write (names from the `user-names` files of this machine's bots, ids
otherwise, `+N` past three lines) and the DM policy. `Enter` shows every raw
field of the row and the posts for it. Below 110 columns project and
receives fold away.
`e` on a bot row opens its access editor (1.13.0): on the left the channels of
the bot's server, `[✓]` where it listens (`space` toggles), each with its
mention rule (`m` toggles), `main` for the channel its prompt names, `bot
cannot read` where its roles and the channel's overwrites keep it out, `?`
where that could not be told; on the right who may write in the channel under
the cursor (`tab` goes there; `space` ticks a person or `anyone in the
channel`; `a` adds a person by numeric id, or by a name this machine keeps
(`user-names`, `peers.json`) or of a person already on one of the bot's lists:
the whole name first, any case, then the one name it starts. A name only the
server's member list gave is never taken: anyone can choose that one); below, the DM policy and
the mode as radios. A change that widens who can drive the bot is drawn in the
alert colour. Nothing is written while editing: `s` runs
`claude-discord access ... set <the changes>` (with `--host`, so `ssh -t` for a
remote bot) on a pseudo-terminal the TUI holds (1.13.1), so the command's
terminal check holds and it prints the changes and asks its one question
itself. The TUI takes the question only as the command's own whole line
(`Apply ...? [y/N]`) after the marker line it prints just before it, which no
Discord name can hold, so a name that ends in `[y/N]` never passes for it.
What it printed up to the question is shown in a popup, its red widenings red
and every other escape sequence and control character removed; the popup fits
the screen at any size: the question with its counts and the buttons stay in
view, and the text above them scrolls (`↑` `↓` `PgUp` `PgDn` `Home` `End`),
with a line saying how much of it is above and below. It opens on No: `y`
writes `y` to the command, and so does Enter on Yes; `n`, `esc` or Enter on
No writes `n`. Anything else the command prints and then waits after (a
ProxyCommand asking for a code, a host slow to answer) is shown in a popup as
"the host says:", never answered: Cancel (the default) stops the command,
Wait waits on for its question. A host that asks for a code at login needs the
command in a shell. The TUI then says what came of it: saved (it asks the
monitor for a pass and closes the editor), answered no (the edits stay), or
the command's own words and exit status (nothing to change, refused, no
terminal, no answer from the host, an exit after the answer). The command is
given 40 s to reach its question; past that, or on `esc` before the answer,
its whole process group is killed, and nothing was written. After a `y`
there is no cap and `esc` does not stop it (it may be writing `access.json`
or setting the mode): the TUI says so and waits for its end, and so does
closing the TUI. Where no pseudo-terminal can be
opened the TUI hands its terminal to the command instead (Enter returns to
the TUI), and where that is not possible either it shows the command for a
shell (`c` copies it). The editor reads through `access ... --json`, run on the bot's own
machine, so the TUI still never reads a `.env` and never holds a token; a host
whose claude-discord is older than 1.13.0 says so in the editor and is not
edited.
A bot on a host whose claude-discord is older than 1.11.0 shows `-` for
channel, receives and last (one older than 1.11.1 shows no mode, `-` on the
`Enter` screen, and its other channels as `#<id>`), and so does any field a host sends in a shape
this version does not expect (a number for a name, an object for a list):
it is never an error. A project whose `health` crashed before any of
its bots was known is one row with bot `-` (it alerts as `blind`) and is not
counted as a bot.

*Alerts tab.* `Open`: what the channel was told and has not seen recover.
`History`: the records of the last 24 hours, newest first: when, kind
(`✕ down`, `▲ check`, `○ host`, `✓ recovered`; an open host alert in the
alert colour, like a bot's), bot, host, the reason, and
the post (`✓ sent`, `✓ sent on retry`, `— not posted`). `Enter` shows the
posted text, or `(the posted text is no longer kept)` for an open alert whose
record is out of the 100. A record written by a monitor older than 1.11.0
has no reason and no text.

*Configuration tab.* `Hosts`: one row per ledger host as the last pass saw
it, this machine first: its
display name, the ssh name with the machine's own hostname (`this machine`
for `local`), server or laptop, the key names of its env words (never a
value), whether the last pass reached it, its claude-discord version and its
bot count. A host taken
out of the ledger is marked `(left the ledger)` for a day, then dropped
(`Enter` on it shows its raw fields). Every change below is one
`claude-discord hosts` call, and after each the TUI asks the monitor for a
pass (`monitor --check`; once per 10 s at most), so the table follows within
a minute; it says so, or that no monitor runs.

`a` (`+ Add host`) opens a search over the `Host` aliases of `~/.ssh/config`
and the files it Includes, read as text (in the background: the dialog says
`reading ~/.ssh/config …` meanwhile): patterns (`*`, `?`, `!`) are no
candidates, `Match` blocks are never evaluated (`Match exec` runs commands),
an `Include` with wildcards in more than three components of its path is
skipped, and `user@host:port` come from the `HostName`, `User`, `Port` and
`ProxyJump` lines that apply. An alias the configuration does not name can
be typed. `Enter` on a candidate adds nothing yet: it shows the exact ssh
command that checks the host first and what the add writes on that machine
(`hosts add --dry-run`), what `ssh -G` says of that one alias (where the
connection goes, and through which ProxyJump or ProxyCommand), and the kind
it will be added as: `(●) server   ( ) laptop`, which `l` switches (a laptop
that is off is not alerted). Editing the search starts over. A second
`Enter` runs `hosts add`: refused for the same home, a warning when another
manager watches it. Once it runs it cannot be cancelled (it writes on the
host and in the ledger): `esc` and `q` say so, and the dialog stays for the
outcome. For a host that does not answer, a third `Enter` adds it unchecked.

`Enter` on a host row opens its settings: the alias and target (not
editable), the display name, the kind (`( ) server   (●) laptop`; space
flips it), the env words, and the last check with its reason and recovery
command. An env word is always drawn `KEY ••••`: the TUI does not know the
value and has no key to show one. To add or change one, type `KEY` and a new
value (masked while typed) and press `Enter`; `KEY` with no value removes
it. `KEY` is an env name: `name` and `laptop` are refused there (`not an env
name`; they have their own fields). `Save` writes every change in one
`hosts set <alias> --stdin` call (a value travels on stdin, never in an
argument list), and only what was entered: with text left in the `KEY` or
the value field it does nothing and says `press enter in the value field to
stage KEY, or clear it`. Unsaved changes, such text included, are said in
the title, and `esc` asks before dropping them. `Check now` asks the
running monitor for a pass (it probes nothing itself and starts nothing);
for 10 s after a request, this one or the one that follows a change, the
button reads `asked · the monitor checks within a minute` and does nothing.
`Stop monitoring this host` asks, then runs `hosts rm`. On a row, `x` does
the same and `l` flips server/laptop.
`Monitor`: the alert language (`ALERT_LANG`) and who is mentioned
(`DISCORD_USER_ID`; `-` when it is not an id, which mentions nobody), both
from the manager project's `config.env`, and the
fixed parts: a check every 5 minutes, `#bot-health-check`, the keeper and
the stop command.

**Expected.** With the backend running (no TUI or session needed), stopping a
bot by hand gives one `[down]` message within 10 minutes and one
`[recovered]` line after it is started again. A pass that sees nothing new
posts nothing. After `claude-discord monitor --stop <manager>`, with the TUI
closed, no monitor or keeper process is left 30 s later, and none comes back
until `claude-discord monitor --start <manager>`.

**Rollback.** Delete `<manager>/hosts`; `rm -r
~/.claude-discord/records/monitor ~/.claude-discord/records/projects` removes
everything the monitor wrote. The other file this release adds is
`<bot>/delivered`, appended by `on-prompt` in every bot's project; delete it
and `health` goes back to judging by `last-message-id`.

## Behind a corporate proxy

bun's `fetch` honours `HTTPS_PROXY`; bun's `WebSocket` does not, so the Discord
gateway connection alone goes direct and dies on TLS interception.
`~/.claude-discord/runtime/discord-proxy.ts` is a bun preload that pins both to
`HTTPS_PROXY`. It does nothing when the variable is unset, so it is safe
everywhere; the wrapper only wires it in (via the plugin's `bunfig.toml`) when
the file exists. Your proxy must forward `discord.com` and `discord.gg`; the
CDN domains carry real certificates and can stay direct.

`setup`, `install` and `update` clone and pull with the ambient git config
and environment, with `GIT_TERMINAL_PROMPT=0` (no credential prompt to hang a
script) and under `timeout 120` where it exists. Where git must go through a
proxy, set it per clone, e.g.
`git -C ~/.claude-discord/source config http.proxy http://proxy:8080` (a
first clone takes `git -c http.proxy=<url> clone ...`).

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
| Bot online but silent when a teammate @mentions it | their user ID is not in the group `allowFrom`; add it at setup, answer `all` there, or edit `access.json` (an empty `allowFrom` admits everyone) |
| Bot cannot read message text | Message Content Intent is off in the Developer Portal |
| Gateway connection fails behind a proxy | `discord-proxy.ts` missing from `~/.claude-discord/runtime/` (`claude-discord update` or `patch` refills it), or `HTTPS_PROXY` unset in the shell that ran `claude-discord` |
| Bot answers in the foreground, silent after `/bg` | wrapper older than 2026-09-18 (state dir not in `--settings`); run `claude-discord update` |
| Every bot in the channel answers one message | someone wrote `@everyone`/`@here` with a wrapper older than 2026-09-18, or the mention policy is off on all of them |
| `no bot '<name>' under ./.claude/discord-agents` | no setup in THIS directory; `cd` to the project you set it up in, or run setup here |
| `bot name must be a plain directory name` | the name contained `/`, or was `.`/`..` |
| `bot name 'hooks'` (or `'checkin'`) `is reserved` | those names are claude-discord's own directories under `.claude/discord-agents/`; pick another. A subcommand's name (`setup`, `install`, `update`, `patch`, `compat`, `refresh`, `health`, `monitor`, `tui`, `access`) is reserved too |
| Two bots answer each other forever | the mention policy is off on both; turn it back on for at least one |
| `Over 500 characters in the channel: start a thread ...` | the bot tried to put a long answer in the channel; `thread start "[<area>] <short title>"`, then post it inside the thread |
| `A mirror line says which way it went ...` | a line opens with `->` or `<-`; write `[sent to name] ...` or `[received from name] ...` |
| `Discord does not render markdown tables: rewrite it as a list, ...` | `thread-guard` found a table it would not rewrite: the reply has an odd number of ``` marks (a lone ``` in prose, or a fence that never closes), or `python3` is missing or failed. Close every fence or drop the stray mark; put `python3` on the bot's PATH |
| After Claude Code upgraded itself, a bot breaks its rules: long answers or raw tables in the channel, no thread, no reactions | the worker that came up after the daemon's self-restart for the upgrade runs no hooks at all, the user's own included, with no error (Claude Code, seen on 2.1.280 → 2.1.281, a respawned worker; an adopted one was fine). Check: the bot's `last-message-id` is older than its last Discord turn, and no `Discord turn.` context arrived. Fix: `claude-discord refresh <bot>` |
| `Before changing claude-discord, announce on Discord ...` | a dev-manager edited claude-discord without mentioning a peer in the last 60 minutes; announce the change, then edit |
| `claude-discord: not set up on this machine` (from the shim) | no plugin install for this project, none global, and no `~/.claude-discord/source`; run the clone line in Install. With the source clone present the shim runs it, so `claude-discord setup <bot>` works in any project |
| `claude-discord: ... pull failed` | `update` could not fast-forward that clone: local changes, a diverged branch (a clone-method install that pinned a version) or no network; the other clones were still updated |
| The hooks do not run in a project | the plugin is not loaded there: the project is not trusted in `~/.claude.json` (scope project), the install path is a dangling link (re-run `setup`), or the session started before `setup` and has not run `/reload-plugins` |
| `refresh` says `handoff.md is missing or empty` | the session did not write it; ask it to, or pass `--force` |
| `refresh` says `<dir> is not a trusted workspace` | `claude --bg` refuses to start in a workspace whose trust was never accepted, and the foreground path does not, so a bot moved to the background with `/bg` can run for weeks without meeting that gate. Run `claude` in the project once and accept the prompt, then retry; `--force` refreshes anyway. The check reads `hasTrustDialogAccepted` and fails **open**, so anything but an explicit `false` proceeds |
| `refresh` says `start failed, so <bot>'s handoff was put back` | the fresh session did not come up (the line above it says why). The launch consumes `handoff.md` before starting claude, so it is moved back and the retry is not refused for want of one |
| `claude-discord health: <bot> stale — ... hooks or its turn are stuck` | the plugin server is up and the bot still is not answering: the hooks died (see the upgrade row above) or a turn is wedged. `claude-discord refresh <bot> --force` |
| `claude-discord health: <bot> duplicate` | two plugin servers share one token, so every reply is sent twice. `/bg` from a foreground session and a fleet spare both respawn a session without going through the wrapper. `claude agents` lists them; stop the one that is not the bot's |
| `claude-discord health: <bot> unreachable` | Discord answered 401 or 403: the token was refused, or the bot cannot read the channel. Check `DISCORD_BOT_TOKEN` in `<bot>/.env` and the bot's channel permissions |
| `claude-discord health: <bot> throttled` / `apierror` | Discord rate-limited (429) or did not answer (000, 5xx). The token was *not* rejected, so nothing is said about the bot this run — these are deliberately not reported as a credential problem |
| `health` says `noreach` for every bot | this machine cannot reach Discord at all (the unauthenticated `/gateway` probe failed), so nothing is said about any bot and no token is blamed. Behind a proxy, `HTTPS_PROXY` is missing from the shell |
| `health` says `cannot count plugin servers on this machine` | neither `/proc` nor a working `ps -axww` (macOS counts through `ps`); the behavioural signal still works, only the cause cannot be named |
| `[hostdown] <host>` in `#bot-health-check` | ssh to that host failed twice. Run the command in the message; `up` means a stale ControlMaster or a tunnel that was reconnecting |
| `[blind] <host>` | ssh works but `health --all` gave no document: `~/.local/bin/claude-discord` is missing there or older than 1.10.0. Run `setup` or `update` on that host |
| `[patchfail] <host>` | the official plugin changed and a patch no longer matches; `claude-discord update` there, and if it still fails the patch needs a claude-discord fix |
| The TUI says `auto-start refused here: another side holds the monitor lock` | an automatic start on this side met a monitor lock held by a monitor it cannot see (a home shared with a container or host): the hooks start nothing here. Set `CLAUDE_DISCORD_NO_AUTOSTART=1` on the side that must not run a backend, and run `claude-discord monitor --start <manager>` on the side where the bots run (the marker is per pid namespace, so it does not stop the other side; a start that gets through clears it) |
| The TUI says `stopped by you` | `claude-discord monitor --stop` was run; `claude-discord monitor --start <manager>` starts the backend again |
| The TUI says `monitor stopped` or `no state yet` | no monitor runs (it was killed with its keeper, or never started); opening the TUI starts it. A reason after it in the red bar is `monitor --ensure` refusing, which `monitor.log` never sees: `no hosts ledger` means `<manager>/hosts` **or** `<manager>/.env` is missing (the message names the ledger for both). With no reason and a monitor that stops again at once, `monitor.log` says why |
| No alert for a bot on a ledger host | its project is not in that host's `~/.claude-discord/records/projects` (run `claude-discord health` there once), or the host is `noreach`/`hostdown`/`blind` (the TUI shows it) |
| `claude-discord: tui needs uv` | install uv (https://docs.astral.sh/uv/); only the TUI needs it |
| `claude-discord health: <bot> nostate` | `claude agents` has not answered for six runs, so whether a turn is running cannot be told, and the unanswered message is no longer being held. The daemon is probably unwell: run `claude agents` by hand |
| `refresh` says `no running session of <name> ... started in <dir>` | the session was started elsewhere, or is a foreground one renamed with `/rename` (only background sessions have a job record); `claude agents` shows it, stop it by hand, then `refresh --force` |
| The agent view still lists dead sessions of my bot | a start removes only its own (the session and, if it had one, its worktree): another name's, another project's and the one a `--resume` names are left alone on purpose, and only 20 go per start (oldest first), so start again for the next 20. Otherwise the wrapper predates 2026-09-19 (`claude-discord update`), or `claude agents --json --all` is not answering: run it by hand |
| No report after an iteration | the bot's `mode` is not `autoresearchclaw`; the session has no standing watch running `events` (ask it to start one); the session started before the mode was set (the rules arrive at session start: restart or `/clear` it); or the runs are not under `artifacts/rc-*/` of the project the bot was set up in. `<bot>/arc-seen` lists what `events` has already reported (running `events` by hand records what it prints, so the watch will not see it again) |

## Test

`./test-claude-discord.sh ./bin/claude-discord` runs the wrapper against a
throwaway HOME with a stub plugin and stub `claude`; it touches nothing real
and prints `ALL PASS`. It runs on Linux only: it finds its stand-in plugin
servers through `/proc`, and assumes GNU `wc`, `sed` and a `/tmp` that is not a
symlink, none of which hold on macOS. A C compiler (`cc`) is optional: with
one the suite builds a faster jq stub, without it a bash stub runs (about 1.5 s
slower, same checks). With jq 1.6 the suite runs some 8 s longer than with 1.7 or
newer: it starts jq about 2,400 times.

`uv run --script tests/tui/test_tui.py` checks the TUI's pure functions (what
each column shows, at which width; how `~/.ssh/config` is read; the access
editor's model and change words) and then
drives it over fixture state files with a stub in place of the wrapper and
of ssh (Textual's pilot). It needs uv and the Textual wheel, so it sits
outside the stub suite and its 40 s budget; it takes about 23 s. Send its
output to a file, not into a pipe: the stand-in monitors it starts keep a
pipe open for a minute after it ends.
