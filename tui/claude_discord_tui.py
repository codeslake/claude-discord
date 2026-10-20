# /// script
# requires-python = ">=3.9"
# dependencies = ["textual>=8.2.8,<9"]
# ///
"""claude-discord tui: a view of a manager bot's backend monitor, and where its hosts are added, set and removed.

Started by `claude-discord tui [<bot>]` through `uv run --script`. It registers
itself as a holder of the monitor (which starts the monitor if none runs),
re-reads state.json when its mtime changes (checked every 2 s) and removes its
holder record on quit. Three tabs (Bots, Alerts, Configuration) over that one
file, plus the display names the bots of this machine keep in `user-names`.
Since 1.12.0 the Configuration tab changes the manager's hosts ledger, always
through `claude-discord hosts` (it never writes the ledger itself, and never
reads it: the CLI gives it key names, no value), and asks the monitor for a
pass with `claude-discord monitor --check`. It reads `~/.ssh/config` as text
and runs `ssh -G` for the one alias the user chose. Since 1.13.0 `e` on a bot
row edits who may drive that bot (its channels, senders, DM policy and mode),
read through `claude-discord access ... --json` and written by
`claude-discord access ... set`, run on a pty the TUI holds (1.13.1): its
question is shown in a popup and the answer written back. Since 1.14.0 `n`
renames a bot (on Discord and here; `=` renames it here to Discord's name, restarting
it if it runs; `enter` shows Discord's name when the two differ), `t` replaces its
token and `a` on the Bots tab adds a bot, each through `claude-discord bot`
on such a pty; a token typed here is written to that pty when the CLI asks for
it (its echo off), never to an argument, a file or the screen. Nothing else:
no restart of its own, no post, no patch, and it never reads a .env or an
access.json, so it cannot show a token.
"""
from __future__ import annotations

import argparse
import copy
import fnmatch
import glob
import json
import os
import re
import select
import shlex
import signal
import subprocess
import threading
import time
from datetime import datetime, timezone
from itertools import islice
from pathlib import Path

from rich.cells import cell_len, set_cell_size
from rich.text import Text
from textual.app import App, ComposeResult, SuspendNotSupported
from textual.binding import Binding
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual import events
from textual.events import Paste, Resize
from textual.geometry import Region
from textual.screen import ModalScreen, Screen
from textual.widgets import Button, Footer, Input, Static

# The slack4agents pane's palette: nothing saturated but an alert.
BRAND, WARN, OK, ALERT, BAR, TAB, CURSOR = "#5fd7ff", "#ffaf00", "#87d787", "#ff5f87", "#3a3a3a", "#585858", "#4e4e4e"
DIM = "dim"    # the terminal's own dim, as the pane's dimColor
DASH = "-"     # a value the state does not have: an older claude-discord on that host, or nothing to show
WIDE = 110     # below it the KPI band is one line and the table's project, receives and env columns fold away
STATUS_MIN, BOT_MAX = 15, 45   # at WIDE and above: the status column's least width (it holds `posted just now`) and the bot column's most
TABS = ("bots", "alerts", "config")
PROBLEM = ("down", "stale", "duplicate", "unreachable", "stale-session")   # stale-session (1.19.0): a server of no bot; fix: claude stop
# The findings the channel is told within 5 minutes of their appearing. Any other is a warning only (the reducer's
# warn_only): told after half an hour (throttled, apierror, hostdown) or never (noreach, a verdict this version does not know).
LOUD = PROBLEM + ("nostate", "patchfail", "blind")
GOOD = ("busy", "ok")
WORD = {"down": "DOWN", "stale": "STUCK", "duplicate": "DUPLICATE", "unreachable": "UNREACHABLE", "throttled": "rate-limited",
        "apierror": "api error", "nostate": "no state", "blind": "blind", "noreach": "no network", "busy": "working", "ok": "ok",
        "unknown": "no token", "stale-session": "STALE SESSION", "held": "held"}


# What text another machine wrote (a ledger host's health document is copied into the state as it is, a display name
# comes from Discord) must not bring to the terminal: the C0 and C1 controls and DEL (an ESC opens a sequence that sets
# the clipboard or the window title, hides text or clears the screen; Rich and Textual let it through), the bidi
# controls (they reorder the rest of the line) and the zero-width characters (cells that are not there). A tab or a
# line break would split a row: one space each. Only a post's `text` keeps its line breaks (UNSAFE_NL): the monitor
# wrote it over several lines and it is drawn in a body of its own, never in a row.
UNSAFE = dict.fromkeys([*range(0x20), *range(0x7f, 0xa0), *range(0x202a, 0x202f), *range(0x2066, 0x206a), *range(0x200b, 0x2010), 0x2060, 0xfeff])
UNSAFE.update({9: " ", 10: " ", 13: " "})
UNSAFE_NL = {**UNSAFE, 10: "\n"}


def clean(v, table=UNSAFE):
    """`v` with every string in it, a dict's keys too, safe to draw (UNSAFE)."""
    if isinstance(v, str):
        return v.translate(table)
    if isinstance(v, dict):
        return {clean(k): clean(x, UNSAFE_NL if k == "text" and isinstance(x, str) else UNSAFE) for k, x in v.items()}
    return [clean(x) for x in v] if isinstance(v, list) else v


def load(path: Path) -> dict:
    """The state, cleaned once here: nothing drawn or copied (`c`) is built from the file's own strings."""
    try:
        data = json.loads(path.read_text())
        return clean(data) if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


# A value of the state is read through one of these three wherever its type matters. The monitor's reducer copies the
# fields of each host's health document as they are, so a host of another version (or a hand edit) can put any JSON
# anywhere: a number for a name, an object for a list. The wrong type reads as missing, which every caller already
# draws as "-"; nothing raises, since one bad field would otherwise take the whole screen down on every machine watching.
def txt(v) -> str:
    return v if isinstance(v, str) else ""


def obj(v) -> dict:
    return v if isinstance(v, dict) else {}


def seq(v) -> list:
    return v if isinstance(v, list) else []


