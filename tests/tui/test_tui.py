# /// script
# requires-python = ">=3.9"
# dependencies = ["textual>=8.2.8,<9"]
# ///
"""Tests for tui/claude_discord_tui.py: its pure functions, then pilot runs over fixture state files. Outside
the 40 s stub suite (it needs uv and the Textual wheel):
    uv run --script tests/tui/test_tui.py
Exit 0 and one "ok:" line per case, or the first failure."""
import asyncio
import contextlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

os.environ["TZ"] = "UTC"   # HH:MM in the title and the Alerts tab is local time: fixed here
time.tzset()
from rich.cells import cell_len
from rich.console import Console

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


def access_doc():
    """What `claude-discord access ... photobot --json` prints (1.13.0), with what another machine may put in it: an
    escape sequence in a name, a channel Discord did not list, a readability that is not known."""
    return {"access": 1, "version": "1.13.0", "bot": "photobot", "bot_id": "777", "host": "lmd79", "project": "/home/u/rcps", "mode": "none", "owner": "111",
            "main": "900", "peers": ["555"], "guild": {"id": "5", "name": "Tor-AIC"},
            "policy": {"dm": "allowlist", "dm_allow": ["111"],
                       "groups": [{"id": "900", "mention": True, "allow": ["111", "222"]}, {"id": "901", "mention": False, "allow": []},
                                  {"id": "1234", "mention": False, "allow": []}]},
            "channels": [{"id": "906", "name": "fo\x1b[2Jrum", "kind": "forum", "read": True}, {"id": "900", "name": "dev-bots", "kind": "text", "read": True},
                         {"id": "901", "name": "bot-health", "kind": "text", "read": True}, {"id": "902", "name": "general", "kind": "text", "read": False},
                         {"id": "905", "name": "odd", "kind": "text", "read": None}, {"id": "1234", "name": "", "kind": "unknown", "read": None}],
            "people": [{"id": "111", "name": "dongyong22", "kept": "dongyong22", "bot": False}, {"id": "222", "name": "gpuvillain", "kept": "", "bot": False},
                       {"id": "333", "name": "junyong-dev-bot", "kept": "", "bot": True}, {"id": "444", "name": "pho\x1b[2Jto", "kept": "", "bot": False},
                       {"id": "555", "name": "peerbot", "kept": "peerbot", "bot": True}, {"id": "556", "name": "peerbot-old", "kept": "peerbot-old", "bot": True}],
            "members": "api", "errors": []}


