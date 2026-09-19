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

- One item (a defect, a feature, a measurement, a review) lives in one thread. Start it with `~/.claude-discord/hooks/tools/thread start "[<area>] <short title>"`: that posts the one line in the channel, opens its thread and prints the thread id. Put a ticket number in the title when the item has one.
- Everything else about that item goes inside the thread, passing that id as chat_id: the full answer, the diff summary, the measurements, and the back-and-forth with peers. Mention peers there as anywhere else.
- The channel holds two lines per item: the one that started it and one when it lands. Close the thread after the closing line: `~/.claude-discord/hooks/tools/thread close <thread_id>`. A thread nobody writes in is archived on its own after a day.
- A human's question in the channel: answer in one or two lines there, or start a thread and answer inside it.
- A decision only a human can make: one line in the channel mentioning them, naming the thread.
- The thread-guard hook denies a channel reply longer than 500 characters.
- Scratch files: durable ones under `~/.claude-discord/scratch/<bot name>/`, throwaway ones in `/tmp` under a name carrying the session id. Never under `~/.claude`; `$CLAUDE_JOB_DIR` exists only in a background session.

## Changing claude-discord

- Before you edit, announce on Discord what you will change, mentioning your peers. You do not need to wait for an answer. The edit-gate hook denies Edit, Write and MultiEdit under claude-discord without such an announcement in the last 60 minutes.
- The hook does not see Bash or git. A change made through Bash (sed, a heredoc, git apply, git checkout) follows the same announce rule, by hand.
- Before pushing to main, share the diff summary in the channel.

## Language

- Discord messages: Korean, fluent and concise (fluent-korean-concise).
- Code and comments: English.
