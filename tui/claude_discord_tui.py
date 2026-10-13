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
import json
import os
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

from rich.cells import cell_len, set_cell_size
from rich.text import Text
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.events import Resize
from textual.geometry import Region
from textual.screen import ModalScreen, Screen
from textual.widgets import Button, Footer, Static

# The slack4agents pane's palette: nothing saturated but an alert.
BRAND, WARN, OK, ALERT, BAR, TAB, CURSOR = "#5fd7ff", "#ffaf00", "#87d787", "#ff5f87", "#3a3a3a", "#585858", "#4e4e4e"
DIM = "dim"    # the terminal's own dim, as the pane's dimColor
DASH = "-"     # a value the state does not have: an older claude-discord on that host, or nothing to show
WIDE = 110     # below it the KPI band is one line and the table's project, receives and env columns fold away
TABS = ("bots", "alerts", "config")
PROBLEM = ("down", "stale", "duplicate", "unreachable")
GOOD = ("busy", "ok")
WORD = {"down": "DOWN", "stale": "STUCK", "duplicate": "DUPLICATE", "unreachable": "UNREACHABLE", "throttled": "rate-limited",
        "apierror": "api error", "nostate": "no state", "blind": "blind", "noreach": "no network", "busy": "working", "ok": "ok",
        "unknown": "no token"}