def status_lines(items, key):
    """What the status column holds on each line of a bot's row: the cells from the header's `status` to its `host`."""
    head = next(l.plain for k, ls in items if k is None for l in ls if l.plain.split()[:2] == ["bot", "status"])
    a, b = head.index("status"), head.index("host")
    out = []
    for line in next(ls for k, ls in items if k == key):
        cell, got = 0, ""
        for ch in line.plain:
            got += ch if a <= cell < b else ""
            cell += cell_len(ch)
        out.append(got.strip())
    return out


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

    # 1.11.1: health gives each access group its `name`. Another channel is #<name> when that is a non-empty string and
    # #<id> otherwise: an older host (no such field), a channel the guild has not (""), a value of another type.
    named = lambda **g: dict(b[PHOTO], access=dict(ACCESS, groups=[ACCESS["groups"][0], dict(ACCESS["groups"][1], **g)]))
    assert tui.channels(named(name="side-room"), "mgr", 22, True) == ["#photo (main)", "#side-room"]
    for v in ("", None, 7, ["x"], {"a": 1}):
        assert tui.channels(named(name=v), "mgr", 22, True) == ["#photo (main)", "#901"], v
    assert tui.channels(named(name="side-room"), "mgr", 22, False) == ["#photo"], "a closed row shows the main channel only"
    print("ok: an opened row names the bot's other channels (#name), and keeps #id for one with no name or a name of another type")

    # 1.11.1: a bot's mode, when it is not `none`, follows its name in the bot column, dim, at 110 columns and more;
    # the column grows for it (a 16-cell name and `dev-manager` are not cut) and the table stays inside the terminal.
    NAME16 = "abcdefghijklmnop"
    moded = lambda **kw: {"bots": {"k": dict(b[MGRBOT], bot=NAME16, **kw), "j": dict(b[PHOTO], bot="plain", mode="none")}}
    for width in (110, 137):
        lines = [l for k, ls in tui.bots_items(moded(mode="dev-manager"), NAMES, width, {"k", "j"}, T) if k for l in ls]
        row = next(l for l in lines if NAME16 in l.plain)
        assert row.plain.startswith(f"▸ {NAME16}  dev-manager ".replace("▸", "▾")), row.plain
        at = row.plain.index("dev-manager")
        assert "dim" in str(row.get_style_at_offset(Console(), at)) and "bold" in str(row.get_style_at_offset(Console(), 2)), "the mode is dim, the name bold"
        assert len({cell_len(l.plain) for l in lines}) == 1 and cell_len(lines[0].plain) <= width, "one width for every line, inside the terminal"
        assert not any("dev-manager" in l.plain or "none" in l.plain for l in lines if "plain" in l.plain), "mode none is not shown"
    long = [l.plain for k, ls in tui.bots_items(moded(mode="autoresearchclaw"), NAMES, 110, set(), T) if k == "k" for l in ls][0]
    assert long.startswith(f"▸ {NAME16}  autoresearchclaw ") and cell_len(long) <= 110, long
    short = [l.plain for k, ls in tui.bots_items({"bots": {"k": dict(b[MGRBOT], mode="autoresearchclaw")}}, NAMES, 110, set(), T) if k for l in ls][0]
    assert short.startswith("▸ mgr  autoresearchclaw ") and cell_len(short) <= 110, short
    # A short name: after a 16-cell one the mode would be cut off at this width whether or not the row leaves it out.
    assert all("dev-manager" not in l.plain for k, ls in tui.bots_items({"bots": {"k": dict(b[MGRBOT], mode="dev-manager")}}, NAMES, 109, {"k"}, T) for l in ls), "no mode below 110 columns"
    assert tui.columns(109, 29) == tui.columns(109) and dict(tui.columns(110))["bot"] == 16
    for v in (None, "", "none", 7, ["dev-manager"], {"a": 1}):   # an older host, the default, a value of another type: the 1.11.0 table
        assert [l.plain for _, ls in tui.bots_items(moded(mode=v), NAMES, 110, {"k"}, T) for l in ls] == \
               [l.plain for _, ls in tui.bots_items(moded(), NAMES, 110, {"k"}, T) for l in ls], v
    for w in (110, 111, 121, 122, 137, 200):
        assert 2 + sum(c for _, c in tui.columns(w, 29)) + len(tui.columns(w, 29)) - 1 == 2 + sum(c for _, c in tui.columns(w)) + len(tui.columns(w)) - 1 <= w, w
    assert "mode             -" in tui.entry_text("k", "k", tui.with_mode(b[OLDBOT]), []) and "mode             -" in tui.entry_text("k", "k", tui.with_mode({"mode": 7}), [])
    assert "mode             dev-manager" in tui.entry_text("k", "k", tui.with_mode({"mode": "dev-manager"}), [])
    print("ok: a mode other than none follows the bot's name, dim, at 110 columns and more (the bot column grows, the table keeps its width); "
          "none, a missing one or another type shows nothing; the all-fields text has mode, a dash when unknown")

    # 1.12.0: at 110 columns and more the status column is as wide as the widest status a closed row shows (15 cells at
    # least, 25 at most), and what it leaves goes to the bot column first. In 1.11.1 a 118-column pane drew
    # `StreamForQuestion  autoresea…` beside a status column of 25 cells holding `● ok`.
    SFQ = "StreamForQuestion"   # 17 cells; 35 with its mode
    ok = lambda key, **kw: dict(b[key], verdict="ok", **kw)

    def table(state, width, opened=()):
        items = tui.bots_items(state, NAMES, width, set(opened), T)
        head = next(l.plain for k, ls in items if k is None for l in ls if l.plain.split()[:2] == ["bot", "status"])
        lines = [l.plain for k, ls in items if k for l in ls]
        assert len({cell_len(l) for l in lines + [head]}) == 1 and cell_len(head) <= width, (width, "one width for every line, inside the terminal")
        return {k: ls[0].plain for k, ls in items if k}, head.index("host") - head.index("status") - 1, head

    arc = {"bots": {"a": ok(MGRBOT, bot=SFQ, mode="autoresearchclaw"), "m": ok(MGRBOT, mode="dev-manager"), "h": ok(HBOT)}}
    for width in (110, 118, 137, 200):
        rows, sw, head = table(arc, width)
        assert sw == 15, (width, sw, "`● ok` rows: the status column is its least width, not 25")
        assert rows["a"].startswith(f"▸ {SFQ}  autoresearchclaw ● ok "), (width, rows["a"])
        assert rows["h"].startswith(f"▸ {HANGUL} "), (width, "a 22-cell Hangul name is whole too", rows["h"])
        if width >= 118:   # at 110 the bot column takes cells from these three, and what is cut there ends in an ellipsis
            assert "#dev-bots " in rows["a"] and "@mention · 5 users " in rows["a"], (width, rows["a"])
        assert all("#dev-bots " in r or "…" in r for r in (rows["a"], rows["m"])), (width, "nothing is cut without an ellipsis")
        assert table(arc, width, {"a", "m", "h"})[2] == head, (width, "opening rows moves no column")
    # A problem row: its status fits, and a longer one widens the column for every row (the bot column keeps its mode whole
    # at 118 by taking cells from channel, receives and project, each cut with an ellipsis).
    down = dict(arc, bots=dict(arc["bots"], d=dict(b[PHOTO], mode="none")))
    unre = dict(arc, bots=dict(arc["bots"], d=dict(b[PHOTO], verdict="unreachable")))
    odd = dict(arc, bots=dict(arc["bots"], d=dict(b[PHOTO], verdict="a-verdict-this-version-does-not-know")))
    for width in (110, 118, 137, 200):
        rows, sw, _ = table(down, width)
        assert sw == 15 and "  ✕ DOWN 12m  " in rows["d"] and rows["a"].startswith(f"▸ {SFQ}  autoresearchclaw ● ok "), (width, sw, rows)
        rows, sw, _ = table(unre, width)
        assert sw == 19 and "  ✕ UNREACHABLE 12m  " in rows["d"] and rows["a"].startswith(f"▸ {SFQ}  autoresearchclaw ● ok "), (width, sw, rows)
        rows, sw, _ = table(odd, width)
        assert sw == 25 and "▲ a-verdict-this-version… " in rows["d"], (width, sw, rows["d"])
    # A name and mode longer than the bot column may be (45 cells): cut with an ellipsis, at any width.
    rows, _, _ = table({"bots": {"a": ok(MGRBOT, bot="n" * 30, mode="autoresearchclaw")}}, 200)
    assert rows["a"].startswith("▸ " + "n" * 30 + "  autoresearch… ● ok"), rows["a"]
    # An opened row: the reason and the note wrap inside the status column, as many more lines as it is narrower than 25.
    quiet = {"bots": {"h": dict(b[HBOT], mode="none")}}
    assert status_lines(tui.bots_items(quiet, NAMES, 118, {"h"}, T), "h") == ["▲ rate-limited", "Discord is", "rate-limiting", "this bot (HTTP", "429); nothing", "can be said ab…", "not posted", "(warning only)"]
    # Below 110 columns nothing changes: the fixed columns of 1.11.0, a status of 25 (an opened row wraps in it), no mode.
    assert status_lines(tui.bots_items(quiet, NAMES, 109, {"h"}, T), "h") == ["▲ rate-limited", "Discord is rate-limiting", "this bot (HTTP 429);", "nothing can be said abou…", "not posted (warning only)"]
    rows, sw, head = table(arc, 109)
    assert sw == 25 and tui.columns(109, 35, 15) == tui.columns(109) == [("bot", 16), ("status", 25), ("host", 9), ("channel", 47), ("last", 5)], (sw, tui.columns(109))
    assert rows["a"].startswith("▸ StreamForQuesti… ● ok" + " " * 22 + "local"), rows["a"]
    print("ok: at 110 columns and more the status column is as wide as the widest closed status (15 to 25 cells) and the bot column takes what it "
          "leaves: a 17-cell name with autoresearchclaw and a Hangul name are whole at 110, 118, 137 and 200; a problem row's status fits; "
          "opening a row moves no column; below 110 the table is as it was")

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
    # The status column is as wide as the widest closed status here (15 cells at least): the reason wraps inside it.
    assert opened[0].startswith("▾ photobot") and status_lines(tui.bots_items(s, NAMES, 110, {PHOTO}, T), PHOTO) == ["✕ DOWN 12m", "no plugin", "server for this", "bot", "posted 11m ago"], opened
    assert "from dongyong22," in opened[1] and "gpuvillain," in opened[2] and "junyong-dev-bot +2" in opened[3] and "DMs dongyong22" in opened[4], opened
    # Warning only is what the verdict is (the monitor's warn_only), not a not_posted record that 100 newer ones push out.
    for v, want in (("throttled", "not posted (warning only)"), ("apierror", "not posted (warning only)"), ("noreach", "not posted (warning only)"),
                    ("newverdict", "not posted (warning only)"), ("nostate", "not posted yet"), ("blind", "not posted yet"), ("stale", "not posted yet")):
        quiet = dict(s, alerts=[], bots={HBOT: dict(s["bots"][HBOT], verdict=v)})
        assert want in " ".join(status_lines(tui.bots_items(quiet, NAMES, 137, {HBOT}, T), HBOT)), (v, want)
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
        # The status column is 18 cells at 137 (`○ host unreachable`) and 25 at 100: the lines under it wrap in the first.
        assert rows[WOK][0].split()[:5] == ["▾", "wbot", "○", "host", "unreachable"] and " ".join(status_lines(items, WOK)[1:]) == "last seen ok 4h ago", rows[WOK]
        assert rows[WDN][0].split()[:5] == ["▾", "wdown", "○", "host", "unreachable"], rows[WDN]
        assert " ".join(status_lines(items, WDN)[1:]) == "last seen DOWN 4h ago posted 3h ago" and "the last detail" not in "".join(rows[WOK] + rows[WDN]), (rows[WOK], rows[WDN])
        assert rows[GHOST][0].split()[:4] == ["▸", "gbot", "●", "ok"], rows[GHOST]
        assert [lines[0].plain for k, lines in items if k is None and lines and lines[0].plain.lstrip().startswith("fix  ")] == [f"     fix  {FIX}   c copies it"]
    print("ok: bots of a host that cannot be reached are dim `host unreachable` rows between what needs a look and the healthy, in no count, "
          "with when their verdict was last seen and no fix line")

    # ---- the shell: the pane's renderer, title, tabs, footer, bar ----
    txt, y, h = tui.render(tui.bots_items(s, NAMES, 137, {HBOT}, T), HBOT, 137)
    lines = txt.plain.split("\n")
    # 8 lines: the status, its reason over five lines of the 15-cell status column, `not posted` / `(warning only)`
    assert HANGUL[:6] in lines[y] and h == 8 and all(cell_len(l) == 137 for l in lines[y:y + h]), (y, h)
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
    # Below 110 columns the Bots footer keeps every key and shortens its labels: all of it, `q quit` too, inside 80
    # columns (the footer with the e key is asserted with the access editor, below).
    assert all(tui.foot_line(t, 80).plain.split()[-2:] == ["q", "quit"] and cell_len(tui.foot_line(t, 80).plain.rstrip()) <= 80 for t in tui.TABS)
    assert tui.foot_line("alerts").plain.split() == "↑↓ select enter the post's text ←→ tabs q quit".split()
    assert tui.foot_line("config").plain.split() == "←→ tabs ↑↓ select enter settings a add host x remove l laptop q quit".split()
    assert tui.foot_line("config", 80).plain.split() == "←→ tabs ↑↓ select enter edit a add x remove l laptop q quit".split() and cell_len(tui.foot_line("config", 80).plain.rstrip()) <= 80
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

    # ---- ~/.ssh/config as text ----
    with tempfile.TemporaryDirectory() as d:
        home = Path(d)
        ssh = home / ".ssh"
        (ssh / "conf.d").mkdir(parents=True)
        (ssh / "config").write_bytes(
            b"# a comment with bytes that are no UTF-8: \xff\xfe\r\n"
            b"User early\r\n"                                     # above the first Host: for every host
            b"Include conf.d/*.conf ~/abs.conf missing.conf conf.d\r\n"
            b"Host lmd_dkim lmd79-host *.wild !neg ?q \"quoted name\" -oProxyCommand=x ev\x1bil # trailing words\r\n"
            b"  HostName = lmd-%h.example\r\n"
            b"  port 2222\r\n"
            b"Host=equals\r\n"
            b"HostName=equals.example\r\n"
            b"Match exec \"touch " + str(home / "pwned").encode() + b"\"\r\n"
            b"  HostName evil.example\r\n"
            b"  Include matched.conf\r\n"
            b"Host lmd*\r\n"
            b"  User late\r\n"
            b"  ProxyJump bastion\r\n"
            b"Host !lmd79-host lmd*\r\n"
            b"  HostName \xff.example\r\n"
            b"Host lmd_dkim\r\n"                                  # a second block for one alias: still one candidate
            b"  Port 1\r\n")
        (ssh / "conf.d" / "b.conf").write_text("Host from-b\n  HostName b.example\nInclude config\nInclude conf.d/a.conf\n")   # a cycle, and a file read before
        (ssh / "conf.d" / "a.conf").write_text("Host from-a\n  User ua\n")
        (ssh / "conf.d" / "skip.txt").write_text("Host not-included\n")
        (ssh / "matched.conf").write_text("Host in-a-match\n")
        (home / "abs.conf").write_text(f"Include {ssh}/deep0.conf\n")
        for i in range(12):                                       # 12 levels of Include: read 8 deep
            (ssh / f"deep{i}.conf").write_text(f"Host deep{i}\nInclude deep{i + 1}.conf\n")
        os.mkfifo(ssh / "conf.d" / "fifo.conf")                   # opening it would block for ever
        ran = subprocess.run
        subprocess.run = lambda *a, **k: (_ for _ in ()).throw(AssertionError("reading ssh config ran a command"))
        try:
            hosts = tui.ssh_hosts(home)
        finally:
            subprocess.run = ran
        by = {h["alias"]: h for h in hosts}
        assert sum(b[0] == ["from-a"] for b in tui.ssh_blocks(ssh / "config", home)) == 1, "a file is read once, whatever includes it again"
        assert [h["alias"] for h in hosts] == ["from-a", "from-b", "deep0", "deep1", "deep2", "deep3", "deep4", "deep5", "deep6", "lmd_dkim", "lmd79-host", "equals"], [h["alias"] for h in hosts]
        assert not (home / "pwned").exists() and "in-a-match" not in by and "not-included" not in by
        assert by["lmd_dkim"] == {"alias": "lmd_dkim", "user": "early", "hostname": "lmd-%h.example", "port": "2222", "proxyjump": "bastion"}, by["lmd_dkim"]
        assert by["from-a"] == {"alias": "from-a", "user": "early"} and by["from-b"]["hostname"] == "b.example" and by["equals"] == {"alias": "equals", "user": "early", "hostname": "equals.example"}, by
        assert tui.ssh_target(by["lmd_dkim"]) == "early@lmd-%h.example:2222 · via bastion" and tui.ssh_target(by["from-a"]) == "early@from-a:22"
        assert tui.ssh_target({}) == ":22" and tui.ssh_target({"alias": 7, "port": ["x"]}) == ":22", "a wrong-typed field is a missing one"
        # a HostName of bytes that are no UTF-8 is drawn as the replacement character, never raised on
        (ssh / "config").write_bytes(b"Host bin\n  HostName \xff\x1b[2J.example\n")
        assert tui.ssh_hosts(home) == [{"alias": "bin", "hostname": "�[2J.example"}], tui.ssh_hosts(home)
        # huge: 40,000 Host blocks in 1.2 MiB: 256 KiB are read, 2000 blocks and 500 candidates kept, in about half a second
        (ssh / "config").write_text("".join(f"Host big{i:05}\n  HostName h{i}\n" for i in range(40000)))
        t0 = time.time()
        big = tui.ssh_hosts(home)
        assert len(big) == tui.SSH_MAX_HOSTS == 500 and big[0] == {"alias": "big00000", "hostname": "h0"} and time.time() - t0 < 2, (len(big), time.time() - t0)
        # the byte cap by itself: a Host line past the first 256 KiB of a file is not read
        (ssh / "config").write_text("Host first\n" + "#" * tui.SSH_MAX_BYTES + "\nHost past-the-cap\n")
        assert [h["alias"] for h in tui.ssh_hosts(home)] == ["first"], [h["alias"] for h in tui.ssh_hosts(home)][:3]
        # a pattern of many stars against a long alias: matched as ssh does (`*` and `?`; a `[` is a plain character
        # there, so `web[12]` is no pattern for web1), in no time
        (ssh / "config").write_text(f"Host {'a' * 60} web1\nHost {'a*' * 16}b web[12]\n  User never\nHost a?*a w?b1\n  User u\n")
        t0 = time.time()
        assert tui.ssh_hosts(home) == [{"alias": "a" * 60, "user": "u"}, {"alias": "web1", "user": "u"}] and time.time() - t0 < 1, (tui.ssh_hosts(home), time.time() - t0)
        # an Include with a wildcard in more than three components of its path is skipped before any directory is walked
        (ssh / "w" / "x" / "y" / "z").mkdir(parents=True)
        (ssh / "w" / "x" / "y" / "three.conf").write_text("Host three\n")
        (ssh / "w" / "x" / "y" / "z" / "four.conf").write_text("Host four\n")
        (ssh / "config").write_text("Include w/*/?/t*.conf\nInclude */*/*/*/four.conf w/x/y/z/four.con[f]\n")
        walked, real = [], tui.glob.iglob
        tui.glob.iglob = lambda pattern, **k: walked.append(pattern) or real(pattern, **k)
        try:
            assert [h["alias"] for h in tui.ssh_hosts(home)] == ["three", "four"], tui.ssh_hosts(home)
        finally:
            tui.glob.iglob = real
        assert [w[len(str(ssh)) + 1:] for w in walked] == ["w/*/?/t*.conf", "w/x/y/z/four.con[f]"], walked
        # an Include of itself, a config that is a directory, one that cannot be read, none at all: no candidates, no error
        (ssh / "config").write_text("Include config\nInclude ~/.ssh/config\nHost only\n")
        assert [h["alias"] for h in tui.ssh_hosts(home)] == ["only"]
        (ssh / "config").chmod(0)
        assert tui.ssh_hosts(home) == [] or os.geteuid() == 0
        (ssh / "config").unlink()
        (ssh / "config").mkdir()
        assert tui.ssh_hosts(home) == [] and tui.ssh_hosts(home / "nowhere") == []
    print("ok: ~/.ssh/config is read as text: Host aliases in file order through Includes (globs, ~/, relative to ~/.ssh, 8 levels, a cycle, each file "
          "once), patterns and Match blocks no candidates and never evaluated, HostName/User/Port/ProxyJump first value wins; CRLF, bytes that are no "
          "UTF-8, a FIFO, a huge, unreadable or missing file, a pattern of many stars neither hang nor raise; 256 KiB of a file are read; an Include "
          "with more than three wildcard components is skipped unwalked")

    hs = [{"alias": "wmac", "hostname": "wmac.example"}, {"alias": "lmd-a100"}, {"alias": "lmd_dkim", "user": "dykim"}, {"alias": "almd"}, {"alias": "l-m-d"},
          {"alias": "bastion", "hostname": "gw.lmd.example"}]
    assert [h["alias"] for h in tui.fuzzy("lmd", hs)] == ["lmd-a100", "lmd_dkim", "almd", "l-m-d", "bastion"], [h["alias"] for h in tui.fuzzy("lmd", hs)]
    assert tui.fuzzy("", hs) == hs and tui.fuzzy("zzz", hs) == [] and [h["alias"] for h in tui.fuzzy("LMD_", hs)] == ["lmd_dkim"]
    assert [h["alias"] for h in tui.fuzzy("dykim", hs)] == ["lmd_dkim"], "a query the alias does not hold is looked for in the target"
    print("ok: the picker's search: an alias that starts with the query, then one that holds it, then one that holds its characters in order, "
          "then a target that holds it; all in file order for no query")

    # run_capped: what the TUI runs (the hosts CLI, `ssh -G`) ends at its cap with every process it started, hands a
    # value over on stdin, and gives back text that can be drawn.
    t0 = time.time()
    rc, out, err = tui.run_capped(["sh", "-c", "echo started; sleep 30 & sleep 30"], 0.3)
    assert (rc, out) == (124, "started") and err == "no answer within 0.3 s" and time.time() - t0 < 2, (rc, out, err, time.time() - t0)
    assert tui.run_capped(["/nonexistent/claude-discord", "hosts"], 1)[::2] == (127, "cannot run /nonexistent/claude-discord: No such file or directory")
    feed = type("Feed", (), {"sending": "KEY=secret\n"})()   # the text is read from an attribute: it is no argument and no local
    assert tui.run_capped(["sh", "-c", "cat; printf 'e\\033[2Jrr\\n' >&2; exit 3"], 5, feed) == (3, "KEY=secret", "e[2Jrr")
    assert len(tui.run_capped(["sh", "-c", "head -c 200000 /dev/zero | tr '\\0' x"], 5)[1]) == 65536
    with tempfile.TemporaryDirectory() as d:
        g = stub(d, 'echo "$*" > "$(dirname "$0")/g.args"; printf "user dykim\\nhostname h.example\\nidentityfile ~/.ssh/id\\nproxycommand ssh -W %%h:%%p \\033]0;T\\007gw\\n"')
        assert tui.ssh_effective(g, "lmd_dkim") == ["user dykim", "hostname h.example", "proxycommand ssh -W %h:%p ]0;Tgw"], tui.ssh_effective(g, "lmd_dkim")
        assert (Path(d) / "g.args").read_text() == "-G -- lmd_dkim\n", "`--` before the alias: it is never an option"
        assert tui.ssh_effective(stub(d, 'echo "ssh: Could not resolve hostname" >&2; exit 255'), "x") == ["nothing (exit 255: ssh: Could not resolve hostname)"]
    print("ok: a command the TUI runs is killed with its children at its cap, takes a value on stdin, and its output is cut and cleaned; "
          "ssh -G is asked with -- before the alias and gives the lines that say where a connection goes")

    # ---- access (1.13.0): the editor's model, its change words, what widens, the people, the drawing ----
    DOC = tui.clean(access_doc())
    was = tui.access_model(DOC)
    assert was == {"groups": {"900": {"mention": True, "allow": ["111", "222"]}, "901": {"mention": False, "allow": []},
                              "1234": {"mention": False, "allow": []}}, "dm": "allowlist", "dm_allow": ["111"], "mode": "none"}, was
    # off is an allowlist with nobody on it; the plugin's own `disabled` and any word it does not know (pairing to it) are told apart.
    dm = lambda p, a: tui.access_model({"policy": {"dm": p, "dm_allow": a}})["dm"]
    assert [dm("allowlist", []), dm("allowlist", ["1"]), dm("pairing", ["1"]), dm("disabled", ["1"]), dm("odd", []), dm(None, [])] == ["off", "allowlist", "pairing", "disabled", "pairing", "pairing"]
    # Another program's document: a wrong type anywhere reads as missing, an id that is not digits is none; nothing raises.
    for junk in ({}, [], None, "x", {"policy": 7, "mode": 7}, {"policy": {"groups": [7, {"id": 5}, {"id": "9x"}, {"id": "9", "allow": "111", "mention": "no"}], "dm_allow": [7, "1\n", "22"]}}):
        m = tui.access_model(junk)
        assert set(m) == {"groups", "dm", "dm_allow", "mode"} and all(g["allow"] == [] and g["mention"] for g in m["groups"].values()) and set(m["groups"]) <= {"9"}, (junk, m)
        tui.access_lines(junk, m, m, 0, "left", 0, 100), tui.access_people(junk, m, m), tui.find_person("x", junk), tui.access_left(junk, m, m)
    assert tui.access_model({"policy": {"dm_allow": [7, "1\n", "22"]}})["dm_allow"] == ["22"]
    print("ok: the access model is the policy and the mode of access --json's document (off is an allowlist with nobody), and a document of the wrong shape raises nothing")

    def edit(**kw):
        now = json.loads(json.dumps(was))
        for path, v in kw.items():
            keys = path.split("__")
            at = now
            for k in keys[:-1]:
                at = at.setdefault(k, {})
            if v is None:
                at.pop(keys[-1])
            else:
                at[keys[-1]] = v
        return now
    words = lambda now, owner="111": tui.access_words(was, now, owner)
    assert words(edit()) == [] and tui.access_wide(was, edit()) == set()
    assert words(edit(groups__900__mention=False)) == ["mention:900=off"] and tui.access_wide(was, edit(groups__900__mention=False)) == {"mention:900"}
    assert words(edit(groups__901__mention=True)) == ["mention:901=on"] and tui.access_wide(was, edit(groups__901__mention=True)) == set()
    assert words(edit(groups__900__allow=[])) == ["allow:900=any"] and tui.access_wide(was, edit(groups__900__allow=[])) == {"any:900"}
    # The additions before the removals: the list is never empty on the way (the CLI refuses a removal that empties one).
    assert words(edit(groups__900__allow=["333"])) == ["allow:900+333", "allow:900-111", "allow:900-222"] and tui.access_wide(was, edit(groups__900__allow=["333"])) == {"new:333"}
    # A sender put on a channel that took anyone narrows it: no widening, whoever it is.
    assert words(edit(groups__901__allow=["333"])) == ["allow:901+333"] and tui.access_wide(was, edit(groups__901__allow=["333"])) == set()
    assert words(edit(groups__901=None)) == ["channel-901"]
    # A new channel: the CLI starts it with an @mention required and the owner alone; the words say what differs from that.
    assert words(edit(groups__902={"mention": True, "allow": ["111"]})) == ["channel+902"]
    new = edit(groups__902={"mention": False, "allow": ["222", "444"]})
    assert words(new) == ["channel+902", "mention:902=off", "allow:902+222", "allow:902+444", "allow:902-111"] and tui.access_wide(was, new) == {"mention:902", "new:444"}
    assert words(edit(groups__902={"mention": True, "allow": []})) == ["channel+902", "allow:902=any"]
    assert words(edit(dm="pairing")) == ["dm=pairing"] and tui.access_wide(was, edit(dm="pairing")) == {"dm"}
    assert words(edit(dm="off", dm_allow=[])) == ["dm=off"] and words(edit(dm_allow=[])) == ["dm=off"] and tui.access_wide(was, edit(dm="off", dm_allow=[])) == set()
    assert words(edit(dm_allow=["111", "222"])) == ["dm+222"] and tui.access_wide(was, edit(dm_allow=["111", "222"])) == {"dm:222"}
    assert words(edit(dm_allow=["222"])) == ["dm+222", "dm-111"]
    assert words(edit(mode="dev-manager")) == ["mode=dev-manager"]
    off = tui.access_model({"policy": {"dm": "allowlist", "dm_allow": []}})
    assert tui.access_words(off, dict(off, dm="allowlist", dm_allow=["5"]), "") == ["dm+5"], "from off to an allowlist is one more person, no policy word"
    assert tui.access_words(off, dict(off, dm="pairing"), "") == ["dm=pairing"]
    dis = tui.access_model({"policy": {"dm": "disabled", "dm_allow": ["5"]}})
    assert tui.access_words(dis, dict(dis, dm="allowlist"), "") == ["dm=allowlist"] and tui.access_wide(dis, dict(dis, dm="allowlist")) == {"dm"} and tui.access_words(dis, dict(dis), "") == []
    for now in (new, edit(dm="pairing", dm_allow=["222"]), edit(groups__900=None, mode="autoresearchclaw")):
        assert all(tui.re.fullmatch(r"[a-z0-9:+=-]+", w) for w in words(now)), words(now)
    print("ok: the change words turn the model as read into the model as edited (a new channel from the CLI's own start, additions before removals, off as one word), and what widens is told from what does not")

    people = tui.access_people(DOC, was, was)
    assert [(p["name"], p["tag"]) for p in people] == [("dongyong22", "owner"), ("gpuvillain", "")], people
    assert [p["name"] for p in tui.access_people(DOC, was, edit(groups__900__allow=["111", "555", "9999"]))] == ["9999", "dongyong22", "gpuvillain", "peerbot"], "a person with no name is the id; bots last"
    find = lambda t: tui.find_person(t, DOC)
    # A name kept here (111, 555, 556) or of a person on the bot's lists (222, by the name Discord gave): the whole name
    # first, then the one it starts; never a part inside it, and never a name only the member list gave (333, 444).
    assert find("12345") == ("12345", "") and find(" @GPUvillain ") == ("222", "") and find("dong") == ("111", "") and find("PEERBOT") == ("555", "")
    assert find("junyong")[0] is None and find("junyong-dev-bot")[0] is None and find("pho[2Jto")[0] is None and find("villain")[0] is None and find("yong22")[0] is None
    assert find("nobody")[0] is None and "numeric user id" in find("nobody")[1] and find("")[0] is None
    assert find("peer") == (None, "2 people match: peerbot, peerbot-old"), find("peer")
    assert find("x" * 30)[0] is None and find("12345678901234567890123")[0] is None, "more than 20 digits is no id"
    print("ok: the people listed are those on a list before or now; a typed name is the one person it names among the names kept here and the bot's lists "
          "(the whole name first, then the one it starts), never a name only Discord's member list gave; digits are an id, and several matches are named")

    def lines(now, at=0, side="left", prow=0, width=112):
        return [l.plain.rstrip() for l in tui.access_lines(DOC, was, now, at, side, prow, width)]
    got = lines(was, at=1)
    assert got[0].split() == "channels in Tor-AIC @mention who may write to it in #dev-bots".split(), got[0]
    assert got[1].split() == "[ ] #fo[2Jrum forum [✓] dongyong22 owner".split() and got[2].split() == "▸ [✓] #dev-bots main required [✓] gpuvillain".split(), got[1:3]
    assert got[3].split() == "[✓] #bot-health any message [ ] anyone in the channel".split(), got[3]
    assert got[4].split() == "[ ] #general bot cannot read a adds a person by name or id".split() and got[5].split() == "[ ] #odd ? not known if readable".split(), got[4:6]
    assert got[6].split() == "[✓] #1234 not in this server's list any message".split(), got[6]
    assert got[8].split() == "DMs (●) allowlist ( ) off ( ) pairing from dongyong22".split() and got[9].split() == "mode (●) none ( ) dev-manager ( ) autoresearchclaw".split(), got[8:]
    assert all(cell_len(l) <= 112 for l in got) and all(cell_len(l) <= 70 for l in lines(was, width=70))
    # The right pane follows the left cursor: a channel the bot does not listen in, the DMs, the mode.
    assert "the bot does not listen here: space adds the channel" in lines(was, at=0)[1] and "who may DM it, and answers its permission prompts" in lines(was, at=6)[0]
    assert "[✓] anyone in the channel" in "\n".join(lines(was, at=2)) and "▸ [✓] anyone" in "\n".join(lines(was, at=2, side="right", prow=2))
    # What widens is drawn in the alert colour: the mention rule, `anyone`, a new person, pairing.
    def styled(now, text, **kw):
        return [str(sp.style) for l in tui.access_lines(DOC, was, now, kw.pop("at", 1), "left", 0, 112) for sp in l.spans if text in l.plain[sp.start:sp.end]]
    assert tui.ALERT in " ".join(styled(edit(groups__900__mention=False), "any message")) and tui.ALERT not in " ".join(styled(was, "required"))
    assert tui.ALERT in " ".join(styled(edit(groups__900__allow=["111", "222", "333"]), "junyong-dev-bot")) and tui.ALERT in " ".join(styled(edit(dm="pairing"), "pairing"))
    disabled = tui.access_model(dict(DOC, policy=dict(DOC["policy"], dm="disabled")))
    assert "(●) disabled" in tui.access_lines(DOC, disabled, disabled, 6, "left", 0, 112)[8].plain and "disabled" not in got[8]
    # More channels than the list shows: a window around the cursor, and where it is.
    many = dict(DOC, channels=[{"id": str(1000 + i), "name": f"c{i:02}", "kind": "text", "read": True} for i in range(40)])
    mm = tui.access_model(many)
    far = [l.plain for l in tui.access_lines(many, mm, mm, 30, "left", 0, 112)]
    assert len(far) == 17 and "▸ [ ] #c30" in "\n".join(far) and "31 of 40 channels" in "\n".join(far) and "#c00" not in "\n".join(far), far
    print("ok: the editor draws the server's channels ([✓] listened in, the mention rule, main, bot cannot read, ? when it cannot be told), the DM policy and the mode as radios, the senders beside the cursor's row, what widens in the alert colour, and a window over a long list")

    assert tui.foot_line("bots").plain.split() == "↑↓ select space expand enter all fields e access c copy fix ←→ tabs q quit".split()
    assert tui.foot_line("bots", 109).plain.split() == "↑↓ move space open enter all e edit c copy ←→ tabs q quit".split()
    rc, out, err = tui.run_capped(["sh", "-c", "head -c 70000 /dev/zero | tr '\\0' a"], 5)
    big = tui.run_capped(["sh", "-c", "head -c 70000 /dev/zero | tr '\\0' a"], 5, limit=1 << 22)
    assert len(out) == 65536 and len(big[1]) == 70000, "access --json's document may be longer than the 64 KiB every other answer is cut at"
    import builtins
    asked, real = [], builtins.input
    builtins.input = lambda prompt="": asked.append(prompt) or ""
    try:
        assert tui.in_terminal(["sh", "-c", "exit 4"]) == 4 and tui.in_terminal(["/nonexistent/x"]) == 127 and len(asked) == 2 and "[exit 4]" in asked[0], asked
    finally:
        builtins.input = real
    print("ok: the Bots footer names e; a command run on the handed-over terminal returns its exit status after one line is read, so what it printed stays until then")


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
                                        "channel_name": "dev", "last_message_at": iso(n - 100), "mode": "dev-manager",
                                        "access": dict(ACCESS, groups=[dict(g, name="n" + g["id"]) for g in ACCESS["groups"]])},
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
                tui.entry_text(k, k, tui.with_mode(e) if scope == "bots" else e, s.get("alerts"))

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
    script.write_text("kill -STOP $$\n")   # alive until killed, and no child that would outlive it holding this test's output open
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