def epoch(iso: str | None) -> float | None:
    try:
        return datetime.strptime(iso or "", "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
    except (TypeError, ValueError):
        return None


def ago(iso: str | None, now: float) -> str:
    """'now', '12m', '3h', '2d' since an ISO time; '' when unknown."""
    t = epoch(iso)
    if t is None:
        return ""
    s = max(0, int(now - t))
    return "now" if s < 60 else f"{s // 60}m" if s < 3600 else f"{s // 3600}h" if s < 172800 else f"{s // 86400}d"


def since(iso: str | None, now: float) -> str:
    """What follows `posted` and `last seen`: ' 12m ago', ' just now' under a minute, '' when the time is unknown."""
    a = ago(iso, now)
    return " just now" if a == "now" else f" {a} ago" if a else ""


def hhmm(t: float | None) -> str:
    return time.strftime("%H:%M", time.localtime(t)) if t is not None else DASH


def fit(s: str, w: int) -> str:
    """`s` in exactly `w` terminal cells (a Hangul or CJK character takes two): padded, or cut with an ellipsis. A cell
    that is no text (a state value of another type) is a dash."""
    if not isinstance(s, str):
        s = DASH
    if cell_len(s) <= w:
        return set_cell_size(s, w)
    return set_cell_size(s, w - 1) + "…" if w > 0 else ""


def wrap(s: str, w: int, n: int) -> list[str]:
    """`s` broken at spaces into at most `n` lines of `w` cells; what is left over stays on the last one (fit cuts it)."""
    lines, cur = [], ""
    for word in s.split():
        if cur and cell_len(cur) + 1 + cell_len(word) > w and len(lines) < n - 1:
            lines.append(cur)
            cur = word
        else:
            cur = f"{cur} {word}" if cur else word
    return lines + [cur] if cur else lines


def fold_names(label: str, names: list, w: int, n: int = 3) -> list[str]:
    """`label a, b, c` on at most `n` lines of `w` cells; the names with no room left are counted: `+2`."""
    lines, cur = [], label
    for i, name in enumerate(names):
        rest = len(names) - i - 1
        if cell_len(name) > w - 4:   # one name wider than the column: cut, so it still gets a line
            name = fit(name, max(w - 4, 1)).rstrip()
        piece = name + ("," if rest else "")
        while True:
            last = len(lines) == n - 1
            room = w - (cell_len(f" +{rest}") if last and rest else 0)
            if cell_len(cur) + (1 if cur else 0) + cell_len(piece) <= room:
                cur = f"{cur} {piece}" if cur else piece
                break
            if last or not cur:
                return lines + [f"{cur.rstrip(',')} +{rest + 1}".strip()]
            lines.append(cur)
            cur = ""
    return lines + [cur]


def rank(verdict: str) -> int:
    """0 a problem, 1 needs a look (any verdict this version does not know too), 2 healthy, 3 no token."""
    return 0 if verdict in PROBLEM else 2 if verdict in GOOD else 3 if verdict in ("unknown", "held") else 1   # held: bot <bot> hold (1.19.1)


def mark(verdict: str) -> tuple[str, str]:
    """A status as symbol + word, and its colour."""
    r = rank(verdict)
    sym, style = (("✕", f"bold #000000 on {ALERT}"), ("▲", WARN), ("◐" if verdict == "busy" else "●", BRAND if verdict == "busy" else OK), ("○", DIM))[r]
    return f"{sym} {WORD.get(verdict, verdict or '?')}", style


def host_label(state: dict, host: str) -> str:
    """The ledger's display name (`name=`), else the machine's own hostname (local), else the ssh alias."""
    h = obj(obj(state.get("hosts")).get(txt(host)))
    return txt(h.get("display")) or txt(h.get("name")) or txt(host) or DASH


def cut_off(state: dict, b: dict) -> bool:
    """The last pass could not ask this bot's host (its `reach` is hostdown, blind or noreach), so the monitor froze the
    bot with the last verdict it saw: not a current one. A host the state does not list counts as reachable."""
    h = obj(state.get("hosts")).get(txt(b.get("host")))
    return h is not None and obj(h).get("reach") != "ok"


def group(state: dict, b: dict) -> float:
    """rank, and 1.5 for a bot of a host that cannot be reached: after what needs a look, before the healthy."""
    return 1.5 if cut_off(state, b) else rank(b.get("verdict"))


def sorted_bots(state: dict) -> list[tuple[str, dict]]:
    """(key, entry) for the Bots tab: problems, then what needs a look, then the bots of a host that cannot be reached,
    then healthy, then no token; by bot name, then host, within each (the key is host|project path|bot: random by name).
    A host|project|- entry (a project whose health crashed before any bot of it was known) has no `bot`: a row with bot
    '-', the first of its group."""
    return sorted(((k, b) for k, b in obj(state.get("bots")).items() if isinstance(b, dict)),
                  key=lambda kv: (group(state, kv[1]), txt(kv[1].get("bot")), txt(kv[1].get("host")), kv[0]))


def kpi(state: dict) -> dict:
    """The numbers of the KPI band. The denominator is every bot; a bot with no token is counted apart, not as a problem,
    and a bot of a host that cannot be reached in none of the counts: the Hosts box says that host is out."""
    rows = [b for _, b in sorted_bots(state)]
    by = [[b for b in rows if group(state, b) == r] for r in range(4)]
    hosts = [(k, obj(h)) for k, h in sorted(obj(state.get("hosts")).items()) if obj(h).get("left_s") is None]
    bad = [k for k, h in hosts if h.get("reach") != "ok"]
    first = lambda bs: (txt(bs[0].get("bot")) or DASH) if bs else ""
    return {"problems": len(by[0]), "look": len(by[1]), "healthy": sum(1 for b in by[2] if txt(b.get("bot"))), "notoken": len(by[3]),
            "bots": sum(1 for b in rows if txt(b.get("bot"))), "first_problem": first(by[0]),
            "problem_word": WORD.get(txt(by[0][0].get("verdict")), "").lower() if by[0] else "", "first_look": first(by[1]),
            "hosts": len(hosts), "hosts_ok": len(hosts) - len(bad), "first_unreachable": host_label(state, bad[0]) if bad else ""}


def kpi_lines(state: dict, width: int) -> list[Text]:
    """Three rows of four boxes; below WIDE one line: `✕ 1  ▲ 1  ● 3  ○ 1 of 6 bots   hosts 2/3`."""
    k = kpi(state)
    if width < WIDE:
        return [Text.assemble((f"✕ {k['problems']}", ALERT if k["problems"] else DIM), "  ", (f"▲ {k['look']}", WARN if k["look"] else DIM), "  ",
                              (f"● {k['healthy']}", OK), "  ", (f"○ {k['notoken']}", DIM), (f" of {k['bots']} bots   hosts {k['hosts_ok']}/{k['hosts']}", DIM))]
    boxes = [(ALERT if k["problems"] else TAB, [("✕ Problems ", ""), (str(k["problems"]), f"bold {ALERT}" if k["problems"] else "bold"),
                                               (f"  {k['first_problem']} {k['problem_word']}" if k["problems"] else "", DIM)]),
             (WARN if k["look"] else TAB, [("▲ Needs a look ", ""), (str(k["look"]), f"bold {WARN}" if k["look"] else "bold"), (f"  {k['first_look']}", DIM)]),
             (TAB, [("● Healthy ", ""), (str(k["healthy"]), f"bold {OK}"), (f" of {k['bots']} bots", "")]),
             (TAB, [("Hosts ", ""), (f"{k['hosts_ok']} / {k['hosts']}", "bold"),
                    (f"  {k['first_unreachable']} unreachable" if k["first_unreachable"] else "", DIM)])]
    bw = (width - 3) // 4
    top, mid, bot = Text(), Text(), Text()
    for i, (edge, parts) in enumerate(boxes):
        inner = Text.assemble(*parts)
        inner.truncate(bw - 4, overflow="ellipsis", pad=True)
        gap = " " if i else ""
        top.append(gap + "╭" + "─" * (bw - 2) + "╮", edge)
        mid.append_text(Text.assemble(gap, ("│ ", edge), inner, (" │", edge)))
        bot.append(gap + "╰" + "─" * (bw - 2) + "╯", edge)
    return [top, mid, bot]


def columns(width: int, bot: int = 16, status: int = 25) -> list[tuple[str, int]]:
    """The Bots table's columns and their widths in cells: 110 in all at WIDE with a 16-cell bot and a 25-cell status,
    the room past it shared by channel, receives and project; below WIDE project and receives fold away and channel
    takes what is left. `bot` and `status` are those two columns' widths at WIDE and above (bots_items sizes both from
    what the rows hold): what `bot` takes past 16 comes out of that shared room and what `status` leaves of its 25
    goes into it, so the table is as wide as before."""
    if width >= WIDE:
        extra = width - WIDE - (bot - 16) + (25 - status)
        return [("bot", bot), ("status", status), ("host", 9), ("channel", 18 + extra // 3), ("receives", 20 + extra // 3),
                ("last", 5), ("project", 9 + extra - 2 * (extra // 3))]
    return [("bot", 16), ("status", 25), ("host", 9), ("channel", max(8, width - 62)), ("last", 5)]


def groups(acc: dict) -> list[dict]:
    """The access groups as health 1.11.0 sends them: objects with a string `id`. Anything else there is no group."""
    return [g for g in seq(acc.get("groups")) if isinstance(g, dict) and isinstance(g.get("id"), str)]


def ids(v) -> list[str]:
    return [i for i in seq(v) if isinstance(i, str)]


def channels(b: dict, manager: str, w: int, opened: bool) -> list[str]:
    """The channel column: the bot's channel; open, every channel of its access groups (by name when health 1.11.1 sent
    one, by id otherwise) and, for the manager bot, the alert channel it only writes to."""
    ch = txt(b.get("channel"))
    if not ch:
        return [DASH]
    main = "#" + (txt(b.get("channel_name")) or ch)
    if not opened:
        return [main]
    others = ["#" + (txt(g.get("name")) or g["id"]) for g in groups(obj(b.get("access"))) if g["id"] != ch]
    wo = ["#bot-health-check (write-only)"] if b.get("bot") == manager and b.get("host") == "local" else []
    out = []
    for line in [main + (" (main)" if others or wo else "")] + others + wo:   # a note that does not fit goes under its channel
        out += [line] if cell_len(line) <= w or " (" not in line else [line[:line.rindex(" (")], "  " + line[line.rindex(" (") + 1:]]
    return out


def receives(b: dict, names: dict, w: int, opened: bool) -> list[str]:
    """The receives column, from the access group of the bot's channel: one line; open, the mention rule, who may write
    (names from user-names, ids when unknown, `+N` past the room) and the DM policy."""
    acc = obj(b.get("access"))
    grp = next((g for g in groups(acc) if g["id"] == b.get("channel")), None)
    if not grp:
        return [DASH]
    allow = [names.get(i, i) for i in ids(grp.get("allow"))]
    rule = "@mention" if grp.get("mention", True) else "any message"
    if not opened:
        return [f"{rule} · {'anyone' if not allow else '1 user' if len(allow) == 1 else f'{len(allow)} users'}"]
    dms = [names.get(i, i) for i in ids(acc.get("dm_allow"))]
    dm = txt(acc.get("dm"))
    return ([rule + (" required" if grp.get("mention", True) else "")] + (fold_names("from", allow, w) if allow else ["from anyone"])
            + (fold_names("DMs", dms, w) if dm == "allowlist" and dms else [f"DMs {'nobody' if dm == 'allowlist' else dm or DASH}"]))


def row_lines(cells: list[tuple[list, int]], lead: str = "  ") -> list[Text]:
    """Table lines from one row's cells: each cell is ([(text, style), ...] one per line, width) and grows downward in its
    own column; every line comes out the same number of cells wide, whatever the script."""
    out = []
    for i in range(max(len(c) for c, _ in cells)):
        line = Text(lead if i == 0 else " " * cell_len(lead))
        for j, (c, w) in enumerate(cells):
            s, style = c[i] if i < len(c) else ("", "")
            line.append(" " if j else "")
            if isinstance(s, Text):   # a cell of two styles (a bot's name and mode): cut and padded as fit does
                s.truncate(w, overflow="ellipsis", pad=True)
                line.append_text(s)
                continue
            line.append(fit(s, w), style)
        out.append(line)
    return out


def fix_of(state: dict, b: dict) -> str:
    """The recovery command drawn under a row, which is what `c` copies: a problem's. Not a warning's (its `fix` is only
    `health` again) and not on a host that cannot be reached (the command would go through it)."""
    return txt(b.get("fix")) if rank(b.get("verdict")) == 0 and not cut_off(state, b) else ""


def recoverable(state: dict, b: dict) -> str:
    """What `f` runs for this row (1.16.0): "recover" for a down or a stale bot, "" for every other verdict (a
    duplicate's fix is a choice, an unreachable one's the token; a warning's is a re-check), a bot of a host the last
    pass could not reach (the command would go through it, and the verdict is not a current one), and a row that is no
    bot the CLI can reach (bot_row's own test). Never "recover --fresh" (1.17.1): it discards the conversation, and a
    STUCK row is not proof the session is wedged (cswap, 2026-10-17: working on something else for 7 h; `f` ran --fresh
    on it). --fresh is the CLI's alone, and the CLI refuses it while the session's transcript moves."""
    if cut_off(state, b) or not (txt(b.get("bot")) and txt(b.get("project")) and ALIAS.fullmatch(txt(b.get("host")))):
        return ""
    return "recover" if txt(b.get("verdict")) in ("down", "stale") else ""


def status_head(state: dict, b: dict, now: float) -> tuple[str, str]:
    """A row's status as its closed row shows it, and its colour: symbol + word, a problem's with how long it has stood."""
    cut = cut_off(state, b)
    word, style = ("○ host unreachable", DIM) if cut else mark(txt(b.get("verdict")))
    return (f" {word} {ago(b.get('since'), now)} " if rank(b.get("verdict")) == 0 and not cut else word), style


def discord_name(b: dict) -> str:
    """Discord's name for the bot when it is not the bot's name here (health 1.14.0's discord_name), else ''."""
    d = txt(b.get("discord_name"))
    return d if d and d != txt(b.get("bot")) else ""


def discord_line(b: dict, width: int) -> Text | None:
    """The all-fields view's line for a bot whose Discord username is not its name here (health 1.14.0's discord_name),
    else None: Discord's name, `=` as a key, and what it does (a running session is stopped and started again by the
    rename). Not in the list: a bot kept under another name on purpose would pay a row for it for ever. Below WIDE the
    restart note goes, never the name."""
    if not discord_name(b):
        return None
    return Text.assemble(("Discord name: ", DIM), (discord_name(b), WARN), ("   ", DIM), ("=", f"bold {BRAND}"),
                         (" rename here to Discord's" + (" (restarts it if running)" if width >= WIDE else ""), DIM))


def with_mode(entry: dict) -> dict:
    """A bot's entry for the all-fields screen: `mode` is always there, a dash when the host sent none (before 1.11.1)."""
    return dict(obj(entry), mode=txt(obj(entry).get("mode")) or DASH)


def bots_items(state: dict, names: dict, width: int, opened: set, now: float) -> list[tuple]:
    """The Bots tab as (row key or None, [Text, ...]) items: a key makes its lines one row the cursor can sit on."""
    # A mode other than `none` follows the bot's name at WIDE and above. There the bot and status columns are sized
    # from the rows: status as wide as the widest status a closed row shows (STATUS_MIN at least, its old 25 at most:
    # `● ok` leaves most of 25 cells empty), and what that frees, with the terminal's cells past WIDE, goes to the bot
    # column first, up to the longest name with its mode (BOT_MAX at most), then to channel, receives and project
    # (columns). On top of what is free the bot column may take 13 cells from those three, as it could in 1.11.1 (29
    # in all then). Only closed-row texts count, so opening a row moves no column; what an opened row adds to its
    # status wraps inside it.
    rows = sorted_bots(state)
    heads = {key: status_head(state, b, now) for key, b in rows}
    tags = {key: txt(b.get("mode")) for key, b in rows if width >= WIDE and txt(b.get("mode")) not in ("", "none")}
    sw = min(25, max([STATUS_MIN] + [cell_len(h) for h, _ in heads.values()])) if width >= WIDE else 25
    want = max([16] + [cell_len(txt(b.get("bot")) or DASH) + (2 + cell_len(tags[key]) if key in tags else 0) for key, b in rows])
    cols = columns(width, min(want, BOT_MAX, 29 + width - WIDE + 25 - sw), sw)
    # As much of a text as its lines held at 25 cells: a narrower column gets more lines, never less of the text.
    lines = lambda s, n: wrap(s, sw, max(n, -(-25 * n // sw)))
    items: list[tuple] = [(None, kpi_lines(state, width) + [Text()]),
                         (None, row_lines([([(n, f"bold {DIM}")], w) for n, w in cols]))]
    for key, b in rows:
        o, v, r, cut = key in opened, txt(b.get("verdict")), rank(b.get("verdict")), cut_off(state, b)
        status = [heads[key]]
        if o and cut:   # not its reason, which is as old as the verdict: when the host stopped answering (its `since`)
            seen = since(obj(obj(state.get("hosts")).get(txt(b.get("host")))).get("since"), now)
            status += [(s, "") for s in lines(f"last seen {WORD.get(v, v or '?')}{seen}", 2)]
            if b.get("posted"):
                status.append((f"posted{since(b.get('posted_at'), now)}", DIM))
        elif o:
            status += [(s, "") for s in lines(txt(b.get("detail")), 3)]
            if r < 2:   # from the verdict, not from its not_posted record in `alerts`: only the last 100 records are kept
                status += [(s, DIM) for s in lines(f"posted{since(b.get('posted_at'), now)}" if b.get("posted") else
                                                   "not posted yet" if v in LOUD else "not posted (warning only)", 1)]
        project = txt(b.get("project"))
        name = txt(b.get("bot")) or DASH
        cell = {"bot": [(Text.assemble((name, "bold"), ("  " + tags[key], DIM)) if key in tags else name, "bold")], "status": status, "host": [(host_label(state, b.get("host")), DIM)],
                "channel": [(s, "") for s in channels(b, state.get("manager"), dict(cols)["channel"], o)],
                "receives": [(s, "" if i == 0 or not o else DIM if s.startswith("DMs") else "")
                             for i, s in enumerate(receives(b, names, dict(cols).get("receives", 0), o))],
                "last": [((ago(b.get("last_message_at"), now) or DASH).rjust(5), DIM)],
                "project": [("~" if project and project == b.get("home") else project.rstrip("/").rsplit("/", 1)[-1] or DASH, DIM)]}
        items.append((key, row_lines([(cell[n], w) for n, w in cols], "▾ " if o else "▸ ")))
        if fix_of(state, b):   # one full-width line, never wrapped into a column, so it selects and copies whole
            # 1.16.0: the keys that run it, on a row f takes (down, stale); the ssh form of the line is 74 cells, so a
            # short form below WIDE.
            hint = ("   f runs it · F runs every recovery · c copies it" if width >= WIDE else "   f runs · F all · c copies") if recoverable(state, b) else "   c copies it"
            items.append((None, [Text.assemble(("     fix  ", DIM), (fix_of(state, b), BRAND), (hint, DIM))]))
        if o:   # what can be done to the bot, under an opened row (the foot has no room for all of it)
            items.append((None, [Text("     keys  e access · n name · t token · f recover · enter all fields", DIM)]))
    return items


def alive(pid: int, bot: str) -> bool:
    """The monitor of `bot` runs: pid's command line is `bash <root>/monitor/monitor.sh <wrapper> --locked <bot>`. A pid
    reused by another program, a zombie or another bot's monitor is not one (state.json keeps the pid of a monitor that
    died without its trap). /proc on Linux, one `ps` elsewhere."""
    if not isinstance(pid, int) or pid <= 0:
        return False
    try:
        if os.path.isdir("/proc/self"):
            cmd = Path(f"/proc/{pid}/cmdline").read_bytes().decode(errors="replace").replace("\0", " ").strip()
        else:
            cmd = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return False
    return "monitor/monitor.sh" in cmd and cmd.endswith(f" --locked {bot}")


def open_alerts(state: dict) -> list[dict]:
    """What the channel was told and has not seen recover: every entry with `posted`, as an alerts record (with the text
    of the last finding sent for its key, when that record is still kept), newest first. Not a host that left the ledger
    (`left_s`: kept a day, frozen) nor its bots: nothing checks them, so nothing of theirs can recover."""
    out, alerts, hosts = [], [a for a in seq(state.get("alerts")) if isinstance(a, dict)], obj(state.get("hosts"))
    for scope in ("hosts", "bots"):
        for k, e in obj(state.get(scope)).items():
            e = obj(e)
            if e.get("posted") and obj(hosts.get(k if scope == "hosts" else txt(e.get("host")))).get("left_s") is None:
                key = k + "|-" if scope == "hosts" else k
                out.append({"ts": txt(e.get("posted_at")), "key": key, "kind": "finding", "verdict": e["posted"], "status": "sent", "detail": e.get("detail"),
                            "text": next((x.get("text") for x in reversed(alerts) if x.get("key") == key and x.get("kind") == "finding"
                                          and x.get("status") == "sent"), None)})
    return sorted(out, key=lambda a: a["ts"], reverse=True)


def render(items: list[tuple], cursor: str | None, width: int) -> tuple[Text, int, int]:
    """The pane's text, and the first line and height of the cursor's row (highlighted to the edge)."""
    out, at = [], (0, 1)
    for key, lines in items:
        if key is not None and key == cursor:
            at = (len(out), len(lines))
            lines = [l.copy() for l in lines]
            for l in lines:
                l.pad_right(max(0, width - l.cell_len))
                l.stylize(f"on {CURSOR}")
        out += lines
    return Text("\n").join(out), at[0], at[1]


def title_line(state: dict, width: int, now: float, live: bool, stopped: bool, version: str = "") -> Text:
    """`◆ claude-discord <version>  <manager>` and, on the right, the backend's status: symbol + word + colour. The
    version is what follows `claude-discord ` in the wrapper's --version line (1.14.1), `1.14.1 (8db5787)`; a TUI
    started without one (an older wrapper) shows none."""
    m, mgr = obj(state.get("monitor")), txt(state.get("manager")) or "?"
    left = Text.assemble(("◆ claude-discord", f"bold {BRAND}"), *([(" " + version, DIM)] if version else []), ("  " + mgr, DIM))
    due, took = epoch(m.get("next_pass")), m.get("pass_s")
    took = took if isinstance(took, (int, float)) and not isinstance(took, bool) else 0
    if stopped or m.get("stopped_by_user"):   # monitor --stop: nothing starts it until monitor --start
        right = Text.assemble(("○ stopped by you", "bold"), ("  start: ", DIM), (f"claude-discord monitor --start {mgr}", BRAND))
    elif not live:
        right = Text("○ not running", DIM)
    # next_pass is the last pass's START plus the interval, and state.json is written when a pass ENDS: a pass under way
    # is not overdue. Overdue is one tick (30 s) past the time a pass may take: twice the last one, 120 s at least.
    elif due is not None and now - due > 30 + max(120, 2 * took):
        right = Text.assemble(("▲ check overdue", f"bold {WARN}"), (f"  due {hhmm(due)} · now {hhmm(now)}", DIM))
    else:
        checked = ago(m.get("last_pass"), now)
        nxt = max(0, int(due - now) + 59) // 60 if due is not None else None
        right = Text.assemble(("● live", f"bold {OK}"), ("  " + " · ".join(
            (["keeper"] if any(obj(h).get("kind") == "keeper" for h in seq(m.get("holders"))) else [])
            + ([f"checked {checked} ago" if checked != "now" else "checked just now"] if checked else ["not checked yet"])
            + ([f"next {nxt}m"] if nxt is not None else [])), DIM))
    if left.cell_len + 2 + right.cell_len > width:   # a narrow terminal: the status alone, cut at the edge
        right.truncate(width, overflow="ellipsis")
        return right
    return Text.assemble(left, " " * (width - left.cell_len - right.cell_len), right)


def tabs_lines(tab: str, n_open: int, width: int, at: list | None = None) -> Text:
    """The tab row: the active tab filled, and underlined `━` in brand on the rule below it. `at` is given the
    (first cell, end, tab) of each label as it is laid out: the cells a click on the tabs is matched against."""
    row, under = Text(), Text()
    for t, label in zip(TABS, ("Bots", f"Alerts {n_open}", "Configuration")):
        if at is not None:
            at.append((row.cell_len, row.cell_len + len(label) + 2, t))
        row.append(f" {label} ", f"bold on {TAB}" if t == tab else DIM)
        row.append(" ")
        under.append("━" * (len(label) + 2) if t == tab else "─" * (len(label) + 2), BRAND if t == tab else TAB)
        under.append("─", TAB)
    under.append("─" * max(0, width - under.cell_len), TAB)
    return Text("\n").join([row, under])


def foot_line(tab: str, width: int = WIDE) -> Text:
    """The keys of a tab. The Bots tab's are 110 cells and the Configuration tab's 91: below WIDE the labels are
    shorter, and the Bots tab's enter is said under an opened row instead, so every key fits in 80 (n, t and = are
    said under a row too)."""
    fields, copy, edit, add, bot = ("all fields", "copy fix", "settings", "add host", "add bot") if width >= WIDE else ("all", "copy", "edit", "add", "add")
    select, expand, access = ("select", "expand", "access") if width >= WIDE else ("move", "open", "edit")
    keys = {"bots": (("↑↓", select), ("space", expand)) + ((("enter", fields),) if width >= WIDE else ()) + (("e", access), ("a", bot), ("c", copy), ("←→", "tabs"), ("q", "quit")),
            "alerts": (("↑↓", "select"), ("enter", "the post's text"), ("←→", "tabs"), ("q", "quit")),
            "config": (("←→", "tabs"), ("↑↓", "select"), ("enter", edit), ("a", add), ("x", "remove"), ("l", "laptop"), ("q", "quit"))}[tab]
    out = Text(" ")
    for k, what in keys:
        out.append(f" {k} ", f"bold on {TAB}")
        out.append(f" {what}  ", DIM)
    return out


def bar_text(state: dict, note: str = "", stopped: bool = False, refused: bool = False) -> str | None:
    """The red bar's text (None when there is nothing to warn about): what the title's one status cannot say. `note` is
    why `monitor --ensure` failed, when it did: the one place a refusal is visible. `stopped`: the `stopped` marker
    (monitor --stop) stands; the title says so. `refused`: this side's `refused.<pid namespace id>` marker (a detached
    start met a monitor lock this side cannot see; a start that gets through clears it) stands."""
    m = obj(state.get("monitor"))
    pid = m.get("pid")
    bar = None
    if not state:
        bar = "no state yet: the monitor has not written state.json"
    elif stopped or m.get("stopped_by_user"):
        pass
    elif refused:   # held until a start gets through (monitor --start), like the stopped marker
        bar = (f"auto-start refused here: another side holds the monitor lock (shared home?). "
               f"Start here with: claude-discord monitor --start {state.get('manager', '?')}")
    elif not pid:
        bar = f"monitor stopped at {m.get('stopped_at') or '?'}"
    elif not alive(pid, state.get("manager") or ""):   # killed without its trap (kill -9, OOM): its pid stays in state.json
        bar = f"monitor pid {pid} is gone"
    elif m.get("error"):   # the last pass could not be folded into the state: nothing in it is current
        bar = f"the last pass failed: {m['error']}"
    elif m.get("post_failed"):
        bar = "the last POST to #bot-health-check failed; it is retried next pass"
    if note:
        bar = f"{bar}; {note}" if bar else note
    return bar


def proj_key(project: str) -> str:
    """The project's state key, as bin/lib/state.sh's proj_key makes it: every byte of the UTF-8 path that is not
    [A-Za-z0-9] a dash (bash in the C locale works on bytes: one Hangul syllable is three dashes)."""
    return bytes(c if c in b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789" else 45 for c in project.encode()).decode()


def load_names(state: dict) -> dict:
    """id -> display name, from the `user-names` file of every bot on this machine (written by on-prompt: `<id> <name>`,
    in ~/.claude-discord/projects/<key>/bots/<bot>/ since 1.18.0). A remote bot's file is out of reach, so its ids get a
    name only when that person wrote to a local bot too."""
    names = {}
    for b in obj(state.get("bots")).values():
        b = obj(b)
        bot, project = txt(b.get("bot")), txt(b.get("project"))
        if b.get("host") != "local" or not bot or not project:
            continue
        try:
            text = (Path.home() / ".claude-discord" / "projects" / proj_key(project) / "bots" / bot / "user-names").read_text(errors="replace")
        except OSError:
            continue
        for line in text.splitlines():
            uid, _, name = line.partition(" ")
            name = clean(name)   # on-prompt removes whitespace runs and <>@"(), only
            if uid.isdigit() and name:
                names[uid] = name
    return names


def entry_text(key: str, akey: str, entry: dict, alerts: list) -> str:
    """Every raw field of a bot or host entry, then the posts for its key."""
    fields = "\n".join(f"{k:<16} {v if isinstance(v, str) else json.dumps(v, ensure_ascii=False)}" for k, v in sorted(obj(entry).items()) if k != "fix")
    mine = [a for a in seq(alerts) if isinstance(a, dict) and a.get("key") == akey]
    return f"{key}\n\n{fields}\n\nposts for this key:\n" + ("\n".join(
        f"{a.get('ts')}  {a.get('kind')}  {a.get('verdict')}  {a.get('status')}" for a in mine) or "(none)")


class Detail(Screen):
    """Enter on a row: its text in full, and the recovery command in a widget of its own so it selects and copies whole."""
    BINDINGS = [Binding("escape", "app.pop_screen", "back")]

    def __init__(self, body: str, fix: str | None = None, name: Text | None = None) -> None:
        super().__init__()
        self.body, self.fix, self.dname = body, fix, name   # dname: discord_line's, for a bot whose two names differ

    def compose(self) -> ComposeResult:
        with VerticalScroll():
            if self.dname is not None:
                yield Static(self.dname, id="discord")
            yield Static(self.body, id="body-detail", markup=False)   # state-derived text: [..] in it is text, not markup
            if self.fix is not None:
                yield Static("\nrecovery command:", markup=False)
                yield Static(self.fix or "(none)", id="fix", markup=False)
        yield Footer()


def key_parts(key: str) -> tuple[str, str]:
    """(host, bot) of an alerts key: `host|-` is the host itself, `host|project|-` a project with no bot known."""
    parts = txt(key).split("|")
    return parts[0], (parts[-1] if len(parts) > 2 else DASH)


def kind(a: dict, opened: bool = False) -> tuple[str, str]:
    """An alerts record's kind as symbol + word, and its colour. A host's is dim in History; open (posted and not
    recovered: a server down, a blind host) it is a problem like a bot's."""
    if a.get("kind") == "recovery":
        return "✓ recovered", OK
    if a.get("kind") == "recover":   # 1.19.0: the monitor ran bot recover --yes; its detail is "exit <status>"
        return ("↻ recover", WARN) if a.get("detail") == "exit 0" else ("↻ recover failed", ALERT)
    if txt(a.get("key")).count("|") == 1:
        return "○ host", ALERT if opened else DIM
    return ("✕ down", ALERT) if rank(a.get("verdict")) == 0 else ("▲ check", WARN)


def posted_text(a: dict) -> str:
    """The text of an alerts record's post, or why there is none."""
    a = obj(a)
    if a.get("status") == "not_posted":
        return "(not posted: a warning only, or still inside its hold time)"
    return txt(a.get("text")) or "(the posted text is no longer kept)"   # out of the 100 records, or a monitor older than 1.11.0 posted it


def rule(name: str, count: int | None, note: str, width: int) -> Text:
    """A rule heading: the name in brand, a dim count, a rule to the edge, a dim note on the right."""
    left = Text.assemble((name, f"bold {BRAND}"), (f" {count}" if count is not None else "", DIM), " ")
    right = Text.assemble(" ", (note, DIM)) if note else Text()
    return Text.assemble(left, ("─" * max(0, width - left.cell_len - right.cell_len), TAB), right)


def alerts_items(state: dict, width: int, now: float) -> list[tuple]:
    """The Alerts tab: Open (posted, not recovered) and History (the alerts records of the last 24 h, newest first)."""
    wide = width >= WIDE
    cols = [("when", 13), ("", 13), ("bot", 22 if wide else 14)] + ([("host", 10)] if wide else []) + [("what", 0), ("post", 16)]
    cols[-2] = ("what", max(10, width - 2 - sum(w for _, w in cols) - len(cols) + 1))

    def row(a: dict, bold: bool) -> list[Text]:
        t, (host, bot) = epoch(a.get("ts")), key_parts(a.get("key"))
        word, style = kind(a, bold)
        post = ("✓ sent on retry", WARN) if a.get("retried") else ("✓ sent", OK) if a.get("status") == "sent" else ("— not posted", DIM)
        cell = {"when": [(f"{hhmm(t)} · {ago(a.get('ts'), now) or DASH}", "" if bold else DIM)],
                "": [(f" {word.upper()} " if bold else word, f"bold #000000 on {ALERT}" if bold and style == ALERT else style)],
                "bot": [(bot, "bold" if bold else "")], "host": [(host_label(state, host), DIM)], "what": [(a.get("detail") or DASH, "")], "post": [post]}
        return row_lines([(cell[n], w) for n, w in cols])

    head = (None, row_lines([([(n, f"bold {DIM}")], w) for n, w in cols]))
    opened = open_alerts(state)
    # A failed POST is retried next pass (the red bar says so); only what went out, or was never due to, is history.
    hist = [(i, a) for i, a in reversed(list(enumerate(seq(state.get("alerts"))))) if isinstance(a, dict) and a.get("status") != "failed"
            and now - (epoch(a.get("ts")) or 0) < 86400]
    items: list[tuple] = [(None, [rule("Open", len(opened), "posted and not recovered yet", width), Text()]), head]
    items += [(f"open {a['key']}", row(a, True)) for a in opened]
    items += [(None, [Text(), rule("History", len(hist), "last 24 h · newest first · #bot-health-check", width), Text()]), head]
    items += [(f"hist {i}", row(a, False)) for i, a in hist]
    return items


def reach_of(h: dict) -> tuple[str, str]:
    """Whether the last pass reached a host: symbol + word, and its colour."""
    v = txt(obj(h).get("verdict"))
    return ("● ok", OK) if v == "ok" else ("○ unreachable", DIM) if v == "hostdown" else (f"▲ {v or '?'}", WARN)


def last_check(h, now: float) -> Text:
    """The host popup's `last check`: the reach, for how long when it is not ok, the monitor's reason, and when it was
    checked. A host the state does not have yet (added since the last pass) says so."""
    if not isinstance(h, dict):
        return Text("not checked yet: the monitor meets it at its next pass", DIM)
    word, style = reach_of(h)
    since, checked, detail = ago(h.get("since"), now), ago(h.get("checked"), now), txt(h.get("detail"))
    return Text.assemble((word + (f" {since}" if since and h.get("verdict") != "ok" else ""), style), "   " + detail if detail else "",
                         ("   checked just now" if checked == "now" else f"   checked {checked} ago" if checked else "", DIM))


def config_items(state: dict, names: dict, width: int) -> list[tuple]:
    """The Configuration tab: the ledger's hosts as the last pass saw them, and the monitor's settings."""
    wide = width >= WIDE
    cols = ([("host", 12), ("ssh target", 0), ("kind", 7)] + ([("env", 16)] if wide else []) + [("reach", 14)]
            + ([("claude-discord", 15)] if wide else []) + [("bots", 4)])
    cols[1] = ("ssh target", max(10, width - 2 - sum(w for _, w in cols) - len(cols) + 1))
    bots, m, mgr = obj(state.get("bots")), obj(state.get("monitor")), txt(state.get("manager")) or "?"
    hosts = sorted(obj(state.get("hosts")).items(), key=lambda kh: (kh[0] != "local", kh[0]))   # this machine first
    add = Text.assemble((" + Add host ", f"bold #000000 on {BRAND}"), ("    a · x remove (asks) · l laptop on/off · enter settings", DIM))
    items: list[tuple] = [(None, [rule("Hosts", len(hosts), "", width), Text(), add, Text()]), (None, row_lines([([(n, f"bold {DIM}")], w) for n, w in cols]))]
    for key, h in hosts:
        h = obj(h)
        name, env, reach = txt(h.get("hostname")), ids(h.get("env")), reach_of(h)
        if key == "local":
            target = "this machine (local" + (f" name={h['display']}" if txt(h.get("display")) else "") + ")"
        else:
            target = key + (f" ({name})" if name and name != key else "")
        if h.get("left_s") is not None:   # out of the ledger, kept for a day so a brief removal does not post again
            target += " (left the ledger)"
        up = h.get("reach") == "ok"
        cell = {"host": [(host_label(state, key), "bold")], "ssh target": [(target, DIM)], "kind": [("laptop" if h.get("laptop") else "server", DIM)],
                "env": [(" ".join(env) or DASH, WARN if env else DIM)], "reach": [reach],
                "claude-discord": [((txt(h.get("version")).split(" ")[0] if up else "") or DASH, "")],
                "bots": [(str(sum(1 for b in bots.values() if obj(b).get("host") == key and txt(obj(b).get("bot")))) if up else DASH, "")]}
        items.append((key, row_lines([(cell[n], w) for n, w in cols])))
    # The monitor mentions an owner id only when it is all digits (its `owner`): any other value mentions nobody.
    owner = m.get("owner_id")
    who = "nobody" if owner == "" else "@" + names.get(owner, owner) if isinstance(owner, str) and owner.isascii() and owner.isdigit() else DASH
    keeper = any(obj(h).get("kind") == "keeper" for h in seq(m.get("holders")))
    rows = [("alert language", txt(m.get("lang")) or DASH, [("ALERT_LANG in config.env", DIM)]),
            ("mention on alert", who, [("DISCORD_USER_ID in config.env", DIM)]),
            ("check every", "5 min", [("fixed", DIM)]), ("alert channel", "#bot-health-check", [("fixed", DIM)]),
            ("kept running by", "keeper" if keeper else "nothing", [("stop: ", DIM), (f"claude-discord monitor --stop {mgr}", BRAND)])]
    items.append((None, [Text(), rule("Monitor", None, "config.env values change with setup; fixed ones do not", width), Text()]
                  + [Text.assemble((fit(label, 18), DIM), value, "   ", *note) for label, value, note in rows]))
    return items


# ---- ~/.ssh/config, read as text ---------------------------------------------
# The add-host picker lists the Host aliases of ~/.ssh/config and of the files it Includes. They are read here as text
# and never through `ssh -G`: that evaluates the configuration, and a `Match exec` line runs a command, once per alias
# asked about. `ssh -G` runs for the one alias the user chose. A configuration is the user's own file, but nothing in
# it may hang or crash the picker: a bound on the files, on the bytes read of each, on the depth of Includes, on the
# blocks and on the candidates; each file once (a cycle of Includes ends there); only a regular file is opened (a FIFO
# would block); an Include with a wildcard in more than three components of its path is skipped (a glob walks every
# directory those match before it yields a file). It is read in a worker thread all the same: never on the event loop.
ALIAS = re.compile(r"[A-Za-z0-9._@][A-Za-z0-9._@-]{0,254}")   # what `claude-discord hosts add` takes as an ssh alias
SSH_MAX_FILES, SSH_MAX_BYTES, SSH_MAX_DEPTH, SSH_MAX_BLOCKS, SSH_MAX_HOSTS, SSH_MAX_WILD = 32, 1 << 18, 8, 2000, 500, 3


def ssh_blocks(path: Path, home: Path, depth: int = 0, seen: set | None = None) -> list[tuple]:
    """The Host blocks of an ssh configuration file in file order, as (patterns, {option: its first value}), with the
    blocks of each Include where it stands. The options above the first Host line are a block for `*`. A Match block is
    (None, {}): never evaluated, so nothing in it counts, an Include neither."""
    seen = set() if seen is None else seen
    try:
        real = path.resolve()
        if depth > SSH_MAX_DEPTH or real in seen or len(seen) >= SSH_MAX_FILES or not real.is_file():
            return []
        seen.add(real)
        with open(real, "rb") as f:
            text = f.read(SSH_MAX_BYTES).decode("utf-8", "replace")
    except (OSError, RuntimeError):   # RuntimeError: a loop of symlinks, before Python 3.13
        return []
    cur = (["*"], {})
    blocks = [cur]
    for line in text.splitlines():
        m = re.match(r"\s*([A-Za-z]+)\s*(?:=\s*|\s+)(.*)$", line)
        if not m:
            continue
        key, words = m.group(1).lower(), []
        for quoted, bare in re.findall(r'"([^"]*)"|(\S+)', m.group(2)):
            if bare.startswith("#"):
                break
            words.append(quoted or bare)
        if key in ("host", "match"):
            cur = (words if key == "host" else None, {})
            blocks.append(cur)
        elif cur[0] is None:
            continue
        elif key == "include":
            for w in words:
                pattern = str(home / w[2:]) if w.startswith("~/") else w if w.startswith("/") else str(home / ".ssh" / w)
                if sum(1 for part in pattern.split("/") if any(c in part for c in "*?[")) > SSH_MAX_WILD:
                    continue
                for p in sorted(islice(glob.iglob(pattern), SSH_MAX_FILES)):
                    blocks += ssh_blocks(Path(p), home, depth + 1, seen)
        elif key in ("hostname", "user", "port", "proxyjump") and words:
            cur[1].setdefault(key, words[0])
    return blocks


def ssh_hosts(home: Path) -> list[dict]:
    """The picker's candidates: every Host pattern of ~/.ssh/config and its Includes that is a plain alias (no `*`, `?`
    or `!`, and one `hosts add` would take), once, in file order, with what the text says of it: `hostname`, `user`,
    `port`, `proxyjump`, each the first value among the blocks whose patterns match the alias, as ssh takes them.
    Every string is cleaned: it is drawn."""
    blocks = [b for b in ssh_blocks(home / ".ssh" / "config", home) if b[0] is not None][:SSH_MAX_BLOCKS]
    # ssh's patterns are `*` and `?` only, and fnmatch takes no exponential time over many `*`. A `[` is a set to fnmatch
    # and a plain character to ssh, where it matches no alias (none holds one): such a pattern is dropped.
    hit = lambda alias, pats: any(fnmatch.fnmatchcase(alias, p) for p in pats)
    matchers = [([p for p in pats if p[:1] != "!" and "[" not in p], [p[1:] for p in pats if p[:1] == "!" and "[" not in p], opts) for pats, opts in blocks]
    hosts: dict = {}
    for pats, _ in blocks:
        for alias in pats:
            if alias in hosts or len(hosts) >= SSH_MAX_HOSTS or not ALIAS.fullmatch(alias):
                continue
            h = {"alias": alias}
            for yes, no, opts in matchers:
                if hit(alias, yes) and not hit(alias, no):
                    for k, v in opts.items():
                        h.setdefault(k, clean(v))
            hosts[alias] = h
    return list(hosts.values())


def ssh_target(h: dict) -> str:
    """`user@hostname:port · via <ProxyJump>` as the configuration's text gives them: the alias for no HostName, 22
    for no Port, no user and no `via` when it names none."""
    h = obj(h)
    user, jump = txt(h.get("user")), txt(h.get("proxyjump"))
    return (f"{user}@" if user else "") + (txt(h.get("hostname")) or txt(h.get("alias"))) + ":" + (txt(h.get("port")) or "22") + (f" · via {jump}" if jump else "")


def fuzzy(query: str, hosts: list[dict]) -> list[dict]:
    """The hosts a search finds, best first: an alias that starts with the query, one that holds it, one that holds its
    characters in order, then a host whose target holds it; file order within each, and for no query at all."""
    q = query.lower()

    def score(h: dict) -> int | None:
        a = h["alias"].lower()
        if a.startswith(q):
            return 0
        if q in a:
            return 1
        rest = iter(a)
        return 2 if all(c in rest for c in q) else 3 if q in ssh_target(h).lower() else None

    return [h for s, h in sorted(((score(h), h) for h in hosts), key=lambda sh: 9 if sh[0] is None else sh[0]) if s is not None]


def run_capped(argv: list, cap: float, feed=None, limit: int = 65536) -> tuple[int, str, str]:
    """A command run to its end, or to `cap` seconds, when its whole process group is killed (a child of it that hangs
    would otherwise keep the pipes open and this call with them): (exit status, stdout, stderr). 124 for the cap, 127
    when it cannot be started. Each stream is cut at `limit` bytes (64 KiB) and cleaned of what must not be drawn; its line breaks
    stay. `feed` is how a value travels to the command: never in its argument list, and here never in a variable
    either (Textual prints the locals of every frame of a traceback): the command's stdin is `feed.sending`, read
    where it is written to the pipe."""
    try:
        p = subprocess.Popen(argv, stdin=subprocess.DEVNULL if feed is None else subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, start_new_session=True)
    except OSError as e:
        return 127, "", f"cannot run {argv[0]}: {e.strerror or e}"
    try:
        out, err = p.communicate(None if feed is None else feed.sending.encode(), timeout=cap)
        rc = p.returncode
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
        out, err = p.communicate()
        rc, err = 124, err + f"\nno answer within {cap:g} s".encode()
    return (rc, *(clean(b[:limit].decode("utf-8", "replace"), UNSAFE_NL).strip() for b in (out, err)))


def ssh_effective(ssh: str, alias: str) -> list[str]:
    """`ssh -G -- <alias>`: what ssh itself will use for the ONE alias the user chose, the lines that say where a
    connection goes and through what. Never run for a candidate while searching: evaluating the configuration can run
    a `Match exec` command, which is also why it gets 5 s and no more."""
    rc, out, err = run_capped([ssh, "-G", "--", alias], 5)
    lines = [l for l in out.splitlines() if l.split(" ", 1)[0] in ("hostname", "user", "port", "proxyjump", "proxycommand")]
    return lines or [f"nothing (exit {rc}" + (f": {err.splitlines()[-1]})" if err else ")")]


HELD = "adding … (cannot be cancelled once started)"


def radio(laptop: bool) -> list[tuple]:
    """A host's kind as a radio pair, drawn `(●) server   ( ) laptop`."""
    return [(f"{'(●)' if on else '( )'} {word}", "bold" if on else "") for word, on in (("server", not laptop), ("laptop", laptop))]


class Query(Input):
    """The picker's search field. At the step that shows the check `l` is not its letter but the kind's key: a key the
    focused field would take is no binding of the screen around it, so the field says it does not take this one."""

    def check_consume_key(self, key: str, character: str | None) -> bool:
        return not (key == "l" and self.screen.step == "shown") and super().check_consume_key(key, character)


class AddHost(ModalScreen):
    """`a` on the Configuration tab: a search over the Host aliases of ~/.ssh/config (ssh_hosts, read in a worker
    thread), or an alias typed in. Enter on a candidate shows the check `hosts add` runs first and what it writes on
    that machine (the lines its --dry-run prints), what `ssh -G` says of that one alias, and the kind it is added as
    (server; `l` switches to laptop and back). A second Enter runs `hosts add`; after a host that did not answer
    (exit 5) a third adds it unchecked. Every call runs in a worker thread, so a probe that takes its whole cap leaves
    the screen alive; once `hosts add` runs it cannot be called back (it writes on the host and in the ledger), so
    Escape and q wait for its outcome. Dismissed with what there is to say, or None."""
    CSS = f"""AddHost {{ align: center middle; }}
    #add {{ width: 104; max-width: 96%; height: auto; border: round {BRAND}; padding: 1 2; }}
    #cands {{ height: auto; margin: 1 0; }} #info {{ height: auto; }}"""
    # l and q are text in the search field: l is the kind's key only at the step that shows it (Query; priority: before
    # the field gets the key), q only while an add runs (the field is disabled then; otherwise the app's q quits).
    BINDINGS = [Binding("escape", "cancel", "cancel"), Binding("up", "move(-1)"), Binding("down", "move(1)"),
                Binding("l", "kind", priority=True), Binding("q", "held")]
    ROWS = 8   # candidates drawn at once

    def __init__(self, listed: set) -> None:
        super().__init__()
        self.hosts: list[dict] | None = None      # the candidates of ~/.ssh/config; None until they are read
        self.listed = listed                      # the aliases the last pass checked
        self.found: list[dict] = []
        self.at = 0
        self.step, self.alias = "search", ""      # search -> shown -> (running) -> failed; the alias the last Enter chose
        self.adding = False                       # a `hosts add` runs: no way out until it ends
        self.laptop, self.shown = False, ""       # the kind to add it as; what the first Enter showed

    def compose(self) -> ComposeResult:
        with Vertical(id="add"):
            yield Static(Text.assemble(("Add a host", f"bold {BRAND}"), ("    from ~/.ssh/config and its Includes", DIM)))
            yield Query(placeholder="search, or type an ssh alias", id="q")
            yield Static("", id="cands")
            yield Static("", id="info", markup=False)

    def on_mount(self) -> None:
        self.query_one("#q", Input).focus()
        self.search("")
        home = self.app.home
        self.run_worker(lambda: self.app.call_from_thread(self.read, ssh_hosts(home)), thread=True)

    def read(self, hosts: list[dict]) -> None:
        self.hosts = hosts
        if self.is_attached and self.step == "search":   # an alias typed and entered meanwhile keeps its step
            self.search(self.query_one("#q", Input).value.strip())

    def say(self, text: str | Text, style: str = DIM) -> None:
        self.query_one("#info", Static).update(Text(text, style) if isinstance(text, str) else text)

    def search(self, query: str) -> None:
        self.step, self.at, self.laptop = "search", 0, False
        self.found = fuzzy(query, self.hosts or [])
        if ALIAS.fullmatch(query) and all(h["alias"] != query for h in self.found):   # an alias the configuration does not name
            self.found.append({"alias": query, "typed": True})
        self.say("enter shows the check that runs first · esc cancel" if self.found else "reading ~/.ssh/config …" if self.hosts is None else
                 "no Host alias here: type the ssh alias to add (letters, digits and . _ @ - only, not starting with -)")
        self.paint()

    def paint(self) -> None:
        n = sum(1 for h in self.found if not h.get("typed"))   # the alias as typed is the last row, and no match
        top = max(0, min(self.at - self.ROWS // 2, len(self.found) - self.ROWS))
        w = min(28, max([8] + [cell_len(h["alias"]) for h in self.found]))
        lines = [Text("reading ~/.ssh/config …" if self.hosts is None else f"{n} match{'' if n == 1 else 'es'}", DIM)]
        for i, h in list(enumerate(self.found))[top:top + self.ROWS]:
            note = "as typed: not in ~/.ssh/config" if h.get("typed") else ssh_target(h)
            line = Text.assemble("▸ " if i == self.at else "  ", (fit(h["alias"], w), "bold"), "  ",
                                 (note + ("   already checked" if h["alias"] in self.listed else ""), DIM))
            if i == self.at:
                line.stylize(f"on {CURSOR}")
            lines.append(line)
        self.query_one("#cands", Static).update(Text("\n").join(lines))

    def on_input_changed(self, event: Input.Changed) -> None:
        self.search(event.value.strip())   # an edited query is a new search: the next Enter shows, it never adds

    def action_move(self, d: int) -> None:
        if self.step == "search" and self.found:
            self.at = max(0, min(len(self.found) - 1, self.at + d))
            self.paint()

    def check_action(self, action: str, parameters: tuple) -> bool | None:
        return self.step == "shown" if action == "kind" else self.adding if action == "held" else True

    def action_kind(self) -> None:
        self.laptop = not self.laptop
        self.show()

    def action_held(self) -> None:
        self.say(HELD, WARN)

    def action_cancel(self) -> None:
        if self.adding:
            self.action_held()
        else:
            self.dismiss(None)

    def show(self) -> None:
        """The step before the add: what will run and what it writes, and the kind, which `l` switches."""
        pair = radio(self.laptop)
        self.say(Text.assemble(self.shown, "\nadded as:  ", pair[0], "   ", pair[1], ("    l switches; a laptop that is off is not alerted", DIM),
                               "\nrefused if it is the same home as a listed host; warns if another manager watches it.   enter adds · esc cancel"))

    def on_input_submitted(self, event: Input.Submitted) -> None:
        cli, ssh, alias, kind = self.app.hosts_cli, self.app.ssh, self.alias, ["laptop"] if self.laptop else []
        if self.step == "search" and self.found:
            alias = self.alias = self.found[self.at]["alias"]
            self.run("shown", f"asking what would run for {alias} ...", lambda: (cli("add", "--dry-run", alias), ssh_effective(ssh, alias)))
        elif self.step == "shown":
            self.run("added", f"checking {alias} ...", lambda: (cli("add", alias, *kind), None))
        elif self.step == "failed":
            self.run("added", f"adding {alias} unchecked ...", lambda: (cli("add", "--no-probe", alias, *kind), None))

    def run(self, then: str, saying: str, call) -> None:
        """`call` in a worker thread, its result to `ran` on the event loop; no key does anything meanwhile but escape,
        and that only before an add."""
        self.step, self.adding = "running", then == "added"
        self.say(saying)
        self.query_one("#q", Input).disabled = True
        self.app.run_worker(lambda: self.app.call_from_thread(self.ran, then, *call()), thread=True)

    def ran(self, then: str, answer: tuple, effective: list | None) -> None:
        if not self.is_attached:   # escape meanwhile
            return
        self.adding = False
        rc, out, err = answer
        q = self.query_one("#q", Input)
        q.disabled = False
        q.focus()
        if then == "shown" and rc == 0:
            self.step, self.shown = "shown", f"enter checks it first:  {out}\nssh -G {self.alias} says:  {' · '.join(effective or [])}"
            self.show()
        elif then == "added" and rc == 0:
            self.dismiss("\n".join(x for x in (out, err) if x))
        elif then == "added" and rc == 5:   # it did not answer, or has no claude-discord: the CLI named --no-probe
            self.step = "failed"
            self.say(f"{err}\nenter adds it unchecked (hosts add --no-probe) · esc cancel", WARN)
        else:
            self.step = "search"
            self.say(err or f"claude-discord hosts exited {rc}", ALERT)


class Kind(Static, can_focus=True):
    """The host popup's kind, a radio pair drawn `( ) server   (●) laptop`: space or an arrow flips it while it has the focus."""
    BINDINGS = [Binding("space", "flip"), Binding("left", "flip"), Binding("right", "flip")]
    laptop = False

    def paint(self) -> None:
        pair = radio(self.laptop)
        self.update(Text.assemble((fit("kind", 16), DIM), pair[0], "   ", pair[1], ("    a laptop that is off is not alerted", DIM)))

    def action_flip(self) -> None:
        self.laptop = not self.laptop
        self.paint()
        self.screen.changed()


ENV_KEY = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
ASKED = "asked · the monitor checks within a minute"


class Value(Input):
    """The host popup's value field. A paste that starts or ends with white space (a copied line's indent) is refused
    out loud: the field takes no white space, and would drop the whole paste without a word."""

    def on_paste(self, event: Paste) -> None:
        line = (event.text.splitlines() or [""])[0]
        if line != line.strip():
            event.prevent_default()   # not Input's own handler
            event.stop()
            self.screen.say("a value cannot start or end with a space", ALERT)


class HostEdit(ModalScreen):
    """Enter on a host row of the Configuration tab: that host's line of the ledger. What can be changed: its display
    name, its kind and its env words. The ledger is read through `hosts list --json` (key names only: this program
    never sees a value) and changed through `hosts set <alias> --stdin`: Save sends every change in that one call, a
    new value on stdin and in no argument list. A value is typed masked and is never drawn: an env word shows `••••`
    whatever it holds, and to change one is to type a new one. Only what was entered (Enter in the value field) is
    sent: with text left in the KEY or value field Save does nothing and says so. Dismissed with what there is to say,
    or None."""
    CSS = f"""HostEdit {{ align: center middle; }}
    #host {{ width: 112; max-width: 96%; height: auto; border: round {BRAND}; padding: 1 2; }}
    #host Horizontal {{ height: 1; }} #host .lab {{ width: 16; color: $text-muted; }} #host .hint {{ width: auto; padding-left: 2; color: $text-muted; }}
    #h-name {{ width: 26; }} #h-key {{ width: 22; }} #h-value {{ width: 34; }} #h-eq {{ width: 3; }}
    #h-buttons {{ margin-top: 1; }} #host Button {{ margin-right: 2; }} Kind:focus {{ background: {CURSOR}; }}"""
    BINDINGS = [Binding("escape", "close", "close")]

    def __init__(self, alias: str, hostname: str) -> None:
        super().__init__()
        self.alias, self.hostname = alias, hostname   # the hostname the last pass saw, or none
        self.was: tuple | None = None   # (display name, laptop, env key names) as the ledger has them; None until it is read
        self.staged: dict = {}          # env key -> its new value ("" removes the key): sent by Save, drawn nowhere
        self.sending = ""               # the stdin of the `hosts set` that runs (run, call): held here and nowhere else

    def compose(self) -> ComposeResult:
        with Vertical(id="host"):
            yield Static("", id="h-title")
            yield Static(Text.assemble((fit("ssh alias", 16), DIM), (self.alias, "bold")))
            yield Static(Text.assemble((fit("target", 16), DIM), "this machine" if self.alias == "local" else ("reading ~/.ssh/config …", DIM)), id="h-target")
            with Horizontal():
                yield Static("display name", classes="lab")
                yield Input(id="h-name", restrict=r"[^\s'\"]*", max_length=40, compact=True, disabled=True, select_on_focus=False)   # the first key adds to the name
                yield Static("shown instead of the hostname", classes="hint")
            yield Kind(id="h-kind", disabled=True)
            yield Static("", id="h-env")
            with Horizontal():
                yield Static("", classes="lab")
                yield Input(id="h-key", placeholder="KEY", restrict=r"[A-Za-z_][A-Za-z0-9_]*", max_length=64, compact=True, disabled=True)
                yield Static(" = ", id="h-eq")
                yield Value(id="h-value", placeholder="a new value; none removes KEY", password=True, restrict=r"[^\s'\"]*", max_length=1024, compact=True, disabled=True)
                yield Static("enter", classes="hint")
            yield Static("", id="h-last")
            yield Static("", id="h-fix", markup=False)
            with Horizontal(id="h-buttons"):
                yield Btn("Check now", id="h-check", compact=True)
                yield Btn("Save", id="h-save", compact=True, disabled=True)
                yield Btn("Stop monitoring this host", id="h-stop", variant="error", compact=True, disabled=True)
                yield Static("asks first; its bots leave the list", classes="hint")
            yield Static("reading the ledger ...", id="h-msg", markup=False)

    def on_mount(self) -> None:
        self.paint_last()
        self.set_interval(2, self.paint_last)   # the app re-reads state.json every 2 s: a pass that ends shows here
        self.run(("list", "--json"), "reading the ledger ...", self.loaded)
        if self.alias != "local":
            home = self.app.home
            self.run_worker(lambda: self.app.call_from_thread(self.targeted, ssh_hosts(home)), thread=True)

    def targeted(self, hosts: list[dict]) -> None:
        """Where the alias goes, as ~/.ssh/config's text has it (read in a worker thread), and the hostname it answered with."""
        if self.is_attached:
            named = next((h for h in hosts if h["alias"] == self.alias), {"alias": self.alias})
            suffix = f" ({self.hostname})" if self.hostname and self.hostname != self.alias else ""
            self.query_one("#h-target", Static).update(Text.assemble((fit("target", 16), DIM), ssh_target(named) + suffix))

    def say(self, text: str, style: str = DIM) -> None:
        self.query_one("#h-msg", Static).update(Text(text, style))

    def paint_last(self) -> None:
        h = obj(self.app.state.get("hosts")).get(self.alias)
        self.query_one("#h-last", Static).update(Text.assemble((fit("last check", 16), DIM), last_check(h, time.time())))
        self.query_one("#h-fix", Static).update(" " * 16 + txt(obj(h).get("fix")) if txt(obj(h).get("fix")) else "")
        self.query_one("#h-check", Button).label = ASKED if self.app.asked_lately() else "Check now"

    def run(self, args: tuple, saying: str, then, sends: bool = False) -> None:
        """A hosts CLI call in a worker thread, its answer to `then` on the event loop; Save and Stop wait meanwhile.
        With `sends` its stdin is self.sending."""
        self.say(saying)
        for b in self.query("#h-save, #h-stop"):
            b.disabled = True
        self.app.run_worker(lambda: self.app.call_from_thread(then, self.call(args, sends)), thread=True)

    def call(self, args: tuple, sends: bool) -> tuple:
        """The call itself (in the worker thread). Whatever it raises becomes a short note with the exception's class
        and nothing else: its message and the locals of its frames may hold the text sent, and an exception that left
        a worker would be printed with both. The text travels in self.sending only, emptied here whatever happened."""
        try:
            return self.app.hosts_cli(*args, feed=self if sends else None)
        except Exception as e:
            return 1, "", f"could not run hosts {args[0]}: {type(e).__name__}"
        finally:
            if sends:
                self.sending = ""

    def loaded(self, answer: tuple) -> None:
        """The ledger's line(s) for this alias, from `hosts list --json`. Its text is another program's output: parsed
        as JSON, cleaned, and every field read through txt/obj/seq, so a wrong shape is a refusal to edit, never a crash."""
        if not self.is_attached:
            return
        rc, out, err = answer
        try:
            doc = clean(json.loads(out)) if rc == 0 else None
        except ValueError:
            doc = None
        rows = [h for h in seq(obj(doc).get("hosts")) if isinstance(h, dict) and h.get("alias") == self.alias]
        if not rows:
            self.query_one("#h-check", Button).disabled = False   # the monitor can be asked whatever the ledger's reading said
            return self.say(err or (f"{self.alias} is not in the ledger" if isinstance(doc, dict) else f"claude-discord hosts list gave no ledger (exit {rc})"), ALERT)
        keys = list(dict.fromkeys(k for h in rows for k in ids(h.get("env"))))   # two lines for one alias: every key of both
        self.was = (txt(rows[0].get("name")), rows[0].get("laptop") is True, keys)
        self.query_one(Kind).laptop = self.was[1]
        for w in list(self.query(Input)) + list(self.query(Button)) + [self.query_one(Kind)]:
            w.disabled = w.id == "h-stop" and self.alias == "local"   # local is this machine: it stays
        name = self.query_one("#h-name", Input)
        name.value = self.was[0]
        name.focus()
        self.query_one(Kind).paint()
        self.changed()
        self.say("tab moves · enter in the value field stages an env change · Save writes them all · esc closes without saving")

    def typed(self) -> bool:
        """Text stands in the KEY or the value field: typed and not entered, so not staged."""
        return bool(self.query_one("#h-key", Input).value or self.query_one("#h-value", Input).value)

    def dirty(self) -> bool:
        return self.was is not None and (self.query_one("#h-name", Input).value != self.was[0] or self.query_one(Kind).laptop != self.was[1]
                                         or bool(self.staged) or self.typed())

    def changed(self) -> None:
        """The title (unsaved changes are said there) and the env line: each key masked, and what Save will do to it."""
        if self.was is None:
            return
        self.query_one("#h-title", Static).update(Text.assemble(("Host", f"bold {BRAND}"), (" · ", DIM), (self.alias, f"bold {BRAND}"),
                                                                ("    ● unsaved changes", WARN) if self.dirty() else ""))
        env = Text(fit("env", 16), DIM)
        for k in self.was[2] + [k for k in self.staged if k not in self.was[2]]:
            new = self.staged.get(k)
            env.append_text(Text.assemble((k, "" if new != "" else DIM), (" ••••" if new != "" else "", DIM),
                                          (" (removed on save)" if new == "" else " (changed)" if new is not None and k in self.was[2] else " (new)" if new is not None else "", WARN), "   "))
        if not self.was[2] and not self.staged:
            env.append("none", DIM)
        self.query_one("#h-env", Static).update(env)

    def on_input_changed(self, event: Input.Changed) -> None:
        self.changed()

    def on_input_submitted(self, event: Input.Submitted) -> None:
        if event.input.id == "h-value":
            self.stage()
        else:
            self.focus_next()

    def stage(self) -> None:
        """KEY and its new value (none: remove KEY) from the two fields into `staged`; the fields are emptied. KEY is
        an env name and nothing else: `name` and `laptop` are the line's own words, with a field each above, and a
        value typed here (masked) under `name` would be drawn as the host's display name."""
        key, value = self.query_one("#h-key", Input), self.query_one("#h-value", Input)
        if not self.typed():
            return
        if not ENV_KEY.fullmatch(key.value) or key.value.lower() in ("name", "laptop"):
            return self.say("not an env name", ALERT)
        if value.value or key.value in self.was[2]:
            self.staged[key.value] = value.value
        else:   # no value for a key the line does not have: nothing to remove
            self.staged.pop(key.value, None)
        key.value = value.value = ""
        key.focus()
        self.changed()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "h-check":
            # Not a probe of its own: the one monitor is asked for a pass now (monitor --check), so there is still one
            # writer of the state and one poster. The line above repaints from the state when that pass ends.
            # A press within 10 s of the last request (this button's, or the one after a change) does nothing: the
            # button says it was asked.
            if self.app.asked_lately():
                return
            self.say("asking the monitor ...")
            ask = self.app.ask_pass
            self.run_worker(lambda: self.app.call_from_thread(self.asked, ask()), thread=True)
        elif event.button.id == "h-save":
            if self.typed():   # never sent unentered: a KEY alone would remove that word, a value alone is nobody's
                return self.say("press enter in the value field to stage KEY, or clear it", ALERT)
            name, laptop = self.query_one("#h-name", Input).value, self.query_one(Kind).laptop
            self.sending = "".join(line + "\n" for line in ([f"name={name}"] if name != self.was[0] else [])
                                   + ([f"laptop {'on' if laptop else 'off'}"] if laptop != self.was[1] else []) + [f"{k}={v}" for k, v in self.staged.items()])
            if not self.sending:
                return self.say("nothing to save")
            self.run(("set", self.alias, "--stdin"), f"saving {self.alias} ...", self.ran, sends=True)
        elif event.button.id == "h-stop":
            self.app.push_screen(Confirm(f"Stop monitoring {self.alias}? Its line leaves the ledger of {self.app.bot}; its bots leave the list (the monitor "
                                         "keeps them a day as 'left the ledger'). Nothing is stopped on the host itself."),
                                 lambda yes: self.run(("rm", self.alias), f"removing {self.alias} ...", self.ran) if yes else None)

    def asked(self, text: str) -> None:
        if self.is_attached:
            self.say(text)
            self.paint_last()

    def ran(self, answer: tuple) -> None:
        if not self.is_attached:
            return
        rc, out, err = answer
        if rc == 0:
            return self.dismiss("\n".join(x for x in (out, err) if x))
        for b in self.query("#h-save, #h-stop"):
            b.disabled = b.id == "h-stop" and self.alias == "local"
        self.say(err or f"claude-discord hosts exited {rc}", ALERT)

    def action_close(self) -> None:
        if self.dirty():
            self.app.push_screen(Confirm(f"Close without saving the changes to {self.alias}?"), lambda yes: self.dismiss(None) if yes else None)
        else:
            self.dismiss(None)


# ---- access: who may drive a bot (1.13.0) -----------------------------------
# `e` on a bot row. What the editor shows comes from `claude-discord access ... <bot> --json`, run on the bot's own
# machine (the token never leaves it); what it changes goes back as change words to `claude-discord access ... <bot>
# set`, which shows the changes on the terminal, asks, and writes. This program never reads or writes access.json.
MODES = ("none", "dev-manager", "autoresearchclaw")
DMS = ("allowlist", "off", "pairing")
DIGITS = re.compile(r"[0-9]{1,20}")


def access_model(doc: dict) -> dict:
    """What the editor changes, from the document's policy and mode: {"groups": {channel id: {"mention": bool, "allow":
    [user ids]}} in the document's order, "dm": allowlist | off | pairing | disabled, "dm_allow": [user ids], "mode"}.
    `off` is an allowlist with nobody on it (the plugin's own `disabled` drops every message, in the channels too). A
    value of the wrong type reads as missing; an id that is not digits is none."""
    pol = obj(obj(doc).get("policy"))
    digits = lambda v: [i for i in ids(v) if DIGITS.fullmatch(i)]
    dm, dm_allow = txt(pol.get("dm")), digits(pol.get("dm_allow"))
    return {"groups": {g["id"]: {"mention": g.get("mention") is not False, "allow": digits(g.get("allow"))} for g in groups(pol) if DIGITS.fullmatch(g["id"])},
            "dm": "disabled" if dm == "disabled" else "pairing" if dm != "allowlist" else "allowlist" if dm_allow else "off",
            "dm_allow": dm_allow, "mode": txt(obj(doc).get("mode")) or "none"}


def dm_word(m: dict) -> str:
    """The DM policy as it works: an allowlist with nobody on it is off."""
    return "off" if m["dm"] == "allowlist" and not m["dm_allow"] else m["dm"]


def access_words(was: dict, now: dict, owner: str) -> list[str]:
    """The change words (`claude-discord access <bot> set <word>...`) that turn the model `was` into `now`. A channel
    the CLI adds starts with an @mention required and the owner alone, so a new channel's words are what differs from
    that. Every word is made of an id and fixed text."""
    out = [f"channel-{c}" for c in was["groups"] if c not in now["groups"]]
    for c, g in now["groups"].items():
        old = was["groups"].get(c)
        if old is None:
            out.append(f"channel+{c}")
            old = {"mention": True, "allow": [owner] if owner else []}
        if g["mention"] != old["mention"]:
            out.append(f"mention:{c}={'on' if g['mention'] else 'off'}")
        if not g["allow"]:
            out += [f"allow:{c}=any"] if old["allow"] else []
        else:   # the additions first: a list is never empty on the way
            out += [f"allow:{c}+{u}" for u in g["allow"] if u not in old["allow"]] + [f"allow:{c}-{u}" for u in old["allow"] if u not in g["allow"]]
    a, b = dm_word(was), dm_word(now)
    if b == "off":
        out += ["dm=off"] if a != "off" else []
    else:
        out += [f"dm={b}"] if b != a and b != "disabled" and not (a == "off" and b == "allowlist") else []
        out += [f"dm+{u}" for u in now["dm_allow"] if u not in was["dm_allow"]] + [f"dm-{u}" for u in was["dm_allow"] if u not in now["dm_allow"]]
    return out + ([f"mode={now['mode']}"] if now["mode"] != was["mode"] else [])


def access_wide(was: dict, now: dict) -> set:
    """What of `now` widens who can drive the bot, drawn in the alert colour: `mention:<channel>` (an @mention no longer
    required), `any:<channel>` (anyone may write), `new:<user>` (a person the bot listed nowhere), `dm` (to pairing, or
    back from disabled), `dm:<user>` (added to the DM allowlist). The CLI decides the same on its own and asks about
    each; this is only what the screen shows before."""
    known = {u for g in was["groups"].values() for u in g["allow"]} | set(was["dm_allow"])
    out = set()
    for c, g in now["groups"].items():
        old = was["groups"].get(c)
        if not g["mention"] and (old is None or old["mention"]):
            out.add(f"mention:{c}")
        if not g["allow"] and (old is None or old["allow"]):
            out.add(f"any:{c}")
        if old is None or old["allow"]:
            out |= {f"new:{u}" for u in g["allow"] if u not in known}
    a, b = dm_word(was), dm_word(now)
    if a != b and (b == "pairing" or a == "disabled"):
        out.add("dm")
    return out | ({f"dm:{u}" for u in now["dm_allow"] if u not in was["dm_allow"]} if b != "off" else set())


def access_people(doc: dict, was: dict, now: dict, extra=()) -> list[dict]:
    """The people the right pane lists: everyone on a list of the bot, before or now, and `extra` (the ids typed into
    this editor), so one just added or just taken off stays in sight. Each is {"id", "name", "bot", "tag"}: people
    first, then bots, by name; no name is the id."""
    listed = {u for m in (was, now) for g in m["groups"].values() for u in g["allow"]} | set(was["dm_allow"]) | set(now["dm_allow"]) | set(extra)
    known = {p["id"]: p for p in seq(obj(doc).get("people")) if isinstance(p, dict) and isinstance(p.get("id"), str)}
    owner, peers = txt(obj(doc).get("owner")), ids(obj(doc).get("peers"))
    rows = [{"id": u, "name": txt(known.get(u, {}).get("name")) or u, "bot": known.get(u, {}).get("bot") is True,
             "tag": "owner" if u == owner else "peer bot" if u in peers else "bot" if known.get(u, {}).get("bot") is True else ""} for u in listed]
    return sorted(rows, key=lambda p: (p["bot"], p["name"].lower(), p["id"]))


def find_person(text: str, doc: dict) -> tuple[str | None, str]:
    """A typed name or id as a user id: (id, "") for digits, or for the one person of that name (the whole name, any
    case, first; then the one name it starts; a leading @ is dropped); (None, why) for no one or for several. A name is
    looked up only among the names this machine keeps (`kept`: user-names, peers.json) and those of the people already
    on one of the bot's lists, never among the names only Discord's member list gave: a display name is anyone's to
    choose, and the one picked may get a shell-capable bot."""
    t = text.strip().lstrip("@").lower()
    if DIGITS.fullmatch(t):
        return t, ""
    m = access_model(doc)
    listed = {u for g in m["groups"].values() for u in g["allow"]} | set(m["dm_allow"])
    names = []   # (name, id): a person may be found by two
    for p in seq(obj(doc).get("people")):
        u = txt(obj(p).get("id"))
        if DIGITS.fullmatch(u):
            names += [(n, u) for n in {txt(p.get("kept")), txt(p.get("name")) if u in listed else ""} if n]
    hits = {u: n for n, u in names if n.lower() == t} or {u: n for n, u in names if t and n.lower().startswith(t)}
    if len(hits) == 1:
        return next(iter(hits)), ""
    if not hits:
        return None, "no one of that name is kept here or on the bot's lists: type the numeric user id"
    return None, f"{len(hits)} people match: " + ", ".join(sorted(hits.values())[:5]) + (" …" if len(hits) > 5 else "")


def box(on: bool) -> str:
    return "[✓]" if on else "[ ]"


def radios(options: tuple, on: str, wide: bool = False) -> Text:
    """Radio choices on one line, drawn `(●) a   ( ) b`; the chosen one bold, in the alert colour when it widens."""
    out = Text()
    for o in options:
        out.append(f"{'(●)' if o == on else '( )'} {o}   ", (f"bold {ALERT}" if wide else "bold") if o == on else "")
    return out


def window(n: int, at: int, rows: int) -> range:
    """The `rows` indexes of `n` drawn around the cursor `at`."""
    top = max(0, min(at - rows // 2, n - rows))
    return range(top, min(n, top + rows))


def access_left(doc: dict, was: dict, now: dict) -> list[tuple]:
    """The left list's rows: ("ch", channel id) for each channel of the document, then ("dm", ""), ("mode", "")."""
    return [("ch", c["id"]) for c in seq(obj(doc).get("channels")) if isinstance(c, dict) and DIGITS.fullmatch(txt(c.get("id")))] + [("dm", ""), ("mode", "")]


def access_right(doc: dict, was: dict, now: dict, row: tuple, extra=()) -> list[tuple]:
    """The right list's rows for the left row the cursor is on: for a channel the bot listens in, ("u", user id) for
    each person and ("any", "") last; for the DMs row the people; nothing for a channel it does not listen in or the mode."""
    people = [("u", p["id"]) for p in access_people(doc, was, now, extra)]
    if row[0] == "ch" and row[1] in now["groups"]:
        return people + [("any", "")]
    return people if row[0] == "dm" else []


def access_lines(doc: dict, was: dict, now: dict, at: int, side: str, prow: int, width: int, rows: int = 12, extra=()) -> list[Text]:
    """The editor's body: on the left the server's channels (`[✓]` the bot listens there; its mention rule; `bot cannot
    read` and `?` from the document's `read`); on the right who may write in the channel under the cursor, or who may
    DM; below both the DM policy and the mode as radios. What widens is in the alert colour. `at` is the cursor of
    the left list (the channels, then DMs, then mode), `prow` of the right one, `side` which of the two has the keys;
    `extra` is access_people's."""
    doc = obj(doc)
    left, wide = access_left(doc, was, now), access_wide(was, now)
    chans = {c["id"]: c for c in seq(doc.get("channels")) if isinstance(c, dict) and isinstance(c.get("id"), str)}
    lw = max(34, min(58, width * 11 // 20))
    name = lambda c: "#" + (txt(chans.get(c, {}).get("name")) or c)
    guild = txt(obj(doc.get("guild")).get("name"))
    L = [Text.assemble((fit("  channels" + (f" in {guild}" if guild else ""), lw - 14), f"bold {DIM}"), (fit("@mention", 14), f"bold {DIM}"))]
    nch = len(left) - 2
    for i in window(nch, min(at, nch - 1), rows) if nch else []:
        c = left[i][1]
        g, info = now["groups"].get(c), chans.get(c, {})
        note = ([("main", DIM)] if c == txt(doc.get("main")) else []) + ([(txt(info.get("kind")), DIM)] if info.get("kind") in ("forum", "news") else [])
        note += [("not in this server's list", DIM)] if info.get("kind") == "unknown" else []
        note += [("bot cannot read", WARN)] if info.get("read") is False else [("? not known if readable", DIM)] if info.get("read") is None and info.get("kind") != "unknown" else []
        head = Text.assemble("▸ " if i == at and side == "left" else "  ", (box(g is not None), BRAND if g else DIM), " ", (name(c), "" if g else DIM))
        for s, style in note:
            head.append("  " + s, style)
        head.truncate(lw - 14, overflow="ellipsis", pad=True)
        head.append(fit("" if g is None else "required" if g["mention"] else "any message", 14), ALERT if f"mention:{c}" in wide else "")
        L.append(head)
    if nch > rows:
        L.append(Text(f"  {min(at, nch - 1) + 1} of {nch} channels", DIM))
    dm = dm_word(now)
    who = ", ".join(p["name"] for p in access_people(doc, was, now, extra) if p["id"] in now["dm_allow"])
    dms = radios(DMS + (("disabled",) if was["dm"] == "disabled" else ()), "allowlist" if dm == "off" and now["dm"] == "allowlist" else dm, "dm" in wide)
    below = [Text(), Text.assemble("▸ " if left[at][0] == "dm" and side == "left" else "  ", (fit("DMs", 6), DIM), dms,
                                   (("from " + who if who else "nobody yet: tab, then a adds") if now["dm"] == "allowlist" else
                                    "drops every message, in the channels too" if dm == "disabled" else "", DIM)),
             Text.assemble("▸ " if left[at][0] == "mode" and side == "left" else "  ", (fit("mode", 6), DIM), radios(MODES + ((now["mode"],) if now["mode"] not in MODES else ()), now["mode"]))]
    # the right pane, beside the lines above
    row, people = left[at], {p["id"]: p for p in access_people(doc, was, now, extra)}
    right = access_right(doc, was, now, row, extra)
    if row[0] == "ch":
        R = [Text(f"who may write to it in {name(row[1])}", f"bold {DIM}")]
        allow = now["groups"].get(row[1], {}).get("allow")
        if allow is None:
            R.append(Text("the bot does not listen here: space adds the channel", DIM))
    elif row[0] == "dm":
        R, allow = [Text("who may DM it, and answers its permission prompts", f"bold {DIM}")], now["dm_allow"]
    else:
        R, allow = [Text("a mode gives a session its rules and hooks", f"bold {DIM}"), Text("applies at once to the hooks; the rules at the", DIM), Text("session's next start, compact or clear", DIM)], None
    for i in window(len(right), prow, rows):
        kind, u = right[i]
        mark = "▸ " if i == prow and side == "right" else "  "
        if kind == "any":
            R.append(Text.assemble(mark, (box(allow == []), BRAND if allow == [] else DIM), " anyone in the channel", style=ALERT if f"any:{row[1]}" in wide else ""))
        else:
            on = u in (allow or [])
            new = on and (f"new:{u}" in wide if row[0] == "ch" else f"dm:{u}" in wide)
            R.append(Text.assemble(mark, (box(on), BRAND if on else DIM), " ", (people[u]["name"], ALERT if new else "" if on else DIM), ("  " + people[u]["tag"], DIM)))
    if right:
        R.append(Text("  a  adds a person by name or id", DIM))
    out = []
    for i in range(max(len(L), len(R))):
        line = L[i].copy() if i < len(L) else Text()
        line.truncate(lw, overflow="ellipsis", pad=True)
        if i < len(R):
            line.append("  ")
            line.append_text(R[i])
        out.append(line)
    out += below   # the DM policy and the mode take the whole width
    for line in out:
        line.truncate(width, overflow="ellipsis")
    return out


def in_terminal(argv: list) -> int:
    """`argv` run on the terminal the TUI has let go of (App.suspend), then one line read, so what it printed stays
    until it was read. Its exit status; 127 when it cannot be started, 130 after Ctrl-C."""
    try:
        rc = subprocess.call(argv)
    except OSError:
        rc = 127
    except KeyboardInterrupt:
        rc = 130
    try:
        input(f"\n[exit {rc}] enter goes back to the claude-discord tui ")
    except (EOFError, KeyboardInterrupt):
        pass
    return rc


A_CAP = 40     # seconds `access ... set` is given to reach its question (ssh's 30 s cap and a margin); none after a y: it may be writing
A_QUIET = 1    # seconds of silence, no question, after which what it printed is shown as the host's (a ProxyCommand's code prompt)
A_MARK = "\u2060"   # the line `access ... set` prints just before its question (1.13.1): U+2060 alone, which no Discord name holds
A_KEEP = 1 << 20    # bytes of what it prints that are kept: the first ones (the widenings come first)
SGR = re.compile(r"\x1b\[([0-9;]*)m")
# The CLI's question, the whole line: one form per count of changes and of widenings among them (bin/claude-discord).
QUESTION = re.compile(r"Apply (this change|these [1-9][0-9]* changes|this widening change|these [1-9][0-9]* widening changes"
                      r"|[1-9][0-9]* changes, [1-9][0-9]* of them widening)\? \[y/N\] ")
# 1.14.0, `claude-discord bot`: a bot's name (its Discord username, the CLI's b_name_re); the prompt `bot ... token|add`
# reads the token with, its echo off; its questions, the whole line (BOT_Q takes the prompt too: asked for after the marker).
BOT_NAME = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_-]{1,31}")
TOKEN_Q = "Token (hidden): "
RENAMED = re.compile(r"^renamed: (.+) -> ([A-Za-z0-9_][A-Za-z0-9_-]{1,31})$", re.M)   # `bot rename`'s last line once the directory moved
# 1.16.0: `bot <bot> recover`'s question names the bot as the CLI prints it (a directory named before 1.14.0's rule may
# hold anything printable): any name, since the marker line before it is what makes the line a question.
BOT_Q = re.compile(r"(Replace the token|Rename it to [A-Za-z0-9_][A-Za-z0-9_-]{1,31}|Add this bot|Recover .{1,64})\? \[y/N\] |" + re.escape(TOKEN_Q))
RECOVER_Q = re.compile(r"Recover .{1,64}\? \[y/N\] $")   # the form a batch (RecoverAll) answers itself


def ask_text(raw: str) -> Text:
    """What `access ... set` printed on its terminal, for a popup or a message: its red (SGR 31, the widenings) drawn in
    the alert colour, any other SGR back to plain, every other escape sequence and control character cleaned as all
    foreign text is (UNSAFE_NL), the pty's \\r and the CLI's marker line gone, and no blank line at either end."""
    raw = "\n".join(l for l in raw.replace("\r", "").split("\n") if l != A_MARK)
    out, style, at = Text(), "", 0
    for m in SGR.finditer(raw):
        out.append(clean(raw[at:m.start()], UNSAFE_NL), style)
        style = ALERT if "31" in m.group(1).split(";") else ""
        at = m.end()
    out.append(clean(raw[at:], UNSAFE_NL), style)
    lines = out.split("\n", allow_blank=True)
    while lines and not lines[0].plain.strip():
        lines.pop(0)
    while lines and not lines[-1].plain.strip():
        lines.pop()
    for line in lines:
        line.rstrip()
    return Text("\n").join(lines)


class PtyRun:
    """`argv` on a pseudo-terminal this program holds (1.13.1): its stdin, stdout and stderr are the pty's other end, so
    the CLI's terminal check holds and it prints its changes and asks its question itself, there; what it prints is
    read here, the answer written there. In a session of its own, so its whole process group (ssh -t, setup --mode)
    can be killed. next() blocks: it runs in a worker thread. The pty is read and closed only under `lock`: by next(),
    or by kill() when nobody reads; a closed pty is a run that has ended. `question` is the CLI's question line:
    access set's (QUESTION), or the bot verbs' (BOT_Q, 1.14.0), which ask for a token too."""

    def __init__(self, argv: list, master: int, slave: int, question: re.Pattern = None) -> None:
        self.question = question or QUESTION
        self.fd, self.buf, self.rc, self.killed = master, b"", None, False
        self.end: float | None = time.monotonic() + A_CAP   # the cap, until the answer
        self.shown = 0      # how much of buf a popup has had
        self.since = 0      # where what it printed after the answer starts
        self.lock = threading.Lock()
        try:
            self.p = subprocess.Popen(argv, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
        except OSError as e:
            self.p, self.rc, self.buf = None, 127, f"cannot run {argv[0]}: {e.strerror or e}\n".encode()
        os.close(slave)

    @classmethod
    def start(cls, argv: list, question: re.Pattern = None) -> "PtyRun | None":
        """None where no pty can be opened (no os.openpty, none left): the terminal is then handed over instead."""
        try:
            master, slave = os.openpty()
        except (AttributeError, OSError):
            return None
        return cls(argv, master, slave, question)

    def drain(self, wait: float) -> bool:
        """What the pty holds, read into buf (its first A_KEEP bytes), `wait` seconds for the first of it. False when
        nothing came (or the other end is closed)."""
        r, _, _ = select.select([self.fd], [], [], wait)
        if not r:
            return False
        try:
            data = os.read(self.fd, 65536)
        except OSError:   # EIO: every holder of the other end has closed it
            return False
        self.buf += data[:max(0, A_KEEP - len(self.buf))]
        return bool(data)

    def asks(self) -> bool:
        """Its last line is the CLI's question, whole, and the line before it the CLI's marker."""
        lines = self.buf.decode("utf-8", "replace").replace("\r", "").split("\n")
        return len(lines) > 1 and lines[-2] == A_MARK and self.question.fullmatch(lines[-1]) is not None

    def next(self, answer: bool | bytearray | None = None) -> tuple[str, str | int]:
        """The answer written (y or n; None: none), then what it printed, until: its question, the last line the CLI's
        and nothing after it for 0.1 s ("ask", with all it printed); A_QUIET s of silence after something else ("said",
        all it printed: a host's prompt is shown, never answered); or its end (its exit status, with what it printed
        after the answer; what is still in the pty is read first, for half a second at most). Until the answer it has
        A_CAP s from its start: past that its process group is killed, 124. After a y there is no cap. A bytearray is
        a token, asked for by TOKEN_Q with the terminal's echo off: written with a line end, then zeroed; the cap
        starts again, since the question is still to come."""
        with self.lock:
            if isinstance(answer, bytearray):
                try:
                    if self.fd >= 0 and not self.killed:
                        os.write(self.fd, bytes(answer) + b"\n")
                except OSError:
                    pass
                answer[:] = bytes(len(answer))
                self.end = time.monotonic() + A_CAP
            elif answer is not None and self.fd >= 0 and not self.killed:
                try:
                    os.write(self.fd, b"y\n" if answer else b"n\n")
                except OSError:
                    pass
                self.end, self.since = None, len(self.buf)
            quiet = time.monotonic()
            while self.rc is None:
                now = time.monotonic()
                if self.killed:
                    self.reap(0.5)
                elif self.end is not None and now >= self.end:
                    self.signal()
                    self.reap(0.5)
                    self.rc = 124
                elif self.p.poll() is not None:   # before any read: what keeps printing never hides its end
                    stop = time.monotonic() + 0.5   # whatever it left running that holds the pty is not waited for
                    while time.monotonic() < stop and self.drain(0.05):
                        pass
                    self.rc = self.p.returncode
                elif self.drain(0.1 if self.end is None else min(self.end - now, 0.1)):
                    quiet = time.monotonic()
                elif self.end is None:   # answered: only its end is waited for
                    continue
                elif len(self.buf) > self.shown and self.asks():   # a question it asked: not again the one answered (a token's)
                    self.shown = len(self.buf)
                    return self.buf.decode("utf-8", "replace"), "ask"
                elif time.monotonic() - quiet >= A_QUIET and self.buf[self.shown:].strip():
                    self.shown = len(self.buf)
                    return self.buf.decode("utf-8", "replace"), "said"
            self.close()
            return self.buf[self.since:].decode("utf-8", "replace"), self.rc

    def wait(self) -> None:
        """Until it ends, read here when no worker reads it (the editor closed after a y: it may be writing)."""
        while self.rc is None:
            self.next()

    def signal(self) -> None:
        if self.p is not None and self.p.poll() is None:
            try:
                os.killpg(self.p.pid, signal.SIGKILL)
            except OSError:
                pass

    def reap(self, wait: float) -> None:
        """Its exit status, `wait` seconds for it at most (a process in D state does not die at once); -9 past that."""
        try:
            self.rc = self.p.wait(wait) if self.p is not None else self.rc
        except subprocess.TimeoutExpired:
            self.rc = -signal.SIGKILL

    def kill(self) -> None:
        """Its process group killed. Whoever reads the pty ends there and closes it; when nobody does, it is closed
        here. Never blocks for long: this runs on the UI thread."""
        self.killed = True
        self.signal()
        if self.lock.acquire(blocking=False):
            try:
                if self.rc is None:
                    self.reap(0.2)
                self.close()
            finally:
                self.lock.release()

    def close(self) -> None:
        if self.fd >= 0:
            os.close(self.fd)
            self.fd = -1


A_HINT = "↑↓ move · space toggle · m mention · tab people · a add · s save · esc close"
A_SAID = {1: "exit 1: what it said is above the TUI, on the terminal; the bot's access.log has a line for anything it wrote", 2: "refused (exit 2): what it said is above the TUI, on the terminal",
          3: "no terminal for its question (exit 3): nothing was changed", 4: "answered no: nothing was changed. The changes are still here: adjust them, or esc",
          5: "the host did not answer, or its claude-discord is older than 1.13.0 (exit 5): nothing was changed"}
# The same, for a run on the TUI's pty, followed by what it said (A_SAID[4] alone).
A_RAN = {1: "not written (exit 1):", 2: "refused (exit 2):", 3: "no terminal for its question (exit 3): nothing was changed",
         5: "the host did not answer, or its claude-discord is older than 1.13.0 (exit 5): nothing was changed"}


class Asking:
    """The run of a command that asks on the TUI's pty (PtyRun), for a popup that has `say` and `ended(rc, said)`:
    `access ... set` (1.13.1) and, since 1.14.0, `bot ...`. Each step is the run's next part in a worker thread; its
    question is a popup (AccessAsk) whose answer is written to it; what it says and waits after that is no question of
    the CLI's is shown as the host's (HostSays), never answered; a token it asks for (TOKEN_Q) is written from
    `secret`, which is zeroed then; its end goes to ended() with the last of what it printed. esc stops it before a y,
    never after one (it may be writing)."""
    run = None                 # its PtyRun while it runs
    printed = ""               # what it printed after the answer, whole, once it ended (ended() gets the last of it)
    FRAME = ("#access", "#a-tail")   # the popup's box and the scroll of its message line in it (BotPopup sets its own)
    asked = stopped = False    # it asked its question; esc (or Cancel) stopped it
    batch_yes = False          # 1.16.0: a batch (RecoverAll) asked once itself and answers the CLI's `Recover <bot>?` y, with no popup
    yes: bool | None = None    # the answer written to it; None: none yet
    says = None                # the HostSays popup while it is open
    secret: bytearray | None = None   # the token to write when it asks for one: never a str, zeroed once written
    YES_SAID = "answered y: it runs, and is waited for (esc does not stop it now)"
    NO_SAID = "answered n; it ends"
    HELD_SAID = "still running: it was answered y and may be writing; it is waited for"
    cancel_rest = False        # 1.16.0: esc after a y, in a batch (RecoverAll): this run is waited for and no other is started

    def step(self, answer: bool | bytearray | None) -> None:
        """The run's next part, in a worker thread: the answer written (y or n, or the token; None: none), then what it
        prints until its question, something else it says and waits after (a host's prompt), or its end."""
        run, app = self.run, self.app
        if run is None:
            return
        if isinstance(answer, bool):
            self.yes = answer
            self.say(self.YES_SAID if answer else self.NO_SAID)

        def work() -> None:
            text, what = run.next(answer)
            try:
                app.call_from_thread(self.stepped, run, text, what)
            except RuntimeError:   # the app has ended meanwhile
                pass
        app.run_worker(work, thread=True, exit_on_error=False)

    def stepped(self, run, text: str, what: str | int) -> None:
        if run is not self.run:
            return
        if what in ("ask", "said") and self.stopped:   # stopped meanwhile: its end is what comes next
            return self.step(None)
        if what == "said":   # no question of the CLI's (a ProxyCommand's code prompt, a slow host): shown, never answered
            if self.says is not None and self.app.screen is self.says:
                self.says.show(ask_text(text))
            else:
                self.says = HostSays(ask_text(text))
                self.app.push_screen(self.says, self.waited)
            return self.step(None)
        self.unsay()
        if what == "ask" and text.replace("\r", "").endswith("\n" + TOKEN_Q):   # the token, asked for with its echo off
            secret, self.secret = self.secret or bytearray(), None
            return self.step(secret)
        if what == "ask" and self.batch_yes and RECOVER_Q.search(text.replace("\r", "")):   # 1.16.0: the batch's one question stood for it
            self.asked = True
            return self.step(True)
        if what == "ask":   # its question: a popup with all it printed, its answer the next step
            self.asked = True
            return self.app.push_screen(AccessAsk(ask_text(text)), self.step)
        rc, self.run = what, None
        self.forget()
        self.printed = ask_text(text).plain   # all of it, for a line a program reads (BotName: `renamed: <old> -> <new>`)
        # What is said: every line after the answer's echo, 16 at most, never the program line (1.14.1). The message
        # sits in a scroll pinned to its end (fit_tail), so on a short terminal it is the FIRST of those lines that go
        # out of view, never the last, where what failed and its command are (review I2).
        lines = [l for l in self.printed.split("\n") if l.strip() and not RENAMED.match(l)]
        if self.yes is not None and lines and lines[0].strip() in ("y", "n"):
            lines.pop(0)   # the pty's echo of the answer
        said = "\n".join(lines[-16:])
        self.ended(rc, f"\n{said}" if said else "")

    def fit_tail(self) -> None:
        """The message's scroll (FRAME: the popup's box and that scroll) as high as the terminal leaves it beside the
        box's other rows, 3 at least, and scrolled to its end: a message longer than that shows its last lines. Called
        after the message is set and at a resize (the box is `height: auto`, so it would else grow past the terminal,
        which cuts it at its end)."""
        if not self.query(self.FRAME[0]):   # taken down meanwhile
            return
        box, tail = self.query_one(self.FRAME[0]), self.query_one(self.FRAME[1], VerticalScroll)
        rest = box.gutter.height + sum(w.outer_size.height for w in box.children if w is not tail)
        tail.styles.max_height = max(3, self.app.size.height - rest)
        self.call_after_refresh(tail.scroll_end, animate=False)

    def on_resize(self, event: Resize) -> None:
        self.call_after_refresh(self.fit_tail)

    def forget(self) -> None:
        """The token zeroed, as far as Python lets a program forget: it never was a str here (the field it was typed in
        is emptied when it is taken), and the bytes written to the pty are gone with their call."""
        if self.secret is not None:
            self.secret[:] = bytes(len(self.secret))
            self.secret = None

    def waited(self, wait: bool | None) -> None:
        """The host's popup answered: Wait, or Cancel (the run stopped). None: taken down here."""
        if wait is not None:
            self.says = None
            if not wait:
                self.stop()

    def unsay(self) -> None:
        if self.says is not None:
            says, self.says = self.says, None
            if self.app.screen is says:
                says.dismiss(None)

    def stop(self) -> None:
        """esc while it runs: its process group killed and its end said. Not after a y: it may be writing, and is
        waited for."""
        if self.yes:
            self.cancel_rest = True
            return self.say(self.HELD_SAID, WARN)
        self.stopped = True
        self.run.kill()

    def on_unmount(self) -> None:
        """The popup taken down while it runs (the TUI quitting): killed, or, after a y, waited for."""
        self.forget()
        if self.run is not None:
            self.run, run = None, self.run
            run.wait() if self.yes else run.kill()


class AccessEdit(Asking, ModalScreen):
    """`e` on a bot row: the channels the bot listens in, per channel whether an @mention is required and who may
    write, the DM policy with its allowlist, and the bot's mode. Read through `access ... --json` in a worker thread
    (for a bot on another host that is one capped ssh call); changed in memory only, until `s`: the change words go to
    `access ... set` on a pty the TUI holds (PtyRun, 1.13.1), because that command shows the changes and asks its one
    question on a terminal: what it printed up to the question is the text of a popup (AccessAsk), whose answer is
    written to it. Where no pty can be opened, the terminal is handed over to it instead (App.suspend, as in 1.13.0).
    Its exit status decides what is said. Dismissed with what there is to say after a save, or None."""
    CSS = f"""AccessEdit {{ align: center middle; }}
    #access {{ width: 118; max-width: 96%; height: auto; border: round {BRAND}; padding: 1 2; }}
    #a-body {{ height: auto; margin: 1 0; text-wrap: nowrap; }} #a-add {{ width: 44; display: none; }} #a-add.shown {{ display: block; }}
    #a-tail {{ height: auto; }}"""
    AUTO_FOCUS = ""   # nothing is focused (None would mean the app's rule: the first field), so the keys are the screen's until a name is typed
    # tab is the screen's too (priority: before the focus moves).
    BINDINGS = [Binding("escape", "close", "close"), Binding("up", "move(-1)"), Binding("down", "move(1)"), Binding("left", "turn(-1)"), Binding("right", "turn(1)"),
                Binding("tab", "side", priority=True), Binding("space", "toggle"), Binding("m", "mention"), Binding("a", "add"), Binding("s", "save"), Binding("c", "copy")]

    def __init__(self, entry: dict) -> None:
        super().__init__()
        self.entry = entry                       # the bot's entry of the state: its host, project and name
        self.doc: dict | None = None             # the document of `access --json`; None until it is read
        self.was: dict = {}                      # the model as the document had it
        self.now: dict = {}                      # the model as edited
        self.at, self.side, self.prow = 0, "left", 0
        self.kept: dict = {}                     # a channel id (or "dm") -> the list it had before `anyone` (or off) emptied it
        self.typed: list = []                    # the ids added here by name or id: they stay listed whatever is unticked
        self.by_hand = ""                        # the command for a shell, where this terminal cannot be handed over
        self.run = None                          # the PtyRun of `access ... set` while it runs
        self.asked = self.stopped = False        # it asked its question; esc (or Cancel) stopped it
        self.yes: bool | None = None             # the answer written to it; None: none yet
        self.says = None                         # the HostSays popup while it is open

    def compose(self) -> ComposeResult:
        with Vertical(id="access"):
            yield Static("", id="a-title")
            yield Static("", id="a-body")
            yield Input(id="a-add", placeholder="a name or a numeric user id, then enter", max_length=64, compact=True)
            tail = VerticalScroll(id="a-tail")   # the message, in a scroll pinned to its end (fit_tail): never focused
            tail.can_focus = False
            with tail:
                yield Static("reading access.json and the server's channels ...", id="a-msg", markup=False)

    def on_mount(self) -> None:
        self.paint()
        call, entry = self.app.access_cli, self.entry
        self.app.run_worker(lambda: self.app.call_from_thread(self.loaded, call(entry, "--json")), thread=True)

    def say(self, text: str, style: str = DIM) -> None:
        self.query_one("#a-msg", Static).update(Text(text, style))
        self.call_after_refresh(self.fit_tail)

    def loaded(self, answer: tuple) -> None:
        """The document. Another program's output, from another machine for a remote bot: parsed as JSON, cleaned, read
        through txt/obj/seq; a wrong shape is a refusal to edit, never a crash."""
        if not self.is_attached:
            return
        rc, out, err = answer
        try:
            doc = clean(json.loads(out)) if rc == 0 else None
        except ValueError:
            doc = None
        if not isinstance(doc, dict) or doc.get("access") != 1:
            return self.say(err or f"claude-discord access gave no document (exit {rc})", ALERT)
        self.doc, self.was = doc, access_model(doc)
        self.now = copy.deepcopy(self.was)
        left = self.left()
        self.at = left.index(("ch", txt(doc.get("main")))) if ("ch", txt(doc.get("main"))) in left else 0
        errors = [txt(e) for e in seq(doc.get("errors")) if txt(e)]
        self.say("Discord did not answer everything (" + "; ".join(errors) + "): a channel it did not list can be named only by id, with the CLI" if errors else A_HINT, WARN if errors else DIM)
        self.paint()

    def left(self) -> list[tuple]:
        return access_left(self.doc, self.was, self.now)

    def right(self) -> list[tuple]:
        return access_right(self.doc, self.was, self.now, self.left()[self.at], self.typed)

    def words(self) -> list[str]:
        return access_words(self.was, self.now, txt(self.doc.get("owner"))) if self.doc is not None else []

    def paint(self) -> None:
        e = self.entry
        title = Text.assemble(("Access", f"bold {BRAND}"), (" · ", DIM), (txt(e.get("bot")), f"bold {BRAND}"),
                              (f"    {host_label(self.app.state, e.get('host'))} · access.json · applies at the next message, no restart", DIM))
        if self.words():
            title.append("    ● unsaved changes", WARN)
        self.query_one("#a-title", Static).update(title)
        if self.doc is not None:
            width = min(118, self.app.width * 96 // 100) - 6
            self.prow = max(0, min(self.prow, len(self.right()) - 1))
            self.query_one("#a-body", Static).update(Text("\n").join(access_lines(self.doc, self.was, self.now, self.at, self.side, self.prow, width, extra=self.typed)))

    def adding(self) -> bool:
        return self.query_one("#a-add", Input).has_class("shown")

    def check_action(self, action: str, parameters: tuple) -> bool | None:
        if action == "close":
            return True
        return self.doc is not None and not self.adding() and self.run is None

    def action_move(self, d: int) -> None:
        if self.side == "left":
            self.at, self.prow = max(0, min(len(self.left()) - 1, self.at + d)), 0
        else:
            self.prow = max(0, min(len(self.right()) - 1, self.prow + d))
        self.paint()

    def action_side(self) -> None:
        self.side = "right" if self.side == "left" and self.right() else "left"
        self.paint()

    def radio(self, kind: str, d: int) -> None:
        if kind == "mode":
            opts = MODES + ((self.was["mode"],) if self.was["mode"] not in MODES else ())
            self.now["mode"] = opts[(opts.index(self.now["mode"]) + d) % len(opts)]
        else:
            opts = DMS + (("disabled",) if self.was["dm"] == "disabled" else ())
            cur = self.now["dm"]
            new = opts[(opts.index(cur) + d) % len(opts)]
            if new == "off":       # off is an allowlist with nobody on it: the list is put aside, and back when off is left
                self.kept["dm"], self.now["dm_allow"] = self.now["dm_allow"], []
            elif cur == "off":
                self.now["dm_allow"] = self.kept.pop("dm", None) or list(self.was["dm_allow"])
            self.now["dm"] = new
        self.paint()

    def action_turn(self, d: int) -> None:
        row = self.left()[self.at]
        if self.side == "left" and row[0] != "ch":
            self.radio(row[0], d)
        elif (self.side == "left") == (d > 0):
            self.action_side()

    def action_toggle(self) -> None:
        row, owner = self.left()[self.at], txt(self.doc.get("owner"))
        if self.side == "left" and row[0] != "ch":
            return self.radio(row[0], 1)
        if self.side == "left":
            c = row[1]
            if c in self.now["groups"]:
                del self.now["groups"][c]
            elif c in self.was["groups"]:
                self.now["groups"][c] = copy.deepcopy(self.was["groups"][c])
            elif owner:
                self.now["groups"][c] = {"mention": True, "allow": [owner]}   # what the CLI makes of channel+
            else:
                return self.say("no owner id is known for this bot (DISCORD_USER_ID in its project's config.env): a channel cannot be added", ALERT)
            return self.paint()
        kind, u = self.right()[self.prow]
        if row[0] == "dm":
            allow = self.now["dm_allow"]
            allow.remove(u) if u in allow else allow.append(u)
            if self.now["dm"] == "off":
                self.now["dm"] = "allowlist"
        else:
            g = self.now["groups"][row[1]]
            if kind == "any" and g["allow"]:
                self.kept[row[1]], g["allow"] = g["allow"], []
            elif kind == "any":
                back = self.kept.pop(row[1], None) or list(self.was["groups"].get(row[1], {}).get("allow", [])) or ([owner] if owner else [])
                if not back:
                    return self.say("nobody to go back to: add a person first (a)", ALERT)
                g["allow"] = back
            elif u not in g["allow"]:
                g["allow"].append(u)
            elif len(g["allow"]) == 1:
                return self.say("the last sender stays: a list with nobody on it is everyone. Tick `anyone in the channel` to mean that, or leave the channel (space on it)", ALERT)
            else:
                g["allow"].remove(u)
        self.say(A_HINT)
        self.paint()

    def action_mention(self) -> None:
        row = self.left()[self.at]
        if row[0] == "ch" and row[1] in self.now["groups"]:
            g = self.now["groups"][row[1]]
            g["mention"] = not g["mention"]
            self.paint()

    def action_add(self) -> None:
        if not self.right():
            return self.say("a person is added to a channel the bot listens in, or to the DMs: move there first", ALERT)
        self.side = "right"
        field = self.query_one("#a-add", Input)
        field.add_class("shown")
        field.focus()
        self.paint()

    def added(self) -> None:
        field = self.query_one("#a-add", Input)
        field.value = ""
        field.remove_class("shown")
        self.set_focus(None)

    def on_input_submitted(self, event: Input.Submitted) -> None:
        u, why = find_person(event.value, self.doc)
        if u is None:
            return self.say(why, ALERT)
        row = self.left()[self.at]
        allow = self.now["dm_allow"] if row[0] == "dm" else self.now["groups"][row[1]]["allow"]
        if u not in allow:
            allow.append(u)
        self.typed.append(u)
        if row[0] == "dm" and self.now["dm"] == "off":
            self.now["dm"] = "allowlist"
        self.added()
        self.prow = self.right().index(("u", u))
        self.say(A_HINT)
        self.paint()

    def action_save(self) -> None:
        words = self.words()
        if not words:
            return self.say("nothing to save")
        argv = self.app.access_argv(self.entry, "set", *words)
        run = self.app.pty(argv)
        if run is not None:
            self.run, self.asked, self.yes, self.stopped, self.says = run, False, None, False, None
            self.say("claude-discord access ... set is reading the changes; esc stops it")
            return self.step(None)
        rc = self.app.handover(argv)
        if rc is None:   # no terminal to hand over (Textual cannot suspend here): the same command, for a shell
            self.by_hand = f"cd {shlex.quote(os.getcwd())} && " + shlex.join(["claude-discord", *argv[1:]])
            self.say(f"this terminal cannot be handed over for its question. Run it in a shell (c copies it), then esc:\n{self.by_hand}", WARN)
        elif rc == 0:
            self.dismiss("access saved: the plugin reads access.json at the next message, no restart" + (
                "; the hooks follow the new mode at once, the dev-manager rules at the session's next start, compact or clear" if self.now["mode"] != self.was["mode"] else ""))
        else:
            self.say(A_SAID.get(rc, f"claude-discord access exited {rc}: what it said is above the TUI, on the terminal"), ALERT)

    YES_SAID = "answered y: claude-discord access ... set writes the changes, and is waited for (esc does not stop it now)"
    NO_SAID = "answered n; claude-discord access ... set ends"
    HELD_SAID = "still running: it was answered y and may be writing access.json or setting the mode; it is waited for"

    def ended(self, rc: int, said: str) -> None:
        if self.stopped:   # only ever before a y
            self.say("stopped: nothing was changed", ALERT)
        elif rc == 0 and not self.asked:
            self.dismiss(said.strip() or "nothing to change")
        elif rc == 0 and self.yes:
            self.dismiss("access saved: the plugin reads access.json at the next message, no restart" + (
                "; the hooks follow the new mode at once, the dev-manager rules at the session's next start, compact or clear" if self.now["mode"] != self.was["mode"] else ""))
        elif self.yes:
            self.say(f"claude-discord access exited {rc} after the answer y. The bot's access.log has a line for each thing it did "
                     "(access.json written; the mode set, or failed):" + said, ALERT)
        elif rc == 4:
            self.say(A_SAID[4], ALERT)
        elif rc == 124:
            self.say(f"claude-discord access asked no question this TUI answers within {A_CAP} s and was stopped: nothing was changed" + said, ALERT)
        else:
            self.say(A_RAN.get(rc, f"claude-discord access exited {rc}:") + said, ALERT)

    def action_copy(self) -> None:
        if self.by_hand:
            self.app.copy_to_clipboard(self.by_hand)
            self.say(f"copied (if your terminal allows it):\n{self.by_hand}", WARN)

    def action_close(self) -> None:
        if self.run is not None:
            self.stop()
        elif self.adding():
            self.added()
        elif self.words() and not self.by_hand:
            self.app.push_screen(Confirm(f"Close without saving the changes to {txt(self.entry.get('bot'))}'s access?"), lambda yes: self.dismiss(None) if yes else None)
        else:
            self.dismiss(None)


class Btn(Button):
    """A button of a popup's row: ← and → move the focus to the one before or after it in that row (around at the
    ends), Enter presses it."""
    BINDINGS = [Binding("left", "row(-1)", show=False), Binding("right", "row(1)", show=False)]

    def action_row(self, d: int) -> None:
        row = [b for b in self.parent.children if isinstance(b, Button) and b.focusable]
        if self in row:
            row[(row.index(self) + d) % len(row)].focus()


class Confirm(ModalScreen[bool]):
    """A yes/no question, No by default (focused, and Enter, n and Escape answer it; ← → move between the buttons)."""
    CSS = "Confirm { align: center middle; } #confirm { width: 70; height: auto; border: thick $error; padding: 1 2; }"
    BINDINGS = [Binding("y", "answer(True)", "yes"), Binding("n", "answer(False)", "no"), Binding("escape", "answer(False)", "no")]
    LABELS = ("No", "Yes")

    def __init__(self, text) -> None:
        super().__init__()
        self.text = text

    def compose(self) -> ComposeResult:
        with Vertical(id="confirm"):
            yield Static(self.text, markup=False)
            with Horizontal():
                yield from self.buttons()

    def buttons(self) -> ComposeResult:
        yield Btn(self.LABELS[0], id="no")
        yield Btn(self.LABELS[1], id="yes", variant="error")

    def on_mount(self) -> None:
        self.query_one("#no", Button).focus()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        self.dismiss(event.button.id == "yes")

    def action_answer(self, yes: bool) -> None:
        self.dismiss(yes)


class Scrolled(Confirm):
    """A popup for a text that may not fit the screen: the text scrolls (↑↓ PgUp PgDn Home End, the focus staying on
    the buttons), a line under it says how much of it is above and below, and its last line stays in view, under that,
    with the buttons. Sized to the screen whatever its size."""
    CSS = """Scrolled { align: center middle; } #ask { width: 118; max-width: 96%; height: auto; max-height: 100%; border: thick $error; padding: 1 2; }
    #ask-text { height: auto; } #ask-more { height: 1; color: $text-muted; } #ask Horizontal { height: auto; margin-top: 1; }"""
    BINDINGS = [Binding("up", "scroll('up')", show=False), Binding("down", "scroll('down')", show=False), Binding("pageup", "scroll('page_up')", show=False),
                Binding("pagedown", "scroll('page_down')", show=False), Binding("home", "scroll('home')", show=False), Binding("end", "scroll('end')", show=False)]

    def parts(self) -> tuple:
        """The text that scrolls and the last line, which does not."""
        lines = self.text.split("\n")
        return Text("\n").join(lines[:-1]), lines[-1]

    def compose(self) -> ComposeResult:
        body, last = self.parts()
        scroll = VerticalScroll(id="ask-text")
        scroll.can_focus = False
        with Vertical(id="ask"):
            with scroll:
                yield Static(body, id="ask-body", markup=False)
            yield Static("", id="ask-more", markup=False)
            yield Static(last, id="ask-q", markup=False)
            with Horizontal():
                yield from self.buttons()

    def on_mount(self) -> None:
        super().on_mount()
        for what in ("scroll_y", "virtual_size"):   # scrolled; laid out again (fitted, the scrollbar come or gone)
            self.watch(self.query_one("#ask-text"), what, lambda *_: self.more(), init=False)
        self.call_after_refresh(self.fit)

    def on_resize(self, event: Resize) -> None:
        self.call_after_refresh(self.fit)

    def fit(self) -> None:
        """The text as high as the screen leaves it: the screen less the frame, the line under it, the last line and
        the buttons."""
        if not self.query("#ask"):   # taken down meanwhile
            return
        ask = self.query_one("#ask")
        rest = ask.gutter.height + sum(w.outer_size.height for w in ask.children if w.id != "ask-text")
        self.query_one("#ask-text").styles.max_height = max(3, self.size.height - rest)
        self.call_after_refresh(self.more)

    def more(self) -> None:
        if not self.query("#ask-text"):
            return
        t = self.query_one("#ask-text", VerticalScroll)
        above, below = round(t.scroll_y), round(t.max_scroll_y - t.scroll_y)
        said = [f"▲ {above} more line{'s' * (above != 1)} above"] * (above > 0) + [f"▼ {below} more line{'s' * (below != 1)} below"] * (below > 0)
        self.query_one("#ask-more", Static).update(", ".join(said) + "  ·  ↑↓ PgUp PgDn scroll" if said else "")

    def action_scroll(self, how: str) -> None:
        getattr(self.query_one("#ask-text", VerticalScroll), f"scroll_{how}")(animate=False)


class AccessAsk(Scrolled):
    """The question of `access ... set`, run on the TUI's pty: all it printed up to it (the changes, the widenings
    first and red, the warnings) and, always in view under them, the question with its counts; Yes / No. No is the
    default (focused, and Enter on it, n and Escape answer it): `n` is written to it; y, or Enter on Yes, writes `y`."""


class HostSays(Scrolled):
    """What `access ... set` printed and waits after, which is no question of the CLI's (a ProxyCommand asking for a
    code, a host slow to answer): shown as the host's, never answered. Cancel (the default, and Escape) stops the run;
    Wait closes this and waits on, within the cap. Shown again with all it printed when it says more."""
    LABELS = ("Cancel", "Wait")

    def parts(self) -> tuple:
        return (Text.assemble(("the host says:", "bold"), "\n", self.text),
                Text(f"Not answered here, and nothing is written before claude-discord access asks its own question: Cancel stops it; "
                     f"Wait waits for that question, up to {A_CAP} s from the start.", DIM))

    def show(self, text: Text) -> None:
        self.text = text
        self.query_one("#ask-body", Static).update(self.parts()[0])
        self.call_after_refresh(self.fit)


# ---- bot: a bot's token, its name, a new bot (1.14.0) ------------------------
# Through `claude-discord bot --host <host> --manager <this manager> --project <project> -- ...`, run on a pty of the
# TUI's as access set is: the CLI shows what it will do and asks its one question there (AccessAsk). A token is typed
# into a Secret field, taken out of it as a bytearray when the popup runs (the field emptied), and written to the pty
# only when the CLI asks for it with its echo off; PtyRun zeroes it then.
B_RAN = {1: "it could not:", 2: "refused (exit 2):", 3: "no terminal for its question (exit 3): nothing was changed",
         4: "answered no: nothing was changed", 5: "the host did not answer, or its claude-discord is too old for this (exit 5): nothing was changed"}


class Secret(Input):
    """The token field: drawn as dots, and never copied or cut (Input copies a password field's text to the clipboard)."""

    def action_copy(self) -> None:
        pass

    def action_cut(self) -> None:
        pass


class Choice(Static, can_focus=True):
    """A radio row of a popup, drawn `label  (●) a   ( ) b`: ← → or space move the choice while it has the focus.
    `labels` are what is drawn for the options (a host's display name), when given."""
    BINDINGS = [Binding("space", "turn(1)"), Binding("left", "turn(-1)"), Binding("right", "turn(1)")]

    def __init__(self, label: str, options: list, labels: list | None = None, **kw) -> None:
        super().__init__(**kw)
        self.label, self.options, self.labels, self.at = label, list(options), labels, 0

    @property
    def value(self) -> str:
        return self.options[self.at] if self.options else ""

    def on_mount(self) -> None:
        self.paint()

    def paint(self) -> None:
        shown = self.labels or self.options
        self.update(Text.assemble((fit(self.label, 12), DIM), radios(tuple(shown), shown[self.at]) if shown else Text("none known", DIM)))

    def action_turn(self, d: int) -> None:
        if self.options:
            self.at = (self.at + d) % len(self.options)
            self.paint()
            self.screen.changed(self)

    def on_click(self, event: events.Click) -> None:   # the focus is taken by Textual on the press
        if self.app.plain(event):
            self.action_turn(1)


class Check(Static, can_focus=True):
    """A checkbox of a popup, drawn `[✓] label`: space toggles it while it has the focus."""
    BINDINGS = [Binding("space", "flip")]
    on = True

    def __init__(self, label: str, **kw) -> None:
        super().__init__(**kw)
        self.label = label

    def on_mount(self) -> None:
        self.update(Text.assemble((" " * 12), box(self.on), " ", self.label))

    def action_flip(self) -> None:
        self.on = not self.on
        self.on_mount()

    def on_click(self, event: events.Click) -> None:
        if self.app.plain(event):
            self.action_flip()


class BotPopup(Asking, ModalScreen):
    """What the three bot popups share: the frame, the message line, the buttons (← → between them, the safe one
    first and focused when it opens), the run of `claude-discord bot ...` on the TUI's pty and what its end says. Dismissed with what there is
    to say (the monitor is then asked for a pass), or None."""
    CSS = f"""BotPopup {{ align: center middle; }}
    #bot {{ width: 104; max-width: 96%; height: auto; border: round {BRAND}; padding: 1 2; }}
    #bot Horizontal {{ height: auto; }} #bot .lab {{ width: 12; color: $text-muted; }} #bot .hint {{ width: auto; padding-left: 2; color: $text-muted; }}
    #b-field {{ width: 56; }} #b-buttons {{ margin-top: 1; }} #bot Button {{ margin-right: 2; }}
    Choice:focus, Check:focus {{ background: {CURSOR}; }} #b-tail {{ height: auto; }}"""
    BINDINGS = [Binding("escape", "close", "close")]
    FRAME = ("#bot", "#b-tail")
    GO = "Run"     # the label of the button that runs it
    DONE = "done"  # what is said when it ran and said nothing

    def __init__(self, entry: dict) -> None:
        super().__init__()
        self.entry = entry   # the bot's entry of the state (its host, project and name); {} for a new bot
        self.by_hand = ""    # the command for a shell, where no pty can be opened

    def body(self) -> ComposeResult:
        yield from ()

    def compose(self) -> ComposeResult:
        with Vertical(id="bot"):
            yield Static("", id="b-title")
            yield from self.body()
            with Horizontal(id="b-buttons"):
                yield Btn("Cancel", id="b-no")
                yield Btn(self.GO, id="b-go", variant="error")
            tail = VerticalScroll(id="b-tail")   # the message, in a scroll pinned to its end (fit_tail): never focused
            tail.can_focus = False
            with tail:
                yield Static("", id="b-msg", markup=False)

    def say(self, text: str, style: str = DIM) -> None:
        self.query_one("#b-msg", Static).update(Text(text, style))
        self.call_after_refresh(self.fit_tail)

    def changed(self, choice: "Choice") -> None:
        pass

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "b-no":
            self.action_close()
        elif self.run is None:
            self.go()

    def on_input_submitted(self, event: Input.Submitted) -> None:
        if self.run is None:
            self.go()

    def go(self) -> None:
        pass

    def start(self, argv: list) -> None:
        """`argv` on a pty, its first step; where no pty can be opened, the command for a shell (c copies it)."""
        run = self.app.pty(argv, BOT_Q)
        if run is None:
            self.forget()
            self.by_hand = shlex.join(["claude-discord", *argv[1:]])
            return self.say(f"no pseudo-terminal can be opened here: run it in a shell (c copies it), then esc:\n{self.by_hand}", WARN)
        self.run, self.asked, self.yes, self.stopped, self.says = run, False, None, False, None
        self.say("claude-discord bot is running; esc stops it until it is answered y")
        self.step(None)

    def ended(self, rc: int, said: str) -> None:
        if self.stopped:   # only ever before a y
            self.say("stopped: nothing was changed", ALERT)
        elif rc == 0:
            self.dismiss(said.strip() or self.DONE)
        elif rc == 124:
            self.say(f"claude-discord bot asked no question this TUI answers within {A_CAP} s and was stopped: nothing was changed" + said, ALERT)
        else:
            self.say(B_RAN.get(rc, f"claude-discord bot exited {rc}:") + said, ALERT)

    def token_field(self) -> ComposeResult:
        with Horizontal():
            yield Static("token", classes="lab")
            yield Secret(id="b-field", password=True, max_length=200, compact=True, placeholder="paste the bot's token: it is drawn as dots")

    def take(self) -> bool:
        """The token out of its field into self.secret (a bytearray), the field emptied; False when there is none."""
        field = self.query_one("#b-field", Input)
        if not field.value.strip():
            return False
        self.secret, field.value = bytearray(field.value.strip().encode()), ""
        return True

    def key_c(self) -> None:   # a key, not a binding: in a focused field c is text
        if self.by_hand:
            self.app.copy_to_clipboard(self.by_hand)

    def action_close(self) -> None:
        if self.run is not None:
            self.stop()
        else:
            self.dismiss(None)


class BotName(BotPopup):
    """`n` on a bot row: its name, which is its Discord username, changed on Discord and here together (`bot <name>
    rename <new>`); `=` on a row whose two names differ opens it with Discord's name and runs it at once (Discord is
    then not asked to change anything)."""
    GO = "Rename"

    def __init__(self, entry: dict, preset: str = "") -> None:
        super().__init__(entry)
        self.preset = preset

    def body(self) -> ComposeResult:
        e = self.entry
        yield Static(Text.assemble((fit("Discord", 12), DIM), (discord_name(e) or txt(e.get("discord_name")) or "-", "bold"),
                                   ("    its username there, which is its name here too", DIM)))
        with Horizontal():
            yield Static("new name", classes="lab")
            yield Input(self.preset or txt(e.get("bot")), id="b-field", restrict=r"[A-Za-z0-9_-]*", max_length=32, compact=True)
            yield Static("2 to 32 of A-Z a-z 0-9 _ -", classes="hint")

    def on_mount(self) -> None:
        e = self.entry
        self.query_one("#b-title", Static).update(Text.assemble(("Name", f"bold {BRAND}"), (" · ", DIM), (txt(e.get("bot")), f"bold {BRAND}"),
                                                                (f"    {host_label(self.app.state, e.get('host'))} · Discord allows about 2 changes an hour", DIM)))
        self.query_one("#b-no", Button).focus()
        self.say("shift+tab to the name · enter in it renames: Discord first, then here (a running bot is stopped and started again) · esc closes")
        if self.preset:
            self.go()

    def go(self) -> None:
        new = self.query_one("#b-field", Input).value
        if not BOT_NAME.fullmatch(new):
            return self.say("a name is 2 to 32 of A-Z a-z 0-9 _ -, not starting with -", ALERT)
        self.start(self.app.bot_argv(self.entry, txt(self.entry.get("bot")), "rename", new))

    def ended(self, rc: int, said: str) -> None:
        # Once the CLI says the directory moved (its last line), whatever failed after that: the bot's row is the new
        # name's now (1.14.1), and for the manager itself its backend's state is the new name's too. Its exit status
        # cannot say it: a start after the move may fail. The line is read from all it printed: `said` drops it. The
        # manager's own: retarget first (it reads the moved state.json, whose bots still carry the old name: the
        # monitor renames them at its next pass), then the row renamed in what that gave (review I1).
        m, e = RENAMED.search(self.printed), self.entry
        if m and m.group(1) == txt(e.get("bot")):
            if m.group(1) == self.app.bot and e.get("host") == "local":
                self.app.retarget(m.group(2))
            self.app.renamed(txt(e.get("host")), txt(e.get("project")), m.group(1), m.group(2))
        super().ended(rc, said)


class BotToken(BotPopup):
    """`t` on a bot row: its token replaced (`bot <name> token`). The current token is never read or shown; the new
    one is checked with Discord as that bot before it is saved, by the CLI on the bot's machine."""
    GO = "Replace"

    def body(self) -> ComposeResult:
        yield Static(Text("Paste the bot's new token (Developer Portal, the bot's Bot tab, Reset Token). It is checked with Discord "
                          "as that bot before it is saved; a token of another bot is refused. The current token is never read here.", DIM))
        yield from self.token_field()

    def on_mount(self) -> None:
        e = self.entry
        self.query_one("#b-title", Static).update(Text.assemble(("Token", f"bold {BRAND}"), (" · ", DIM), (txt(e.get("bot")), f"bold {BRAND}"),
                                                                (f"    {host_label(self.app.state, e.get('host'))} · a running session logs in with it within 10 s", DIM)))
        self.query_one("#b-no", Button).focus()
        self.say("shift+tab to the token field · enter in it checks it with Discord, then asks · esc closes")

    def go(self) -> None:
        if not self.take():
            return self.say("paste the token first", ALERT)
        self.start(self.app.bot_argv(self.entry, txt(self.entry.get("bot")), "token"))


class BotAdd(BotPopup):   # not a BotToken: Textual runs each class's on_mount
    """`a` on the Bots tab: a new bot (`bot add`). Its host (this machine or a ledger host), its project (one a bot of
    that host is in: the channel and the owner are that project's), its mode and whether it starts now are chosen
    here; its name is not asked: it is its Discord username, which the CLI reads with its token. A username that is
    no name here (a space, a letter outside A-Z) is refused by the CLI, which says to rename the bot on Discord first."""
    GO = "Add"
    DONE = "added"

    def __init__(self, hosts: list, labels: list, projects: dict) -> None:
        super().__init__({})
        self.hosts, self.labels, self.projects = hosts, labels, projects

    def body(self) -> ComposeResult:
        yield Choice("host", self.hosts, self.labels, id="b-host")
        yield Choice("project", self.projects.get(self.hosts[0] if self.hosts else "", []), id="b-project")
        yield Choice("mode", list(MODES), id="b-mode")
        yield Check("start it now", id="b-start")
        yield from self.token_field()

    def on_mount(self) -> None:
        self.query_one("#b-title", Static).update(Text.assemble(("Add a bot", f"bold {BRAND}"),
                                                                ("    its name is its Discord username, read with its token", DIM)))
        self.query_one("#b-no", Button).focus()
        self.say("tab moves · ← → or space choose · enter in the token field adds · esc closes")

    def changed(self, choice: Choice) -> None:
        """Another host: the projects of that host's bots."""
        if choice.id != "b-host":
            return
        project = self.query_one("#b-project", Choice)
        project.options, project.at = self.projects.get(self.query_one("#b-host", Choice).value, []), 0
        project.paint()

    def go(self) -> None:
        host, project = self.query_one("#b-host", Choice).value, self.query_one("#b-project", Choice).value
        if not project:
            return self.say("no project of this host has a bot yet: set up its first bot there with claude-discord setup", ALERT)
        if not self.take():
            return self.say("paste the token first", ALERT)
        start = ["--start"] if self.query_one("#b-start", Check).on else []
        self.start(self.app.bot_argv({"host": host, "project": project}, "add", "--mode", self.query_one("#b-mode", Choice).value, *start))


# ---- recover: the recovery keys f and F (1.16.0) ------------------------------
# `claude-discord bot <bot> recover` on the bot's host, through the pty as the other bot popups: the host decides what
# runs (claude respawn of the bot's last session while claude agents lists it, or, when its current session id moved on
# since its job record, a stop and a --bg --resume of the current id; else --bg --name), prints it and asks. The row is
# not changed here: the monitor is asked for one pass. Never `--fresh` (1.17.1): see recoverable().
R_HOW = {"recover": "the host decides: claude respawn of its last session while claude agents still lists it (or a stop and a --resume of its current session id, after a /clear), else --bg --name"}


def recover_why(b: dict, how: str) -> str:
    """What will be asked of the host for this row: R_HOW's line; a stale row is told its conversation is kept, and
    where the discarding form lives."""
    if txt(b.get("verdict")) == "stale":
        return "STUCK is 'no answer on Discord', not 'wedged': the host respawns its last session, conversation kept; --fresh (a fresh session, the conversation gone) is the CLI's alone, claude-discord bot <bot> recover --fresh, refused while its transcript moved in the last 15 min"
    return R_HOW[how]


def verdict_since(b: dict, now: float) -> str:
    v = txt(b.get("verdict"))
    return f"{WORD.get(v, v or '?')} {ago(b.get('since'), now)}".rstrip()


class BotRecover(BotPopup):
    """`f` on a down or stale row: `bot <bot> recover`, run at once (as `=` does); the CLI's plan and its one
    question are the popup (AccessAsk, No first), its `ran` line what the dismiss says."""
    GO = "Recover"
    DONE = "ran"

    def __init__(self, entry: dict, how: str) -> None:
        super().__init__(entry)
        self.how = how   # recoverable()'s word: "recover"

    def body(self) -> ComposeResult:
        e = self.entry
        yield Static(Text.assemble((fit("runs", 12), DIM), (f"claude-discord bot {txt(e.get('bot'))} {self.how}", f"bold {BRAND}"),
                                   (f"    on {host_label(self.app.state, e.get('host'))}, in {txt(e.get('project'))}", DIM)), id="r-cmd")
        yield Static(Text.assemble((fit("fix line", 12), DIM), (txt(e.get("fix")), DIM)))
        yield Static(Text.assemble((" " * 12, ""), (recover_why(e, self.how), DIM)), id="r-why")

    def on_mount(self) -> None:
        e = self.entry
        self.query_one("#b-title", Static).update(Text.assemble(("Recover", f"bold {BRAND}"), (" · ", DIM), (txt(e.get("bot")), f"bold {BRAND}"),
                                                                (f"    {host_label(self.app.state, e.get('host'))} · ", DIM), (verdict_since(e, time.time()), WARN),
                                                                ("  ·  the CLI asks before it runs anything", DIM)))
        self.query_one("#b-no", Button).focus()
        self.say("the CLI's question opens as a popup: y or Yes runs it, n or esc runs nothing · esc here stops it until then")
        self.go()

    def go(self) -> None:
        self.start(self.app.bot_argv(self.entry, txt(self.entry.get("bot")), *self.how.split()))


class RecoverAll(BotPopup):
    """`F`: every row `f` would take, listed in the table's order with what will be asked of its host (the problem rows
    `f` refuses listed as skipped); one question of this popup's; then each row's `bot <bot> recover [--fresh]` in turn
    on the pty, the next only after the previous ended, the CLI's own question answered y here (batch_yes); at the end
    what ran and what failed (the CLI's last lines), and the monitor asked for one pass, its answer shown with the
    results (the dismiss asks none again: ASK_GAP). esc before a run's y stops it and skips the rest; after a y it is
    waited for. Its state: ready (nothing ran yet), running (the row at `at`), done (`outcome`: done or stopped)."""
    BINDINGS = BotPopup.BINDINGS + [Binding("y", "yes", show=False)]
    HELD_SAID = "still running: it was answered y and may be writing; it is waited for, and the rest of the batch is not started"

    def __init__(self, rows: list, skipped: list) -> None:
        super().__init__({})
        self.rows, self.skipped = rows, skipped   # [(entry, how)] and [entry]
        self.GO = f"Run {len(rows)}"
        self.phase, self.outcome, self.at, self.results, self.succeeded = "ready", "", 0, [], 0
        self.summary = Text()

    def body(self) -> ComposeResult:
        now, st = time.time(), self.app.state
        for i, (b, how) in enumerate(self.rows):
            yield Static(Text.assemble((f"{i + 1:>2}. ", DIM), (txt(b.get("bot")), "bold"), (f"  {host_label(st, b.get('host'))} · ", DIM), (verdict_since(b, now), WARN),
                                       ("  →  ", DIM), (f"claude-discord bot {txt(b.get('bot'))} {how}", BRAND)), id=f"r-{i}")
            yield Static(Text.assemble(("     ", ""), (recover_why(b, how), DIM)), id=f"r-why-{i}")
            yield Static(Text.assemble(("     fix line: ", DIM), (txt(b.get("fix")), DIM)))
        for i, b in enumerate(self.skipped):
            why = ("its host could not be reached at the last pass" if cut_off(st, b) else
                   "no command recovers a duplicate: which copy to stop is yours" if txt(b.get("verdict")) == "duplicate" else "nothing to run") + " (f refuses it too)"
            yield Static(Text.assemble((" –  ", DIM), (txt(b.get("bot")), f"bold {DIM}"), (f"  {host_label(st, b.get('host'))} · {verdict_since(b, now)}  →  skipped: {why}", DIM)), id=f"r-skip-{i}")
            yield Static(Text.assemble(("     fix line: ", DIM), (txt(b.get("fix")), DIM)))
        yield Static(Text.assemble((self.question(), "bold"), ("    each CLI question is answered y here; what failed is listed at the end", DIM)), id="r-q")

    def question(self) -> str:
        n = len(self.rows)
        return f"Recover {n} bot{'s' if n != 1 else ''}? [y/N]"

    def on_mount(self) -> None:
        self.query_one("#b-title", Static).update(Text.assemble(("Recover every down or stale bot", f"bold {BRAND}"),
                                                                (f"    {len(self.rows)} of {len(self.rows) + len(self.skipped)} problem rows · the host decides what each runs", DIM)))
        self.query_one("#b-no", Button).focus()
        self.say(f"← → between the buttons · y or Run {len(self.rows)} runs them in the table's order · esc closes, or stops a run before its y")

    def action_yes(self) -> None:
        self.go()

    def go(self) -> None:
        if self.phase != "ready":
            return
        self.phase, self.batch_yes = "running", True
        self.query_one("#r-q", Static).update(Text(self.question() + " y", "bold"))
        self.next_run()

    def next_run(self) -> None:
        b, how = self.rows[self.at]
        self.start(self.app.bot_argv(b, txt(b.get("bot")), *how.split()))
        if self.run is None:   # no pty: start() showed the command for a shell; the batch ends here
            self.results.append(f"– {txt(b.get('bot'))}: not run (no pseudo-terminal: {self.by_hand})")
            self.results += [f"– {txt(x.get('bot'))}: not run" for x, _ in self.rows[self.at + 1:]]
            return self.finish("stopped")
        self.say(f"{self.at + 1}/{len(self.rows)}: {txt(b.get('bot'))} runs; esc stops it until its question is answered y")

    def ended(self, rc: int, said: str) -> None:
        bot = txt(self.rows[self.at][0].get("bot"))
        lines = [l for l in said.split("\n") if l.strip()]
        if self.stopped:   # only ever before its y
            self.results.append(f"– {bot}: stopped before its y: nothing was run")
            self.results += [f"– {txt(b.get('bot'))}: not run" for b, _ in self.rows[self.at + 1:]]
            return self.finish("stopped")
        if rc == 0:
            self.results.append(f"✓ {bot}: {lines[-1] if lines else self.DONE}")
            self.succeeded += 1
        else:
            self.results.append(f"✕ {bot} (exit {rc}): " + ("\n      ".join(lines[-3:]) if lines else B_RAN.get(rc, f"claude-discord bot exited {rc}")))
        self.at += 1
        if self.cancel_rest:   # esc after this run's y: it was waited for, the rest is not started (I2 of the review)
            self.results += [f"– {txt(b.get('bot'))}: not run" for b, _ in self.rows[self.at:]]
            return self.finish("stopped")
        if self.at < len(self.rows):
            return self.next_run()
        self.finish("done")

    def finish(self, outcome: str) -> None:
        self.phase, self.outcome, self.batch_yes = "done", outcome, False
        ok, bad = sum(r.startswith("✓") for r in self.results), sum(r.startswith("✕") for r in self.results)
        left = len(self.results) - ok - bad
        self.summary = Text(f"{outcome}: {ok} succeeded, {bad} failed" + (f", {left} not run" if left else ""), ALERT if bad or outcome == "stopped" else OK)
        for r in self.results:   # one line per bot, in the colour of its outcome
            self.summary.append("\n" + r, OK if r.startswith("✓") else ALERT if r.startswith("✕") else DIM)
        self.query_one("#b-msg", Static).update(self.summary)
        self.call_after_refresh(self.fit_tail)
        if self.succeeded:   # the pass (a row changed something), asked here so that its answer is read with the results
            self.app.run_worker(lambda: self.app.call_from_thread(self.passed, self.app.ask_pass()), thread=True)

    def passed(self, text: str) -> None:
        self.query_one("#b-msg", Static).update(Text.assemble(self.summary, ("\n\nasked the monitor for a pass: the rows change when it has run (esc closes)\n", DIM), (text, DIM)))
        self.call_after_refresh(self.fit_tail)

    def action_close(self) -> None:
        if self.run is not None:
            self.stop()
        else:
            self.dismiss("\n".join(self.results) if self.succeeded else None)


class Pane(VerticalScroll, can_focus=False):
    """The tab's body. Never focused: the arrow keys move the row cursor (the app's bindings), not the scroll position.
    The wheel is the arrows': a row up or down, and the pane follows the cursor (paint)."""

    def on_mouse_scroll_down(self, event: events.MouseScrollDown) -> None:
        self.app.action_move(1)
        event.prevent_default()
        event.stop()

    def on_mouse_scroll_up(self, event: events.MouseScrollUp) -> None:
        self.app.action_move(-1)
        event.prevent_default()
        event.stop()


class MonitorTUI(App):
    TITLE = "claude-discord"
    CSS = f"""
    #title, #foot {{ height: 1; text-wrap: nowrap; }} #tabs {{ height: 2; text-wrap: nowrap; }}
    #bar {{ background: darkred; color: white; }} #bar.hidden {{ display: none; }}
    #pane {{ height: 1fr; overflow-x: hidden; }} #body {{ width: auto; text-wrap: nowrap; }}
    #foot {{ background: {BAR}; }}
    """
    BINDINGS = [Binding("q", "quit", "quit"), Binding("Q", "quit_stop", "quit + stop backend"),
                Binding("up", "move(-1)"), Binding("down", "move(1)"), Binding("left", "tab(-1)"), Binding("right", "tab(1)"),
                Binding("space", "toggle"), Binding("enter", "open"), Binding("c", "copy"), Binding("a", "add"), Binding("x", "remove"),
                Binding("l", "laptop"), Binding("e", "edit"), Binding("n", "name"), Binding("t", "token"), Binding("equals_sign", "align"),
                Binding("f", "recover"), Binding("F", "recover_all")]

    def __init__(self, state_dir: Path, bot: str, wrapper: str | None, version: str = "") -> None:
        super().__init__()
        self.state_dir, self.bot, self.wrapper, self.version = state_dir, bot, wrapper, version
        self.home, self.ssh = Path.home(), "ssh"   # where ~/.ssh/config is, and the ssh that `ssh -G` runs (the tests set both)
        self.state: dict = {}
        self.names: dict = {}
        self.note = ""   # why `monitor --ensure` failed, shown in the red bar
        self.mtime: float | None = None
        self.ensured = float("-inf")   # when `monitor --ensure` last ran (time.monotonic())
        self.asked = float("-inf")     # when `monitor --check` last asked for a pass (time.monotonic())
        self.ask_lock = threading.Lock()   # ask_pass runs in worker threads
        self.holder = state_dir / "holders" / f"tui-{os.getpid()}"
        # The plugin's version file, read on every refresh (1.18.2): a TUI left open across `claude-discord update`
        # reads the files of the version it started on (at 1.18.1 the backend's records moved out from under one, and
        # it showed '○ not running' and 'no state yet' while the backend ran at the new path), so a change is said.
        self.plugin_json = Path(wrapper).resolve().parent.parent / ".claude-plugin" / "plugin.json" if wrapper else None
        self.width = 0   # the terminal's: set at mount, then by each Resize (self.size still holds the old one while that event runs)
        self.tab = "bots"
        self.cursor: dict = {t: None for t in TABS}   # the selected row's key, per tab
        self.opened: set = set()                      # the expanded bot rows
        self.shown: dict = {}                         # widget id -> the Text it shows: an update only when it changes
        self.tab_at: list = []                        # (first cell, end, tab) of each label of #tabs, as the last paint laid them out
        self.line_key: list = []                      # the row key of each line of #body (None: no row), as the last paint laid them out
        self.pressed = None                           # where the mouse button last went down (screen cell)

    def compose(self) -> ComposeResult:
        yield Static("", id="title")
        yield Static("", id="tabs")
        yield Static("", id="bar", classes="hidden", markup=False)
        with Pane(id="pane"):
            yield Static("", id="body")
        yield Static("", id="foot")

    def ensure(self) -> None:
        """The holder record and the monitor: one wrapper call, which returns at once."""
        self.ensured = time.monotonic()
        # Its refusals (no ledger, no .env) go to stderr, not monitor.log; the monitor child writes to the log.
        try:
            r = subprocess.run([self.wrapper, "monitor", "--ensure", self.bot, "--holder", "tui", str(os.getpid())],
                               stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                               text=True, errors="replace", check=False)
            self.note = (" ".join(r.stderr.split()) or f"monitor --ensure exited {r.returncode}") if r.returncode else ""
        except OSError as e:   # a missing or non-executable wrapper: say so instead of crashing the mount
            self.note = f"cannot run {self.wrapper}: {e.strerror or e}"

    def stopped(self) -> str | None:
        """When `monitor --stop` left its marker (UTC), or None when there is none."""
        try:
            t = (self.state_dir / "stopped").stat().st_mtime
        except OSError:
            return None
        return datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    def refused(self) -> bool:
        try:   # this side's marker: monitor.sh names it by the pid namespace (digits only), plain where /proc has none
            ns = "".join(c for c in os.readlink("/proc/self/ns/pid") if c in "0123456789")
        except OSError:
            ns = ""
        return (self.state_dir / (f"refused.{ns}" if ns else "refused")).exists()

    def backend(self, verb: str) -> None:
        """`monitor --start` or `--stop` of this bot; a failure is shown in the red bar."""
        try:
            r = subprocess.run([self.wrapper, "monitor", verb, self.bot], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                               stderr=subprocess.PIPE, text=True, errors="replace", check=False)
            self.note = (" ".join(r.stderr.split()) or f"monitor {verb} exited {r.returncode}") if r.returncode else ""
        except OSError as e:
            self.note = f"cannot run {self.wrapper}: {e.strerror or e}"

    def started(self, yes: bool | None) -> None:
        if yes:
            self.backend("--start")
            self.ensure()
        self.refresh_state()   # No: read-only, the title says stopped by you

    def on_mount(self) -> None:
        self.width = self.size.width
        stopped = self.stopped()
        if self.wrapper and stopped:
            self.push_screen(Confirm(f"The backend of {self.bot} was stopped by you at {stopped}. Start it again?"), self.started)
        elif self.wrapper:
            self.ensure()
        self.refresh_state()
        self.set_interval(2, self.refresh_state)

    def updated_to(self) -> str | None:
        """The plugin's version when it differs from the one this TUI started on (`--version-line`'s first word), else
        None: no wrapper, no file, no version in it, or the same version."""
        if not self.plugin_json or not self.version:
            return None
        try:
            v = txt(json.loads(self.plugin_json.read_text()).get("version"))
        except (OSError, ValueError, AttributeError):
            return None
        return v if v and v != self.version.split()[0] else None

    def refresh_state(self) -> None:
        path = self.state_dir / "state.json"
        try:
            mtime = path.stat().st_mtime
        except OSError:
            mtime = None
        if mtime is None or mtime != self.mtime:
            self.mtime = mtime
            self.state = load(path)
            self.names = load_names(self.state)
        # Checked on every refresh, not only on a new state.json: a monitor that died without its trap writes none.
        pid = obj(self.state.get("monitor")).get("pid")
        if self.wrapper and not self.stopped() and not alive(pid, self.bot) and time.monotonic() - self.ensured >= 30:
            self.ensure()
        self.paint()

    def items(self, now: float) -> list[tuple]:
        w = self.width
        if self.tab == "bots":
            return bots_items(self.state, self.names, w, self.opened, now)
        return alerts_items(self.state, w, now) if self.tab == "alerts" else config_items(self.state, self.names, w)

    def show(self, wid: str, text: Text) -> bool:
        """Updates a widget only when its text changed: a repaint every 2 s would drop a mouse selection each time."""
        if self.shown.get(wid) == text:
            return False
        self.shown[wid] = text
        self.query_one(wid, Static).update(text)
        return True

    def paint(self) -> None:
        now, w, stopped = time.time(), self.width, self.stopped() is not None
        live = alive(obj(self.state.get("monitor")).get("pid"), self.bot)
        self.show("#title", title_line(self.state, w, now, live, stopped, self.version))
        self.tab_at = []
        self.show("#tabs", tabs_lines(self.tab, len(open_alerts(self.state)), w, self.tab_at))
        bar = bar_text(self.state, self.note, stopped, self.refused())
        up = self.updated_to()
        if up:   # ahead of every other bar text: what this TUI shows is the old version's view of files that moved on
            bar = f"claude-discord updated to {up} since this TUI started ({self.version}): press q, then run claude-discord tui again"
        b = self.query_one("#bar", Static)
        b.update(bar or "")
        b.set_class(bar is None, "hidden")
        items = self.items(now)
        keys = [k for k, _ in items if k is not None]
        if self.cursor[self.tab] not in keys:   # the row left the state (or nothing was selected yet): the first one
            self.cursor[self.tab] = keys[0] if keys else None
        text, y, h = render(items, self.cursor[self.tab], w)
        self.line_key = [k for k, lines in items for _ in lines]   # render() lays the lines out in this order
        if self.show("#body", text):
            self.query_one("#pane", Pane).scroll_to_region(Region(0, y, 1, h), animate=False, force=True)
        self.show("#foot", foot_line(self.tab, w))

    def on_resize(self, event: Resize) -> None:
        self.width = event.size.width
        self.paint()

    def check_action(self, action: str, parameters: tuple) -> bool | None:
        # The row keys belong to the main view: under a Detail or a dialog they do nothing.
        return len(self.screen_stack) == 1 or action not in ("move", "tab", "toggle", "open", "copy", "add", "remove", "laptop", "edit", "name", "token", "align",
                                                             "recover", "recover_all")

    def on_mouse_down(self, event: events.MouseDown) -> None:
        self.pressed = event.screen_offset

    def plain(self, event: events.Click) -> bool:
        """A click and not a drag. Textual sends a Click to the widget the button went down on, wherever it went up, and
        keeps what a drag selected: only down and up on one cell is a click (that up drops any selection before the Click
        arrives). A double or triple click is Textual's: it selects the word or the line."""
        return event.chain == 1 and self.pressed == event.screen_offset

    def on_click(self, event: events.Click) -> None:
        """The main view's clicks (a popup's own widgets take theirs): a tab label is the tab key's, a row is selected, and
        the selected one is Enter's."""
        wid = event.widget.id if event.widget else None
        if len(self.screen_stack) != 1 or wid not in ("tabs", "body") or not self.plain(event):
            return
        if wid == "tabs":
            tab = next((t for a, b, t in self.tab_at if a <= event.x < b), None)
            if tab:
                self.action_tab(TABS.index(tab) - TABS.index(self.tab))
            return
        key = self.line_key[event.y] if 0 <= event.y < len(self.line_key) else None
        if key is None:
            return
        if key == self.cursor[self.tab]:
            self.action_open()
        else:
            self.cursor[self.tab] = key
            self.paint()

    def action_tab(self, d: int) -> None:
        self.tab = TABS[(TABS.index(self.tab) + d) % len(TABS)]
        self.paint()

    def action_move(self, d: int) -> None:
        keys = [k for k, _ in self.items(time.time()) if k is not None]
        if keys:
            i = keys.index(self.cursor[self.tab]) if self.cursor[self.tab] in keys else 0
            self.cursor[self.tab] = keys[max(0, min(len(keys) - 1, i + d))]
            self.paint()

    def action_toggle(self) -> None:
        if self.tab == "bots" and self.cursor["bots"]:
            self.opened ^= {self.cursor["bots"]}
            self.paint()

    def action_open(self) -> None:
        key, alerts = self.cursor[self.tab], seq(self.state.get("alerts"))
        if key is None:
            return
        if self.tab == "alerts":
            which, _, k = key.partition(" ")
            a = next((x for x in open_alerts(self.state) if x["key"] == k), {}) if which == "open" else alerts[int(k)] if int(k) < len(alerts) else {}
            self.push_screen(Detail(posted_text(a)))
            return
        scope = "bots" if self.tab == "bots" else "hosts"
        entry = obj(self.state.get(scope)).get(key)
        if scope == "hosts" and isinstance(entry, dict) and entry.get("left_s") is None:   # a host of the ledger: its settings
            self.push_screen(HostEdit(key, txt(entry.get("hostname"))), self.wrote)
            return
        entry = obj(entry)
        # A host's posts are keyed host|- in `alerts`; a bot's and a project row's by their own key.
        self.push_screen(Detail(entry_text(key, key + "|-" if scope == "hosts" else key, with_mode(entry) if scope == "bots" else entry, alerts),
                                txt(entry.get("fix")), discord_line(entry, self.width) if scope == "bots" else None))

    def action_copy(self) -> None:
        fix = fix_of(self.state, obj(obj(self.state.get("bots")).get(self.cursor["bots"] or ""))) if self.tab == "bots" else ""
        if fix:   # only what the row shows as its fix line
            self.copy_to_clipboard(fix)   # OSC 52: the terminal's clipboard, over ssh too
            self.notify("fix copied (if your terminal allows it)")   # OSC 52 has no answer, and not every terminal takes it

    def hosts_cli(self, *args: str, feed=None) -> tuple[int, str, str]:
        """`claude-discord hosts --bot <bot> <args>` from the manager's project (the TUI's own cwd): the one way this
        program reads or changes the ledger. 90 s at most: the CLI caps each of its ssh calls at 20 s itself. `feed`
        is run_capped's: the object whose `sending` is the command's stdin."""
        if not self.wrapper:
            return 127, "", "started without the wrapper (--claude-discord): the ledger cannot be changed from here"
        return run_capped([self.wrapper, "hosts", "--bot", self.bot, *args], 90, feed)

    def said(self, text: str | None) -> None:
        """Words of the CLI, shown as they are (never as markup)."""
        if text:
            self.notify(text, timeout=10, markup=False)

    ASK_GAP = 10   # seconds between two `monitor --check` calls, at least

    def asked_lately(self) -> bool:
        return time.monotonic() - self.asked < self.ASK_GAP

    def ask_pass(self) -> str:
        """`monitor --check`: the running monitor is asked for a pass at its next tick (it reads the ledger afresh at
        every pass, 5 minutes apart otherwise). Returns what to tell the user: that it will, or why nobody was asked
        (no monitor runs: stopped by its owner). Within ASK_GAP of the last request none is made: that one stands
        (the monitor serves all it meets in one pass), whether it came from Check now or after a change to the ledger.
        Run in a worker thread."""
        with self.ask_lock:
            if self.asked_lately():
                return ASKED
            self.asked = time.monotonic()
        rc, out, err = run_capped([self.wrapper, "monitor", "--check", self.bot], 10) if self.wrapper else (127, "", "")
        if rc != 0:
            self.asked = float("-inf")   # nobody was asked: the next one asks again
        return out if rc == 0 else err or f"claude-discord monitor --check exited {rc}"

    def wrote(self, text: str | None) -> None:
        """A dialog was dismissed with the CLI's words about a change it made to the ledger (None: it made none): the
        monitor is asked for a pass, so the table shows the change within a tick and a pass, and both are said."""
        if text:
            self.run_worker(lambda: self.call_from_thread(self.said, f"{text}\n{self.ask_pass()}"), thread=True)

    def hosts_do(self, *args: str) -> None:
        """A hosts CLI call from a key of the main view, in a worker thread; what it says is shown when it ends."""
        def work() -> None:
            rc, out, err = self.hosts_cli(*args)
            self.call_from_thread(self.said, "\n".join(x for x in (out, err, self.ask_pass() if rc == 0 else "") if x) or f"claude-discord hosts exited {rc}")
        self.run_worker(work, thread=True)

    def action_remove(self) -> None:
        key = self.cursor["config"] if self.tab == "config" else None
        if key:
            self.push_screen(Confirm(f"Stop monitoring {key}? Its line leaves the ledger of {self.bot}; its bots leave the list (the monitor keeps them "
                                     "a day as 'left the ledger'). Nothing is stopped on the host itself."),
                             lambda yes: self.hosts_do("rm", key) if yes else None)

    def action_laptop(self) -> None:
        key = self.cursor["config"] if self.tab == "config" else None
        if key:   # from what the last pass saw; when the ledger was changed since, the CLI says `already so`
            self.hosts_do("laptop", key, "off" if obj(obj(self.state.get("hosts")).get(key)).get("laptop") else "on")

    def action_add(self) -> None:
        listed = [k for k, h in obj(self.state.get("hosts")).items() if obj(h).get("left_s") is None]
        if self.tab == "config":
            self.push_screen(AddHost(set(listed)), self.wrote)
        elif self.tab == "bots":   # 1.14.0: a new bot, on this machine or a ledger host, in a project a bot of it is in
            hosts = sorted((h for h in listed if ALIAS.fullmatch(h)), key=lambda h: (h != "local", h))
            bots = [obj(b) for b in obj(self.state.get("bots")).values()]
            projects = {h: sorted({txt(b.get("project")) for b in bots if b.get("host") == h and txt(b.get("bot")) and txt(b.get("project"))}) for h in hosts}
            self.push_screen(BotAdd(hosts, [host_label(self.state, h) for h in hosts], projects), self.wrote)

    def bot_row(self) -> dict:
        """The bot of the Bots tab's cursor row, when it is one the CLI can reach: a bot (not a project whose health
        crashed) of `local` or of a ledger alias. {} otherwise."""
        b = obj(obj(self.state.get("bots")).get(self.cursor["bots"] or "")) if self.tab == "bots" else {}
        return b if txt(b.get("bot")) and txt(b.get("project")) and ALIAS.fullmatch(txt(b.get("host"))) else {}

    def action_edit(self) -> None:
        """`e` on a bot row: its access editor. Not for a row that is no bot (a project whose health crashed)."""
        if self.bot_row():
            self.push_screen(AccessEdit(self.bot_row()), self.wrote)

    def action_name(self) -> None:
        if self.bot_row():
            self.push_screen(BotName(self.bot_row()), self.wrote)

    def action_token(self) -> None:
        if self.bot_row():
            self.push_screen(BotToken(self.bot_row()), self.wrote)

    def action_align(self) -> None:
        """`=` on a row whose name is not Discord's: the name here becomes Discord's (Discord is not asked to change)."""
        b = self.bot_row()
        if b and discord_name(b):
            self.push_screen(BotName(b, discord_name(b)), self.wrote)

    def action_recover(self) -> None:
        """`f` on a problem row (1.16.0): `bot <bot> recover [--fresh]` on the bot's host, after the CLI's one question.
        A row it may not run on is said, with the row's fix text: `f` takes a down or stale bot of a host that answers."""
        b = self.bot_row()
        if not b:
            return
        how = recoverable(self.state, b)
        if not how:
            v = txt(b.get("verdict"))
            return self.notify(f"{txt(b.get('bot'))}: {WORD.get(v, v or '?')}{': ' + txt(b.get('fix')) if txt(b.get('fix')) else ''}"
                               + (" (its host could not be reached at the last pass)" if cut_off(self.state, b) else "") + "\nf recovers a down or stale bot only",
                               title="not recovered", severity="warning", markup=False, timeout=10)
        self.push_screen(BotRecover(b, how), self.wrote)

    def action_recover_all(self) -> None:
        """`F` on the Bots tab (1.16.0): every row `f` would take, in the table's order, after one question."""
        if self.tab != "bots":
            return
        rows = [(b, recoverable(self.state, b)) for _, b in sorted_bots(self.state)]
        take = [(b, how) for b, how in rows if how]
        if not take:
            return self.notify("nothing to recover: no down or stale bot on a host that answers", title="not recovered", severity="warning", timeout=10)
        self.push_screen(RecoverAll(take, [b for b, how in rows if not how and rank(b.get("verdict")) == 0]), self.wrote)

    def bot_argv(self, b: dict, *rest: str) -> list[str]:
        """`claude-discord bot --host <the bot's host> --manager <this manager> --project <its project> -- ...`, as
        access_argv: the CLI takes the ledger line's env words itself and sends names and paths over ssh as hex."""
        return [self.wrapper or "claude-discord", "bot", "--host", txt(b.get("host")), "--manager", self.bot, "--project", txt(b.get("project")), "--", *rest]

    def retarget(self, bot: str) -> None:
        """The manager renamed (`bot rename` moved its backend's records): this TUI follows it, its holder record moved with them."""
        self.bot, self.state_dir = bot, self.state_dir.parent / bot
        self.holder, self.mtime = self.state_dir / "holders" / f"tui-{os.getpid()}", None
        self.refresh_state()

    def renamed(self, host: str, project: str, old: str, new: str) -> None:
        """`bot rename` moved a bot's directory (the CLI's last line): its row is the new name's now, without waiting
        for the pass the popup asked for. Both names are the new one, so `enter` shows no Discord name line. The next
        state.json replaces all of this. The key is the monitor's reducer's, `host|project|bot` (a remote bot's project
        is the path on that host, as the entry holds it)."""
        bots = obj(self.state.get("bots"))
        for key in [k for k, b in bots.items() if isinstance(b, dict) and (txt(b.get("host")), txt(b.get("project")), txt(b.get("bot"))) == (host, project, old)]:
            b = bots.pop(key)
            b["bot"], b["discord_name"] = new, new
            nk = "|".join((host, project, new))
            bots[nk] = b
            if self.cursor["bots"] == key:
                self.cursor["bots"] = nk
            if key in self.opened:
                self.opened = (self.opened - {key}) | {nk}
        self.names = load_names(self.state)
        self.paint()

    def access_argv(self, b: dict, *rest: str) -> list[str]:
        """`claude-discord access --host <the bot's host> --manager <this manager> --project <its project> -- <bot> ...`,
        run from the manager's project (the TUI's own cwd). The host is `local` or an alias of the ledger; the CLI
        takes that line's env words itself (this program never has an env value), and sends a project path and a
        bot's name, which are another machine's text, over ssh as hex digits."""
        return [self.wrapper, "access", "--host", txt(b.get("host")), "--manager", self.bot, "--project", txt(b.get("project")), "--", txt(b.get("bot")), *rest]

    def access_cli(self, b: dict, *rest: str) -> tuple[int, str, str]:
        """A read-only access call (`--json`), 60 s at most: the CLI caps its ssh call at 30 s (one retry after a failed
        connection) and starts no Discord call past 12 s."""
        if not self.wrapper:
            return 127, "", "started without the wrapper (--claude-discord): access cannot be read from here"
        return run_capped(self.access_argv(b, *rest), 60, limit=1 << 22)

    runner = staticmethod(in_terminal)   # what runs a command on the handed-over terminal (the tests set it)
    pty = staticmethod(PtyRun.start)     # what runs `access ... set` on a pty of the TUI's, None without one (the tests set it)

    def handover(self, argv: list) -> int | None:
        """The terminal handed to `argv`, which asks its own question there, until it ends: its exit status. None where
        the terminal cannot be handed over (Textual's suspend is not supported: no real terminal, Textual Web)."""
        try:
            with self.suspend():
                return self.runner(argv)
        except SuspendNotSupported:
            return None

    def action_quit_stop(self) -> None:
        if not self.wrapper:
            return

        def answered(yes: bool | None) -> None:
            if yes:
                # --stop waits up to 5 s per keeper and 5 s for the monitor: off the event loop, the bar saying so.
                self.note = f"stopping the backend of {self.bot} ..."
                self.refresh_state()
                self.run_worker(self.stop_and_quit, thread=True)
        self.push_screen(Confirm(f"Quit and stop the backend of {self.bot}: its keeper and monitor stop, and so do its alerts "
                                 f"until claude-discord monitor --start {self.bot}."), answered)

    def stop_and_quit(self) -> None:
        self.backend("--stop")
        self.call_from_thread(self.exit)

    def on_unmount(self) -> None:
        try:
            self.holder.unlink()
        except OSError:
            pass


def main() -> None:
    p = argparse.ArgumentParser(prog="claude-discord tui")
    p.add_argument("--bot", required=True)
    p.add_argument("--state-dir", required=True, type=Path)
    p.add_argument("--claude-discord", default=None, help="the wrapper, for the holder record and --ensure")
    p.add_argument("--version-line", default="", help="what claude-discord --version prints, for the title (1.14.1)")
    a = p.parse_args()
    # The title shows what follows the name (`1.14.1 (8db5787)`); a line of another shape is shown whole.
    version = a.version_line[len("claude-discord "):] if a.version_line.startswith("claude-discord ") else a.version_line
    MonitorTUI(a.state_dir, a.bot, a.claude_discord, version).run()


if __name__ == "__main__":
    main()
