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
install -m 755 claude-discord ~/.local/bin/
install -m 644 discord-proxy.ts ~/.claude/     # only behind a corporate proxy, see below
```

## Usage

```
claude-discord setup alpha            # channel ID, your user ID, allowed IDs, alpha's token, mention policy
claude-discord setup beta             # only beta's token and mention policy: the IDs are shared
claude-discord alpha                  # start the session; the bot is online while it runs
claude-discord alpha --resume         # any claude argument passes through
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

Everything lives under `~/.claude/channels/discord-agents/`, mode 0700, outside
any git tree. Nothing goes in your project.

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

## Behind a corporate proxy

bun's `fetch` honours `HTTPS_PROXY`; bun's `WebSocket` does not, so the Discord
gateway connection alone goes direct and dies on TLS interception.
`discord-proxy.ts` is a bun preload that pins both to `HTTPS_PROXY`. It does
nothing when the variable is unset, so it is safe everywhere; the wrapper only
wires it in (via the plugin's `bunfig.toml`) when the file exists. Your proxy
must forward `discord.com` and `discord.gg`; the CDN domains carry real
certificates and can stay direct.

## If your `claude` is wrapped

`claude-discord` is bash: it runs the `claude` binary on `PATH`, never a shell
function or alias. If your shell wraps `claude` in a process wrapper (a proxy
chain, a version pin) set `CLAUDE_DISCORD_LAUNCHER` to it and the session is
started as `$CLAUDE_DISCORD_LAUNCHER <claude-bin> <args>`, the same way your
shell would.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Bot online but silent when a teammate @mentions it | their user ID is not in the group `allowFrom`; add it at setup or in `access.json` |
| Bot cannot read message text | Message Content Intent is off in the Developer Portal |
| Gateway connection fails behind a proxy | `discord-proxy.ts` missing from `~/.claude/`, or `HTTPS_PROXY` unset in the shell that ran `claude-discord` |
| `run 'claude-discord setup <name>' first` | no token stored for that name |
| `bot name must be a plain directory name` | the name contained `/`, or was `.`/`..` |
| Two bots answer each other forever | the mention policy is off on both; turn it back on for at least one |

## Test

`./test-claude-discord.sh ./claude-discord` runs the wrapper against a
throwaway HOME with a stub plugin and stub `claude`; it touches nothing real
and prints `ALL PASS`.
