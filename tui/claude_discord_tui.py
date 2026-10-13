# /// script
# requires-python = ">=3.9"
# dependencies = ["textual>=8.2.8,<9"]
# ///
"""claude-discord tui: a read-only view of a manager bot's backend monitor.

Started by `claude-discord tui [<bot>]` through `uv run --script`. It registers
itself as a holder of the monitor (which starts the monitor if none runs),
re-reads state.json when its mtime changes (checked every 2 s) and removes its
holder record on quit. Three tabs (Bots, Alerts, Configuration) over that one
file, plus the display names the bots of this machine keep in `user-names`.
It changes nothing else: no restart, no post, no patch, and it never reads a
.env, so it cannot show a token.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import signal
import subprocess
import time
from datetime import datetime, timezone
from itertools import islice
from pathlib import Path

from rich.cells import cell_len, set_cell_size
from rich.text import Text
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.events import Resize
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
PROBLEM = ("down", "stale", "duplicate", "unreachable")
# The findings the channel is told within 5 minutes of their appearing. Any other is a warning only (the reducer's
# warn_only): told after half an hour (throttled, apierror, hostdown) or never (noreach, a verdict this version does not know).
LOUD = PROBLEM + ("nostate", "patchfail", "blind")
GOOD = ("busy", "ok")
WORD = {"down": "DOWN", "stale": "STUCK", "duplicate": "DUPLICATE", "unreachable": "UNREACHABLE", "throttled": "rate-limited",
        "apierror": "api error", "nostate": "no state", "blind": "blind", "noreach": "no network", "busy": "working", "ok": "ok",
        "unknown": "no token"}


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
    return 0 if verdict in PROBLEM else 2 if verdict in GOOD else 3 if verdict == "unknown" else 1


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


def status_head(state: dict, b: dict, now: float) -> tuple[str, str]:
    """A row's status as its closed row shows it, and its colour: symbol + word, a problem's with how long it has stood."""
    cut = cut_off(state, b)
    word, style = ("○ host unreachable", DIM) if cut else mark(txt(b.get("verdict")))
    return (f" {word} {ago(b.get('since'), now)} " if rank(b.get("verdict")) == 0 and not cut else word), style


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
            items.append((None, [Text.assemble(("     fix  ", DIM), (fix_of(state, b), BRAND), ("   c copies it", DIM))]))
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


def title_line(state: dict, width: int, now: float, live: bool, stopped: bool) -> Text:
    """`◆ claude-discord  <manager>` and, on the right, the backend's status: symbol + word + colour."""
    m, mgr = obj(state.get("monitor")), txt(state.get("manager")) or "?"
    left = Text.assemble(("◆ claude-discord", f"bold {BRAND}"), ("  " + mgr, DIM))
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


def tabs_lines(tab: str, n_open: int, width: int) -> Text:
    """The tab row: the active tab filled, and underlined `━` in brand on the rule below it."""
    row, under = Text(), Text()
    for t, label in zip(TABS, ("Bots", f"Alerts {n_open}", "Configuration")):
        row.append(f" {label} ", f"bold on {TAB}" if t == tab else DIM)
        row.append(" ")
        under.append("━" * (len(label) + 2) if t == tab else "─" * (len(label) + 2), BRAND if t == tab else TAB)
        under.append("─", TAB)
    under.append("─" * max(0, width - under.cell_len), TAB)
    return Text("\n").join([row, under])


def foot_line(tab: str, width: int = WIDE) -> Text:
    """The keys of a tab. The Bots tab's are 85 cells: below WIDE two labels are shorter, so all six keys fit in 80."""
    fields, copy = ("all fields", "copy fix") if width >= WIDE else ("fields", "copy")
    keys = {"bots": (("↑↓", "select"), ("space", "expand"), ("enter", fields), ("c", copy), ("←→", "tabs"), ("q", "quit")),
            "alerts": (("↑↓", "select"), ("enter", "the post's text"), ("←→", "tabs"), ("q", "quit")),
            "config": (("←→", "tabs"), ("↑↓", "select"), ("enter", "all fields"), ("a", "add host"), ("q", "quit"))}[tab]
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