async def settle(app, pilot):
    """Until the worker threads are done (a hosts CLI call) and what they handed back is drawn. Again while one runs:
    what a worker hands back may start another (a dialog's result, then the call that follows it)."""
    while True:
        await app.workers.wait_for_complete()
        await pilot.pause()
        if all(w.is_finished for w in app.workers):
            return


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
    assert foot.split() == "↑↓ move space open enter all e edit c copy ←→ tabs q quit".split() and cell_len(foot.rstrip()) <= app.size.width == 80, foot
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
    assert app.opened == {PHOTO, HBOT} and "(warning only)" in text(app, "#body") and "DMs pairing" in text(app, "#body")   # `not posted` is the line above it
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
    for want in (PHOTO, "servers          0", "mode             -", "posted_at", '"dm_allow": ["111"]', "posts for this key:", "finding  down  sent"):
        assert want in raw, (want, raw)
    await pilot.press("down", "right", "space")   # the row keys belong to the main view
    assert isinstance(app.screen, tui.Detail) and app.tab == "bots" and app.cursor["bots"] == PHOTO and app.opened == {HBOT}
    await pilot.press("escape")
    # A new pass: the selected row stays selected, open rows stay open, and what changed is shown.
    await pilot.press("down", "down")
    assert app.cursor["bots"] == MGRBOT
    state = json.loads((app.state_dir / "state.json").read_text())
    state["bots"][MGRBOT].update(verdict="stale", detail="unanswered for 22m", fix="x", mode="dev-manager")   # it moves up, among the problems
    (app.state_dir / "state.json").write_text(json.dumps(state))
    os.utime(app.state_dir / "state.json", (1, 1))   # a different mtime, whatever the clock's resolution
    app.refresh_state()
    assert app.cursor["bots"] == MGRBOT and app.opened == {HBOT} and "✕ STUCK" in row_of(app, "mgr "), row_of(app, "mgr ")
    assert row_of(app, "mgr ").startswith("▸ mgr  dev-manager "), row_of(app, "mgr ")
    await pilot.press("enter")
    await pilot.pause()
    assert "mode             dev-manager" in str(app.screen.query_one("#body-detail").render())
    await pilot.press("escape")
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
    keys = [k for k, _ in app.items(time.time()) if k is not None]
    assert len(keys) == 25 and keys[-1] == NOTOK
    app.cursor["bots"] = keys[-2]       # set, not walked there (24 presses): the pane is still at the top
    await pilot.press("down", "down")   # to the last row, then past it: the cursor stops there and the pane has followed
    await pilot.pause()
    assert app.cursor["bots"] == NOTOK
    _, y, h = tui.render(app.items(time.time()), NOTOK, 100)
    assert pane.scroll_offset.y > 0 and pane.scroll_offset.y <= y and y + h <= pane.scroll_offset.y + pane.size.height, (pane.scroll_offset, y, h, pane.size)
    app.cursor["bots"] = keys[1]
    await pilot.press("up", "up")
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
    assert row_of(app, "pho]52;c;aGFjaw==\\to ") and "#c]0;TITLE\\" in row_of(app, "pho") and row_of(app, "eviltxt.sh") and row_of(app, "kb x")
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
    # Enter on a host row is its settings (1.12.0). With no wrapper (as here) nothing can be read or changed, and it says so.
    await pilot.press("down", "down", "enter")
    await settle(app, pilot)
    assert isinstance(app.screen, tui.HostEdit) and text(app.screen, "#h-msg").startswith("started without the wrapper"), text(app.screen, "#h-msg")
    assert text(app.screen, "#h-last") == "last check      ○ unreachable 4h   ssh to wmac failed (exit 255), also with ControlPath=none   checked 1m ago", text(app.screen, "#h-last")
    assert "ControlPath=none wmac 'echo up'" in text(app.screen, "#h-fix") and app.screen.query_one("#h-save").disabled
    await pilot.press("escape")
    assert len(app.screen_stack) == 1


