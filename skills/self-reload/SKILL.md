---
name: self-reload
description: Run /reload-plugins or /reload-skills on THIS session. Use whenever you just edited a plugin, skill, hook or agent and need it picked up by your own session, whenever someone asks you to "reload", "reload plugins/skills" or "apply the new plugin/skill", and before telling anyone a reload happened. Bash cannot run these and SendMessage cannot carry them; this skill says which session kind can do it and how to prove it ran.
---

# self-reload

`/reload-plugins` and `/reload-skills` are harness commands: the CLI executes
them when they arrive as the session's own INPUT. No tool reaches
that input:

- **Bash** runs a shell. `/reload-plugins` there is a missing file, not a command.
- **SendMessage** sets `skipSlashCommands` on every delivery, so the line lands
  as plain words (and may open a skill of that name instead).

## The rule that trips everyone

**The typed line runs only after the calling turn ends, as the next turn's
input.** Nothing reloads while the turn that sent it is still running. So: send,
end the turn at once, and read the proof on the following turn. Waiting, polling
or re-checking inside the same turn proves nothing and only delays the reload.

## Which session are you?

`$CLAUDE_PID` names your record, `<config dir>/sessions/$CLAUDE_PID.json`. Its
`kind` decides everything:

| kind | can it self-reload? | how |
|---|---|---|
| `bg` | yes | the daemon's `reply` op types into the input it owns |
| anything else (interactive REPL) | **no** | give the user the exact line to type |

### Background session

```sh
python3 "${CLAUDE_PLUGIN_ROOT}/skills/self-reload/scripts/self_cmd.py" run "/reload-plugins"
```

It sends `{"proto":1,"op":"reply","short":<job id>,"text":"/reload-plugins","auth":<key>}`
to `/tmp/cc-daemon-<uid>/<sha256(realpath(config dir))[:8]>/control.sock`
(key from `<config dir>/daemon/control.key`), then a second reply with `""` one
second later, which submits a line left sitting unsent. The `short` is the JOB
id (record `jobId`, else the basename of `$CLAUDE_JOB_DIR`), never
`sessionId[:8]`, which answers `ENOJOB`.

`/reload-skills` the same way. Those two are the only commands it accepts.

Then **end the turn**. Never ask the user to type it: a bg session has no one at
its prompt, and the daemon route works.

### Interactive session

It cannot do this to itself. `run` exits 2 and prints the line; say so plainly
and hand the user that exact line, e.g. "Please type `/reload-plugins` in this
session." Do not look for another way in.

## Three states, only one of them is "reloaded"

| state | what you saw | what you may say |
|---|---|---|
| refused | `run` exit 1, `daemon refused: <code>` | it failed, with the code |
| typed | `run` exit 0 (`{"ok":true}` from the daemon) | "sent; it runs when this turn ends" |
| ran | `verify` exit 0 on the NEXT turn | "reloaded", quoting the output |

`{"ok":true}` means the daemon typed the line, nothing more. Never report a
reload from it.

On the next turn:

```sh
python3 "${CLAUDE_PLUGIN_ROOT}/skills/self-reload/scripts/self_cmd.py" verify reload-plugins
```

It looks in this session's transcript for a record with
`"commandRun":{"command":"reload-plugins"}` newer than the last `run`, and
prints its stdout (`Reloaded: N plugins · M skills · ...`). Quote that line as
the proof. No record means it did not run: say so, and `run` again.