def load_names(state: dict) -> dict:
    """id -> display name, from the `user-names` file of every bot on this machine (written by on-prompt: `<id> <name>`).
    A remote bot's file is out of reach, so its ids get a name only when that person wrote to a local bot too."""
    names = {}
    for b in obj(state.get("bots")).values():
        b = obj(b)
        bot, project = txt(b.get("bot")), txt(b.get("project"))
        if b.get("host") != "local" or not bot or not project:
            continue
        try:
            text = (Path(project) / ".claude" / "discord-agents" / bot / "user-names").read_text(errors="replace")
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

    def __init__(self, body: str, fix: str | None = None) -> None:
        super().__init__()
        self.body, self.fix = body, fix

    def compose(self) -> ComposeResult:
        with VerticalScroll():
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


def config_items(state: dict, names: dict, width: int) -> list[tuple]:
    """The Configuration tab, read-only: the ledger's hosts as the last pass saw them, and the monitor's settings."""
    wide = width >= WIDE
    cols = ([("host", 12), ("ssh target", 0), ("kind", 7)] + ([("env", 16)] if wide else []) + [("reach", 14)]
            + ([("claude-discord", 15)] if wide else []) + [("bots", 4)])
    cols[1] = ("ssh target", max(10, width - 2 - sum(w for _, w in cols) - len(cols) + 1))
    bots, m, mgr = obj(state.get("bots")), obj(state.get("monitor")), txt(state.get("manager")) or "?"
    hosts = sorted(obj(state.get("hosts")).items(), key=lambda kh: (kh[0] != "local", kh[0]))   # this machine first
    add = Text.assemble((" + Add host ", f"bold #000000 on {BRAND}"), ("    a · from ~/.ssh/config and its Includes, or an ssh alias typed in", DIM))
    items: list[tuple] = [(None, [rule("Hosts", len(hosts), "", width), Text(), add, Text()]), (None, row_lines([([(n, f"bold {DIM}")], w) for n, w in cols]))]
    for key, h in hosts:
        h = obj(h)
        v, name, env = txt(h.get("verdict")), txt(h.get("hostname")), ids(h.get("env"))
        reach = ("● ok", OK) if v == "ok" else ("○ unreachable", DIM) if v == "hostdown" else (f"▲ {v or '?'}", WARN)
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
# blocks and on the candidates; each file once (a cycle of Includes ends there); only a regular file is opened (a FIFO would block).
ALIAS = re.compile(r"[A-Za-z0-9._@][A-Za-z0-9._@-]{0,254}")   # what `claude-discord hosts add` takes as an ssh alias
SSH_MAX_FILES, SSH_MAX_BYTES, SSH_MAX_DEPTH, SSH_MAX_BLOCKS, SSH_MAX_HOSTS = 32, 1 << 18, 8, 2000, 500


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
    rx = lambda p: re.compile(".*".join(".".join(map(re.escape, part.split("?"))) for part in p.split("*")))
    matchers = [([rx(p) for p in pats if not p.startswith("!")], [rx(p[1:]) for p in pats if p.startswith("!")], opts) for pats, opts in blocks]
    hosts: dict = {}
    for pats, _ in blocks:
        for alias in pats:
            if alias in hosts or len(hosts) >= SSH_MAX_HOSTS or not ALIAS.fullmatch(alias):
                continue
            h = {"alias": alias}
            for yes, no, opts in matchers:
                if any(r.fullmatch(alias) for r in yes) and not any(r.fullmatch(alias) for r in no):
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


def run_capped(argv: list, cap: float, stdin: str | None = None) -> tuple[int, str, str]:
    """A command run to its end, or to `cap` seconds, when its whole process group is killed (a child of it that hangs
    would otherwise keep the pipes open and this call with them): (exit status, stdout, stderr). 124 for the cap, 127
    when it cannot be started. Each stream is cut at 64 KiB and cleaned of what must not be drawn; its line breaks
    stay. `stdin` is how a value travels to the command: never in its argument list."""
    try:
        p = subprocess.Popen(argv, stdin=subprocess.DEVNULL if stdin is None else subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, start_new_session=True)
    except OSError as e:
        return 127, "", f"cannot run {argv[0]}: {e.strerror or e}"
    try:
        out, err = p.communicate(None if stdin is None else stdin.encode(), timeout=cap)
        rc = p.returncode
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
        out, err = p.communicate()
        rc, err = 124, err + f"\nno answer within {cap:g} s".encode()
    return (rc, *(clean(b[:65536].decode("utf-8", "replace"), UNSAFE_NL).strip() for b in (out, err)))


