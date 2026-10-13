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
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

os.environ["TZ"] = "UTC"   # HH:MM in the title and the Alerts tab is local time: fixed here
time.tzset()
from rich.cells import cell_len

sys.dont_write_bytecode = True   # loading the TUI by path would leave tui/__pycache__ in the repo
ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("tui", ROOT / "tui" / "claude_discord_tui.py")
tui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tui)


def iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


HANGUL = "한글봇이름이아주길어요"   # 11 characters, 22 cells
ACCESS = {"dm": "allowlist", "dm_allow": ["111"],
          "groups": [{"id": "900", "mention": True, "allow": ["111", "222", "333", "444", "555"]}, {"id": "901", "mention": False, "allow": []}]}
NAMES = {"111": "dongyong22", "222": "gpuvillain", "333": "junyong-dev-bot"}
PHOTO, MGRBOT, HBOT, OLDBOT, NOTOK = ("local|/home/u/rcps|photobot", "local|/home/u/cd|mgr", "local|/home/u/cd|" + HANGUL,
                                      "old|/home/u/p|oldbot", "local|/home/u|notok")
FIX = "cd ~/rcps && claude-discord --bg --name photobot"


def base(n=None):
    """A state as 1.11.0's monitor writes it, built from the clock (the offsets sit 20 s inside their minute): a down bot
    (posted), the manager bot working, a rate-limited bot with a Hangul name and channel, a bot on a host whose
    claude-discord is older (none of the 1.11.0 fields), and a bot with no token and no channel."""
    n = time.time() if n is None else n
    bot = lambda host, project, name, verdict, **kw: dict(
        {"host": host, "project": project, "home": "/home/u", "bot": name, "verdict": verdict, "since": iso(n - 20), "detail": "", "servers": "1"}, **kw)
    return {"version": 1, "manager": "mgr",
            "monitor": {"pid": MON.pid, "started": iso(n - 4000), "last_pass": iso(n - 80), "next_pass": iso(n + 220), "pass_s": 2,
                        "holders": [{"kind": "keeper", "pid": 789}, {"kind": "tui", "pid": 456}], "post_failed": False, "lang": "en", "owner_id": "111"},
            "hosts": {"local": {"host": "local", "name": "SECA2033001362", "hostname": "SECA2033001362", "display": "lmd79", "env": ["HTTPS_PROXY"],
                                "reach": "ok", "patch": "ok", "version": "1.11.0 (abc)", "verdict": "ok", "detail": "", "fix": "", "checked": iso(n - 80), "laptop": False},
                      "wmac": {"host": "wmac", "name": "wmac", "hostname": "SECA2033002083", "display": "", "env": [], "reach": "hostdown", "verdict": "hostdown",
                               "detail": "ssh to wmac failed (exit 255), also with ControlPath=none", "since": iso(n - 14420),
                               "fix": "ssh -o BatchMode=yes -o ConnectTimeout=8 -o ControlPath=none wmac 'echo up'", "checked": iso(n - 80), "laptop": True},
                      # a state entry written before 1.11.0: no display, env or hostname
                      "old": {"host": "old", "name": "old", "reach": "ok", "patch": "ok", "version": "1.10.5 (x)", "verdict": "ok", "checked": iso(n - 80), "laptop": False}},
            "bots": {PHOTO: bot("local", "/home/u/rcps", "photobot", "down", since=iso(n - 740), detail="no plugin server for this bot", servers="0", fix=FIX,
                                posted="down", posted_at=iso(n - 680), channel="900", channel_name="photo", access=ACCESS, last_message_at=iso(n - 740)),
                     MGRBOT: bot("local", "/home/u/cd", "mgr", "busy", detail="a turn has been in flight 3m; holding the finding",
                                 channel="900", channel_name="dev-bots", access=ACCESS, last_message_at=iso(n - 5)),
                     HBOT: bot("local", "/home/u/cd", HANGUL, "throttled", detail="Discord is rate-limiting this bot (HTTP 429); nothing can be said about it this run",
                               channel="902", channel_name="한글-채널-이름이-아주-길다", last_message_at=iso(n - 560),
                               access={"dm": "pairing", "dm_allow": [], "groups": [{"id": "902", "mention": False, "allow": []}]}),
                     OLDBOT: bot("old", "/home/u/p", "oldbot", "ok"),
                     NOTOK: bot("local", "/home/u", "notok", "unknown", detail="no token or channel in /home/u/.claude/discord-agents/notok",
                                channel="", channel_name="", access=None, last_message_at=None)},
            "alerts": [{"ts": iso(n - 30020), "key": OLDBOT, "kind": "finding", "verdict": "unreachable", "status": "sent", "retried": True,
                        "detail": "Discord refused this bot's token (HTTP 401)", "text": "[unreachable] oldbot on old (~/p)"},
                       {"ts": iso(n - 14420), "key": "wmac|-", "kind": "finding", "verdict": "hostdown", "status": "not_posted",
                        "detail": "ssh to wmac failed (exit 255), also with ControlPath=none"},
                       {"ts": iso(n - 7520), "key": MGRBOT, "kind": "finding", "verdict": "down", "status": "sent", "detail": "no plugin server for this bot",
                        "text": "<@111> [down] mgr on lmd79 (~/cd)"},
                       {"ts": iso(n - 7400), "key": MGRBOT, "kind": "finding", "verdict": "down", "status": "failed", "detail": "no plugin server for this bot"},
                       # as 1.10.x wrote it: no detail, no text
                       {"ts": iso(n - 7220), "key": MGRBOT, "kind": "recovery", "verdict": "down", "status": "sent"},
                       {"ts": iso(n - 7100), "key": "wmac|-", "kind": "recovery", "verdict": "blind", "status": "sent", "detail": "back after 5m",
                        "text": "[recovered] wmac: answering again after 5m (was blind)"},
                       {"ts": iso(n - 680), "key": PHOTO, "kind": "finding", "verdict": "down", "status": "sent", "detail": "no plugin server for this bot",
                        "text": "<@111> [down] photobot on lmd79 (~/rcps)\nreason: no plugin server for this bot\nfix: " + FIX},
                       {"ts": iso(n - 20), "key": HBOT, "kind": "finding", "verdict": "throttled", "status": "not_posted",
                        "detail": "Discord is rate-limiting this bot (HTTP 429); nothing can be said about it this run"}]}


