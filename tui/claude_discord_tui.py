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

from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import VerticalScroll
from textual.screen import Screen
from textual.widgets import DataTable, Footer, Static

GOOD = ("ok", "busy")


def load(path: Path) -> dict:
    try:
        data = json.loads(path.read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def ago(iso: str | None) -> str:
    """'12m', '3h', '2d' since an ISO time; '' when unknown."""
    if not iso:
        return ""
    try:
        t = datetime.strptime(iso, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return ""
    s = max(0, int(time.time() - t.timestamp()))
    return f"{s // 60}m" if s < 7200 else (f"{s // 3600}h" if s < 172800 else f"{s // 86400}d")


def short(project: str, home: str) -> str:
    return "~" + project[len(home):] if home and project.startswith(home + "/") else project


def header_lines(state: dict) -> tuple[str, str | None]:
    """The header text and the red bar's text (None when there is nothing to warn about)."""
    m = state.get("monitor") or {}
    holders = ", ".join(f"{h.get('kind')} {h.get('pid')}" for h in m.get("holders") or []) or "none"
    pid = m.get("pid")
    text = (f"manager {state.get('manager', '?')}   monitor pid {pid if pid else '-'}   holders {holders}\n"
            f"last pass {m.get('last_pass') or '-'}   next pass {m.get('next_pass') or '-'}   pass took {m.get('pass_s', '-')}s")
    bar = None
    if not state:
        bar = "no state yet: the monitor has not written state.json"
    elif not pid:
        bar = f"monitor stopped at {m.get('stopped_at') or '?'}"
    elif m.get("post_failed"):
        bar = "the last POST to #bot-health-check failed; it is retried next pass"
    return text, bar


def bot_rows(state: dict) -> list[tuple[str, tuple]]:
    """(key, row) for the bots table, findings first, then by key. A host|project|- entry (a project whose
    health crashed before any bot of it was known) has no `bot`: it is a project row, shown with bot '-'."""
    bots = state.get("bots") or {}
    rows = []
    for key, b in sorted(bots.items(), key=lambda kv: (kv[1].get("verdict") in GOOD, kv[0])):
        rows.append((key, (b.get("name") or b.get("host", ""), short(b.get("project", ""), b.get("home", "")),
                           b.get("bot") or "-", b.get("verdict", ""), ago(b.get("since")),
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
            yield Static("\n".join(lines))
            yield Static(e.get("fix") or "(none)", id="fix")   # its own widget so the text can be selected and copied
            mine = [a for a in self.alerts if a.get("key") == self.alert_key]
            yield Static("\nposts for this key:\n" + ("\n".join(
                f"{a.get('ts')}  {a.get('kind')}  {a.get('verdict')}  {a.get('status')}" for a in mine) or "(none)"))
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
            t.add_row(a.get("ts", ""), a.get("key", ""), a.get("kind", ""), a.get("verdict", ""), a.get("status", ""))
        yield t
        yield Footer()


class MonitorTUI(App):
    TITLE = "claude-discord monitor"
    CSS = "#bar { background: darkred; color: white; } #bar.hidden { display: none; }"
    BINDINGS = [Binding("q", "quit", "quit"), Binding("a", "alerts", "alerts")]

    def __init__(self, state_dir: Path, bot: str, wrapper: str | None) -> None:
        super().__init__()
        self.state_dir, self.bot, self.wrapper = state_dir, bot, wrapper
        self.state: dict = {}
        self.mtime: float | None = None
        self.holder = state_dir / "holders" / f"tui-{os.getpid()}"

    def compose(self) -> ComposeResult:
        yield Static("", id="head")
        yield Static("", id="bar", classes="hidden")
        hosts = DataTable(id="hosts", cursor_type="row")
        hosts.add_columns("host", "reach", "patch", "claude-discord", "bots ok", "checked")
        bots = DataTable(id="bots", cursor_type="row")
        bots.add_columns("host", "project", "bot", "verdict", "for", "servers", "detail")
        yield hosts
        yield bots
        yield Footer()

    def on_mount(self) -> None:
        if self.wrapper:   # the holder record and the monitor: one wrapper call, which returns at once
            subprocess.run([self.wrapper, "monitor", "--ensure", self.bot, "--holder", "tui", str(os.getpid())],
                           stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        self.refresh_state()
        self.set_interval(2, self.refresh_state)

    def refresh_state(self) -> None:
        path = self.state_dir / "state.json"
        try:
            mtime = path.stat().st_mtime
        except OSError:
            mtime = None
        if mtime is not None and mtime == self.mtime:
            return
        self.mtime = mtime
        self.state = load(path)
        text, bar = header_lines(self.state)
        self.query_one("#head", Static).update(text)
        b = self.query_one("#bar", Static)
        b.update(bar or "")
        b.set_class(bar is None, "hidden")
        for table_id, rows in (("#hosts", host_rows(self.state)), ("#bots", bot_rows(self.state))):
            t = self.query_one(table_id, DataTable)
            t.clear()
            for key, row in rows:
                t.add_row(*row, key=key)

    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        key = event.row_key.value
        scope = "hosts" if event.data_table.id == "hosts" else "bots"
        entry = (self.state.get(scope) or {}).get(key) or {}
        # A host's posts are keyed host|- in `alerts`; a bot's and a project row's by their own key.
        self.push_screen(Detail(key, key + "|-" if scope == "hosts" else key, entry, self.state.get("alerts") or []))

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