SSH_CONFIG = ("Host lmd_dkim\n  HostName lmd-dkim.example\nHost lmd79-host lmd-a100\nHost lmd-gpu-01\n  ProxyJump bastion\n"
              "Host wmac\n  HostName wmac.example\nHost *\n  User dykim\nMatch exec \"touch /tmp/claude-discord-tui-test-pwned\"\n")
# The hosts CLI as the picker meets it: a host that answers (slowly, with a warning that looks like markup), one that is
# already listed, one that does not answer (exit 5, then added unchecked), and one that is this same home (exit 4).
HOSTS_CLI = r'''d=$(dirname "$0"); echo "$*" >> "$d/args"
case "$*" in
  *"add --dry-run wmac") echo "claude-discord: hosts: wmac is already in /p/hosts" >&2; exit 3;;
  *"add --dry-run "*) for a; do :; done; echo "ssh -o BatchMode=yes -o ConnectTimeout=8 -- $a '~/.local/bin/claude-discord --version --host-id'"
    echo "checks it and writes ~/.claude-discord/host-id there if missing; adding it writes ~/.claude-discord/watchers/mgr";;
  *"add lmd_dkim") n=0; while [ ! -e "$d/go" ] && [ $n -lt 300 ]; do sleep 0.01; n=$((n + 1)); done   # it ends when the case lets it (3 s at most): what is checked meanwhile needs no timing
    echo "claude-discord: hosts: added lmd_dkim to /p/hosts"; echo "claude-discord: hosts: warning: lmd_dkim is already watched by [bold]other" >&2;;
  *"add lmd-a100 laptop") printf 'claude-discord: hosts: lmd-a100 did not answer (ssh exit 255): \033[2Jtimed out. Not added\n' >&2; exit 5;;
  *"add --no-probe lmd-a100 laptop") echo "claude-discord: hosts: added lmd-a100 to /p/hosts";;
  *"add newbox") echo "claude-discord: hosts: newbox is the same home as local" >&2; exit 4;;
esac'''