def load(path: Path) -> dict:
    try:
        data = json.loads(path.read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


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


def hhmm(t: float | None) -> str:
    return time.strftime("%H:%M", time.localtime(t)) if t is not None else DASH


def fit(s: str, w: int) -> str:
    """`s` in exactly `w` terminal cells (a Hangul or CJK character takes two): padded, or cut with an ellipsis."""
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
    h = (state.get("hosts") or {}).get(host) or {}
    return h.get("display") or h.get("name") or host or DASH


def sorted_bots(state: dict) -> list[tuple[str, dict]]:
    """(key, entry) for the Bots tab: problems, then what needs a look, then healthy, then no token; by key within each.
    A host|project|- entry (a project whose health crashed before any bot of it was known) has no `bot`: a row with bot '-'."""
    return sorted(((k, b) for k, b in (state.get("bots") or {}).items() if isinstance(b, dict)),
                  key=lambda kv: (rank(kv[1].get("verdict", "")), kv[0]))


def kpi(state: dict) -> dict:
    """The numbers of the KPI band. The denominator is every bot; a bot with no token is counted apart, not as a problem."""
    rows = [b for _, b in sorted_bots(state)]
    by = [[b for b in rows if rank(b.get("verdict", "")) == r] for r in range(4)]
    hosts = [(k, h) for k, h in sorted((state.get("hosts") or {}).items()) if h.get("left_s") is None]
    bad = [k for k, h in hosts if h.get("reach") != "ok"]
    first = lambda bs: (bs[0].get("bot") or DASH) if bs else ""
    return {"problems": len(by[0]), "look": len(by[1]), "healthy": sum(1 for b in by[2] if b.get("bot")), "notoken": len(by[3]),
            "bots": sum(1 for b in rows if b.get("bot")), "first_problem": first(by[0]),
            "problem_word": WORD.get(by[0][0].get("verdict", ""), "").lower() if by[0] else "", "first_look": first(by[1]),
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


def columns(width: int) -> list[tuple[str, int]]:
    """The Bots table's columns and their widths in cells: 110 in all at WIDE (status holds `not posted (warning only)`),
    the room past it shared by channel, receives and project; below WIDE project and receives fold away and channel
    takes what is left."""
    if width >= WIDE:
        extra = width - WIDE
        return [("bot", 16), ("status", 25), ("host", 9), ("channel", 18 + extra // 3), ("receives", 20 + extra // 3),
                ("last", 5), ("project", 9 + extra - 2 * (extra // 3))]
    return [("bot", 16), ("status", 25), ("host", 9), ("channel", max(8, width - 62)), ("last", 5)]


def channels(b: dict, manager: str, w: int, opened: bool) -> list[str]:
    """The channel column: the bot's channel; open, every channel of its access groups (a name is known for the main one
    only) and, for the manager bot, the alert channel it only writes to."""
    ch = b.get("channel")
    if not ch:
        return [DASH]
    main = "#" + (b.get("channel_name") or ch)
    if not opened:
        return [main]
    acc = b.get("access") if isinstance(b.get("access"), dict) else {}
    others = ["#" + str(g.get("id")) for g in acc.get("groups") or [] if g.get("id") != ch]
    wo = ["#bot-health-check (write-only)"] if b.get("bot") == manager and b.get("host") == "local" else []
    out = []
    for line in [main + (" (main)" if others or wo else "")] + others + wo:   # a note that does not fit goes under its channel
        out += [line] if cell_len(line) <= w or " (" not in line else [line[:line.rindex(" (")], "  " + line[line.rindex(" (") + 1:]]
    return out


def receives(b: dict, names: dict, w: int, opened: bool) -> list[str]:
    """The receives column, from the access group of the bot's channel: one line; open, the mention rule, who may write
    (names from user-names, ids when unknown, `+N` past the room) and the DM policy."""
    acc = b.get("access") if isinstance(b.get("access"), dict) else {}
    grp = next((g for g in acc.get("groups") or [] if g.get("id") == b.get("channel")), None)
    if not grp:
        return [DASH]
    allow = [names.get(i, i) for i in grp.get("allow") or []]
    rule = "@mention" if grp.get("mention", True) else "any message"
    if not opened:
        return [f"{rule} · {'anyone' if not allow else '1 user' if len(allow) == 1 else f'{len(allow)} users'}"]
    dms = [names.get(i, i) for i in acc.get("dm_allow") or []]
    dm = acc.get("dm")
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
            line.append(fit(s, w), style)
        out.append(line)
    return out


def bots_items(state: dict, names: dict, width: int, opened: set, now: float) -> list[tuple]:
    """The Bots tab as (row key or None, [Text, ...]) items: a key makes its lines one row the cursor can sit on."""
    cols = columns(width)
    items: list[tuple] = [(None, kpi_lines(state, width) + [Text()]),
                         (None, row_lines([([(n, f"bold {DIM}")], w) for n, w in cols]))]
    for key, b in sorted_bots(state):
        o, v, r = key in opened, b.get("verdict", ""), rank(b.get("verdict", ""))
        word, style = mark(v)
        status = [(f" {word} {ago(b.get('since'), now)} " if r == 0 else word, style)]
        if o:
            status += [(s, "") for s in wrap(b.get("detail") or "", dict(cols)["status"], 3)]
            if r < 2:   # warning only: the monitor recorded this verdict in `alerts` as one it does not post when it appears
                quiet = any(a.get("key") == key and a.get("status") == "not_posted" and a.get("verdict") == v for a in state.get("alerts") or [])
                status.append((f"posted {ago(b.get('posted_at'), now)} ago" if b.get("posted") else
                               "not posted (warning only)" if quiet else "not posted yet", DIM))
        project = b.get("project") or ""
        cell = {"bot": [(b.get("bot") or DASH, "bold")], "status": status, "host": [(host_label(state, b.get("host", "")), DIM)],
                "channel": [(s, "") for s in channels(b, state.get("manager", ""), dict(cols)["channel"], o)],
                "receives": [(s, "" if i == 0 or not o else DIM if s.startswith("DMs") else "")
                             for i, s in enumerate(receives(b, names, dict(cols).get("receives", 0), o))],
                "last": [((ago(b.get("last_message_at"), now) or DASH).rjust(5), DIM)],
                "project": [("~" if project and project == b.get("home") else project.rstrip("/").rsplit("/", 1)[-1] or DASH, DIM)]}
        items.append((key, row_lines([(cell[n], w) for n, w in cols], "▾ " if o else "▸ ")))
        if r == 0 and b.get("fix"):   # one full-width line, never wrapped into a column, so it selects and copies whole
            items.append((None, [Text.assemble(("     fix  ", DIM), (b["fix"], BRAND), ("   c copies it", DIM))]))
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
    of the last finding sent for its key, when that record is still kept), newest first."""
    out, alerts = [], state.get("alerts") or []
    for scope in ("hosts", "bots"):
        for k, e in (state.get(scope) or {}).items():
            if e.get("posted") and e.get("left_s") is None:
                key = k + "|-" if scope == "hosts" else k
                out.append({"ts": e.get("posted_at"), "key": key, "kind": "finding", "verdict": e["posted"], "status": "sent", "detail": e.get("detail", ""),
                            "text": next((x.get("text") for x in reversed(alerts) if x.get("key") == key and x.get("kind") == "finding"
                                          and x.get("status") == "sent"), None)})
    return sorted(out, key=lambda a: a.get("ts") or "", reverse=True)


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
    m, mgr = state.get("monitor") or {}, state.get("manager", "?")
    left = Text.assemble(("◆ claude-discord", f"bold {BRAND}"), ("  " + mgr, DIM))
    due = epoch(m.get("next_pass"))
    if stopped or m.get("stopped_by_user"):   # monitor --stop: nothing starts it until monitor --start
        right = Text.assemble(("○ stopped by you", "bold"), ("  start: ", DIM), (f"claude-discord monitor --start {mgr}", BRAND))
    elif not live:
        right = Text("○ not running", DIM)
    elif due is not None and now - due > 30:   # more than one tick (30 s) past the pass that was due
        right = Text.assemble(("▲ check overdue", f"bold {WARN}"), (f"  due {hhmm(due)} · now {hhmm(now)}", DIM))
    else:
        checked = ago(m.get("last_pass"), now)
        nxt = max(0, int(due - now) + 59) // 60 if due is not None else None
        right = Text.assemble(("● live", f"bold {OK}"), ("  " + " · ".join(
            (["keeper"] if any(h.get("kind") == "keeper" for h in m.get("holders") or []) else [])
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


def foot_line(tab: str) -> Text:
    keys = {"bots": (("↑↓", "select"), ("space", "expand"), ("enter", "all fields"), ("c", "copy fix"), ("←→", "tabs"), ("q", "quit")),
            "alerts": (("↑↓", "select"), ("enter", "the post's text"), ("←→", "tabs"), ("q", "quit")),
            "config": (("←→", "tabs"), ("↑↓", "select"), ("enter", "all fields"), ("q", "quit"))}[tab]
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
    m = state.get("monitor") or {}
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
    for b in (state.get("bots") or {}).values():
        if b.get("host") != "local" or not b.get("bot") or not b.get("project"):
            continue
        try:
            text = (Path(b["project"]) / ".claude" / "discord-agents" / b["bot"] / "user-names").read_text(errors="replace")
        except OSError:
            continue
        for line in text.splitlines():
            uid, _, name = line.partition(" ")
            if uid.isdigit() and name:
                names[uid] = name
    return names


def entry_text(key: str, akey: str, entry: dict, alerts: list) -> str:
    """Every raw field of a bot or host entry, then the posts for its key."""
    fields = "\n".join(f"{k:<16} {v if isinstance(v, str) else json.dumps(v, ensure_ascii=False)}" for k, v in sorted(entry.items()) if k != "fix")
    mine = [a for a in alerts if a.get("key") == akey]
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
                Binding("space", "toggle"), Binding("enter", "open"), Binding("c", "copy")]

    def __init__(self, state_dir: Path, bot: str, wrapper: str | None) -> None:
        super().__init__()
        self.state_dir, self.bot, self.wrapper = state_dir, bot, wrapper
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
        pid = (self.state.get("monitor") or {}).get("pid")
        if self.wrapper and not self.stopped() and not alive(pid, self.bot) and time.monotonic() - self.ensured >= 30:
            self.ensure()
        self.paint()

    def items(self, now: float) -> list[tuple]:
        w = self.width
        if self.tab == "bots":
            return bots_items(self.state, self.names, w, self.opened, now)
        return []

    def show(self, wid: str, text: Text) -> bool:
        """Updates a widget only when its text changed: a repaint every 2 s would drop a mouse selection each time."""
        if self.shown.get(wid) == text:
            return False
        self.shown[wid] = text
        self.query_one(wid, Static).update(text)
        return True

    def paint(self) -> None:
        now, w, stopped = time.time(), self.width, self.stopped() is not None
        live = alive((self.state.get("monitor") or {}).get("pid"), self.bot)
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
        self.show("#foot", foot_line(self.tab))

    def on_resize(self, event: Resize) -> None:
        self.width = event.size.width
        self.paint()

    def check_action(self, action: str, parameters: tuple) -> bool | None:
        # The row keys belong to the main view: under a Detail or a dialog they do nothing.
        return len(self.screen_stack) == 1 or action not in ("move", "tab", "toggle", "open", "copy")

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
        key, alerts = self.cursor[self.tab], self.state.get("alerts") or []
        if key is None:
            return
        scope = "bots" if self.tab == "bots" else "hosts"
        entry = (self.state.get(scope) or {}).get(key) or {}
        # A host's posts are keyed host|- in `alerts`; a bot's and a project row's by their own key.
        self.push_screen(Detail(entry_text(key, key + "|-" if scope == "hosts" else key, entry, alerts), entry.get("fix") or ""))

    def action_copy(self) -> None:
        fix = ((self.state.get("bots") or {}).get(self.cursor["bots"] or "") or {}).get("fix") if self.tab == "bots" else None
        if fix:
            self.copy_to_clipboard(fix)   # OSC 52: the terminal's clipboard, over ssh too
            self.notify("fix copied")

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