# ---- pure functions --------------------------------------------------------
def pure():
    T = tui.epoch("2026-10-13T17:49:00Z")
    assert [tui.ago(iso(T - s), T) for s in (0, 59, 60, 3599, 3600, 172799, 172800)] == ["now", "now", "1m", "59m", "1h", "47h", "2d"]
    assert tui.ago(None, T) == "" and tui.ago("yesterday", T) == "" and tui.hhmm(T - 720) == "17:37" and tui.hhmm(None) == "-"
    print("ok: ago is now/m/h/d, empty for a time that is missing or not one; HH:MM is local time")

    # Width: a Hangul or CJK character is two cells, and every cell of the table must come out exactly its column wide.
    assert cell_len(HANGUL) == 22
    for s in ("photobot", HANGUL, "日本語のチャンネル名です", "a" * 40, ""):
        assert cell_len(tui.fit(s, 16)) == 16, (s, tui.fit(s, 16))
    assert tui.fit(HANGUL, 16).endswith("…") and tui.fit("photobot", 16) == "photobot" + " " * 8 and tui.fit("abc", 0) == ""
    assert tui.wrap("no plugin server for this bot", 18, 3) == ["no plugin server", "for this bot"]
    assert tui.wrap("a b c d e f", 3, 2) == ["a b", "c d e f"], "what does not fit in n lines stays on the last (fit cuts it)"
    print("ok: fit gives exactly the column's cells for ASCII, Hangul and CJK, with an ellipsis when cut; wrap breaks at spaces")

    # An allowFrom list longer than its column: names fold over three lines, the rest is counted.
    assert tui.fold_names("from", ["dongyong22", "gpuvillain", "junyong-dev-bot", "d", "e"], 22) == ["from dongyong22,", "gpuvillain,", "junyong-dev-bot, d, e"]
    many = ["dongyong22", "gpuvillain", "junyong-dev-bot", "another-long-name", "x5", "x6"]
    got = tui.fold_names("from", many, 22)
    assert got == ["from dongyong22,", "gpuvillain,", "junyong-dev-bot +3"], got
    assert all(cell_len(l) <= 22 for l in got)
    assert tui.fold_names("from", ["한" * 20, "b"], 22)[0] == "from" and all(cell_len(l) <= 22 for l in tui.fold_names("from", ["한" * 20, "b"], 22))
    assert tui.fold_names("DMs", ["dongyong22"], 22) == ["DMs dongyong22"]
    print("ok: names fold over at most three lines of the column and the rest is counted (+N); a name wider than the column is cut")

    s = base(T)
    assert [k for k, _ in tui.sorted_bots(s)] == [PHOTO, HBOT, MGRBOT, OLDBOT, NOTOK], [k for k, _ in tui.sorted_bots(s)]
    assert [tui.rank(v) for v in ("down", "stale", "duplicate", "unreachable", "throttled", "apierror", "nostate", "blind", "noreach", "newverdict",
                                  "busy", "ok", "unknown")] == [0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 2, 2, 3]
    k = tui.kpi(s)
    assert (k["problems"], k["look"], k["healthy"], k["notoken"], k["bots"], k["hosts_ok"], k["hosts"]) == (1, 1, 2, 1, 5, 2, 3), k
    assert (k["first_problem"], k["problem_word"], k["first_look"], k["first_unreachable"]) == ("photobot", "down", HANGUL, "wmac"), k
    assert [l.plain for l in tui.kpi_lines(s, 109)] == ["✕ 1  ▲ 1  ● 2  ○ 1 of 5 bots   hosts 2/3"]
    wide = [l.plain for l in tui.kpi_lines(s, 137)]
    assert len(wide) == 3 and len({cell_len(l) for l in wide}) == 1 and cell_len(wide[0]) <= 137, wide
    assert "✕ Problems 1  photobot down" in wide[1] and "● Healthy 2 of 5 bots" in wide[1] and "Hosts 2 / 3  wmac unreachable" in wide[1], wide[1]
    print("ok: problems first, then what needs a look, then healthy, then no token; the KPI band counts every bot, a no-token bot apart; one line below 110")

    assert [n for n, _ in tui.columns(110)] == ["bot", "status", "host", "channel", "receives", "last", "project"]
    assert [n for n, _ in tui.columns(109)] == ["bot", "status", "host", "channel", "last"]
    for w in (80, 109, 110, 137, 200):
        assert 2 + sum(c for _, c in tui.columns(w)) + len(tui.columns(w)) - 1 <= w, w
    b = s["bots"]
    assert tui.receives(b[PHOTO], NAMES, 22, False) == ["@mention · 5 users"] and tui.receives(b[HBOT], NAMES, 22, False) == ["any message · anyone"]
    assert tui.receives(b[PHOTO], NAMES, 22, True) == ["@mention required", "from dongyong22,", "gpuvillain,", "junyong-dev-bot +2", "DMs dongyong22"]
    assert tui.receives(b[HBOT], NAMES, 22, True) == ["any message", "from anyone", "DMs pairing"]
    assert tui.receives(b[PHOTO], {}, 22, True)[1:3] == ["from 111, 222, 333,", "444, 555"], "ids when the names are unknown"
    assert tui.channels(b[PHOTO], "mgr", 22, False) == ["#photo"] and tui.channels(b[PHOTO], "mgr", 22, True) == ["#photo (main)", "#901"]
    assert tui.channels(b[MGRBOT], "mgr", 22, True) == ["#dev-bots (main)", "#901", "#bot-health-check", "  (write-only)"]
    assert tui.channels(b[MGRBOT], "mgr", 40, True)[-1] == "#bot-health-check (write-only)"
    # An older claude-discord on the host (no such fields at all), and a bot with no token and no channel: a dash, no error.
    for key in (OLDBOT, NOTOK):
        for o in (False, True):
            assert tui.receives(b[key], NAMES, 22, o) == ["-"] and tui.channels(b[key], "mgr", 22, o) == ["-"], (key, o)
    print("ok: receives and channel columns closed and open; ids without names; a dash for an older host's bot and for a bot with no token and no channel")

    for width in (137, 100):
        items = tui.bots_items(s, NAMES, width, {PHOTO, HBOT, MGRBOT, OLDBOT, NOTOK}, T)
        rows = {k: [l.plain for l in lines] for k, lines in items if k}
        assert list(rows) == [PHOTO, HBOT, MGRBOT, OLDBOT, NOTOK]
        widths = {cell_len(l) for lines in rows.values() for l in lines}
        assert len(widths) == 1 and widths.pop() <= width, "every table line is the same number of cells wide, Hangul or not"
        at = lambda key, word: cell_len(rows[key][0][:rows[key][0].index(word)])
        assert at(HBOT, "▲ rate-limited") == at(MGRBOT, "◐ working") == at(OLDBOT, "● ok"), "the status column starts at the same cell on every row"
        assert at(HBOT, "lmd79") == at(MGRBOT, "lmd79"), "and so does the host column, after a Hangul name and channel"
        assert rows[OLDBOT][0].split() == ["▾", "oldbot", "●", "ok", "old", "-"] + (["-", "-", "p"] if width >= 110 else ["-"]), rows[OLDBOT]
        fixes = [lines[0].plain for k, lines in items if k is None and lines and lines[0].plain.lstrip().startswith("fix  ")]
        assert fixes == [f"     fix  {FIX}   c copies it"], fixes
    closed = {k: [l.plain for l in lines] for k, lines in tui.bots_items(s, NAMES, 137, set(), T) if k}
    assert all(len(v) == 1 for v in closed.values()) and closed[PHOTO][0].startswith("▸ photobot") and "✕ DOWN 12m" in closed[PHOTO][0]
    assert "12m" in closed[PHOTO][0].split("@mention · 5 users")[1] and closed[PHOTO][0].rstrip().endswith("rcps") and closed[NOTOK][0].rstrip().endswith("~")
    opened = [l.plain for k, lines in tui.bots_items(s, NAMES, 110, {PHOTO}, T) if k == PHOTO for l in lines]
    assert opened[0].startswith("▾ photobot") and "no plugin server for this" in opened[1] and "posted 11m ago" in opened[3], opened
    assert "from dongyong22," in opened[1] and "gpuvillain," in opened[2] and "junyong-dev-bot +2" in opened[3] and "DMs dongyong22" in opened[4], opened
    assert "not posted (warning only)" in "".join(l.plain for k, lines in tui.bots_items(s, NAMES, 137, {HBOT}, T) if k == HBOT for l in lines)
    fresh = dict(s, bots={PHOTO: dict(s["bots"][PHOTO], posted=None)})   # a problem inside its hold time: the channel will be told
    assert "not posted yet" in "".join(l.plain for _, lines in tui.bots_items(fresh, NAMES, 137, {PHOTO}, T) for l in lines)
    print("ok: the Bots table: one width for every line at 137 and 100 columns, project and receives folded below 110, a row grows "
          "downward in its own columns, one full-width fix line under a problem row")