def ssh_home(app, config=SSH_CONFIG):
    """Gives the app a home with that ~/.ssh/config (none for None) and an `ssh` that logs its arguments and answers -G."""
    d = Path(app.state_dir)
    (d / "home" / ".ssh").mkdir(parents=True)
    if config is not None:
        (d / "home" / ".ssh" / "config").write_text(config)
    ssh = d / "ssh-stub"
    ssh.write_text('#!/bin/sh\necho "$*" >> "$(dirname "$0")/ssh.args"\nprintf "user dykim\\nhostname lmd-dkim.example\\nport 22\\nproxycommand ssh -W %%h:%%p \\033]0;T\\007gw\\n"\n')
    ssh.chmod(0o755)
    app.home, app.ssh = d / "home", str(ssh)
    app.ASK_GAP = 0   # every change asks the monitor; the 10 s between two requests have their own checks
    app.said_all = []
    # What a dialog leaves to say, instead of a toast; said as markup it would not be the text it is.
    app.notify = lambda m, **k: app.said_all.append(m if k.get("markup") is False else ("markup", m))


CHECKS = "claude-discord: monitor: mgr checks its hosts at its next tick (within 30 s; a minute after its last pass began at the earliest)"
NO_MONITOR = "claude-discord: monitor: no monitor of mgr runs here, so nothing was asked (claude-discord monitor --start mgr starts the backend)"
# The stub's `monitor --check`: the monitor's own answer, or its refusal once the case made a `nomonitor` file.
CHECK_STUB = f'''
case "$*" in "monitor --check mgr") [ -e "$d/nomonitor" ] && {{ echo "{NO_MONITOR}" >&2; exit 1; }}; echo "{CHECKS}";; esac'''


def checks(app):
    """How many times the wrapper stub was asked `monitor --check mgr`."""
    return (Path(app.state_dir) / "args").read_text().splitlines().count("monitor --check mgr")


def cli_calls(app):
    """The wrapper stub's `hosts` calls (the mount's `monitor --ensure` is in the file too)."""
    return [l for l in (Path(app.state_dir) / "args").read_text().splitlines() if l.startswith("hosts ")]


async def add_host(app, pilot):
    ssh_home(app)
    cands = lambda: str(app.screen.query_one("#cands").render()).split("\n")
    info = lambda: str(app.screen.query_one("#info").render())
    await pilot.press("a")
    assert len(app.screen_stack) == 1, "a is the Configuration tab's key"
    await pilot.press("left")
    assert "+ Add host" in body(app)[2] and " a  add host " in text(app, "#foot")
    # ~/.ssh/config is read in a worker thread, never on the event loop: the dialog is up at once and says so.
    gate, on_loop, real = threading.Event(), [], tui.ssh_hosts

    def slow(home):
        on_loop.append(threading.current_thread() is threading.main_thread())
        gate.wait(5)
        return real(home)
    tui.ssh_hosts = slow
    try:
        await pilot.press("a")
        await pilot.pause()
        assert isinstance(app.screen, tui.AddHost) and isinstance(app.focused, tui.Input)
        assert cands() == ["reading ~/.ssh/config …"] and info() == "reading ~/.ssh/config …" and on_loop == [False], (cands(), info(), on_loop)
        gate.set()
        await settle(app, pilot)
    finally:
        tui.ssh_hosts = real
    assert cands()[0] == "5 matches" and cands()[1].split() == ["▸", "lmd_dkim", "dykim@lmd-dkim.example:22"], cands()
    assert cands()[5].split() == ["wmac", "dykim@wmac.example:22", "already", "checked"], cands()[5]
    await pilot.press("l", "m", "d", "q")   # a letter that is a key of the main view (q quits) is text here
    assert app.return_code is None and cands() == ["0 matches", "▸ lmdq      as typed: not in ~/.ssh/config"], cands()
    await pilot.press("backspace")
    assert cands() == ["4 matches", "▸ lmd_dkim    dykim@lmd-dkim.example:22", "  lmd79-host  dykim@lmd79-host:22", "  lmd-a100    dykim@lmd-a100:22",
                       "  lmd-gpu-01  dykim@lmd-gpu-01:22 · via bastion", "  lmd         as typed: not in ~/.ssh/config"], cands()
    await pilot.press("down", "down", "down", "down", "down", "up", "up")   # past the last row, then back two
    assert cands()[3].startswith("▸ lmd-a100") and app.tab == "config", "the arrows move the candidate, not the row or the tab under the dialog"
    await pilot.press("up", "up", "enter")
    await settle(app, pilot)
    # First Enter: nothing is added. The exact command the CLI will run and what the add writes on that machine (the
    # two lines of --dry-run), what ssh -G says of this one alias, cleaned, and the kind it will be added as.
    shown = ["enter checks it first:  ssh -o BatchMode=yes -o ConnectTimeout=8 -- lmd_dkim '~/.local/bin/claude-discord --version --host-id'",
             "checks it and writes ~/.claude-discord/host-id there if missing; adding it writes ~/.claude-discord/watchers/mgr",
             "ssh -G lmd_dkim says:  user dykim · hostname lmd-dkim.example · port 22 · proxycommand ssh -W %h:%p ]0;Tgw",
             "added as:  (●) server   ( ) laptop    l switches; a laptop that is off is not alerted"]
    assert info().split("\n")[:4] == shown, info()
    assert cli_calls(app) == ["hosts --bot mgr add --dry-run lmd_dkim"] and (Path(app.state_dir) / "ssh.args").read_text() == "-G -- lmd_dkim\n"
    # Second Enter: the add, in a worker (the stub's waits for this case). Meanwhile the screen says so and a third
    # Enter does nothing. It cannot be called back (it writes on the host and in the ledger): Escape and q say so,
    # and the dialog stays for its outcome.
    await pilot.press("enter")
    assert info() == "checking lmd_dkim ..." and app.screen.query_one("#q").disabled, info()
    await pilot.press("enter", "escape")
    assert isinstance(app.screen, tui.AddHost) and info() == "adding … (cannot be cancelled once started)", info()
    app.screen.say("")
    await pilot.press("q")
    assert isinstance(app.screen, tui.AddHost) and app.return_code is None and info() == "adding … (cannot be cancelled once started)", (app.return_code, info())
    (Path(app.state_dir) / "go").write_text("")
    await settle(app, pilot)
    assert len(app.screen_stack) == 1 and cli_calls(app)[1:] == ["hosts --bot mgr add lmd_dkim"], cli_calls(app)
    # The change is said with what the monitor answered to `monitor --check`: it is asked for a pass after every change.
    assert app.said_all == ["claude-discord: hosts: added lmd_dkim to /p/hosts\nclaude-discord: hosts: warning: lmd_dkim is already watched by [bold]other\n" + CHECKS], app.said_all
    assert checks(app) == 1
    # A host that does not answer (exit 5): said, cleaned, and a third Enter adds it unchecked. Chosen as a laptop
    # (l at the step that shows the check): both calls pass the word.
    await pilot.press("a")
    await settle(app, pilot)
    q = app.screen.query_one("#q")
    q.value = "a100"
    await pilot.press("enter")
    await settle(app, pilot)
    # The query edited after the first Enter is a new search: the next Enter shows again, it never adds the alias of before.
    q.value = "a10"
    await pilot.pause()
    assert app.screen.step == "search" and info() == "enter shows the check that runs first · esc cancel", (app.screen.step, info())
    await pilot.press("enter")
    await settle(app, pilot)
    assert cli_calls(app)[-2:] == ["hosts --bot mgr add --dry-run lmd-a100"] * 2 and app.screen.step == "shown", cli_calls(app)
    # l switches the kind at this step (in the search it is a letter of the query, as above).
    await pilot.press("l")
    assert info().split("\n")[3].startswith("added as:  ( ) server   (●) laptop") and q.value == "a10" and app.screen.step == "shown", info()
    await pilot.press("enter")
    await settle(app, pilot)
    assert cli_calls(app)[-1] == "hosts --bot mgr add lmd-a100 laptop", cli_calls(app)[-1]
    assert isinstance(app.screen, tui.AddHost) and info() == ("claude-discord: hosts: lmd-a100 did not answer (ssh exit 255): [2Jtimed out. Not added\n"
                                                             "enter adds it unchecked (hosts add --no-probe) · esc cancel"), info()
    await pilot.press("enter")
    await settle(app, pilot)
    assert len(app.screen_stack) == 1 and cli_calls(app)[-1] == "hosts --bot mgr add --no-probe lmd-a100 laptop" and app.said_all[-1] == "claude-discord: hosts: added lmd-a100 to /p/hosts\n" + CHECKS
    # An alias the configuration does not name can be typed; the same home (exit 4) is said and nothing is added.
    await pilot.press("a")
    await settle(app, pilot)
    app.screen.query_one("#q").value = "newbox"
    await pilot.pause()
    assert cands() == ["0 matches", "▸ newbox    as typed: not in ~/.ssh/config"], cands()
    await pilot.press("enter")
    await settle(app, pilot)
    await pilot.press("enter")
    await settle(app, pilot)
    assert isinstance(app.screen, tui.AddHost) and info() == "claude-discord: hosts: newbox is the same home as local" and app.screen.step == "search", info()
    # What is no alias is no candidate, and Enter on it runs nothing.
    n = len(cli_calls(app))
    for bad in ("-oProxyCommand=x", "x y;$(id)"):
        app.screen.query_one("#q").value = bad
        await pilot.pause()
        assert cands() == ["0 matches"], (bad, cands())
        await pilot.press("enter")
        await settle(app, pilot)
    assert len(cli_calls(app)) == n and all("-G -- -" not in l for l in (Path(app.state_dir) / "ssh.args").read_text().splitlines())
    # An alias the last pass already checked: the CLI's refusal (exit 3) is shown.
    app.screen.query_one("#q").value = "wmac"
    await pilot.pause()
    await pilot.press("enter")
    await settle(app, pilot)
    assert info() == "claude-discord: hosts: wmac is already in /p/hosts" and "\x1b" not in info()
    await pilot.press("escape")
    assert len(app.screen_stack) == 1 and len(app.said_all) == 2 and not Path("/tmp/claude-discord-tui-test-pwned").exists()
    assert checks(app) == 2, "a pass is asked for after each change, and for nothing else (a dry run, a refusal, a closed dialog)"


