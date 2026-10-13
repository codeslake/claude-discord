# /// script
# requires-python = ">=3.9"
# dependencies = ["textual>=8.2.8,<9"]
# ///
"""Tests for tui/claude_discord_tui.py: its pure functions, then pilot runs over fixture state files. Outside
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
                               channel="902", channel_name="한글-채널-이름이-아주-길다", last_message_at=iso(n - 560), fix="cd ~/cd && claude-discord health",
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
    # Within a group by bot name, then host: the key (host|project path|bot) reads as random by name.
    named = {k: dict(s["bots"][OLDBOT], host=k.split("|")[0], bot=k.split("|")[2]) for k in ("b|/p|alpha", "a|/p|beta", "a|/p|alpha")}
    assert [k for k, _ in tui.sorted_bots({"bots": named})] == ["a|/p|alpha", "b|/p|alpha", "a|/p|beta"], tui.sorted_bots({"bots": named})
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
    # Warning only is what the verdict is (the monitor's warn_only), not a not_posted record that 100 newer ones push out.
    for v, want in (("throttled", "not posted (warning only)"), ("apierror", "not posted (warning only)"), ("noreach", "not posted (warning only)"),
                    ("newverdict", "not posted (warning only)"), ("nostate", "not posted yet"), ("blind", "not posted yet"), ("stale", "not posted yet")):
        quiet = dict(s, alerts=[], bots={HBOT: dict(s["bots"][HBOT], verdict=v)})
        assert want in "".join(l.plain for k, lines in tui.bots_items(quiet, NAMES, 137, {HBOT}, T) if k for l in lines), (v, want)
    posted = lambda **kw: [l.plain.strip() for k, ls in tui.bots_items({"bots": {"k": dict({"bot": "b", "verdict": "down", "posted": "down"}, **kw)}}, {}, 137, {"k"}, T)
                           if k for l in ls][-1]
    assert (posted(posted_at=iso(T - 5)), posted(posted_at=iso(T - 120)), posted()) == ("posted just now", "posted 2m ago", "posted"), "no `posted now ago`, no `posted  ago`"
    fresh = dict(s, bots={PHOTO: dict(s["bots"][PHOTO], posted=None)})   # a problem inside its hold time: the channel will be told
    assert "not posted yet" in "".join(l.plain for _, lines in tui.bots_items(fresh, NAMES, 137, {PHOTO}, T) for l in lines)
    print("ok: the Bots table: one width for every line at 137 and 100 columns, project and receives folded below 110, a row grows "
          "downward in its own columns, one full-width fix line under a problem row")

    # Bots of a host the last pass could not ask (reach hostdown, blind or noreach): the monitor froze them with their
    # last verdict, which is not a current one. Dim `○ host unreachable`, after what needs a look and before the healthy,
    # in none of the three counts (the Hosts box says the host is out); open, when that verdict was last seen (the
    # host's `since`). No fix line: the command would go through the host that does not answer. A host the state does
    # not list counts as reachable.
    WOK, WDN, GHOST = "wmac|/Users/u/q|wbot", "wmac|/Users/u/q|wdown", "ghost|/home/u/g|gbot"
    wb = lambda name, verdict, **kw: dict({"host": "wmac", "project": "/Users/u/q", "home": "/Users/u", "bot": name, "verdict": verdict,
                                          "since": iso(T - 90000), "detail": "the last detail seen", "servers": "1"}, **kw)
    fz = dict(s, bots=dict(s["bots"], **{WOK: wb("wbot", "ok"), GHOST: dict(wb("gbot", "ok"), host="ghost"),
                                         WDN: wb("wdown", "down", posted="down", posted_at=iso(T - 10800), fix="ssh wmac 'cd ~/q && x'")}))
    assert [k for k, _ in tui.sorted_bots(fz)] == [PHOTO, HBOT, WOK, WDN, GHOST, MGRBOT, OLDBOT, NOTOK], [k for k, _ in tui.sorted_bots(fz)]
    k = tui.kpi(fz)
    assert (k["problems"], k["look"], k["healthy"], k["notoken"], k["bots"]) == (1, 1, 3, 1, 8), k
    assert [l.plain for l in tui.kpi_lines(fz, 109)] == ["✕ 1  ▲ 1  ● 3  ○ 1 of 8 bots   hosts 2/3"], "the one-line band gets no new symbol"
    for width in (137, 100):
        items = tui.bots_items(fz, NAMES, width, {WOK, WDN}, T)
        rows = {k: [l.plain for l in lines] for k, lines in items if k}
        assert len({cell_len(l) for lines in rows.values() for l in lines}) == 1
        assert rows[WOK][0].split()[:5] == ["▾", "wbot", "○", "host", "unreachable"] and "last seen ok 4h ago" in rows[WOK][1], rows[WOK]
        assert rows[WDN][0].split()[:5] == ["▾", "wdown", "○", "host", "unreachable"] and "last seen DOWN 4h ago" in rows[WDN][1], rows[WDN]
        assert "posted 3h ago" in rows[WDN][2] and len(rows[WOK]) == 2 and "the last detail" not in "".join(rows[WOK] + rows[WDN]), (rows[WOK], rows[WDN])
        assert rows[GHOST][0].split()[:4] == ["▸", "gbot", "●", "ok"], rows[GHOST]
        assert [lines[0].plain for k, lines in items if k is None and lines and lines[0].plain.lstrip().startswith("fix  ")] == [f"     fix  {FIX}   c copies it"]
    print("ok: bots of a host that cannot be reached are dim `host unreachable` rows between what needs a look and the healthy, in no count, "
          "with when their verdict was last seen and no fix line")

    # ---- the shell: the pane's renderer, title, tabs, footer, bar ----
    txt, y, h = tui.render(tui.bots_items(s, NAMES, 137, {HBOT}, T), HBOT, 137)
    lines = txt.plain.split("\n")
    assert HANGUL[:6] in lines[y] and h == 5 and all(cell_len(l) == 137 for l in lines[y:y + h]), (y, h)
    assert tui.render([], None, 80)[0].plain == "" and [a["key"] for a in tui.open_alerts(s)] == [PHOTO]
    mon = lambda **kw: {"manager": "mgr", "monitor": dict({"pid": 1, "last_pass": iso(T - 80), "next_pass": iso(T + 220), "holders": [{"kind": "keeper", "pid": 9}]}, **kw)}
    t = tui.title_line(mon(), 100, T, True, False).plain
    assert t.startswith("◆ claude-discord  mgr ") and t.endswith("● live  keeper · checked 1m ago · next 4m") and cell_len(t) == 100, t
    assert tui.title_line(mon(holders=[]), 100, T, True, False).plain.endswith("● live  checked 1m ago · next 4m")
    # next_pass is the pass's START plus the interval and state.json is written when the pass ENDS, so a pass under way
    # is not overdue: only one that is a tick (30 s) past the longer of 120 s and twice the last pass (pass_s; 0 when
    # missing or not a number). Due here at T+220.
    live, late = "● live  keeper · checked", "▲ check overdue  due 17:52 · now "
    assert tui.title_line(mon(pass_s=45), 100, T + 260, True, False).plain.endswith(live + " 5m ago · next 0m"), "a 45 s pass, 40 s past due, is live"
    for took, last in ((45, 370), (None, 370), ("x", 370), (True, 370), (100, 450)):
        st = mon() if took is None else mon(pass_s=took)
        assert live in tui.title_line(st, 100, T + last, True, False).plain, (took, last)
        assert tui.title_line(st, 100, T + last + 1, True, False).plain.endswith(late + tui.hhmm(T + last + 1)), (took, last)
    for st in (mon(stopped_by_user=True), mon()):
        t = tui.title_line(st, 100, T, False, st["monitor"].get("stopped_by_user") is None).plain
        assert t.endswith("○ stopped by you  start: claude-discord monitor --start mgr"), t
    assert tui.title_line(mon(), 100, T, False, False).plain.endswith("○ not running")
    assert tui.title_line(mon(), 50, T, True, False).plain == "● live  keeper · checked 1m ago · next 4m", "too narrow for both: the status alone"
    cut = tui.title_line(mon(stopped_by_user=True), 40, T, False, False).plain
    assert cut.startswith("○ stopped by you  start: claude-discord") and cut.endswith("…") and cell_len(cut) == 40, cut
    row, under = tui.tabs_lines("alerts", 2, 60).plain.split("\n")
    assert row.rstrip() == " Bots   Alerts 2   Configuration" and under == "─" * 7 + "━" * 10 + "─" * 43, (row, under)
    assert tui.foot_line("bots").plain.split() == "↑↓ select space expand enter all fields c copy fix ←→ tabs q quit".split()
    # Below 110 columns the Bots footer keeps every key and shortens two labels: all of it, `q quit` too, inside 80 columns.
    assert tui.foot_line("bots", 109).plain.split() == "↑↓ select space expand enter fields c copy ←→ tabs q quit".split()
    assert all(tui.foot_line(t, 80).plain.split()[-2:] == ["q", "quit"] and cell_len(tui.foot_line(t, 80).plain.rstrip()) <= 80 for t in tui.TABS)
    assert tui.foot_line("alerts").plain.split() == "↑↓ select enter the post's text ←→ tabs q quit".split()
    assert tui.foot_line("config").plain.split() == "←→ tabs ↑↓ select enter all fields q quit".split()
    assert tui.bar_text({}) == "no state yet: the monitor has not written state.json"
    assert tui.bar_text(mon(stopped_by_user=True)) is None and tui.bar_text(mon(), stopped=True) is None, "the title says stopped by you"
    assert tui.bar_text(mon(), note="no ledger", stopped=True) == "no ledger"
    print("ok: the cursor's row is highlighted to the edge; the title's right side is live / check overdue / stopped by you / not running; "
          "the tab row underlines the active tab and counts the open alerts; one footer per tab")

    # ---- alerts ----
    r = tui.rule("Open", 1, "posted and not recovered yet", 80)
    assert r.plain.startswith("Open 1 ─") and r.plain.endswith("─ posted and not recovered yet") and r.cell_len == 80
    items = tui.alerts_items(s, 137, T)
    plain = [l.plain for _, lines in items for l in lines]
    assert plain[0].startswith("Open 1 ─") and plain[0].endswith("posted and not recovered yet"), plain[0]
    assert [k for k, _ in items if k] == ["open " + PHOTO, "hist 7", "hist 6", "hist 5", "hist 4", "hist 2", "hist 1", "hist 0"], "a failed POST is no history row"
    rows = {k: lines[0].plain for k, lines in items if k}
    assert rows["open " + PHOTO].split() == "17:37 · 11m ✕ DOWN photobot lmd79 no plugin server for this bot ✓ sent".split(), rows["open " + PHOTO]
    assert rows["hist 7"].split()[:5] == ["17:48", "·", "now", "▲", "check"] and rows["hist 7"].rstrip().endswith("— not posted"), rows["hist 7"]
    assert rows["hist 5"].split() == "15:50 · 1h ✓ recovered - wmac back after 5m ✓ sent".split(), rows["hist 5"]
    assert rows["hist 4"].split() == "15:48 · 2h ✓ recovered mgr lmd79 - ✓ sent".split(), "a record of a 1.10.x monitor has no detail: " + rows["hist 4"]
    assert rows["hist 1"].split()[:10] == "13:48 · 4h ○ host - wmac ssh to wmac".split() and rows["hist 1"].rstrip().endswith("… — not posted"), rows["hist 1"]
    assert rows["hist 0"].split() == "09:28 · 8h ✕ down oldbot old Discord refused this bot's token (HTTP 401) ✓ sent on retry".split(), rows["hist 0"]
    assert any(l.startswith("History 7 ─") for l in plain)
    # A host alert that is open (posted, not recovered) is drawn in the alert colour like a bot problem; in History it is dim.
    hot = lambda st, key: [str(sp.style) for k, lines in tui.alerts_items(st, 137, T) if k == key for sp in lines[0].spans if tui.ALERT in str(sp.style)]
    down = dict(s, hosts=dict(s["hosts"], wmac=dict(s["hosts"]["wmac"], posted="hostdown", posted_at=iso(T - 100))),
                bots=dict(s["bots"], **{"wmac|/Users/u/q|wb": dict(s["bots"][PHOTO], host="wmac", bot="wb")}))
    assert [a["key"] for a in tui.open_alerts(down)] == ["wmac|-", PHOTO, "wmac|/Users/u/q|wb"], [a["key"] for a in tui.open_alerts(down)]
    assert hot(down, "open wmac|-") == [f"bold #000000 on {tui.ALERT}"] and hot(down, "open " + PHOTO) and not hot(down, "hist 1"), hot(down, "open wmac|-")
    assert " ○ HOST " in dict(tui.alerts_items(down, 137, T))["open wmac|-"][0].plain
    # A host that left the ledger is kept a day with its bots and what the channel was told (so a line lost for a pass
    # posts nothing again): neither it nor its bots are open alerts meanwhile.
    left = dict(down, hosts=dict(down["hosts"], wmac=dict(down["hosts"]["wmac"], left_s=1)))
    assert [a["key"] for a in tui.open_alerts(left)] == [PHOTO], [a["key"] for a in tui.open_alerts(left)]
    aged = dict(tui.alerts_items(dict(s, alerts=[dict(s["alerts"][0], ts=iso(T - 86400))] + s["alerts"][1:]), 137, T))
    assert "hist 0" not in aged and "hist 1" in aged, "a record 24 h old is out of History"
    assert len({cell_len(l) for l in rows.values()}) == 1
    narrow = {k: lines[0].plain for k, lines in tui.alerts_items(s, 100, T) if k}
    assert "lmd79" not in narrow["open " + PHOTO] and all(cell_len(l) <= 100 for l in narrow.values())
    assert tui.posted_text(s["alerts"][6]).startswith("<@111> [down] photobot") and tui.posted_text(tui.open_alerts(s)[0]).endswith("fix: " + FIX)
    assert tui.posted_text(s["alerts"][7]).startswith("(not posted") and tui.posted_text(s["alerts"][4]) == "(the posted text is no longer kept)"
    assert tui.posted_text(tui.open_alerts(dict(s, alerts=[]))[0]) == "(the posted text is no longer kept)", "an open alert whose record is gone"
    print("ok: the Alerts tab: Open is what was posted and has not recovered, History the last 24 h newest first; kind, what and post per record; "
          "the host column folds below 110; the posted text, or why there is none")

    # ---- configuration ----
    items = tui.config_items(s, NAMES, 137)
    rows = {k: lines[0].plain for k, lines in items if k}
    assert list(rows) == ["local", "old", "wmac"]
    assert rows["local"].split() == "lmd79 this machine (local name=lmd79) server HTTPS_PROXY ● ok 1.11.0 4".split(), rows["local"]
    assert rows["wmac"].split() == "wmac wmac (SECA2033002083) laptop - ○ unreachable - -".split(), rows["wmac"]
    assert rows["old"].split() == "old old server - ● ok 1.10.5 1".split(), rows["old"]   # no display/env/hostname in an older entry: dashes
    plain = [l.plain for _, lines in items for l in lines]
    assert plain[0].startswith("Hosts 3 ─") and "http" not in "\n".join(plain), "env shows key names only, never a value"
    for want in ("alert language    en   ALERT_LANG in config.env", "mention on alert  @dongyong22   DISCORD_USER_ID in config.env", "check every       5 min   fixed",
                 "alert channel     #bot-health-check   fixed", "kept running by   keeper   stop: claude-discord monitor --stop mgr"):
        assert want in plain, (want, plain)
    more = dict(s, hosts=dict(s["hosts"], abc=dict(s["hosts"]["old"], host="abc", name="abc")))
    assert [k for k, _ in tui.config_items(more, NAMES, 137) if k] == ["local", "abc", "old", "wmac"], "this machine first, then by ledger name"
    # The monitor mentions an owner id only when it is all digits: anything else mentions nobody, and is not shown as one.
    for owner, want in (("abc", "-"), ("1>@everyone", "-"), ("", "nobody"), ("999", "@999")):
        plain = [l.plain for _, lines in tui.config_items(dict(s, monitor=dict(s["monitor"], owner_id=owner)), NAMES, 137) for l in lines]
        assert f"mention on alert  {want}   DISCORD_USER_ID in config.env" in plain, (owner, plain[-4])
    older = dict(s, monitor={"pid": 1, "holders": []})
    plain = [l.plain for _, lines in tui.config_items(older, NAMES, 137) for l in lines]
    assert "alert language    -   ALERT_LANG in config.env" in plain and "mention on alert  -   DISCORD_USER_ID in config.env" in plain, plain
    narrow = {k: lines[0].plain for k, lines in tui.config_items(s, NAMES, 100) if k}
    assert "HTTPS_PROXY" not in narrow["local"] and all(cell_len(l) <= 100 for l in narrow.values())
    print("ok: the Configuration tab: one row per ledger host (display name, target, kind, env key names, reach, version, bots), dashes for what an "
          "older state lacks, and the monitor's settings")


def fuzz():
    """Every value of a small state replaced, one at a time, by a value of each other type: a host of another version
    (the reducer copies a health document's fields unchecked), a hand edit. Nothing may raise: such a value is a dash."""
    n = time.time()
    st = lambda: json.loads(json.dumps({   # a copy each time: ACCESS is shared
        "version": 1, "manager": "mgr",
        "monitor": {"pid": 1, "last_pass": iso(n - 80), "next_pass": iso(n + 220), "pass_s": 2, "holders": [{"kind": "keeper", "pid": 9}], "lang": "en",
                    "owner_id": "111", "error": "e", "stopped_at": iso(n), "post_failed": True},
        "hosts": {"local": {"host": "local", "name": "box", "hostname": "box", "display": "lmd79", "env": ["HTTPS_PROXY"], "reach": "ok", "version": "1.11.0 (a)",
                            "verdict": "ok", "laptop": False},
                  "srv": {"host": "srv", "name": "srv", "reach": "hostdown", "verdict": "hostdown", "since": iso(n - 7200), "posted": "hostdown",
                          "posted_at": iso(n - 5400), "detail": "ssh to srv failed", "fix": "ssh srv", "laptop": True, "left_s": None}},
        "bots": {"local|/home/u/p|b1": {"host": "local", "project": "/home/u/p", "home": "/home/u", "bot": "b1", "verdict": "down", "since": iso(n - 700),
                                        "detail": "no plugin server", "fix": FIX, "posted": "down", "posted_at": iso(n - 600), "channel": "900",
                                        "channel_name": "dev", "last_message_at": iso(n - 100), "access": ACCESS},
                 "srv|/p|b2": {"host": "srv", "project": "/p", "bot": "b2", "verdict": "throttled", "since": iso(n - 9000), "detail": "d", "posted": None}},
        "alerts": [{"ts": iso(n - 600), "key": "local|/home/u/p|b1", "kind": "finding", "verdict": "down", "status": "sent", "detail": "no plugin server",
                    "text": "[down] b1", "retried": True},
                   {"ts": iso(n - 500), "key": "srv|-", "kind": "recovery", "verdict": "hostdown", "status": "not_posted", "detail": "d"}]}))

    def views(s):
        for w in (137, 80):
            for opened in (set(), set(s["bots"]) if isinstance(s.get("bots"), dict) else set()):
                tui.render(tui.bots_items(s, {"111": "dong"}, w, opened, n), None, w)
            tui.alerts_items(s, w, n), tui.config_items(s, {"111": "dong"}, w), tui.title_line(s, w, n, True, False)
            tui.tabs_lines("bots", len(tui.open_alerts(s)), w)
        tui.bar_text(s), tui.load_names(s)
        for a in tui.open_alerts(s) + (s.get("alerts") if isinstance(s.get("alerts"), list) else []):
            tui.posted_text(a)
        for scope in ("bots", "hosts"):
            for k, e in (s[scope].items() if isinstance(s.get(scope), dict) else []):
                tui.entry_text(k, k, e, s.get("alerts"))

    def paths(o, p=()):
        yield p
        for k, v in o.items() if isinstance(o, dict) else enumerate(o) if isinstance(o, list) else ():
            yield from paths(v, p + (k,))

    views(st())
    raised, total = {}, 0
    for p in list(paths(st()))[1:]:
        for v in (None, 7, "str", [], [1], {}, {"a": 1}, True, 1.5e30, ""):
            s = o = st()
            for k in p[:-1]:
                o = o[k]
            o[p[-1]] = v
            total += 1
            try:
                views(s)
            except Exception as e:
                raised.setdefault(".".join(map(str, p)), set()).add(f"{type(v).__name__}: {type(e).__name__}: {e}")
    assert total > 900 and not raised, f"{sum(map(len, raised.values()))} of {total} states raised: {raised}"
    for s in ({}, {"bots": [], "hosts": [], "alerts": [], "monitor": []}, dict(st(), alerts=["x", None, 7]), dict(st(), bots={"k": None}),
              dict(st(), hosts={"k": None}), dict(st(), monitor="x"), dict(st(), manager=None), dict(st(), manager=5)):
        views(s)
    print(f"ok: {total} states with one value of another type each (a string for a list, a number for a name, ...) draw without raising")


FAKES = tempfile.TemporaryDirectory()


def fake_monitor(bot):
    """A live process whose command line is a monitor's: `bash <root>/monitor/monitor.sh <wrapper> --locked <bot>`."""
    script = Path(FAKES.name) / "monitor" / "monitor.sh"
    script.parent.mkdir(exist_ok=True)
    script.write_text("sleep 60\n")
    return subprocess.Popen(["bash", str(script), "/x/bin/claude-discord", "--locked", bot])


MON = fake_monitor("mgr")
CRASHED = "wmac|/Users/u/q|-"


def variant(name):
    s = base()
    if name == "crashed_project":
        # What the monitor writes for a project whose health crashed before any bot of it was known: no `bot` field.
        s["hosts"]["wmac"].update(reach="ok", verdict="ok", detail="")   # the host answered: one of its projects did not
        s["bots"][CRASHED] = {"host": "wmac", "name": "wmac", "project": "/Users/u/q", "home": "/Users/u", "owner_id": "111", "verdict": "blind",
                              "since": iso(time.time() - 20), "detail": "health exited 1 with no document", "fix": "ssh wmac 'cd ~/q && ~/.local/bin/claude-discord health'"}
    elif name == "markup":
        # state-derived text with Rich/Textual markup lookalikes: shown as typed, never parsed ([/] would raise)
        s["manager"] = "mgr [bold]"
        s["monitor"].update(pid=None, stopped_at="[down]x", holders=[])
        s["bots"][PHOTO].update(bot="pho[/]to", detail="error [/] near", fix="echo patch output [down] here", channel_name="[red]x")
        s["alerts"][6].update(detail="find[/]ing", text="[bold]posted[/]")
    elif name == "escapes":
        # Text another machine wrote (a ledger host's health document, a Discord display name) with what a terminal
        # obeys: an OSC 52 (sets the clipboard), an OSC 0 (the window title), ESC[2J (clears the screen), ESC[8m (hides
        # text), a bidi override (reorders the line) and a line break (splits the row).
        s["bots"][PHOTO].update(bot="pho\x1b]52;c;aGFjaw==\x1b\\to", detail="d\x1b[2J\x1b[Hgone\x9b2J", channel_name="c\x1b]0;TITLE\x1b\\",
                                fix="echo \x1b[8mhidden\x1b[0m;\trm -rf x")
        s["bots"][HBOT].update(bot="evil\u202etxt\u200b.\ufeffsh", detail="one\r\ntwo\x7f")
        s["bots"]["local|/home/u/k\x1b[2J|kb\nx"] = dict(s["bots"][OLDBOT], host="local", bot="kb\nx")
        s["alerts"][6].update(detail="find\x1b[2Jing", text="[down]\x1b[2J photobot\nreason: x\x1b]0;T\x07")
        s["hosts"]["wmac"].update(display="w\x1b[5mmac", detail="ssh\x1b[2J failed")
    elif name == "wrong_types":   # the app's own reads of the state (the fuzz above covers what it draws)
        s["monitor"], s["alerts"] = "x", ["x", 7] + s["alerts"]
        s["bots"][PHOTO].update(fix=7, access={"groups": {"900": {}}}, channel_name=["x"])
        s["bots"]["local|/p|none"], s["hosts"]["odd"] = None, 7
    elif name == "many":   # more rows than a 20-line terminal shows
        for i in range(20):
            s["bots"][f"local|/home/u/m|m{i:02}"] = dict(s["bots"][OLDBOT], host="local", project="/home/u/m", bot=f"m{i:02}")
    elif name == "stopped":
        s["monitor"].update(pid=None, stopped_at="2026-10-11T12:00:00Z", holders=[])
    elif name == "stopped_by_user":
        s["monitor"].update(pid=None, stopped_at="2026-10-11T12:00:00Z", holders=[], stopped_by_user=True)
    elif name == "overdue":
        s["monitor"]["next_pass"] = iso(time.time() - 400)   # past the 30 s + 120 s a pass is given
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


async def case(name, check, wrapper=None, state=None, size=(137, 40)):
    with tempfile.TemporaryDirectory() as d:
        (Path(d) / "holders").mkdir()
        (Path(d) / "state.json").write_text(json.dumps(variant(state or name)))
        app = tui.MonitorTUI(Path(d), "mgr", wrapper(d) if wrapper else None)
        async with app.run_test(size=size) as pilot:
            await pilot.pause()
            app.names = dict(NAMES)   # the fixture's projects do not exist, so no user-names file is read
            app.paint()
            await check(app, pilot)
    print(f"ok: {name}")


def text(app, sel):
    return str(app.query_one(sel).render())


def body(app):
    return text(app, "#body").split("\n")


def line_of(app, word):
    return next(l for l in body(app) if word in l)


def row_of(app, bot):
    """The first line of a bot's row in the Bots table."""
    return next(l for l in body(app) if l[:2] in ("▸ ", "▾ ") and l[2:].startswith(bot))


# ---- pilot cases -----------------------------------------------------------
async def shell(app, pilot):
    assert text(app, "#title").endswith("● live  keeper · checked 1m ago · next 4m"), text(app, "#title")
    assert app.query_one("#bar").has_class("hidden")
    assert text(app, "#tabs").split("\n")[0].rstrip() == " Bots   Alerts 1   Configuration"
    assert "space" in text(app, "#foot")
    assert app.focused is None, "nothing is focused, so the arrow keys reach the app's bindings"
    await pilot.press("right")
    assert app.tab == "alerts" and "the post's text" in text(app, "#foot") and text(app, "#tabs").split("\n")[1].startswith("─" * 7 + "━")
    await pilot.press("right", "right")
    assert app.tab == "bots"
    await pilot.press("left")
    assert app.tab == "config"


async def small(app, pilot):
    foot = text(app, "#foot")
    assert foot.split() == "↑↓ select space expand enter fields c copy ←→ tabs q quit".split() and cell_len(foot.rstrip()) <= app.size.width == 80, foot
    assert [app.query_one(w).size.height for w in ("#title", "#tabs", "#foot", "#pane")] == [1, 2, 1, 20]
    for tab in ("alerts", "config"):
        await pilot.press("right")
        assert app.tab == tab and text(app, "#foot").split()[-2:] == ["q", "quit"] and cell_len(text(app, "#foot").rstrip()) <= 80


async def bots(app, pilot):
    assert [l[:2] for l in body(app) if l[:2] in ("▸ ", "▾ ")] == ["▸ "] * 5
    assert app.cursor["bots"] == PHOTO and row_of(app, "photobot").startswith("▸ photobot") and "fix  " + FIX in text(app, "#body")
    await pilot.press("space")
    assert row_of(app, "photobot").startswith("▾ photobot") and "posted 11m ago" in text(app, "#body") and "from dongyong22, gpuvillain," in text(app, "#body")
    await pilot.press("down", "space")   # several rows may be open
    assert app.opened == {PHOTO, HBOT} and "not posted (warning only)" in text(app, "#body") and "DMs pairing" in text(app, "#body")
    await pilot.press("c")   # a rate-limited row has a `fix` in the state (every finding has) and shows no fix line
    assert app.clipboard == "" and not list(app._notifications), "a row with no fix line copies nothing"
    await pilot.press("up", "c")
    # OSC 52 gets no answer: whether the terminal took it cannot be known (macOS Terminal.app does not).
    assert app.clipboard == FIX and [n.message for n in app._notifications] == ["fix copied (if your terminal allows it)"], app.clipboard
    await pilot.press("space")
    assert app.opened == {HBOT}
    await pilot.press("enter")
    await pilot.pause()
    assert isinstance(app.screen, tui.Detail) and str(app.screen.query_one("#fix").render()) == FIX
    raw = str(app.screen.query_one("#body-detail").render())
    for want in (PHOTO, "servers          0", "posted_at", '"dm_allow": ["111"]', "posts for this key:", "finding  down  sent"):
        assert want in raw, (want, raw)
    await pilot.press("down", "right", "space")   # the row keys belong to the main view
    assert isinstance(app.screen, tui.Detail) and app.tab == "bots" and app.cursor["bots"] == PHOTO and app.opened == {HBOT}
    await pilot.press("escape")
    # A new pass: the selected row stays selected, open rows stay open, and what changed is shown.
    await pilot.press("down", "down")
    assert app.cursor["bots"] == MGRBOT
    state = json.loads((app.state_dir / "state.json").read_text())
    state["bots"][MGRBOT].update(verdict="stale", detail="unanswered for 22m", fix="x")   # it moves up, among the problems
    (app.state_dir / "state.json").write_text(json.dumps(state))
    os.utime(app.state_dir / "state.json", (1, 1))   # a different mtime, whatever the clock's resolution
    app.refresh_state()
    assert app.cursor["bots"] == MGRBOT and app.opened == {HBOT} and "✕ STUCK" in row_of(app, "mgr "), row_of(app, "mgr ")
    del state["bots"][MGRBOT]
    (app.state_dir / "state.json").write_text(json.dumps(state))
    os.utime(app.state_dir / "state.json", (2, 2))
    app.refresh_state()
    assert app.cursor["bots"] == PHOTO, "a selected row that left the state gives the cursor to the first row"


async def narrow(app, pilot):
    assert [app.query_one(w).size.height for w in ("#title", "#tabs", "#foot")] == [1, 2, 1], "one line each, however narrow"
    assert app.width == 100 and body(app)[0] == "✕ 1  ▲ 1  ● 22  ○ 1 of 25 bots   hosts 2/3", body(app)[0]
    head = line_of(app, "status")
    assert head.split() == ["bot", "status", "host", "channel", "last"], head
    pane = app.query_one("#pane")
    assert pane.scroll_offset.y == 0 and pane.max_scroll_y > 0, "more rows than the terminal has lines"
    await pilot.press(*["down"] * 30)   # past the last row: the cursor stops there
    await pilot.pause()
    assert app.cursor["bots"] == NOTOK
    _, y, h = tui.render(app.items(time.time()), NOTOK, 100)
    assert pane.scroll_offset.y <= y and y + h <= pane.scroll_offset.y + pane.size.height, (pane.scroll_offset, y, h, pane.size)
    await pilot.press(*["up"] * 30)
    await pilot.pause()
    assert app.cursor["bots"] == PHOTO and pane.scroll_offset.y <= tui.render(app.items(time.time()), PHOTO, 100)[1]
    await pilot.resize_terminal(120, 30)
    await pilot.pause()
    assert "receives" in line_of(app, "status") and body(app)[0].startswith("╭"), "a wider terminal gets the columns and the KPI band back"


async def crashed_project(app, pilot):
    row = line_of(app, "▲ blind")
    assert row.split()[:5] == ["▸", "-", "▲", "blind", "wmac"] and row.rstrip().endswith("q"), f"a project row, among what needs a look: {row}"
    assert "of 5 bots" in "\n".join(body(app)[:3]), "a project row is not a bot"
    await pilot.press("down", "enter")   # the first of what needs a look: it has no name
    await pilot.pause()
    assert isinstance(app.screen, tui.Detail) and "claude-discord health" in str(app.screen.query_one("#fix").render())
    assert CRASHED in str(app.screen.query_one("#body-detail").render())


async def markup(app, pilot):
    assert "mgr [bold]" in text(app, "#title"), text(app, "#title")
    assert "[down]x" in text(app, "#bar"), text(app, "#bar")
    assert "pho[/]to" in text(app, "#body") and "#[red]x" in text(app, "#body") and "fix  echo patch output [down] here" in text(app, "#body")
    await pilot.press("space", "enter")
    await pilot.pause()
    assert "error [/] near" in text(app, "#body")
    assert str(app.screen.query_one("#fix").render()) == "echo patch output [down] here"
    await pilot.press("escape")
    await pilot.press("right")
    assert "find[/]ing" in text(app, "#body")
    await pilot.press("enter")
    await pilot.pause()
    assert str(app.screen.query_one("#body-detail").render()) == "[bold]posted[/]"


ESCAPES = ("\x1b", "\x9b", "\x7f", "\x07", "\u202e", "\u200b", "\ufeff", "\t", "\r")


async def escapes(app, pilot):
    def drawn():   # what the terminal is sent: the styles' own sequences are in it, so the four of the fixture are looked for
        out = app.screen._compositor.render_full_update().render_segments(app.console)
        assert not [q for q in ("\x1b]52", "\x1b]0;", "\x1b[2J", "\x1b[8m", "\x1b[5m", "\x1b[H") if q in out], out
    for tab in tui.TABS:
        lines = [l.plain for _, ls in app.items(time.time()) for l in ls] + [text(app, w) for w in ("#title", "#bar", "#foot")] + text(app, "#tabs").split("\n")
        assert not [(c, l) for l in lines for c in ESCAPES + ("\n",) if c in l], (tab, [l for l in lines if any(c in l for c in ESCAPES + ("\n",))])
        drawn()
        await pilot.press("right")
    assert row_of(app, "pho]52;c;aGFjaw…") and "#c]0;TITLE\\" in row_of(app, "pho") and row_of(app, "eviltxt.sh") and row_of(app, "kb x")
    assert "local|/home/u/k[2J|kb x" in app.state["bots"], "keys are cleaned too"
    await pilot.press("space", "c")
    drawn()
    assert "d[2J[Hgone2J" in text(app, "#body") and app.clipboard == "echo [8mhidden[0m; rm -rf x", app.clipboard
    await pilot.press("enter")
    await pilot.pause()
    raw = str(app.screen.query_one("#body-detail").render())
    assert not [c for c in ESCAPES if c in raw] and "detail           d[2J[Hgone2J" in raw and str(app.screen.query_one("#fix").render()) == app.clipboard, raw
    drawn()
    await pilot.press("escape", "down", "space")
    assert "one two" in text(app, "#body"), "a line break in a reason is a space, not a second row"
    await pilot.press("right", "enter")
    await pilot.pause()
    raw = str(app.screen.query_one("#body-detail").render())
    assert raw == "[down][2J photobot\nreason: x]0;T", repr(raw)   # the post keeps its own line breaks, and nothing else
    drawn()


async def wrong_types(app, pilot):
    assert row_of(app, "photobot").split()[:6] == ["▸", "photobot", "✕", "DOWN", "12m", "lmd79"] and "#900" in row_of(app, "photobot")
    assert "fix  " not in text(app, "#body"), "a fix that is no text is no fix line"
    await pilot.press("space", "c", "enter")
    await pilot.pause()
    assert app.clipboard == "" and str(app.screen.query_one("#fix").render()) == "(none)"
    await pilot.press("escape", "right", "down", "down", "enter")
    await pilot.pause()
    assert isinstance(app.screen, tui.Detail)
    await pilot.press("escape", "right", "down", "enter")
    await pilot.pause()
    assert isinstance(app.screen, tui.Detail) and str(app.screen.query_one("#body-detail").render()).startswith("odd\n")


async def alerts(app, pilot):
    await pilot.press("right")
    assert body(app)[0].startswith("Open 1 ─") and any(l.startswith("History 7 ─") for l in body(app))
    assert app.cursor["alerts"] == "open " + PHOTO
    await pilot.press("enter")
    await pilot.pause()
    assert str(app.screen.query_one("#body-detail").render()).endswith("fix: " + FIX) and not app.screen.query("#fix")
    await pilot.press("escape", "down", "enter")
    await pilot.pause()
    assert str(app.screen.query_one("#body-detail").render()).startswith("(not posted")
    await pilot.press("escape", "space", "c")
    assert app.opened == set() and app.clipboard == "", "space and c are the Bots tab's"


async def config(app, pilot):
    await pilot.press("left")
    assert body(app)[0].startswith("Hosts 3 ─") and app.cursor["config"] == "local"
    assert "this machine (local name=lmd79)" in line_of(app, "lmd79") and "http" not in text(app, "#body")
    await pilot.press("down", "down", "enter")
    await pilot.pause()
    assert isinstance(app.screen, tui.Detail) and "ControlPath=none wmac 'echo up'" in str(app.screen.query_one("#fix").render())
    raw = str(app.screen.query_one("#body-detail").render())
    assert raw.startswith("wmac\n") and "hostname         SECA2033002083" in raw and "finding  hostdown  not_posted" in raw, raw


async def stopped(app, pilot):
    assert text(app, "#title").endswith("○ not running") and f"monitor stopped at 2026-10-11T12:00:00Z" in text(app, "#bar")


async def stopped_by_user(app, pilot):
    assert text(app, "#title").endswith("○ stopped by you  start: claude-discord monitor --start mgr"), text(app, "#title")
    assert app.query_one("#bar").has_class("hidden")


async def overdue(app, pilot):
    assert "▲ check overdue  due " in text(app, "#title") and " · now " in text(app, "#title"), text(app, "#title")


async def refused_marker(app, pilot):
    bar = text(app, "#bar")
    assert "auto-start refused here" in bar and "claude-discord monitor --start mgr" in bar, bar


async def refused_other_side(app, pilot):
    assert app.query_one("#bar").has_class("hidden"), text(app, "#bar")   # another pid namespace's marker is not ours


def own_marker(d):
    """This side's refused marker, named as monitor.sh names it: the digits of the pid namespace link, plain where /proc has none."""
    ns = "".join(c for c in os.readlink("/proc/self/ns/pid") if c.isdigit()) if os.path.islink("/proc/self/ns/pid") else ""
    return Path(d) / (f"refused.{ns}" if ns else "refused")


async def post_failed(app, pilot):
    assert "POST" in text(app, "#bar")


async def pass_failed(app, pilot):
    assert "the last pass failed: the reducer rejected its input" in text(app, "#bar"), text(app, "#bar")
    await pilot.press("left")
    assert "wmac (SECA2033002083) (left the ledger)" in line_of(app, "laptop"), line_of(app, "laptop")


async def missing_wrapper(app, pilot):
    assert not app.query_one("#bar").has_class("hidden")
    assert "/nonexistent/claude-discord" in text(app, "#bar"), text(app, "#bar")
    assert "photobot" in text(app, "#body")   # the rest of the screen still came up


async def refused(app, pilot):
    assert "no hosts ledger [x]" in text(app, "#bar"), text(app, "#bar")
    args = (Path(app.state_dir) / "args").read_text().strip()
    assert args == f"monitor --ensure mgr --holder tui {os.getpid()}", args


async def main():
    pure()
    t0 = time.time()
    fuzz()
    assert time.time() - t0 < 3, f"the fuzz took {time.time() - t0:.1f} s"
    await case("shell", shell, state="all_ok")
    await case("bots", bots, state="all_ok")
    await case("narrow", narrow, state="many", size=(100, 20))
    await case("small", small, state="all_ok", size=(80, 24))
    await case("crashed_project", crashed_project)
    await case("markup", markup)
    await case("escapes", escapes)
    await case("wrong_types", wrong_types)
    await case("alerts", alerts, state="all_ok")
    await case("config", config, state="all_ok")
    await case("stopped", stopped)
    await case("stopped_by_user", stopped_by_user)
    await case("overdue", overdue)
    # the refused marker (a detached start met a monitor lock this side cannot see) is shown in the bar
    await case("refused_marker", refused_marker, state="all_ok", wrapper=lambda d: own_marker(d).write_text("") or None)
    await case("refused_other_side", refused_other_side, state="all_ok", wrapper=lambda d: (Path(d) / "refused.1").write_text("") or None)
    await case("post_failed", post_failed)
    await case("pass_failed", pass_failed)
    await case("missing_wrapper", missing_wrapper, wrapper=lambda d: "/nonexistent/claude-discord", state="all_ok")
    await case("refused", refused, state="all_ok",
               wrapper=lambda d: stub(d, 'echo "$*" > "$(dirname "$0")/args"; echo "claude-discord: monitor: no hosts ledger [x]" >&2; exit 1'))
    # the display names come from the user-names files of this machine's bots
    with tempfile.TemporaryDirectory() as d:
        s = base()
        s["bots"][PHOTO]["project"] = d
        names = Path(d) / ".claude" / "discord-agents" / "photobot" / "user-names"
        names.parent.mkdir(parents=True)
        names.write_text("111 dong yong\nnot-an-id x\n222\n333 한글이름\n444 es\x1b]52;c;eA==\x07c\u202eape\t!\n555 \x1b\n")
        assert tui.load_names(s) == {"111": "dong yong", "333": "한글이름", "444": "es]52;c;eA==cape !"}, tui.load_names(s)
        # A remote bot's project path is a path on ITS machine: never opened here, even when such a path exists here too.
        s["bots"][PHOTO]["host"] = "old"
        assert tui.load_names(s) == {}, tui.load_names(s)
    print("ok: names are read from the local bots' user-names files (<id> <name>), other lines skipped, control characters dropped")
    # q removes the holder record
    with tempfile.TemporaryDirectory() as d:
        (Path(d) / "holders").mkdir()
        (Path(d) / "state.json").write_text(json.dumps(base()))
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
        s = base()
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
            assert f"monitor pid {mon.pid} is gone" in text(app, "#bar") and text(app, "#title").endswith("○ not running"), text(app, "#bar")
            app.refresh_state()   # within 30 s of the last call: none
            calls = (Path(d) / "args").read_text().splitlines()
            assert calls == [f"monitor --ensure mgr --holder tui {os.getpid()}"] * 2, calls
    print("ok: a vanished monitor is shown and ensured again")
    # A pid that lives but is no monitor of this bot (reused by another program; another bot's monitor) is as gone as a dead one.
    for what, other in (("a reused pid", subprocess.Popen(["sleep", "30"])), ("another bot's monitor", fake_monitor("other"))):
        with tempfile.TemporaryDirectory() as d:
            s = base()
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
    # the usual --ensure; No (Enter) runs nothing and the title says stopped by you.
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
                    assert args == [] and not isinstance(app.screen, tui.Confirm), args
                    assert "○ stopped by you  start: claude-discord monitor --start mgr" in text(app, "#title"), text(app, "#title")
    print("ok: launched after monitor --stop, a dialog asks: yes starts the backend, no (the default) stays read-only")
    # Q: quit and stop the backend, after a dialog, No by default. Yes runs monitor --stop and quits; No (Enter) stays.
    for answer in ("y", "enter"):
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "holders").mkdir()
            (Path(d) / "state.json").write_text(json.dumps(base()))
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
