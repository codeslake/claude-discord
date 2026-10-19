#!/usr/bin/env python3
"""Run /reload-plugins or /reload-skills in THIS session, and later check that
it actually ran.

    self_cmd.py run "/reload-plugins"     type it into this session's input
    self_cmd.py verify reload-plugins     did a command record land after the run?

Those are harness commands, handled by the CLI, not by a tool: Bash cannot run it, and
SendMessage cannot carry it (every socket enqueue sets skipSlashCommands, so the
line arrives as words). The only way in is the session's own input:

  bg           the claude daemon owns it; its `reply` op types into it.
  interactive  the user's terminal owns it. A session cannot do this to itself:
               the user types the line.

`run` exit codes: 0 typed (NOT yet run: see verify), 2 interactive session, the
user must type it (the line is printed), 1 refused or failed (reason printed).
`verify` exit codes: 0 it ran (its output printed), 1 no record yet.
"""
import glob
import hashlib
import json
import os
import re
import socket
import sys
import time
from datetime import datetime

COMMANDS = ("/reload-plugins", "/reload-skills")
# One file per session (by pid): every session of a user shares /tmp, and a
# shared file let another session's `run` move this one's `since` past its record.
STATE = os.path.join(os.environ.get("TMPDIR") or "/tmp",
                     "self-reload-%d-%s.json" % (os.getuid(), os.environ.get("CLAUDE_PID", "0")))


def config_dir():
    return os.path.realpath(os.environ.get("CLAUDE_CONFIG_DIR")
                            or os.path.expanduser("~/.claude"))


def session_record():
    """This session's record, matched on the live pid, never on a name."""
    pid = int(os.environ.get("CLAUDE_PID") or 0)
    try:
        with open(os.path.join(config_dir(), "sessions", "%d.json" % pid)) as fh:
            rec = json.load(fh)
    except (OSError, ValueError):
        return None
    return rec if rec.get("pid") == pid else None


def control_sock():
    """Derived the way the CLI derives it, never searched for: two config dirs
    run two daemons, and the wrong one answers for somebody else's sessions."""
    h = hashlib.sha256(config_dir().encode()).hexdigest()[:8]
    base = os.path.join(os.environ["PREFIX"], "tmp") if os.environ.get("TERMUX_VERSION") else "/tmp"
    return os.path.join(base, "cc-daemon-%d" % os.getuid(), h, "control.sock")


def job_id(rec):
    """The JOB id, never sessionId[:8]: the wrong key answers ENOJOB, which reads
    as a dead job rather than a wrong key."""
    return rec.get("jobId") or os.path.basename(os.environ.get("CLAUDE_JOB_DIR") or "")


def daemon_reply(short, text, key, timeout=10):
    payload = json.dumps({"proto": 1, "op": "reply", "short": short,
                          "text": text, "auth": key}) + "\n"
    buf = b""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(timeout)
        s.connect(control_sock())
        s.sendall(payload.encode())
        while b"\n" not in buf:
            chunk = s.recv(4096)
            if not chunk:
                raise RuntimeError("the daemon closed without answering")
            buf += chunk
    ack = json.loads(buf.split(b"\n", 1)[0].decode())
    if not ack.get("ok"):
        raise RuntimeError(("daemon refused: %s %s" % (ack.get("code"), ack.get("error", ""))).strip())


def run(line):
    if line not in COMMANDS:
        print("only %s" % " and ".join(COMMANDS), file=sys.stderr)
        return 1
    rec = session_record()
    if rec is None:
        print("cannot identify this session (CLAUDE_PID has no record)", file=sys.stderr)
        return 1
    if rec.get("kind") != "bg":
        print("interactive session: it cannot run a harness command on itself.\n"
              "Ask the user to type this line in this session's prompt, then Enter:\n%s" % line)
        return 2
    short = job_id(rec)
    try:
        if not short:
            raise RuntimeError("the session record carries no jobId and CLAUDE_JOB_DIR is unset")
        with open(os.path.join(config_dir(), "daemon", "control.key")) as fh:
            key = fh.read().strip()
        daemon_reply(short, line, key)
        # A second, EMPTY reply 1 s later submits a line left sitting unsent and
        # adds nothing after a line that already ran.
        time.sleep(1.0)
        daemon_reply(short, "", key)
    except (OSError, RuntimeError, ValueError) as exc:
        print("refused: %s" % exc, file=sys.stderr)
        return 1
    with open(STATE, "w") as fh:
        json.dump({"at": time.time() - 2, "line": line}, fh)
    print("typed %r. Not yet run: it is this session's NEXT input, so end the turn and "
          "run `self_cmd.py verify %s` on the next one." % (line, line.lstrip("/").split()[0]))
    return 0


def verify(name):
    """0 and the command's output when a `commandRun` record for `name` landed
    after the last `run`, else 1."""
    try:
        with open(STATE) as fh:
            since = json.load(fh)["at"]
    except (OSError, ValueError, KeyError):
        since = 0
    rec = session_record()
    hits = rec and glob.glob(os.path.join(config_dir(), "projects", "*", "%s.jsonl" % rec.get("sessionId")))
    if not hits:
        print("no transcript found for this session", file=sys.stderr)
        return 1
    with open(hits[0], errors="replace") as fh:
        for raw in fh:
            if '"commandRun"' not in raw:
                continue
            try:
                d = json.loads(raw)
                at = datetime.fromisoformat(d["timestamp"].replace("Z", "+00:00")).timestamp()
            except (ValueError, KeyError):
                continue
            if d["commandRun"].get("command") == name and at >= since:
                out = re.sub(r"</?local-command-stdout>", "", d.get("content") or "")
                print("ran %s at %s: %s" % (name, d["timestamp"], out.strip() or "(no output)"))
                return 0
    print("no %s record after the run yet" % name, file=sys.stderr)
    return 1


def main(argv):
    if len(argv) == 2 and argv[0] == "run":
        return run(" ".join(argv[1].splitlines()).strip())
    if len(argv) == 2 and argv[0] == "verify":
        return verify(argv[1].lstrip("/"))
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