async def add_host_bare(app, pilot):
    ssh_home(app, None)   # no ~/.ssh/config at all, and no wrapper: the dialog still opens, and says why nothing can be added
    await pilot.press("left", "a")
    await settle(app, pilot)
    assert str(app.screen.query_one("#cands").render()) == "0 matches" and "type the ssh alias" in str(app.screen.query_one("#info").render())
    await pilot.press("b", "enter")
    await settle(app, pilot)
    assert str(app.screen.query_one("#info").render()).startswith("started without the wrapper"), str(app.screen.query_one("#info").render())


# The hosts CLI as the host popup meets it: the ledger's lines by name (two for wmac: every env key of both), a set that
# keeps what came on stdin, an rm, a laptop switch. `bad` is refused by set.
LEDGER_JSON = json.dumps({"manager": "mgr", "ledger": "/p/hosts", "ignored": 0, "hosts": [
    {"alias": "local", "laptop": False, "name": "lmd79", "env": ["HTTPS_PROXY"], "skipped": 0},
    {"alias": "wmac", "laptop": True, "name": "w\x1b[2Jmac", "env": ["HTTPS_PROXY", "NO_PROXY"], "skipped": 0},
    {"alias": "wmac", "laptop": False, "name": "", "env": ["NO_PROXY", "EXTRA"], "skipped": 1},
    {"alias": "old", "laptop": "yes", "name": 7, "env": {"A": 1}, "skipped": None}, "x", None]})
EDIT_CLI = r'''d=$(dirname "$0"); echo "$*" >> "$d/args"
case "$*" in
  *"list --json") cat "$d/ledger.json";;
  *"set bad --stdin") cat > /dev/null; echo "claude-discord: hosts: K: a value holds no space [/]" >&2; exit 2;;
  *"set "*" --stdin") cat > "$d/stdin"; echo "claude-discord: hosts: changed $5 in /p/hosts (2 lines)";;
  *"rm "*) echo "claude-discord: hosts: removed $5 from /p/hosts";;
  *"laptop bad "*) echo "claude-discord: hosts: bad is not in /p/hosts" >&2; exit 3;;
  *"laptop "*) echo "claude-discord: hosts: changed $5 in /p/hosts (1 line)";;
esac'''


def edit_cli(d, ledger=LEDGER_JSON):
    (Path(d) / "ledger.json").write_text(ledger)
    return stub(d, EDIT_CLI + CHECK_STUB)


def drawn(app):
    """Everything the terminal is sent for the screen as it stands."""
    return app.screen._compositor.render_full_update().render_segments(app.console)