NOW = "2026-10-11T12:00:00Z"
FAKES = tempfile.TemporaryDirectory()


def fake_monitor(bot):
    """A live process whose command line is a monitor's: `bash <root>/monitor/monitor.sh <wrapper> --locked <bot>`."""
    script = Path(FAKES.name) / "monitor" / "monitor.sh"
    script.parent.mkdir(exist_ok=True)
    script.write_text("sleep 30\n")
    return subprocess.Popen(["bash", str(script), "/x/bin/claude-discord", "--locked", bot])


MON = fake_monitor("mgr")
BASE = {"version": 1, "manager": "mgr",
        "monitor": {"pid": MON.pid, "started": NOW, "last_pass": NOW, "next_pass": NOW, "pass_s": 2,
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
    elif name == "markup":
        # state-derived text with Rich/Textual markup lookalikes: shown as typed, never parsed ([/] would raise)
        s["manager"] = "mgr [bold]"
        s["monitor"].update(pid=None, stopped_at="[down]x", holders=[])
        s["bots"]["wmac|/Users/u/p|MAC"].update(verdict="down", detail="error [/] near", servers="[0]",
                                                fix="echo patch output [down] here")
        s["alerts"] = [{"ts": NOW, "key": "wmac|/Users/u/p|MAC", "kind": "find[/]ing", "verdict": "down", "status": "[red]sent"}]
    elif name == "cursor":
        s["bots"]["wmac|/Users/u/p|MAC"]["detail"] = "before"
    elif name == "stopped":
        s["monitor"].update(pid=None, stopped_at=NOW, holders=[])
    elif name == "keeper":
        s["monitor"]["holders"] = [{"kind": "keeper", "pid": 789}, {"kind": "tui", "pid": 456}]
    elif name == "stopped_by_user":
        s["monitor"].update(pid=None, stopped_at=NOW, holders=[], stopped_by_user=True)
    elif name == "post_failed":
        s["monitor"]["post_failed"] = True
    elif name == "pass_failed":
        s["monitor"]["error"] = "the reducer rejected its input at 2026-10-11T12:05:00Z (monitor.log)"
        s["hosts"]["wmac"]["left_s"] = 1760184000
    return s


def stub(d, body):
    """An executable stand-in for the wrapper: `body` is its shell text."""
    p = Path(d) / "wrapper-stub"
    p.write_text("#!/bin/sh\n" + body + "\n")
    p.chmod(0o755)
    return str(p)


async def case(name, check, wrapper=None, state=None):
    with tempfile.TemporaryDirectory() as d:
        (Path(d) / "holders").mkdir()
        (Path(d) / "state.json").write_text(json.dumps(variant(state or name)))
        app = tui.MonitorTUI(Path(d), "mgr", wrapper(d) if wrapper else None)
        async with app.run_test() as pilot:
            await pilot.pause()
            await check(app, pilot)
    print(f"ok: {name}")


def text(app, sel):
    return str(app.query_one(sel).render())


def cells(table, key):
    return [str(c) for c in table.get_row(key)]


async def all_ok(app, pilot):
    assert f"monitor pid {MON.pid}" in text(app, "#head"), text(app, "#head")
    assert app.query_one("#bar").has_class("hidden")
    assert "--stop" not in text(app, "#head"), "no keeper, no stop hint"
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


async def stopped_by_user(app, pilot):
    assert "stopped by you" in text(app, "#bar") and "claude-discord monitor --start mgr" in text(app, "#bar"), text(app, "#bar")


async def refused_marker(app, pilot):
    bar = text(app, "#bar")
    assert "auto-start refused here" in bar and "claude-discord monitor --start mgr" in bar, bar


async def refused_other_side(app, pilot):
    assert app.query_one("#bar").has_class("hidden"), text(app, "#bar")   # another pid namespace's marker is not ours


def own_marker(d):
    """This side's refused marker, named as monitor.sh names it: the digits of the pid namespace link, plain where /proc has none."""
    ns = "".join(c for c in os.readlink("/proc/self/ns/pid") if c.isdigit()) if os.path.islink("/proc/self/ns/pid") else ""
    return Path(d) / (f"refused.{ns}" if ns else "refused")


async def keeper(app, pilot):
    head = text(app, "#head")
    assert "holders keeper 789, tui 456" in head and "claude-discord monitor --stop mgr" in head, head
    assert app.query_one("#bar").has_class("hidden")   # a keeper is no warning


async def post_failed(app, pilot):
    assert "POST" in text(app, "#bar")


async def pass_failed(app, pilot):
    assert "the last pass failed: the reducer rejected its input" in text(app, "#bar"), text(app, "#bar")
    assert cells(app.query_one("#hosts"), "wmac")[0] == "wmac (laptop) (left the ledger)", cells(app.query_one("#hosts"), "wmac")


async def markup(app, pilot):
    assert "mgr [bold]" in text(app, "#head"), text(app, "#head")
    assert "[down]x" in text(app, "#bar"), text(app, "#bar")
    bots = app.query_one("#bots")
    row = [str(c) for c in bots.get_row_at(0)]
    assert row[5:] == ["[0]", "error [/] near"], row
    bots.focus()
    bots.move_cursor(row=0)
    await pilot.press("enter")
    await pilot.pause()
    assert isinstance(app.screen, tui.Detail)
    assert str(app.screen.query_one("#fix").render()) == "echo patch output [down] here", str(app.screen.query_one("#fix").render())
    await pilot.press("escape")
    await pilot.press("a")
    await pilot.pause()
    assert isinstance(app.screen, tui.Alerts)
    assert [str(c) for c in app.screen.query_one("#alerts").get_row_at(0)][2:] == ["find[/]ing", "down", "[red]sent"]


async def missing_wrapper(app, pilot):
    assert not app.query_one("#bar").has_class("hidden")
    assert "/nonexistent/claude-discord" in text(app, "#bar"), text(app, "#bar")
    assert f"monitor pid {MON.pid}" in text(app, "#head")   # the rest of the screen still came up


async def refused(app, pilot):
    assert "no hosts ledger [x]" in text(app, "#bar"), text(app, "#bar")
    args = (Path(app.state_dir) / "args").read_text().strip()
    assert args == f"monitor --ensure mgr --holder tui {os.getpid()}", args


async def cursor(app, pilot):
    bots = app.query_one("#bots")
    key = "wmac|/Users/u/p|MAC"
    bots.focus()
    bots.move_cursor(row=1)
    assert bots.ordered_rows[bots.cursor_row].key.value == key
    state = json.loads((app.state_dir / "state.json").read_text())
    state["bots"][key]["detail"] = "after"
    state["bots"]["local|/home/u/p|RVP"]["detail"] = "also"
    (app.state_dir / "state.json").write_text(json.dumps(state))
    os.utime(app.state_dir / "state.json", (1, 1))   # a different mtime, whatever the clock's resolution
    app.refresh_state()
    assert [str(c) for c in bots.get_row(key)][6] == "after", "the pass was not re-read"
    assert bots.ordered_rows[bots.cursor_row].key.value == key, "the selected row must stay selected across a refresh"


async def main():
    pure()
    await case("all_ok", all_ok)
    await case("findings", findings)
    await case("crashed_project", crashed_project)
    await case("stopped", stopped)
    await case("keeper", keeper)
    # the refused marker (a detached start met a monitor lock this side cannot see) is shown in the bar
    await case("refused_marker", refused_marker, state="all_ok", wrapper=lambda d: own_marker(d).write_text("") or None)
    await case("refused_other_side", refused_other_side, state="all_ok", wrapper=lambda d: (Path(d) / "refused.1").write_text("") or None)
    await case("stopped_by_user", stopped_by_user)
    await case("post_failed", post_failed)
    await case("pass_failed", pass_failed)
    await case("markup", markup)
    await case("cursor", cursor)
    await case("missing_wrapper", missing_wrapper, wrapper=lambda d: "/nonexistent/claude-discord", state="all_ok")
    await case("refused", refused, state="all_ok",
               wrapper=lambda d: stub(d, 'echo "$*" > "$(dirname "$0")/args"; echo "claude-discord: monitor: no hosts ledger [x]" >&2; exit 1'))
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
    # A monitor gone without its trap (kill -9, OOM): its pid stays in state.json and the mtime does not move. The bar
    # says so and --ensure runs again, once per 30 s at most.
    with tempfile.TemporaryDirectory() as d:
        mon = fake_monitor("mgr")
        s = variant("all_ok")
        s["monitor"]["pid"] = mon.pid
        (Path(d) / "holders").mkdir()
        (Path(d) / "state.json").write_text(json.dumps(s))
        app = tui.MonitorTUI(Path(d), "mgr", stub(d, 'echo "$*" >> "$(dirname "$0")/args"'))
        async with app.run_test() as pilot:
            await pilot.pause()
            assert app.query_one("#bar").has_class("hidden"), text(app, "#bar")
            mon.kill()
            mon.wait()
            app.ensured -= 31   # the 30 s since the mount's call, without waiting them
            app.refresh_state()
            assert f"monitor pid {mon.pid} is gone" in text(app, "#bar"), text(app, "#bar")
            app.refresh_state()   # within 30 s of the last call: none
            calls = (Path(d) / "args").read_text().splitlines()
            assert calls == [f"monitor --ensure mgr --holder tui {os.getpid()}"] * 2, calls
    print("ok: a vanished monitor is shown and ensured again")
    # A pid that lives but is no monitor of this bot (reused by another program; another bot's monitor) is as gone as a dead one.
    for what, other in (("a reused pid", subprocess.Popen(["sleep", "30"])), ("another bot's monitor", fake_monitor("other"))):
        with tempfile.TemporaryDirectory() as d:
            s = variant("all_ok")
            s["monitor"]["pid"] = other.pid
            (Path(d) / "holders").mkdir()
            (Path(d) / "state.json").write_text(json.dumps(s))
            app = tui.MonitorTUI(Path(d), "mgr", stub(d, 'echo "$*" >> "$(dirname "$0")/args"'))
            async with app.run_test() as pilot:
                await pilot.pause()
                assert f"monitor pid {other.pid} is gone" in text(app, "#bar"), (what, text(app, "#bar"))
                assert (Path(d) / "args").read_text().splitlines() == [f"monitor --ensure mgr --holder tui {os.getpid()}"], what
        other.kill()
        other.wait()
    print("ok: a live pid that is no monitor of this bot is shown gone and ensured")
    # Launched with the `stopped` marker (monitor --stop): a dialog asks, No by default. Yes runs monitor --start, then
    # the usual --ensure; No (Enter) runs nothing and the bar says stopped by you, with the marker's time.
    for answer in ("y", "enter"):
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "holders").mkdir()
            (Path(d) / "state.json").write_text(json.dumps(variant("stopped_by_user")))
            (Path(d) / "stopped").write_text("")
            app = tui.MonitorTUI(Path(d), "mgr", stub(d, 'echo "$*" >> "$(dirname "$0")/args"'))
            async with app.run_test() as pilot:
                await pilot.pause()
                assert isinstance(app.screen, tui.Confirm) and "stopped by you at" in str(app.screen.text), app.screen
                await pilot.press(answer)
                await pilot.pause()
                args = (Path(d) / "args").read_text().splitlines() if (Path(d) / "args").exists() else []
                if answer == "y":
                    assert args == ["monitor --start mgr", f"monitor --ensure mgr --holder tui {os.getpid()}"], args
                else:
                    assert args == [], args
                    assert "stopped by you at " in text(app, "#bar"), text(app, "#bar")
    print("ok: launched after monitor --stop, a dialog asks: yes starts the backend, no (the default) stays read-only")
    # Q: quit and stop the backend, after a dialog, No by default. Yes runs monitor --stop and quits; No (Enter) stays.
    for answer in ("y", "enter"):
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "holders").mkdir()
            (Path(d) / "state.json").write_text(json.dumps(variant("keeper")))
            app = tui.MonitorTUI(Path(d), "mgr", stub(d, 'echo "$*" >> "$(dirname "$0")/args"; case "$*" in *--stop*) sleep 1;; esac'))
            async with app.run_test() as pilot:
                await pilot.pause()
                await pilot.press("Q")
                await pilot.pause()
                assert isinstance(app.screen, tui.Confirm) and "keeper and monitor stop" in app.screen.text, app.screen
                await pilot.press(answer)
                if answer == "y":
                    # The stub's --stop takes a second: the screen must stay alive meanwhile and say what it does.
                    assert app.return_code is None and "stopping the backend of mgr" in text(app, "#bar"), (app.return_code, text(app, "#bar"))
                    for _ in range(100):
                        if app.return_code is not None:
                            break
                        await asyncio.sleep(0.05)
                await pilot.pause()
                args = (Path(d) / "args").read_text().splitlines()
                if answer == "y":
                    assert args[-1] == "monitor --stop mgr" and app.return_code is not None, (args, app.return_code)
                else:
                    assert "monitor --stop mgr" not in args and not isinstance(app.screen, tui.Confirm) and app.return_code is None, args
    print("ok: Q asks, then stops the backend and quits on yes, and does nothing on no (the default)")


try:
    asyncio.run(main())
finally:
    MON.kill()
    MON.wait()
    FAKES.cleanup()