def ssh_effective(ssh: str, alias: str) -> list[str]:
    """`ssh -G -- <alias>`: what ssh itself will use for the ONE alias the user chose, the lines that say where a
    connection goes and through what. Never run for a candidate while searching: evaluating the configuration can run
    a `Match exec` command, which is also why it gets 5 s and no more."""
    rc, out, err = run_capped([ssh, "-G", "--", alias], 5)
    lines = [l for l in out.splitlines() if l.split(" ", 1)[0] in ("hostname", "user", "port", "proxyjump", "proxycommand")]
    return lines or [f"nothing (exit {rc}" + (f": {err.splitlines()[-1]})" if err else ")")]


class AddHost(ModalScreen):
    """`a` on the Configuration tab: a search over the Host aliases of ~/.ssh/config (ssh_hosts), or an alias typed in.
    Enter on a candidate shows the check `hosts add` runs first (the line its --dry-run prints) and what `ssh -G` says
    of that one alias; a second Enter runs `hosts add`; after a host that did not answer (exit 5) a third adds it
    unchecked. Every call runs in a worker thread, so a probe that takes its whole cap leaves the screen alive.
    Dismissed with what there is to say, or None."""
    CSS = f"""AddHost {{ align: center middle; }}
    #add {{ width: 104; max-width: 96%; height: auto; border: round {BRAND}; padding: 1 2; }}
    #cands {{ height: auto; margin: 1 0; }} #info {{ height: auto; }}"""
    BINDINGS = [Binding("escape", "cancel", "cancel"), Binding("up", "move(-1)"), Binding("down", "move(1)")]
    ROWS = 8   # candidates drawn at once

    def __init__(self, hosts: list[dict], listed: set) -> None:
        super().__init__()
        self.hosts, self.listed = hosts, listed   # the candidates of ~/.ssh/config; the aliases the last pass checked
        self.found: list[dict] = []
        self.at = 0
        self.step, self.alias = "search", ""      # search -> shown -> (running) -> failed; the alias the last Enter chose

    def compose(self) -> ComposeResult:
        with Vertical(id="add"):
            yield Static(Text.assemble(("Add a host", f"bold {BRAND}"), ("    from ~/.ssh/config and its Includes", DIM)))
            yield Input(placeholder="search, or type an ssh alias", id="q")
            yield Static("", id="cands")
            yield Static("", id="info", markup=False)

    def on_mount(self) -> None:
        self.query_one("#q", Input).focus()
        self.search("")

    def say(self, text: str, style: str = DIM) -> None:
        self.query_one("#info", Static).update(Text(text, style))

    def search(self, query: str) -> None:
        self.step, self.at = "search", 0
        self.found = fuzzy(query, self.hosts)
        if ALIAS.fullmatch(query) and all(h["alias"] != query for h in self.found):   # an alias the configuration does not name
            self.found.append({"alias": query, "typed": True})
        self.say("enter shows the check that runs first · esc cancel" if self.found else
                 "no Host alias here: type the ssh alias to add (letters, digits and . _ @ - only, not starting with -)")
        self.paint()

    def paint(self) -> None:
        n = sum(1 for h in self.found if not h.get("typed"))   # the alias as typed is the last row, and no match
        top = max(0, min(self.at - self.ROWS // 2, len(self.found) - self.ROWS))
        w = min(28, max([8] + [cell_len(h["alias"]) for h in self.found]))
        lines = [Text(f"{n} match{'' if n == 1 else 'es'}", DIM)]
        for i, h in list(enumerate(self.found))[top:top + self.ROWS]:
            note = "as typed: not in ~/.ssh/config" if h.get("typed") else ssh_target(h)
            line = Text.assemble("▸ " if i == self.at else "  ", (fit(h["alias"], w), "bold"), "  ",
                                 (note + ("   already checked" if h["alias"] in self.listed else ""), DIM))
            if i == self.at:
                line.stylize(f"on {CURSOR}")
            lines.append(line)
        self.query_one("#cands", Static).update(Text("\n").join(lines))

    def on_input_changed(self, event: Input.Changed) -> None:
        self.search(event.value.strip())

    def action_move(self, d: int) -> None:
        if self.step == "search" and self.found:
            self.at = max(0, min(len(self.found) - 1, self.at + d))
            self.paint()

    def action_cancel(self) -> None:
        self.dismiss(None)

    def on_input_submitted(self, event: Input.Submitted) -> None:
        cli, ssh, alias = self.app.hosts_cli, self.app.ssh, self.alias
        if self.step == "search" and self.found:
            alias = self.alias = self.found[self.at]["alias"]
            self.run("shown", f"asking what would run for {alias} ...", lambda: (cli("add", "--dry-run", alias), ssh_effective(ssh, alias)))
        elif self.step == "shown":
            self.run("added", f"checking {alias} ...", lambda: (cli("add", alias), None))
        elif self.step == "failed":
            self.run("added", f"adding {alias} unchecked ...", lambda: (cli("add", "--no-probe", alias), None))

    def run(self, then: str, saying: str, call) -> None:
        """`call` in a worker thread, its result to `ran` on the event loop; no key but escape does anything meanwhile."""
        self.step = "running"
        self.say(saying)
        self.query_one("#q", Input).disabled = True
        self.run_worker(lambda: self.app.call_from_thread(self.ran, then, *call()), thread=True)

    def ran(self, then: str, answer: tuple, effective: list | None) -> None:
        if not self.is_attached:   # escape meanwhile
            return
        rc, out, err = answer
        q = self.query_one("#q", Input)
        q.disabled = False
        q.focus()
        if then == "shown" and rc == 0:
            self.step = "shown"
            self.say(f"enter checks it first:  {out}\nssh -G {self.alias} says:  {' · '.join(effective or [])}\n"
                     "refused if it is the same home as a listed host; warns if another manager watches it.   esc cancel", "")
        elif then == "added" and rc == 0:
            self.dismiss("\n".join(x for x in (out, err) if x))
        elif then == "added" and rc == 5:   # it did not answer, or has no claude-discord: the CLI named --no-probe
            self.step = "failed"
            self.say(f"{err}\nenter adds it unchecked (hosts add --no-probe) · esc cancel", WARN)
        else:
            self.step = "search"
            self.say(err or f"claude-discord hosts exited {rc}", ALERT)


class Confirm(ModalScreen[bool]):
    """A yes/no question, No by default (focused, and Enter, n and Escape answer it)."""
    CSS = "Confirm { align: center middle; } #confirm { width: 70; height: auto; border: thick $error; padding: 1 2; }"
    BINDINGS = [Binding("y", "answer(True)", "yes"), Binding("n", "answer(False)", "no"), Binding("escape", "answer(False)", "no")]

    def __init__(self, text: str) -> None:
        super().__init__()
        self.text = text

    def compose(self) -> ComposeResult:
        with Vertical(id="confirm"):
            yield Static(self.text, markup=False)
            with Horizontal():
                yield Button("No", id="no")
                yield Button("Yes", id="yes", variant="error")

    def on_mount(self) -> None:
        self.query_one("#no", Button).focus()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        self.dismiss(event.button.id == "yes")

    def action_answer(self, yes: bool) -> None:
        self.dismiss(yes)


class Pane(VerticalScroll, can_focus=False):
    """The tab's body. Never focused: the arrow keys move the row cursor (the app's bindings), not the scroll position."""


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
                Binding("space", "toggle"), Binding("enter", "open"), Binding("c", "copy"), Binding("a", "add")]

    def __init__(self, state_dir: Path, bot: str, wrapper: str | None) -> None:
        super().__init__()
        self.state_dir, self.bot, self.wrapper = state_dir, bot, wrapper
        self.home, self.ssh = Path.home(), "ssh"   # where ~/.ssh/config is, and the ssh that `ssh -G` runs (the tests set both)
        self.state: dict = {}
        self.names: dict = {}
        self.note = ""   # why `monitor --ensure` failed, shown in the red bar
        self.mtime: float | None = None
        self.ensured = float("-inf")   # when `monitor --ensure` last ran (time.monotonic())
        self.holder = state_dir / "holders" / f"tui-{os.getpid()}"
        self.width = 0   # the terminal's: set at mount, then by each Resize (self.size still holds the old one while that event runs)
        self.tab = "bots"
        self.cursor: dict = {t: None for t in TABS}   # the selected row's key, per tab
        self.opened: set = set()                      # the expanded bot rows
        self.shown: dict = {}                         # widget id -> the Text it shows: an update only when it changes

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
        self.show("#title", title_line(self.state, w, now, live, stopped))
        self.show("#tabs", tabs_lines(self.tab, len(open_alerts(self.state)), w))
        bar = bar_text(self.state, self.note, stopped, self.refused())
        b = self.query_one("#bar", Static)
        b.update(bar or "")
        b.set_class(bar is None, "hidden")
        items = self.items(now)
        keys = [k for k, _ in items if k is not None]
        if self.cursor[self.tab] not in keys:   # the row left the state (or nothing was selected yet): the first one
            self.cursor[self.tab] = keys[0] if keys else None
        text, y, h = render(items, self.cursor[self.tab], w)
        if self.show("#body", text):
            self.query_one("#pane", Pane).scroll_to_region(Region(0, y, 1, h), animate=False, force=True)
        self.show("#foot", foot_line(self.tab, w))

    def on_resize(self, event: Resize) -> None:
        self.width = event.size.width
        self.paint()

    def check_action(self, action: str, parameters: tuple) -> bool | None:
        # The row keys belong to the main view: under a Detail or a dialog they do nothing.
        return len(self.screen_stack) == 1 or action not in ("move", "tab", "toggle", "open", "copy", "add")

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
        entry = obj(obj(self.state.get(scope)).get(key))
        # A host's posts are keyed host|- in `alerts`; a bot's and a project row's by their own key.
        self.push_screen(Detail(entry_text(key, key + "|-" if scope == "hosts" else key, with_mode(entry) if scope == "bots" else entry, alerts),
                                txt(entry.get("fix"))))

    def action_copy(self) -> None:
        fix = fix_of(self.state, obj(obj(self.state.get("bots")).get(self.cursor["bots"] or ""))) if self.tab == "bots" else ""
        if fix:   # only what the row shows as its fix line
            self.copy_to_clipboard(fix)   # OSC 52: the terminal's clipboard, over ssh too
            self.notify("fix copied (if your terminal allows it)")   # OSC 52 has no answer, and not every terminal takes it

    def hosts_cli(self, *args: str, stdin: str | None = None) -> tuple[int, str, str]:
        """`claude-discord hosts --bot <bot> <args>` from the manager's project (the TUI's own cwd): the one way this
        program reads or changes the ledger. 90 s at most: the CLI caps each of its ssh calls at 20 s itself."""
        if not self.wrapper:
            return 127, "", "started without the wrapper (--claude-discord): the ledger cannot be changed from here"
        return run_capped([self.wrapper, "hosts", "--bot", self.bot, *args], 90, stdin)

    def said(self, text: str | None) -> None:
        """What a dialog was dismissed with: the CLI's own words, shown as they are (never as markup)."""
        if text:
            self.notify(text, timeout=10, markup=False)

    def action_add(self) -> None:
        if self.tab == "config":
            listed = {k for k, h in obj(self.state.get("hosts")).items() if obj(h).get("left_s") is None}
            self.push_screen(AddHost(ssh_hosts(self.home), listed), self.said)

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
    a = p.parse_args()
    MonitorTUI(a.state_dir, a.bot, a.claude_discord).run()


if __name__ == "__main__":
    main()
