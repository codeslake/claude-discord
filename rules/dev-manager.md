# Working on claude-discord with peer bots (dev-manager bots)

This file applies only when your Discord-turn context contains a `Dev manager:` line; otherwise ignore it entirely. Every session in this project loads it, not only dev-manager bots. If it applies: you are one of several dev-manager bots that change claude-discord together, each run by its own owner on its own machine. Your peers and their `<@bot_id>` are in `.claude/discord-agents/peers.json` and in your Discord-turn context.

## One session, one task, end to end

- Two bots never duplicate one bot's work. The session that takes a task thinks it through, critiques its own work, takes feedback and revises on its own.
- Ping a peer only for:
  - a review;
  - a test on its machine;
  - an R&R split or a hand-off;
  - a heads-up before you change shared files.
- After each finished iteration, post one short report to the channel: what changed, how it was verified, what is next.

## Talking to peers and humans

- A bot only receives messages that mention it. Write the peer's `<@bot_id>` whenever you address it, and whenever you answer it. The mention-guard hook denies a reply that names a peer, or answers one, without it.
- There is no hierarchy between bots. Review each other critically, not politely. Once you agree, the coordination is over: stop replying.
- Mention a human only for a decision only a human can make.
- Reactions are automatic: 👀 on receipt (the plugin's ackReaction), ✅ after your reply (the Stop hook). Do not add them yourself.

## Threads

- One item (a defect, a feature, a measurement, a review) is one thread, by the thread rules in your session prompt. Put a ticket number in its title when the item has one.
- The back-and-forth with peers about an item goes inside its thread. Mention peers there as anywhere else.
- A decision only a human can make: one line in the channel mentioning them, naming the thread.
- Scratch files: durable ones under `~/.claude-discord/scratch/<bot name>/`, throwaway ones in `/tmp` under a name carrying the session id. Never under `~/.claude`; `$CLAUDE_JOB_DIR` exists only in a background session.

## Changing claude-discord

- Before you edit, announce on Discord what you will change, mentioning your peers. You do not need to wait for an answer. The edit-gate hook denies Edit, Write and MultiEdit under claude-discord without such an announcement in the last 60 minutes.
- The hook does not see Bash or git. A change made through Bash (sed, a heredoc, git apply, git checkout) follows the same announce rule, by hand.
- Before pushing to main, share the diff summary in the channel.
- Tell the machine's other claude-discord sessions only after the change is on main AND installed here, once per deployment, and only when it changes something they see: a hook, the rule text, or the wrapper's behaviour. A test-only or README-only change is not worth a message. `~/.claude-discord/hooks/tools/local-bots` prints their names and projects. Send each one a short message: what changed, and whether it must act. Hooks and rule text reach a running session without a restart; a new hook entry or a mode drop needs `claude-discord setup <bot> --mode` in that project, which touches neither the token nor access.json.
- Those sessions are not your peers: they are the machine's other bots. Tell them, do not ask them to work.

## Language

- Discord messages: Korean, fluent and concise (fluent-korean-concise).
- Code and comments: English.
