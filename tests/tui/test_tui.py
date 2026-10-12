# /// script
# requires-python = ">=3.9"
# dependencies = ["textual>=8.2.8,<9"]
# ///
"""Pilot tests for tui/claude_discord_tui.py over fixture state files. Outside
the 40 s stub suite (it needs uv and the Textual wheel):
    uv run --script tests/tui/test_tui.py
Exit 0 and one "ok:" line per case, or the first failure."""
import asyncio
import importlib.util
import json
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("tui", ROOT / "tui" / "claude_discord_tui.py")
tui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tui)

NOW = "2026-10-11T12:00:00Z"
BASE = {"version": 1, "manager": "mgr",
        "monitor": {"pid": 123, "started": NOW, "last_pass": NOW, "next_pass": NOW, "pass_s": 2,
                    "holders": [{"kind": "tui", "pid": 456}], "post_failed": False},
        "hosts": {"local": {"host": "local", "name": "lambda", "reach": "ok", "patch": "ok", "version": "1.10.0 (abc)",
                            "verdict": "ok", "checked": NOW, "laptop": False},
                  "wmac": {"host": "wmac", "name": "wmac", "reach": "ok", "patch": "ok", "version": "1.10.0 (abc)",
                           "verdict": "ok", "checked": NOW, "laptop": True}},
        "bots": {"local|/home/u/p|RVP": {"host": "local", "name": "lambda", "project": "/home/u/p", "home": "/home/u",
                                         "bot": "RVP", "verdict": "ok", "since": NOW, "detail": "", "servers": "1"},
                 "wmac|/Users/u/p|MAC": {"host": "wmac", "name": "wmac", "project": "/Users/u/p", "home": "/Users/u",
                                         "bot": "MAC", "verdict": "ok", "since": NOW, "detail": "", "servers": "1"}},
        "alerts": []}
CRASHED = "wmac|/Users/u/q|-"


def variant(name):
    s = json.loads(json.dumps(BASE))
    if name == "findings":
        s["bots"]["wmac|/Users/u/p|MAC"].update(verdict="down", detail="no plugin server for this bot", servers="0",
                                                fix="ssh wmac 'cd ~/p && ~/.local/bin/claude-discord --bg --name MAC'")
        s["alerts"] = [{"ts": NOW, "key": "wmac|/Users/u/p|MAC", "kind": "finding", "verdict": "down", "status": "sent"}]
    elif name == "crashed_project":
        # What the monitor writes for a project whose health crashed before any bot of it was known: no `bot` field.
        s["bots"][CRASHED] = {"host": "wmac", "name": "wmac", "project": "/Users/u/q", "home": "/Users/u",
                              "owner_id": "111", "verdict": "blind", "since": NOW, "detail": "health exited 1 with no document",
                              "fix": "ssh wmac 'cd ~/q && ~/.local/bin/claude-discord health'"}
    elif name == "stopped":
        s["monitor"].update(pid=None, stopped_at=NOW, holders=[])
    elif name == "post_failed":
        s["monitor"]["post_failed"] = True
    return s


async def case(name, check):
    with tempfile.TemporaryDirectory() as d:
        (Path(d) / "holders").mkdir()
        (Path(d) / "state.json").write_text(json.dumps(variant(name)))
        app = tui.MonitorTUI(Path(d), "mgr", None)
        async with app.run_test() as pilot:
            await pilot.pause()
            await check(app, pilot)
    print(f"ok: {name}")


def text(app, sel):
    return str(app.query_one(sel).render())


def cells(table, key):
    return [str(c) for c in table.get_row(key)]


async def all_ok(app, pilot):
    assert "monitor pid 123" in text(app, "#head"), text(app, "#head")
    assert app.query_one("#bar").has_class("hidden")
    hosts = app.query_one("#hosts")
    assert hosts.row_count == 2
    assert cells(hosts, "wmac")[0] == "wmac (laptop)" and cells(hosts, "wmac")[4] == "1/1", cells(hosts, "wmac")
    # the Mac row: its server count (macOS counts through ps -ax) is shown in its own cell
    assert cells(app.query_one("#bots"), "wmac|/Users/u/p|MAC")[5] == "1", cells(app.query_one("#bots"), "wmac|/Users/u/p|MAC")


async def findings(app, pilot):
    bots = app.query_one("#bots")
    assert [str(c) for c in bots.get_row_at(0)][3] == "down", "findings first"
    assert cells(app.query_one("#hosts"), "wmac")[4] == "0/1", cells(app.query_one("#hosts"), "wmac")
    bots.focus()
    bots.move_cursor(row=0)
    await pilot.press("enter")
    await pilot.pause()
    assert isinstance(app.screen, tui.Detail)
    assert "claude-discord --bg --name MAC" in str(app.screen.query_one("#fix").render())
    await pilot.press("escape")
    await pilot.press("a")
    await pilot.pause()
    assert isinstance(app.screen, tui.Alerts) and app.screen.query_one("#alerts").row_count == 1


async def crashed_project(app, pilot):
    bots = app.query_one("#bots")
    row = [str(c) for c in bots.get_row_at(0)]
    assert row[1:4] == ["~/q", "-", "blind"], f"a project row, sorted with the findings: {row}"
    assert cells(app.query_one("#hosts"), "wmac")[4] == "1/1", "a project row is not a bot: " + str(cells(app.query_one("#hosts"), "wmac"))
    bots.focus()
    bots.move_cursor(row=0)
    await pilot.press("enter")
    await pilot.pause()
    assert isinstance(app.screen, tui.Detail) and app.screen.key == CRASHED
    assert "claude-discord health" in str(app.screen.query_one("#fix").render())


async def stopped(app, pilot):
    assert not app.query_one("#bar").has_class("hidden")
    assert f"monitor stopped at {NOW}" in text(app, "#bar")


async def post_failed(app, pilot):
    assert "POST" in text(app, "#bar")


async def main():
    await case("all_ok", all_ok)
    await case("findings", findings)
    await case("crashed_project", crashed_project)
    await case("stopped", stopped)
    await case("post_failed", post_failed)
    # q removes the holder record
    with tempfile.TemporaryDirectory() as d:
        (Path(d) / "holders").mkdir()
        (Path(d) / "state.json").write_text(json.dumps(BASE))
        app = tui.MonitorTUI(Path(d), "mgr", None)
        app.holder.write_text("x")
        async with app.run_test() as pilot:
            await pilot.press("q")
        assert not app.holder.exists(), "quit must remove the holder record"
    print("ok: quit removes its holder record")


asyncio.run(main())
