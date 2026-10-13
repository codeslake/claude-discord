# /// script
# requires-python = ">=3.9"
# dependencies = ["textual>=8.2.8,<9"]
# ///
"""claude-discord tui: a read-only view of a manager bot's backend monitor.

Started by `claude-discord tui [<bot>]` through `uv run --script`. It registers
itself as a holder of the monitor (which starts the monitor if none runs),
re-reads state.json when its mtime changes (checked every 2 s) and removes its
holder record on quit. It changes nothing else: no restart, no post, no patch,
and it never reads a .env, so it cannot show a token.
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
from textual.screen import ModalScreen, Screen
from textual.widgets import Button, DataTable, Footer, Static

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


def short(project: str, home: str) -> str:
    return "~" + project[len(home):] if home and project.startswith(home + "/") else project


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


def header_lines(state: dict, note: str = "", stopped: str | None = None, refused: bool = False) -> tuple[str, str | None]:
    """The header text and the red bar's text (None when there is nothing to warn about). `note` is why
    `monitor --ensure` failed, when it did: the one place a refusal is visible. `stopped`: when the `stopped` marker
    (monitor --stop) was left, if it stands. `refused`: this side's `refused.<pid namespace id>` marker (a detached start met a monitor lock this
    side cannot see; a start that gets through clears it) stands."""
    m = state.get("monitor") or {}
    holders = ", ".join(f"{h.get('kind')} {h.get('pid')}" for h in m.get("holders") or []) or "none"
    pid = m.get("pid")
    text = (f"manager {state.get('manager', '?')}   monitor pid {pid if pid else '-'}   holders {holders}\n"
            f"last pass {m.get('last_pass') or '-'}   next pass {m.get('next_pass') or '-'}   pass took {m.get('pass_s', '-')}s")
    if any(h.get("kind") == "keeper" for h in m.get("holders") or []):   # why quitting leaves the monitor running
        text += f"\nthe backend runs on after q; Q quits and stops it (claude-discord monitor --stop {state.get('manager', '?')})"
    bar = None
    if not state:
        bar = "no state yet: the monitor has not written state.json"
    elif stopped is not None or m.get("stopped_by_user"):   # monitor --stop: nothing starts it until monitor --start
        bar = (f"stopped by you{' at ' + stopped if stopped else ''} (monitor --stop); "
               f"start it again: claude-discord monitor --start {state.get('manager', '?')}")
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
    return text, bar


def bot_rows(state: dict) -> list[tuple[str, tuple]]:
    """(key, row) for the bots table, findings first, then by key. A host|project|- entry (a project whose
    health crashed before any bot of it was known) has no `bot`: it is a project row, shown with bot '-'."""
    bots = state.get("bots") or {}
    rows = []
    for key, b in sorted(bots.items(), key=lambda kv: (kv[1].get("verdict") in GOOD, kv[0])):
        rows.append((key, (b.get("name") or b.get("host", ""), short(b.get("project", ""), b.get("home", "")),
                           b.get("bot") or "-", b.get("verdict", ""), ago(b.get("since"), time.time()),
                           b.get("servers", ""), b.get("detail", ""))))
    return rows


def host_rows(state: dict) -> list[tuple[str, tuple]]:
    bots = state.get("bots") or {}
    rows = []
    for key, h in sorted((state.get("hosts") or {}).items()):
        mine = [b for b in bots.values() if b.get("host") == key and b.get("bot")]   # project rows are not bots
        ok = sum(1 for b in mine if b.get("verdict") in GOOD)
        label = h.get("name") or key
        if h.get("laptop"):
            label += " (laptop)"
        if h.get("left_s") is not None:   # out of the ledger, kept for a day so a brief removal does not post again
            label += " (left the ledger)"
        rows.append((key, (label, h.get("reach", ""), h.get("patch", ""), h.get("version", ""),
                           f"{ok}/{len(mine)}", h.get("checked", ""))))
    return rows


class Detail(Screen):
    BINDINGS = [Binding("escape", "app.pop_screen", "back")]

    def __init__(self, key: str, alert_key: str, entry: dict, alerts: list) -> None:
        super().__init__()
        self.key, self.alert_key, self.entry, self.alerts = key, alert_key, entry, alerts

    def compose(self) -> ComposeResult:
        e = self.entry
        lines = [f"{self.key}", "", f"verdict  {e.get('verdict', '')} (since {e.get('since', '?')})",
                 f"detail   {e.get('detail', '')}", f"posted   {e.get('posted') or '-'}", "", "recovery command:"]
        with VerticalScroll():
            yield Static("\n".join(lines), markup=False)   # state-derived text: [..] in it is text, not markup
            yield Static(e.get("fix") or "(none)", id="fix", markup=False)   # its own widget so the text can be selected and copied
            mine = [a for a in self.alerts if a.get("key") == self.alert_key]
            yield Static("\nposts for this key:\n" + ("\n".join(
                f"{a.get('ts')}  {a.get('kind')}  {a.get('verdict')}  {a.get('status')}" for a in mine) or "(none)"), markup=False)
        yield Footer()


class Alerts(Screen):
    BINDINGS = [Binding("escape", "app.pop_screen", "back"), Binding("a", "app.pop_screen", "back")]

    def __init__(self, alerts: list) -> None:
        super().__init__()
        self.alerts = alerts

    def compose(self) -> ComposeResult:
        t = DataTable(id="alerts")
        t.add_columns("time", "key", "kind", "verdict", "status")
        for a in reversed(self.alerts):
            t.add_row(*(Text(str(a.get(k, ""))) for k in ("ts", "key", "kind", "verdict", "status")))
        yield t
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


class MonitorTUI(App):
    TITLE = "claude-discord monitor"
    CSS = "#bar { background: darkred; color: white; } #bar.hidden { display: none; }"
    BINDINGS = [Binding("q", "quit", "quit"), Binding("Q", "quit_stop", "quit + stop backend"), Binding("a", "alerts", "alerts")]

    def __init__(self, state_dir: Path, bot: str, wrapper: str | None) -> None:
        super().__init__()
        self.state_dir, self.bot, self.wrapper = state_dir, bot, wrapper
        self.state: dict = {}
        self.note = ""   # why `monitor --ensure` failed, shown in the red bar
        self.mtime: float | None = None
        self.ensured = float("-inf")   # when `monitor --ensure` last ran (time.monotonic())
        self.holder = state_dir / "holders" / f"tui-{os.getpid()}"

    def compose(self) -> ComposeResult:
        yield Static("", id="head", markup=False)
        yield Static("", id="bar", classes="hidden", markup=False)
        hosts = DataTable(id="hosts", cursor_type="row")
        hosts.add_columns("host", "reach", "patch", "claude-discord", "bots ok", "checked")
        bots = DataTable(id="bots", cursor_type="row")
        bots.add_columns("host", "project", "bot", "verdict", "for", "servers", "detail")
        yield hosts
        yield bots
        yield Footer()

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
        self.refresh_state()   # No: read-only, the bar says stopped by you

    def on_mount(self) -> None:
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
        changed = mtime is None or mtime != self.mtime
        if changed:
            self.mtime = mtime
            self.state = load(path)
        # Checked on every refresh, not only on a new state.json: a monitor that died without its trap writes none.
        pid = (self.state.get("monitor") or {}).get("pid")
        stopped = self.stopped()
        if self.wrapper and not stopped and not alive(pid, self.bot) and time.monotonic() - self.ensured >= 30:
            self.ensure()
        text, bar = header_lines(self.state, self.note, stopped, self.refused())
        self.query_one("#head", Static).update(text)
        b = self.query_one("#bar", Static)
        b.update(bar or "")
        b.set_class(bar is None, "hidden")
        if not changed:
            return
        for table_id, rows in (("#hosts", host_rows(self.state)), ("#bots", bot_rows(self.state))):
            t = self.query_one(table_id, DataTable)
            # clear() resets the cursor to row 0: put it back on the same row key (once per pass otherwise).
            keep = t.ordered_rows[t.cursor_row].key if t.row_count else None
            t.clear()
            for key, row in rows:
                t.add_row(*(Text(str(c)) for c in row), key=key)   # Text: [..] in a cell is not markup
            if keep is not None and any(k == keep.value for k, _ in rows):
                t.move_cursor(row=t.get_row_index(keep))

    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        key = event.row_key.value
        scope = "hosts" if event.data_table.id == "hosts" else "bots"
        entry = (self.state.get(scope) or {}).get(key) or {}
        # A host's posts are keyed host|- in `alerts`; a bot's and a project row's by their own key.
        self.push_screen(Detail(key, key + "|-" if scope == "hosts" else key, entry, self.state.get("alerts") or []))

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

    def action_alerts(self) -> None:
        self.push_screen(Alerts(self.state.get("alerts") or []))

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
