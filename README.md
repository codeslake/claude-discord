# claude-discord

Run a Claude Code session behind its own Discord bot, so several sessions can
sit in one Discord channel. The human talks to each session by @mentioning its
bot. It is a 100-line bash wrapper around the official
`discord@claude-plugins-official` channel plugin; the session is an ordinary
`claude` REPL with a Discord channel attached, so `--resume`, `/rename`, your
settings, hooks and skills all work as usual.

Origin: written by d.kim4, extended here.

## Prerequisites

| Need | Why |
|---|---|
| Claude Code 2.1.x with channels support | `--channels` flag |
| `bun` | the plugin's runtime (`curl -fsSL https://bun.sh/install \| bash`) |
| `jq` | writes `access.json` and reads the plugin's install path |
| the plugin | `claude plugin install discord@claude-plugins-official` then `claude plugin disable discord@claude-plugins-official` (see below) |

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
  `./.claude/discord-agents/` there, so a bot belongs to a project.

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

puts `claude-discord` in `~/.local/bin/` and the helpers (today only
`discord-proxy.ts`) in `~/.claude-discord/`. Re-run it after a pull.

## Usage

Run everything from the project directory; that is where the state goes.

```
cd ~/work/my-project
claude-discord setup alpha            # channel ID, your user ID, allowed IDs, alpha's token, mention policy
claude-discord setup beta             # only beta's token and mention policy: the IDs are shared
claude-discord alpha                  # start the session; the bot is online while it runs
claude-discord alpha --resume         # any claude argument passes through
claude-discord alpha --resume my-bot  # a session NAME or a short id also works, see below
claude-discord setup alpha --reset    # forget alpha's token and policy AND the shared IDs; ask everything again
```

The setup prompts:

| Prompt | Stored in | Notes |
|---|---|---|
| Discord channel ID | `config.env` (shared) | |
| Your Discord user ID | `config.env` (shared) | the only user allowed to DM the bot |
| Other user or bot IDs | `config.env` (shared) | comma-separated; may be empty. These can trigger the bot in the channel |
| Bot token | `<name>/.env` | input is hidden, like a password |
| Respond without an @mention? | `<name>/access.json` | default N. With Y the bot answers every channel message |

Everything lives under `./.claude/discord-agents/` in the project, mode 0700.
Setup writes a `*` `.gitignore` inside that directory, so the token can never
be staged even with `git add -A`; your project's own `.gitignore` is untouched.
A second project gets its own setup and its own bots.

## Resuming by name

`claude --resume` takes a full session id; a name only reaches its interactive
picker, which cannot appear under `--bg`. So the wrapper resolves the value
first, against the transcripts of the project you are in: a session name (what
`-n` set, or `/rename`) or a short id as `claude agents` prints it becomes the
full id, and it says so on stderr. A full id, or a name it cannot find, is
passed through and claude decides.

## Expected behaviour

- In the channel, `@alpha do X` reaches session alpha only. A reply to one of
  the bot's messages also counts as a mention.
- Tool-permission prompts arrive as buttons in your DM with the bot.
- The bot is online exactly while `claude-discord alpha` runs. Registering
  alone shows nothing.
- With several bots in one channel, keep the default mention policy: with
  "respond without mention" on every bot, one human message gets one reply
  per bot.

## Bots hearing each other

The upstream plugin ignores every message whose author is a bot
(`server.ts`: `if (msg.author.bot) return`). At each start the wrapper patches
that one line to ignore only the bot's own messages, so other bots reach the
allowlist like anyone else: add their IDs at setup or in `access.json`, and
they must @mention your bot unless you turned the mention policy off. The
patch is idempotent and re-applied every start because a plugin update replaces
the plugin directory. If upstream changes that line, the patch silently no-ops
and bots go back to ignoring each other.

The system prompt tells the session never to @mention a bot when answering
one, because a mention would make it answer again and the two would loop until
a human steps in.

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
`DISCORD_STATE_DIR` and its plugin server died silently. Two things to know:

- The `/bg` fork does not carry `--append-system-prompt`, so the identity
  paragraph (name, channel, the "never @mention a bot" rule) is gone after
  `/bg`. The transcript still holds everything said so far.
- One token, one session. After `/bg` the foreground REPL exits; do not start
  `claude-discord alpha` again while the background copy runs, or both answer
  every mention.

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
`CLAUDE_CODE_PROCESS_WRAPPER` (which Claude Code exports into every session, so
starting `claude-discord` from inside a session needs no extra setting).

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
| Two bots answer each other forever | the mention policy is off on both; turn it back on for at least one |

## Test

`./test-claude-discord.sh ./claude-discord` runs the wrapper against a
throwaway HOME with a stub plugin and stub `claude`; it touches nothing real
and prints `ALL PASS`.