async def host_edit(app, pilot):
    ssh_home(app)
    d, scr = Path(app.state_dir), lambda sel: text(app.screen, sel)
    await pilot.press("left", "down", "down", "enter")
    await settle(app, pilot)
    # What the popup shows comes from three places: the ledger through `hosts list --json` (name, kind, env KEY NAMES),
    # ~/.ssh/config as text (the target) and the state (the last check). No value is anywhere, and the name is cleaned.
    assert isinstance(app.screen, tui.HostEdit) and cli_calls(app) == ["hosts --bot mgr list --json"], cli_calls(app)
    assert scr("#h-title") == "Host · wmac" and app.screen.query_one("#h-name").value == "w[2Jmac" and app.focused.id == "h-name"
    assert scr("#h-kind").startswith("kind            ( ) server   (●) laptop"), scr("#h-kind")
    assert scr("#h-env").split() == "env HTTPS_PROXY •••• NO_PROXY •••• EXTRA ••••".split(), scr("#h-env")
    assert scr("#h-target") == "target          dykim@wmac.example:22 (SECA2033002083)" and "http" not in drawn(app) and "\x1b[2J" not in drawn(app), scr("#h-target")
    # Changes are staged and said: the name, the kind (space on the radio pair), a new env word typed masked, a removal.
    await pilot.press("2")
    assert scr("#h-title") == "Host · wmac    ● unsaved changes"
    await pilot.press("tab", "space")
    assert scr("#h-kind").startswith("kind            (●) server   ( ) laptop") and app.focused.id == "h-kind"
    await pilot.press("tab", *"FOO", "enter", *"s3c")
    assert app.focused.id == "h-value" and "s3c" not in drawn(app) and "•••" in drawn(app), "a value is typed masked"
    await pilot.press("enter")
    key = app.screen.query_one("#h-key")
    assert app.focused is key and key.value == "" and app.screen.query_one("#h-value").value == ""
    key.value = "HTTPS_PROXY"                                         # a key and no value: remove it
    await pilot.press("enter", "enter")
    key.value = "NOPE"                                                # no value for a key the line does not have: nothing
    await pilot.press("enter", "enter")
    env = "env HTTPS_PROXY (removed on save) NO_PROXY •••• EXTRA •••• FOO •••• (new)"
    assert " ".join(scr("#h-env").split()) == env, scr("#h-env")
    value, save = app.screen.query_one("#h-value"), app.screen.query_one("#h-save")
    # A paste with white space at an end is refused out loud (the field takes none and would drop it without a word);
    # a clean one, its line end apart, is taken.
    value.post_message(tui.Paste("  s3e \n"))
    await pilot.pause()
    assert scr("#h-msg") == "a value cannot start or end with a space" and value.value == "", (scr("#h-msg"), value.value)
    value.post_message(tui.Paste("s3e\n"))
    await pilot.pause()
    assert value.value == "s3e"
    # KEY is an env name only. `name` and `laptop`, in any case, are the line's own words: a value typed here (masked)
    # under `name` would be drawn as the display name. Nothing is staged, and the fields keep what was typed.
    value.focus()
    for bad in ("name", "NAME", "laptop", "Laptop", "1K", ""):
        key.value, value.value = bad, "TOPSECRET"
        if bad == "name":
            await pilot.press("enter")   # Enter in the value field
        else:
            app.screen.stage()           # what that Enter runs
        assert scr("#h-msg") == "not an env name" and sorted(app.screen.staged) == ["FOO", "HTTPS_PROXY"] and (key.value, value.value) == (bad, "TOPSECRET"), (bad, scr("#h-msg"), app.screen.staged)
        app.screen.say("")
    assert " ".join(scr("#h-env").split()) == env and "TOPSECRET" not in drawn(app)
    # Typed and not entered is never sent (a KEY alone would remove that word; a value alone is nobody's): with text in
    # either field Save does nothing and says what to do.
    for k, v in (("NO_PROXY", ""), ("", "s3d"), ("NO_PROXY", "s3d")):
        key.value, value.value = k, v
        save.press()
        await settle(app, pilot)
        assert isinstance(app.screen, tui.HostEdit) and scr("#h-msg") == "press enter in the value field to stage KEY, or clear it", (k, v)
        assert len(cli_calls(app)) == 1 and not (d / "stdin").exists() and sorted(app.screen.staged) == ["FOO", "HTTPS_PROXY"], (k, v, cli_calls(app))
    app.screen.stage()   # entered (what Enter in the value field runs): staged
    # Save: ONE call, `hosts set <alias> --stdin`, every change a line of its stdin. No value is in an argument list.
    save.press()
    await settle(app, pilot)
    assert len(app.screen_stack) == 1 and cli_calls(app)[1:] == ["hosts --bot mgr set wmac --stdin"], cli_calls(app)
    assert (d / "stdin").read_text() == "name=w[2Jmac2\nlaptop off\nFOO=s3c\nHTTPS_PROXY=\nNO_PROXY=s3d\n", (d / "stdin").read_text()
    assert "s3" not in (d / "args").read_text() and "TOPSECRET" not in (d / "args").read_text() and app.said_all == ["claude-discord: hosts: changed wmac in /p/hosts (2 lines)\n" + CHECKS], app.said_all
    # Escape with no change closes; with one it asks (No by default). Nothing is written either way.
    await pilot.press("enter")
    await settle(app, pilot)
    await pilot.press("escape")
    await pilot.pause()
    assert len(app.screen_stack) == 1, "no change, no question"
    await pilot.press("enter")
    await settle(app, pilot)
    # Text typed in the KEY or the value field and not entered is a change too (Escape asks, as for the name below).
    for field in ("#h-key", "#h-value"):
        app.screen.query_one(field).value = "v"
        assert app.screen.dirty(), field
        app.screen.query_one(field).value = ""
    assert not app.screen.dirty()
    await pilot.press("x", "escape")
    await pilot.pause()
    assert isinstance(app.screen, tui.Confirm) and "Close without saving the changes to wmac?" in app.screen.text
    await pilot.press("enter")
    await pilot.pause()
    assert isinstance(app.screen, tui.HostEdit) and [c for c in cli_calls(app) if " set " in c] == ["hosts --bot mgr set wmac --stdin"]
    # Stop monitoring this host asks first (No by default), then runs `hosts rm`.
    app.screen.query_one("#h-stop").press()
    await pilot.pause()
    assert isinstance(app.screen, tui.Confirm) and "Stop monitoring wmac?" in app.screen.text
    await pilot.press("enter")
    await settle(app, pilot)
    assert isinstance(app.screen, tui.HostEdit) and not [c for c in cli_calls(app) if " rm " in c]
    app.screen.query_one("#h-stop").press()
    await pilot.pause()
    await pilot.press("y")
    await settle(app, pilot)
    assert len(app.screen_stack) == 1 and cli_calls(app)[-1] == "hosts --bot mgr rm wmac" and app.said_all[-1] == "claude-discord: hosts: removed wmac from /p/hosts\n" + CHECKS
    # local: its settings open like any host's, but it cannot be stopped.
    await pilot.press("up", "up", "enter")
    await settle(app, pilot)
    assert scr("#h-title") == "Host · local" and scr("#h-target") == "target          this machine" and app.screen.query_one("#h-stop").disabled and not app.screen.query_one("#h-save").disabled
    assert scr("#h-env").split() == "env HTTPS_PROXY ••••".split() and scr("#h-last").startswith("last check      ● ok   checked 1m ago")
    # Check now asks the monitor that runs for a pass (monitor --check) and says what it answered: no ssh, no hosts
    # call, nothing written from here.
    n, c = len(cli_calls(app)), checks(app)
    app.ASK_GAP, app.asked = 10, float("-inf")   # as it is outside these cases, and the last request long ago
    check = app.screen.query_one("#h-check")
    assert str(check.label) == "Check now"
    check.press()
    await settle(app, pilot)
    assert scr("#h-msg") == CHECKS and checks(app) == c + 1 and len(cli_calls(app)) == n and not (d / "ssh.args").exists(), scr("#h-msg")
    # Within 10 s of a request another press does nothing (the monitor serves all it meets in one pass, and a pass per
    # press would turn what is counted in passes into seconds): the button says it was asked.
    assert str(check.label) == "asked · the monitor checks within a minute", check.label
    for _ in range(5):
        check.press()
    await settle(app, pilot)
    assert checks(app) == c + 1 and scr("#h-msg") == CHECKS, checks(app)
    await pilot.press("escape")
    # So does the request after a change to the ledger: said as asked, and no second call.
    await pilot.press("l")
    await settle(app, pilot)
    assert checks(app) == c + 1 and app.said_all[-1] == "claude-discord: hosts: changed local in /p/hosts (1 line)\nasked · the monitor checks within a minute", app.said_all[-1]
    app.ASK_GAP = 0
    # A ledger entry of another shape (a name that is a number, env an object): read as empty, never raised on.
    await pilot.press("down", "enter")
    await settle(app, pilot)
    assert scr("#h-title") == "Host · old" and app.screen.query_one("#h-name").value == "" and scr("#h-env").split() == ["env", "none"]
    assert scr("#h-kind").startswith("kind            (●) server   ( ) laptop")
    await pilot.press("escape")
    # x on a row asks, then removes; l flips the kind the last pass saw. Each is one CLI call, said when it ends.
    await pilot.press("x")
    await pilot.pause()
    assert isinstance(app.screen, tui.Confirm) and "Stop monitoring old?" in app.screen.text
    await pilot.press("y")
    await settle(app, pilot)
    await pilot.press("l", "down", "l")
    await settle(app, pilot)
    assert cli_calls(app)[-3:] == ["hosts --bot mgr rm old", "hosts --bot mgr laptop old on", "hosts --bot mgr laptop wmac off"], cli_calls(app)[-3:]
    assert app.said_all[-2:] == ["claude-discord: hosts: changed old in /p/hosts (1 line)\n" + CHECKS, "claude-discord: hosts: changed wmac in /p/hosts (1 line)\n" + CHECKS], app.said_all
    await pilot.press("right", "x", "l")
    await settle(app, pilot)
    assert len(app.screen_stack) == 1 and len(cli_calls(app)) == 11, "x and l are the Configuration tab's keys"
    assert checks(app) == 6, "one pass asked for per change (a save, two removals, two kind flips) and one by Check now; none within 10 s of another"


async def host_edit_refused(app, pilot):
    """What the CLI refuses stays on the screen, as text; a ledger that cannot be read is said and nothing can be saved."""
    ssh_home(app)
    d = Path(app.state_dir)
    app.state["hosts"]["bad"] = dict(app.state["hosts"]["old"], host="bad")
    (d / "ledger.json").write_text(json.dumps({"hosts": [{"alias": "bad", "laptop": False, "name": "", "env": []}]}))
    app.paint()
    await pilot.press("left", "down", "l")
    await settle(app, pilot)
    assert app.said_all == ["claude-discord: hosts: bad is not in /p/hosts"], app.said_all
    app.said_all.clear()
    await pilot.press("enter")
    await settle(app, pilot)
    await pilot.press("n")
    app.screen.query_one("#h-save").press()
    await settle(app, pilot)
    assert isinstance(app.screen, tui.HostEdit) and text(app.screen, "#h-msg") == "claude-discord: hosts: K: a value holds no space [/]", text(app.screen, "#h-msg")
    assert text(app.screen, "#h-title").endswith("● unsaved changes") and not app.screen.query_one("#h-save").disabled and app.said_all == []
    assert checks(app) == 0, "a refused change (the l key's, the save's) asks for no pass"
    # The call itself fails (here the process's start, with the text it was handed in its message): a short note with
    # the exception's class, the app up, and the value in no text of the screen. An exception that left the worker
    # would end the app with a traceback that prints every frame's locals.
    class Dies:
        def __init__(self, *a, **k):
            pass

        def communicate(self, input=None, timeout=None):
            raise RuntimeError(f"died with {input!r}")
    app.screen.staged["TOKEN"] = "hunter2secret"
    real, tui.subprocess.Popen = tui.subprocess.Popen, Dies
    try:
        app.screen.query_one("#h-save").press()
        await settle(app, pilot)
    finally:
        tui.subprocess.Popen = real
    assert isinstance(app.screen, tui.HostEdit) and app.return_code is None and text(app.screen, "#h-msg") == "could not run hosts set: RuntimeError", text(app.screen, "#h-msg")
    assert "hunter2secret" not in drawn(app) and all("hunter2secret" not in repr(w) for w in [app.screen, *app.screen.walk_children()])
    assert app.screen.sending == "" and not app.screen.query_one("#h-save").disabled
    # With no monitor running (stopped by its owner) Check now says so: it starts nothing.
    (d / "nomonitor").write_text("")
    app.screen.query_one("#h-check").press()
    await settle(app, pilot)
    assert text(app.screen, "#h-msg") == NO_MONITOR, text(app.screen, "#h-msg")
    await pilot.press("escape", "y")
    await pilot.pause()
    for ledger, want in (("not json", "claude-discord hosts list gave no ledger (exit 0)"), ("[]", "claude-discord hosts list gave no ledger (exit 0)"),
                         ('{"hosts": [{"alias": ["bad"]}, 7, {"bad": 1}]}', "bad is not in the ledger")):
        (d / "ledger.json").write_text(ledger)
        await pilot.press("enter")
        await settle(app, pilot)
        assert text(app.screen, "#h-msg") == want and app.screen.query_one("#h-save").disabled and app.screen.query_one("#h-name").disabled, (ledger, text(app.screen, "#h-msg"))
        assert not app.screen.query_one("#h-check").disabled, "the monitor can be asked whatever the ledger's reading said"
        await pilot.press("escape")
        await pilot.pause()
        assert len(app.screen_stack) == 1


# The wrapper for the access editor: `access ... --json` prints the document the case put in access.json (or what
# access.err holds, exit 5); every call's arguments go to `args`.
ACCESS_CLI = r'''d=$(dirname "$0"); echo "$*" >> "$d/args"
case "$*" in
  access*" --json") [ ! -e "$d/access.err" ] || { cat "$d/access.err" >&2; exit 5; }; cat "$d/access.json";;
esac'''


def access_cli(d):
    """The document, longer than the 64 KiB every other answer of the CLI is cut at (a server with hundreds of channels)."""
    (Path(d) / "access.json").write_text(json.dumps(dict(access_doc(), pad="x" * 70000)))
    return stub(d, ACCESS_CLI + CHECK_STUB)


def access_calls(app):
    return [l for l in (Path(app.state_dir) / "args").read_text().splitlines() if l.startswith("access ")]


def hand_over(app, *codes):
    """The terminal can be handed over (as a real one can; the test driver cannot): what would run there is kept in
    app.ran, and each run exits with the next of `codes`."""
    app.ran, left = [], list(codes)
    app.suspend = contextlib.nullcontext
    app.runner = lambda argv: app.ran.append(argv) or left.pop(0)


async def access_edit(app, pilot):
    ssh_home(app)
    hand_over(app, 4, 0)
    scr, body = lambda sel: text(app.screen, sel), lambda: text(app.screen, "#a-body").split("\n")
    await pilot.press("right", "e", "left", "e")   # e is the Bots tab's key
    await settle(app, pilot)
    base = "access --host local --manager mgr --project /home/u/rcps -- photobot"
    assert isinstance(app.screen, tui.AccessEdit) and access_calls(app) == [base + " --json"], access_calls(app)
    assert scr("#a-title") == "Access · photobot    lmd79 · access.json · applies at the next message, no restart" and scr("#a-msg") == tui.A_HINT
    # The cursor starts on the bot's main channel; a name another machine wrote is drawn without its escape sequence.
    assert body()[2].split() == "▸ [✓] #dev-bots main required [✓] gpuvillain".split() and "\x1b[2J" not in drawn(app), body()
    await pilot.press("m")
    assert body()[2].split()[:5] == "▸ [✓] #dev-bots main any".split() and scr("#a-title").endswith("● unsaved changes"), body()[2]
    # A channel the bot does not listen in: space adds it for the owner alone; tab goes to its senders; `a` takes a name.
    await pilot.press("down", "down", "m", "space")
    assert body()[4].split() == "▸ [✓] #general bot cannot read required a adds a person by name or id".split() and "[✓] dongyong22  owner" in body()[1], body()
    await pilot.press("tab", "a", *"junyong", "enter")
    assert "numeric user id" in scr("#a-msg") and app.screen.adding(), "a name only Discord's member list gave is not taken"
    await pilot.press(*["backspace"] * 7, *"333", "enter")
    assert "▸ [✓] junyong-dev-bot  bot" in "\n".join(body()) and not app.screen.adding() and app.focused is None, body()
    # A name nobody has, then one several have: said, and the field stays for another try; escape leaves the field, not the editor.
    await pilot.press("a", *"zzz", "enter")
    assert "numeric user id" in scr("#a-msg") and app.screen.adding()
    await pilot.press("escape")
    assert isinstance(app.screen, tui.AccessEdit) and not app.screen.adding()
    # The last sender cannot be unticked (an empty list is everyone); `anyone` says that on purpose, and gives the list back.
    await pilot.press("up", "up", "space", "down", "down", "space")
    assert "the last sender stays" in scr("#a-msg") and "▸ [✓] junyong-dev-bot" in "\n".join(body()), (scr("#a-msg"), body())
    await pilot.press("down", "space")
    assert "▸ [✓] anyone in the channel" in "\n".join(body()) and app.screen.now["groups"]["902"]["allow"] == []
    await pilot.press("space")
    assert app.screen.now["groups"]["902"]["allow"] == ["333"], app.screen.now
    # The DM policy and the mode are radios: an arrow or space moves the choice.
    await pilot.press("tab", "down", "down", "down", "right", "right")
    assert "(●) pairing" in body()[8] and app.screen.now["dm"] == "pairing", body()[8]
    await pilot.press("down", "space", "space")
    assert "(●) autoresearchclaw" in body()[9], body()[9]
    # s hands the terminal to `access ... set <the change words>`. Exit 4 (a question answered no): nothing was changed,
    # the editor and its changes stay.
    await pilot.press("s")
    words = ["mention:900=off", "channel+902", "allow:902+333", "allow:902-111", "dm=pairing", "mode=autoresearchclaw"]
    assert app.ran == [[app.wrapper, "access", "--host", "local", "--manager", "mgr", "--project", "/home/u/rcps", "--", "photobot", "set", *words]], app.ran
    assert isinstance(app.screen, tui.AccessEdit) and scr("#a-msg").startswith("answered no: nothing was changed") and app.screen.words() == words
    # Exit 0: said, the editor closes, and the monitor is asked for a pass so the row shows the new policy.
    await pilot.press("s")
    await settle(app, pilot)
    assert len(app.ran) == 2 and len(app.screen_stack) == 1 and checks(app) == 1, (app.ran, app.screen_stack)
    assert app.said_all == ["access saved: the plugin reads access.json at the next message, no restart; the hooks follow the new mode at once, the dev-manager rules at the "
                            f"session's next start, compact or clear\n{CHECKS}"], app.said_all
    # Nothing changed: s runs nothing, escape closes without a question.
    await pilot.press("e")
    await settle(app, pilot)
    await pilot.press("s")
    assert scr("#a-msg") == "nothing to save" and len(app.ran) == 2
    await pilot.press("escape")
    assert len(app.screen_stack) == 1
    # Changed: escape asks before it closes.
    await pilot.press("e")
    await settle(app, pilot)
    await pilot.press("m", "escape")
    assert isinstance(app.screen, tui.Confirm) and "photobot" in app.screen.text
    await pilot.press("y")
    assert len(app.screen_stack) == 1 and len(app.ran) == 2


async def access_no_terminal(app, pilot):
    """Where the terminal cannot be handed over (here: the test driver; in the field: Textual Web), s runs nothing and
    shows the command to run in a shell; c copies it."""
    await pilot.press("e")
    await settle(app, pilot)
    await pilot.press("m", "s")
    cmd = f"cd {os.getcwd()} && claude-discord access --host local --manager mgr --project /home/u/rcps -- photobot set mention:900=off"
    assert cmd in text(app.screen, "#a-msg") and "cannot be handed over" in text(app.screen, "#a-msg"), text(app.screen, "#a-msg")
    await pilot.press("c")
    assert app.clipboard == cmd, app.clipboard
    await pilot.press("escape")
    assert len(app.screen_stack) == 1, "the command was given: escape closes without asking again"


async def access_refused(app, pilot):
    """A host whose claude-discord is older than 1.13.0 (the CLI's exit 5), a document of the wrong shape, a row that
    is no bot: said, nothing to edit, nothing run."""
    d = Path(app.state_dir)
    hand_over(app)
    (d / "access.err").write_text("claude-discord: access: old needs claude-discord 1.13.0 for this (it has 1.10.5; claude-discord update, there) [/]\n")
    app.cursor["bots"] = OLDBOT
    app.paint()
    await pilot.press("e")
    await settle(app, pilot)
    assert access_calls(app) == ["access --host old --manager mgr --project /home/u/p -- oldbot --json"], access_calls(app)
    assert text(app.screen, "#a-msg") == "claude-discord: access: old needs claude-discord 1.13.0 for this (it has 1.10.5; claude-discord update, there) [/]"
    await pilot.press("space", "m", "a", "s", "tab", "down")
    assert app.ran == [] and text(app.screen, "#a-body") == "" and isinstance(app.screen, tui.AccessEdit)
    await pilot.press("escape")
    (d / "access.err").unlink()
    for doc in ('{"access": 2}', "not json", '{"access": 1, "policy": "x", "channels": [7, {"id": 5}, {"id": "9", "name": 3, "read": "y"}], "people": "no", "guild": 4, "errors": [3, "the server\'s channels: HTTP 403"]}'):
        (d / "access.json").write_text(doc)
        await pilot.press("e")
        await settle(app, pilot)
        if doc.startswith('{"access": 1'):   # the shape is wrong everywhere but the marker: a list with one channel, and what Discord did not answer is said
            assert "▸ [ ] #9" in text(app.screen, "#a-body") and "the server's channels: HTTP 403" in text(app.screen, "#a-msg"), text(app.screen, "#a-body")
            await pilot.press("space", "tab", "s")
            assert "no owner id is known" in text(app.screen, "#a-msg") or text(app.screen, "#a-msg") == "nothing to save"
        else:
            assert text(app.screen, "#a-msg") == "claude-discord access gave no document (exit 0)" and text(app.screen, "#a-body") == ""
        await pilot.press("escape")
        assert len(app.screen_stack) == 1 and app.ran == []
    # e on a row that is no bot (a project whose health crashed) opens nothing.
    n = len(access_calls(app))
    app.state["bots"][CRASHED] = {"host": "wmac", "project": "/Users/u/q", "verdict": "blind", "since": iso(time.time() - 20), "detail": "x"}
    app.cursor["bots"] = CRASHED
    app.paint()
    await pilot.press("e")
    await settle(app, pilot)
    assert len(app.screen_stack) == 1 and len(access_calls(app)) == n


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
    assert "wmac (SECA2033002083) (left the ledger)" in line_of(app, "(left"), line_of(app, "(left")
    await pilot.press("down", "down", "enter")   # out of the ledger: nothing to set, so its raw fields as before 1.12.0
    await pilot.pause()
    assert isinstance(app.screen, tui.Detail) and str(app.screen.query_one("#body-detail").render()).startswith("wmac\n")


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
    await case("add_host", add_host, state="all_ok", wrapper=lambda d: stub(d, HOSTS_CLI + CHECK_STUB))
    await case("add_host_bare", add_host_bare, state="all_ok")
    await case("host_edit", host_edit, state="all_ok", wrapper=edit_cli)
    await case("host_edit_refused", host_edit_refused, state="all_ok", wrapper=edit_cli)
    await case("access_edit", access_edit, state="all_ok", wrapper=access_cli)
    await case("access_no_terminal", access_no_terminal, state="all_ok", wrapper=access_cli)
    await case("access_refused", access_refused, state="all_ok", wrapper=access_cli)
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
            app = tui.MonitorTUI(Path(d), "mgr", stub(d, 'd=$(dirname "$0"); echo "$*" >> "$d/args"; case "$*" in *--stop*) n=0; while [ ! -e "$d/go" ] && [ $n -lt 300 ]; do sleep 0.01; n=$((n + 1)); done;; esac'))
            async with app.run_test() as pilot:
                await pilot.pause()
                await pilot.press("Q")
                await pilot.pause()
                assert isinstance(app.screen, tui.Confirm) and "keeper and monitor stop" in app.screen.text, app.screen
                await pilot.press(answer)
                if answer == "y":
                    # The stub's --stop waits for this case: the screen must stay alive meanwhile and say what it does.
                    assert app.return_code is None and "stopping the backend of mgr" in text(app, "#bar"), (app.return_code, text(app, "#bar"))
                    (Path(d) / "go").write_text("")
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
