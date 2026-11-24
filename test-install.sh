#!/usr/bin/env bash
# The install half of the acceptance suite: patch, setup on an old install, compat, setup --mode and scopes, install and
# update. Same sandbox, stubs and first setup as test-claude-discord.sh (tests/suite-lib.sh). Usage: test-install.sh <script>
. "$(dirname "$0")/tests/suite-lib.sh"

# --- the manager's CLI: hosts, access, bot (moved here from the core file, 1.19.10) ----------------------------------
# The fixture they need, as the core file builds it for its monitor cases: the ssh stub (setup's host probe, the --host
# calls), a manager bot mgr in its own project with a ledger, a claude whose `agents` lists nothing, and a bot b1ok of
# another project (a name `bot rename` must refuse in any case). The claude stub goes back after these blocks.
cp "$HOME/bin/claude" "$HOME/claude.suite"
printf '#!/usr/bin/env bash\n[ "$1" = agents ] && echo "[]"\n' > "$HOME/bin/claude"; chmod +x "$HOME/bin/claude"
B1=$(bdir "$HOME/b1okproj" b1ok); mkdir -p "$B1"; printf 'DISCORD_BOT_TOKEN=tokH\n' > "$B1/.env"
# ssh, stubbed for setup's host probe and the monitor's passes: argv to ssh.log; per host, $HOME/mon/<host>.out is
# printed, .rc is the exit status (.rc2 instead on the ControlPath=none retry; .out is printed with a non-zero one only
# when .both exists; .trc instead for a call under -t; .arc instead for the access call itself, not the version probe before it), .sleep delays it, .hold leaves a detached child behind that keeps the output open so long; a byte left on
# stdin is reported as "ATE" (a probe must never eat setup's piped answers).
MON="$HOME/mon"; mkdir -p "$MON"
cat > "$HOME/bin/ssh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$HOME/ssh.log"
IFS= read -r -t 0.05 l && printf 'ATE %s\n' "$l" >> "$HOME/ssh.log"
host="" none="" tty=""
for a in "$@"; do [ "$a" != ControlPath=none ] || none=1; done
while [ $# -gt 0 ]; do case $1 in -o) shift 2;; --) shift;; -t) tty=1; shift;; *) host=$1; break;; esac; done
d=$HOME/mon
[ ! -f "$d/$host.hold" ] || setsid /bin/sleep "$(<"$d/$host.hold")" &
if [ -f "$d/$host.sleep" ]; then echo $$ > "$d/$host.pid"; /bin/sleep "$(<"$d/$host.sleep")"; fi
rc=0; [ ! -f "$d/$host.rc" ] || rc=$(<"$d/$host.rc")
[ -z "$none" ] || [ ! -f "$d/$host.rc2" ] || rc=$(<"$d/$host.rc2")
[ -z "$tty" ] || [ ! -f "$d/$host.trc" ] || rc=$(<"$d/$host.trc")
case "$*" in *--access*) [ ! -f "$d/$host.arc" ] || rc=$(<"$d/$host.arc");; esac
[ "$rc" != 0 ] && [ ! -f "$d/$host.both" ] || cat "$d/$host.out" 2>/dev/null
exit "$rc"
STUB
chmod +x "$HOME/bin/ssh"; rm -f "$HOME/ssh.log"

MP="$HOME/monproj"; mkdir -p "$MP"; cd "$MP"; MR=$(broot "$MP")
jq --arg p "$(pwd -P)" '.projects[$p].hasTrustDialogAccepted = true' "$HOME/.claude.json" > "$HOME/.claude.json.t" && mv "$HOME/.claude.json.t" "$HOME/.claude.json"
printf '\n900\n111\n\ntokMgrUnique\nn\ndev-manager\n\n\n' | bash "$S" setup mgr --scope project >/dev/null 2>&1
[ -f "$MR/mgr/hosts" ] || { echo "FAIL: the manager fixture for the hosts, access and bot cases has no ledger"; exit 1; }

# --- hosts: the ledger's CLI (1.12.0) ---------------------------------------
# hc <args>: `claude-discord hosts <args>` in the manager's project; stdout in HO, stderr in HE, the exit status in HRC.
hc() { HRC=0; HO=$(bash "$S" hosts "$@" 2>"$HOME/hosts.err") || HRC=$?; HE=$(<"$HOME/hosts.err"); }
# hosts list reads a line as the monitor's pass does: CRLF, a comment and a blank line skipped, a first word that is no
# plain ssh name not a host (counted), laptop only as the second word, the last name= word (its control characters
# gone), key names of KEY=VALUE words and a count of the words the monitor skips. Never a value.
printf '# mine\r\n\r\nlocal laptop name=람다 HTTPS_PROXY=http://u:secretpw@127.0.0.1:8118\r\nh1 X=1 odd name=a name=bo\037x Y=2 laptop\n-oProxyCommand=x\nlap laptop\nh1 laptop' > "$MR/mgr/hosts"
LEDGER=$(<"$MR/mgr/hosts")
hc list
[ "$HRC" = 0 ] && [ "$HO" = "$(printf 'local                laptop  name=람다 env=HTTPS_PROXY\nh1                   server  name=box env=X,Y (2 words the monitor skips)\nlap                  laptop  name=- env=-\nh1                   laptop  name=- env=-')" ] ||
  { echo "FAIL: hosts list prints one line per host line of the ledger (alias, kind, name, env key names): rc=$HRC $HO / $HE"; exit 1; }
hc list --json
jq -e --arg f "$MR/mgr/hosts" '. == {manager: "mgr", ledger: $f, ignored: 1, hosts: [
  {alias: "local", laptop: true, name: "람다", env: ["HTTPS_PROXY"], skipped: 0}, {alias: "h1", laptop: false, name: "box", env: ["X", "Y"], skipped: 2},
  {alias: "lap", laptop: true, name: "", env: [], skipped: 0}, {alias: "h1", laptop: true, name: "", env: [], skipped: 0}]}' <<<"$HO" >/dev/null ||
  { echo "FAIL: hosts list --json: the manager, the ledger's path, the lines that are no host (ignored) and per host alias, laptop, name, env key names and skipped words: $HO / $HE"; exit 1; }
hc list; A=$HO; hc list --json
case "$A$HO$HE" in *secretpw*|*8118*) echo "FAIL: hosts list must never print an env value: $A $HO $HE"; exit 1;; esac
[ "$(<"$MR/mgr/hosts")" = "$LEDGER" ] || { echo "FAIL: hosts list must not write the ledger"; exit 1; }
# Which manager: the one dev-manager bot with a ledger in the project above the cwd, else in a recorded project
# (setup recorded $MP); --bot names it; several and none named is exit 2 with their names; none is exit 1.
mkdir -p "$MP/sub/dir"
A=$(cd "$MP/sub/dir" && bash "$S" hosts list --json | jq -r .manager); B=$(cd "$HOME" && bash "$S" hosts --bot mgr list --json | jq -r .ledger)
[ "$A" = mgr ] && [ "$B" = "$(bdir "$MP" mgr)/hosts" ] || { echo "FAIL: hosts finds the manager from below its project and, outside any, among the recorded projects: '$A' '$B'"; exit 1; }
mkdir -p "$MR/mgr2" "$MR/plain"; echo dev-manager > "$MR/mgr2/mode"; echo 'local name=two' > "$MR/mgr2/hosts"; echo none > "$MR/plain/mode"; echo local > "$MR/plain/hosts"
hc list
[ "$HRC" = 2 ] && [ -z "$HO" ] && grep -q -- '--bot <manager>' <<<"$HE" && grep -q "/mgr2$" <<<"$HE" && ! grep -q '/plain$' <<<"$HE" || { echo "FAIL: two manager bots and none named is exit 2, naming them (a bot that is no dev-manager is none): rc=$HRC $HE"; exit 1; }
hc --bot mgr2 list
[ "$HRC" = 0 ] && [ "$HO" = "local                server  name=two env=-" ] || { echo "FAIL: --bot names the manager: rc=$HRC $HO / $HE"; exit 1; }
hc --bot plain list
[ "$HRC" = 1 ] && grep -q "no dev-manager bot 'plain' with a hosts ledger" <<<"$HE" || { echo "FAIL: a bot that is no dev-manager with a ledger is exit 1: rc=$HRC $HE"; exit 1; }
rm -rf "$MR/mgr2" "$MR/plain" "$MP/sub"
# A flag that means nothing for the verb is a usage error too, not ignored (`rm --dry-run` would remove).
for bad in "" "nosuchverb" "list extra" "--bot" "list --frob" "list --stdin" "rm --dry-run h1" "set h1 X=1 --dry-run" "add --json h7" "laptop --no-probe h1 on"; do
  hc $bad </dev/null
  [ "$HRC" = 2 ] && grep -q '^usage: claude-discord hosts ' <<<"$HE" && [ "$(<"$MR/mgr/hosts")" = "$LEDGER" ] || { echo "FAIL: 'hosts $bad' is a usage error (exit 2), nothing written: rc=$HRC $HE"; exit 1; }
done
rc=0; out=$(printf '\n' | bash "$S" setup hosts 2>&1) || rc=$?
[ "$rc" = 2 ] && grep -q "bot name 'hosts' is reserved" <<<"$out" || { echo "FAIL: 'hosts' is a subcommand now, so no bot may take the name: rc=$rc $out"; exit 1; }
echo "ok: hosts list prints each host line as the monitor reads it (alias, kind, display name, env key names, skipped words; --json for the TUI) and never a value; the manager is the project's or a recorded project's one dev-manager bot with a ledger, or --bot's; 'hosts' is a reserved bot name"

# hosts add --no-probe: the line is appended and every other byte of the ledger kept (CRLF lines, the comment, the
# words the monitor skips); the file is replaced by rename (a monitor may be reading it), keeps the owner's mode and
# leaves no temp file.
chmod 640 "$MR/mgr/hosts"; li=$(stat -c %i "$MR/mgr/hosts")
hc add --no-probe h9
[ "$HRC" = 0 ] && [ "$(<"$MR/mgr/hosts")" = "$LEDGER"$'\n'h9 ] && [ "$(tail -c 3 "$MR/mgr/hosts")" = "h9" ] && [ "$HO" = "claude-discord: hosts: added h9 to $MR/mgr/hosts" ] ||
  { echo "FAIL: hosts add appends the alias as a line of its own and keeps every other byte: rc=$HRC $HO / $HE / $(od -c "$MR/mgr/hosts" | tail -4)"; exit 1; }
[ "$(stat -c %a "$MR/mgr/hosts")" = 640 ] && [ "$(stat -c %i "$MR/mgr/hosts")" != "$li" ] && [ "$(ls "$MR/mgr" | grep -c '^hosts')" = 2 ] ||
  { echo "FAIL: the ledger is written to a temp file and moved in (mode kept, no temp left; hosts.lock is the one new file): $(ls -l "$MR/mgr")"; exit 1; }
hc add --no-probe lap2 laptop HTTPS_PROXY=http://u:p#w\$x@127.0.0.1:8118 name=랩-2 A_b1=-x
[ "$HRC" = 0 ] && [ "$(tail -n 1 "$MR/mgr/hosts")" = 'lap2 laptop HTTPS_PROXY=http://u:p#w$x@127.0.0.1:8118 name=랩-2 A_b1=-x' ] && [[ $HO$HE != *127.0.0.1* ]] ||
  { echo "FAIL: add writes laptop and the KEY=VALUE words as given (a #, a \$ and a leading - in a value are the monitor's to read literally) and prints no value: rc=$HRC $HO / $HE / $(tail -n 1 "$MR/mgr/hosts")"; exit 1; }
LEDGER=$(<"$MR/mgr/hosts")
hc add --no-probe h1 laptop
[ "$HRC" = 3 ] && grep -q "h1 is already in $MR/mgr/hosts" <<<"$HE" && [ "$(<"$MR/mgr/hosts")" = "$LEDGER" ] || { echo "FAIL: an alias already in the ledger is exit 3 and changes nothing: rc=$HRC $HE"; exit 1; }
# What cannot be an alias: an ssh option, whitespace, a #, an =, a command substitution, an escape sequence, nothing,
# 256 characters, and a letter that is not ASCII (accented, fullwidth: a range of a UTF-8 locale takes them, so the
# match is made in the C locale). Exit 2, the ledger untouched, ssh never run, and the word is not echoed: only where
# it stands and the rule.
rm -f "$HOME/ssh.log"
NOALIAS="claude-discord: hosts: the alias (argument 2) is not an ssh alias: letters, digits, . _ @ -, not starting with -, 255 at most"
for bad in 'a b' 'a#b' 'a=b' '$(id)' $'a\033[2Jb' '' "$(printf 'a%.0s' {1..256})" 'é' 'ｗeb' 'ａ'; do
  HRC=0; HE=$(LC_ALL=en_US.utf8 bash "$S" hosts add --no-probe "$bad" 2>&1) || HRC=$?
  [ "$HRC" = 2 ] && [ "$(<"$MR/mgr/hosts")" = "$LEDGER" ] && [ ! -e "$HOME/ssh.log" ] && [ "$HE" = "$NOALIAS" ] ||
    { echo "FAIL: '$bad' is no ssh alias: exit 2, nothing written, no ssh, the word not echoed: rc=$HRC $HE"; exit 1; }
done
for bad in '-oProxyCommand=touch$IFS/tmp/pwned' '-v'; do
  hc add --no-probe "$bad"
  [ "$HRC" = 2 ] && [ "$(<"$MR/mgr/hosts")" = "$LEDGER" ] && [ ! -e "$HOME/ssh.log" ] && grep -q '^usage: ' <<<"$HE" || { echo "FAIL: an alias that is an ssh option ($bad) is a usage error: rc=$HRC $HE"; exit 1; }
done
# The arguments swapped, a secret where the alias belongs: every verb says the same and echoes nothing of it.
for cmd in "set HTTPS_PROXY=http://u:secretpw@h lap" "rm secretpw/x" "laptop secretpw! on"; do
  hc $cmd </dev/null
  [ "$HRC" = 2 ] && [ "$(<"$MR/mgr/hosts")" = "$LEDGER" ] && [ ! -e "$HOME/ssh.log" ] && [ "$HO$HE" = "$NOALIAS" ] || { echo "FAIL: 'hosts $cmd': a refused alias is never echoed: rc=$HRC $HO $HE"; exit 1; }
done
# What cannot be a word of the line: no KEY=, a KEY that is no identifier (a letter that is not ASCII neither), a value
# with a space, a quote or a control character, a display name with a space, an empty value (the word may be a token
# that ends in =), a value past 1024 characters, a display name past 40. Exit 2, and nothing of the word is echoed
# (a secret pasted in the wrong place), its key neither: only where it stands.
for bad in 'secretpw' '1K=secretpw' 'K=secretpw x' 'K="secretpw"' $'K=secretpw\033[2J' 'name=secretpw box' 'secretpw=' "K=secretpw$(printf 'a%.0s' {1..1020})" 'Ｋ=secretpw' "name=secretpw$(printf '가%.0s' {1..33})"; do
  HRC=0; HE=$(LC_ALL=en_US.utf8 bash "$S" hosts add --no-probe h8 "$bad" 2>&1) || HRC=$?
  [ "$HRC" = 2 ] && [ "$(<"$MR/mgr/hosts")" = "$LEDGER" ] && [[ $HE != *secretpw* ]] && [[ $HE == "claude-discord: hosts: argument 3"* ]] || { echo "FAIL: '$bad' is no word of a ledger line: exit 2, nothing written, the word not echoed: rc=$HRC $HE"; exit 1; }
done
hc add --no-probe h8 'K=secretpw x'
grep -q '^claude-discord: hosts: argument 3: a value holds no space' <<<"$HE" || { echo "FAIL: a refused value is named by where it stands: $HE"; exit 1; }
# laptop is the third word or none, and a KEY comes once.
for cmd in "h8 laptop laptop" "h8 laptop X=secretpw Y=2 X=3"; do
  hc add --no-probe $cmd
  [ "$HRC" = 2 ] && [ "$(<"$MR/mgr/hosts")" = "$LEDGER" ] && [[ $HE != *secretpw* ]] && [[ $HE == "claude-discord: hosts: argument "[46][:\ ]* ]] || { echo "FAIL: 'hosts add $cmd' repeats a word: exit 2, nothing written: rc=$HRC $HE"; exit 1; }
done
# A display name is counted in characters of the user's locale (40 Hangul are 120 bytes), and may hold any of them.
HRC=0; HE=$(LC_ALL=en_US.utf8 bash "$S" hosts add --no-probe h40 "name=$(printf '가%.0s' {1..40})" 2>&1 >/dev/null) || HRC=$?
[ "$HRC" = 0 ] && [ -z "$HE" ] && [ "$(tail -n 1 "$MR/mgr/hosts")" = "h40 name=$(printf '가%.0s' {1..40})" ] || { echo "FAIL: a display name of 40 characters that are not ASCII is taken: rc=$HRC $HE"; exit 1; }
printf '%s\n' "$LEDGER" > "$MR/mgr/hosts"
# Two writers: one holds the ledger's lock, reads the ledger, and 0.1 s later moves in its own version (as a TUI save
# or another `hosts` call would). An add started meanwhile must wait for it and then add to THAT version; were it not
# to wait, the first writer's rename would drop its line.
perl -MFcntl=:flock -e 'my $f = shift; open(my $l, ">>", "$f.lock") or die; flock($l, LOCK_EX) or die; open(my $r, "<", $f) or die; my $c = do { local $/; <$r> };
  open(my $g, ">", "$f.ready") or die; print $g "1\n"; close $g; select(undef, undef, undef, 0.1);
  open(my $w, ">", "$f.held") or die; print $w $c . "held\n"; close $w; rename("$f.held", $f) or die' "$MR/mgr/hosts" &
wait_for_file "$MR/mgr/hosts.ready"
hc add --no-probe late; wait
[ "$HRC" = 0 ] && [ "$(<"$MR/mgr/hosts")" = "$LEDGER"$'\n'held$'\n'late ] || { echo "FAIL: an add started while another writer holds the ledger's lock waits and adds to that writer's version: rc=$HRC $HE / $(tail -n 3 "$MR/mgr/hosts")"; exit 1; }
rm -f "$MR/mgr/hosts.ready"
echo "ok: hosts add --no-probe appends a host line (laptop, KEY=VALUE and name= words) keeping every other byte, by temp file and rename with the ledger's mode; an alias that is an ssh option or holds anything but letters, digits and . _ @ - and a word that is no KEY=VALUE are exit 2 with nothing written and no word echoed; an alias already listed is exit 3; a second writer waits for the first"

# hosts set / laptop / rm. ledger_is <printf format>: the ledger is exactly that.
ledger_is() { [ "$(<"$MR/mgr/hosts")" = "$(printf "$1")" ]; }
HEAD='# mine\r\n\r\n'; LOCAL='local laptop name=람다 HTTPS_PROXY=http://u:secretpw@127.0.0.1:8118\r\n'; TAIL='-oProxyCommand=x\nlap laptop\nh2  A=1\n'
printf "$HEAD${LOCAL}h1   X=1 odd name=a  name=b Y=2 X=3\n${TAIL}h1 laptop" > "$MR/mgr/hosts"
# KEY=VALUE replaces the first KEY= word where it stands (a later one of the same key goes), else is added last; on
# every line of the alias; every other word and line as it was.
hc set h1 X=9 Z=http://secretz
[ "$HRC" = 0 ] && ledger_is "$HEAD${LOCAL}h1 X=9 odd name=a name=b Y=2 Z=http://secretz\n${TAIL}h1 laptop X=9 Z=http://secretz" && [ "$HO" = "claude-discord: hosts: changed h1 in $MR/mgr/hosts (2 lines)" ] && [[ $HE != *secretz* ]] ||
  { echo "FAIL: set KEY=VALUE replaces the key's first word in place or adds it last, on every line of the alias, and prints no value: rc=$HRC $HO / $HE / $(<"$MR/mgr/hosts")"; exit 1; }
hc set h1 Y= name=box
[ "$HRC" = 0 ] && ledger_is "$HEAD${LOCAL}h1 X=9 odd name=box Z=http://secretz\n${TAIL}h1 laptop X=9 Z=http://secretz name=box" || { echo "FAIL: set KEY= removes the word; name=<display> is one word, where the first stood: rc=$HRC $HE / $(<"$MR/mgr/hosts")"; exit 1; }
hc set h1 name= X= NOPE=
[ "$HRC" = 0 ] && ledger_is "$HEAD${LOCAL}h1 odd Z=http://secretz\n${TAIL}h1 laptop Z=http://secretz" || { echo "FAIL: name= and KEY= remove, a key that is not there is no error: rc=$HRC $HE / $(<"$MR/mgr/hosts")"; exit 1; }
# --stdin: one change a line (a value never in an argument list), laptop on|off among them, all in one rename. A line
# that is not allowed fails the whole call before anything is written.
li=$(stat -c %i "$MR/mgr/hosts")
HRC=0; HO=$(printf 'name=랩\nHTTPS_PROXY=http://u:pw2@h:1\r\nlaptop off\n\nK=' | bash "$S" hosts set lap --stdin 2>&1) || HRC=$?
[ "$HRC" = 0 ] && ledger_is "$HEAD${LOCAL}h1 odd Z=http://secretz\n-oProxyCommand=x\nlap name=랩 HTTPS_PROXY=http://u:pw2@h:1\nh2  A=1\nh1 laptop Z=http://secretz" && [[ $HO != *pw2* ]] ||
  { echo "FAIL: set --stdin applies every line of stdin in one write: rc=$HRC $HO / $(<"$MR/mgr/hosts")"; exit 1; }
LEDGER=$(<"$MR/mgr/hosts"); li=$(stat -c %i "$MR/mgr/hosts")
HRC=0; HO=$(printf 'A=1\nB=secretpw x\n' | bash "$S" hosts set lap --stdin 2>&1) || HRC=$?
[ "$HRC" = 2 ] && [ "$(<"$MR/mgr/hosts")" = "$LEDGER" ] && [ "${HO%%:*:*:*}" = "claude-discord" ] && [[ $HO == "claude-discord: hosts: line 2 of stdin: a value holds no space"* ]] || { echo "FAIL: one bad line on stdin fails the whole set --stdin, nothing written, and is named by its line: rc=$HRC $HO"; exit 1; }
# A change that is already so writes nothing: the line keeps its bytes (h2's two spaces) and the file its inode.
hc set h2 A=1; A=$HRC$HO; hc laptop h2 off
[ "$A$HRC$HO" = "0claude-discord: hosts: h2 is already so in $MR/mgr/hosts0claude-discord: hosts: h2 is already so in $MR/mgr/hosts" ] && [ "$(<"$MR/mgr/hosts")" = "$LEDGER" ] && [ "$(stat -c %i "$MR/mgr/hosts")" = "$li" ] ||
  { echo "FAIL: a change that is already so is said and writes nothing: $A / rc=$HRC $HO / $HE"; exit 1; }
# laptop: the second word, on and off; a changed CRLF line keeps its CRLF; local is a host like any other here.
hc laptop local off
[ "$HRC" = 0 ] && [ "$(sed -n 3p "$MR/mgr/hosts")" = "$(printf 'local name=람다 HTTPS_PROXY=http://u:secretpw@127.0.0.1:8118\r')" ] || { echo "FAIL: laptop off removes the second word and keeps the line's CRLF: rc=$HRC $(sed -n 3p "$MR/mgr/hosts" | od -c | tail -3)"; exit 1; }
hc laptop local on; hc laptop h2 on
[ "$HRC" = 0 ] && [ "$(sed -n 3p "$MR/mgr/hosts")" = "$(printf "${LOCAL%'\\n'}")" ] && [ "$(sed -n 7p "$MR/mgr/hosts")" = "h2 laptop A=1" ] || { echo "FAIL: laptop on makes laptop the second word: rc=$HRC $(<"$MR/mgr/hosts")"; exit 1; }
# rm removes every line of the alias and nothing else; local stays; an alias that is not there is exit 3 for all three.
hc rm --no-probe h1
[ "$HRC" = 0 ] && ledger_is "$HEAD$LOCAL-oProxyCommand=x\nlap name=랩 HTTPS_PROXY=http://u:pw2@h:1\nh2 laptop A=1" && grep -q "^claude-discord: hosts: removed h1 from $MR/mgr/hosts" <<<"$HO" ||
  { echo "FAIL: rm removes both lines of h1 and keeps every other byte: rc=$HRC $HO / $HE / $(<"$MR/mgr/hosts")"; exit 1; }
LEDGER=$(<"$MR/mgr/hosts")
hc rm --no-probe local
[ "$HRC" = 2 ] && grep -q 'local is this machine' <<<"$HE" && [ "$(<"$MR/mgr/hosts")" = "$LEDGER" ] || { echo "FAIL: rm local is refused (exit 2): rc=$HRC $HE"; exit 1; }
for cmd in "rm --no-probe h1" "set h1 X=1" "laptop h1 on"; do
  hc $cmd
  [ "$HRC" = 3 ] && grep -q "h1 is not in $MR/mgr/hosts" <<<"$HE" && [ "$(<"$MR/mgr/hosts")" = "$LEDGER" ] || { echo "FAIL: 'hosts $cmd' on an alias that is not in the ledger is exit 3: rc=$HRC $HE"; exit 1; }
done
for cmd in "rm a b" "rm -oProxyCommand=x" "set lap" "set lap X=1 --stdin" "laptop lap maybe"; do
  hc $cmd </dev/null
  [ "$HRC" = 2 ] && [ "$(<"$MR/mgr/hosts")" = "$LEDGER" ] || { echo "FAIL: 'hosts $cmd' is a usage error (exit 2), nothing written: rc=$HRC $HE"; exit 1; }
done
# The last hosts go: the ledger file stays (it is the monitor's switch), with local, the comment and the line that is no host.
hc rm --no-probe lap; hc rm --no-probe h2
[ "$HRC" = 0 ] && ledger_is "$HEAD$LOCAL-oProxyCommand=x" || { echo "FAIL: removing the last other host leaves the ledger in place with local: rc=$HRC $(<"$MR/mgr/hosts")"; exit 1; }
echo "ok: hosts set replaces, adds or removes a KEY=VALUE or name= word on every line of the alias (values on stdin with --stdin, all changes in one write, none when a line is bad), laptop on|off sets the second word, rm removes the alias's lines; other lines and words keep their bytes, a change already so writes nothing, an alias not listed is exit 3, rm local is refused"

# An alias is matched whole: web is not web2, for any verb. A word of a line that is a glob pattern (the monitor skips
# it) is kept as it is, never matched against the files of the directory the command runs in.
printf "$HEAD${LOCAL}web2 A=1 * [a-z]*\n" > "$MR/mgr/hosts"; LEDGER=$(<"$MR/mgr/hosts"); : > "$MP/zz1"
for cmd in "set web A=9" "laptop web on" "rm --no-probe web"; do
  hc $cmd
  [ "$HRC" = 3 ] && [ "$(<"$MR/mgr/hosts")" = "$LEDGER" ] || { echo "FAIL: 'hosts $cmd' must not touch web2: rc=$HRC $HE / $(<"$MR/mgr/hosts")"; exit 1; }
done
hc set web2 A=2
[ "$HRC" = 0 ] && ledger_is "$HEAD${LOCAL}web2 A=2 * [a-z]*" || { echo "FAIL: a changed line keeps its other words as they are (a * is no list of the files here): rc=$HRC $HE / $(<"$MR/mgr/hosts")"; exit 1; }
# A ledger with no local line (hand-edited): its last host stays, or the monitor would run with none and say nothing;
# and `add local` adds this machine with no ssh (nobody is asked who local is).
printf '# c\nh1\nh2 X=1\n-x\n' > "$MR/mgr/hosts"; rm -f "$HOME/ssh.log"
hc rm --no-probe h1; A=$HRC; hc rm --no-probe h2
[ "$A$HRC" = 02 ] && ledger_is '# c\nh2 X=1\n-x' && grep -q 'the ledger would be empty: the monitor needs at least one host' <<<"$HE" || { echo "FAIL: rm must not leave a ledger with no host line: $A rc=$HRC $HE / $(<"$MR/mgr/hosts")"; exit 1; }
hc add local laptop
[ "$HRC" = 0 ] && [ ! -e "$HOME/ssh.log" ] && ledger_is '# c\nh2 X=1\n-x\nlocal laptop' || { echo "FAIL: add local, when the ledger has none, adds it and runs no ssh: rc=$HRC $HE / $(cat "$HOME/ssh.log" 2>&1)"; exit 1; }
printf "$HEAD$LOCAL-oProxyCommand=x" > "$MR/mgr/hosts"; rm -f "$MP/zz1"
echo "ok: hosts: an alias is matched whole (web is not web2), a glob word of a line is kept as it is, rm never leaves a ledger with no host, add local runs no ssh"

# ~/.claude-discord/host-id: 32 hex digits, made once. Eight first calls at once agree on one id and leave no temp
# file; a file that is no id is replaced; a plain --version makes none.
HID="$HOME/.claude-discord/host-id"; rm -f "$HID"
bash "$S" --version > "$HOME/hid.0"
[ ! -e "$HID" ] && [ "$(wc -l < "$HOME/hid.0")" = 1 ] || { echo "FAIL: a plain --version prints its one line and makes no host-id: $(<"$HOME/hid.0")"; exit 1; }
VLINE=$(<"$HOME/hid.0")   # the version line, as the tui block below expects it passed to the TUI (1.14.1)
[[ $VLINE =~ ^claude-discord\ [0-9]+\.[0-9]+\.[0-9]+\ \(([0-9a-f]{7,}|nogit)\)$ ]] || { echo "FAIL: --version prints 'claude-discord <version> (<short sha>|nogit)': $VLINE"; exit 1; }
for i in 1 2 3 4 5 6 7 8; do bash "$S" --version --host-id > "$HOME/hid.$i" 2>&1 & done; wait
L=$(cat "$HID" 2>/dev/null) || L=""
[[ $L =~ ^[0-9a-f]{32}$ ]] && [ "$(wc -l < "$HID")" = 1 ] && [ "$(stat -c %a "$HID")" = 600 ] && [ "$(ls -A "$HOME/.claude-discord" | grep -c host-id)" = 1 ] ||
  { echo "FAIL: host-id is one line of 32 hex digits, mode 600, and no temp file stays: $(ls -lA "$HOME/.claude-discord") $(cat "$HID" 2>&1)"; exit 1; }
for i in 1 2 3 4 5 6 7 8; do
  [ "$(sed 1d "$HOME/hid.$i")" = "host-id $L" ] && [ "$(sed -n 1p "$HOME/hid.$i")" = "$(<"$HOME/hid.0")" ] || { echo "FAIL: eight first --version --host-id calls at once must all print the one id that was kept ($L): $(cat "$HOME/hid.$i")"; exit 1; }
done
for bad in '' "${L}0"; do
  printf '%s\n' "$bad" > "$HID"
  A=$(bash "$S" --version --host-id | sed -n 2p)
  [[ ${A#host-id } =~ ^[0-9a-f]{32}$ ]] && [ "${A#host-id }" = "$(<"$HID")" ] || { echo "FAIL: a host-id file that holds no id ('$bad') is replaced: $A / $(<"$HID")"; exit 1; }
done
printf '%s\n' "$L" > "$HID"; rm -f "$HOME"/hid.*
# ans <host> <version> [<host-id>]: what that host's `claude-discord --version --host-id` prints.
ans() { printf 'claude-discord %s (abc1234)\n' "$2" > "$MON/$1.out"; [ -z "${3:-}" ] || printf 'host-id %s\n' "$3" >> "$MON/$1.out"; }
ID_B=$(printf 'b%.0s' {1..32})
LEDGER=$(<"$MR/mgr/hosts"); rm -f "$HOME/ssh.log"
# The probe's command: --dry-run prints it and runs nothing; the real add then runs exactly that (ssh's argument list
# is the printed line without its quoting), with stdin closed, and adds the host.
# Its answer comes after a banner (sshd's, the shell's) longer than the 4096 bytes kept, which holds a version line and
# this home's own id: the LAST line that reads as a version line counts, with what follows it. And its ssh leaves a
# process behind that holds the output open for 3 s (as a ControlPersist master does): the answer is taken when ssh
# ends, not when the last holder of its output does.
ans h5 1.12.0 "$ID_B"; echo 3 > "$MON/h5.hold"
{ printf 'claude-discord 0.0.1 (banner)\nhost-id %s\n' "$L"; head -c 6000 /dev/zero | tr '\0' 'b' | fold -w 100; echo; cat "$MON/h5.out"; } > "$MON/h5.t" && mv "$MON/h5.t" "$MON/h5.out"
hc add --dry-run h5; SHOWN=$HO
[ "$HRC" = 0 ] && [ "$SHOWN" = "$(printf "ssh -o BatchMode=yes -o ConnectTimeout=8 -- h5 '~/.local/bin/claude-discord --version --host-id'\nchecks it and writes ~/.claude-discord/host-id there if missing; adding it writes ~/.claude-discord/watchers/mgr")" ] && [ ! -e "$HOME/ssh.log" ] && [ "$(<"$MR/mgr/hosts")" = "$LEDGER" ] ||
  { echo "FAIL: add --dry-run prints the probe's command and what the add writes on that machine, and runs nothing: rc=$HRC $HO / $HE"; exit 1; }
SHOWN=${SHOWN%%$'\n'*}
t0=$(date +%s%N); HRC=0; HO=$(printf 'left on stdin\n' | bash "$S" hosts add h5 laptop X=1 2>"$HOME/hosts.err") || HRC=$?
[ $(( ($(date +%s%N) - t0) / 1000000 )) -lt 2000 ] || { echo "FAIL: an answer is taken when ssh ends, not when what it left behind lets go of its output (3 s here): $(( ($(date +%s%N) - t0) / 1000000 )) ms"; exit 1; }
SHOWN=${SHOWN#ssh }; SHOWN=${SHOWN//\'/}
[ "$HRC" = 0 ] && [ ! -s "$HOME/hosts.err" ] && [ "$(sed -n 1p "$HOME/ssh.log")" = "$SHOWN" ] && [ "$(command grep -c -- '--host-id$' "$HOME/ssh.log")" = 1 ] && ! grep -q '^ATE' "$HOME/ssh.log" && [ "$(tail -n 1 "$MR/mgr/hosts")" = "h5 laptop X=1" ] ||
  { echo "FAIL: add runs the command --dry-run printed, once, eats no stdin, and adds the host that answered (after a banner) with another home's id: rc=$HRC $HO / $(<"$HOME/hosts.err") / $(cat "$HOME/ssh.log" 2>&1)"; exit 1; }
LEDGER=$(<"$MR/mgr/hosts"); rm -f "$HOME/ssh.log"
# refused <host> <exit status> <stderr regex> <what>: `hosts add <host>` exits so, says so, and writes nothing.
refused() {
  hc add "$1"
  [ "$HRC" = "$2" ] && command grep -qE -- "$3" <<<"$HE" && [ "$(<"$MR/mgr/hosts")" = "$LEDGER" ] && [[ $HE != *$'\033'* ]] && [ "${#HE}" -lt 700 ] ||
    { echo "FAIL: $4: want exit $2 and /$3/, nothing written: rc=$HRC $HE / $(cat "$HOME/ssh.log" 2>&1)"; exit 1; }
}
# Already listed, and local: no ssh at all.
refused h5 3 'h5 is already in ' "an alias already listed is refused before any ssh"
refused local 3 'local is already in ' "local is never asked over ssh"
hc add --dry-run local; hc add --no-probe np1
[ ! -e "$HOME/ssh.log" ] && [ "$(tail -n 1 "$MR/mgr/hosts")" = np1 ] || { echo "FAIL: an alias already listed, local and --no-probe run no ssh: $(cat "$HOME/ssh.log" 2>&1)"; exit 1; }
LEDGER=$(<"$MR/mgr/hosts")
# The same home (the answer carries this home's id): refused.
ans same 1.12.0 "$L"
refused same 4 '^claude-discord: hosts: same is the same home as local' "a host that answers with this home's host-id is the same home"
# ssh itself fails (255), also on the ControlPath=none retry: not added, with ssh's own last line, cleaned: no C0 or C1
# control, no bidi override or isolate, no byte that is no UTF-8, in whatever locale.
printf 'banner \033[2J\nssh: connect to host dead port 22: Connect\302\233ion \342\200\256timed\342\201\246 out\033]0;x\007\377\n' > "$MON/dead.out"; echo 255 > "$MON/dead.rc"; : > "$MON/dead.both"
refused dead 5 'dead did not answer \(ssh exit 255, also with ControlPath=none\): ssh: connect to host dead port 22: Connection timed out\]0;x\. Not added; .*hosts add --no-probe dead' "an unreachable host is not added"
[ "$(command grep -c ' -- dead ' "$HOME/ssh.log")" = 2 ] && [ "$(command grep -c 'ControlPath=none -- dead ' "$HOME/ssh.log")" = 1 ] || { echo "FAIL: an ssh exit 255 is tried once more with ControlPath=none: $(<"$HOME/ssh.log")"; exit 1; }
# 255 on the first try only (a stale master): the retry's answer counts.
# Its answer is a 1.12.0 with no host-id: it could not make one (an unwritable home). Said as that, not as an older
# version, and added.
ans stale 1.12.0; echo 255 > "$MON/stale.rc"; echo 0 > "$MON/stale.rc2"
hc add stale
[ "$HRC" = 0 ] && [ "$(tail -n 1 "$MR/mgr/hosts")" = stale ] && [ "${HE%% (*}" = "claude-discord: hosts: warning: claude-discord 1.12.0 on stale answered but could not create its host-id" ] ||
  { echo "FAIL: a host that answers on the ControlPath=none retry is added; a 1.12.0 with no host-id with the warning that it could not create one: rc=$HRC $HE"; exit 1; }
LEDGER=$(<"$MR/mgr/hosts")
# A host that connects and never answers: the cap (0.2 s here, by the suite's own knob in tenths) ends the whole call, the ssh process group killed. Also
# when a process ssh left behind outside its group still holds the output open (as a ControlPersist master does): it
# is not waited for.
ans hang 1.12.0 "$ID_B"; echo 4 > "$MON/hang.sleep"; echo 4 > "$MON/hang.hold"
t0=$(date +%s%N); CLAUDE_DISCORD_PROBE_CAP_TENTHS=2 refused hang 5 'hang gave no answer within 0\.2s\. Not added' "a probe that hangs is ended by the cap"
[ $(( ($(date +%s%N) - t0) / 1000000 )) -lt 2200 ] && ! kill -0 "$(<"$MON/hang.pid")" 2>/dev/null || { echo "FAIL: a hung probe must end at its cap (0.2 s; within 2 s more), its ssh killed, whatever still holds its output: $(( ($(date +%s%N) - t0) / 1000000 )) ms"; exit 1; }
# The cap is an integer from 1 to 300, else the default 20 (0 would be no cap at all); a HUP to the runner (a closed
# terminal) ends ssh as the cap does. Seen through the one message that names the cap.
rm -f "$MON/hang.pid" "$MON/hang.hold"
CLAUDE_DISCORD_PROBE_CAP=0 bash "$S" hosts add hang >/dev/null 2>"$HOME/hosts.err" & hp=$!
wait_for_file "$MON/hang.pid"; read -r _ _ _ pp _ < "/proc/$(<"$MON/hang.pid")/stat"
kill -HUP "$pp"; HRC=0; wait "$hp" || HRC=$?
[ "$HRC" = 5 ] && grep -q 'hang gave no answer within 20s' "$HOME/hosts.err" && ! kill -0 "$(<"$MON/hang.pid")" 2>/dev/null ||
  { echo "FAIL: CLAUDE_DISCORD_PROBE_CAP=0 is the default 20, and a HUP to the runner kills ssh: rc=$HRC $(<"$HOME/hosts.err")"; exit 1; }
# A host that prints megabytes: read up to 65536 bytes and no further. Whatever follows them is not waded through, were
# it a version line. And a line of an answer is cut at 200 characters before any of it is printed.
{ head -c 2000000 /dev/zero | tr '\0' 'x' | fold -w 300; printf '\nclaude-discord 1.12.0 (abc1234)\nhost-id %s\n' "$ID_B"; } > "$MON/big.out"
refused big 5 'big answered, but not as claude-discord \(exit [0-9]+\): x{200}\. Install' "an answer is read up to 65536 bytes and no further, its line cut at 200 characters"
# No claude-discord there (the remote shell's exit 127).
echo 'bash: line 1: /home/u/.local/bin/claude-discord: No such file or directory' > "$MON/bare.out"; echo 127 > "$MON/bare.rc"; : > "$MON/bare.both"
refused bare 5 'bare answered, but not as claude-discord \(exit 127\): bash: line 1: /home/u/.local/bin/claude-discord: No such file or directory\. Install it there first' "a host with no claude-discord is not added"
# An older claude-discord (a version line, no host-id), behind a banner with an escape sequence and a host-id line that
# is no id: added, with a warning, and nothing of the banner reaches stderr.
printf 'motd \033[2J\033]52;c;eA==\007 banner\nclaude-discord 1.11.1 (abc1234)\nhost-id %s\nhost-id nope\n' "$(printf 'Z%.0s' {1..32})" > "$MON/old.out"
hc add old
[ "$HRC" = 0 ] && [ "$(tail -n 1 "$MR/mgr/hosts")" = old ] && grep -q '^claude-discord: hosts: warning: claude-discord 1.11.1 on old is older than 1.12.0 and has no host-id' <<<"$HE" && [[ $HE != *$'\033'* ]] && [[ $HE != *motd* ]] ||
  { echo "FAIL: a host whose claude-discord is older than 1.12.0 is added with a warning (a host-id line that is no id is none): rc=$HRC $HE"; exit 1; }
printf "$HEAD$LOCAL" > "$MR/mgr/hosts"; rm -f "$HOME/ssh.log" "$MON"/*
echo "ok: host-id is made once (eight first calls agree, a damaged file is replaced); hosts add asks the host with the command --dry-run prints (stdin closed, ConnectTimeout, -- before the alias, a 255 retried with ControlPath=none), refuses the same home (exit 4) and a host that did not answer, hung past the cap (whatever holds its output open), printed megabytes or has no claude-discord (exit 5, its last line cleaned and cut), takes the last version line after a banner, and adds an older claude-discord with a warning; --no-probe, local and a listed alias run no ssh"

# watchers/<manager>, on the checked host (this sandbox HOME plays that host): --watch writes one line, --host-id lists
# every file, --unwatch removes only the record of the home that wrote it. A word of the wrong shape writes nothing.
WD="$HOME/.claude-discord/watchers"; ID_C=$(printf 'c%.0s' {1..32}); rm -rf "$WD"
A=$(bash "$S" --version --watch other "$ID_B" my-alias | sed 1d)
read -r wi wa ws < "$WD/other"
[ "$A" = "watched other" ] && [ "$wi $wa" = "$ID_B my-alias" ] && [[ $ws =~ ^20[0-9-]{8}T[0-9:]{8}Z$ ]] && [ "$(stat -c %a "$WD/other")$(stat -c %a "$WD")" = 600700 ] && [ "$(ls -A "$WD")" = other ] ||
  { echo "FAIL: --version --watch writes watchers/<manager> as '<host-id> <alias> <time>': $A / $(cat "$WD/other" 2>&1) / $(ls -lA "$WD" 2>&1)"; exit 1; }
mkdir "$WD/adir"; : > "$WD/.hidden"; : > "$WD/we ird"; printf 'x\033[2J y z w v\n' > "$WD/junk"
[ "$(bash "$S" --version --host-id | sed 1d)" = "$(printf 'host-id %s\nwatcher junk x[2J y z w v\nwatcher other %s my-alias %s' "$L" "$ID_B" "$ws")" ] ||
  { echo "FAIL: --version --host-id lists each watcher file after the host-id (plain names only, no control character): $(bash "$S" --version --host-id | od -c | head -20)"; exit 1; }
rm -rf "$WD/adir" "$WD/.hidden" "$WD/we ird" "$WD/junk"
for bad in "../x $ID_B a" "ok nothex a" "ok $ID_B -oProxyCommand=x"; do
  rc=0; bash "$S" --version --watch $bad >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] && [ "$(ls -A "$WD")" = other ] && [ ! -e "$HOME/.claude-discord/x" ] || { echo "FAIL: --watch '$bad' has a word of the wrong shape: exit 2, nothing written: rc=$rc $(ls -A "$WD" "$HOME/.claude-discord")"; exit 1; }
done
rc=0; bash "$S" --version --watch me "$L" a >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] && [ ! -e "$WD/me" ] || { echo "FAIL: a home never records itself as its own watcher: rc=$rc"; exit 1; }
A=$(bash "$S" --version --unwatch other "$ID_C" | sed 1d)
[ "$A" = "unwatched other" ] && [ -e "$WD/other" ] || { echo "FAIL: --unwatch from another home must leave the record: $A"; exit 1; }
bash "$S" --version --unwatch other "$ID_B" >/dev/null
[ ! -e "$WD/other" ] || { echo "FAIL: --unwatch from the home that wrote the record removes it"; exit 1; }
rm -rf "$WD"
# hosts add reads the host's watchers. Another manager's record: a warning, added all the same, and this manager's
# own record is then written there (the second ssh call), with words that need no quoting.
LEDGER=$(<"$MR/mgr/hosts"); rm -f "$HOME/ssh.log"
ans w1 1.12.0 "$ID_B"; printf 'watcher other %s their-alias 2026-10-01T00:00:00Z\nwatcher ev/il %s a 2026-10-01T00:00:00Z\nwatcher bad nothex a 2026-10-01T00:00:00Z\nwatcher\n' "$ID_C" "$ID_C" >> "$MON/w1.out"
hc add w1
[ "$HRC" = 0 ] && [ "$(tail -n 1 "$MR/mgr/hosts")" = w1 ] && [ "$HE" = "claude-discord: hosts: warning: w1 is already watched by other (since 2026-10-01T00:00:00Z): both managers will report its bots" ] &&
  [ "$(sed -n 2p "$HOME/ssh.log")" = "-o BatchMode=yes -o ConnectTimeout=8 -- w1 ~/.local/bin/claude-discord --version --watch mgr $L w1" ] && [ "$(wc -l < "$HOME/ssh.log")" = 2 ] ||
  { echo "FAIL: another manager's watcher record is a warning (a record of the wrong shape is none); the host is added and this manager's record sent: rc=$HRC $HE / $(cat "$HOME/ssh.log" 2>&1)"; exit 1; }
# This manager's own record under another alias that is still listed: the same home again, refused. No --watch call.
ans w2 1.12.0 "$ID_B"; printf 'watcher mgr %s w1 2026-10-02T00:00:00Z\n' "$L" >> "$MON/w2.out"
LEDGER=$(<"$MR/mgr/hosts"); rm -f "$HOME/ssh.log"
refused w2 4 '^claude-discord: hosts: w2 is the same home as w1 \(' "a host this manager already checks under another alias is the same home"
[ "$(wc -l < "$HOME/ssh.log")" = 1 ] || { echo "FAIL: a refused add sends no --watch: $(<"$HOME/ssh.log")"; exit 1; }
# The same record once w1 is out of the ledger is stale: added, no warning. A record for this very alias is ours too.
hc rm --no-probe w1; hc add w2; A=$HRC$HE
printf 'watcher mgr %s w3 2026-10-02T00:00:00Z\n' "$L" >> "$MON/w2.out"; cp "$MON/w2.out" "$MON/w3.out"; hc add w3
[ "$A$HRC$HE" = 00 ] && [ "$(tail -n 2 "$MR/mgr/hosts")" = "$(printf 'w2\nw3')" ] || { echo "FAIL: this manager's own record under an alias no longer listed, or under the alias being added, is no obstacle: $A / rc=$HRC $HE"; exit 1; }
# A manager of the same name from another home: a warning that says so.
ans w4 1.12.0 "$ID_B"; printf 'watcher mgr %s x 2026-10-03T00:00:00Z\n' "$ID_C" >> "$MON/w4.out"
hc add w4
[ "$HRC" = 0 ] && grep -q '^claude-discord: hosts: warning: w4 is already watched by a manager also named mgr, from another home (since 2026-10-03T00:00:00Z)' <<<"$HE" || { echo "FAIL: a watcher of the same name from another home is said as such: rc=$HRC $HE"; exit 1; }
# The --watch call fails (the host went away between the two calls): added, with a warning.
ans w5 1.12.0 "$ID_B"; rm -f "$HOME/ssh.log"
printf '#!/bin/bash\ncase "$*" in *--watch*) exit 255;; esac\nexec "%s" "$@"\n' "$HOME/bin/ssh" > "$HOME/ssh-nowatch"; chmod +x "$HOME/ssh-nowatch"
mkdir -p "$HOME/nwbin"; ln -sf "$HOME/ssh-nowatch" "$HOME/nwbin/ssh"
HRC=0; HE=$(PATH="$HOME/nwbin:$PATH" bash "$S" hosts add w5 2>&1 >/dev/null) || HRC=$?
[ "$HRC" = 0 ] && [ "$(tail -n 1 "$MR/mgr/hosts")" = w5 ] && grep -q '^claude-discord: hosts: warning: w5 is added, but this manager could not be recorded there (ssh exit 255)' <<<"$HE" || { echo "FAIL: a failed --watch is a warning, the host stays added: rc=$HRC $HE"; exit 1; }
rm -rf "$HOME/nwbin" "$HOME/ssh-nowatch"
# An older claude-discord (no host-id) is sent no --watch; a manager whose name a file name cannot carry sends none and says so.
ans w6 1.11.1; rm -f "$HOME/ssh.log"; hc add w6
mkdir -p "$MR/m gr"; echo dev-manager > "$MR/m gr/mode"; echo local > "$MR/m gr/hosts"; ans w7 1.12.0 "$ID_B"
hc --bot "m gr" add w7
[ "$HRC" = 0 ] && [ "$(wc -l < "$HOME/ssh.log")" = 2 ] && [ "$(<"$MR/m gr/hosts")" = "$(printf 'local\nw7')" ] && grep -q "^claude-discord: hosts: warning: no watcher record is written for a manager named 'm gr'" <<<"$HE" ||
  { echo "FAIL: no --watch to an older claude-discord, and none for a manager name that is no plain file name: rc=$HRC $HE / $(<"$HOME/ssh.log")"; exit 1; }
rm -rf "$MR/m gr"
# hosts rm: the ledger first, then --unwatch with this home's id. Unreachable: exit 0, the line gone, the way to
# remove the record later said. --no-probe, and a home with no host-id, send nothing.
rm -f "$HOME/ssh.log"; hc rm w2
[ "$HRC" = 0 ] && [ -z "$HE" ] && [ "$(<"$HOME/ssh.log")" = "-o BatchMode=yes -o ConnectTimeout=8 -- w2 ~/.local/bin/claude-discord --version --unwatch mgr $L" ] && ! grep -q '^w2' "$MR/mgr/hosts" ||
  { echo "FAIL: rm removes the line, then this manager's watcher record on the host: rc=$HRC $HE / $(cat "$HOME/ssh.log" 2>&1)"; exit 1; }
echo 255 > "$MON/w3.rc"; hc rm w3
[ "$HRC" = 0 ] && ! grep -q '^w3' "$MR/mgr/hosts" && grep -q "^claude-discord: hosts: warning: w3 did not answer (ssh exit 255), so this manager's watcher record stays there.*ssh w3 '~/.local/bin/claude-discord --version --unwatch mgr $L'" <<<"$HE" ||
  { echo "FAIL: rm of a host that cannot be reached still removes the line (exit 0) and says how to remove the record later: rc=$HRC $HE"; exit 1; }
rm -f "$HOME/ssh.log"; hc rm --no-probe w4; mv "$HID" "$HID.off"; hc rm w5; mv "$HID.off" "$HID"
[ "$HRC" = 0 ] && [ ! -e "$HOME/ssh.log" ] && [ ! -e "$HID.off" ] && ! command grep -qE '^w[45]' "$MR/mgr/hosts" || { echo "FAIL: rm --no-probe, and rm from a home with no host-id, run no ssh: rc=$HRC $(cat "$HOME/ssh.log" 2>&1)"; exit 1; }
printf "$HEAD$LOCAL" > "$MR/mgr/hosts"; rm -f "$HOME/ssh.log" "$MON"/*
echo "ok: watchers: --version --watch/--unwatch write and remove watchers/<manager> on the checked host (words of the wrong shape write nothing, a home removes only its own record) and --host-id lists them; hosts add warns of another manager's record, refuses a home this manager already checks under a listed alias (exit 4), then records itself there (a failure is a warning); hosts rm removes the line first and the record after, also when the host is unreachable"

# --- access: who may drive a bot (1.13.0) ------------------------------------
# ac <args>: `claude-discord access <args>` in the manager's project; stdout in AO, stderr in AE, the exit status in ARC.
ac() { ARC=0; AO=$(bash "$S" access "$@" 2>"$HOME/access.err") || ARC=$?; AE=$(<"$HOME/access.err"); }
# The bot these cases drive: made by hand (setup is asserted above; each run of it costs 0.2 s). Its access.json holds
# what the plugin and an owner may have put there besides the policy: a pending pairing, a key nobody here knows.
cd "$MP"; AD="$MR/acc"; mkdir -p "$AD"; echo none > "$AD/mode"; printf 'DISCORD_BOT_TOKEN=tokAccUnique\n' > "$AD/.env"
ACC='{"dmPolicy":"allowlist","allowFrom":["111"],"ackReaction":"👀","groups":{"900":{"requireMention":true,"allowFrom":["111","222"]},"901":{"requireMention":false,"allowFrom":[]}},"pending":{"abc123":{"senderId":"999","chatId":"5","createdAt":1,"expiresAt":99999999999999}},"custom":{"keep":[1,2]}}'
jq . <<<"$ACC" > "$AD/access.json"; printf '777\n' > "$AD/bot-id"; printf '900 5 dev-bots %s\n' "$(date +%s)" > "$AD/channel-guild"
printf '900 dev-bots\n901 bot-health\n' > "$AD/channel-names"; printf '111 dongyong22\n222 gpu villain\n' > "$AD/user-names"
printf '{"peers":[{"name":"peerbot","bot_id":"555","owner_id":"1","machine":"m"},{"name":"ACC","bot_id":"777","owner_id":"1","machine":"m"},{"name":"odd","bot_id":"x9","owner_id":"1","machine":"m"}]}\n' > "$(pstate "$MP")/peers.json"
# access --json asks Discord four things with the bot's token: the server's channels, the server (its roles), the bot's
# membership (its roles) and the members. Whether the bot can read a channel is VIEW_CHANNEL (1024) and
# READ_MESSAGE_HISTORY (65536) after the roles and the channel's overwrites: 900 plain; 901 denied to @everyone and
# given back to a role of the bot; 902 denied to @everyone; 903 its history denied to the bot itself; 904 a voice
# channel (not listed); 905 an overwrite that is no number (not known, never a guess); 906 a forum, denied to a role
# the bot has not, its name with an escape sequence, a bidi override and a zero-width space in it; 907 allowed to one
# role of the bot and denied to another (within one level the allow wins). 905's name is cut at 40 characters.
A_CH='[{"id":"900","type":0,"name":"dev-bots","position":1,"permission_overwrites":[]},{"id":"901","type":0,"name":"bot-health","position":2,"permission_overwrites":[{"id":"5","type":0,"allow":"0","deny":"1024"},{"id":"70","type":0,"allow":"1024","deny":"0"}]},{"id":"902","type":0,"name":"general","position":3,"permission_overwrites":[{"id":"5","type":0,"allow":"0","deny":"1024"}]},{"id":"903","type":0,"name":"hist","position":4,"permission_overwrites":[{"id":"777","type":1,"allow":"0","deny":"65536"}]},{"id":"904","type":2,"name":"voice","position":5},{"id":"905","type":0,"name":"abcdefghijabcdefghijabcdefghijabcdefghijabcde","position":6,"permission_overwrites":[{"id":"5","type":0,"allow":"x","deny":"0"}]},{"id":"906","type":15,"name":"fo\u001b[2J\u202erum\u200b","position":0,"permission_overwrites":[{"id":"71","type":0,"allow":"0","deny":"1024"}]},{"id":"907","type":0,"name":"split","position":7,"permission_overwrites":[{"id":"70","type":0,"allow":"1024","deny":"0"},{"id":"72","type":0,"allow":"0","deny":"1024"}]}]'
A_G='{"id":"5","name":"Tor-AIC","owner_id":"1","roles":[{"id":"5","permissions":"66560"},{"id":"70","permissions":"0"},{"id":"71","permissions":"8"},{"id":"72","permissions":"0"}]}'
A_M='{"user":{"id":"777"},"roles":["70","72"]}'
A_MM='[{"user":{"id":"111","username":"dy","global_name":"dongyong22"},"nick":null},{"user":{"id":"333","username":"jbot","bot":true},"nick":"junyong-dev-bot"}]'
: > "$CURL_LOG"; : > "$CURL_STDIN_LOG"; : > "$CURL_REPLIES"
queue_line "200 $A_CH"; queue_line "200 $A_G"; queue_line "200 $A_M"; queue_line "200 $A_MM"
ac acc --json
[ "$ARC" = 0 ] && [ -z "$AE" ] && [ "$(wc -l <<<"$AO")" = 1 ] && jq -e --arg p "$(pwd -P)" '.access == 1 and .bot == "acc" and .bot_id == "777" and .project == $p and .mode == "none" and .owner == "111" and .main == "900"
  and .peers == ["555"] and .guild == {id: "5", name: "Tor-AIC"} and .members == "api" and .errors == []
  and .policy == {dm: "allowlist", dm_allow: ["111"], groups: [{id: "900", mention: true, allow: ["111", "222"]}, {id: "901", mention: false, allow: []}]}
  and ([.channels[] | [.id, .name, .kind, .read]] == [["906", "fo[2Jrum", "forum", true], ["900", "dev-bots", "text", true], ["901", "bot-health", "text", true],
       ["902", "general", "text", false], ["903", "hist", "text", false], ["905", "abcdefghijabcdefghijabcdefghijabcdefghij", "text", null], ["907", "split", "text", true]])
  and .people == [{id: "111", name: "dongyong22", kept: "dongyong22", bot: false}, {id: "222", name: "gpu villain", kept: "gpu villain", bot: false},
                  {id: "333", name: "junyong-dev-bot", kept: "", bot: true}, {id: "555", name: "peerbot", kept: "peerbot", bot: true}, {id: "777", name: "ACC", kept: "ACC", bot: true}]' <<<"$AO" >/dev/null &&
  [ "$(<"$AD/member-names")" = "$(printf '111 dongyong22\n333 junyong-dev-bot')" ] && [ "$(stat -c %a "$AD/member-names")" = 600 ] ||
  { echo "FAIL: access --json is one line: the policy, the server's text and forum channels with whether the bot can read each (true, false, or null when it cannot be told), the people (the members, then the names kept here, which are marked kept), the peers; the member list's names are kept in member-names for set: rc=$ARC $AO / $AE / $(cat "$AD/member-names" 2>&1)"; exit 1; }
[ "$(<"$CURL_LOG")" = "$(printf '%s\n' "-s --max-time 5 -w \n%{http_code} -H @- https://discord.com/api/v10/guilds/5/"{channels,,members/777,members?limit=1000} | sed 's#/$##')" ] &&
  [ "$(sort -u "$CURL_STDIN_LOG")" = "Authorization: Bot tokAccUnique" ] && [[ $AO$AE$(<"$CURL_LOG") != *tokAcc* ]] ||
  { echo "FAIL: access --json makes four calls, the token on curl's stdin and nowhere else: $(<"$CURL_LOG") / $(<"$CURL_STDIN_LOG")"; exit 1; }
# What cannot be told is not guessed: with no @everyone role among the server's roles no channel is readable or
# unreadable, only not known; with the member list refused (the Server Members Intent is off) the people are the
# names kept here, and that is no error.
: > "$CURL_REPLIES"; queue_line "200 $A_CH"; queue_line '200 {"id":"5","name":"Tor-AIC","owner_id":"1","roles":[{"id":"70","permissions":"66560"}]}'; queue_line "200 $A_M"; queue_line '403 {"message":"Missing Access"}'
ac acc --json
[ "$ARC" = 0 ] && jq -e '([.channels[].read] | unique) == [null] and (.channels | length) == 7 and .members == "names" and .errors == [] and [.people[].id] == ["111", "222", "555", "777"]' <<<"$AO" >/dev/null ||
  { echo "FAIL: roles that do not say what @everyone may do leave every channel not known (null), never readable; no member list is no error: rc=$ARC $AO / $AE"; exit 1; }
# The server's owner reads every channel, whatever its overwrites (an administrator too: --host local, below).
: > "$CURL_REPLIES"; queue_line "200 $A_CH"; queue_line "200 $(jq -c '.owner_id = "777"' <<<"$A_G")"; queue_line "200 $A_M"; queue_line '403 {}'
ac acc --json
[ "$ARC" = 0 ] && jq -e '[.channels[] | select(.kind != "unknown") | .read] == [true, true, true, true, true, true, true]' <<<"$AO" >/dev/null ||
  { echo "FAIL: the server's owner reads every channel: rc=$ARC $AO / $AE"; exit 1; }
# Usage, a bot that is not set up, and the verb's name as a bot's.
for bad in "" "acc frob" "--frob acc --json"; do
  ac $bad
  [ "$ARC" = 2 ] && grep -q '^usage: claude-discord access ' <<<"$AE" || { echo "FAIL: 'access $bad' is a usage error (exit 2): rc=$ARC $AE"; exit 1; }
done
ac nosuch --json
[ "$ARC" = 1 ] && grep -q "no bot 'nosuch' set up in $MR" <<<"$AE" || { echo "FAIL: a bot that is not set up is exit 1: rc=$ARC $AE"; exit 1; }
# One run (bot); access and add are asserted on the wrapper's reserved_name case line, which that run proves is used (1.14.1: review cut 4).
rc=0; out=$(printf '\n' | bash "$S" setup bot 2>&1) || rc=$?
[ "$rc" = 2 ] && grep -q "bot name 'bot' is reserved" <<<"$out" && grep -q '^reserved_name() { case \$1 in .*|hosts|access|bot|add|hooks|checkin|boot) return 0;; esac; return 1; }$' "$S" ||
  { echo "FAIL: access, bot and add are words claude-discord uses (a subcommand, bot add), so no bot may take the name: rc=$rc $out / $(grep -n '^reserved_name()' "$S")"; exit 1; }
# A DISCORD_CHANNEL_ID that is no id (the bot's main channel when access.json does not say) is said, before Discord is asked.
cp "$(pstate "$MP")/config.env" "$HOME/acc.env.was"; printf "DISCORD_CHANNEL_ID='9 9'\nDISCORD_USER_ID='111'\n" > "$(pstate "$MP")/config.env"; : > "$CURL_LOG"
ac acc --json; cp "$HOME/acc.env.was" "$(pstate "$MP")/config.env"; rm -f "$HOME/acc.env.was"
[ "$ARC" = 1 ] && [ -z "$AO" ] && grep -q "^claude-discord: access: DISCORD_CHANNEL_ID in $(pstate "$MP")/config.env is not a channel id" <<<"$AE" && [ ! -s "$CURL_LOG" ] ||
  { echo "FAIL: a DISCORD_CHANNEL_ID that is no id is exit 1 with a reason, not an empty answer: rc=$ARC $AO / $AE"; exit 1; }
echo "ok: access --json: one line with the policy, the server's channels and whether the bot can read each (roles, then the channel's overwrites for @everyone, the bot's roles, allow over deny within one level, and the bot; the server's owner and an administrator read all; not known is null, never a guess), names without controls, bidi or zero-width characters and cut at 40, the people (the member list when Discord gives it, the names kept here when it does not) and the peers; four calls, the token on curl's stdin only; a DISCORD_CHANNEL_ID that is no id is exit 1; 'access' is a reserved bot name"
# access set, with no terminal: the changes are printed and nothing is written (exit 3), so what a set of words would do
# can be read by anyone. A change that widens who can drive the bot is marked "!": an @mention no longer required, a
# channel opened to anyone, DMs to pairing, a person added to the DM allowlist, a person the bot listed nowhere
# (333: once, however many channels). The rest is not: a sender taken off, a channel added for people it already
# lists, a channel left. People are named with their id (a display name is the sender's to choose), channels by name:
# a name kept here before the id, one only the member list gave (member-names, from the last --json) after it.
A_FILE=$(<"$AD/access.json")
ac acc set mention:900=off allow:900-222 allow:900+333 channel+902 allow:902+333 allow:902+222 mention:901=on allow:901+111 dm=pairing dm+222 dm-111
[ "$ARC" = 3 ] && [ "$AO" = "claude-discord: access: acc on $(uname -n | cut -d. -f1), $AD/access.json
  ! #dev-bots: an @mention required -> any message
  ! 333 (junyong-dev-bot): new to this bot: may write to it in #dev-bots, #902
  ! DMs: allowlist -> pairing: anyone who shares a server with the bot can DM it and is sent a pairing code
  ! DMs: + gpu villain (222) may DM it, and answers its permission prompts
    #dev-bots: - gpu villain (222) may no longer write to it there
    #bot-health: any message -> an @mention required
    #bot-health: from anyone -> from dongyong22 (111)
    #902: + listens here: an @mention required, from dongyong22 (111), gpu villain (222), 333 (junyong-dev-bot)
    DMs: - dongyong22 (111) may no longer DM it
warning: dongyong22 (111) is the owner of this bot and no longer gets its DMs or its permission prompts" ] &&
  grep -q 'not a terminal (stdin and stdout), so nothing was changed' <<<"$AE" && [ "$(<"$AD/access.json")" = "$A_FILE" ] && [ ! -e "$AD/access.log" ] ||
  { echo "FAIL: access set with no terminal prints the changes (the widenings first, marked !, then the others, the warnings last), writes nothing and exits 3: rc=$ARC $AO / $AE"; exit 1; }
# The other widenings and warnings: a channel opened to anyone, a new channel that answers every message, the owner
# and a peer bot taken off a dev-manager's channel, the channel the bot's prompt and hooks name left behind.
echo dev-manager > "$AD/mode"; jq '.groups["900"].allowFrom += ["555"] | .dmPolicy = "disabled"' <<<"$ACC" > "$AD/access.json"
ac acc set allow:901=any allow:901+111 allow:901=any channel+903 mention:903=off allow:900-111 allow:900-555 channel-901 channel-900 channel+900 allow:900+222 allow:900-111 dm=allowlist
[ "$ARC" = 3 ] && [ "$(sed 1d <<<"$AO")" = "  ! #903: answers every message there, with no @mention
  ! DMs: disabled -> allowlist: the bot receives again, in its channels too (disabled drops every message)
    #903: + listens here: any message, from dongyong22 (111)
    #dev-bots: - dongyong22 (111) may no longer write to it there
    #dev-bots: - peerbot (555) may no longer write to it there
    #bot-health: - stops listening here
warning: dongyong22 (111) is the owner of this bot (DISCORD_USER_ID) and can no longer write to it in #dev-bots
warning: peerbot (555) is a peer dev bot (peers.json) and can no longer reach this bot in #dev-bots" ] ||
  { echo "FAIL: the words are applied in order (a channel left and taken again is the same channel with the senders given; =any undone by a later +), and the owner's and a peer's removal are warned of: rc=$ARC $AO / $AE"; exit 1; }
# Narrowing cuts a peer off as a removal does: 901 lists nobody (everyone), so the peer bot reaches it until a sender is put on it.
echo dev-manager > "$AD/mode"; jq '.groups["900"].allowFrom += ["555"]' <<<"$ACC" > "$AD/access.json"
ac acc set allow:901+111
[ "$ARC" = 3 ] && grep -qx 'warning: peerbot (555) is a peer dev bot (peers.json) and can no longer reach this bot in #bot-health' <<<"$AO" ||
  { echo "FAIL: a peer bot's open channel narrowed to others is warned of: rc=$ARC $AO / $AE"; exit 1; }
ac acc set allow:901+111 allow:901+555
! grep -q 'peerbot (555) is a peer dev bot' <<<"$AO" || { echo "FAIL: a peer put on the narrowed channel is no warning: $AO"; exit 1; }
# peers.json lists the bot itself too: with no warning for it (only the peers that go onto the lists are named) that call writes with no terminal.
[ "$ARC" = 0 ] && grep -q 'written without a question' <<<"$AO" || { echo "FAIL: a peer put on the narrowed channel, nothing else in it, is written with no terminal (the bot itself in peers.json is no peer): rc=$ARC $AO / $AE"; exit 1; }
find "$AD" -maxdepth 1 -name access.log -delete
echo none > "$AD/mode"; printf '%s\n' "$A_FILE" > "$AD/access.json"
printf "DISCORD_CHANNEL_ID='901'\nDISCORD_USER_ID='111'\n" > "$HOME/acc.env"; cp "$(pstate "$MP")/config.env" "$HOME/acc.env.was"; cp "$HOME/acc.env" "$(pstate "$MP")/config.env"
ac acc set channel-901 dm=off; cp "$HOME/acc.env.was" "$(pstate "$MP")/config.env"; rm -f "$HOME/acc.env" "$HOME/acc.env.was"
[ "$ARC" = 3 ] && grep -qx 'warning: the main channel of the bot becomes #dev-bots (was #bot-health): its session prompt, its hooks and health use that one' <<<"$AO" &&
  grep -qx '    DMs: allowlist -> off' <<<"$AO" && grep -qx '    DMs: - dongyong22 (111) may no longer DM it' <<<"$AO" ||
  { echo "FAIL: leaving the channel config.env names moves the bot's main channel to the one group left, and is warned of; dm=off is an allowlist with nobody on it (not the plugin's disabled): rc=$ARC $AO"; exit 1; }
# What cannot be made is refused before anything is asked (exit 2): the last sender taken off a list (an empty list is
# everyone: only =any says that), a rule for a channel the bot does not listen in. What is no change word at all is
# refused without being echoed: it is text from somewhere else.
ac acc set allow:900-111 allow:900-222
[ "$ARC" = 2 ] && [ -z "$AO" ] && grep -q '^claude-discord: access: allow:900: that would leave no sender, and a channel with none listed takes everyone. Say allow:900=any' <<<"$AE" ||
  { echo "FAIL: the last sender is never removed into an open channel: rc=$ARC $AO / $AE"; exit 1; }
ac acc set mention:905=off
[ "$ARC" = 2 ] && grep -q 'mention:905: the bot does not listen in that channel' <<<"$AE" || { echo "FAIL: a rule for a channel that is no group is exit 2: rc=$ARC $AE"; exit 1; }
for bad in 'dm=pairing;secretpw' dm=disabled $'allow:900+111\nsecretpw' "channel+$(printf '9%.0s' {1..21})"; do
  ac acc set dm=off "$bad"
  [ "$ARC" = 2 ] && [ -z "$AO" ] && [ "$AE" = "claude-discord: access: change 2 is not one of the changes access takes (claude-discord access, with no argument, lists them)" ] ||
    { echo "FAIL: '$bad' is no change: exit 2, nothing printed of it: rc=$ARC $AO / $AE"; exit 1; }
done
ac acc set channel+900 mention:900=on allow:900+111 dm=allowlist dm+111
[ "$ARC" = 0 ] && [ "$AO" = "claude-discord: access: acc is already so; nothing to change" ] && [ "$(<"$AD/access.json")" = "$A_FILE" ] && [ ! -e "$AD/access.log" ] ||
  { echo "FAIL: words that change nothing are said so (exit 0, with or without a terminal): rc=$ARC $AO / $AE"; exit 1; }
echo "ok: access set without a terminal prints what would change and writes nothing (exit 3): the widenings first, each marked (no @mention, anyone, pairing, back from disabled, a DM sender, a person new to the bot), the owner's, a peer's and the main channel's loss warned of, the words applied in order; a list is never emptied by a removal, a rule needs its channel, and what is no change word is refused unechoed (exit 2)"
# access set at a terminal. at <answers> <args>: the same call with a terminal on stdin and stdout (python3's pty, which
# types what it is fed; the suite needs python3 for thread-guard's table already), all it printed in AO. Past the
# answers a case means come two n: a question nobody expected is answered no (exit 4) instead of hanging the suite.
at() { ARC=0; AO=$(printf "$1"'n\nn\n' | python3 -c 'import os, pty, sys; sys.exit(os.waitstatus_to_exitcode(pty.spawn(sys.argv[1:])))' bash "$S" access "${@:2}" 2>&1) || ARC=$?; AO=${AO//$'\r'/}; }
# One question for the whole change set (1.13.1), naming how many changes and how many of them widen. Yes: the file is replaced by rename (never
# written in place: the plugin reads it at every message), mode 600 whatever it was, and holds the new policy with
# every other key as it was and in its place (the plugin's pending pairing, a key nobody here knows); access.log gets
# the time, the account, the machine and the words, marked access.json. The question is the last line, and the line
# before it is the CLI's marker (U+2060 alone, which no name can hold: names are cleaned of it), for the TUI to know
# the question from a name ending in [y/N].
chmod 644 "$AD/access.json"; ai=$(stat -c %i "$AD/access.json")
at 'y\n' acc set mention:900=off allow:900-222 channel+902 dm=pairing
[ "$ARC" = 0 ] && [ "$(grep -o '\[y/N\]' <<<"$AO" | wc -l)" = 1 ] && grep -q '^Apply 4 changes, 2 of them widening? \[y/N\]' <<<"$AO" &&
  [ "$(grep -B1 '^Apply 4 changes, 2 of them widening? \[y/N\]' <<<"$AO" | head -n1)" = $'\342\201\240' ] &&
  grep -q "access.json written. The plugin reads it at the next message: no restart.$" <<<"$AO" && grep -qF $'\033[1;31m  ! #dev-bots: an @mention required -> any message\033[0m' <<<"$AO" ||
  { echo "FAIL: at a terminal one question names the changes and the widenings (shown red) among them: rc=$ARC $(printf '%q' "$AO")"; exit 1; }
[ "$(jq -c . "$AD/access.json")" = '{"dmPolicy":"pairing","allowFrom":["111"],"ackReaction":"👀","groups":{"900":{"requireMention":false,"allowFrom":["111"]},"901":{"requireMention":false,"allowFrom":[]},"902":{"requireMention":true,"allowFrom":["111"]}},"pending":{"abc123":{"senderId":"999","chatId":"5","createdAt":1,"expiresAt":99999999999999}},"custom":{"keep":[1,2]}}' ] &&
  [ "$(stat -c %a "$AD/access.json")" = 600 ] && [ "$(stat -c %i "$AD/access.json")" != "$ai" ] && [ "$(ls "$AD" | grep -c '^access')" = 3 ] ||
  { echo "FAIL: the new access.json holds the changes and every other key as it was, is mode 600 and was moved in (access.json, its .lock and access.log are all there is): $(jq -c . "$AD/access.json") $(ls -l "$AD")"; exit 1; }
[[ $(<"$AD/access.log") =~ ^20[0-9-]{8}T[0-9:]{8}Z\ $(id -un)\ $(uname -n | cut -d. -f1)\ access.json:\ mention:900=off\ allow:900-222\ channel\+902\ dm=pairing$ ]] && [ "$(stat -c %a "$AD/access.log")" = 600 ] ||
  { echo "FAIL: access.log has one line for the write: time, account, machine, the change words: $(cat "$AD/access.log" 2>&1)"; exit 1; }
# A terminal on stdout with stdin from elsewhere is no terminal: nothing is asked, nothing written (exit 3; a widening change, since one that widens nothing is written with no question, test-install.sh).
A=$(<"$AD/access.json"); ARC=0; AO=$(python3 -c 'import os, pty, sys; sys.exit(os.waitstatus_to_exitcode(pty.spawn(sys.argv[1:])))' bash -c 'exec bash "$0" access acc set allow:900=any </dev/null' "$S" 2>&1) || ARC=$?
[ "$ARC" = 3 ] && grep -q 'not a terminal (stdin and stdout), so nothing was changed' <<<"$AO" && [ "$(<"$AD/access.json")" = "$A" ] ||
  { echo "FAIL: stdin that is no terminal is refused even with stdout one (exit 3): rc=$ARC $AO"; exit 1; }
# Anything but y writes nothing (exit 4): the file is what was shown and agreed to, or as it was. Here the answer is
# "yes", which is not y; the changes all widen, which the question says.
printf '%s\n' "$A_FILE" > "$AD/access.json"; A_LOG=$(<"$AD/access.log")
at 'yes\n' acc set mention:900=off dm=pairing
[ "$ARC" = 4 ] && grep -q 'answered no; nothing was changed' <<<"$AO" && [ "$(grep -o '\[y/N\]' <<<"$AO" | wc -l)" = 1 ] && grep -q '^Apply these 2 widening changes? \[y/N\]' <<<"$AO" &&
  [ "$(<"$AD/access.json")" = "$A_FILE" ] && [ "$(<"$AD/access.log")" = "$A_LOG" ] ||
  { echo "FAIL: an answer that is not y writes nothing and exits 4, asking nothing more; changes that all widen are said so: rc=$ARC $AO"; exit 1; }
# Another writer: while one holds the lock a second waits for it, then makes its document from the file as it is THEN,
# and writes nothing when the policy in it is no longer the one its question was about.
perl -e 'open(L, ">>", "$ARGV[0].lock") or die; flock(L, 2) or die; open(R, ">", "$ARGV[0].held"); print R 1; close R; select(undef, undef, undef, 0.1);
  open(F, ">", "$ARGV[0].other") or die; print F $ARGV[1]; close F; rename "$ARGV[0].other", $ARGV[0]' "$AD/access.json" "$(jq '.groups["901"].allowFrom = ["111"]' <<<"$ACC")" &
wait_for_file "$AD/access.json.held"; rm -f "$AD/access.json.held"
at 'y\n' acc set channel-901; wait
[ "$ARC" = 1 ] && grep -q '^Apply this change? \[y/N\]' <<<"$AO" && grep -q 'changed while you were answering (or is no longer valid JSON); nothing was changed, run it again' <<<"$AO" && [ "$(jq -c '.groups["901"]' "$AD/access.json")" = '{"requireMention":false,"allowFrom":["111"]}' ] ||
  { echo "FAIL: a write waits for the lock and is given up when the policy changed meanwhile: rc=$ARC $AO / $(jq -c .groups "$AD/access.json")"; exit 1; }
printf '%s\n' "$A_FILE" > "$AD/access.json"
echo "ok: access set at a terminal asks once for the whole change set, naming the widenings among them; yes writes access.json by rename, mode 600, every other key kept, and one access.log line; anything but y writes nothing (exit 4); a second writer waits for the lock and gives up when the policy changed under its question"
# The mode goes through `setup <bot> --mode` (the mode on its stdin; its peers and hosts questions read the end of
# input, which keeps both lists), after this verb's own question. A mode alone changes no access.json; the mode the
# bot has is no change, and a word that is no mode is no change word.
ac acc set mode=none; A=$ARC$AO; ac acc set mode=secretpw
[ "$A" = "0claude-discord: access: acc is already so; nothing to change" ] && [ "$ARC" = 2 ] && [[ $AO$AE != *secretpw* ]] || { echo "FAIL: the bot's own mode is nothing to change, and a mode setup does not know is refused unechoed: $A / rc=$ARC $AE"; exit 1; }
# Into dev-manager: the peers of peers.json go into every channel that lists its senders, once, after all the other
# words, wherever mode= stands; the changes shown say so (555 is new to this bot: a widening, here on the channel
# added in the same call too; 777 is this bot itself, skipped by name as setup skips it).
ac acc set mode=dev-manager channel+902; A=$ARC$AO; ac acc set channel+902 mode=dev-manager
[ "$ARC$AO" = "$A" ] && [ "$ARC" = 3 ] && [ "$(sed 1d <<<"$AO")" = "  ! peerbot (555): new to this bot: may write to it in #dev-bots, #902
    #902: + listens here: an @mention required, from dongyong22 (111), peerbot (555)
    mode: none -> dev-manager: it gets a hosts ledger (this machine) and its monitor starts, which posts in #bot-health-check" ] || { echo "FAIL: mode=dev-manager shows the peers it adds, to a channel added in the same call too, whatever the order of the words: $A / rc=$ARC $AO / $AE"; exit 1; }
# A peer the bot already lists is known: put on one more channel it is no widening. Taken off in the same call that
# enters dev-manager, it is put back (so no removal is shown) and that is said.
jq '.groups["900"].allowFrom += ["555"] | .groups["903"] = {requireMention: true, allowFrom: ["111"]}' <<<"$ACC" > "$AD/access.json"
ac acc set allow:900-555 mode=dev-manager
[ "$ARC" = 3 ] && [ "$(sed 1d <<<"$AO")" = "    #903: + peerbot (555) may write to it there
    mode: none -> dev-manager: it gets a hosts ledger (this machine) and its monitor starts, which posts in #bot-health-check
warning: peerbot (555) is a peer dev bot (peers.json): entering dev-manager puts it back in #dev-bots" ] || { echo "FAIL: a peer taken off as the bot enters dev-manager is put back and said so, a known peer on one more channel is no widening: rc=$ARC $AO / $AE"; exit 1; }
# A peer taken off is warned of only when the bot stays a dev-manager: the mode after the call counts.
echo dev-manager > "$AD/mode"; ac acc set allow:900-555 mode=none; echo none > "$AD/mode"; printf '%s\n' "$A_FILE" > "$AD/access.json"
[ "$ARC" = 3 ] && grep -qx '    #dev-bots: - peerbot (555) may no longer write to it there' <<<"$AO" && ! grep -q 'peer dev bot' <<<"$AO" ||
  { echo "FAIL: a peer taken off by a call that also leaves dev-manager is no warning: rc=$ARC $AO / $AE"; exit 1; }
# At a terminal, all yes: setup --mode sets the mode, and access.json holds exactly what was shown, written once, under
# the lock: setup does not merge the peers again (a peer whose id is no id, which access never adds, would show it).
# access.log has a line for the write of access.json, made right after the rename (before setup --mode runs, so a
# setup that is stopped leaves the write logged), then one for the mode.
at 'y\n' acc set mode=dev-manager
[ "$ARC" = 0 ] && [ "$(<"$AD/mode")" = dev-manager ] && [ "$(grep -o '\[y/N\]' <<<"$AO" | wc -l)" = 1 ] && grep -q '^Apply 2 changes, 1 of them widening? \[y/N\]' <<<"$AO" &&
  grep -q "claude-discord: $AD/mode set to dev-manager$" <<<"$AO" && grep -q 'access.json written' <<<"$AO" &&
  grep -q 'the hooks follow the new mode from their next call; the dev-manager rules reach, or leave, a running session at its next start, compact or clear' <<<"$AO" &&
  [ "$(jq -c .groups "$AD/access.json")" = '{"900":{"requireMention":true,"allowFrom":["111","222","555"]},"901":{"requireMention":false,"allowFrom":[]}}' ] &&
  [ "$(tail -n 2 "$AD/access.log" | cut -d' ' -f4-)" = "access.json: mode=dev-manager
mode: none -> dev-manager" ] ||
  { echo "FAIL: mode=dev-manager at a terminal is asked about, set through setup --mode, logged, and access.json holds the peers shown and nothing setup added after: rc=$ARC $AO / $(cat "$AD/mode" "$AD/access.log") / $(jq -c .groups "$AD/access.json")"; exit 1; }
rm -f "$AD/hosts"; echo none > "$AD/mode"; printf '%s\n' "$A_FILE" > "$AD/access.json"
# Out of dev-manager with a ledger: setup deletes the ledger, which stops the monitor and its keeper. That is a
# widening; no keeps the ledger and the mode. The end of input (^D) at the question is no.
mkdir -p "$MR/dm1"; cp "$AD/access.json" "$AD/.env" "$MR/dm1/"; echo dev-manager > "$MR/dm1/mode"; printf 'local\nh9\n' > "$MR/dm1/hosts"
at '\004' dm1 set mode=none
[ "$ARC" = 4 ] && grep -qF "  ! mode: dev-manager -> none: its hosts ledger ($MR/dm1/hosts) is deleted and its monitor and keeper stop within a minute. Nobody is told in #bot-health-check when a bot of its hosts goes down" <<<"$AO" &&
  grep -q '^Apply this widening change? \[y/N\]' <<<"$AO" && [ "$(<"$MR/dm1/hosts")" = "$(printf 'local\nh9')" ] && [ "$(<"$MR/dm1/mode")" = dev-manager ] ||
  { echo "FAIL: leaving dev-manager says what stops, as a widening; the end of input is no and keeps the ledger: rc=$ARC $AO"; exit 1; }
# A mode alone changes no access.json: yes here runs setup --mode, which fails (this bot has no token: not set up).
rm -f "$MR/dm1/.env"; ai=$(stat -c %i "$MR/dm1/access.json")
at 'y\n' dm1 set mode=none
[ "$ARC" = 1 ] && grep -q "access: the mode was not changed (claude-discord setup dm1 --mode, above)$" <<<"$AO" && ! grep -q 'access.json written' <<<"$AO" &&
  [ "$(stat -c %i "$MR/dm1/access.json")" = "$ai" ] && [ "$(<"$MR/dm1/mode")" = dev-manager ] && [ -f "$MR/dm1/hosts" ] &&
  [ "$(cut -d' ' -f4- "$MR/dm1/access.log")" = "mode: dev-manager -> none failed (claude-discord setup dm1 --mode)" ] ||
  { echo "FAIL: a mode alone leaves access.json alone, and a setup --mode that fails is exit 1 and logged as failed: rc=$ARC $AO / $(cat "$MR/dm1/access.log" 2>&1)"; exit 1; }
rm -rf "$MR/dm1"
echo "ok: access set mode=<mode> asks, then runs setup --mode with the mode on its stdin (peers and hosts kept), leaving access.json alone for a mode alone; into dev-manager the peers it adds go in once, after all the words, are shown (a new one a widening) and are written under the lock, setup adding nothing after; out of it with a ledger it says the monitor stops, a widening, and no keeps both"
# access --host <alias>: the bot lives on a host of the manager's ledger. Over ssh as the monitor's pass goes (BatchMode,
# ConnectTimeout, the alias after --, the line's env words, a proxy word in both spellings; name= is no env word), and
# into the remote command go only hex digits (the project, the bot's name), the action and the change words, behind
# --version: a host before 1.13.0 prints its version line and does nothing else.
a_hex() { printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n'; }
printf "$HEAD$LOCAL"'h1 X=1 name=box https_proxy=http://q:1\nh2\n' > "$MR/mgr/hosts"; rm -f "$HOME/ssh.log"
A_REMOTE="-- h1 env X=1 HTTPS_PROXY=http://q:1 https_proxy=http://q:1 ~/.local/bin/claude-discord --version --access $(a_hex '/x y/한') 616363"
# The answer is the last line that starts as the document, whatever the host prints around it, and may be far longer
# than the 4096 bytes a probe's answer is cut at (a server with hundreds of channels).
A_DOC='{"access":1,"version":"1.13.0","bot":"acc","pad":"'$(printf 'a%.0s' {1..70000})'"}'
printf 'motd\n{"access":1,"bot":"decoy"}\n%s\nbye\n' "$A_DOC" > "$MON/h1.out"
ac --host h1 --manager mgr --project '/x y/한' acc --json
[ "$ARC" = 0 ] && [ "$AO" = "$A_DOC" ] && [ "$(<"$HOME/ssh.log")" = "-o BatchMode=yes -o ConnectTimeout=8 $A_REMOTE --json" ] ||
  { echo "FAIL: access --host --json asks the host once, capped, and prints the document it answered with: rc=$ARC ${AO:0:200} / $AE / $(cut -c1-400 "$HOME/ssh.log")"; exit 1; }
# A terminal here: the question is asked on the host, of this terminal (ssh -t), after its version was asked. The
# host's exit status is this command's.
printf 'claude-discord 1.13.0 (abc1234)\n' > "$MON/h1.out"; echo 4 > "$MON/h1.rc"; : > "$MON/h1.both"; rm -f "$HOME/ssh.log"
at '' --host h1 --manager mgr --project '/x y/한' acc set dm=pairing mention:900=off
[ "$ARC" = 4 ] && [ "$(command grep -v '^ATE' "$HOME/ssh.log")" = "-o BatchMode=yes -o ConnectTimeout=8 -- h1 ~/.local/bin/claude-discord --version
-t -o BatchMode=yes -o ConnectTimeout=8 $A_REMOTE set dm=pairing mention:900=off" ] ||
  { echo "FAIL: access --host set at a terminal asks the host's version, then runs the change there under ssh -t and exits as it did: rc=$ARC $AO / $(<"$HOME/ssh.log")"; exit 1; }
# ssh -t itself failing (255) is no answer from the host (exit 5), not the host's own status.
rm -f "$MON/h1.rc"; echo 255 > "$MON/h1.trc"
at '' --host h1 --manager mgr --project '/x y/한' acc set dm=pairing
[ "$ARC" = 5 ] && grep -q '^claude-discord: access: ssh to h1 failed (exit 255)' <<<"$AO" || { echo "FAIL: ssh -t failing is exit 5: rc=$ARC $AO"; exit 1; }
# With no terminal here the host prints the changes and refuses (exit 3): what it printed is another machine's text,
# passed on without its control characters.
rm -f "$MON/h1.trc"; printf 'claude-discord 1.13.0 (abc1234)\n  ! DMs: allowlist -> pairing\033[2J\n' > "$MON/h1.out"; echo 3 > "$MON/h1.rc"
ac --host h1 --manager mgr --project '/x y/한' acc set dm=pairing
[ "$ARC" = 3 ] && grep -qx '  ! DMs: allowlist -> pairing\[2J' <<<"$AO" || { echo "FAIL: what the host prints for a set with no terminal is passed on cleaned, with its exit status: rc=$ARC $(printf '%q' "$AO")"; exit 1; }
# A host that does not answer within the cap (the capped call's 142, as h_capped ends it; the hosts cases wait for a
# real one) is exit 5. --json is given 30 s: the connection, then the host's Discord calls (12 s, then 5 s at most).
echo 142 > "$MON/h1.rc"; rm -f "$MON/h1.both"
ac --host h1 --manager mgr --project '/x y/한' acc --json; : > "$MON/h1.both"
[ "$ARC" = 5 ] && [ "$AE" = "claude-discord: access: h1 gave no answer within 30s" ] || { echo "FAIL: a host that does not answer within the cap is exit 5, and --json is given 30 s: rc=$ARC $AE"; exit 1; }
# A set with no terminal here gets the same 30 s, after the version probe's 20 s: the host may write it, and asks Discord to post.
printf 'claude-discord 1.13.0 (abc1234)\n' > "$MON/h1.out"; rm -f "$MON/h1.rc"; echo 142 > "$MON/h1.arc"; : > "$MON/h1.both"
ac --host h1 --manager mgr --project '/x y/한' acc set dm=pairing
rm -f "$MON/h1.arc"
[ "$ARC" = 5 ] && [ "$AE" = "claude-discord: access: h1 gave no answer within 30s" ] || { echo "FAIL: a set with no terminal is given 30 s, as --json is: rc=$ARC $AE"; exit 1; }
# A 1.13.0 host that could not do it (no such bot there) prints no version line and says why: that is passed on (exit 1).
printf "motd: release notes of claude-discord 1.12.0 (old)\\nclaude-discord: access: no bot 'acc'\\007 set up in /x y/.claude/discord-agents (claude-discord setup <bot>)\\n\\n" > "$MON/h1.out"; echo 1 > "$MON/h1.rc"
ac --host h1 --manager mgr --project '/x y/한' acc --json
[ "$ARC" = 1 ] && [ -z "$AO" ] && [ "$AE" = "claude-discord: access: h1: no bot 'acc' set up in /x y/.claude/discord-agents (claude-discord setup <bot>)" ] ||
  { echo "FAIL: what a 1.13.0 host says when it cannot do it is passed on, without its control characters (exit 1): rc=$ARC $AO / $(printf '%q' "$AE")"; exit 1; }
# A host before 1.13.0 (it prints its version line whatever follows --version) is said to need the update (exit 5),
# and a change is never sent to it: an older wrapper would read `access` as a bot's name. An alias that is not in the
# ledger, or is no alias, is exit 2 and runs no ssh.
printf 'banner\nclaude-discord 1.12.0 (abc1234)\n' > "$MON/h2.out"; rm -f "$HOME/ssh.log"
ac --host h2 --manager mgr --project /p acc --json; A=$ARC$AE
ac --host h2 --manager mgr --project /p acc set dm=pairing
[ "$A" = "5claude-discord: access: h2 needs claude-discord 1.13.0 for this (it has 1.12.0; claude-discord update, there)" ] && [ "$ARC$AE" = "$A" ] && [ -z "$AO" ] &&
  [ "$(sed -n 2p "$HOME/ssh.log")" = "-o BatchMode=yes -o ConnectTimeout=8 -- h2 ~/.local/bin/claude-discord --version" ] && [ "$(wc -l < "$HOME/ssh.log")" = 2 ] ||
  { echo "FAIL: a host before 1.13.0 is exit 5 naming its version, and is sent no change: $A / rc=$ARC $AO $AE / $(<"$HOME/ssh.log")"; exit 1; }
rm -f "$HOME/ssh.log"
for bad in nope 'h1;id'; do
  ac --host "$bad" --manager mgr --project /p acc --json
  [ "$ARC" = 2 ] && [ ! -e "$HOME/ssh.log" ] && [[ $AE != *';id'* ]] || { echo "FAIL: --host '$bad' is not a host of the ledger: exit 2, no ssh: rc=$ARC $AE"; exit 1; }
done
ac --host h1 --manager mgr acc --json
[ "$ARC" = 2 ] && grep -q 'needs --project' <<<"$AE" && [ ! -e "$HOME/ssh.log" ] || { echo "FAIL: a remote bot is named with its project: rc=$ARC $AE"; exit 1; }
# The host's side: `--version --access <hex> <hex> ...` is `access --project <dir> -- <bot> ...` there; words that are
# not hex are exit 2 and print nothing (no version line either: the caller reads that as an older host).
: > "$CURL_REPLIES"
out=$(cd "$HOME" && bash "$S" --version --access "$(a_hex "$MP")" "$(a_hex acc)" --json) || :
jq -e --arg p "$(cd "$MP" && pwd -P)" '.access == 1 and .bot == "acc" and .project == $p and .policy.dm == "allowlist" and ([.channels[].read] | unique) == [null]
  and .errors == ["the server'"'"'s channels: HTTP 000", "the server'"'"'s roles: HTTP 000", "the bot'"'"'s roles: HTTP 000"]' <<<"$out" >/dev/null ||
  { echo "FAIL: --version --access decodes the project and the bot and runs access there; what Discord did not answer is in errors, and no channel's readability is guessed: $out"; exit 1; }
for bad in "zz 616363" "2f7 616363"; do
  rc=0; out=$(cd "$HOME" && bash "$S" --version --access $bad --json 2>&1) || rc=$?
  [ "$rc" = 2 ] && [ -z "$out" ] || { echo "FAIL: --version --access '$bad' is exit 2 with no output: rc=$rc $out"; exit 1; }
done
# --host local: here, with the env words of the ledger's local line (the monitor's Discord calls use the same). The bot
# is an administrator here (its role 71): it reads every channel, whatever the overwrites.
: > "$CURL_REPLIES"; queue_line "200 $A_CH"; queue_line "200 $A_G"; queue_line '200 {"user":{"id":"777"},"roles":["71"]}'; queue_line '403 {}'
rm -f "$HOME/curl.proxy"; ac --host local --manager mgr --project "$MP" acc --json
[ "$ARC" = 0 ] && jq -e '.bot == "acc" and [.channels[] | select(.kind != "unknown") | .read] == [true, true, true, true, true, true, true]' <<<"$AO" >/dev/null && [ "$(sort -u "$HOME/curl.proxy")" = "http://u:secretpw@127.0.0.1:8118|http://u:secretpw@127.0.0.1:8118" ] && [[ $AO$AE != *secretpw* ]] ||
  { echo "FAIL: --host local runs here with the local line's env words, and an administrator reads every channel: rc=$ARC $AO / $AE / $(cat "$HOME/curl.proxy" 2>&1)"; exit 1; }
echo "ok: access --host: over ssh as a pass goes (the ledger line's env words, the alias after --), only hex digits and change words in the remote command, behind --version; --json takes a document of any length from among what the host prints; set runs under ssh -t at a terminal, after the host's version was asked; a host before 1.13.0 is exit 5 and is sent no change, and what a 1.13.0 host could not do is passed on (a version inside a banner line is none); ssh -t failing and no answer within the cap are exit 5; what a host prints with no terminal here is passed on cleaned; local runs here with the local line's env"
# --- bot: a bot's token (1.14.0) -----------------------------------------------
# bt <token> <answer> <args>: `claude-discord bot <args>` on a pty (python3's), the token written only once the token
# prompt ends what it printed (its echo is off by then: a token written earlier would be echoed), the answer at its
# question; its output in BO (\r gone), its exit status in BRC, the terminal's echo after it ended in BECHO (on/off).
# "-" writes nothing there; one ending in "^C" types what is before it and a Ctrl-C. One driver serves every bt of the bot blocks (a python3 start each was
# 10 ms): it reads a job per line (NUL-separated: the output file, the cwd, the token, the answer, the command), runs it
# on a fresh pty, and answers "<status> <echo>".
cat > "$HOME/drive.py" <<'EOF'
import fcntl, os, select, signal, sys, termios
for line in sys.stdin.buffer:
    f = line.rstrip(b"\n").split(b"\0")[:-1]
    out, cwd, sends, qcmd, cmd = f[0], f[1], [[b"Token (hidden): ", f[2]], [b"[y/N] ", f[3]]], f[4], f[5:]
    m, s = os.openpty()
    pid = os.fork()
    if pid == 0:   # the child: its own session, the pty its controlling terminal (a Ctrl-C there is its SIGINT)
        os.setsid(); os.close(m); os.chdir(cwd); fcntl.ioctl(s, termios.TIOCSCTTY, 0)
        signal.signal(signal.SIGINT, signal.SIG_DFL)   # a background job's is ignored, and so would a script's be
        for fd in (0, 1, 2):
            os.dup2(s, fd)
        os.execvp(cmd[0], cmd)
    os.close(s)
    buf = b""
    while select.select([m], [], [], 5)[0]:
        try:
            d = os.read(m, 65536)
        except OSError:
            break
        buf += d
        for x in sends:
            if x[1] not in (b"", b"-") and buf.endswith(x[0]):
                if x[0] == b"[y/N] " and qcmd:   # a shell command run in cwd while the question is open, before its answer
                    os.chdir(cwd)
                    os.system(qcmd.decode() + " >/dev/null </dev/null")   # not on this driver's fifos (its stdin and stdout)
                os.write(m, x[1][:-2] + b"\x03" if x[1].endswith(b"^C") else x[1] + b"\n")
                x[1] = b""
    echo = "on" if termios.tcgetattr(m)[3] & termios.ECHO else "off"
    os.close(m)
    rc = os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1])
    with open(out, "wb") as o:
        o.write(buf)
    sys.stdout.write(f"{rc} {echo}\n")
    sys.stdout.flush()
EOF
mkfifo "$HOME/bt.in" "$HOME/bt.rc"; python3 -S "$HOME/drive.py" < "$HOME/bt.in" > "$HOME/bt.rc" & BT_PID=$!
exec {BT_IN}>"$HOME/bt.in" {BT_RC}<"$HOME/bt.rc"
bt() { printf '%s\0' "$HOME/bt.out" "$PWD" "$1" "$2" "" bash "$S" bot "${@:3}" >&"$BT_IN"; printf '\n' >&"$BT_IN"; read -r BRC BECHO <&"$BT_RC"; BO=$(<"$HOME/bt.out"); BO=${BO//$'\r'/}; }
# btq <token> <answer> <command> <args>: as bt, the command run (a shell line, in this directory) when the driver sees the
# question, before it answers it. btx <token> <answer> <args>: as bt, under xtrace from the environment (SHELLOPTS).
btq() { printf '%s\0' "$HOME/bt.out" "$PWD" "$1" "$2" "$3" bash "$S" bot "${@:4}" >&"$BT_IN"; printf '\n' >&"$BT_IN"; read -r BRC BECHO <&"$BT_RC"; BO=$(<"$HOME/bt.out"); BO=${BO//$'\r'/}; }
btx() { printf '%s\0' "$HOME/bt.out" "$PWD" "$1" "$2" "" env SHELLOPTS=xtrace bash "$S" bot "${@:3}" >&"$BT_IN"; printf '\n' >&"$BT_IN"; read -r BRC BECHO <&"$BT_RC"; BO=$(<"$HOME/bt.out"); BO=${BO//$'\r'/}; }
TOK_NEW=tokNewAAAAbbbbCCCCdddd.eeeeFFFF_gggg-hh TOK_ME='{"id":"777","bot":true,"username":"acc"}'
# No terminal: nothing is read and Discord is not asked (exit 3).
: > "$CURL_LOG"; rc=0; out=$(printf '%s\n' "$TOK_NEW" | bash "$S" bot acc token 2>&1) || rc=$?
[ "$rc" = 3 ] && grep -q 'reads the token from a terminal and asks there' <<<"$out" && [ ! -s "$CURL_LOG" ] && [ "$(<"$AD/.env")" = DISCORD_BOT_TOKEN=tokAccUnique ] ||
  { echo "FAIL: bot token with no terminal reads nothing, asks Discord nothing and changes nothing (exit 3): rc=$rc $out"; exit 1; }
# A token of another bot (its id is not the one kept in bot-id) is refused; so is one Discord refuses. Neither is echoed.
: > "$CURL_REPLIES"; queue_line '200 {"id":"888","bot":true,"username":"other"}'; queue_line '401 {"message":"401: Unauthorized"}'
bt "$TOK_NEW" - acc token; A=$BRC$BO; bt "$TOK_NEW" - acc token
[[ $A == 1*"that token is the bot other (888), not acc (777): a token of another bot is refused"* ]] && [ "$BRC" = 1 ] &&
  grep -q 'Discord refused the token (HTTP 401): copy it again' <<<"$BO" && [[ $A$BO != *"$TOK_NEW"* ]] && [ "$(<"$AD/.env")" = DISCORD_BOT_TOKEN=tokAccUnique ] ||
  { echo "FAIL: a token of another bot, and one Discord refuses, change nothing (exit 1) and are never shown: $A / rc=$BRC $BO"; exit 1; }
# What was typed outside a token's characters (here a space and a quote) is no token: exit 2, Discord not asked, not shown.
: > "$CURL_LOG"; bt "tokBadAAAA bbbbCCCC'dddd" - acc token
[ "$BRC" = 2 ] && grep -q 'what was typed is no bot token' <<<"$BO" && [ ! -s "$CURL_LOG" ] && [[ $BO != *tokBad* ]] &&
  [ "$(<"$AD/.env")" = DISCORD_BOT_TOKEN=tokAccUnique ] ||
  { echo "FAIL: what was typed outside a token's characters is refused (exit 2) before Discord is asked, and never shown: rc=$BRC $BO"; exit 1; }
# With no bot-id kept, the bot's id is the one Discord gives for the token in .env now: a token of another bot with this
# bot's username is refused (two calls: the new token, then the current one). With the current one refused too (a reset
# token), the new token must be of no bot set up on this machine (here mgr, by its bot-id); else its id is shown in red as
# unchecked before the one question, and y writes it and its bot-id: the rename that needed a working token works then.
mv "$AD/bot-id" "$HOME/acc.id"; printf '888\n' > "$MR/mgr/bot-id"
: > "$CURL_REPLIES"; queue_line '200 {"id":"888","bot":true,"username":"acc"}'; queue_line "200 $TOK_ME"
queue_line '200 {"id":"888","bot":true,"username":"mgrx"}'; queue_line '401 {"message":"401: Unauthorized"}'
bt "$TOK_NEW" - acc token; A=$BRC$BO; bt "$TOK_NEW" - acc token; A2=$BRC$BO$(<"$AD/.env")
rm -f "$MR/mgr/bot-id"; : > "$CURL_REPLIES"
queue_line '200 {"id":"7771","bot":true,"username":"accX"}'; queue_line '401 {"message":"401: Unauthorized"}'; queue_line '200 {"id":"7771","bot":true,"username":"accX"}'
bt "$TOK_NEW" y acc token; rc=0; out=$(bash "$S" bot acc rename accX </dev/null 2>&1) || rc=$?
[[ $A == 1*"that token is the bot acc (888), not acc (777)"* ]] && [[ $A2 == 1*"that token is of the bot mgrx (888), set up in $MR/mgr already"*"DISCORD_BOT_TOKEN=tokAccUnique" ]] &&
  [ "$BRC" = 0 ] && [[ $BO == *$'\n\033[1;31m  ! this bot\'s id could not be checked: 7771 (accX)\033[0m\n'*"Replace the token? [y/N] y"* ]] &&
  [ "$(<"$AD/.env")" = "DISCORD_BOT_TOKEN=$TOK_NEW" ] && [ "$(<"$AD/bot-id")" = 7771 ] &&
  [ "$rc" = 3 ] && grep -qx '    Discord: it is accX there already: Discord is not asked to change it' <<<"$out" && [[ $A$A2$BO$out != *"$TOK_NEW"* ]] ||
  { echo "FAIL: with no bot-id, a token is checked against the id of the token in .env; with that one refused, a bot set up here is refused and any other is written after a red unchecked line (bot-id written, a rename works then): $A / $A2 / rc=$BRC $BO / rc=$rc $out"; exit 1; }
printf 'DISCORD_BOT_TOKEN=tokAccUnique\n' > "$AD/.env"; mv "$HOME/acc.id" "$AD/bot-id"
# Ctrl-C at the hidden prompt: exit 130, the terminal's echo on again, what was typed never shown, Discord not asked. A
# token of a user (no bot) is refused.
: > "$CURL_LOG"; bt "tokTyped^C" - acc token; A="$BRC $BECHO $BO"; : > "$CURL_REPLIES"; queue_line '200 {"id":"5","bot":false,"username":"human"}'; bt "$TOK_NEW" - acc token
[[ $A == "130 on "* ]] && [[ $A != *tokTyped* ]] && [ "$BRC" = 1 ] && grep -q "that token is no bot's (Discord says it is a user's); nothing was changed" <<<"$BO" &&
  [ "$(wc -l < "$CURL_LOG")" = 1 ] && [ "$(<"$AD/.env")" = DISCORD_BOT_TOKEN=tokAccUnique ] ||
  { echo "FAIL: Ctrl-C at the token prompt is exit 130 with the echo back on and nothing shown; a user's token is refused: $A / rc=$BRC $BO"; exit 1; }
# The same bot, y: .env is replaced by rename (another inode), mode 600, its other lines kept; access.log says so, with
# no token; the token went to curl on its stdin, never into an argument or anything printed.
printf 'DISCORD_BOT_TOKEN=tokAccUnique\nKEEP=1\n' > "$AD/.env"; chmod 644 "$AD/.env"; ei=$(stat -c %i "$AD/.env")
: > "$CURL_LOG"; : > "$CURL_STDIN_LOG"; : > "$CURL_REPLIES"; queue_line "200 $TOK_ME"
bt "$TOK_NEW"$'\x16\r' y acc token   # ^V CR: a CR typed after it (a Windows paste), which is no part of it
MK=$(printf '\342\201\240')
[ "$BRC" = 0 ] && [ "$(printf '%s\n' "$BO" | grep -v '^$')" = "$MK
Token (hidden): 
claude-discord: bot: acc on $(uname -n | cut -d. -f1), $AD/.env
    its token is replaced by this one, of acc (777); the old one is not kept
    a running session of acc logs in with it within 10 s (one started before claude-discord 1.14.0: claude-discord refresh acc --force)
$MK
Replace the token? [y/N] y
claude-discord: bot: $AD/.env written. A running session of acc logs in with it within 10 s." ] &&
  [ "$(<"$AD/.env")" = "DISCORD_BOT_TOKEN=$TOK_NEW
KEEP=1" ] && [ "$(stat -c %a "$AD/.env")" = 600 ] && [ "$(stat -c %i "$AD/.env")" != "$ei" ] &&
  [[ $(tail -n 1 "$AD/access.log") =~ ^20[0-9-]{8}T[0-9:]{8}Z\ $(id -un)\ [^\ ]+\ token:\ replaced\ \(bot\ 777\)$ ]] &&
  [ "$(<"$CURL_STDIN_LOG")" = "Authorization: Bot $TOK_NEW" ] && [ "$(<"$CURL_LOG")" = "-s --max-time 10 -w \n%{http_code} -X GET -H @- https://discord.com/api/v10/users/@me" ] &&
  [ "$(cut -d' ' -f2- "$AD/discord-name")" = acc ] &&
  [[ $BO$(<"$AD/access.log") != *"$TOK_NEW"* ]] ||
  { echo "FAIL: bot token at a terminal, y: .env replaced by rename, mode 600, its other lines kept, a line in access.log, the token on curl's stdin only and never printed: rc=$BRC $BO / $(cat "$AD/.env" "$AD/access.log" "$CURL_LOG" 2>&1)"; exit 1; }
printf 'DISCORD_BOT_TOKEN=tokAccUnique\n' > "$AD/.env"
# The same under xtrace from the environment (SHELLOPTS=xtrace, as a `bash -x` or a debugging shell's transcript would
# have it): the trace runs up to the bot verb, which turns it off before the token is read, so no trace line (`+ `)
# follows the hidden prompt and the token is in none (M6b of the 1.14.0 review).
: > "$CURL_REPLIES"; queue_line "200 $TOK_ME"
btx "$TOK_NEW" y acc token
[ "$BRC" = 0 ] && [[ $BO == *$'\n+ '* ]] && [[ ${BO#*"Token (hidden): "} != *$'\n+ '* ]] && [[ $BO != *"$TOK_NEW"* ]] && [ "$(<"$AD/.env")" = "DISCORD_BOT_TOKEN=$TOK_NEW" ] ||
  { echo "FAIL: bot under xtrace (SHELLOPTS=xtrace) traces nothing from the token prompt on, so the token is in no trace line: rc=$BRC, $(grep -c '^+ ' <<<"$BO") trace lines, $(grep -c -F "$TOK_NEW" <<<"$BO") with the token, $(grep -c '^+ ' <<<"${BO#*"Token (hidden): "}") after the prompt"; exit 1; }
printf 'DISCORD_BOT_TOKEN=tokAccUnique\n' > "$AD/.env"
# Under xtrace again, rename: it reads .env's token itself, with no prompt, before Discord is asked (a refusal queued:
# .env's token is some other bot's). The trace stops where the verb starts, so no trace line holds that token either.
: > "$CURL_REPLIES"; queue_line '200 {"id":"888","bot":true,"username":"other"}'
btx - - acc rename acc2
[ "$BRC" = 1 ] && grep -q "holds the token of the bot other (888), not acc's (777)" <<<"$BO" && [[ $BO == *$'\n+ '* ]] && [[ $BO != *tokAccUnique* ]] && [ "$(grep -c '^+ ' <<<"${BO#*claude-discord: bot:}")" = 0 ] ||
  { echo "FAIL: bot rename under xtrace (SHELLOPTS=xtrace) traces nothing of the verb, so .env's token is in no trace line: rc=$BRC, $(grep -c '^+ ' <<<"$BO") trace lines, $(grep -c tokAccUnique <<<"$BO") with the token, $(grep -c '^+ ' <<<"${BO#*claude-discord: bot:}") after the refusal"; exit 1; }
# --host: no terminal here, no ssh at all (exit 3); a host before 1.14.0 is exit 5 and is sent nothing but --version;
# a 1.14.0 host gets the call under ssh -t, the project and the bot's name in hex, so the token goes to its terminal
# (ssh's stdin) and never into the command. The host's side decodes --version --bot as --version --access.
rm -f "$HOME/ssh.log" "$MON"/h1.* "$MON"/h2.*; rc=0; out=$(bash "$S" bot --host h1 --manager mgr --project /p acc token </dev/null 2>&1) || rc=$?; A=$rc
printf 'claude-discord 1.13.1 (abc1234)\n' > "$MON/h2.out"; printf 'claude-discord 1.14.0 (abc1234)\n' > "$MON/h1.out"
bt "$TOK_NEW" - --host h2 --manager mgr --project /p acc token; A="$A $BRC"; bt "$TOK_NEW" - --host h1 --manager mgr --project '/x y' acc token
rc=0; out=$(cd "$HOME" && bash "$S" --version --bot "$(a_hex "$MP")" "$(a_hex acc)" token </dev/null 2>&1) || rc=$?
[ "$A $BRC $rc" = "3 5 0 3" ] && grep -q 'reads the token from a terminal' <<<"$out" && [ "$(command grep -v '^ATE' "$HOME/ssh.log")" = "-o BatchMode=yes -o ConnectTimeout=8 -- h2 ~/.local/bin/claude-discord --version
-o BatchMode=yes -o ConnectTimeout=8 -- h1 ~/.local/bin/claude-discord --version
-t -o BatchMode=yes -o ConnectTimeout=8 -- h1 env X=1 HTTPS_PROXY=http://q:1 https_proxy=http://q:1 ~/.local/bin/claude-discord --version --bot $(a_hex '/x y') 616363 token" ] &&
  [[ $(<"$HOME/ssh.log") != *"$TOK_NEW"* ]] || { echo "FAIL: bot --host token: no terminal is exit 3 with no ssh, a host before 1.14.0 exit 5 sent only --version, a 1.14.0 host gets it under ssh -t in hex; the host decodes --version --bot: $A $BRC $rc $out / $(cat "$HOME/ssh.log" 2>&1)"; exit 1; }
rm -f "$HOME/ssh.log" "$MON"/h1.* "$MON"/h2.*
echo "ok: bot token: read from the terminal with its echo off, only there (no terminal: exit 3, nothing read); Discord asked who it is with it on curl's stdin; a token of another bot or one Discord refuses changes nothing; y replaces .env by rename, mode 600, its other lines kept, and logs the fact; the token is never printed; --host runs it on the bot's host under ssh -t (a host before 1.14.0: exit 5)"
# bot rename: a name that is none, a name taken, a reserved one, one of another bot of this machine but for its case
# (this project's mgr, another project's b1ok), and a session renaming its own bot are refused before Discord is asked
# (exit 2, exit 1). A manager's name with a backend in another project is no refusal since 1.18.1 (records are keyed by
# the project).
: > "$CURL_LOG"; A=""; MB2=$HOME/.claude-discord/records/monitor/$(skey "$MP"); echo dev-manager > "$AD/mode"; printf 'local\n' > "$AD/hosts"
for w in "acc rename a.b" "acc rename mgr" "acc rename hosts" "acc rename add" "acc rename hooks" "acc rename -ab" "acc rename MGR" "acc rename B1OK"; do BRC=0; bash "$S" bot $w </dev/null >/dev/null 2>&1 || BRC=$?; A="$A$BRC "; done
BRC=0; BO=$(DISCORD_STATE_DIR=$AD bash "$S" bot acc rename acc2 2>&1) || BRC=$?
echo none > "$AD/mode"; rm -rf "$AD/hosts"
[ "$A$BRC" = "2 1 2 2 2 2 1 1 2" ] && grep -q 'a session cannot rename its own bot' <<<"$BO" && [ ! -s "$CURL_LOG" ] ||
  { echo "FAIL: bot rename refuses a name that is none, one taken, a reserved one and its own session's bot before asking Discord: $A$BRC $BO"; exit 1; }
# No terminal: what it would do is printed, nothing is done (exit 3). Discord refusing the name (it allows about two
# changes an hour) changes nothing here.
printf '{"peers":[{"name":"peerbot","bot_id":"555","owner_id":"1","machine":"m"},{"name":"acc","bot_id":"777","owner_id":"1","machine":"m"}]}\n' > "$(pstate "$MP")/peers.json"
# Refused after Discord says who the token in .env is: one of another bot (not the bot-id's), and a name a peer of
# peers.json has (the bot would skip that peer as itself).
: > "$CURL_REPLIES"; queue_line '200 {"id":"888","bot":true,"username":"other"}'; queue_line "200 $TOK_ME"; A=""
for w in acc2 peerbot; do BRC=0; BO=$(bash "$S" bot acc rename $w </dev/null 2>&1) || BRC=$?; A="$A$BRC $BO / "; done
[[ $A == "1 claude-discord: bot: $AD/.env holds the token of the bot other (888), not acc's (777)"*" / 1 claude-discord: bot: the peer peerbot (555) in $(pstate "$MP")/peers.json has that name"* ]] &&
  [ -d "$AD" ] || { echo "FAIL: bot rename refuses a .env token of another bot and a peer's name: $A"; exit 1; }
: > "$CURL_REPLIES"; queue_line "200 $TOK_ME"; queue_line "200 $TOK_ME"
queue_line '400 {"message":"Invalid Form Body","code":50035,"errors":{"username":{"_errors":[{"code":"USERNAME_RATE_LIMIT","message":"You are changing your username too fast."}]}}}'
rc=0; out=$(bash "$S" bot acc rename acc2 2>&1 </dev/null) || rc=$?; bt - y acc rename acc2
[ "$rc" = 3 ] && grep -qx '    Discord: acc -> acc2 (about 2 changes an hour are allowed: if Discord refuses, nothing here is changed)' <<<"$out" &&
  grep -qx '    it is not running: renamed only (claude-discord --bg --name acc2 starts it)' <<<"$out" &&
  [ "$BRC" = 1 ] && grep -q "Discord refused the new name (HTTP 400: You are changing your username too fast.: Invalid Form Body); nothing was changed$" <<<"$BO" &&
  [ -d "$AD" ] && [ ! -e "$MR/acc2" ] || { echo "FAIL: bot rename with no terminal prints what it would do (exit 3), and a name Discord refuses changes nothing (exit 1): rc=$rc $out / rc=$BRC $BO"; exit 1; }
# A running bot, y: Discord first (PATCH, the token on curl's stdin), then the session stopped, the directory renamed,
# its line in peers.json (by its id) and its scratch directory with it, and the session started again under the new
# name from its handoff (the suite's launcher stub prints the start).
sleep 300 & OLD=$!; echo "$OLD" > "$HOME/old.pid"; cp "$HOME/bin/claude" "$HOME/claude.keep"; rm -f "$HOME/claude.calls"
cat > "$HOME/claude.live" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  agents) echo '[{"id":"acc11111","pid":'"$(<"$HOME/old.pid")"',"name":"acc","cwd":"'"$PWD"'","sessionId":"0123abcd-1111-2222-3333-444444444444"}'"$([ ! -e "$HOME/old2.pid" ] || echo ',{"id":"acc22222","pid":'"$(<"$HOME/old2.pid")"',"name":"acc","cwd":"'"$PWD"'"}')"',{"id":"0e1a2222","pid":45,"name":"acc","cwd":"/elsewhere"}]';;
  stop) echo "STOP $2" >> "$HOME/claude.calls"; case $2 in acc22222) kill "$(<"$HOME/old2.pid")";; *) [ -e "$HOME/stop.fails" ] || kill "$(<"$HOME/old.pid")";; esac;;
  respawn) echo "RESPAWN $2" >> "$HOME/claude.calls"; [ ! -e "$HOME/respawn.fails" ] || exit 7;;
  *) printf 'PLAIN %s\n' "$(printf '%s ' "$@" | tr '\n' ' ')" >> "$HOME/claude.calls";;
esac
STUB
SCR2=$HOME/.claude-discord/scratch/$(skey "$MP")   # a bot's scratch, keyed by the project (1.18.1)
chmod +x "$HOME/claude.live"; cp "$HOME/claude.live" "$HOME/bin/claude"; printf 'HANDOFF_ACC\n' > "$AD/handoff.md"; mkdir -p "$SCR2/acc"
# It runs, and its workspace is not trusted (a start would be refused): refused before anything is stopped. One of its
# two sessions does not stop (a stop that fails, here a session that outlives `claude stop`): nothing here is renamed
# and nothing is started (two sessions on one token both answer), what Discord was told is said, and so is the session
# that did stop, with the command that starts one (M2 of the 1.14.0 review). The 10 s wait for it is skipped.
cp "$HOME/.claude.json" "$HOME/cj.keep"; jq --arg p "$(pwd -P)" '.projects[$p].hasTrustDialogAccepted = false' "$HOME/cj.keep" > "$HOME/.claude.json"
: > "$CURL_REPLIES"; queue_line "200 $TOK_ME"; rc=0; out=$(bash "$S" bot acc rename acc2 </dev/null 2>&1) || rc=$?; cp "$HOME/cj.keep" "$HOME/.claude.json"
sleep 300 & OLD2=$!; echo "$OLD2" > "$HOME/old2.pid"
cp "$HOME/bin/sleep" "$HOME/sleep.keep"; printf '#!/bin/sh\n' > "$HOME/bin/sleep"; : > "$HOME/stop.fails"
queue_line "200 $TOK_ME"; queue_line '200 {"id":"777","bot":true,"username":"acc3"}'
bt - y acc rename acc3; cp "$HOME/sleep.keep" "$HOME/bin/sleep"; rm -f "$HOME/stop.fails" "$HOME/old2.pid"
[ "$rc" = 1 ] && grep -q "is not a trusted workspace, so acc would not start again after the rename" <<<"$out" &&
  [ "$BRC" = 1 ] && grep -q "acc still runs after stop (pid $OLD): nothing here was renamed (Discord calls it acc3 now: run this again to rename it here). Stop it by hand first; stopped and not started again: acc22222 (claude-discord --bg --name acc starts one)" <<<"$BO" &&
  [[ $BO != *LAUNCHER* ]] && [[ $BO != *"renamed: acc -> acc3"* ]] && [ -d "$AD" ] && [ ! -e "$MR/acc3" ] && kill -0 "$OLD" && ! kill -0 "$OLD2" 2>/dev/null && [ "$(<"$HOME/claude.calls")" = $'STOP acc11111\nSTOP acc22222' ] ||
  { echo "FAIL: bot rename of a running bot refuses an untrusted workspace before it stops anything, and a stop that fails renames and starts nothing and names the session that did stop: rc=$rc $out / rc=$BRC $BO / $(cat "$HOME/claude.calls" 2>&1)"; exit 1; }
rm -f "$HOME/claude.calls"
: > "$CURL_LOG"; : > "$CURL_STDIN_LOG"; : > "$CURL_REPLIES"; queue_line "200 $TOK_ME"; queue_line '200 {"id":"777","bot":true,"username":"acc2"}'
bt - y acc rename acc2
[ "$BRC" = 0 ] && grep -qx '    it runs (1 session): stopped, renamed, started again as acc2 from its handoff.md' <<<"$BO" &&
  grep -qx "claude-discord: bot: renamed: $MR/acc2 (and on Discord)" <<<"$BO" && grep -qx '    its session runs again as acc2' <<<"$BO" && [ "${BO##*$'\n'}" = "renamed: acc -> acc2" ] &&
  [ ! -e "$AD" ] && [ -f "$MR/acc2/.env" ] && [ -d "$SCR2/acc2" ] && ! kill -0 "$OLD" 2>/dev/null &&
  [ "$(jq -c '[.peers[] | [.name, .bot_id]]' "$(pstate "$MP")/peers.json")" = '[["peerbot","555"],["acc2","777"]]' ] &&
  [ "$(sed -n '2s/ .*//p' "$CURL_LOG")" = "-s" ] && grep -q -- "-X PATCH -H @- -H Content-Type: application/json --data-binary {\"username\":\"acc2\"} https://discord.com/api/v10/users/@me$" "$CURL_LOG" &&
  [ "$(sort -u "$CURL_STDIN_LOG")" = "Authorization: Bot tokAccUnique" ] && [ "$(<"$HOME/claude.calls")" = "STOP acc11111" ] &&
  [[ $BO == *"stopping acc (acc11111, pid $OLD)"$'\n'"LAUNCHER "*" -n acc2 --append-system-prompt "*HANDOFF_ACC*" --bg Catch up on the channel and continue from your handoff."$'\n'* ]] &&
  [ "$(tail -n 2 "$MR/acc2/access.log" | cut -d' ' -f4-)" = "rename: on Discord acc -> acc2
rename: acc -> acc2" ] || { echo "FAIL: bot rename of a running bot, y: Discord first, then the session stopped, the directory, its peers.json line by id and its scratch directory renamed, the session started again as the new name from its handoff: rc=$BRC $BO / $(cat "$HOME/claude.calls" "$CURL_LOG" "$(pstate "$MP")/peers.json" 2>&1)"; exit 1; }
# A step after the directory moved fails (here the start under the new name): exit 1, what failed said, and the last line
# still names the move, which a program follows (the TUI, after a manager's rename). Its handoff.md went with the start
# above, so the plan says what a start with none means (M1). A scratch directory of the new name is there already: the
# bot's stays, said (M3).
sleep 300 & OLD=$!; echo "$OLD" > "$HOME/old.pid"; sed 's/"name":"acc"/"name":"acc2"/' "$HOME/claude.live" > "$HOME/bin/claude"; : > "$HOME/launch.fails"
: > "$CURL_REPLIES"; queue_line '200 {"id":"777","bot":true,"username":"acc2"}'; queue_line '200 {"id":"777","bot":true,"username":"acc4"}'
mkdir -p "$SCR2/acc4"
bt - y acc2 rename acc4; rm -f "$HOME/launch.fails"
[ "$BRC" = 1 ] && grep -qx '    acc4 did not start (above): claude-discord --bg --name acc4' <<<"$BO" && [ "${BO##*$'\n'}" = "renamed: acc2 -> acc4" ] && [ -d "$MR/acc4" ] &&
  grep -qx '    it runs (1 session): stopped, renamed, started again as acc4 with no handoff.md: an empty context that catches up from the channel (its conversation is not carried over)' <<<"$BO" &&
  grep -qx "    its scratch directory stays $SCR2/acc2: $SCR2/acc4 is there already" <<<"$BO" && [ -d "$SCR2/acc2" ] ||
  { echo "FAIL: bot rename whose start fails after the directory moved is exit 1 and still ends with the renamed line; its plan says a session with no handoff starts empty; a scratch directory of the new name already there keeps the bot's, said: rc=$BRC $BO"; exit 1; }
mv "$MR/acc4" "$MR/acc2"; rm -rf "$SCR2/acc4" "$HOME/claude.calls"
cp "$HOME/claude.keep" "$HOME/bin/claude"
# A manager whose name Discord has already (the TUI's `=`), here only its case: Discord is not asked to change it; its
# directory and its backend's state move (through a temporary name, so a case-insensitive file system renames them too)
# and name the new manager, stopped as its owner left it, and its watcher record on each ledger host is renamed.
MB2=$HOME/.claude-discord/records/monitor/$(skey "$MP"); mkdir -p "$MB2/acc2"; : > "$MB2/acc2/stopped"; printf '{"version":1,"manager":"acc2","bots":{}}\n' > "$MB2/acc2/state.json"
echo dev-manager > "$MR/acc2/mode"; printf '# ledger\nlocal\nh1 X=1\n' > "$MR/acc2/hosts"; read -r HID < "$HOME/.claude-discord/host-id"
: > "$MON/h1.out"; rm -f "$MON/h1.rc" "$HOME/ssh.log"; : > "$CURL_LOG"; : > "$CURL_REPLIES"; queue_line '200 {"id":"777","bot":true,"username":"ACC2"}'
bt - y acc2 rename ACC2
[ "$BRC" = 0 ] && grep -qx '    Discord: it is ACC2 there already: Discord is not asked to change it' <<<"$BO" && [ "$(wc -l < "$CURL_LOG")" = 1 ] &&
  [ -d "$MR/ACC2" ] && [ ! -e "$MR/acc2" ] && [ ! -e "$MB2/acc2" ] && [ -e "$MB2/ACC2/stopped" ] && [ "$(jq -r .manager "$MB2/ACC2/state.json")" = ACC2 ] &&
  grep -q 'its backend stays stopped, as you left it: claude-discord monitor --start ACC2' <<<"$BO" && [ -z "$(find "$MR" "$MB2" -name '.*.cd.*')" ] &&
  [ "${BO##*$'\n'}" = "renamed: acc2 -> ACC2" ] &&
  [ "$(cut -d' ' -f5- "$HOME/ssh.log")" = "-- h1 ~/.local/bin/claude-discord --version --watch ACC2 $HID h1
-- h1 ~/.local/bin/claude-discord --version --unwatch acc2 $HID" ] ||
  { echo "FAIL: bot rename of a manager to the name Discord has: no PATCH, its backend's records moved and renamed, stopped as left, its watcher records renamed: rc=$BRC $BO / $(cat "$HOME/ssh.log" "$CURL_LOG" 2>&1) / $(ls "$MB2")"; exit 1; }
# What a TUI still on the old name runs (its periodic --ensure, its Q's --stop) makes no record for that name again.
bash "$S" monitor --ensure acc2 --holder tui $$ >/dev/null 2>&1 || :; bash "$S" monitor --stop acc2 >/dev/null 2>&1 || :
[ ! -e "$MB2/acc2" ] || { echo "FAIL: monitor --ensure and --stop of a name whose bot directory and records moved away make no records/monitor for it: $(ls -R "$MB2/acc2")"; exit 1; }
mv "$MR/ACC2" "$AD"; echo none > "$AD/mode"; rm -rf "$AD/hosts" "$AD/handoff.md" "$AD/handoff.prev.md" "$MB2/ACC2" "$SCR2/acc2" "$HOME/ssh.log" "$HOME/claude.calls"
# The directory's rename(2) fails (the project's directory unwritable here): what was stopped runs again, and a manager's
# stopped marker its owner left stays. On a case-insensitive file system ACC and acc are one directory (a symlink here):
# the marker under the new name is then the owner's, and the rename made none to take back.
echo dev-manager > "$AD/mode"; printf '# ledger\nlocal\n' > "$AD/hosts"; mkdir -p "$MB2/acc"; : > "$MB2/acc/stopped"; ln -s acc "$MB2/ACC"
sleep 300 & OLD=$!; echo "$OLD" > "$HOME/old.pid"; cp "$HOME/claude.live" "$HOME/bin/claude"
: > "$CURL_REPLIES"; queue_line '200 {"id":"777","bot":true,"username":"ACC"}'; chmod 555 "$MR"
bt - y acc rename ACC; chmod 755 "$MR"
[ "$BRC" = 1 ] && grep -q "could not rename $AD: nothing here was renamed" <<<"$BO" && [ -d "$AD" ] && [ ! -e "$MR/ACC" ] && [ -e "$MB2/acc/stopped" ] &&
  [[ $BO == *"stopping acc (acc11111, pid $OLD)"$'\n'*"LAUNCHER "*" -n acc "* ]] && [ "$(<"$HOME/claude.calls")" = "STOP acc11111" ] ||
  { echo "FAIL: a failed rename(2) of the directory starts the stopped session again and keeps the owner's stopped marker: rc=$BRC $BO / $(ls -a "$MB2/acc" 2>&1)"; exit 1; }
cp "$HOME/claude.keep" "$HOME/bin/claude"; echo none > "$AD/mode"; rm -rf "$AD/hosts" "$MB2/acc" "$MB2/ACC" "$HOME/claude.calls"
# --host with no terminal here: the host prints what it would do and refuses (exit 3), passed on; the new name travels
# as it is (a name is plain), the bot's in hex.
printf 'claude-discord 1.14.0 (abc1234)\n    Discord: acc -> acc2\033[2J\n' > "$MON/h1.out"; echo 3 > "$MON/h1.rc"; : > "$MON/h1.both"
rc=0; out=$(bash "$S" bot --host h1 --manager mgr --project /p acc rename acc2 2>&1 </dev/null) || rc=$?
[ "$rc" = 3 ] && grep -qx '    Discord: acc -> acc2\[2J' <<<"$out" && [ "$(tail -n 1 "$HOME/ssh.log")" = "-o BatchMode=yes -o ConnectTimeout=8 -- h1 env X=1 HTTPS_PROXY=http://q:1 https_proxy=http://q:1 ~/.local/bin/claude-discord --version --bot 2f70 616363 rename acc2" ] ||
  { echo "FAIL: bot --host rename with no terminal is passed on from the host cleaned, exit 3: rc=$rc $out / $(cat "$HOME/ssh.log")"; exit 1; }
rm -f "$HOME/ssh.log" "$MON"/h1.*
echo "ok: bot rename: a name that is none, taken or reserved, and a session's own bot, refused before Discord is asked; no terminal prints what it would do; Discord first (a refusal changes nothing here), then a running session stopped, the directory, its peers.json line (by id) and scratch directory renamed, the session started again from its handoff; a manager's backend records move and name it, and its watcher records on its ledger hosts are renamed; a name Discord has already is not asked of it; --host passes on what the host printed"
# bot recover [--fresh] (1.16.0, the TUI's f and F): a bad word, and a session recovering its own bot, are refused (exit 2)
# before `claude agents` is asked, and nothing runs. The stub's listing is the rename block's (acc11111 of acc here, with
# a sessionId for the plugin-sessions case below; 0e1a2222 of /elsewhere); its respawn is logged and fails on demand.
cp "$HOME/claude.live" "$HOME/bin/claude"; rm -f "$HOME/claude.calls" "$AD/recover.log"; sleep 300 & OLD=$!; echo "$OLD" > "$HOME/old.pid"
printf 'acc11111\n' > "$AD/pinned-job"
rc=0; out=$(bash "$S" bot acc recover --x </dev/null 2>&1) || rc=$?; A=$rc; BRC=0; bash "$S" bot acc recover x </dev/null >/dev/null 2>&1 || BRC=$?; A="$A $BRC"
BRC=0; BO=$(DISCORD_STATE_DIR=$AD bash "$S" bot acc recover 2>&1) || BRC=$?
[ "$A $BRC" = "2 2 2" ] && grep -q 'recover \[--fresh\]' <<<"$out" && grep -q 'a session cannot recover its own bot' <<<"$BO" && [ ! -e "$HOME/claude.calls" ] ||
  { echo "FAIL: bot recover refuses a bad flag and its own session (exit 2) and runs nothing: $A $BRC $out / $BO"; exit 1; }
# No terminal: the plan is printed (its pinned job is listed: a respawn), nothing is run or logged (exit 3).
rc=0; out=$(bash "$S" bot acc recover </dev/null 2>&1) || rc=$?
[ "$rc" = 3 ] && grep -q 'its last session acc11111 (pinned-job) is listed by claude agents' <<<"$out" && grep -q '^    run: claude respawn acc11111' <<<"$out" &&
  [ ! -e "$HOME/claude.calls" ] && [ ! -e "$AD/recover.log" ] || { echo "FAIL: bot recover with no terminal prints its plan (exit 3) and runs nothing: rc=$rc $out"; exit 1; }
# --yes (1.19.0, what boot and the monitor run): the plan, then the command with no terminal and no question, logged as
# `recover --yes`; a bad word beside it still exit 2.
[ ! -e "$AD/auto-start" ] || { echo "FAIL: a recover that only printed its plan (no --yes, no terminal) must not touch auto-start"; exit 1; }
rc=0; out=$(bash "$S" bot acc recover --yes </dev/null 2>&1) || rc=$?; BRC=0; bash "$S" bot acc recover --yes --x </dev/null >/dev/null 2>&1 || BRC=$?
[ "$rc $BRC" = "0 2" ] && grep -q '^    run: claude respawn acc11111' <<<"$out" && [[ $out != *"$MK"* ]] && [ "$(<"$HOME/claude.calls")" = "RESPAWN acc11111" ] &&
  [ "$(cut -d' ' -f4- "$AD/recover.log")" = "recover --yes: claude respawn acc11111 (exit 0)" ] ||
  { echo "FAIL: bot recover --yes runs its plan with no terminal and no question, logged as recover --yes: rc=$rc $BRC $out / $(cat "$HOME/claude.calls" "$AD/recover.log" 2>&1)"; exit 1; }
[ -e "$AD/auto-start" ] && [ "$(find "$AD/auto-start" -mmin -2 | wc -l | tr -d ' ')" = 1 ] || { echo "FAIL: bot recover --yes (what the monitor and boot run) touches <bot dir>/auto-start once the session is started"; exit 1; }
grep -qE "^acc11111 [0-9]+$" "$AD/own-stop" || { echo "FAIL: recover records the job it respawns in own-stop (the respawn kills the old process: not a person's stop): $(cat "$AD/own-stop" 2>&1)"; exit 1; }
rm -f "$AD/own-stop"
rm -f "$HOME/claude.calls" "$AD/recover.log" "$AD/auto-start"
# hold (1.19.1): the marker, no question, nothing run; a word after it is usage (exit 2).
rc=0; out=$(bash "$S" bot acc hold </dev/null 2>&1) || rc=$?; BRC=0; bash "$S" bot acc hold x </dev/null >/dev/null 2>&1 || BRC=$?
[ "$rc $BRC" = "0 2" ] && [ -f "$AD/held" ] && grep -q 'acc is held: ' <<<"$out" && [ ! -e "$HOME/claude.calls" ] ||
  { echo "FAIL: bot hold writes held and runs nothing; a word after it is usage: rc=$rc $BRC $out"; exit 1; }
rm -f "$AD/held"
# At a terminal: n runs nothing (exit 4); y respawns the listed session after the marker and the one question, logs it to
# recover.log and passes the status on (a respawn that fails: exit 1, said with its status; nothing else is run).
bt - n acc recover; A=$BRC; [ -e "$HOME/claude.calls" ] || A="$A none"; bt - y acc recover; B="$BRC $BO"
: > "$HOME/respawn.fails"; bt - y acc recover; rm -f "$HOME/respawn.fails"
[ "$A" = "4 none" ] && [[ $B == 0*$'\n'"$MK"$'\n'"Recover acc? [y/N] y"* ]] && [[ $B == *"claude-discord: bot: ran claude respawn acc11111 (exit 0); the monitor's next pass says whether acc answers"* ]] &&
  [ "$BRC" = 1 ] && grep -q 'claude-discord: bot: ran claude respawn acc11111 (exit 7)' <<<"$BO" && [[ $B$BO != *LAUNCHER* ]] &&
  [ "$(<"$HOME/claude.calls")" = $'RESPAWN acc11111\nRESPAWN acc11111' ] && [ "$(cut -d' ' -f4- "$AD/recover.log")" = $'recover: claude respawn acc11111 (exit 0)\nrecover: claude respawn acc11111 (exit 7)' ] &&
  [ ! -e "$AD/auto-start" ] ||
  { echo "FAIL: bot recover respawns the listed last session after its one question, logs it, and passes the status on: $A / $B / rc=$BRC $BO / $(cat "$HOME/claude.calls" "$AD/recover.log" 2>&1)"; exit 1; }
# --fresh with exactly one listed session (I3 of the review): it is stopped (STOP before the start) and gone before the
# fresh start.
# 1.19.4: the stop is ours, for a restart, so the hold the old session's SessionEnd hook writes on it goes once the
# pid is gone (a start that fails then leaves the bot down, recovered, never held). Planted here as the hook would.
rm -f "$HOME/claude.calls"; : > "$AD/held"; bt - y acc recover --fresh; A="$BRC $BO"; kill -0 "$OLD" 2>/dev/null || A="$A gone1"; [ ! -e "$AD/held" ] || A="$A held-left"
grep -qE "^acc11111 [0-9]+$" "$AD/own-stop" 2>/dev/null || A="$A no-own-stop"   # 1.19.7: person_stopped ignores a stop of ours
[[ $A == 0*"    run: claude stop acc11111, then cd $MP && claude-discord --bg --name acc"*"stopping acc (acc11111, pid $OLD)"*"LAUNCHER "*" -n acc "*"ran claude-discord --bg --name acc (exit 0)"*" gone1" ]] &&
  [ "$(<"$HOME/claude.calls")" = "STOP acc11111" ] || { echo "FAIL: bot recover --fresh with one listed session stops it before the fresh start: $A / $(cat "$HOME/claude.calls" 2>&1)"; exit 1; }
sleep 300 & OLD=$!; echo "$OLD" > "$HOME/old.pid"; rm -f "$HOME/claude.calls"
# 1.17.1 (the cswap loss of 2026-10-17): --fresh while a transcript of the bot's session changed in the last 15 minutes is
# refused before the question, nothing stopped: a working session is not a wedged one. The session's marker names the id
# it has NOW (a /clear or a takeover changed it since the listing's sessionId), so that id's transcript is the one read.
# 20 minutes old: allowed again (the plan, exit 3 with no terminal).
TDA="$HOME/.claude/projects/$(cd -P "$MP" && LC_ALL=C && printf '%s' "${PWD//[^A-Za-z0-9]/-}")"
mkdir -p "$TDA" "$AD/plugin-sessions"; : > "$AD/plugin-sessions/3df5c3fb-1111-2222-3333-444444444444"; : > "$TDA/3df5c3fb-1111-2222-3333-444444444444.jsonl"
rc=0; out=$(bash "$S" bot acc recover --fresh </dev/null 2>&1) || rc=$?
touch -d '20 minutes ago' "$TDA/3df5c3fb-1111-2222-3333-444444444444.jsonl"
rc2=0; out2=$(bash "$S" bot acc recover --fresh </dev/null 2>&1) || rc2=$?
[ "$rc" = 1 ] && grep -q "a transcript of acc's session changed within the last 15 minutes" <<<"$out" && [[ $out != *"run: "* ]] && [ ! -e "$HOME/claude.calls" ] && kill -0 "$OLD" 2>/dev/null &&
  [ "$rc2" = 3 ] && grep -q "^    run: claude stop acc11111, then cd $MP && claude-discord --bg --name acc" <<<"$out2" ||
  { echo "FAIL: recover --fresh is refused while a transcript of the bot's session (by its current marker) changed in the last 15 minutes, and allowed once it is older: rc=$rc $out / rc=$rc2 $out2 / $(cat "$HOME/claude.calls" 2>&1)"; exit 1; }
rm -f "$AD/plugin-sessions/3df5c3fb-1111-2222-3333-444444444444"
# The job's conversation moved on (a /clear or a handover-and-takeover: ~/.claude/sessions/<pid>.json names the session
# the process runs NOW, the job record the one it started with): claude respawn would bring the old one back, so the plan
# is a stop and a --bg --resume of the current id under a new job; y runs both. The same ids: a respawn, as above.
mkdir -p "$HOME/.claude/jobs/acc11111" "$HOME/.claude/sessions"
echo '{"sessionId":"0123abcd-1111-2222-3333-444444444444"}' > "$HOME/.claude/jobs/acc11111/state.json"
echo "{\"sessionId\":\"3df5c3fb-1111-2222-3333-444444444444\",\"jobId\":\"acc11111\",\"pid\":$OLD}" > "$HOME/.claude/sessions/$OLD.json"
bt - y acc recover; A="$BRC $BO"; kill -0 "$OLD" 2>/dev/null || A="$A gone1"
[[ $A == 0*"its last session acc11111 (pinned-job) is listed by claude agents"*"    run: claude stop acc11111, then cd $MP && claude-discord --bg --name acc --resume 3df5c3fb-1111-2222-3333-444444444444    (its conversation moved on to session 3df5c3fb-1111-2222-3333-444444444444, which its job record's 0123abcd-1111-2222-3333-444444444444 does not name"*"stopping acc (acc11111, pid $OLD)"*"LAUNCHER "*" -n acc "*"--resume 3df5c3fb-1111-2222-3333-444444444444"*"ran claude-discord --bg --name acc --resume 3df5c3fb-1111-2222-3333-444444444444 (exit 0)"*" gone1" ]] &&
  [ "$(<"$HOME/claude.calls")" = "STOP acc11111" ] && [[ $A != *RESPAWN* ]] ||
  { echo "FAIL: a session whose current id (sessions/<pid>.json) differs from its job record's is stopped and resumed under its current id, not respawned: $A / $(cat "$HOME/claude.calls" 2>&1)"; exit 1; }
# 1.19.9: CC 2.1.331 keeps sessionId as the job's birth id and records the live one in resumeSessionId, which respawn resumes:
# equal to the process's id, the plan is a respawn (no stop, no new job); a resumeSessionId that also differs is still a takeover.
echo '{"sessionId":"0123abcd-1111-2222-3333-444444444444","resumeSessionId":"3df5c3fb-1111-2222-3333-444444444444"}' > "$HOME/.claude/jobs/acc11111/state.json"
rm -f "$HOME/claude.calls"; bt - y acc recover; A="$BRC $BO"; A2=$(<"$HOME/claude.calls"); rm -f "$HOME/claude.calls"
echo '{"sessionId":"0123abcd-1111-2222-3333-444444444444","resumeSessionId":"99999999-1111-2222-3333-444444444444"}' > "$HOME/.claude/jobs/acc11111/state.json"
bt - n acc recover; B="$BRC $BO"
[[ $A == 0*"    run: claude respawn acc11111"* ]] && [ "$A2" = "RESPAWN acc11111" ] && [[ $A != *LAUNCHER* && $A != *"--resume"* ]] &&
  [[ $B == *"    run: claude stop acc11111, then cd $MP && claude-discord --bg --name acc --resume 3df5c3fb-1111-2222-3333-444444444444"*"NEW job id"* ]] && [ ! -e "$HOME/claude.calls" ] ||
  { echo "FAIL: a job record whose resumeSessionId is the live id is respawned, one whose resumeSessionId differs is still taken over: $A / $A2 / $B"; exit 1; }
rm -rf "$HOME/.claude/jobs/acc11111" "$HOME/.claude/sessions/$OLD.json"; sleep 300 & OLD=$!; echo "$OLD" > "$HOME/old.pid"; rm -f "$HOME/claude.calls"
# Its last session is not listed as started here (its pinned job runs in another project, and the newest plugin-sessions
# marker names a session that is not listed): a fresh --bg start, after the question. An untrusted workspace is refused
# before the marker, nothing asked. With no pinned-job, the marker whose session IS listed finds the session.
printf '0e1a2222\n' > "$AD/pinned-job"; mkdir -p "$AD/plugin-sessions"; : > "$AD/plugin-sessions/0123abcd-1111-2222-3333-444444444444"; rm -f "$HOME/claude.calls"
printf '#!/usr/bin/env bash\ncase "$1" in agents) echo %s;; *) echo "PLAIN $*" >> "$HOME/claude.calls";; esac\n' \
  "'"'[{"id":"0e1a2222","pid":45,"name":"acc","cwd":"/elsewhere","sessionId":"0123abcd-1111-2222-3333-444444444444"}]'"'" > "$HOME/bin/claude"
bt - y acc recover; A="$BRC $BO"
cp "$HOME/.claude.json" "$HOME/cj.keep"; jq --arg p "$(pwd -P)" '.projects[$p].hasTrustDialogAccepted = false' "$HOME/cj.keep" > "$HOME/.claude.json"
rc=0; out=$(bash "$S" bot acc recover </dev/null 2>&1) || rc=$?; cp "$HOME/cj.keep" "$HOME/.claude.json"
rm -f "$AD/pinned-job"; cp "$HOME/claude.live" "$HOME/bin/claude"; BRC=0; BO=$(bash "$S" bot acc recover </dev/null 2>&1) || BRC=$?
[[ $A == 0*"its last session 0e1a2222 (pinned-job) is not listed by claude agents"*"    run: cd $MP && claude-discord --bg --name acc"*$'\n'"$MK"$'\n'"Recover acc? [y/N] y"*"LAUNCHER "*" -n acc "*"claude-discord: bot: ran claude-discord --bg --name acc (exit 0)"* ]] &&
  [[ $A != *RESPAWN* ]] && [ ! -e "$HOME/claude.calls" ] && [ "$(tail -n 2 "$AD/recover.log" | head -n 1 | cut -d' ' -f4-)" = "recover: claude-discord --bg --name acc (exit 0)" ] &&
  [ "$rc" = 1 ] && grep -q "$MP is not a trusted workspace, so a --bg start would refuse" <<<"$out" && [[ $out != *"$MK"* ]] && [[ $out != *"run: "* ]] && [ "$(wc -l < "$AD/recover.log" | tr -d ' ')" = 8 ] &&
  [ "$BRC" = 3 ] && grep -q 'its last session acc11111 (plugin-sessions) is listed by claude agents' <<<"$BO" && grep -q '^    run: claude respawn acc11111' <<<"$BO" ||
  { echo "FAIL: bot recover starts a fresh --bg session when no last session is listed, refuses an untrusted workspace before asking, and finds the session by its plugin-sessions marker: $A / rc=$rc $out / rc=$BRC $BO / $(cat "$HOME/claude.calls" "$AD/recover.log" 2>&1)"; exit 1; }
# Two listed sessions: refused before the question, both named (exit 1), nothing run; --fresh stops every one, then
# starts one (exit 0); a stop that fails (a session that outlives claude stop; the 10 s wait skipped) starts nothing (exit 1).
sleep 300 & OLD2=$!; echo "$OLD2" > "$HOME/old2.pid"; printf 'acc11111\n' > "$AD/pinned-job"; rm -f "$HOME/claude.calls"
rc=0; out=$(bash "$S" bot acc recover </dev/null 2>&1) || rc=$?; A="$rc $out"; [ -e "$HOME/claude.calls" ] || A="$A none"
bt - y acc recover --fresh; B="$BRC $BO"; kill -0 "$OLD" 2>/dev/null || B="$B gone1"; kill -0 "$OLD2" 2>/dev/null || B="$B gone2"; P1=$OLD P2=$OLD2
sleep 300 & OLD=$!; echo "$OLD" > "$HOME/old.pid"; sleep 300 & OLD2=$!; echo "$OLD2" > "$HOME/old2.pid"; rm -f "$HOME/claude.calls"
cp "$HOME/bin/sleep" "$HOME/sleep.keep"; printf '#!/bin/sh\n' > "$HOME/bin/sleep"; : > "$HOME/stop.fails"
bt - y acc recover --fresh; cp "$HOME/sleep.keep" "$HOME/bin/sleep"; rm -f "$HOME/stop.fails" "$HOME/old2.pid"
[[ $A == "1 claude-discord: bot: 2 sessions of acc are listed (acc11111 pid $P1, acc22222 pid $P2): two on one token both answer"*"nothing was run none" ]] &&
  [[ $B == 0*"    run: claude stop acc11111, claude stop acc22222, then cd $MP && claude-discord --bg --name acc"*"stopping acc (acc11111, pid "*"stopping acc (acc22222, pid "*"LAUNCHER "*" -n acc "*" --bg Catch up on the channel."*"claude-discord: bot: ran claude-discord --bg --name acc (exit 0)"*" gone1 gone2" ]] &&
  [ "$BRC" = 1 ] && grep -q "claude-discord: bot: acc still runs after stop (pid $OLD): nothing was started; stopped: acc22222" <<<"$BO" && [[ $BO != *LAUNCHER* ]] && kill -0 "$OLD" && ! kill -0 "$OLD2" 2>/dev/null &&
  [ "$(<"$HOME/claude.calls")" = $'STOP acc11111\nSTOP acc22222' ] ||
  { echo "FAIL: bot recover refuses two listed sessions, and --fresh stops every one before it starts one (a stop that fails starts nothing): $A / $B / rc=$BRC $BO / $(cat "$HOME/claude.calls" 2>&1)"; exit 1; }
# --host: a host before 1.16.0 is exit 5 and is sent nothing but --version; a 1.16.0 host gets the act under ssh -t,
# --fresh as it is; the host's side decodes --version --bot ... recover --fresh (no terminal there: the plan, exit 3).
rm -f "$HOME/ssh.log" "$MON"/h1.*; printf 'claude-discord 1.15.0 (abc1234)\n' > "$MON/h1.out"
rc=0; out=$(bash "$S" bot --host h1 --manager mgr --project /x -- acc recover </dev/null 2>&1) || rc=$?; A="$rc $(command grep -v '^ATE' "$HOME/ssh.log")"
printf 'claude-discord 1.16.0 (abc1234)\n' > "$MON/h1.out"; bt - - --host h1 --manager mgr --project /x -- acc recover --fresh
rc2=0; out2=$(cd "$HOME" && bash "$S" --version --bot "$(a_hex "$MP")" "$(a_hex acc)" recover --fresh </dev/null 2>&1) || rc2=$?
[ "$A" = "5 -o BatchMode=yes -o ConnectTimeout=8 -- h1 ~/.local/bin/claude-discord --version" ] && grep -q 'h1 needs claude-discord 1.16.0 for this (it has 1.15.0' <<<"$out" &&
  [ "$BRC" = 0 ] && [ "$(tail -n 1 "$HOME/ssh.log")" = "-t -o BatchMode=yes -o ConnectTimeout=8 -- h1 env X=1 HTTPS_PROXY=http://q:1 https_proxy=http://q:1 ~/.local/bin/claude-discord --version --bot 2f78 616363 recover --fresh" ] &&
  [ "$rc2" = 3 ] && grep -q '^claude-discord: bot: recover --fresh acc on ' <<<"$out2" && grep -q "^    run: claude stop acc11111, then cd $MP && claude-discord --bg --name acc" <<<"$out2" ||
  { echo "FAIL: bot --host recover: a host before 1.16.0 is exit 5 and is sent only --version, a 1.16.0 host gets it under ssh -t; the host decodes --version --bot ... recover --fresh: $A / $out / rc=$BRC $(cat "$HOME/ssh.log") / rc=$rc2 $out2"; exit 1; }
rm -f "$HOME/ssh.log" "$MON"/h1.*
# `claude agents --json` failing: what runs is unknown, so nothing is (exit 1). The one listed session a foreground one
# (no job id): claude respawn cannot restart it, so nothing is run (exit 1) and --fresh is named.
printf '#!/bin/sh\n[ "$1" != agents ] || exit 1\necho "PLAIN $*" >> "$HOME/claude.calls"\n' > "$HOME/bin/claude"; rm -f "$HOME/claude.calls"
rc=0; out=$(bash "$S" bot acc recover </dev/null 2>&1) || rc=$?
printf '#!/bin/sh\ncase "$1" in agents) echo %s;; *) echo "PLAIN $*" >> "$HOME/claude.calls";; esac\n' "'"'[{"pid":4242,"name":"acc","cwd":"'"$PWD"'"}]'"'" > "$HOME/bin/claude"
rc2=0; out2=$(bash "$S" bot acc recover </dev/null 2>&1) || rc2=$?
rc3=0; out3=$(bash "$S" bot acc recover --fresh </dev/null 2>&1) || rc3=$?   # --fresh names it as a foreground session (M4 of the review)
[ "$rc" = 1 ] && grep -q "'claude agents --json' failed, so what is running is unknown" <<<"$out" && [ ! -e "$HOME/claude.calls" ] && [[ $out != *"run: "* ]] &&
  [ "$rc2" = 1 ] && grep -q 'the one listed session of acc is a foreground one (pid 4242, no job id), which claude respawn cannot restart' <<<"$out2" && [[ $out2 != *"run: "* ]] && [ ! -e "$HOME/claude.calls" ] &&
  [ "$rc3" = 3 ] && grep -qx '    its one listed session is a foreground one (pid 4242, no job id)' <<<"$out3" && grep -q "^    run: kill 4242, then cd $MP && claude-discord --bg --name acc" <<<"$out3" ||
  { echo "FAIL: bot recover with a failing claude agents, or with only a foreground session listed, runs nothing (exit 1), and --fresh names that session as a foreground one: rc=$rc $out / rc=$rc2 $out2 / rc=$rc3 $out3"; exit 1; }
cp "$HOME/claude.keep" "$HOME/bin/claude"; kill "$OLD" 2>/dev/null || :; rm -rf "$AD/pinned-job" "$AD/plugin-sessions" "$AD/recover.log" "$HOME/claude.calls" "$HOME/old2.pid"
echo "ok: bot recover: a bad word and its own session refused (exit 2); no terminal prints the plan (exit 3); its last session (pinned-job, then the newest plugin-sessions marker) listed as started here is respawned after the one question, logged, its status passed on, or, when its current session id (sessions/<pid>.json) differs from its job record's, stopped and resumed under the current id; none listed: a fresh --bg start, an untrusted workspace refused before the question; two listed refused, --fresh stops every one then starts one, a stop that fails starts nothing, a transcript that moved within 15 minutes refuses --fresh; a failed listing runs nothing; --host needs 1.16.0 and sends the act under ssh -t"
# bot add: no terminal, nothing is read (exit 3). A bot whose Discord name is no name here (it is renamed on Discord
# first), and one set up here already (its id in a bot-id: one token, one session), are refused; nothing is written.
# So is a user's token (no bot). A manager name with a backend in another project is no refusal since 1.18.1.
was=$(ls "$MR"); rc=0; out=$(bash "$S" bot add </dev/null 2>&1) || rc=$?
: > "$CURL_REPLIES"; queue_line '200 {"id":"999","bot":true,"username":"New Bot"}'; queue_line '200 {"id":"777","bot":true,"username":"acc9"}'
queue_line '200 {"id":"5","bot":false,"username":"human"}'
bt "$TOK_NEW" - add; A=$BRC$BO; bt "$TOK_NEW" - add; A2=$BRC$BO; bt "$TOK_NEW" - add; A3=$BRC$BO
[ "$rc" = 3 ] && [[ $A == 1*"Discord calls this bot 'New Bot', and a bot's name here is its Discord username"*"Rename it in the Developer Portal first"* ]] &&
  [[ $A2 == 1*"that token's bot (777) is set up in $AD already"* ]] && [[ $A3 == 1*"that token is no bot's (Discord says it is a user's)"* ]] && [ "$(ls "$MR")" = "$was" ] ||
  { echo "FAIL: bot add reads nothing without a terminal (exit 3), and refuses a bot whose Discord name is no name here, one set up already and a user's token: rc=$rc $out / $A / $A2 / $A3"; exit 1; }
# A setup that fails (here at its first write, the bot's directory under an unwritable bots/) leaves no half bot.
chmod 555 "$MR"; : > "$CURL_REPLIES"; queue_line '200 {"id":"995","bot":true,"username":"halfbot"}'
bt "$TOK_NEW" y add; chmod 755 "$MR"
[ "$BRC" = 1 ] && grep -q 'claude-discord: bot: setup failed (above); nothing was added' <<<"$BO" && [ "$(ls "$MR")" = "$was" ] ||
  { echo "FAIL: bot add whose setup fails removes the directory setup made: rc=$BRC $BO / $(ls "$MR")"; exit 1; }
# A bot set up here with no bot-id (health never saw it) is still found: by its directory (Discord's name for the new
# token is its name), and by its token (the same token under another Discord name), compared in-process, never shown.
TOK_TWIN=tokTwinAAAAbbbbCCCCdddd.eeee; mkdir -p "$MR/twin"; printf 'DISCORD_BOT_TOKEN=%s\n' "$TOK_NEW" > "$MR/twin/.env"
: > "$CURL_REPLIES"; queue_line '200 {"id":"991","bot":true,"username":"twin"}'; queue_line '200 {"id":"992","bot":true,"username":"newbot"}'
queue_line '200 {"id":"993","bot":true,"username":"ACC"}'
bt "$TOK_TWIN" - add; A=$BRC$BO; bt "$TOK_NEW" - add; A2=$BRC$BO; bt "$TOK_TWIN" - add
[[ $A == 1*"a bot 'twin' is set up in $MR already"* ]] && [[ $BRC$BO == 1*"'ACC' is the name of $AD but for its case"* ]] && BRC=${A2%%[!0-9]*} BO=$A2 && [ "$BRC" = 1 ] && grep -q "that token is the token of $MR/twin already: two sessions on one token both answer; nothing was changed" <<<"$BO" &&
  [ ! -e "$MR/newbot" ] && [[ $A$BO != *tok[TN]* ]] ||
  { echo "FAIL: bot add refuses a bot set up here with no bot-id, by its directory and by its token, and a name of another bot but for its case: $A / $A2 / rc=$BRC $BO"; exit 1; }
rm -rf "$MR/twin"
# y, a mode, --start: setup writes it as at a terminal (the token in .env, the project's channel with an @mention
# required, the mode), its id is kept, access.log says so, and it is started; the token is never printed.
: > "$CURL_REPLIES"; queue_line '200 {"id":"999","bot":true,"username":"newbot"}'
bt "$TOK_NEW" y add --mode autoresearchclaw --start
[ "$BRC" = 0 ] && [ "$(<"$MR/newbot/.env")" = "DISCORD_BOT_TOKEN=$TOK_NEW" ] && [ "$(<"$MR/newbot/mode")" = autoresearchclaw ] && [ "$(<"$MR/newbot/bot-id")" = 999 ] &&
  [ "$(cut -d' ' -f2- "$MR/newbot/discord-name")" = newbot ] &&
  jq -e '[.groups[]] | length == 1 and .[0].requireMention == true' "$MR/newbot/access.json" >/dev/null && grep -q '^LAUNCHER .* -n newbot ' <<<"$BO" &&
  [ "$(tail -n 1 "$MR/newbot/access.log" | cut -d' ' -f4-)" = "added (bot 999, mode autoresearchclaw)" ] && [ "${BO##*$'\n'}" = "claude-discord: bot: newbot added and started" ] &&
  [[ $BO != *"$TOK_NEW"* ]] || { echo "FAIL: bot add, y: setup writes the bot (token, channel, mention, mode), its id kept and logged, started; the token never printed: rc=$BRC $BO / $(ls "$MR/newbot" 2>&1)"; exit 1; }
rm -rf "$MR/newbot"
# A bot of that name made while the question was open (another terminal's add or setup): y changes nothing and setup
# never runs (M4 of the 1.14.0 review). The driver runs the mkdir when it sees the question, before it answers it.
: > "$CURL_REPLIES"; queue_line '200 {"id":"999","bot":true,"username":"newbot"}'
btq "$TOK_NEW" y "mkdir -p $MR/newbot" add
[ "$BRC" = 1 ] && grep -q "a bot 'newbot' appeared in $MR while the question was open; nothing was changed" <<<"$BO" && [ -d "$MR/newbot" ] && [ -z "$(ls -A "$MR/newbot")" ] ||
  { echo "FAIL: bot add, y, with a bot of that name made while the question was open: refused (exit 1), setup never run (the directory as the mkdir left it): rc=$BRC $BO / $(ls -A "$MR/newbot" 2>&1)"; exit 1; }
rm -rf "$MR/newbot"
# --host at a terminal: run there under ssh -t, the word add in hex, the mode and --start as they are.
printf 'claude-discord 1.14.0 (abc1234)\n' > "$MON/h1.out"
bt "$TOK_NEW" - --host h1 --manager mgr --project /p add --mode dev-manager --start
[ "$BRC" = 0 ] && [ "$(tail -n 1 "$HOME/ssh.log")" = "-t -o BatchMode=yes -o ConnectTimeout=8 -- h1 env X=1 HTTPS_PROXY=http://q:1 https_proxy=http://q:1 ~/.local/bin/claude-discord --version --bot 2f70 616464 --mode dev-manager --start" ] && [ "$(grep -c -- "^-t " "$HOME/ssh.log")" = 1 ] ||
  { echo "FAIL: bot --host add runs on the host under ssh -t: rc=$BRC $BO / $(cat "$HOME/ssh.log")"; exit 1; }
rm -f "$HOME/ssh.log" "$MON"/h1.*
exec {BT_IN}>&- {BT_RC}<&-; wait "$BT_PID"; rm -f "$HOME/bt.in" "$HOME/bt.rc" "$HOME/bt.out"
echo "ok: bot add: no terminal reads nothing; its Discord username is its name (one that is no name here is renamed on Discord first), a bot set up already is refused; y runs setup with its answers on stdin, keeps its id, logs it, and --start starts it; the token is never printed; --host runs it on the host under ssh -t"
# What is written down for people: the dev-manager rule forbids an access change on a channel message's request, and the
# README says what the terminal check is and is not.
grep -q "never on a channel message's request" "$D/rules/dev-manager.md" && grep -q 'That is a speed bump, not a boundary' "$D/README.md" &&
  grep -q '^- `claude-discord bot ... token | rename | add | recover` .* never on a channel message.s request' "$D/rules/dev-manager.md" && grep -q '^## A bot.s token and name: `bot`$' "$D/README.md" &&
  grep -q '^#   claude-discord bot \[--host' "$D/bin/claude-discord" && grep -q '^#   claude-discord bot \[\.\.\.\] <name> recover \[--fresh\]' "$D/bin/claude-discord" &&
  grep -q '^claude-discord bot <bot> recover \[--fresh\]' "$D/README.md" && grep -q '^`F` (1.16.0): `f` recovers the selected bot' "$D/README.md" ||
  { echo "FAIL: the dev-manager rule must forbid access and bot changes (recover too) on a channel message's request, the README must call the terminal check a speed bump and have the bot section with recover and the TUI's f and F, the header the bot verb and its recover act"; exit 1; }
echo "ok: the dev-manager rule forbids access and bot changes on a channel message's request; the README calls the terminal check a speed bump, not a boundary, and documents the bot verb, recover and the TUI's f and F"
mv "$HOME/claude.suite" "$HOME/bin/claude"; cd "$P"
rm -rf "$MON" "$HOME/ssh.log" "$HOME/bin/ssh" "$HOME/b1okproj" "$(pstate "$HOME/b1okproj")"; : > "$CURL_REPLIES"; : > "$CURL_LOG"; : > "$CURL_STDIN_LOG"

# from the core file: the starts before this block had patched 0.0.4 (the fake plugin), so patch has nothing to report there.
bash "$S" --name alpha >/dev/null 2>&1 || { echo "FAIL: fixture: a start must patch the fake plugin"; exit 1; }
# patch: every discord version dir in the cache, idempotent, the .mcp.json env
# line for the failure cache, a moved pattern reported with exit 1. 0.0.4 is the
# fake plugin above, already patched by the starts; 0.0.5 and 0.0.6 are clean.
PCACHE="$HOME/.claude/plugins/cache/claude-plugins-official/discord"
for v in 0.0.5 0.0.6; do
  mkdir -p "$PCACHE/$v"
  cp "$HOME/server.ts.pristine" "$PCACHE/$v/server.ts"
  printf '{"mcpServers":{"discord":{"command":"bun","args":["run","--cwd","${CLAUDE_PLUGIN_ROOT}","start"]}}}\n' > "$PCACHE/$v/.mcp.json"
done
out=$(bash "$S" patch 2>&1) || { echo "FAIL: patch on clean and patched version dirs must exit 0: $out"; exit 1; }
for v in 0.0.5 0.0.6; do
  grep -q 'msg.author.id === client.user?.id' "$PCACHE/$v/server.ts" &&
  grep -q 'ignoreEveryone: true' "$PCACHE/$v/server.ts" &&
  grep -qF "(await import(\"$HOME/.claude-discord/runtime/discord-chunk.ts\")).chunk(text, limit, mode)" "$PCACHE/$v/server.ts" &&
  grep -qF "$HOME/.claude-discord/runtime/discord-proxy.ts" "$PCACHE/$v/bunfig.toml" &&
  [ "$(jq -c '.mcpServers.discord.env' "$PCACHE/$v/.mcp.json")" = '{"CLAUDE_DISCORD_BOT":"${DISCORD_STATE_DIR:-}"}' ] &&
  grep -qF "$PCACHE/$v/server.ts" <<<"$out" ||
  { echo "FAIL: patch must apply all five patches to $v and name its files: $out"; exit 1; }
done
! grep -qF "$PCACHE/0.0.4" <<<"$out" || { echo "FAIL: the already patched 0.0.4 must not be reported as changed: $out"; exit 1; }
out=$(bash "$S" patch 2>&1) && [ -z "$out" ] || { echo "FAIL: a second patch run must be silent and exit 0: $out"; exit 1; }
[ -f "$HOME/.claude-discord/runtime/discord-chunk.ts" ] && [ -f "$HOME/.claude-discord/runtime/discord-proxy.ts" ] || { echo "FAIL: patch must keep the runtime copy"; exit 1; }
# A .mcp.json an earlier release patched carries DISCORD_STATE_DIR: "${DISCORD_STATE_DIR}", which masks the
# server's own default for a user without claude-discord: it goes, our key comes, any other env key stays; once.
jq '.mcpServers.discord.env = {DISCORD_STATE_DIR: "${DISCORD_STATE_DIR}", KEEP: "1"}' "$PCACHE/0.0.5/.mcp.json" > "$HOME/m.tmp" && mv "$HOME/m.tmp" "$PCACHE/0.0.5/.mcp.json"
out=$(bash "$S" patch 2>&1) && [ "$(jq -c '.mcpServers.discord.env' "$PCACHE/0.0.5/.mcp.json")" = '{"KEEP":"1","CLAUDE_DISCORD_BOT":"${DISCORD_STATE_DIR:-}"}' ] && grep -qF "$PCACHE/0.0.5/.mcp.json" <<<"$out" || { echo "FAIL: patch must replace an earlier DISCORD_STATE_DIR env line by CLAUDE_DISCORD_BOT and keep other keys: $out $(<"$PCACHE/0.0.5/.mcp.json")"; exit 1; }
out=$(bash "$S" patch 2>&1) && [ -z "$out" ] || { echo "FAIL: the .mcp.json rewrite must be idempotent: $out"; exit 1; }
# runtime/VERSION: an older wrapper leaves a newer runtime and the cache alone, says so once, exits 0.
[ "$(<"$HOME/.claude-discord/runtime/VERSION")" = "$(jq -r .version "$PC/.claude-plugin/plugin.json")" ] || { echo "FAIL: patch must stamp runtime/VERSION with its plugin version"; exit 1; }
cp "$HOME/.claude-discord/runtime/VERSION" "$HOME/rtv.before"; echo 99.0.0 > "$HOME/.claude-discord/runtime/VERSION"
echo stale > "$HOME/.claude-discord/runtime/discord-chunk.ts"; cp "$HOME/server.ts.pristine" "$PCACHE/0.0.5/server.ts"
rc=0; out=$(bash "$S" patch 2>&1) || rc=$?
[ "$rc" = 0 ] && [ "$(grep -c 'newer than this' <<<"$out")" = 1 ] && [ "$(<"$HOME/.claude-discord/runtime/discord-chunk.ts")" = stale ] && cmp -s "$HOME/server.ts.pristine" "$PCACHE/0.0.5/server.ts" || { echo "FAIL: an older patch must leave a newer runtime and the cache alone and say so once (rc=$rc): $out"; exit 1; }
cp "$HOME/rtv.before" "$HOME/.claude-discord/runtime/VERSION"; mv "$HOME/rtv.before" "$HOME/rtv.ref"
bash "$S" patch >/dev/null 2>&1 && cmp -s "$PC/runtime/discord-chunk.ts" "$HOME/.claude-discord/runtime/discord-chunk.ts" && grep -q 'ignoreEveryone: true' "$PCACHE/0.0.5/server.ts" || { echo "FAIL: the same version must refill the runtime and patch again"; exit 1; }
for junk in junk 1.9.0.1 1.08.0; do   # garbled, four parts, a leading zero (not octal; 1.8.0 is older)
  echo "$junk" > "$HOME/.claude-discord/runtime/VERSION"; echo stale > "$HOME/.claude-discord/runtime/discord-chunk.ts"
  bash "$S" patch >/dev/null 2>&1 && cmp -s "$PC/runtime/discord-chunk.ts" "$HOME/.claude-discord/runtime/discord-chunk.ts" && cmp -s "$HOME/rtv.ref" "$HOME/.claude-discord/runtime/VERSION" || { echo "FAIL: runtime/VERSION '$junk' must not lock the runtime or crash patch: it is refilled and restamped"; exit 1; }
done
rm -f "$HOME/rtv.ref"
# A dir the previous release patched imports the chunk helper and preloads the proxy from the old compat paths; patch re-points both to runtime/, once.
perl -pi -e 's{import\("[^"]*"\)}{import("$ENV{HOME}/.claude-discord/discord-chunk.ts")}' "$PCACHE/0.0.6/server.ts"
printf 'preload = ["%s/.claude-discord/discord-proxy.ts"]\n' "$HOME" > "$PCACHE/0.0.6/bunfig.toml"
grep -qF "$HOME/.claude-discord/discord-chunk.ts" "$PCACHE/0.0.6/server.ts" || { echo "FAIL: the old-path fixture was not planted"; exit 1; }
out=$(bash "$S" patch 2>&1) || { echo "FAIL: patch over an old-path import must exit 0: $out"; exit 1; }
grep -qF "(await import(\"$HOME/.claude-discord/runtime/discord-chunk.ts\")).chunk(text, limit, mode)" "$PCACHE/0.0.6/server.ts" && ! grep -qF "$HOME/.claude-discord/discord-chunk.ts" "$PCACHE/0.0.6/server.ts" &&
  [ "$(<"$PCACHE/0.0.6/bunfig.toml")" = "preload = [\"$HOME/.claude-discord/runtime/discord-proxy.ts\"]" ] &&
  grep -qF "$PCACHE/0.0.6/server.ts" <<<"$out" && grep -qF "$PCACHE/0.0.6/bunfig.toml" <<<"$out" || { echo "FAIL: patch must re-point an old chunk import and proxy preload to runtime/: $out"; exit 1; }
out=$(bash "$S" patch 2>&1) && [ -z "$out" ] || { echo "FAIL: a second patch after the rewrite must change nothing: $out"; exit 1; }
echo "ok: patch rewrites a chunk import and a proxy preload left at the old paths to runtime/, and a second run is silent"

# A server.ts 1.9.3 patched (its guard line in, its login giving up on a refused token): only the login is replaced, once.
# So is the login of one patched by 1.9.4 to 1.13.x (0.0.2), which waited out a refused token only at the login.
OLD193='new Promise<string>(ok => { if (TOKEN) return ok(TOKEN); const t = setInterval(() => { let m; try { m = readFileSync(ENV_FILE, "utf8").match(/^DISCORD_BOT_TOKEN=(.+)$/m) } catch {} if (m?.[1].trim()) { clearInterval(t); ok(m[1].trim()) } }, 10000) }).then(t => client.login(t)).catch('
mkdir -p "$PCACHE/0.0.3"
CD_OLD=$OLD193 perl -0777 -pe 's/^  process\.exit\(1\)\n\}\n/  process.stderr.write("discord channel: no token yet; waiting for it (re-read every 10 s)\\n")\n}\n/m; s/^client\.login\(TOKEN\)\.catch\(/$ENV{CD_OLD}/m' "$HOME/server.ts.pristine" > "$PCACHE/0.0.3/server.ts"
grep -qF "$OLD193" "$PCACHE/0.0.3/server.ts" && [ "$(grep -c 'process.exit(1)' "$PCACHE/0.0.3/server.ts")" = 1 ] || { echo "FAIL: the 1.9.3-patched fixture was not planted: $(<"$PCACHE/0.0.3/server.ts")"; exit 1; }
OLD194=';(async () => { let bad = ""; const read = () => { let m; try { m = readFileSync(ENV_FILE, "utf8").match(/^DISCORD_BOT_TOKEN=(.+)$/m) } catch {} return m?.[1].trim() || "" }; const pick = () => { const v = bad ? read() : (TOKEN || read()); return v && v !== bad ? v : "" }; for (;;) { const t = await new Promise<string>(ok => { const v = pick(); if (v) return ok(v); const i = setInterval(() => { const w = pick(); if (w) { clearInterval(i); ok(w) } }, 10000) }); try { return await client.login(t) } catch (e) { if ((e as any)?.code !== "TokenInvalid") throw e; bad = t; process.stderr.write("discord channel: the token was refused; waiting for a new one in .env (re-read every 10 s)\n") } } })().catch('
mkdir -p "$PCACHE/0.0.2"
CD_OLD=$OLD194 perl -0777 -pe 's/^  process\.exit\(1\)\n\}\n/  process.stderr.write("discord channel: no token yet; waiting for it (re-read every 10 s)\\n")\n}\n/m; s/^client\.login\(TOKEN\)\.catch\(/$ENV{CD_OLD}/m' "$HOME/server.ts.pristine" > "$PCACHE/0.0.2/server.ts"
# And one patched by 1.14.0 to 1.19.x (0.0.8), whose login rethrew any other error, which ended the server.
OLD1190=';(async () => { let bad = ""; const read = () => { let m; try { m = readFileSync(ENV_FILE, "utf8").match(/^DISCORD_BOT_TOKEN=(.+)$/m) } catch {} return m?.[1].trim() || "" }; const pick = () => { const v = bad ? read() : (TOKEN || read()); return v && v !== bad ? v : "" }; for (;;) { const t = await new Promise<string>(ok => { const v = pick(); if (v) return ok(v); const i = setInterval(() => { const w = pick(); if (w) { clearInterval(i); ok(w) } }, 10000) }); try { await client.login(t); await new Promise<void>(ok => { const f = (ev: any) => { if (ev?.code === 4004) { client.off("shardDisconnect", f); ok() } }; client.on("shardDisconnect", f) }); bad = t; process.stderr.write("discord channel: the gateway refused the token (4004); waiting for a new one in .env (re-read every 10 s)\n") } catch (e) { if ((e as any)?.code !== "TokenInvalid") throw e; bad = t; process.stderr.write("discord channel: the token was refused; waiting for a new one in .env (re-read every 10 s)\n") } } })().catch('
mkdir -p "$PCACHE/0.0.8"
CD_OLD=$OLD1190 perl -0777 -pe 's/^  process\.exit\(1\)\n\}\n/  process.stderr.write("discord channel: no token yet; waiting for it (re-read every 10 s)\\n")\n}\n/m; s/^client\.login\(TOKEN\)\.catch\(/$ENV{CD_OLD}/m' "$HOME/server.ts.pristine" > "$PCACHE/0.0.8/server.ts"
grep -qF 'TokenInvalid") throw e;' "$PCACHE/0.0.8/server.ts" || { echo "FAIL: the 1.14-1.19 fixture was not planted: $(<"$PCACHE/0.0.8/server.ts")"; exit 1; }
out=$(bash "$S" patch 2>&1) && grep -qF "$PCACHE/0.0.3/server.ts" <<<"$out" && ! grep -qF '.then(t => client.login(t))' "$PCACHE/0.0.3/server.ts" &&
  [ "$(grep -c 'code !== "TokenInvalid"' "$PCACHE/0.0.3/server.ts")" = 1 ] && grep -qF '})().catch(err => {' "$PCACHE/0.0.3/server.ts" &&
  [ "$(grep -c 'no token yet; waiting for it' "$PCACHE/0.0.3/server.ts")" = 1 ] && [ "$(grep -c 'process.exit(1)' "$PCACHE/0.0.3/server.ts")" = 1 ] || { echo "FAIL: patch must upgrade a 1.9.3 login to the refused-token loop: $out $(<"$PCACHE/0.0.3/server.ts")"; exit 1; }
grep -qF "$PCACHE/0.0.2/server.ts" <<<"$out" && ! grep -qF 'return await client.login(t)' "$PCACHE/0.0.2/server.ts" && [ "$(grep -c 'client.on("shardDisconnect", f)' "$PCACHE/0.0.2/server.ts")" = 1 ] &&
  [ "$(grep -c 'code !== "TokenInvalid"' "$PCACHE/0.0.2/server.ts")" = 1 ] && grep -qF '})().catch(err => {' "$PCACHE/0.0.2/server.ts" || { echo "FAIL: patch must upgrade a 1.9.4 login to the one that waits out a 4004 too: $out $(<"$PCACHE/0.0.2/server.ts")"; exit 1; }
grep -qF "$PCACHE/0.0.8/server.ts" <<<"$out" && ! grep -qF 'TokenInvalid") throw e;' "$PCACHE/0.0.8/server.ts" && [ "$(grep -c 'login failed (' "$PCACHE/0.0.8/server.ts")" = 1 ] &&
  [ "$(grep -c 'code !== "TokenInvalid"' "$PCACHE/0.0.8/server.ts")" = 1 ] && grep -qF '})().catch(err => {' "$PCACHE/0.0.8/server.ts" || { echo "FAIL: patch must upgrade a 1.14-1.19 login to the one that retries any other login error: $out $(<"$PCACHE/0.0.8/server.ts")"; exit 1; }
out=$(bash "$S" patch 2>&1) && [ -z "$out" ] || { echo "FAIL: a second patch after the 1.9.3 and 1.9.4 upgrades must change nothing: $out"; exit 1; }
rm -rf "$PCACHE/0.0.3" "$PCACHE/0.0.2" "$PCACHE/0.0.8"
echo "ok: patch upgrades a server.ts 1.9.3 patched to wait out a refused token, one 1.9.4 to 1.13.x patched to wait out a 4004 after the login too, and one 1.14 to 1.19.x patched to retry any other login error; a second run is silent"
# A moved pattern: exit 1 naming file and patch, the other patches still applied.
mkdir -p "$PCACHE/0.0.7"
printf 'client.on(x, msg => {\n  if (msg.author.isBot()) return\n})\nif (!TOKEN) {\n  process.exit(1)\n}\nclient.connect(TOKEN).catch(err => {})\n' > "$PCACHE/0.0.7/server.ts"
printf '{"mcpServers":{"discord":{"command":"bun"}}}\n' > "$PCACHE/0.0.7/.mcp.json"
out=$(bash "$S" patch 2>&1) && { echo "FAIL: a pattern that no longer matches must exit 1"; exit 1; }
grep -q 'patch: .*0.0.7/server.ts: bot-authors no longer matches' <<<"$out" || { echo "FAIL: wrong no-match report: $out"; exit 1; }
# One late-token anchor without the other (the login moved): reported, and the exit left in place.
grep -q 'patch: .*0.0.7/server.ts: late-token no longer matches' <<<"$out" && grep -q '^  process.exit(1)$' "$PCACHE/0.0.7/server.ts" || { echo "FAIL: a moved login must leave the no-token exit alone and be reported: $out"; exit 1; }
! grep -q '0.0.[456]/server.ts: ' <<<"$out" || { echo "FAIL: only the moved dir may be reported: $out"; exit 1; }
grep -qF "$HOME/.claude-discord/runtime/discord-proxy.ts" "$PCACHE/0.0.7/bunfig.toml" &&
  [ "$(jq -r '.mcpServers.discord.env.CLAUDE_DISCORD_BOT' "$PCACHE/0.0.7/.mcp.json")" = '${DISCORD_STATE_DIR:-}' ] || { echo "FAIL: the patches that still match must be applied beside the moved one"; exit 1; }
# failure-cache: a .mcp.json without the discord server's command, and one that
# is not JSON, are left byte-identical, named, exit 1; the file lists once.
rm -rf "$PCACHE/0.0.7"
for v in 0.0.8 0.0.9; do mkdir -p "$PCACHE/$v"; cp "$HOME/server.ts.pristine" "$PCACHE/$v/server.ts"; done
printf '{"mcpServers":{"other":{"command":"x"}}}\n' > "$PCACHE/0.0.8/.mcp.json"
printf '{"mcpServers": oops\n' > "$PCACHE/0.0.9/.mcp.json"
cp "$PCACHE/0.0.8/.mcp.json" "$HOME/mcp8.orig"; cp "$PCACHE/0.0.9/.mcp.json" "$HOME/mcp9.orig"
out=$(bash "$S" patch 2>&1) && { echo "FAIL: a .mcp.json the failure-cache patch cannot edit must exit 1: $out"; exit 1; }
for v in 0.0.8 0.0.9; do
  grep -q "patch: .*$v/.mcp.json: failure-cache no longer matches" <<<"$out" || { echo "FAIL: no failure-cache report for $v: $out"; exit 1; }
  cmp -s "$HOME/mcp${v#0.0.}.orig" "$PCACHE/$v/.mcp.json" || { echo "FAIL: $v/.mcp.json must be left byte-identical"; exit 1; }
  grep -q 'ignoreEveryone: true' "$PCACHE/$v/server.ts" || { echo "FAIL: the other patches must still be applied to $v"; exit 1; }
done
! grep '^claude-discord: patched' <<<"$out" | grep -q '\.mcp\.json' || { echo "FAIL: an unpatched .mcp.json must not be listed as patched: $out"; exit 1; }
[ "$(grep '^claude-discord: patched' <<<"$out" | grep -o "$PCACHE/0.0.8/server.ts" | wc -l)" = 1 ] || { echo "FAIL: a patched file must be listed once: $out"; exit 1; }
rm -f "$HOME/mcp8.orig" "$HOME/mcp9.orig"
rm -rf "$PCACHE/0.0.8" "$PCACHE/0.0.9"
rm -rf "$PCACHE/0.0.5" "$PCACHE/0.0.6"
echo "ok: patch applies the five patches to every cached version, is idempotent and silent, and reports a moved pattern with exit 1"
# The old single file moved the plugin cache aside after these cases; the install cases below ran with it aside.
mv "$HOME/.claude/plugins" "$HOME/.claude/plugins.off"

# A machine with the 1.8-1.16 install (5b, 1.18.1): compat (every update) removes ~/.claude-discord/hooks (a directory of
# links into compat/, or the 1.8 copies), compat/ and its leftovers (compat.*) and the old rule copies; keeps
# discord-chunk.ts and discord-proxy.ts as links into runtime/ (a bun server patched before 1.9 imports the chunk module
# from there at its next long reply, and that running process cannot be re-patched), the bots' scratch, records, runtime
# and the source clone. A symlink at hooks/ (a dev checkout) goes as a link, its target untouched; a compat/ that holds a
# git tree (a clone put there by hand) is left, said. `patch --compat` (a 1.17 on-session-start from a stale clone still
# sends it) is plain patch: exit 0, silent.
OH="$HOME/.claude-discord"
rm -rf "$OH/hooks" "$OH/rules" "$OH/discord-chunk.ts" "$OH/discord-proxy.ts"
mkdir -p "$OH/scratch/b" "$OH/rules" "$OH/hooks/tools" "$OH/compat/hooks/turn" "$OH/compat.new.1/old" "$OH/compat.lock"
for t in turn peers lib autoresearchclaw; do mkdir -p "$OH/hooks/$t"; echo old > "$OH/hooks/$t/stale"; done
: > "$OH/scratch/b/note"; echo old > "$OH/hooks/tools/thread"; : > "$OH/rules/dev-manager.md"; echo old > "$OH/discord-chunk.ts"; echo old > "$OH/discord-proxy.ts"; echo old > "$OH/compat/hooks/turn/on-prompt"
out=$(cd "$HOME" && bash "$S" compat 2>&1) || { echo "FAIL: compat failed: $out"; exit 1; }
[ ! -e "$OH/hooks" ] && [ ! -L "$OH/hooks" ] && [ ! -e "$OH/compat" ] && [ ! -e "$OH/compat.new.1" ] && [ ! -e "$OH/compat.lock" ] && [ ! -e "$OH/rules" ] &&
  [ "$(readlink "$OH/discord-chunk.ts")" = "$OH/runtime/discord-chunk.ts" ] && [ "$(readlink "$OH/discord-proxy.ts")" = "$OH/runtime/discord-proxy.ts" ] &&
  cmp -s "$OH/discord-chunk.ts" "$PC/runtime/discord-chunk.ts" && cmp -s "$OH/discord-proxy.ts" "$PC/runtime/discord-proxy.ts" &&
  [ -e "$OH/scratch/b/note" ] && [ -d "$OH/source/.git" ] && [ -d "$OH/records" ] ||
  { echo "FAIL: compat removes the old install copies and keeps the runtime links: $out / $(ls -la "$OH" 2>&1)"; exit 1; }
mkdir -p "$HOME/old-target/hooks/turn" "$OH/compat/.git"; : > "$HOME/old-target/hooks/turn/on-prompt"; ln -s "$HOME/old-target/hooks" "$OH/hooks"
out=$(cd "$HOME" && bash "$S" compat 2>&1) || { echo "FAIL: compat failed: $out"; exit 1; }
[ ! -L "$OH/hooks" ] && [ ! -e "$OH/hooks" ] && [ -e "$HOME/old-target/hooks/turn/on-prompt" ] && [ -d "$OH/compat/.git" ] && grep -q 'compat holds a git tree' <<<"$out" ||
  { echo "FAIL: a symlinked hooks goes as a link, its target untouched, and a compat/ holding a git tree is left, said: $out / $(ls -la "$OH" "$HOME/old-target/hooks/turn" 2>&1)"; exit 1; }
rm -rf "$OH/compat" "$HOME/old-target"
out=$(bash "$S" patch --compat 2>&1) && [ -z "$out" ] || { echo "FAIL: patch --compat (a 1.17 on-session-start from a stale clone) is plain patch: exit 0, silent: $out"; exit 1; }
echo "ok: compat removes ~/.claude-discord/hooks, compat/ with its leftovers and the old rule copies (a symlinked hooks as a link, a compat/ holding a git tree left and said), keeps the two runtime links, scratch, records and the source clone; patch --compat is plain patch"

# setup --mode: changes only a set-up bot's mode. A fresh project, so these
# assertions are not entangled with any other bot's state.
P5="$HOME/project5"; mkdir -p "$P5"; cd "$P5"
jq -n --arg p5 "$PHOME/project5" '{projects: {($p5): {hasTrustDialogAccepted: true}}}' > "$HOME/.claude.json"
R5=$HOME/.claude-discord/projects/$(skey "$P5")/bots   # by hand, not broot: the first case asserts that nothing made the key dir
SL5="$P5/.claude/settings.local.json"

out=$(printf '' | bash "$S" setup nosetup --mode 2>&1) && { echo "FAIL: --mode on a bot that is not set up should refuse"; exit 1; }
rc=$?
[ "$rc" -eq 2 ] && grep -qF "run 'claude-discord setup nosetup' first" <<<"$out" || { echo "FAIL: --mode on an unset bot must exit 2 with a hint, got rc=$rc: $out"; exit 1; }
[ ! -e "$HOME/.claude-discord/projects/$(skey "$P5")" ] && [ ! -e "$P5/.claude/discord-agents" ] || { echo "FAIL: --mode on an unset bot must create nothing (no key dir, bot dir or config.env): $(find "$HOME/.claude-discord/projects/$(skey "$P5")" "$P5/.claude" 2>&1)"; exit 1; }
echo "ok: --mode on a bot that is not set up exits 2 with a hint and creates nothing"
# 1.18.4 (the peer's pmac report): `setup --help` read --help as the bot's name, installed, made the key dir and waited
# at the token prompt. --help/-h print the usage line; a name starting with - is refused (exit 2) before anything is
# installed or made, by setup and by a launch alike.
for a in --help -h; do
  rc=0; out=$(printf '' | bash "$S" setup $a 2>&1) || rc=$?
  [ "$rc" = 2 ] && [ "$out" = "usage: claude-discord setup <name> [--scope project|global] [--method link|clone] [--reset|--mode]" ] || { echo "FAIL: setup $a prints the usage line, exit 2: rc=$rc $out"; exit 1; }
done
rc=0; out=$(printf '' | bash "$S" setup -x 2>&1) || rc=$?
[ "$rc" = 2 ] && grep -q "bot name must be a plain directory name" <<<"$out" || { echo "FAIL: setup refuses a name starting with -, exit 2: rc=$rc $out"; exit 1; }
rc=0; out=$(bash "$S" --name -x 2>&1) || rc=$?
[ "$rc" = 2 ] && grep -q "bot name must be a plain directory name" <<<"$out" || { echo "FAIL: a launch refuses a name starting with -, exit 2: rc=$rc $out"; exit 1; }
[ ! -e "$HOME/.claude-discord/projects/$(skey "$P5")" ] && [ ! -e "$P5/.claude" ] && [ ! -e "$HOME/.claude-discord/projects/$(skey "$P5")/bots/--help" ] || { echo "FAIL: setup --help, -h and -x must create nothing: $(find "$HOME/.claude-discord/projects/$(skey "$P5")" "$P5/.claude" 2>&1 | head -5)"; exit 1; }
echo "ok: setup --help and -h print the usage line; a bot name starting with - is refused by setup and by a launch before anything is made"

printf '\n1\n222\n\ntokF\nn\n' | bash "$S" setup five --scope project >/dev/null   # mode kept at its default, none
cp "$R5/five/.env" "$P5/five.env.before"; cp "$R5/five/access.json" "$P5/five.access.before"
printf 'autoresearchclaw\n' | bash "$S" setup five --mode >/dev/null
[ "$(<"$R5/five/mode")" = autoresearchclaw ] || { echo "FAIL: --mode fed only the mode answer did not switch the mode"; exit 1; }
! grep -qs '/.claude/discord-agents/hooks/' "$SL5" || { echo "FAIL: --mode must register no settings hook: $(cat "$SL5" 2>&1)"; exit 1; }
cmp -s "$R5/five/.env" "$P5/five.env.before" || { echo "FAIL: --mode must not touch the token file"; exit 1; }
cmp -s "$R5/five/access.json" "$P5/five.access.before" || { echo "FAIL: --mode must not touch access.json"; exit 1; }
printf 'none\n' | bash "$S" setup five --mode >/dev/null
[ "$(<"$R5/five/mode")" = none ] || { echo "FAIL: --mode did not switch back to none"; exit 1; }
cmp -s "$R5/five/.env" "$P5/five.env.before" || { echo "FAIL: --mode must not touch the token file (second run)"; exit 1; }
cmp -s "$R5/five/access.json" "$P5/five.access.before" || { echo "FAIL: --mode must not touch access.json (second run)"; exit 1; }
echo "ok: --mode fed only the mode answer switches a set-up bot's mode, writes no settings hook, and leaves the token file and access.json byte-identical"

printf 'dev-manager\npeerx:700:800:host\n' | bash "$S" setup five --mode >/dev/null
[ "$(<"$R5/five/mode")" = dev-manager ] || { echo "FAIL: --mode to dev-manager did not switch the mode"; exit 1; }
[ "$(jq -c '.peers' "$(pstate "$P5")/peers.json" 2>/dev/null)" = '[{"name":"peerx","bot_id":"700","owner_id":"800","machine":"host"}]' ] || { echo "FAIL: --mode to dev-manager must record the peer: $(cat "$(pstate "$P5")/peers.json" 2>&1)"; exit 1; }
[ "$(jq -c '.groups["1"].allowFrom' "$R5/five/access.json")" = '["222","700"]' ] || { echo "FAIL: the peer must reach access.json's allowFrom: $(jq -c . "$R5/five/access.json")"; exit 1; }
echo "ok: --mode to dev-manager also asks the peers question and records a peer in peers.json and access.json's allowFrom"

# A group whose allowFrom is not a list (a hand edit) is left as it is: it must not stop the other groups from getting their peers
# (jq failed on it and "could not update ... leaving it alone" kept all of them from it). And the bot is left out of the peers by its
# bot-id when it is kept: a peer named five with another id (702) is a peer.
cp "$R5/five/access.json" "$P5/five.access.keep"; cp "$(pstate "$P5")/peers.json" "$P5/five.peers.keep"
jq -c '.groups["2"] = {allowFrom: "111 222"} | .groups["3"] = {allowFrom: ["222"]} | .groups["4"] = 7' "$P5/five.access.keep" > "$R5/five/access.json"
printf '900\n' > "$R5/five/bot-id"
out=$(printf 'dev-manager\nperty:701:801:host,five:702:802:host,perta:900:803:host\n' | bash "$S" setup five --mode 2>&1) || :
[ "$(jq -c '.groups["3"].allowFrom, .groups["1"].allowFrom, .groups["2"].allowFrom, .groups["4"]' "$R5/five/access.json" | tr '\n' ' ')" = '["222","700","701","702"] ["222","700","701","702"] "111 222" 7 ' ] ||
  { echo "FAIL: the peers (not the bot's own id 900) must go into every list group while a group whose allowFrom is a string or a number stays as it is: $(jq -c .groups "$R5/five/access.json") / $out"; exit 1; }
rm -f "$R5/five/bot-id"; cp "$P5/five.access.keep" "$R5/five/access.json"; cp "$P5/five.peers.keep" "$(pstate "$P5")/peers.json"; rm -f "$P5/five.access.keep" "$P5/five.peers.keep"
echo "ok: setup's peer merge skips a group whose allowFrom is no list and still adds the peers to the others, and leaves the bot out by its bot-id"

# setup installs the plugin. Fixtures: XP (git, path with a space, trusted), refusals leave the bot untouched.
XP="$HOME/scope proj"; XR=$(broot "$XP"); XL="$XP/.claude/skills/claude-discord"; GL="$HOME/.claude/skills/claude-discord"
mkdir -p "$XP"; (cd "$XP" && git init -q .)
jq -n --arg p "$PHOME/scope proj" '{projects: {($p): {hasTrustDialogAccepted: true}}, other: 1}' > "$HOME/.claude.json"
# link: the project path is a symlink to the one source; second project shares it; the install stays out of git status, is recorded, and the shim is installed.
(cd "$XP" && printf '900\n111\n\ntokS\nn\n' | bash "$S" setup xbot --scope project --method link >/dev/null) || { echo "FAIL: setup --scope project --method link failed"; exit 1; }
[ "$(readlink "$XL")" = "$HOME/.claude-discord/source" ] || { echo "FAIL: link method must link to the source clone"; exit 1; }
[ "$(git -C "$XP" status --porcelain --untracked-files=all | grep -c 'skills/claude-discord')" = 0 ] && grep -qxF '/.claude/skills/claude-discord' "$XP/.git/info/exclude" || { echo "FAIL: the link must be excluded from the project's git"; exit 1; }
cmp -s "$D/shim/claude-discord" "$HOME/.local/bin/claude-discord" || { echo "FAIL: setup must install the shim"; exit 1; }
grep -qxF "$XL" "$HOME/.claude-discord/records/installs" || { echo "FAIL: setup must record the install"; exit 1; }
# A re-run with no flags keeps the link and asks nothing (the extra 'global' line would be taken by a scope question), refreshes a stale shim, keeps one exclude line.
echo stale > "$HOME/.local/bin/claude-discord"
out=$(cd "$XP" && printf '\nn\n\nglobal\n' | bash "$S" setup xbot 2>&1) || { echo "FAIL: a re-run in an installed project must succeed without a question: $out"; exit 1; }
[ "$(readlink "$XL")" = "$HOME/.claude-discord/source" ] && grep -q 'already installed at' <<<"$out" && [ ! -e "$GL" ] || { echo "FAIL: a re-run must keep the install and ask nothing: $out"; exit 1; }
cmp -s "$D/shim/claude-discord" "$HOME/.local/bin/claude-discord" && [ "$(grep -c 'skills/claude-discord' "$XP/.git/info/exclude")" = 1 ] || { echo "FAIL: a re-run must refresh the shim and keep a single exclude line"; exit 1; }
# Refusals and bad flags decide before anything is written: no new bot dir, and --reset deletes nothing.
mkdir -p "$GL"
out=$(cd "$XP" && printf '\nn\n' | bash "$S" setup rbot --scope project 2>&1) && { echo "FAIL: a global copy beside a project copy must be refused"; exit 1; }
grep -q "already installed globally" <<<"$out" && [ ! -e "$XR/rbot" ] || { echo "FAIL: wrong or late refusal ($(ls "$XR")): $out"; exit 1; }
rmdir "$GL"
out=$(cd "$XP" && printf '\nn\n' | bash "$S" setup xbot --reset --scope global --method clone 2>&1) && { echo "FAIL: a global clone beside a project copy must be refused"; exit 1; }
grep -q "already installed for this project" <<<"$out" && [ -f "$XR/xbot/.env" ] || { echo "FAIL: wrong or late refusal, --reset must not run: $out"; exit 1; }
# A new global copy would shadow every recorded project install (the global one wins), so it is refused naming one.
mkdir -p "$HOME/gr proj"
out=$(cd "$HOME/gr proj" && printf '\nn\n' | bash "$S" setup grbot --scope global --method clone 2>&1) && { echo "FAIL: a global clone beside another project's install must be refused"; exit 1; }
grep -q "a project install exists at .*claude/skills/claude-discord" <<<"$out" && [ ! -e "$HOME/gr proj/.claude/discord-agents/grbot" ] && [ ! -e "$GL" ] || { echo "FAIL: wrong or late refusal: $out"; exit 1; }
rm -rf "$HOME/gr proj"
rc=0; (cd "$XP" && printf 'dev-manager\n\n' | bash "$S" setup xbot --mode --scope project >/dev/null 2>&1) || rc=$?
[ "$rc" = 2 ] && [ "$(<"$XR/xbot/mode")" = none ] || { echo "FAIL: --mode with --scope must be refused before the mode is written, rc=$rc"; exit 1; }
for bad in "--scope bogus" "--method bogus" "--scope" "--method"; do
  # shellcheck disable=SC2086
  rc=0; (cd "$XP" && printf '\nn\n' | bash "$S" setup rbot $bad >/dev/null 2>&1) || rc=$?
  [ "$rc" = 2 ] && [ ! -e "$XR/rbot" ] || { echo "FAIL: 'setup rbot $bad' must exit 2 and write nothing, rc=$rc"; exit 1; }
done
# Trust: reported, never written unasked, written (other keys kept) on an explicit y. Answered n, the plugin
# will not load, so the old settings hooks and rule file must stay (setup never removes them).
jq -n '{projects: {}, other: 1}' > "$HOME/.claude.json"
mkdir -p "$XP/.claude/rules"; : > "$XP/.claude/rules/claude-discord-dev-manager.md"; echo '{}' > "$XP/.claude/settings.local.json"; plant_old "$XP/.claude/settings.local.json"; cp "$XP/.claude/settings.local.json" "$HOME/xsl.before"
out=$(cd "$XP" && printf '\n\nn\n' | bash "$S" setup xbot 2>&1)
grep -q 'not trusted' <<<"$out" && [ "$(jq -r --arg p "$PHOME/scope proj" '.projects[$p] | if . == null then "unset" else "set" end' "$HOME/.claude.json")" = unset ] || { echo "FAIL: setup must say the project is not trusted and write nothing: $out"; exit 1; }
cmp -s "$XP/.claude/settings.local.json" "$HOME/xsl.before" && [ -e "$XP/.claude/rules/claude-discord-dev-manager.md" ] || { echo "FAIL: with trust answered n, setup must remove no old hook and no rule file"; exit 1; }
rm -rf "$XP/.claude/rules" "$XP/.claude/settings.local.json" "$HOME/xsl.before"
(cd "$XP" && printf 'y\n\nn\n' | bash "$S" setup xbot >/dev/null 2>&1)
[ "$(jq -r --arg p "$PHOME/scope proj" '.projects[$p].hasTrustDialogAccepted' "$HOME/.claude.json")" = true ] && [ "$(jq -r .other "$HOME/.claude.json")" = 1 ] || { echo "FAIL: an explicit y must write trust and keep other keys"; exit 1; }
# Reached through a symlink, the project is trusted by its physical path; a dangling install link is replaced.
ln -s "$XP" "$HOME/xp link"; ln -sfn "$HOME/nowhere" "$XL"
out=$(cd "$HOME/xp link" && printf '\n\nn\n\n' | bash "$S" setup xbot 2>&1)
! grep -q 'not trusted' <<<"$out" || { echo "FAIL: trust must be read by the physical path: $out"; exit 1; }
[ "$(readlink "$XL")" = "$HOME/.claude-discord/source" ] || { echo "FAIL: a dangling install link must be replaced: $out"; exit 1; }
rm -f "$HOME/xp link"
# clone + global, then a second bot elsewhere uses the global install on Enter (no refusal, no project copy); --mode installs nothing.
rm -rf "$XP"
GP="$HOME/g proj"; GP2="$HOME/g proj2"; mkdir -p "$GP" "$GP2"
# A global install is refused while a project install is recorded: park the records for this part, put them back after.
RECS=$HOME/.claude-discord/records/installs; cp "$RECS" "$HOME/installs.parked"; : > "$RECS"
(cd "$GP" && printf '900\n111\n\ntokG\nn\n' | bash "$S" setup gbot --scope global --method clone >/dev/null) || { echo "FAIL: setup --scope global --method clone failed"; exit 1; }
[ -d "$GL/.git" ] && [ ! -L "$GL" ] && [ ! -e "$GP/.claude/skills" ] || { echo "FAIL: global clone must be a real clone at ~/.claude/skills and leave the project alone"; exit 1; }
# Run the clone's own wrapper: it is the one whose self_root is the clone.
(cd "$GP" && printf '\nn\n' | bash "$GL/bin/claude-discord" setup gbot >/dev/null 2>&1) || { echo "FAIL: a re-run of the global clone's own wrapper failed"; exit 1; }
(cd "$GP2" && printf '900\n111\n\ntokG2\nn\n\nproject\n' | bash "$S" setup gbot2 >/dev/null 2>&1) || { echo "FAIL: a second bot on a globally installed machine must not be refused"; exit 1; }
[ ! -e "$GP2/.claude/skills" ] || { echo "FAIL: with a global install the project must get no copy"; exit 1; }
rm -rf "$GL"
{ cat "$HOME/installs.parked" "$RECS"; } | awk '!seen[$0]++' > "$RECS.new" && mv "$RECS.new" "$RECS" && rm -f "$HOME/installs.parked"
(cd "$GP2" && printf 'none\n' | bash "$S" setup gbot2 --mode >/dev/null)
[ ! -e "$GL" ] && [ ! -e "$GP2/.claude/skills" ] || { echo "FAIL: setup --mode must install nothing"; exit 1; }
# A project in a subdirectory of a repo, and in a git worktree of it, is excluded with the right path.
SG="$HOME/sg repo"; mkdir -p "$SG/sub"; (cd "$SG" && git init -q . && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m e && git worktree add -q -b sgwt "$HOME/sg wt")
for w in "$SG/sub" "$HOME/sg wt"; do
  (cd "$w" && printf '\n900\n111\n\ntokW\nn\n' | bash "$S" setup wb --scope project --method link >/dev/null 2>&1) || { echo "FAIL: setup in $w failed"; exit 1; }
  [ "$(git -C "$w" status --porcelain --untracked-files=all | grep -c 'skills/claude-discord')" = 0 ] || { echo "FAIL: the install in $w must be ignored by git"; exit 1; }
done
grep -qxF '/sub/.claude/skills/claude-discord' "$SG/.git/info/exclude" || { echo "FAIL: a subdirectory project needs its prefix in the exclude pattern"; exit 1; }
echo "ok: setup installs the plugin as a link or a clone at project or global scope, asks nothing when an install exists, refuses the other scope and bad flags before writing, excludes it in subdirectories and worktrees, records it, and writes trust only on y"

# install: the plugin, shim and runtime, asking nothing (stdin is left unread) and writing no bot
# file; a re-run is the same. A setup whose clone fails writes no bot file: the install comes before the questions.
IP="$HOME/inst proj"; FP="$HOME/fail proj"; mkdir -p "$IP" "$FP"
jq --arg p "$PHOME/inst proj" '.projects[$p].hasTrustDialogAccepted = true' "$HOME/.claude.json" > "$HOME/cj.tmp" && mv "$HOME/cj.tmp" "$HOME/.claude.json"
for _ in 1 2; do
  rc=0; left=$(printf 'leftover\n' | { (cd "$IP" && bash "$S" install --scope project --method link >"$HOME/inst.out" 2>&1) || rc=$?; cat; })
  [ "$rc" = 0 ] && [ "$left" = leftover ] && [ "$(readlink "$IP/.claude/skills/claude-discord")" = "$HOME/.claude-discord/source" ] && [ ! -e "$IP/.claude/discord-agents" ] || { echo "FAIL: install must install, read nothing from stdin and write no bot file (rc=$rc, left=$left): $(<"$HOME/inst.out")"; exit 1; }
done
grep -qxF "$IP/.claude/skills/claude-discord" "$HOME/.claude-discord/records/installs" && cmp -s "$D/shim/claude-discord" "$HOME/.local/bin/claude-discord" && [ ! -e "$HOME/.claude-discord/compat" ] && [ ! -e "$HOME/.claude-discord/hooks" ] || { echo "FAIL: install must record the install, refresh the shim and leave no compat copy"; exit 1; }
# install ends with one patch of the official plugin cache: an install then /reload-plugins with no bot start must
# find .mcp.json and server.ts patched. A version dir whose pattern moved warns on stderr and leaves the install at rc 0.
for v in 0.0.20 0.0.21; do mkdir -p "$PCACHE/$v"; done
cp "$HOME/server.ts.pristine" "$PCACHE/0.0.20/server.ts"; printf 'nothing to patch here\n' > "$PCACHE/0.0.21/server.ts"
printf '{"mcpServers":{"discord":{"command":"bun"}}}\n' > "$PCACHE/0.0.20/.mcp.json"
rc=0; (cd "$IP" && bash "$S" install >"$HOME/inst.out" 2>"$HOME/inst.err") || rc=$?
[ "$rc" = 0 ] && [ "$(jq -r '.mcpServers.discord.env.CLAUDE_DISCORD_BOT' "$PCACHE/0.0.20/.mcp.json")" = '${DISCORD_STATE_DIR:-}' ] && grep -q 'ignoreEveryone: true' "$PCACHE/0.0.20/server.ts" && grep -qF "$PCACHE/0.0.20/.mcp.json" "$HOME/inst.out" &&
  grep -q '^claude-discord: some patches no longer apply' "$HOME/inst.err" || { echo "FAIL: install must patch the official plugin cache and survive a patch that no longer applies (rc=$rc): $(<"$HOME/inst.out") $(<"$HOME/inst.err")"; exit 1; }
rm -rf "$PCACHE/0.0.20" "$PCACHE/0.0.21" "$HOME/inst.err"
# No flags, an untrusted project: still no stdin read (no scope, method or trust question), a hint instead; </dev/null too.
UI="$HOME/untrusted inst"; mkdir -p "$UI"
rc=0; left=$(printf 'l1\nl2\nl3\nl4\n' | { (cd "$UI" && bash "$S" install >"$HOME/inst.out" 2>&1) || rc=$?; cat; })
[ "$rc" = 0 ] && [ "$left" = "$(printf 'l1\nl2\nl3\nl4')" ] && [ "$(readlink "$UI/.claude/skills/claude-discord")" = "$HOME/.claude-discord/source" ] && grep -q 'not trusted' "$HOME/inst.out" && grep -q "answer y in 'claude-discord setup <bot>'" "$HOME/inst.out" ||
  { echo "FAIL: install with no flags in an untrusted project must read none of 4 piped lines and print the trust hint (rc=$rc, left=$left): $(<"$HOME/inst.out")"; exit 1; }
[ "$(jq -r --arg p "$PHOME/untrusted inst" '.projects[$p] | if . == null then "unset" else "set" end' "$HOME/.claude.json")" = unset ] || { echo "FAIL: install must not write trust"; exit 1; }
rc=0; (cd "$UI" && bash "$S" install </dev/null >/dev/null 2>&1) || rc=$?
[ "$rc" = 0 ] || { echo "FAIL: install </dev/null must succeed, rc=$rc"; exit 1; }
rm -rf "$UI"
rc=0; (cd "$IP" && bash "$S" install bogus >/dev/null 2>&1) || rc=$?
[ "$rc" = 2 ] || { echo "FAIL: install takes only --scope and --method, rc=$rc"; exit 1; }
GW="$HOME/gitwrap"; mkdir -p "$GW"
printf '#!/bin/bash\necho "${GIT_TERMINAL_PROMPT:-unset} $(ps -o comm= -p $PPID) $1" >> "%s/log"\nexec %s "$@"\n' "$GW" "$(command -v git)" > "$GW/git"; chmod +x "$GW/git"
rc=0; out=$(cd "$FP" && printf '900\n111\n\ntokF\nn\n' | PATH="$GW:$PATH" CLAUDE_DISCORD_REPO="$HOME/no such repo" bash "$S" setup fbot --scope project --method clone 2>&1) || rc=$?
[ "$rc" != 0 ] && grep -q 'could not clone' <<<"$out" && [ ! -e "$FP/.claude/discord-agents" ] || { echo "FAIL: a failed clone must stop setup before any bot file (rc=$rc): $out $(find "$FP")"; exit 1; }
! command -v timeout >/dev/null || grep -q '^0 timeout clone$' "$GW/log" || { echo "FAIL: a clone must run with GIT_TERMINAL_PROMPT=0 under timeout: $(<"$GW/log")"; exit 1; }
rm -rf "$GW"
rm -rf "$IP" "$FP" "$HOME/inst.out"
echo "ok: install installs and refreshes (twice), patches the official plugin cache once (a patch that no longer applies only warns), reading no stdin at all (no flags and untrusted too: a trust hint instead) and writing no bot file, refuses other words; a setup whose clone fails writes no bot file, and git runs with no prompt under a timeout"

# Scopes: a bot in $HOME is a global install (its .claude is ~/.claude); a project link and the global link to
# the one source coexist (one code, loaded once); a clone on either side beside another install is refused.
mkdir -p "$HOME/.claude"
rc=0; out=$(cd "$HOME" && printf '900\n111\n\ntokH\nn\n' | bash "$S" setup hbot --method link 2>&1) || rc=$?
[ "$rc" = 0 ] && grep -q 'this project is \$HOME' <<<"$out" && [ "$(readlink "$GL")" = "$HOME/.claude-discord/source" ] && [ -f "$(bdir "$HOME" "hbot")/.env" ] || { echo "FAIL: a bot in \$HOME must install globally, saying so (rc=$rc): $out"; exit 1; }
CO="$HOME/co proj"; mkdir -p "$CO"
jq --arg p "$PHOME/co proj" '.projects[$p].hasTrustDialogAccepted = true' "$HOME/.claude.json" > "$HOME/cj.tmp" && mv "$HOME/cj.tmp" "$HOME/.claude.json"
rc=0; out=$(cd "$CO" && printf '900\n111\n\ntokC\nn\n' | bash "$S" setup cobot --scope project 2>&1) || rc=$?
[ "$rc" = 0 ] && [ "$(readlink "$CO/.claude/skills/claude-discord")" = "$HOME/.claude-discord/source" ] && [ -L "$GL" ] || { echo "FAIL: a project link beside the global link must be allowed, as a link (rc=$rc): $out"; exit 1; }
rm -f "$CO/.claude/skills/claude-discord"
rc=0; out=$(cd "$CO" && printf '\nn\n' | bash "$S" setup cobot --scope project --method clone 2>&1) || rc=$?
[ "$rc" = 2 ] && grep -q 'already installed globally' <<<"$out" && [ ! -e "$CO/.claude/skills/claude-discord" ] || { echo "FAIL: a project clone beside the global link must be refused (rc=$rc): $out"; exit 1; }
rm -f "$GL"; rm -rf "$CO" "$(pstate "$HOME")"
echo "ok: a bot in \$HOME installs globally and says so; a project link and the global link coexist; a clone beside another install is refused"

# --version and update. UP is a project linked to the source (so are the earlier projects the records still hold), UC a clone-method install.
UP="$HOME/up proj"; UC="$HOME/up clone"; mkdir -p "$UP" "$UC"; for w in "$UP" "$UC"; do (cd "$w" && git init -q .); done
jq -n --arg a "$PHOME/up proj" --arg c "$PHOME/up clone" '{projects: {($a): {hasTrustDialogAccepted: true}, ($c): {hasTrustDialogAccepted: true}}}' > "$HOME/.claude.json"
(cd "$UP" && printf '\n900\n111\n\ntokU\nn\n' | bash "$S" setup ubot --scope project >/dev/null)
(cd "$UC" && printf '900\n111\n\ntokU\nn\n' | bash "$S" setup ubot --scope project --method clone >/dev/null)
C="$UP/.claude/skills/claude-discord"; CC="$UC/.claude/skills/claude-discord"
[ -L "$C" ] && [ ! -L "$CC" ] || { echo "FAIL: fixture: the default method links, --method clone does not"; exit 1; }
v=$(cd "$UP" && bash "$C/bin/claude-discord" --version)
grep -qE '^claude-discord [0-9]+\.[0-9]+\.[0-9]+ \([0-9a-f]{7,}\)$' <<<"$v" && [[ $v == *"($(git -C "$PC" rev-parse --short HEAD))" ]] || { echo "FAIL: --version through a link must print the version and the source's sha: $v"; exit 1; }
# The upstream moves: a new commit in the stand-in repo, with a new plugin version.
# The pulled commit also changes what the patch verb prints, so the test can tell the pulled patch code from the code update was started with.
jq '.version = "9.9.9"' "$SRC/.claude-plugin/plugin.json" > "$SRC/p.json" && mv "$SRC/p.json" "$SRC/.claude-plugin/plugin.json" &&
  sed -i 's/^if \[ "\${1:-}" = patch \]; then$/& echo PATCH-CODE-V2 >\&2/' "$SRC/bin/lib/patch.sh" && grep -q PATCH-CODE-V2 "$SRC/bin/lib/patch.sh" &&
  git -C "$SRC" -c user.email=t@t -c user.name=t commit -qam bump || { echo "FAIL: could not bump the stand-in repo"; exit 1; }
rm -rf "$HOME/.claude-discord/runtime"; echo stale > "$HOME/.local/bin/claude-discord"
out=$(cd "$UP" && bash "$C/bin/claude-discord" update 2>&1) || { echo "FAIL: update failed: $out"; exit 1; }
grep -q PATCH-CODE-V2 <<<"$out" || { echo "FAIL: update must run the patch step from the code it just pulled: $out"; exit 1; }
grep -q -- '-> 9.9.9' <<<"$out" && grep -q '/reload-plugins' <<<"$out" && [ "$(grep -c -- "$PC" <<<"$out")" = 1 ] || { echo "FAIL: update must pull the source behind the link once and ask for /reload-plugins: $out"; exit 1; }
# 1.18.5: the advice works on a machine without the owner's dotfiles: the self-reload skill ships in the plugin
# (skills/self-reload, SKILL.md + scripts/self_cmd.py executable) and the line also names the no-skill ways.
[ -f "$PC/skills/self-reload/SKILL.md" ] && [ -x "$PC/skills/self-reload/scripts/self_cmd.py" ] || { echo "FAIL: the plugin ships the self-reload skill (skills/self-reload/SKILL.md, scripts/self_cmd.py executable): $(ls -R "$PC/skills" 2>&1 | head -5)"; exit 1; }
grep -q "run /reload-plugins in running sessions (a bot: the plugin's self-reload skill; by hand: type /reload-plugins in that session, or claude-discord bot <bot> recover from another shell)" <<<"$out" || { echo "FAIL: update's last line names the shipped skill and the by-hand ways: $out"; exit 1; }
[ "$(jq -r .version "$PC/.claude-plugin/plugin.json")" = 9.9.9 ] && [ "$(jq -r .version "$CC/.claude-plugin/plugin.json")" != 9.9.9 ] || { echo "FAIL: update must pull the source and only the source"; exit 1; }
[ -s "$HOME/.claude-discord/runtime/discord-chunk.ts" ] && [ -s "$HOME/.claude-discord/runtime/discord-proxy.ts" ] && cmp -s "$D/shim/claude-discord" "$HOME/.local/bin/claude-discord" || { echo "FAIL: update must refill the runtime copy and refresh the shim"; exit 1; }
# --all: every recorded link and the clone, the source pulled once, a project removed since setup pruned, live records kept.
git -C "$SRC" -c user.email=t@t -c user.name=t commit -q --allow-empty -m again
printf '%s\n' "$HOME/gone proj/.claude/skills/claude-discord" >> "$HOME/.claude-discord/records/installs"
links=0; while IFS= read -r r; do [ "$(cd -P "$r" 2>/dev/null && pwd -P)" != "$PC" ] || links=$((links + 1)); done < "$HOME/.claude-discord/records/installs"
[ "$links" -ge 3 ] || { echo "FAIL: fixture: the records should hold several links to the source, got $links"; exit 1; }
out=$(cd "$UP" && bash "$C/bin/claude-discord" update --all 2>&1) || { echo "FAIL: update --all failed: $out"; exit 1; }
[ "$(grep -c -- "$PC" <<<"$out")" = 1 ] && [ "$(grep -c -- "$CC" <<<"$out")" = 1 ] && [ "$(grep -c -- ' -> ' <<<"$out")" = 2 ] || { echo "FAIL: update --all must pull each real clone once: $out"; exit 1; }
[ "$(git -C "$CC" rev-parse HEAD)" = "$(git -C "$SRC" rev-parse HEAD)" ] && ! grep -qF 'gone proj' "$HOME/.claude-discord/records/installs" && [ "$(wc -l < "$HOME/.claude-discord/records/installs" | tr -d ' ')" = "$((links + 1))" ] || { echo "FAIL: update --all must update the clone install, prune the removed project and keep the others"; exit 1; }
# A clone that cannot fast-forward is reported with exit 1 and does not stop the others.
git -C "$CC" -c user.email=t@t -c user.name=t commit -q --allow-empty -m local
git -C "$SRC" -c user.email=t@t -c user.name=t commit -q --allow-empty -m remote
div=$(git -C "$CC" rev-parse HEAD)
rc=0; out=$(cd "$UP" && bash "$C/bin/claude-discord" update --all 2>&1) || rc=$?
[ "$(git -C "$CC" rev-parse HEAD)" = "$div" ] && [ -z "$(git -C "$CC" status --porcelain)" ] || { echo "FAIL: a failed pull must leave the clone as it was"; exit 1; }
[ "$rc" = 1 ] && grep -q "$CC: pull failed" <<<"$out" && [ "$(git -C "$PC" rev-parse HEAD)" = "$(git -C "$SRC" rev-parse HEAD)" ] || { echo "FAIL: a diverged clone must exit 1, named, after the others were pulled (rc=$rc): $out"; exit 1; }
# A shim that cannot be refreshed is reported with exit 1 on its own.
git -C "$CC" reset -q --hard '@{u}'
echo stale > "$HOME/.local/bin/claude-discord"; chmod 555 "$HOME/.local/bin"
rc=0; out=$(cd "$UP" && bash "$C/bin/claude-discord" update --all 2>&1) || rc=$?
chmod 755 "$HOME/.local/bin"
[ "$rc" = 1 ] && grep -q 'could not install the shim' <<<"$out" && ! grep -q 'pull failed' <<<"$out" || { echo "FAIL: an unwritable shim must exit 1 with a message (rc=$rc): $out"; exit 1; }
# A clone pinned to a tag or sha (detached HEAD) is skipped by name and is not a failure; the others are still pulled.
git -C "$CC" checkout -q --detach; pin=$(git -C "$CC" rev-parse HEAD)
git -C "$SRC" -c user.email=t@t -c user.name=t commit -q --allow-empty -m after-pin
rc=0; out=$(cd "$UP" && bash "$C/bin/claude-discord" update --all 2>&1) || rc=$?
[ "$rc" = 0 ] && grep -q "$CC: pinned at ${pin:0:7}, skipped" <<<"$out" && [ "$(git -C "$CC" rev-parse HEAD)" = "$pin" ] && [ "$(git -C "$PC" rev-parse HEAD)" = "$(git -C "$SRC" rev-parse HEAD)" ] || { echo "FAIL: a detached clone must be skipped without failing the run (rc=$rc): $out"; exit 1; }
bash "$C/bin/claude-discord" update --bogus >/dev/null 2>&1 && { echo "FAIL: update takes only --all"; exit 1; }
# Pulled code older than the compat copy (1.8.0) would read 'compat' as a bot name: skipped with a line.
jq '.version = "1.7.9"' "$SRC/.claude-plugin/plugin.json" > "$SRC/p.json" && mv "$SRC/p.json" "$SRC/.claude-plugin/plugin.json" && git -C "$SRC" -c user.email=t@t -c user.name=t commit -qam old-version
rm -rf "$HOME/.claude-discord/compat"
rc=0; out=$(cd "$UP" && bash "$C/bin/claude-discord" update 2>&1) || rc=$?
[ "$rc" = 0 ] && grep -q 'before the compat step (1.8.0)' <<<"$out" && [ ! -e "$HOME/.claude-discord/compat" ] || { echo "FAIL: update must skip compat from code before 1.8.0, with a line (rc=$rc): $out"; exit 1; }
rm -rf "$UP" "$UC"
echo "ok: --version prints the version and the clone's sha (a link's is the source's); update pulls the source behind a link once, runs the pulled commit's patch step, refills the runtime copy and the shim and asks for /reload-plugins; --all pulls each real clone once, prunes a removed project, skips a detached (pinned) clone without failing, and exits 1 on a diverged clone (left as it was) or an unwritable shim"

# --- the state move (1.18.0): a project's state lives in ~/.claude-discord/projects/<key>/ ------------------------------
# (a) the key is Claude Code's project folder name: every non-alphanumeric byte a dash, in the C locale (a table from lmd79).
pk() { bash -c '. "$1/bin/lib/state.sh"; proj_key "$2"' _ "$PC" "$1" 2>/dev/null; }
[ "$(pk /home/d.kim4)" = -home-d-kim4 ] && [ "$(pk /home/d.kim4/projects/my_dotfiles)" = -home-d-kim4-projects-my-dotfiles ] &&
  [ "$(pk /home/d.kim4/projects/hoi_trigger_codebase/.claude/worktrees/hoi-v2-pr)" = -home-d-kim4-projects-hoi-trigger-codebase--claude-worktrees-hoi-v2-pr ] &&
  [ "$(pk /home/d.kim4/projects/RobustAlwaysOn)" = -home-d-kim4-projects-RobustAlwaysOn ] && [ "$(pk /tmp)" = -tmp ] && [ "$(pk '/a b/c.d')" = -a-b-c-d ] &&
  [ "$(pk /x/a_b)" = -x-a-b ] && [ "$(pk /x/a.b)" = -x-a-b ] && [ "$(skey '/a b/c.d')" = -a-b-c-d ] ||
  { echo "FAIL: the key is Claude Code's folder encoding: every non-alphanumeric byte a dash: '$(pk /home/d.kim4)' '$(pk '/a b/c.d')' '$(pk /x/a_b)'"; exit 1; }
echo "ok: proj_key (bin/lib/state.sh) is Claude Code's project folder name: every non-alphanumeric byte a dash, in the C locale; a_b and a.b share one"
# (b) setup in a fresh project: the new layout, modes 700, nothing under the project's .claude but the install; the
# launcher's --settings names the new state dir.
NPJ="$HOME/new proj"; CA="$HOME/x/a_b"; CB2="$HOME/x/a.b"; mkdir -p "$NPJ" "$CA" "$CB2"
jq --arg a "$NPJ" --arg b "$CA" '.projects[$a].hasTrustDialogAccepted = true | .projects[$b].hasTrustDialogAccepted = true' "$HOME/.claude.json" > "$HOME/cj.tmp" && mv "$HOME/cj.tmp" "$HOME/.claude.json"
NS="$HOME/.claude-discord/projects/$(skey "$NPJ")"
(cd "$NPJ" && printf '\n4242\n111\n\ntokN\nn\n' | bash "$S" setup nbot --scope project >/dev/null 2>&1) || { echo "FAIL: setup in a fresh project failed"; exit 1; }
[ "$(cat "$NS/project" 2>/dev/null)" = "$NPJ" ] && grep -q "^DISCORD_CHANNEL_ID='4242'$" "$NS/config.env" && grep -q '^DISCORD_BOT_TOKEN=tokN$' "$NS/bots/nbot/.env" &&
  [ "$(jq -r '.groups["4242"].requireMention' "$NS/bots/nbot/access.json")" = true ] && [ "$(<"$NS/bots/nbot/mode")" = none ] &&
  [ "$(stat -c %a "$NS")" = 700 ] && [ "$(stat -c %a "$NS/bots")" = 700 ] && [ "$(stat -c %a "$NS/bots/nbot")" = 700 ] &&
  [ ! -e "$NPJ/.claude/discord-agents" ] && [ "$(ls -A "$NPJ/.claude")" = skills ] ||
  { echo "FAIL: setup and the start keep every bot file under ~/.claude-discord/projects/<key>, none under the project's .claude: $(find "$NPJ/.claude" "$NS" 2>&1)"; exit 1; }
out=$(cd "$NPJ" && bash "$S" --name nbot 2>&1)
grep -qF -- "\"DISCORD_STATE_DIR\": \"$NS/bots/nbot\"" <<<"$out" && [ ! -e "$NPJ/.claude/discord-agents" ] ||
  { echo "FAIL: setup and the start keep every bot file under ~/.claude-discord/projects/<key>, none under the project's .claude: the launcher must name the new state dir: $out"; exit 1; }
echo "ok: setup in a fresh project writes ~/.claude-discord/projects/<key>/{project,config.env,bots/<bot>} (700) and nothing under the project's .claude but the install; the start's --settings names it"
# (c) two paths with one key (a_b and a.b): the second setup is refused, naming both, and writes no bot file.
CK="$HOME/.claude-discord/projects/$(skey "$CB2")"; mkdir -p "$CK"; printf '%s\n' "$CB2" > "$CK/project"
rc=0; out=$(cd "$CA" && printf '\n1\n2\n\nt\nn\n' | bash "$S" setup cbot --scope project 2>&1) || rc=$?
[ "$rc" = 1 ] && grep -qF "$CA" <<<"$out" && grep -qF "$CB2" <<<"$out" && grep -q 'share one' <<<"$out" && [ "$(ls -A "$CK")" = project ] && [ ! -e "$CA/.claude/discord-agents" ] ||
  { echo "FAIL: two paths with one key: setup refuses the second (rc=$rc): $out / $(ls -A "$CK")"; exit 1; }
echo "ok: two projects whose paths share one key: setup refuses the second, naming both, and writes no bot file"
# (M-3) The collision must not keep a bot of the second project down: a start there says it and launches on the old path.
mkdir -p "$CA/.claude/discord-agents/cbot"; printf 'DISCORD_BOT_TOKEN=tc\n' > "$CA/.claude/discord-agents/cbot/.env"; echo none > "$CA/.claude/discord-agents/cbot/mode"; echo '{}' > "$CA/.claude/discord-agents/cbot/access.json"
printf "DISCORD_CHANNEL_ID='7'\nDISCORD_USER_ID='8'\nDISCORD_ALLOW_IDS=''\n" > "$CA/.claude/discord-agents/config.env"
out=$(cd "$CA" && bash "$S" --name cbot 2>&1) || :
grep -q 'share one' <<<"$out" && grep -qF -- "\"DISCORD_STATE_DIR\": \"$CA/.claude/discord-agents/cbot\"" <<<"$out" && [ -d "$CA/.claude/discord-agents/cbot" ] && [ ! -L "$CA/.claude/discord-agents/cbot" ] ||
  { echo "FAIL: a key collision must not stop a bot of the second project: the start says it and launches on the old path: $out"; exit 1; }
echo "ok: a start in a project whose key another project holds says so and launches on the old path (setup alone refuses)"
# (d) a project of the old shape (<project>/.claude/discord-agents/) with two bots, moved by compat: every bot dir by
# rename (same inode), config.env, peers.json and checkin/ with it, a link per bot whose old path a job record names, the
# hooks link gone, the .gitignore kept, a manager's records/monitor and scratch moved under the key (1.18.1; the backend
# stopped by its owner stays stopped; scratch/ob1 left as a link, which nothing removes), the
# records/projects list renamed .1.16 (its one line has a key dir now), and a second run changing nothing.
OLDP="$HOME/old shape"; OR="$OLDP/.claude/discord-agents"; mkdir -p "$OR/ob1/turns" "$OR/ob2/plugin-sessions" "$OR/checkin"
printf "DISCORD_CHANNEL_ID='7'\nDISCORD_USER_ID='8'\nDISCORD_ALLOW_IDS=''\n" > "$OR/config.env"; echo '{"peers":[]}' > "$OR/peers.json"; : > "$OR/checkin/s1"
printf 'DISCORD_BOT_TOKEN=t1\n' > "$OR/ob1/.env"; echo dev-manager > "$OR/ob1/mode"; printf '# ledger\nlocal\n' > "$OR/ob1/hosts"; echo '{}' > "$OR/ob1/access.json"; : > "$OR/ob1/turns/t1"
printf 'DISCORD_BOT_TOKEN=t2\n' > "$OR/ob2/.env"; echo none > "$OR/ob2/mode"; : > "$OR/ob2/plugin-sessions/p1"; printf '*\n' > "$OR/.gitignore"; ln -s "$PC/hooks" "$OR/hooks"
chmod 700 "$OR" "$OR/ob1" "$OR/ob2"; chmod 600 "$OR/ob1/.env" "$OR/ob2/.env"
MON1="$HOME/.claude-discord/records/monitor/ob1" SCR1="$HOME/.claude-discord/scratch/ob1"; mkdir -p "$MON1" "$SCR1"; : > "$SCR1/f"; : > "$MON1/stopped"
cp -a "$OR" "$HOME/old-shape.ref"; i1=$(stat -c %i "$OR/ob1"); i2=$(stat -c %i "$OR/ob2")
JOBS="$HOME/.claude/jobs"; mkdir -p "$JOBS/mv000001" "$JOBS/mv000002"
jq -n --arg s "{\"env\": {\"DISCORD_STATE_DIR\": \"$OR/ob1\"}}" '{sessionId: "0b100000-1111-2222-3333-444444444444", respawnFlags: ["--settings", $s]}' > "$JOBS/mv000001/state.json"
jq -n --arg s "{\"env\": {\"DISCORD_STATE_DIR\": \"$OR/ob2\"}}" '{sessionId: "0b200000-1111-2222-3333-444444444444", respawnFlags: ["--settings", $s]}' > "$JOBS/mv000002/state.json"
OPF=$HOME/.claude-discord/records/projects; printf '%s\n' "$OLDP" > "$OPF"   # the 1.16 list (nothing writes it since 1.18.1)
cp "$HOME/bin/claude" "$HOME/claude.before-move"; printf '#!/bin/bash\ncase $1 in agents) echo "[]";; *) echo "PLAIN $*";; esac\n' > "$HOME/bin/claude"   # no session of any bot runs
out=$(cd "$HOME" && bash "$S" compat 2>&1) || { echo "FAIL: compat failed: $out"; exit 1; }
OS="$HOME/.claude-discord/projects/$(skey "$OLDP")"
[ "$(cat "$OS/project" 2>/dev/null)" = "$OLDP" ] && diff -r "$HOME/old-shape.ref/ob1" "$OS/bots/ob1" >/dev/null 2>&1 && diff -r "$HOME/old-shape.ref/ob2" "$OS/bots/ob2" >/dev/null 2>&1 &&
  [ "$(stat -c %i "$OS/bots/ob1")" = "$i1" ] && [ "$(stat -c %i "$OS/bots/ob2")" = "$i2" ] && [ "$(stat -c %a "$OS/bots/ob1/.env")" = 600 ] &&
  cmp -s "$HOME/old-shape.ref/config.env" "$OS/config.env" && cmp -s "$HOME/old-shape.ref/peers.json" "$OS/peers.json" && [ -e "$OS/checkin/s1" ] &&
  [ "$(readlink "$OR/ob1")" = "$OS/bots/ob1" ] && [ "$(readlink "$OR/ob2")" = "$OS/bots/ob2" ] && [ ! -e "$OR/hooks" ] && [ ! -L "$OR/hooks" ] &&
  [ "$(<"$OR/.gitignore")" = "*" ] && [ ! -e "$OR/config.env" ] && [ ! -e "$OR/peers.json" ] && [ ! -e "$OR/checkin" ] &&
  [ "$(stat -c %a "$OS")" = 700 ] && [ "$(stat -c %a "$OS/bots")" = 700 ] && [ ! -e "$MON1" ] && [ -e "$HOME/.claude-discord/records/monitor/$(skey "$OLDP")/ob1/stopped" ] &&
  [ -f "$HOME/.claude-discord/scratch/$(skey "$OLDP")/ob1/f" ] && [ "$(readlink "$SCR1")" = "$HOME/.claude-discord/scratch/$(skey "$OLDP")/ob1" ] && [ ! -e "$OPF" ] && grep -qxF "$OLDP" "$OPF.1.16" ||
  { echo "FAIL: compat moves a project's state by rename, leaves a link per bot, and is idempotent: $out / $(find "$OR" "$OS" 2>&1)"; exit 1; }
snap=$(find "$OR" "$OS" -printf '%p %y %m %i\n' | sort)
out2=$(cd "$HOME" && bash "$S" compat 2>&1) || { echo "FAIL: a second compat failed: $out2"; exit 1; }
[ "$(find "$OR" "$OS" -printf '%p %y %m %i\n' | sort)" = "$snap" ] || { echo "FAIL: compat moves a project's state by rename, leaves a link per bot, and is idempotent: the second run changed something: $out2"; exit 1; }
echo "ok: compat moves a 1.16 project's bots, config.env, peers.json and checkin/ into ~/.claude-discord/projects/<key>/ by rename, leaves a link per bot a job record names, drops the hooks link, keeps the .gitignore, moves a stopped manager's records/monitor and scratch under the key, retires the 1.16 list, and a second run changes nothing"
# (g) the link goes only when no jobs/<id>/state.json names its old path; after the last, discord-agents/ and its .gitignore.
rm -rf "$JOBS/mv000002"
# (M-4) No job record, but a foreground session of ob2 on the old path (`claude agents` lists it with a pid, no id): kept, said.
printf '#!/bin/bash\ncase $1 in agents) echo %s;; *) echo "PLAIN $*";; esac\n' "'[{\"name\":\"ob2\",\"pid\":4242,\"cwd\":\"$(cd "$OLDP" && pwd -P)\"}]'" > "$HOME/bin/claude"
out=$(cd "$HOME" && bash "$S" compat 2>&1) || { echo "FAIL: compat failed: $out"; exit 1; }
[ "$(readlink "$OR/ob2")" = "$OS/bots/ob2" ] && grep -qF "$OR/ob2" <<<"$out" && grep -q 'a foreground session of ob2' <<<"$out" ||
  { echo "FAIL: a foreground session on the old path (no job record) keeps its link at compat, said: $out / $(ls -la "$OR" 2>&1)"; exit 1; }
# A row WITH a job id whose record names the NEW path (lmd79 after the live move: photo-bot's a890d472) is a background
# session on the new place already, found by its name: no reason to keep the link.
mkdir -p "$JOBS/ob200002"; jq -n --arg s "{\"env\": {\"DISCORD_STATE_DIR\": \"$OS/bots/ob2\"}}" '{sessionId: "0b500000-1111-2222-3333-444444444444", respawnFlags: ["--settings", $s]}' > "$JOBS/ob200002/state.json"
printf '#!/bin/bash\ncase $1 in agents) echo %s;; *) echo "PLAIN $*";; esac\n' "'[{\"name\":\"ob2\",\"id\":\"ob200002\",\"pid\":4242,\"cwd\":\"$(cd "$OLDP" && pwd -P)\"}]'" > "$HOME/bin/claude"
out=$(cd "$HOME" && bash "$S" compat 2>&1) || { echo "FAIL: compat failed: $out"; exit 1; }
[ ! -L "$OR/ob2" ] && [ ! -e "$OR/ob2" ] && ! grep -q 'foreground' <<<"$out" || { echo "FAIL: a live row with a job id whose record names the new path is no reason to keep the link: $out / $(ls -la "$OR" 2>&1)"; exit 1; }
rm -rf "$JOBS/ob200002"
printf '#!/bin/bash\ncase $1 in agents) echo "[]";; *) echo "PLAIN $*";; esac\n' > "$HOME/bin/claude"
out=$(cd "$HOME" && bash "$S" compat 2>&1) || { echo "FAIL: compat failed: $out"; exit 1; }
[ ! -L "$OR/ob2" ] && [ ! -e "$OR/ob2" ] && [ "$(readlink "$OR/ob1")" = "$OS/bots/ob1" ] && [ -d "$OS/bots/ob2" ] && grep -q mv000001 <<<"$out" && grep -qF "$OR/ob1" <<<"$out" ||
  { echo "FAIL: the old path goes only when no job record names it: $out / $(ls -la "$OR" 2>&1)"; exit 1; }
rm -rf "$JOBS/mv000001"
out=$(cd "$HOME" && bash "$S" compat 2>&1) || { echo "FAIL: compat failed: $out"; exit 1; }
[ ! -e "$OR" ] && [ ! -L "$OR" ] && [ -d "$OLDP/.claude" ] && [ -d "$OS/bots/ob1" ] || { echo "FAIL: the old path goes only when no job record names it: with none left, discord-agents/ and its .gitignore go: $(ls -la "$OLDP/.claude" 2>&1)"; exit 1; }
echo "ok: a bot's old-path link stays while a jobs/<id>/state.json names it (compat says which job), goes when none does, and the empty discord-agents/ with its .gitignore after the last"
# (M-2) A move cut between the rename and the link (bots/ob2 there, no link) is repaired by the next compat when a job record
# names the old path; (I-1) the record holds the start's LOGICAL $PWD, here the project through a link: the path's last
# part decides, not its spelling.
mkdir -p "$OR" "$HOME/lnk"; printf '*\n' > "$OR/.gitignore"; ln -s "$OLDP" "$HOME/lnk/old"
mkdir -p "$JOBS/mv000003"; jq -n --arg s "{\"env\": {\"DISCORD_STATE_DIR\": \"$HOME/lnk/old/.claude/discord-agents/ob2\"}}" '{sessionId: "0b400000-1111-2222-3333-444444444444", respawnFlags: ["--settings", $s]}' > "$JOBS/mv000003/state.json"
out=$(cd "$HOME" && bash "$S" compat 2>&1) || { echo "FAIL: compat failed: $out"; exit 1; }
[ "$(readlink "$OR/ob2")" = "$OS/bots/ob2" ] && grep -qF "$OR/ob2" <<<"$out" && [ ! -e "$OR/ob1" ] ||
  { echo "FAIL: a move cut before its link is repaired by compat when a job record (in any spelling of the project path) names the old path, said: $out / $(ls -la "$OR" 2>&1)"; exit 1; }
rm -rf "$JOBS/mv000003"
out=$(cd "$HOME" && bash "$S" compat 2>&1) || { echo "FAIL: compat failed: $out"; exit 1; }
[ ! -e "$OR" ] && [ ! -L "$OR" ] || { echo "FAIL: the repaired link goes as any other once its record is gone: $(ls -la "$OR" 2>&1)"; exit 1; }
echo "ok: compat makes the per-bot link again when a move was cut before it and a job record names the old path in any spelling of the project path; it goes with the record"
# (M-1) The lock is taken before anything is written: a held lock leaves the old shape whole, the start says so and runs on it.
OLDL="$HOME/old lock"; LR="$OLDL/.claude/discord-agents"; mkdir -p "$LR/lb"; printf 'DISCORD_BOT_TOKEN=tl\n' > "$LR/lb/.env"; echo none > "$LR/lb/mode"; echo '{}' > "$LR/lb/access.json"
printf "DISCORD_CHANNEL_ID='7'\nDISCORD_USER_ID='8'\nDISCORD_ALLOW_IDS=''\n" > "$LR/config.env"
LS="$HOME/.claude-discord/projects/$(skey "$OLDL")"; mkdir -p "$LS.lock"
out=$(cd "$OLDL" && bash "$S" --name lb 2>&1) || :
grep -q 'lock is held' <<<"$out" && grep -qF -- "\"DISCORD_STATE_DIR\": \"$LR/lb\"" <<<"$out" && [ ! -e "$LS/project" ] && [ -d "$LR/lb" ] && [ ! -L "$LR/lb" ] && [ -f "$LR/config.env" ] ||
  { echo "FAIL: a held <key>.lock must leave the old shape whole (no project file written) and the start say it and run on the old path: $out / $(find "$LS" "$LR" 2>&1)"; exit 1; }
rmdir "$LS.lock"
out=$(cd "$OLDL" && bash "$S" --name lb 2>&1)
grep -qF -- "\"DISCORD_STATE_DIR\": \"$LS/bots/lb\"" <<<"$out" && [ -f "$LS/bots/lb/.env" ] || { echo "FAIL: with the lock gone the next start moves the project: $out"; exit 1; }
echo "ok: a held <key>.lock leaves a 1.16 project whole (nothing written under the key), the start says it and runs on the old path; the next start moves it"
# (h) another filesystem (rename(2) refused; a perl stub refuses the move's rename): a bot with a live session is left in
# place and said; with none, copied, compared, the source removed and the link made.
OLDX="$HOME/old xdev"; XR="$OLDX/.claude/discord-agents"; mkdir -p "$XR/xb"; printf 'DISCORD_BOT_TOKEN=tx\n' > "$XR/xb/.env"; echo none > "$XR/xb/mode"; printf 'a\nb\n' > "$XR/xb/handoff.md"
printf "DISCORD_CHANNEL_ID='7'\nDISCORD_USER_ID='8'\n" > "$XR/config.env"
REALPERL=$(command -v perl); printf '#!/bin/bash\ncase "$*" in *"rename \\$ARGV[0], \\$ARGV[1]"*) exit 1;; esac\nexec %q "$@"\n' "$REALPERL" > "$HOME/bin/perl"; chmod +x "$HOME/bin/perl"
cp "$HOME/bin/claude" "$HOME/claude.before-xdev"
printf '#!/bin/bash\ncase $1 in agents) echo %s;; *) echo "PLAIN $*";; esac\n' "'[{\"name\":\"xb\",\"id\":\"xb000001\",\"pid\":1,\"cwd\":\"$OLDX\",\"state\":\"working\"}]'" > "$HOME/bin/claude"
printf '%s\n' "$OLDX" > "$OPF"
out=$(cd "$HOME" && bash "$S" compat 2>&1) || { echo "FAIL: compat failed: $out"; exit 1; }
XS="$HOME/.claude-discord/projects/$(skey "$OLDX")"
[ -d "$XR/xb" ] && [ ! -L "$XR/xb" ] && [ ! -e "$XS/bots/xb" ] && [ "$(cat "$XS/project" 2>/dev/null)" = "$OLDX" ] && [ -f "$XS/config.env" ] && grep -qF "$XR/xb" <<<"$out" && grep -q 'session' <<<"$out" ||
  { echo "FAIL: a cross-filesystem move of a running bot waits: $out / $(find "$XR" "$XS" 2>&1)"; exit 1; }
printf '#!/bin/bash\ncase $1 in agents) echo "[]";; *) echo "PLAIN $*";; esac\n' > "$HOME/bin/claude"
mkdir -p "$JOBS/xb000001"; jq -n --arg s "{\"env\": {\"DISCORD_STATE_DIR\": \"$XR/xb\"}}" '{sessionId: "0b300000-1111-2222-3333-444444444444", respawnFlags: ["--settings", $s]}' > "$JOBS/xb000001/state.json"
out=$(cd "$HOME" && bash "$S" compat 2>&1) || { echo "FAIL: compat failed: $out"; exit 1; }
[ "$(readlink "$XR/xb")" = "$XS/bots/xb" ] && [ "$(<"$XS/bots/xb/handoff.md")" = $'a\nb' ] && [ "$(<"$XS/bots/xb/.env")" = DISCORD_BOT_TOKEN=tx ] && [ -z "$(ls -A "$XS/bots" | command grep '^\.')" ] ||
  { echo "FAIL: with no live session a bot on another filesystem is copied, compared and replaced by a link: $out / $(find "$XR" "$XS" 2>&1)"; exit 1; }
rm -f "$HOME/bin/perl"; cp "$HOME/claude.before-move" "$HOME/bin/claude"; rm -f "$HOME/claude.before-xdev" "$HOME/claude.before-move"; rm -rf "$JOBS/xb000001"
echo "ok: a bot whose directory cannot be renamed (another filesystem) is left in place and said while a session of it runs, and copied, compared and linked once none does"
# A start in a project of the old shape moves it first (no job record names the bot: no link is left) and launches on the new path.
OLDS="$HOME/old start"; SR2="$OLDS/.claude/discord-agents"; mkdir -p "$SR2/sb"; printf 'DISCORD_BOT_TOKEN=ts\n' > "$SR2/sb/.env"; echo none > "$SR2/sb/mode"; echo '{}' > "$SR2/sb/access.json"
printf "DISCORD_CHANNEL_ID='7'\nDISCORD_USER_ID='8'\nDISCORD_ALLOW_IDS=''\n" > "$SR2/config.env"
out=$(cd "$OLDS" && bash "$S" --name sb 2>&1)
SS="$HOME/.claude-discord/projects/$(skey "$OLDS")"
grep -qF -- "\"DISCORD_STATE_DIR\": \"$SS/bots/sb\"" <<<"$out" && [ -f "$SS/bots/sb/.env" ] && [ -f "$SS/config.env" ] && [ ! -e "$OLDS/.claude/discord-agents" ] ||
  { echo "FAIL: a start in a project of the old shape moves it first and starts on the new path: $out / $(find "$OLDS" "$SS" 2>&1)"; exit 1; }
rm -f "$OPF" "$OPF.1.16"
echo "ok: a start in a 1.16-shaped project moves its state first and launches on the new path"


# --- the two cases of the state move that start a plugin server (moved here from the core file, 1.18.0) ---------------
# A project with one bot, as the core file's single-project (the install questions skipped: this file's earlier cases
# leave the trust and install state in another place than the core's); the health run below reads it from its root.
SP="$HOME/single-project"; mkdir -p "$SP"; cd "$SP"
printf '900\n111\n222\ntokS\nn\n' | CLAUDE_DISCORD_SETUP_NOASK=1 bash "$S" setup sbot --scope project >/dev/null 2>&1 || { echo "FAIL: fixture: the setup of single-project failed"; exit 1; }
SD="$(bdir "$SP" "sbot")"
echo "$ID_SEEN" > "$SD/last-message-id"; seed_id "$SD"; seed_guild "$SD"
start_server "$SD"   # as in the core file: the case below counts this one too
# 1.18.0: a server whose environ names the bot's path before the move (<project>/.claude/discord-agents/<bot>: a job
# respawned on it) counts as one on the path after it does: a moved bot never reads as down.
NEWSD="$HOME/.claude-discord/projects/$(skey "$SP")/bots/sbot" OLDSD="$SP/.claude/discord-agents/sbot"
mkdir -p "${OLDSD%/*}"; ln -s "$NEWSD" "$OLDSD"   # the link the move leaves while a job record names the old path; without it such a server reads as down (accepted)
start_server "$OLDSD"; start_server "$NEWSD"
queue "200 $NONE" '200 {"threads":[]}'
out=$(bash "$S" health --json 2>/dev/null) || :
[ "$(field_of sbot servers "$out")" = 3 ] || { echo "FAIL: health counts a server under either path: $(field_of sbot servers "$out") servers: $out"; exit 1; }
stop_one_server "$NEWSD"; stop_one_server "$OLDSD"; rm -rf "$SP/.claude/discord-agents"
echo "ok: health counts a bun server whose DISCORD_STATE_DIR is the bot's path before the move (through the link the move left) as well as one on its path after it"
# (I-1) A 1.17 job record and a server's environ hold the start's LOGICAL $PWD: a project reached through a link is recorded
# (records/projects, pwd -P) as the real path, while the record and the environ name the link's. compat keeps the per-bot
# link, health counts the server, --resume finds the bot: the path's last part and what it resolves to decide, not its spelling.
RP="$HOME/real/p3"; LP="$HOME/link/p3"; RB="$RP/.claude/discord-agents/b"; mkdir -p "$RB" "$HOME/link"; ln -s "$RP" "$LP"
jq --arg p "$(cd "$RP" && pwd -P)" '.projects[$p].hasTrustDialogAccepted = true' "$HOME/.claude.json" > "$HOME/cj.tmp" && mv "$HOME/cj.tmp" "$HOME/.claude.json"   # a --bg start checks the trust
printf "DISCORD_CHANNEL_ID='900'\nDISCORD_USER_ID='111'\nDISCORD_ALLOW_IDS=''\n" > "$RP/.claude/discord-agents/config.env"
printf 'DISCORD_BOT_TOKEN=tokP3\n' > "$RB/.env"; echo none > "$RB/mode"; jq -n '{dmPolicy:"allowlist", allowFrom:["111"], groups:{"900":{requireMention:true, allowFrom:["111"]}}}' > "$RB/access.json"
echo "$ID_SEEN" > "$RB/last-message-id"; seed_id "$RB"; seed_guild "$RB"
mkdir -p "$HOME/.claude/jobs/lk000001"; jq -n --arg s "{\"env\": {\"DISCORD_STATE_DIR\": \"$LP/.claude/discord-agents/b\"}}" '{sessionId: "1111aaaa-2222-3333-4444-555555555555", respawnFlags: ["--settings", $s]}' > "$HOME/.claude/jobs/lk000001/state.json"
RPF="$HOME/.claude-discord/records/projects"; printf '%s\n' "$(cd "$RP" && pwd -P)" > "$RPF"   # the 1.16 list: this project is not moved yet
out=$(cd "$HOME" && bash "$S" compat 2>&1) || { echo "FAIL: compat failed: $out"; exit 1; }
RBN="$HOME/.claude-discord/projects/$(skey "$RP")/bots/b"
[ "$(readlink "$RB")" = "$RBN" ] && grep -q lk000001 <<<"$out" || { echo "FAIL: a job record naming the old path through a link of the project must keep the bot's link: $out / $(ls -la "$RP/.claude/discord-agents" 2>&1)"; exit 1; }
start_server "$LP/.claude/discord-agents/b"
queue "200 $NONE" '200 {"threads":[]}'
out=$(cd "$RP" && bash "$S" health --json 2>"$HOME/health.err") || :
[ "$(field_of b servers "$out")" = 1 ] || { echo "FAIL: health must count a server whose environ names the old path through a link of the project: $out"; exit 1; }
# A real server's environ is NUL-separated: the one grep that reads it must leave nothing on stderr (1.18.0 on lmd42:
# "warning: command substitution: ignored null byte in input", once per server per bot per run).
[ ! -s "$HOME/health.err" ] || { echo "FAIL: health must say nothing on stderr while counting a real server's environ: $(head -c 300 "$HOME/health.err")"; exit 1; }
stop_one_server "$LP/.claude/discord-agents/b"
mkdir -p "${RBN%/b}/c"; printf 'DISCORD_BOT_TOKEN=tokC\n' > "${RBN%/b}/c/.env"; echo none > "${RBN%/b}/c/mode"   # a second bot: with one, a start picks it with no record at all
out=$(cd "$RP" && bash "$S" --bg --resume 1111aaaa-2222-3333-4444-555555555555 2>&1) || :   # the launcher stub prints the exec line; the claude stub here refuses a launch
grep -q -- '-n b' <<<"$out" || { echo "FAIL: --resume must find the bot from a job record naming the old path through a link of the project: $out"; exit 1; }
rm -rf "$RPF" "$RPF.1.16" "$HOME/.claude/jobs/lk000001" "$HOME/link" "$HOME/real"
echo "ok: a job record and a server environ naming the old path in the start's logical spelling (the project through a link) keep the link at compat, count in health and resolve --resume"
# health --all names a stale session (1.19.0): a plugin server whose DISCORD_STATE_DIR no longer exists (a session of a
# bot from before the 1.18 move, revived from the agent view: it has no token and never logs in), with the job of the
# session above it (~/.claude/sessions/<pid>.json); one on a path that exists only through a link is a bot's, not listed.
# Its own HOME with no project: --all is then the scan alone (the suite's shell is the server's parent here).
BH=$HOME/stalebox; mkdir -p "$BH/.claude/sessions"; jq -n '{jobId: "old00001", sessionId: "0ld00001-1111-2222-3333-444444444444"}' > "$BH/.claude/sessions/$$.json"
mkdir -p "$HOME/lk"; ln -s "$SD" "$HOME/lk/sbot"; start_server "$HOME/gone/x"; start_server "$HOME/lk/sbot"
out=$(HOME=$BH bash "$S" health --all --json 2>/dev/null) || :
txt=$(HOME=$BH bash "$S" health --all 2>/dev/null) || :
[ "$(jq -c --arg d "$HOME/gone/x" '[.stale_sessions[] | select(.state_dir == $d) | {job, state_dir}]' <<<"$out")" = "[{\"job\":\"old00001\",\"state_dir\":\"$HOME/gone/x\"}]" ] &&
  [ "$(jq --arg d "$HOME/lk/sbot" '[.stale_sessions[] | select(.state_dir == $d)] | length' <<<"$out")" = 0 ] &&
  grep -qF "stale session: plugin server pid " <<<"$txt" && grep -qF "runs for $HOME/gone/x, which no longer exists: it holds no token and never logs in; claude stop old00001" <<<"$txt" ||
  { echo "FAIL: health --all lists a server whose state dir is gone, with its session's job, and not one on a linked path: $out / $txt"; exit 1; }
stop_one_server "$HOME/lk/sbot"; stop_one_server "$HOME/gone/x"; rm -rf "${BH:?}" "$HOME/lk"
# 1.19.4: a live bot job that is not in pins.json (the daemon retires it after 8 h idle) is pinned by health --all
# --patch (the monitor's run), with a line in the bot's health.log, and only said without --patch. A live job of no bot
# (no DISCORD_STATE_DIR in its record) and one already pinned are left alone.
BH=$HOME/pinbox; mkdir -p "$BH/bin" "$BH/.claude/jobs/a1000001" "$BH/.claude/jobs/b2000002" "$BH/.claude/jobs/c3000003" "$BH/bd"
printf 'DISCORD_BOT_TOKEN=x\n' > "$BH/bd/.env"
for j in a1000001 c3000003; do jq -n --arg s "{\"env\": {\"DISCORD_STATE_DIR\": \"$BH/bd\"}}" '{respawnFlags: ["--settings", $s]}' > "$BH/.claude/jobs/$j/state.json"; done
echo '{"respawnFlags": []}' > "$BH/.claude/jobs/b2000002/state.json"; printf '["c3000003"]' > "$BH/.claude/jobs/pins.json"
printf '#!/bin/bash\n[ "$1" = agents ] && echo %s\n' "'[{\"id\":\"a1000001\",\"pid\":11},{\"id\":\"b2000002\",\"pid\":12},{\"id\":\"c3000003\",\"pid\":13},{\"id\":\"d4000004\"}]'" > "$BH/bin/claude"; chmod +x "$BH/bin/claude"
txt=$(HOME=$BH PATH=$BH/bin:$PATH bash "$S" health --all 2>/dev/null) || :
p1=$(<"$BH/.claude/jobs/pins.json")
out=$(HOME=$BH PATH=$BH/bin:$PATH bash "$S" health --all --json --patch 2>/dev/null) || :
grep -qF "not pinned: job a1000001 of $BH/bd is not in pins.json" <<<"$txt" && [ "$p1" = '["c3000003"]' ] &&
  [ "$(jq -c '.unpinned' <<<"$out")" = "[{\"job\":\"a1000001\",\"state_dir\":\"$BH/bd\",\"pinned_now\":true}]" ] &&
  [ "$(jq -c . "$BH/.claude/jobs/pins.json")" = '["c3000003","a1000001"]' ] && grep -q 'health: pinned job a1000001' "$BH/bd/health.log" ||
  { echo "FAIL: health --all says a live unpinned bot job and --patch pins it (health.log line), leaving a job of no bot and a pinned one alone: $txt / $p1 / $(jq -c .unpinned <<<"$out") / $(cat "$BH/.claude/jobs/pins.json" "$BH/bd/health.log" 2>&1)"; exit 1; }
rm -rf "${BH:?}"
echo "ok: health --all pins a live bot job missing from pins.json under --patch (the monitor's run) and only says so without it"
# 1.19.7: a bot whose live job is ALREADY in pins.json is not pinned again, but its pinned-job (what person_stopped, boot and
# recover read) is set under --patch when it is missing, empty, or names a job that is not running (that old id leaves
# pins.json, as pin_job does); one naming a running job, and the case without --patch, are left alone.
BH=$HOME/pinbox2; mkdir -p "$BH/bin" "$BH/.claude/jobs"
for x in m e k l d; do
  mkdir -p "$BH/b$x"; printf 'DISCORD_BOT_TOKEN=x\n' > "$BH/b$x/.env"
done
for j in a1000001:m e2000002:e c3000003:k b4000004:l f5000005:l d6000006:d; do
  mkdir -p "$BH/.claude/jobs/${j%%:*}"
  jq -n --arg s "{\"env\": {\"DISCORD_STATE_DIR\": \"$BH/b${j##*:}\"}}" '{respawnFlags: ["--settings", $s]}' > "$BH/.claude/jobs/${j%%:*}/state.json"
done
: > "$BH/be/pinned-job"; echo c3000003 > "$BH/bk/pinned-job"; echo f5000005 > "$BH/bl/pinned-job"; echo dead0007 > "$BH/bd/pinned-job"
printf '["a1000001","e2000002","c3000003","b4000004","f5000005","d6000006","dead0007"]' > "$BH/.claude/jobs/pins.json"
printf '#!/bin/bash\n[ "$1" = agents ] && echo %s\n' "'[{\"id\":\"a1000001\",\"pid\":1},{\"id\":\"e2000002\",\"pid\":2},{\"id\":\"c3000003\",\"pid\":3},{\"id\":\"b4000004\",\"pid\":4},{\"id\":\"f5000005\",\"pid\":5},{\"id\":\"d6000006\",\"pid\":6}]'" > "$BH/bin/claude"; chmod +x "$BH/bin/claude"
HOME=$BH PATH=$BH/bin:$PATH bash "$S" health --all >/dev/null 2>&1 || :
[ ! -e "$BH/bm/pinned-job" ] && [ ! -s "$BH/be/pinned-job" ] && [ "$(<"$BH/bd/pinned-job")" = dead0007 ] ||
  { echo "FAIL: health --all without --patch changes no pinned-job"; exit 1; }
HOME=$BH PATH=$BH/bin:$PATH bash "$S" health --all --patch >/dev/null 2>&1 || :
[ "$(<"$BH/bm/pinned-job")" = a1000001 ] && [ ! -e "$BH/bm/pin-foreign" ] ||
  { echo "FAIL: --patch writes a missing pinned-job for a job already in pins.json, and the bot's own job (by its state dir) is not recorded in pin-foreign: $(cat "$BH/bm/pinned-job" "$BH/bm/pin-foreign" 2>&1)"; exit 1; }
[ "$(<"$BH/be/pinned-job")" = e2000002 ] && [ ! -e "$BH/be/pin-foreign" ] || { echo "FAIL: --patch writes an empty pinned-job: $(cat "$BH/be/pinned-job")"; exit 1; }
[ "$(<"$BH/bk/pinned-job")" = c3000003 ] && [ ! -e "$BH/bk/health.log" ] && [ ! -e "$BH/bk/pin-foreign" ] ||
  { echo "FAIL: --patch leaves a pinned-job that is already right alone"; exit 1; }
[ "$(<"$BH/bl/pinned-job")" = f5000005 ] && [ ! -e "$BH/bl/health.log" ] ||
  { echo "FAIL: --patch never overwrites a pinned-job that names a running job: $(cat "$BH/bl/pinned-job")"; exit 1; }
[ "$(<"$BH/bd/pinned-job")" = d6000006 ] && grep -q 'pinned-job set to d6000006 (it was dead0007)' "$BH/bd/health.log" &&
  [ "$(jq -c . "$BH/.claude/jobs/pins.json")" = '["a1000001","e2000002","c3000003","b4000004","f5000005","d6000006"]' ] ||
  { echo "FAIL: --patch replaces a pinned-job naming a job that is not running (the old id leaves pins.json): $(cat "$BH/bd/pinned-job" "$BH/.claude/jobs/pins.json" 2>&1)"; exit 1; }
# A job in pin-foreign that the bot has moved on from (pinned-job names another) and that no longer runs leaves pins.json and
# pin-foreign under --patch; one that still runs (a person's pin of a live job), and the bot's current job, stay.
# ab00000b is a job that finished (its dir stays, as the CLI keeps it until claude rm): a person's ctrl+t pin of it stays.
mkdir -p "$BH/.claude/jobs/ab00000b"
jq -c '. + ["dead0009","dead000a","ab00000b","dead00bb","dead00bc"]' "$BH/.claude/jobs/pins.json" > "$BH/pins.new" && mv "$BH/pins.new" "$BH/.claude/jobs/pins.json"
# bq is a bot of a recorded project (the sweep walks those): its job is c3000003, and it has recorded four foreign ids.
mkdir -p "$BH/pq"; kq="$BH/.claude-discord/projects/$(skey "$BH/pq")"; mkdir -p "$kq/bots/bq"
printf '%s\n' "$(cd -P "$BH/pq" && pwd)" > "$kq/project"; printf 'DISCORD_BOT_TOKEN=x\n' > "$kq/bots/bq/.env"; echo c3000003 > "$kq/bots/bq/pinned-job"
printf 'dead0009\ne2000002\ndead000a\nc3000003\nab00000b\n' > "$kq/bots/bq/pin-foreign"
# br's current job (pinned-job) has no dir here, and is in pin-foreign all the same: never dropped; its other id is gone: dropped.
mkdir -p "$kq/bots/br"; printf 'DISCORD_BOT_TOKEN=x\n' > "$kq/bots/br/.env"; echo dead00bb > "$kq/bots/br/pinned-job"; printf 'dead00bb\ndead00bc\n' > "$kq/bots/br/pin-foreign"
HOME=$BH PATH=$BH/bin:$PATH bash "$S" health --all --patch >/dev/null 2>&1 || :
[ "$(jq -c . "$BH/.claude/jobs/pins.json")" = '["a1000001","e2000002","c3000003","b4000004","f5000005","d6000006","ab00000b","dead00bb"]' ] &&
  [ "$(<"$kq/bots/bq/pin-foreign")" = $'e2000002\nc3000003\nab00000b' ] && [ "$(<"$kq/bots/br/pin-foreign")" = dead00bb ] ||
  { echo "FAIL: --patch drops a pin-foreign job whose dir is gone from pins.json and pin-foreign, never a job that only finished (dir kept) or the bot's own: $(cat "$BH/.claude/jobs/pins.json" "$kq/bots/bq/pin-foreign" "$kq/bots/br/pin-foreign" 2>&1)"; exit 1; }
# pin_drop decides by the job dir alone, so a claude agents answer that is not JSON changes nothing about it: a gone job still goes.
jq -c '. + ["dead00cc"]' "$BH/.claude/jobs/pins.json" > "$BH/pins.new" && mv "$BH/pins.new" "$BH/.claude/jobs/pins.json"; echo dead00cc >> "$kq/bots/br/pin-foreign"
printf '#!/bin/bash\n[ "$1" = agents ] && echo "not json"\n' > "$BH/bin/claude"
HOME=$BH PATH=$BH/bin:$PATH bash "$S" health --all --patch >/dev/null 2>&1 || :
{ ! grep -q dead00cc "$BH/.claude/jobs/pins.json" && [ "$(<"$kq/bots/br/pin-foreign")" = dead00bb ]; } ||
  { echo "FAIL: --patch with a claude agents answer that is not JSON still drops a pin-foreign job whose dir is gone (pin_drop reads no live list): $(cat "$BH/.claude/jobs/pins.json" "$kq/bots/br/pin-foreign" 2>&1)"; exit 1; }
rm -rf "${BH:?}"
echo "ok: health --all --patch sets a missing, empty or dead pinned-job for a job already in pins.json (not as pin-foreign when it is the bot's own), leaves a running or right one, and drops a dead pin-foreign job"
# held (1.19.1): sbot's own server is the last one up; with it stopped and bot sbot hold, health reads held, not down.
stop_one_server "$SD"; : > "$SD/held"; queue "200 $NONE" '200 {"threads":[]}'
out=$(cd "$SP" && bash "$S" health --json 2>/dev/null) || :
[ "$(field_of sbot verdict "$out")" = held ] || { echo "FAIL: a bot held on purpose with no server reads held, not down: $out"; exit 1; }
rm -f "$SD/held"
# A bot its person stopped (1.19.7, person_stopped): the job in pinned-job has "bg settled <id> (killed)" as the LAST line of
# its life in daemon.log (claude stop and claude rm; the SessionEnd hook cannot tell them from a SIGTERM), and health
# writes held and reads it held, so the monitor never recovers it. Each case with its opposite: a (done) last, a later start of
# the same id, the daemon's own shutdown or start just before (a kill 90 s after a start is a person's), a line older than the
# newest session marker, an id in own-stop, no pinned-job, another job's line, an unreadable time; a held file already there
# is kept as it is. A big log after the kill and many markers must not change a verdict (pipefail with head: SIGPIPE).
DLOG="$HOME/.claude/daemon.log"; SDM="$SD/plugin-sessions"
dts() { date -u -d "$1" +%Y-%m-%dT%H:%M:%S.000Z; }
hv() {  # <log lines>: health's verdict for sbot, then the held file's first two words when health wrote one
  printf '%s\n' "$1" > "$DLOG"; rm -f "$SD/held"; queue "200 $NONE" '200 {"threads":[]}'
  out=$(cd "$SP" && bash "$S" health --json 2>/dev/null) || :
  printf '%s' "$(field_of sbot verdict "$out")"; [ ! -f "$SD/held" ] || printf ' %s' "$(cut -d' ' -f1-2 "$SD/held")"
}
echo ee0000ff > "$SD/pinned-job"; rm -rf "$SDM" "$SD/own-stop"
SP1="[$(dts '10 minutes ago')] [bg] bg spawned ee0000ff (spare)"; KL="[$(dts '1 minute ago')] [bg] bg settled ee0000ff (killed)"; KE=$(date -u -d '1 minute ago' +%s)
R1=$(hv "$SP1"$'\n'"$KL")
R2=$(hv "$SP1"$'\n'"[$(dts '1 minute ago')] [bg] bg retire ee0000ff: idle-prompt, idle 60m"$'\n'"[$(dts '1 minute ago')] [bg] bg settled ee0000ff (done)")
R3=$(hv "$KL"$'\n'"[$(dts '30 seconds ago')] [bg] bg claimed-spare ee0000ff (slash)")
SD1="[$(dts '5 minutes ago')] [supervisor] shutting down (cause=upgrade, uptime=9s, leases=1, live_workers=1)"
R6=$(hv "$SD1"$'\n'"$KL")
R7=$(hv "[$(dts '1 minute ago')] [bg] bg settled ee0000ff (done)"$'\n'"[$(dts '30 seconds ago')] [bg] bg settled 99999999 (killed)")
R8=$(hv "[not-a-time] [bg] bg settled ee0000ff (killed)")
R14=$(hv "[$(dts '90 seconds ago')] [supervisor] shutting down (cause=signal, uptime=9s, leases=1, live_workers=1)"$'\n'"$KL")
DS="[$(dts '70 seconds ago')] [supervisor] shutting down (cause=upgrade, uptime=9s, leases=1, live_workers=1)"
DN="[$(dts '150 seconds ago')] [supervisor] ─── daemon start ─── version=2.1.207 pid=1 origin=transient"
R16=$(hv "$DN"$'\n'"$KL")   # the kill 90 s after a daemon start, no shutdown: a person's
R20=$(hv "[$(dts '80 seconds ago')] [supervisor] ─── daemon start ─── version=2.1.207 pid=1 origin=transient"$'\n'"$KL")   # 20 s after a start: the new daemon's clean-up
FILL=$(awk 'BEGIN { for (i = 0; i < 1500; i++) print "[2026-10-30T20:00:00.000Z] [bg] bg spare spawned host pid=" i " ................................" }')
R17=$(hv "$DS"$'\n'"$KL"$'\n'"$FILL")   # 100 KB of log after the kill must not drop the shutdown line before it
cp "$SD/.env" "$SD/.env.keep"; : > "$SD/.env"; R15=$(hv "$KL"); mv "$SD/.env.keep" "$SD/.env"   # no token: unknown, nothing to hold
mkdir -p "$SDM"; : > "$SDM/s1"; touch -d '10 minutes ago' "$SDM/s1"
R9=$(hv "$KL")
touch "$SDM/s1"
R10=$(hv "[$(dts '5 minutes ago')] [bg] bg settled ee0000ff (killed)")
rm -rf "$SDM"; mkdir -p "$SDM"; LONG=$(printf 'm%.0s' {1..240}); for i in $(seq 1 3000); do : > "$SDM/$LONG$i"; done; touch -d '10 minutes ago' "$SDM"/*
R18=$(hv "$KL")   # 3000 markers (720 KB of names), all older than the line: held
: > "$SDM/new1"; R19=$(hv "[$(dts '5 minutes ago')] [bg] bg settled ee0000ff (killed)")   # one newer among them: not
rm -rf "$SDM"; echo "ee0000ff $((KE - 30))" > "$SD/own-stop"
R11=$(hv "$KL")   # our own stop 30 s before the kill line
echo "ee0000ff $((KE - 600))" > "$SD/own-stop"
R21=$(hv "$KL")   # an old line of ours, the kill 10 minutes after it: a person's stop
echo "99999999 $((KE - 30))" > "$SD/own-stop"
R22=$(hv "$KL"); rm -f "$SD/own-stop"   # a recent line for another job
# The window's edges, person_stopped itself against the log line in DLOG (hv's whole health pass per case costs 0.1 s each; the cases
# above already cover health's reading of the verdict). KB = the kill line's own epoch, so each edge is exact.
KB=$(date -u -d "${KL:1:24}" +%s)
pv() { echo "ee0000ff $1" > "$SD/own-stop"; ( . "$D/bin/lib/state.sh" 2>/dev/null; person_stopped "$SD" >/dev/null && echo held || echo ours ); }
R23=$(pv "$KB")          # the line at the kill's second (+0): ours
R24=$(pv "$((KB - 121))")   # the kill 121 s after the line: a person's
R25=$(pv "$((KB + 1))"); rm -f "$SD/own-stop"   # the line written 1 s AFTER the kill: a person's
rm -f "$SD/pinned-job"; R12=$(hv "$KL"); echo ee0000ff > "$SD/pinned-job"
printf '%s\n' "$KL" > "$DLOG"; echo "by hand" > "$SD/held"; queue "200 $NONE" '200 {"threads":[]}'; out=$(cd "$SP" && bash "$S" health --json 2>/dev/null) || :
R13="$(field_of sbot verdict "$out") $(<"$SD/held")"
K1="session-end killed"
[ "$R1" = "held $K1" ] && [ "$R2" = down ] && [ "$R3" = down ] && [ "$R6" = "held $K1" ] && [ "$R7" = down ] &&
  [ "$R8" = down ] && [ "$R9" = "held $K1" ] && [ "$R10" = down ] && [ "$R11" = down ] && [ "$R21" = "held $K1" ] && [ "$R22" = "held $K1" ] && [ "$R23" = ours ] && [ "$R24" = held ] && [ "$R25" = held ] && [ "$R12" = down ] && [ "$R13" = "held by hand" ] && [ "$R14" = down ] && [ "$R15" = unknown ] &&
  [ "$R16" = "held $K1" ] && [ "$R17" = down ] && [ "$R18" = "held $K1" ] && [ "$R19" = down ] && [ "$R20" = down ] ||
  { echo "FAIL: health holds a bot whose pinned job's last daemon.log line is a (killed) and nothing else: $R1 | $R2 | $R3 | $R6 | $R7 | $R8 | $R9 | $R10 | $R11 | $R12 | $R13 | $R14 | $R15 | $R16 | $R17 | $R18 | $R19 | $R20 | $R21 | $R22 | $R23 | $R24 | $R25"; exit 1; }
# An inferred hold (session-end killed <time>) counts only while no session marker is newer than <time> (health race 1.19.7:
# a bot restarted during the pass, its hold written after on-session-start removed it): dropped, the bot reads down.
: > "$DLOG"; mkdir -p "$SDM"; touch -d '10 minutes ago' "$SDM"; : > "$SDM/s1"; touch -d '10 minutes ago' "$SDM/s1"
hh() {  # <held content>: health's verdict for sbot, then "kept" when the held file is still there
  printf '%s\n' "$1" > "$SD/held"; queue "200 $NONE" '200 {"threads":[]}'
  out=$(cd "$SP" && bash "$S" health --json 2>/dev/null) || :
  printf '%s' "$(field_of sbot verdict "$out")"; [ ! -f "$SD/held" ] || printf ' kept'
}
H1=$(hh "session-end killed $(dts '5 minutes ago')")   # the marker is older than the line: kept
touch "$SDM/s1"; H2=$(hh "session-end killed $(dts '5 minutes ago')")   # a session started after the line: dropped
H3=$(hh "session-end prompt_input_exit $(dts '5 minutes ago')")   # the hook's own hold is not inferred: kept
rm -rf "$SDM"
[ "$H1" = "held kept" ] && [ "$H2" = down ] && [ "$H3" = "held kept" ] || { echo "FAIL: an inferred hold is dropped once a session marker is newer than its line, the hook's hold is not: $H1 | $H2 | $H3"; exit 1; }
rm -f "$SD/held" "$SD/pinned-job" "$DLOG"
echo "ok: health --all lists stale sessions (a plugin server whose state dir is gone) with the job to stop, and leaves a server on a linked path alone"
stop_servers

# --- many bots per project (1.18.1, Task 4): nothing is keyed by a bot's name alone ----------------------------------
# (a, d) Two projects each with a manager named mgr: setup of the second succeeds (1.18.0 refused it), records/managers
# lists both keys, a missing file is rebuilt from projects/*/bots/*/hosts by the hooks, and revive_backends starts two
# keepers (monitor --keep mgr --detach from each project), each with its own records/monitor/<key>/mgr.
M2A="$HOME/mgr one"; M2B="$HOME/mgr two"; mkdir -p "$M2A" "$M2B"
jq --arg a "$M2A" --arg b "$M2B" '.projects[$a].hasTrustDialogAccepted = true | .projects[$b].hasTrustDialogAccepted = true' "$HOME/.claude.json" > "$HOME/cj.tmp" && mv "$HOME/cj.tmp" "$HOME/.claude.json"
for p in "$M2A" "$M2B"; do
  rc=0; out=$(cd "$p" && printf '900\n111\n\ntokM\nn\ndev-manager\n\n\n' | CLAUDE_DISCORD_SETUP_NOASK=1 bash "$S" setup mgr --scope project 2>&1) || rc=$?
  [ "$rc" = 0 ] && [ -f "$(bdir "$p" mgr)/hosts" ] && [ "$(<"$(bdir "$p" mgr)/mode")" = dev-manager ] || { echo "FAIL: two managers of one name in two projects are two backends: setup of mgr in $p (rc=$rc): $out"; exit 1; }
done
KA=$(skey "$M2A") KB=$(skey "$M2B"); MGRS="$HOME/.claude-discord/records/managers"
grep -qxF -- "$KA mgr" "$MGRS" && grep -qxF -- "$KB mgr" "$MGRS" || { echo "FAIL: two managers of one name in two projects are two backends: records/managers must list both keys: $(cat "$MGRS" 2>&1)"; exit 1; }
FX="$HOME/fxroot"; mkdir -p "$FX/bin/lib" "$FX/hooks/turn" "$FX/hooks/lib"; cp "$D/hooks/turn/on-prompt" "$FX/hooks/turn/"; cp "$D/hooks/lib/discord.sh" "$FX/hooks/lib/"; cp "$D/bin/lib/state.sh" "$FX/bin/lib/"
printf '#!/bin/sh\nprintf "%%s %%s\\n" "$PWD" "$*" >> "$HOME/fx.rec"\n' > "$FX/bin/claude-discord"; chmod +x "$FX/bin/claude-discord"
FXR=$(cd -P "$FX" && pwd -P); printf '{"session_id":"sM2","prompt":"hi"}' > "$HOME/up.json"
fxhook() { rm -f "$HOME/fx.rec" "$HOME"/.claude-discord/records/monitor/*/mgr/last-start* "$HOME"/.claude-discord/records/monitor/mgr/last-start*; env -u CLAUDE_DISCORD_NO_AUTOSTART CLAUDE_PLUGIN_ROOT="$FXR" CLAUDE_PROJECT_DIR="$M2A" DISCORD_STATE_DIR="$(bdir "$M2A" mgr)" bash "$FXR/hooks/turn/on-prompt" < "$HOME/up.json" >/dev/null 2>&1; nap 0.1; }
rm -f "$MGRS"; fxhook
grep -qxF -- "$KA mgr" "$MGRS" 2>/dev/null && grep -qxF -- "$KB mgr" "$MGRS" || { echo "FAIL: a missing records/managers is rebuilt by the hooks from projects/*/bots/*/hosts: $(cat "$MGRS" 2>&1)"; exit 1; }
printf '%s mgr\n%s mgr\n%s mgr\n' "$KA" "$KB" "$KA" > "$MGRS"; fxhook   # a line twice: one keeper
[ "$(sort "$HOME/fx.rec" 2>/dev/null)" = "$(printf '%s monitor --keep mgr --detach\n%s monitor --keep mgr --detach\n' "$M2A" "$M2B" | sort)" ] &&
  [ -s "$HOME/.claude-discord/records/monitor/$KA/mgr/last-start"* ] && [ -s "$HOME/.claude-discord/records/monitor/$KB/mgr/last-start"* ] && [ ! -e "$HOME/.claude-discord/records/monitor/mgr" ] ||
  { echo "FAIL: two managers of one name in two projects are two backends: revive_backends must start a keeper per manager (key and name) from its project, each with its own records/monitor/<key>/mgr: $(cat "$HOME/fx.rec" 2>&1) / $(ls -R "$HOME/.claude-discord/records/monitor" 2>&1)"; exit 1; }
echo none > "$(bdir "$M2B" mgr)/mode"; fxhook   # a listed line whose mode is no longer dev-manager: nothing forked for it
[ "$(cat "$HOME/fx.rec" 2>/dev/null)" = "$M2A monitor --keep mgr --detach" ] || { echo "FAIL: revive_backends starts nothing for a listed manager whose mode is no longer dev-manager: $(cat "$HOME/fx.rec" 2>&1)"; exit 1; }
echo dev-manager > "$(bdir "$M2B" mgr)/mode"
rm -rf "$FX" "$HOME/fx.rec" "$HOME/up.json" "$HOME/.claude-discord/records/monitor"
echo "ok: two projects may each have a manager named mgr: setup accepts the second, records/managers lists both keys (rebuilt by the hooks when missing), and revive_backends starts one keeper per key and name, from its project, with records/monitor/<key>/<bot> each"

# (e) The hooks read the channel and the people from the bot's own access.json, never from config.env: a config.env
# naming another channel and owner changes nothing in on-prompt's identity and People line, and a removed one neither;
# with none or several groups there is no channel (the identity says so).
SD2="$(bdir "$SP" sbot)"; cp "$SD2/access.json" "$HOME/acc.keep"; cp "$(pstate "$SP")/config.env" "$HOME/cfg.keep"
ehook() { printf '{"session_id":"%s","prompt":"<channel source=\\"plugin:discord:discord\\" chat_id=\\"900\\" message_id=\\"%s\\" user=\\"u\\" user_id=\\"111\\" ts=\\"t\\">\\nhi\\n</channel>"}' "$1" "$2" | CLAUDE_PLUGIN_ROOT="$PC" CLAUDE_PROJECT_DIR="$SP" DISCORD_STATE_DIR="$SD2" bash "$PC/hooks/turn/on-prompt" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null; }
printf "DISCORD_CHANNEL_ID='7777'\nDISCORD_USER_ID='8888'\nDISCORD_ALLOW_IDS=''\n" > "$(pstate "$SP")/config.env"
c1=$(ehook e1 901); rm -f "$(pstate "$SP")/config.env"; c2=$(ehook e2 902)
grep -q ' in channel 900\. ' <<<"$c1" && grep -q '^People in this channel (mention one as <@id> to reach them): u <@111>, <@222>$' <<<"$c1" && [ "$c1" = "$c2" ] ||
  { echo "FAIL: the hooks read the channel and the people from access.json only: $c1 /// $c2"; exit 1; }
# Several groups (1.18.2): config.env's DISCORD_CHANNEL_ID is the home channel when it is one of them (1.18.1 read
# nothing from config.env and left such a bot with no channel: junyong-dev-bot and RVP on lmd42 could not `thread start`);
# a home that is none of the groups, or no config.env, is no channel, as before.
jq '.groups["901"] = .groups["900"]' "$HOME/acc.keep" > "$SD2/access.json"; printf "DISCORD_CHANNEL_ID='901'\nDISCORD_USER_ID='111'\nDISCORD_ALLOW_IDS=''\n" > "$(pstate "$SP")/config.env"
c3=$(ehook e3 903)
grep -q ' in channel 901\. ' <<<"$c3" && ! grep -q 'no channel' <<<"$c3" || { echo "FAIL: with several groups config.env's channel, when it is one of them, is the home channel: $c3"; exit 1; }
: > "$CURL_LOG"; printf '200 {"id":"5551"}\n200 {"id":"5552"}\n' > "$CURL_REPLIES"   # the two POSTs' replies, no gateway line: the tool asks for none
tout=$(cd "$SP" && DISCORD_STATE_DIR=$SD2 bash "$PC/tools/thread" start "[t] home" 2>&1) || { echo "FAIL: thread start must work for a bot with several groups and a home channel: $tout"; exit 1; }
grep -q 'channels/901/messages' "$CURL_LOG" || { echo "FAIL: thread start posts the channel line to the home channel: $(cat "$CURL_LOG")"; exit 1; }
printf "DISCORD_CHANNEL_ID='7777'\nDISCORD_USER_ID='111'\nDISCORD_ALLOW_IDS=''\n" > "$(pstate "$SP")/config.env"; c4=$(ehook e4 904)
grep -q ' with no channel (its access.json names no single channel)\. ' <<<"$c4" && ! grep -q 'in channel' <<<"$c4" || { echo "FAIL: with several groups and a config.env channel that is none of them there is no channel: $c4"; exit 1; }
rm -f "$(pstate "$SP")/config.env"; c5=$(ehook e5 905)
grep -q ' with no channel (its access.json names no single channel)\. ' <<<"$c5" || { echo "FAIL: with several groups and no config.env there is no channel: $c5"; exit 1; }
printf '' > "$SD2/access.json"
(DISCORD_STATE_DIR=$SD2; . "$PC/hooks/lib/discord.sh"; resolve_channel; [ -z "$bot_channel" ] && [ -z "$bot_access_ids" ]) || { echo "FAIL: an empty access.json leaves no channel (config.env is not read): '$(DISCORD_STATE_DIR=$SD2; . "$PC/hooks/lib/discord.sh"; resolve_channel; echo "$bot_channel")'"; exit 1; }
cp "$HOME/acc.keep" "$SD2/access.json"; cp "$HOME/cfg.keep" "$(pstate "$SP")/config.env"; rm -f "$HOME/acc.keep" "$HOME/cfg.keep" "$SD2"/turns/e[12345]*
echo "ok: on-prompt's identity and People line come from access.json alone (config.env naming another channel and owner, or removed, changes nothing); none is no channel; several groups take config.env's channel as home when it is one of them (thread start posts there), else no channel"

# (f) peers.json is written under peers.json.lock (mkdir, 5 s): held, the writer says the file was not changed and goes
# on (exit status as without the lock); released, the next write lands.
PJ="$(pstate "$M2A")/peers.json"; cp "$PJ" "$HOME/pj.keep" 2>/dev/null || : > "$HOME/pj.keep"; mkdir "$PJ.lock"
rc=0; out=$(cd "$M2A" && printf 'dev-manager\npeerz:700:800:host\n\n' | bash "$S" setup mgr --mode 2>&1) || rc=$?
[ "$rc" = 0 ] && grep -q "$PJ.lock is held" <<<"$out" && grep -q 'not changed' <<<"$out" && ! grep -q peerz "$PJ" 2>/dev/null || { echo "FAIL: peers.json is written under its lock (rc=$rc): $out / $(cat "$PJ" 2>&1)"; exit 1; }
rmdir "$PJ.lock"
rc=0; out=$(cd "$M2A" && printf 'dev-manager\npeerz:700:800:host\n\n' | bash "$S" setup mgr --mode 2>&1) || rc=$?
[ "$rc" = 0 ] && grep -q peerz "$PJ" && [ ! -e "$PJ.lock" ] || { echo "FAIL: with the lock released the peers line is written and the lock left clean (rc=$rc): $out / $(cat "$PJ" 2>&1)"; exit 1; }
echo "ok: a held peers.json.lock makes setup --mode (the peers writer) say the file was not changed and go on; released, the write lands and the lock is released"

# (b, c) The backend records of a manager, records/monitor/<bot> before 1.18.1, move to records/monitor/<key>/<bot> at
# compat with the backend stopped before and started after (as bot rename does): the holder lock and state.json are at
# the new path, the alerts continue (one appended after the move follows the ones before it), the next pass writes to
# the new path; scratch/<bot> goes to scratch/<key>/<bot> with a link in its place, which nothing removes (a session
# started before 1.18.1 may write there, and whether one runs cannot be judged from every side of a shared home). A
# backend a hook or a TUI started at the new path meanwhile (its own keeper and monitor, no history) is stopped too and
# its records replaced by the old path's: one backend after, with the history. A start at the new path that fails (a
# --keep that fails once) puts the records back and starts the backend at the old path again: compat exits 1 with the
# reason. A backend this side cannot see (the other side of a shared home holds the lock) is not moved: compat exits 1
# saying where to run it, and leaves no stopped marker.
export CLAUDE_DISCORD_MONITOR_TICK=0.01 CLAUDE_DISCORD_MONITOR_PASS=60 CLAUDE_DISCORD_MONITOR_HOST_CAP=0.03 CLAUDE_DISCORD_MONITOR_LOCK_WAIT=0.10
mv "$HOME/.local/bin/claude-discord" "$HOME/shim.real"; mkdir -p "$HOME/mon"
printf '#!/bin/bash\ncat "$HOME/mon/local.out"\n' > "$HOME/.local/bin/claude-discord"; chmod +x "$HOME/.local/bin/claude-discord"
mdoc2() { local b bots=""; for b in "$@"; do bots="$bots${bots:+,}{\"bot\":\"$b\",\"verdict\":\"stale\",\"detail\":\"why stale\",\"owner_id\":\"222\",\"servers\":\"1\"}"; done; printf '{"host":"h1","version":"1.18.1 (abc1234)","home":"/home/u","patch":{"rc":0,"output":""},"projects":[{"project":"/home/u/ws/p","bots":[%s]}]}\n' "$bots" > "$HOME/mon/local.out"; }
OLDM="$HOME/.claude-discord/records/monitor/mgr" NEWM="$HOME/.claude-discord/records/monitor/$KA/mgr"
alerts() { jq -r '[.alerts[] | .key] | join(" ")' "$1/state.json" 2>/dev/null || :; }
wait_alerts() { local n=0; while [ "$(alerts "$1")" != "$2" ] && [ "$n" -lt 7500 ]; do nap 0.002; n=$((n + 1)); done; [ "$(alerts "$1")" = "$2" ]; }
mon_pid() { local l=""; { read -r l < "$1/lock"; } 2>/dev/null || :; case $l in ''|*[!0-9]*) return 1;; esac; [[ $(tr '\0' ' ' < "/proc/$l/cmdline" 2>/dev/null) == *"--locked mgr "* ]] && echo "$l"; }
wait_mon() { local n=0; while ! mon_pid "$1" >/dev/null && [ "$n" -lt 7500 ]; do nap 0.002; n=$((n + 1)); done; mon_pid "$1" >/dev/null; }
keepers() { local f; for f in "$1"/holders/keeper-*; do [ ! -f "$f" ] || { kill -0 "${f##*-}" 2>/dev/null && echo "${f##*-}"; }; done; }   # the live keeper pids a records dir names
wait_keeper() { local n=0 k; while :; do k=$(keepers "$1"); [ -n "$k" ] && [ "$k" != "${2:-}" ] && break; [ "$n" -lt 7500 ] || break; nap 0.002; n=$((n + 1)); done; keepers "$1"; }
mdoc2 b1; : > "$CURL_REPLIES"; : > "$CURL_LOG"
mkdir -p "$HOME/.claude-discord/scratch/mgr"; : > "$HOME/.claude-discord/scratch/mgr/f"
(cd "$M2A" && CLAUDE_DISCORD_MONITOR_DIR=$OLDM bash "$S" monitor --start mgr >/dev/null 2>&1) || { echo "FAIL: fixture: the backend of mgr did not start at the old path"; exit 1; }
wait_alerts "$OLDM" 'local|/home/u/ws/p|b1' || { echo "FAIL: fixture: the backend at the old path ran no pass: $(cat "$OLDM/monitor.log" 2>&1)"; exit 1; }
# (M-1) A backend at the new path too, as a hook's revive_backends or a TUI starts one between the pull and the move.
(cd "$M2A" && bash "$S" monitor --start mgr >/dev/null 2>&1) || { echo "FAIL: fixture: the backend of mgr did not start at the new path"; exit 1; }
wait_mon "$NEWM" && NKP=$(wait_keeper "$NEWM") && [ -n "$NKP" ] || { echo "FAIL: fixture: no backend at the new path: $(ls -R "$NEWM" 2>&1)"; exit 1; }
mdoc2 b1 b2
rc=0; out=$(cd "$HOME" && bash "$S" compat 2>&1) || rc=$?
KP2=$(wait_keeper "$NEWM" "$NKP")
[ "$rc" = 0 ] && [ ! -e "$OLDM" ] && [ -f "$NEWM/state.json" ] && wait_mon "$NEWM" && wait_alerts "$NEWM" 'local|/home/u/ws/p|b1 local|/home/u/ws/p|b2' && grep -qF "$NEWM" <<<"$out" &&
  [ "$(wc -l <<<"$KP2")" = 1 ] && [ "$KP2" != "$NKP" ] && ! kill -0 "$NKP" 2>/dev/null && [ "$(ps -eo args= | command grep -c "[m]onitor/monitor.sh .* --locked mgr")" = 1 ] ||
  { echo "FAIL: the records move with the backend stopped and started: the lock and state.json at the new path, the alerts continuous, the next pass there, and a backend started at the new path meanwhile stopped (one keeper, one monitor after; its holder gone) (rc=$rc): $out / keepers=$KP2 nkp=$NKP / $(ls -R "$HOME/.claude-discord/records/monitor" 2>&1) / $(cat "$NEWM/monitor.log" "$OLDM/monitor.log" 2>&1 | tail -n 20)"; exit 1; }
[ -f "$HOME/.claude-discord/scratch/$KA/mgr/f" ] && [ "$(readlink "$HOME/.claude-discord/scratch/mgr")" = "$HOME/.claude-discord/scratch/$KA/mgr" ] ||
  { echo "FAIL: scratch/<bot> moves to scratch/<key>/<bot> with a link in its place: $out / $(ls -la "$HOME/.claude-discord/scratch" 2>&1)"; exit 1; }
(cd "$M2A" && bash "$S" monitor --stop mgr >/dev/null 2>&1) || :
n=0; while mon_pid "$NEWM" >/dev/null && [ "$n" -lt 1500 ]; do nap 0.002; n=$((n + 1)); done
cp "$HOME/bin/claude" "$HOME/claude.keep"; printf '#!/bin/bash\ncase $1 in agents) echo "[]";; *) echo "PLAIN $*";; esac\n' > "$HOME/bin/claude"   # a listing with no session of mgr
out=$(cd "$HOME" && bash "$S" compat 2>&1) || { echo "FAIL: compat failed: $out"; exit 1; }
[ "$(readlink "$HOME/.claude-discord/scratch/mgr")" = "$HOME/.claude-discord/scratch/$KA/mgr" ] && [ -f "$HOME/.claude-discord/scratch/$KA/mgr/f" ] || { echo "FAIL: the scratch link stays (a session started before 1.18.1 may write there, and a listing cannot see every side): $out / $(ls -la "$HOME/.claude-discord/scratch" 2>&1)"; exit 1; }
cp "$HOME/claude.keep" "$HOME/bin/claude"; rm -f "$HOME/claude.keep"
echo "ok: compat moves a manager's records/monitor/<bot> to records/monitor/<key>/<bot> with the backend stopped before and started after (lock and state at the new path, the alerts continuous, the next pass there; a backend started at the new path meanwhile stopped: one backend after), and scratch/<bot> to scratch/<key>/<bot> behind a link that stays"
# The rollback: the backend at the old path again, a --keep that fails once at the new path.
rm -rf "$NEWM"; mdoc2 b1
(cd "$M2A" && CLAUDE_DISCORD_MONITOR_DIR=$OLDM bash "$S" monitor --start mgr >/dev/null 2>&1) || { echo "FAIL: fixture: the backend of mgr did not start at the old path again"; exit 1; }
wait_alerts "$OLDM" 'local|/home/u/ws/p|b1' || { echo "FAIL: fixture: the backend at the old path ran no pass (second start): $(cat "$OLDM/monitor.log" 2>&1)"; exit 1; }
printf '#!/bin/bash\nif [ -e "$HOME/keep.fail" ]; then case "$*" in *" --kept"*) rm -f "$HOME/keep.fail"; exit 1;; esac; fi\nexec %q "$@"\n' "$REALPERL" > "$HOME/bin/perl"; chmod +x "$HOME/bin/perl"; : > "$HOME/keep.fail"
rc=0; out=$(cd "$HOME" && bash "$S" compat 2>&1) || rc=$?
[ "$rc" = 1 ] && [ ! -e "$NEWM" ] && [ -f "$OLDM/state.json" ] && wait_mon "$OLDM" && [ ! -e "$HOME/keep.fail" ] && grep -q "did not start at $NEWM" <<<"$out" && grep -qF "back at $OLDM" <<<"$out" ||
  { echo "FAIL: a failed restart at the new path puts the records back at the old one and starts the backend there again, compat exit 1 with the reason (rc=$rc): $out / $(ls -R "$HOME/.claude-discord/records/monitor" 2>&1) / $(cat "$OLDM/monitor.log" 2>&1 | tail -n 20)"; exit 1; }
rm -f "$HOME/bin/perl"
(cd "$M2A" && CLAUDE_DISCORD_MONITOR_DIR=$OLDM bash "$S" monitor --stop mgr >/dev/null 2>&1) || :
n=0; while mon_pid "$OLDM" >/dev/null && [ "$n" -lt 1500 ]; do nap 0.002; n=$((n + 1)); done
rm -rf "$OLDM"
echo "ok: a records move whose restart fails puts the records back at the old path and starts the backend there again; compat exits 1 and says why"
# (I-1) The old path's lock held by a monitor this side cannot see (the other side of a shared home: its pid reads as
# another process here, so --stop stops nothing): the records are not moved, no stopped marker is left, compat exits 1
# naming where to run it.
mkdir -p "$OLDM"; printf '{"version":1,"manager":"mgr","monitor":{},"hosts":{},"bots":{},"alerts":[]}\n' > "$OLDM/state.json"
perl -MFcntl=:flock -e 'open(my $l, ">>", $ARGV[0]) or die; flock($l, LOCK_EX) or die; open(my $w, ">", $ARGV[0]) or die; print $w "$$\n"; close $w; sleep 30' "$OLDM/lock" & LP=$!
KILL_AT_EXIT="$KILL_AT_EXIT $LP"; n=0; l=""; until [ "$l" = "$LP" ] || [ "$n" -ge 1000 ]; do nap 0.002; n=$((n + 1)); { read -r l < "$OLDM/lock"; } 2>/dev/null || :; done
rc=0; out=$(cd "$HOME" && bash "$S" compat 2>&1) || rc=$?
[ "$rc" = 1 ] && [ -f "$OLDM/state.json" ] && [ ! -e "$OLDM/stopped" ] && [ ! -e "$NEWM" ] && grep -q 'runs where this side cannot see it: run update there' <<<"$out" ||
  { echo "FAIL: a backend this side cannot see (its lock held) is not moved, no stopped marker is left, compat exit 1 saying to run update there (rc=$rc): $out / $(ls -R "$HOME/.claude-discord/records/monitor" 2>&1)"; exit 1; }
kill "$LP" 2>/dev/null || :; wait "$LP" 2>/dev/null || :; rm -rf "$OLDM"
echo "ok: a backend whose lock this side cannot see is not moved: no stopped marker, compat exits 1 and says to run update where it runs"
# (M-2) A manager whose project compat does not know (no key dir, no 1.16 line: never set up or started since 1.18.0):
# its first start moves its records too, the backend stopped before and started after, and the start goes on.
UNK="$HOME/unknown mgr"; UR="$UNK/.claude/discord-agents"; mkdir -p "$UR/umgr"
printf 'DISCORD_BOT_TOKEN=tu\n' > "$UR/umgr/.env"; echo dev-manager > "$UR/umgr/mode"; printf '# ledger\nlocal\n' > "$UR/umgr/hosts"; echo '{}' > "$UR/umgr/access.json"
printf "DISCORD_CHANNEL_ID='7'\nDISCORD_USER_ID='8'\nDISCORD_ALLOW_IDS=''\n" > "$UR/config.env"
OLDU="$HOME/.claude-discord/records/monitor/umgr" NEWU="$HOME/.claude-discord/records/monitor/$(skey "$UNK")/umgr"
mon_pid_u() { local l=""; { read -r l < "$1/lock"; } 2>/dev/null || :; case $l in ''|*[!0-9]*) return 1;; esac; [[ $(tr '\0' ' ' < "/proc/$l/cmdline" 2>/dev/null) == *"--locked umgr "* ]] && echo "$l"; }
mdoc2 b1
(cd "$UNK" && CLAUDE_DISCORD_MONITOR_DIR=$OLDU bash "$S" monitor --start umgr >/dev/null 2>&1) || { echo "FAIL: fixture: the backend of umgr did not start at the old path"; exit 1; }
wait_alerts "$OLDU" 'local|/home/u/ws/p|b1' || { echo "FAIL: fixture: umgr's backend at the old path ran no pass: $(cat "$OLDU/monitor.log" 2>&1)"; exit 1; }
out=$(cd "$UNK" && bash "$S" --name umgr 2>&1) || :
n=0; while ! mon_pid_u "$NEWU" >/dev/null && [ "$n" -lt 1500 ]; do nap 0.002; n=$((n + 1)); done
grep -qF -- "\"DISCORD_STATE_DIR\": \"$HOME/.claude-discord/projects/$(skey "$UNK")/bots/umgr\"" <<<"$out" && [ ! -e "$OLDU" ] && [ "$(alerts "$NEWU")" = 'local|/home/u/ws/p|b1' ] && mon_pid_u "$NEWU" >/dev/null && grep -qF "$NEWU" <<<"$out" ||
  { echo "FAIL: a start in a project compat never saw moves a manager's old-path records (backend stopped and started) and launches: $out / $(ls -R "$HOME/.claude-discord/records/monitor" 2>&1)"; exit 1; }
(cd "$UNK" && bash "$S" monitor --stop umgr >/dev/null 2>&1) || :
n=0; while mon_pid_u "$NEWU" >/dev/null && [ "$n" -lt 1500 ]; do nap 0.002; n=$((n + 1)); done
rm -rf "$UNK" "$HOME/mon" "$HOME/pj.keep"; mv "$HOME/shim.real" "$HOME/.local/bin/claude-discord"
unset CLAUDE_DISCORD_MONITOR_TICK CLAUDE_DISCORD_MONITOR_PASS CLAUDE_DISCORD_MONITOR_HOST_CAP CLAUDE_DISCORD_MONITOR_LOCK_WAIT
echo "ok: a manager's first start in a project compat never saw moves its old-path records with the backend stopped and started, then launches"

# (g) records/projects retires: compat reads the union of the file and projects/*/project, and renames the file to
# records/projects.1.16 only once every line of it has a key dir; health --all, tui and the monitor verbs walk
# projects/*/project (a project that never started a bot after 1.18.0 is found once it does).
G1="$HOME/g one"; mkdir -p "$G1/.claude/discord-agents/gb"; printf 'DISCORD_BOT_TOKEN=tg\n' > "$G1/.claude/discord-agents/gb/.env"; echo none > "$G1/.claude/discord-agents/gb/mode"
printf "DISCORD_CHANNEL_ID='7'\nDISCORD_USER_ID='8'\nDISCORD_ALLOW_IDS=''\n" > "$G1/.claude/discord-agents/config.env"
GPF="$HOME/.claude-discord/records/projects"; printf '%s\n%s\n' "$G1" "$HOME/gone forever" > "$GPF"
out=$(cd "$HOME" && bash "$S" compat 2>&1) || { echo "FAIL: compat failed: $out"; exit 1; }
GS="$HOME/.claude-discord/projects/$(skey "$G1")"
[ -f "$GS/bots/gb/.env" ] && [ -f "$GPF" ] && [ ! -e "$GPF.1.16" ] || { echo "FAIL: compat moves a project the 1.16 list names and keeps the list while a line of it (a missing folder) has no key dir: $out / $(ls "$HOME/.claude-discord/records" 2>&1)"; exit 1; }
printf '%s\n' "$G1" > "$GPF"
out=$(cd "$HOME" && bash "$S" compat 2>&1) || { echo "FAIL: compat failed: $out"; exit 1; }
[ ! -e "$GPF" ] && [ -f "$GPF.1.16" ] && [ "$(<"$GPF.1.16")" = "$G1" ] || { echo "FAIL: the 1.16 list is renamed records/projects.1.16 once every line of it has a key dir: $out / $(ls "$HOME/.claude-discord/records" 2>&1)"; exit 1; }
doc=$(cd "$HOME" && bash "$S" health --all --json 2>/dev/null) || :
jq -e --arg p "$G1" --arg a "$M2A" 'any(.projects[]; .project == $p and (.bots | length) == 1 and .bots[0].bot == "gb") and any(.projects[]; .project == $a)' <<<"$doc" >/dev/null ||
  { echo "FAIL: health --all walks projects/*/project (the 1.16 list retired): $doc"; exit 1; }
rm -f "$GPF.1.16"; rm -rf "$G1"
echo "ok: compat reads the union of records/projects and projects/*/project, renames the file to records/projects.1.16 once every line has a key dir, and health --all walks the key dirs"
rm -rf "$M2A" "$M2B"

# boot (1.19.0): every bot of every recorded project, once. A bot `claude agents` lists with a pid (its pinned job or its
# name, started in its project) is skipped; one listed with no pid is recovered (bot recover --yes: its pinned job
# respawned); a failed recover is said and makes the exit 1. Its own HOME: boot walks every project of the machine.
BH=$HOME/bootbox; mkdir -p "$BH/pa" "$BH/pb" "$BH/bin"
for x in a b; do
  k=$(skey "$BH/p$x"); bd="$BH/.claude-discord/projects/$k/bots/b$x"; mkdir -p "$bd"
  printf '%s\n' "$(cd -P "$BH/p$x" && pwd)" > "$BH/.claude-discord/projects/$k/project"
  printf 'DISCORD_BOT_TOKEN=x\n' > "$bd/.env"; printf 'b%s000001\n' "$x" > "$bd/pinned-job"
done
# 1.19.1: a held bot (bot hold) and one with no token in its .env are skipped, nothing asked of them.
kb="$BH/.claude-discord/projects/$(skey "$BH/pb")/bots"; mkdir -p "$kb/bh" "$kb/bn"; printf 'DISCORD_BOT_TOKEN=x\n' > "$kb/bh/.env"; : > "$kb/bh/held"
printf 'DISCORD_CHANNEL_ID=1\n' > "$kb/bn/.env"
# 1.19.7: bx holds an inferred hold (session-end killed <time>) older than its newest session marker: stale (it has run since,
# then crashed), dropped, and bx is recovered; by holds the same with the marker older than the line: kept, skipped.
for x in bx by; do mkdir -p "$kb/$x/plugin-sessions"; printf 'DISCORD_BOT_TOKEN=x\n' > "$kb/$x/.env"; printf 'session-end killed %s\n' "$(dts '1 hour ago')" > "$kb/$x/held"; done
echo bx000001 > "$kb/bx/pinned-job"; : > "$kb/bx/plugin-sessions/s1"; : > "$kb/by/plugin-sessions/s1"; touch -d '2 hours ago' "$kb/by/plugin-sessions/s1" "$kb/by/plugin-sessions"
# 1.19.7: bs was stopped by a person (its pinned job's last daemon.log line is a (killed), the job no longer listed) just
# before the host went down: held is written and it is skipped; bb's last line is a (done): recovered as before.
mkdir -p "$kb/bs" "$BH/.claude"; printf 'DISCORD_BOT_TOKEN=x\n' > "$kb/bs/.env"; echo b5000001 > "$kb/bs/pinned-job"
printf '[2026-10-30T10:00:00.000Z] [bg] bg settled bb000001 (done)\n[2026-10-30T10:00:01.000Z] [bg] bg settled b5000001 (killed)\n' > "$BH/.claude/daemon.log"
printf '#!/bin/bash\ncase $1 in agents) echo %s;; respawn) echo "RESPAWN $2" >> "$HOME/calls"; [ ! -e "$KBDIR/bb/auto-start" ] || echo "PRE $2" >> "$HOME/pre"; [ ! -e "$HOME/fail" ] || exit 7;; *) echo "PLAIN $*";; esac\n' \
  "'[{\"name\":\"ba\",\"id\":\"ba000001\",\"pid\":4242,\"cwd\":\"$(cd -P "$BH/pa" && pwd)\"},{\"name\":\"bb\",\"id\":\"bb000001\",\"cwd\":\"$(cd -P "$BH/pb" && pwd)\",\"state\":\"done\"},{\"name\":\"bx\",\"id\":\"bx000001\",\"cwd\":\"$(cd -P "$BH/pb" && pwd)\",\"state\":\"done\"}]'" > "$BH/bin/claude"
chmod +x "$BH/bin/claude"
rc=0; out=$(cd "$BH" && KBDIR=$kb HOME=$BH PATH=$BH/bin:$PATH bash "$S" boot 2>&1) || rc=$?
# recover --yes: the respawn's job is in own-stop before the respawn; auto-start is there while the respawn runs (its SessionStart
# can come before the command returns) and stays after a successful one.
grep -qE "^bb000001 [0-9]+$" "$kb/bb/own-stop" && [ -e "$kb/bb/auto-start" ] && grep -qx 'PRE bb000001' "$BH/pre" || { echo "FAIL: recover --yes records the respawned job in own-stop and touches auto-start before a respawn that succeeds: $(cat "$kb/bb/own-stop" "$BH/pre" 2>&1) $(ls "$kb/bb" 2>&1)"; exit 1; }
rm -f "$kb/bb/auto-start"
: > "$BH/fail"; rc2=0; out2=$(cd "$BH" && KBDIR=$kb HOME=$BH PATH=$BH/bin:$PATH bash "$S" boot 2>&1) || rc2=$?
[ "$rc $rc2" = "0 1" ] && grep -qE "^boot: .*/pa ba: running \(pid 4242\), skipped$" <<<"$out" && grep -qE "^boot: .*/pb bb: recovered$" <<<"$out" &&
  grep -qE "^boot: .*/pb bb: failed \(exit 1\): .*claude respawn bb000001 \(exit 7\)" <<<"$out2" && [ "$(<"$BH/calls")" = $'RESPAWN bb000001\nRESPAWN bx000001\nRESPAWN bb000001\nRESPAWN bx000001' ] && [ ! -e "$kb/bb/auto-start" ] && [ ! -e "$kb/bx/held" ] &&
  grep -qE "^boot: .*/pb bx: recovered$" <<<"$out" && grep -qE "^boot: .*/pb by: held \(bot by hold\), skipped$" <<<"$out" && [ -f "$kb/by/held" ] &&
  grep -qE "^boot: .*/pb bs: stopped by a person \(daemon.log, 2026-10-30T10:00:01.000Z\), held, skipped$" <<<"$out" && [ "$(cut -d' ' -f1-2 "$kb/bs/held")" = "session-end killed" ] &&
  grep -qE "^boot: .*/pb bh: held \(bot bh hold\), skipped$" <<<"$out" && grep -qE "^boot: .*/pb bn: no token, skipped$" <<<"$out" ||
  { echo "FAIL: boot skips a bot listed with a pid or stopped by a person (held written), recovers one listed without, says a failure (exit 1): rc=$rc $rc2 / $out / $out2 / $(cat "$BH/calls" 2>&1)"; exit 1; }
# own-stop lines (1.19.7) are "<id> <epoch>", append only, each taken immediately before that job's own call: stop_sessions
# stopping two jobs in turn (the fake stop moves a fake clock on by 1 s) writes two lines, each epoch inside its own call's window; two writers
# in a loop keep every line; the recover above wrote one for bb000001.
grep -qE '^bb000001 [0-9]+$' "$kb/bb/own-stop" ||
  { echo "FAIL: recover writes '<id> <epoch>' to own-stop: $(cat "$kb/bb/own-stop" 2>&1)"; exit 1; }
OT=$BH/ot; mkdir -p "$OT"; : > "$OT/own-stop"
OTR=$( ( helpers=$BH/h; . "$D/bin/lib/state.sh" && . "$D/bin/lib/sessions.sh" || exit 1
  sleep() { [ "$1" = 3 ] || command sleep "$1"; }   # stop_sessions' 3 s token wait is not under test
  FAKE=1000; date() { if [ "${1:-}" = +%s ]; then echo "$FAKE"; else command date "$@"; fi; }   # a clock that a stop advances by 1 s: no real wait
  claude() { echo "$(date +%s) $1 $2" >> "$OT/calls"; [ "$1" != stop ] || FAKE=$((FAKE + 1)); }
  t0=$(date +%s); stop_sessions n $'aaaa0001 -\nbbbb0002 -' "$OT" >/dev/null 2>&1; t1=$(date +%s)
  echo "$t0 $t1"
  for w in 1 2; do ( for i in $(seq 1 30); do own_stop_add "$OT" "cccc000$w"; done ) & done; wait ) 2>&1 )
read -r t0 t1 <<<"$(head -n 1 <<<"$OTR")"
l1=$(grep '^aaaa0001 ' "$OT/own-stop"); l2=$(grep '^bbbb0002 ' "$OT/own-stop")
e1=${l1#* }; e2=${l2#* }; c1=$(sed -n 1p "$OT/calls" | cut -d' ' -f1); c2=$(sed -n 2p "$OT/calls" | cut -d' ' -f1)
{ [[ $e1 =~ ^[0-9]+$ ]] && [[ $e2 =~ ^[0-9]+$ ]] && [ "$e1" -ge "$t0" ] && [ "$e1" -le "$c1" ] && [ "$e2" -gt "$e1" ] && [ "$e2" -le "$c2" ] && [ "$c2" -le "$t1" ] &&
  [ "$(grep -cE '^cccc000[12] [0-9]+$' "$OT/own-stop")" = 60 ] && [ "$(wc -l < "$OT/own-stop" | tr -d ' ')" = 62 ]; } ||
  { echo "FAIL: stop_sessions writes '<id> <epoch>' just before each job's claude stop (two jobs, 1 fake second apart), and concurrent appends keep every line: t0=$t0 t1=$t1 e1=$e1 c1=$c1 e2=$e2 c2=$c2 / $OTR / $(wc -l < "$OT/own-stop")"; exit 1; }
# prune_dead_sessions writes the same format (its rm of a done row with a live worker logs "(killed)").
grep -q 'own_stop_add "\$dir" "\$id"' "$D/bin/claude-discord" && grep -q 'own_stop_add "\$3" "\$id"' "$D/bin/lib/sessions.sh" && grep -q 'own_stop_add "\$d" "\$b_id"' "$D/bin/lib/bot.sh" ||
  { echo "FAIL: every own-stop writer goes through own_stop_add"; exit 1; }
# no raw writer: the one redirect into own-stop is own_stop_add's own line
[ -z "$(grep -RnE '>>.*own-stop' "$D/bin" "$D/hooks" | grep -v 'own_stop_add()')" ] ||
  { echo "FAIL: nothing appends to own-stop outside own_stop_add: $(grep -RnE '>>.*own-stop' "$D/bin" "$D/hooks")"; exit 1; }
rm -rf "${BH:?}"
# The SessionEnd hook and person_stopped describe one order of the daemon's killed line and the hook (measured, 2.1.314: the
# line comes about 0.6 s AFTER the hook starts): neither says the hook runs behind it.
grep -q 'AFTER it starts' "$D/bin/lib/state.sh" && grep -q '0\.6 s ahead' "$D/hooks/turn/on-session-end" && ! grep -q '0\.6 s behind' "$D/hooks/turn/on-session-end" ||
  { echo "FAIL: on-session-end and state.sh agree on the order of the hook and the killed line (0.6 s ahead, not behind)"; exit 1; }
echo "ok: boot recovers every bot of the machine that runs no session (bot recover --yes), skips one that does, and exits 1 when one failed"

# recover (1.19.8), its own HOME. The stub answers `agents --json` from plain and `agents --json --all` from all (a file
# that is not there: the call fails); any other call goes to claude.calls. rt <answer> runs it at a terminal.
RH=$HOME/rcbox; mkdir -p "$RH/p" "$RH/bin" "$RH/.claude"; RP=$(cd -P "$RH/p" && pwd); RK="$RH/.claude-discord/projects/$(skey "$RP")"; RD=$RK/bots/rb
mkdir -p "$RD"; printf '%s\n' "$RP" > "$RK/project"; printf 'DISCORD_BOT_TOKEN=x\n' > "$RD/.env"; echo aa000001 > "$RD/pinned-job"
printf '#!/bin/bash\ncase $1 in agents) f=$HOME/plain; [ "${3:-}" != --all ] || f=$HOME/all; [ -e "$f" ] || exit 1; echo "$(<"$f")";; *) echo "$*" >> "$HOME/claude.calls";; esac\n' > "$RH/bin/claude"; chmod +x "$RH/bin/claude"
rr() { rc=0; out=$(cd "$RP" && HOME=$RH PATH=$RH/bin:$PATH bash "$S" bot rb recover "$@" </dev/null 2>&1) || rc=$?; }
rt() { rc=0; out=$(printf '%s\n' "$1" | HOME=$RH PATH=$RH/bin:$PATH python3 -c 'import os, pty, sys; sys.exit(os.waitstatus_to_exitcode(pty.spawn(sys.argv[1:])))' bash -c 'cd "$1" && exec bash "$2" bot rb recover' x "$RP" "$S" 2>&1) || rc=$?; }
rlast() { { tail -n 1 "$RD/recover.log" 2>/dev/null || :; } | cut -d' ' -f4-; }
# (a) The pinned job settled: only --all lists it, done, in this cwd. It is the last session: respawned, its conversation kept.
echo '[]' > "$RH/plain"; printf '[{"id":"aa000001","cwd":"%s","state":"done"},{"id":"bb000002","cwd":"%s","state":"done"}]\n' "$RP" "$RP" > "$RH/all"
rt y; A="$rc $out"; A2=$(rlast); A3=$(cat "$RH/claude.calls" 2>&1) || :; rm -f "$RH/claude.calls"; rr --yes
[[ $A == 0*"its last session aa000001 (pinned-job (done))"*"run: claude respawn aa000001"* ]] && [ "$A3" = "respawn aa000001" ] && [ "$A2" = "recover: claude respawn aa000001 (exit 0)" ] &&
  [ "$rc" = 0 ] && [ "$(<"$RH/claude.calls")" = "respawn aa000001" ] && [ "$(rlast)" = "recover --yes: claude respawn aa000001 (exit 0)" ] ||
  { echo "FAIL: recover respawns a settled pinned job only --all lists, at a terminal and with --yes: $A / $A2 / $A3 / rc=$rc $out"; exit 1; }
# (b) Not that row: the pin's in another cwd, the pin's not done, a done row (by the bot's name, with a plugin-sessions
# marker) that is not the pin: a fresh start. So does a failed --all listing, as before it was asked. --fresh stops nothing
# that only --all lists. A session the plain listing has (by name) is the one session, the settled pin no second one.
mkdir -p "$RD/plugin-sessions"; : > "$RD/plugin-sessions/cc000003-1111-2222-3333-444444444444"; rm -f "$RH/claude.calls"
printf '[{"id":"aa000001","cwd":"/elsewhere","state":"done"},{"id":"aa000001","cwd":"%s","state":"working"},{"id":"cc000003","name":"rb","sessionId":"cc000003-1111-2222-3333-444444444444","cwd":"%s","state":"done"}]\n' "$RP" "$RP" > "$RH/all"
rr; A="$rc $out"; rm -rf "$RD/plugin-sessions"
mv "$RH/all" "$RH/all.keep"; rr; B="$rc $out"; mv "$RH/all.keep" "$RH/all"
printf '[{"id":"aa000001","cwd":"%s","state":"done"}]\n' "$RP" > "$RH/all"; rr --fresh; C="$rc $out"
printf '[{"id":"dd000004","name":"rb","cwd":"%s","state":"working","pid":77}]\n' "$RP" > "$RH/plain"; rr; E="$rc $out"; echo '[]' > "$RH/plain"
[[ $A == 3*"run: cd $RP && claude-discord --bg --name rb"* ]] && [[ $A != *"claude respawn"* ]] && [[ $B == 3*"run: cd $RP && claude-discord --bg --name rb"* ]] && [[ $B != *refused* ]] &&
  [[ $C == 3*"run: cd $RP && claude-discord --bg --name rb    (no session of rb is listed, so nothing is stopped"* ]] && [[ $E == 3*"run: claude respawn dd000004"* ]] && [ ! -e "$RH/claude.calls" ] ||
  { echo "FAIL: only the pin's own row, this cwd, state done counts, and only when nothing else was found; a failed --all listing is a fresh start: $A / $B / $C / $E"; exit 1; }
# (c) A person stopped the pinned job: --yes refuses, logged, nothing run; without --yes the person is asked, as before.
printf '[2026-10-30T10:00:01.000Z] [bg] bg settled aa000001 (killed)\n' > "$RH/.claude/daemon.log"; rm -f "$RD/own-stop" "$RD/auto-start"
rr --yes; A="$rc $out"; A2=$(rlast); rt n
[[ $A == 1*"a person stopped rb"* ]] && [ "$A2" = "recover --yes: refused: stopped by a person (daemon.log, 2026-10-30T10:00:01.000Z) (exit 1)" ] &&
  [ "$rc" = 4 ] && grep -q 'Recover rb? \[y/N\]' <<<"$out" && [ ! -e "$RH/claude.calls" ] && [ ! -e "$RD/auto-start" ] && [ ! -e "$RD/own-stop" ] ||
  { echo "FAIL: recover --yes refuses a bot a person stopped, logged, and recover without --yes reaches its question: $A / $A2 / rc=$rc $out"; exit 1; }
rm -f "$RH/.claude/daemon.log"
# (d) Every refusal is in recover.log, so the monitor's "its recover.log says why" is true.
rrf() { local why=$1; shift; rr "$@"; [ "$rc" = 1 ] && [[ $(rlast) == "recover${*:+ $*}: refused: $why"*" (exit 1)" ]] && [ ! -e "$RH/claude.calls" ] || { echo "FAIL: this refusal writes recover.log ($why): rc=$rc $out / $(rlast)"; exit 1; }; }
mv "$RH/plain" "$RH/plain.keep"; rrf 'claude agents failed' --yes; mv "$RH/plain.keep" "$RH/plain"
printf '[{"id":"dd000004","name":"rb","cwd":"%s"},{"id":"ee000005","name":"rb","cwd":"%s"}]\n' "$RP" "$RP" > "$RH/plain"; rrf '2 sessions listed'
printf '[{"pid":4242,"name":"rb","cwd":"%s"}]\n' "$RP" > "$RH/plain"; rrf 'a foreground session (pid 4242)'; echo '[]' > "$RH/plain"; rm -f "$RH/all"
jq -n --arg p "$RP" '.projects[$p].hasTrustDialogAccepted = false' > "$RH/.claude.json"; rrf 'an untrusted workspace'; rm -f "$RH/.claude.json"
RT=$RH/.claude/projects/$(skey "$RP"); mkdir -p "$RT" "$RD/plugin-sessions"; : > "$RD/plugin-sessions/ff000006-1111-2222-3333-444444444444"; : > "$RT/ff000006-1111-2222-3333-444444444444.jsonl"; rrf 'a transcript changed within 15 minutes' --fresh
# (f) 1.19.9: --yes never interrupts a working session: a respawn plan with a transcript touched now is deferred (exit 6,
# logged, nothing run); without --yes the same state reaches the question. An old transcript runs the respawn.
printf '[{"id":"aa000001","cwd":"%s","state":"working","pid":88}]\n' "$RP" > "$RH/plain"; echo aa000001 > "$RD/pinned-job"; rm -f "$RH/claude.calls"
RT=$RH/.claude/projects/$(skey "$RP"); mkdir -p "$RT" "$RD/plugin-sessions"; rm -f "$RD/plugin-sessions"/* "$RT"/*.jsonl; : > "$RD/plugin-sessions/fa000006-1111-2222-3333-444444444444"; : > "$RT/fa000006-1111-2222-3333-444444444444.jsonl"
rr --yes; A="$rc $out"; A2=$(rlast); rt n; B="$rc $out"
touch -d '20 minutes ago' "$RT/fa000006-1111-2222-3333-444444444444.jsonl"; rr --yes; C="$rc"
[[ $A == 6*"--yes does not interrupt it"* ]] && [ "$A2" = "recover --yes: refused: a transcript changed within 15 minutes (exit 6)" ] && [ "$(wc -l < "$RH/claude.calls" | tr -d ' ')" = 1 ] &&
  [ "$(<"$RH/claude.calls")" = "respawn aa000001" ] && [ "$C" = 0 ] && [[ $B == 4*"Recover rb? [y/N]"* ]] ||
  { echo "FAIL: recover --yes defers (exit 6, logged, nothing run) while a transcript moves, asks without --yes, runs once it is old: $A / $A2 / $B / $C / $(cat "$RH/claude.calls" 2>&1)"; exit 1; }
# (g) CLAUDE_DISCORD_RECOVER_BY names the caller in a --yes line; a value outside ^[a-z-]{1,20}$ is ignored.
rm -f "$RH/claude.calls"; rc=0; out=$(cd "$RP" && CLAUDE_DISCORD_RECOVER_BY=monitor HOME=$RH PATH=$RH/bin:$PATH bash "$S" bot rb recover --yes </dev/null 2>&1) || rc=$?; A=$(rlast)
rc=0; out=$(cd "$RP" && CLAUDE_DISCORD_RECOVER_BY='Bad;x' HOME=$RH PATH=$RH/bin:$PATH bash "$S" bot rb recover --yes </dev/null 2>&1) || rc=$?; B=$(rlast)
[ "$A" = "recover --yes by monitor: claude respawn aa000001 (exit 0)" ] && [ "$B" = "recover --yes: claude respawn aa000001 (exit 0)" ] ||
  { echo "FAIL: recover.log names CLAUDE_DISCORD_RECOVER_BY when valid and ignores an invalid one: $A / $B"; exit 1; }
rm -f "$RH/claude.calls" "$RD/plugin-sessions"/* "$RT"/*.jsonl; echo '[]' > "$RH/plain"
# (e) The monitor says at its start that it cannot recover. An empty ledger: its first pass asks nothing of anyone, and TERM ends it.
# A short tick: a TERM between the main loop's `sleep &` and its `tp=$!` leaves that sleep behind, so it must be short.
RM=$RH/.claude-discord/records/monitor/$(skey "$RP")/rb; : > "$RD/hosts"
NOCL=""; IFS=: read -ra RPA <<<"$PATH"; for p in "${RPA[@]}"; do [ -x "$p/claude" ] || NOCL=$NOCL${NOCL:+:}$p; done
rmon() {
  local rp n=0
  (cd "$RP" && export HOME=$RH PATH=$1 CLAUDE_DISCORD_MONITOR_TICK=0.2 && exec bash "$D/monitor/monitor.sh" "$S" --locked rb </dev/null >/dev/null 2>&1) & rp=$!
  until grep -q ' pass hosts=' "$RM/monitor.log" 2>/dev/null || [ "$n" -ge 7500 ]; do nap 0.002; n=$((n + 1)); done
  kill "$rp"; wait "$rp" || :
}
rmon "$NOCL"; A=$(<"$RM/monitor.log"); rm -f "$RM/monitor.log"
rmon "$RH/bin:$PATH"; B=$(<"$RM/monitor.log")
[ "$(grep -cF "warning: claude is not on PATH ($NOCL): the automatic recover cannot run" <<<"$A")" = 1 ] && grep -q 'Z start$' <<<"$B" && [[ $B != *warning* ]] ||
  { echo "FAIL: the monitor logs one warning at its start when claude is not on PATH, and none when it is: $A / $B"; exit 1; }
rm -rf "${RH:?}"
echo "ok: recover (1.19.8, 1.19.9) respawns a settled pinned job (only its own row of --all, only when nothing else is found), recover --yes refuses a bot a person stopped, every refusal is in recover.log, and the monitor warns when claude is not on PATH"

# access set with no terminal writes with no question when nothing in it widens who can drive the bot: no W, N or E
# line, no mode change, and every channel it adds is in the bot's own server (its main channel's, as Discord says). Else it
# prints the changes and exits 3 as before. The bot: 900 (the main channel) and 901 (open to anyone) listed; 111 (the owner)
# and 222 on 900, 333 on the DM allowlist only; 902, 903 and 950 are channels of the server (950 is not, in the stub).
NP="$HOME/ntproj"; NR=$(broot "$NP"); NS=$(pstate "$NP"); ND="$NR/nt"; mkdir -p "$ND"
printf "DISCORD_CHANNEL_ID='900'\nDISCORD_USER_ID='111'\n" > "$NS/config.env"; echo none > "$ND/mode"; printf 'DISCORD_BOT_TOKEN=tokNtUnique\n' > "$ND/.env"
NF='{"dmPolicy":"allowlist","allowFrom":["333"],"groups":{"900":{"requireMention":true,"allowFrom":["111","222"]},"901":{"requireMention":true,"allowFrom":[]}}}'
NCH='[{"id":"900","type":0},{"id":"901","type":0},{"id":"902","type":0},{"id":"903","type":5},{"id":"904","type":2}]'
# nt <words>: the call with no terminal (the $(...) takes stdout); nt_reset: the bot as it was, the guild known, curl's log and queue empty.
nt() { ARC=0; AO=$(cd "$NP" && bash "$S" access nt set "$@" 2>"$HOME/nt.err") || ARC=$?; AE=$(<"$HOME/nt.err"); }
nt_reset() { printf '%s\n' "$NF" > "$ND/access.json"; rm -f "$ND/access.log" "$ND/access.json.lock"; echo none > "$ND/mode"; printf '900 5 dev-bots %s\n' "$(date +%s)" > "$ND/channel-guild"
  : > "$CURL_LOG"; : > "$CURL_STDIN_LOG"; : > "$CURL_REPLIES"; }
# nt_refused <what> <pattern> [<reason>]: exit 3, the changes were printed (a line matching the pattern among them), the reason said on stderr
# (a line "why: <reason>" matching the third word, when given), nothing written, no log line, no post.
nt_refused() { grep -q -- "$2" <<<"$AO" && [ "$ARC" = 3 ] && grep -q -- "^claude-discord: access: why: ${3:-.}" <<<"$AE" && grep -q 'not a terminal (stdin and stdout), so nothing was changed' <<<"$AE" && [ "$(<"$ND/access.json")" = "$NF" ] && [ ! -e "$ND/access.log" ] && ! grep -q '/messages' "$CURL_LOG" ||
  { echo "FAIL: access set with no terminal must refuse (exit 3, nothing written or posted) $1: rc=$ARC $AO / $AE / $(cat "$ND/access.log" "$CURL_LOG" 2>&1)"; exit 1; }; }
# A channel of the server whose senders are all listed already (222 on 900, 333 on the DM allowlist, the owner): written, logged, one post.
nt_reset; queue_line "200 $NCH"; queue_line '200 {"id":"1"}'
nt channel+902 allow:902+222 allow:902+333
[ "$ARC" = 0 ] && grep -q '^    #902: + listens here: an @mention required, from 111, 222, 333$' <<<"$AO" && grep -q 'written without a question: no terminal here, and nothing in it widens who can drive nt' <<<"$AO" &&
  [ "$(jq -c '.groups["902"]' "$ND/access.json")" = '{"requireMention":true,"allowFrom":["111","222","333"]}' ] &&
  [[ $(<"$ND/access.log") =~ ^20[0-9-]{8}T[0-9:]{8}Z\ $(id -un)\ $(uname -n | cut -d. -f1)\ access.json:\ channel\+902\ allow:902\+222\ allow:902\+333\ \(no\ terminal,\ no\ widening\)$ ]] &&
  [ "$(wc -l < "$CURL_LOG")" = 2 ] && [ "$(grep -c 'channels/902/messages$' "$CURL_LOG")" = 1 ] && grep -q 'guilds/5/channels$' "$CURL_LOG" &&
  [ "$(sort -u "$CURL_STDIN_LOG")" = "Authorization: Bot tokNtUnique" ] && [[ $AO$AE$(<"$CURL_LOG") != *tokNt* ]] &&
  grep -q '"content":"[^"]*claude-discord access[^"]*"' "$CURL_LOG" ||
  { echo "FAIL: a channel of the bot's server whose senders are all listed already is written with no terminal: exit 0, access.log marked, one post in it: rc=$ARC $AO / $AE / $(cat "$ND/access.log" "$CURL_LOG" 2>&1)"; exit 1; }
# The server is asked for once when it is not cached: the main channel's guild, then its channels. A forum or a news channel counts; a post that fails
# is logged and is no failure; the same call with 903 (an announcement channel).
nt_reset; rm -f "$ND/channel-guild"; queue_line '200 {"id":"900","guild_id":"5"}'; queue_line "200 $NCH"; queue_line '403 {"message":"Missing Access"}'
nt channel+903 allow:903+333
[ "$ARC" = 0 ] && [ "$(jq -c '.groups["903"].allowFrom' "$ND/access.json")" = '["111","333"]' ] && [ "$(grep -c 'api/v10/' "$CURL_LOG")" = 3 ] && grep -q 'channels/900$' "$CURL_LOG" &&
  [ "$(tail -n 1 "$ND/access.log" | cut -d' ' -f4-)" = "the post in 903 failed (HTTP 403)" ] ||
  { echo "FAIL: an uncached server is asked for (channels/<main>, then its channels), a refused post is logged and the command still exits 0: rc=$ARC $AO / $AE / $(cat "$ND/access.log" "$CURL_LOG" 2>&1)"; exit 1; }
# A change with no new channel asks Discord nothing and posts nothing (a sender off a channel, one off the DM allowlist).
nt_reset; nt allow:900-222 dm-333
[ "$ARC" = 0 ] && [ "$(jq -c '.groups["900"].allowFrom' "$ND/access.json")" = '["111"]' ] && [ ! -s "$CURL_LOG" ] && grep -q '(no terminal, no widening)$' "$ND/access.log" ||
  { echo "FAIL: a change that adds no channel is written with no terminal and asks Discord nothing: rc=$ARC $AO / $AE / $(cat "$CURL_LOG" 2>&1)"; exit 1; }
# The opposites. A sender the bot lists nowhere (444), also one it has a name for but lists nowhere (555; 901, open to anyone,
# lists nobody: it makes nobody known): new to this bot, a widening. Nothing is asked of Discord for it.
printf '555 nobody\n' > "$ND/user-names"
for w in allow:902+444 allow:902+555; do
  nt_reset; queue_line "200 $NCH"; nt channel+902 "$w"
  nt_refused "for $w (a sender new to this bot)" '^  ! [^:]*: new to this bot: may write to it in #902$' 'it widens who can drive nt (the lines marked !)$'
done
[ ! -s "$CURL_LOG" ] || { echo "FAIL: a widening is refused before Discord is asked: $(<"$CURL_LOG")"; exit 1; }
nt_reset; nt channel+902 allow:902=any
nt_refused "for allow:=any on a new channel" '^  ! #902: anyone in the channel may write to it$'
nt_reset; nt channel+902 mention:902=off
nt_refused "for a new channel with no @mention required" '^  ! #902: answers every message there, with no @mention$'
nt_reset; nt allow:900=any
nt_refused "for words that widen an existing channel" '^  ! #900: from 111, 222 -> from anyone in the channel$'
# A channel that is not in the bot's server; a server nobody can name (no cache and no answer, a refusal, no token).
nt_reset; queue_line "200 $NCH"; nt channel+950
nt_refused "for a channel of another server" '^    #950: + listens here: an @mention required, from 111$' "channel not in the bot's server: 950\$" && grep -q 'guilds/5/channels$' "$CURL_LOG" || { echo "FAIL: the server's channels were not asked for"; exit 1; }
nt_reset; rm -f "$ND/channel-guild"; nt channel+902
nt_refused "when the server is not known (Discord does not answer)" '^    #902: + listens here' 'server unknown: Discord did not say which server the main channel 900 is in (HTTP 000)$'
nt_reset; queue_line '200 {"id":"900","guild_id":"5"}'; queue_line '500 {}'; rm -f "$ND/channel-guild"; nt channel+902
nt_refused "when the server's channels are refused (HTTP 500)" '^    #902: + listens here' "server unknown: the server's channels: HTTP 500\$"
nt_reset; mv "$ND/.env" "$ND/.env.off"; nt channel+902
mv "$ND/.env.off" "$ND/.env"; nt_refused "when the bot has no token" '^    #902: + listens here' 'server unknown: no token in '
# A mode change in the words, a warning in the result, an owner-less bot: each keeps the question.
nt_reset; nt allow:900-222 mode=dev-manager
nt_refused "for a change of mode" '^    mode: none -> dev-manager: it gets a hosts ledger' 'it changes the mode$' && [ "$(<"$ND/mode")" = none ] || { echo "FAIL: the mode changed"; exit 1; }
nt_reset; nt allow:900-111
nt_refused "for a change that warns (the owner taken off a channel)" '^warning: 111 is the owner of this bot' 'it has a warning (above)$'
# A list in which no entry is an id (junk, or a number: the plugin compares strings) is not "anyone" (the plugin filters on a
# non-empty list by exact element), and holds nobody known: a sender added to it is new to this bot. An id that is a string counts.
NFA=$NF
nt_with() { NF=$(jq -c --argjson l "$1" '.groups["901"].allowFrom = $l' <<<"$NFA"); nt_reset; }
nt_with '["abc"]'; nt allow:901+444
nt_refused "for a sender added to a list with no id in it" '^  ! 444: new to this bot: may write to it in #901$' 'it widens who can drive nt'
! grep -q 'from anyone' <<<"$AO" || { echo "FAIL: a list with no id in it is not read as anyone: $AO"; exit 1; }
nt_with '["abc"]'; nt allow:901=any
nt_refused "for opening a list with no id in it to anyone" '^  ! #901: from entries that are no id (nobody) -> from anyone in the channel$'
nt_with '["abc"]'; nt allow:901+222
[ "$ARC" = 0 ] && [ "$(jq -c '.groups["901"].allowFrom' "$ND/access.json")" = '["abc","222"]' ] ||
  { echo "FAIL: a sender the bot lists already goes onto a list with no id in it, which keeps its entry: rc=$ARC $AO / $AE"; exit 1; }
nt_with '[444]'; nt allow:900+444
nt_refused "for a number in another list (it never matches)" '^  ! 444: new to this bot: may write to it in #900$'
nt_with '[444]'; nt allow:901+444
nt_refused "for the number itself added as an id" '^  ! 444: new to this bot: may write to it in #901$'
nt_with '["444"]'; nt allow:900+444
[ "$ARC" = 0 ] && [ "$(jq -c '.groups["900"].allowFrom' "$ND/access.json")" = '["111","222","444"]' ] ||
  { echo "FAIL: a string id in another list is known: rc=$ARC $AO / $AE"; exit 1; }
# What the plugin does with allowFrom (server.ts: `allowFrom ?? []`, filtered only when .length > 0, with .includes(id)): a list
# filters by exact element, a non-empty STRING by substring ("111 222" lets 111 and 222 in), and a number, a boolean, an object,
# null, "" and {} have no positive .length, so they let ANYONE in. A number, a boolean or an object reads as anyone here too: a
# sender put on it narrows it (and the owner is warned when that locks them out); a removal never empties it. Only null (and an
# absent key) is a canonical shape, though: every other value that is not a list of strings gets an N line, so a call with no
# terminal never writes while one exists (the plugin's reading of it is not modelled, it is asked about at a terminal).
nt_with 'null'; nt allow:901+222
[ "$ARC" = 0 ] && grep -q '^    #901: from anyone -> from 222$' <<<"$AO" && [ "$(jq -c '.groups["901"].allowFrom' "$ND/access.json")" = '["222"]' ] ||
  { echo "FAIL: an allowFrom that is null is anyone, a sender put on it narrows it: rc=$ARC $AO / $AE"; exit 1; }
for nt_v in '7' 'true' 'false' '{"a":1}' 'null' '""' '{}' '{"length":1}' '[1]' '["a",2]'; do
  nt_t=$(jq -r type <<<"$nt_v")
  if [ "$nt_v" != null ]; then
    for nt_w in allow:901+222 allow:901+444 channel-901 allow:900-222; do
      nt_with "$nt_v"; nt $nt_w
      nt_refused "for $nt_w with an allowFrom that is $nt_v" "^warning: #901: allowFrom ($nt_t) is not what claude-discord writes: set it at a terminal\$"
    done
  fi
  case $nt_v in '{"length":1}'|'[1]'|'["a",2]') continue;; esac
  nt_with "$nt_v"; nt allow:901=any
  [ "$ARC" = 0 ] && [[ $AO == *"already so; nothing to change"* ]] || { echo "FAIL: allow:901=any on an allowFrom that is $nt_v (already anyone) changes nothing: rc=$ARC $AO / $AE"; exit 1; }
done
# A non-empty string is a substring filter in the plugin: read as a list with no id (nobody known), and the N line asks for a terminal,
# so a no-terminal call never writes while one exists (the plugin's "111 222" lets 111 and 222 in, which no id test here can say).
for nt_v in '"111"' '"111 222"' '"x111x"'; do
  for nt_w in allow:900-222 channel-901 allow:901+222; do
    nt_with "$nt_v"; nt $nt_w
    nt_refused "for $nt_w with an allowFrom that is the string $nt_v" '^warning: #901: allowFrom (string) is not what claude-discord writes: set it at a terminal$' 'it has a warning (above)$'
  done
done
nt_with '"111"'; nt allow:901-999
[ "$ARC" = 2 ] && grep -q '^claude-discord: access: allow:901: that would leave no sender' <<<"$AE" && [ "$(<"$ND/access.json")" = "$NF" ] ||
  { echo "FAIL: a removal on a string allowFrom would leave no sender and is refused (exit 2): rc=$ARC $AO / $AE"; exit 1; }
# The owner (111) locked out by a narrowing or a removal while 900 lists only 222 and 901 holds a value: the open readings (a number,
# a boolean, an object) warn of the owner; the controls ([] and ["111"]) still do; strings are caught by the N line above.
NFL=$(jq -c '.groups["900"].allowFrom = ["222"]' <<<"$NFA")
for nt_v in '[]' '["111"]' '7' 'true' '{"a":1}'; do
  for nt_w in channel-901 allow:901+222; do
    [ "$nt_v $nt_w" != '["111"] allow:901+222' ] || continue   # 111 stays on the list: the owner is not cut off
    NFA_SAVE=$NFA; NFA=$NFL; nt_with "$nt_v"; NFA=$NFA_SAVE; nt $nt_w
    nt_refused "for $nt_w with 111 the owner and 901 holding $nt_v" "^warning: 111 is the owner of this bot (DISCORD_USER_ID) and no channel it listens in lets them write to it any more\$" 'it has a warning (above)$'
  done
done
# The sentinel is no person: "abc" stays on the list when 222 is added, so nobody is shown leaving, and a list is told as entries that are no id.
nt_with '["abc"]'; nt allow:901+222
! grep -q 'not-an-id' <<<"$AO" || { echo "FAIL: the sentinel of a list with no id is shown as a person: $AO"; exit 1; }
# The DM allowlist is guarded the same way: a top-level allowFrom that is not a list of strings (here the string "111 222", which the
# plugin matches by substring) is warned of, a no-terminal call is refused, and it reads as a list nobody is on: dm=off and dm-222
# are changes (an allowlist -> off), not "already so" (dm_allow read [] and said nothing changed), and the sentinel is no person.
for nt_v in '"111 222"' '7' '{"length":1}'; do
  nt_t=$(jq -r type <<<"$nt_v")
  for nt_w in dm=off dm-222 dm+444 allow:900-222; do
    [ "$nt_v" != 7 ] || case $nt_w in dm=off|dm-222) continue;; esac   # a number is no filter (anyone, "off" already): those change nothing
    NF=$(jq -c --argjson l "$nt_v" '.allowFrom = $l' <<<"$NFA"); nt_reset; nt $nt_w
    nt_refused "for $nt_w with a top-level allowFrom that is $nt_v" "^warning: DMs: allowFrom ($nt_t) is not what claude-discord writes: set it at a terminal\$"
  done
done
NF=$(jq -c '.allowFrom = "111 222"' <<<"$NFA"); nt_reset; nt dm=off
! grep -q 'already so' <<<"$AO" && grep -q '^    DMs: allowlist -> off$' <<<"$AO" || { echo "FAIL: dm=off on a top-level allowFrom \"111 222\" is a change, not already so: rc=$ARC $AO / $AE"; exit 1; }
nt_reset; nt dm-222
! grep -q 'already so' <<<"$AO" && ! grep -q 'not-an-id' <<<"$AO" || { echo "FAIL: dm-222 on a top-level allowFrom \"111 222\" is no 'already so' and shows no sentinel person: rc=$ARC $AO / $AE"; exit 1; }
# The rest of the shape claude-discord writes. The plugin reads a group of 7 or "x" as a channel that listens (anyone, with an @mention),
# a requireMention of "no" as true and of 0 as false, an unknown dmPolicy as pairing, and groups as [] as a server listening nowhere:
# none of that is modelled, so each gets an N line and a legitimate add with no terminal is refused.
nt_odd() { NF=$(jq -c "$1" <<<"$NFA"); nt_reset; queue_line "200 $NCH"; queue_line '200 {"id":"1"}'; nt channel+902 allow:902+222
  nt_refused "for an add with $1" "$2" "${3:-it has a warning (above)\$}"; }   # groups=[]: no group to keep, so the add widens and says so first
nt_odd '.groups["901"] = 7' '^warning: #901: the group (number) is not what claude-discord writes: set it at a terminal$'
nt_odd '.groups["901"] = "x"' '^warning: #901: the group (string) is not what claude-discord writes: set it at a terminal$'
nt_odd '.groups["901"] = {"requireMention":"no"}' '^warning: #901: requireMention (string) is not what claude-discord writes: set it at a terminal$'
nt_odd '.groups["901"].requireMention = 0' '^warning: #901: requireMention (number) is not what claude-discord writes: set it at a terminal$'
nt_odd '.groups = []' '^warning: groups (array) is not what claude-discord writes: set it at a terminal$' 'it widens who can drive nt'
nt_odd '.dmPolicy = "closed"' '^warning: DMs: dmPolicy (string) is not what claude-discord writes: set it at a terminal$'
nt_odd '.dmPolicy = 7' '^warning: DMs: dmPolicy (number) is not what claude-discord writes: set it at a terminal$'
nt_odd '.mentionPatterns = [""]' '^warning: mentionPatterns (array) is not what claude-discord writes: set it at a terminal$'
# The opposite: a canonical file (arrays of strings, absent keys, no top-level allowFrom) still writes a same-guild add with no terminal.
NF='{"dmPolicy":"allowlist","groups":{"900":{"requireMention":true,"allowFrom":["111","222"]},"901":{"requireMention":true}}}'
nt_reset; queue_line "200 $NCH"; queue_line '200 {"id":"1"}'; nt channel+902 allow:902+222
[ "$ARC" = 0 ] && [ "$(jq -c '.groups["902"].allowFrom' "$ND/access.json")" = '["111","222"]' ] && ! grep -q 'allowFrom is not a list' <<<"$AO" ||
  { echo "FAIL: a canonical file (absent keys, arrays of strings) still takes a same-guild add with no terminal: rc=$ARC $AO / $AE"; exit 1; }
NF=$NFA
# peers.json is shared: it lists this bot too (nt, 555). The dev-manager peer warning is about the peers that go onto the lists
# (pb, 666), never the bot itself (nt, 555), so narrowing an open channel while entering dev-manager names no peer line for 555.
printf '{"peers":[{"name":"nt","bot_id":"555"},{"name":"pb","bot_id":"666"}]}\n' > "$NS/peers.json"
nt_reset; nt mode=dev-manager allow:901+111
[ "$ARC" = 3 ] || { echo "FAIL: entering dev-manager with a peer is refused with no terminal: rc=$ARC $AO / $AE"; exit 1; }
! grep -q '555.*is a peer dev bot' <<<"$AO" || { echo "FAIL: the bot itself (nt, 555 in the shared peers.json) is named as a peer it cuts off: $AO"; exit 1; }
printf '{"peers":[{"name":"nt","bot_id":"555"}]}\n' > "$NS/peers.json"
nt_reset; nt mode=dev-manager allow:901+111
nt_refused "for entering dev-manager (the mode)" '^    mode: none -> dev-manager' 'it changes the mode$'
! grep -q 'peer dev bot' <<<"$AO" || { echo "FAIL: peers.json listing only the bot gives a peer warning: $AO"; exit 1; }
# Entering dev-manager with an allowFrom that is no list (a string, a number): the peer merge leaves that group as it is, the diff
# is made, and it is not "not valid JSON".
printf '{"peers":[{"name":"pb","bot_id":"666"}]}\n' > "$NS/peers.json"
for nt_v in '"111"' '7' '{"a":1}'; do
  nt_with "$nt_v"; nt mode=dev-manager
  [ "$ARC" = 3 ] && ! grep -q 'not valid JSON' <<<"$AE" && grep -q '^    mode: none -> dev-manager' <<<"$AO" && [ "$(<"$ND/access.json")" = "$NF" ] ||
    { echo "FAIL: entering dev-manager with an allowFrom that is $nt_v must give a diff, not the JSON error: rc=$ARC $AO / $AE"; exit 1; }
done
# The bot is left out of the peers by its bot-id when it is kept (bot-id 555), else by name: a peer of the bot's own name and another id
# (666) is a peer and goes onto the lists (new to this bot), while the peer with the bot's id (555, whatever its name) does not.
printf '{"peers":[{"name":"nt","bot_id":"666"},{"name":"other","bot_id":"555"}]}\n' > "$NS/peers.json"
NF=$NFA; printf '555\n' > "$ND/bot-id"; nt_reset; nt mode=dev-manager
grep -q '^  ! nt (666): new to this bot: may write to it in #900$' <<<"$AO" && ! grep -q '555.*new to this bot' <<<"$AO" ||
  { echo "FAIL: with bot-id 555, the peer named like the bot (666) goes onto the lists and the one with its id (555) does not: rc=$ARC $AO / $AE"; exit 1; }
rm -f "$ND/bot-id"; nt_reset; nt mode=dev-manager
! grep -q '666.*new to this bot' <<<"$AO" && grep -q '555.*new to this bot' <<<"$AO" ||
  { echo "FAIL: with no bot-id the bot is left out by name (666 not added, 555 added): rc=$ARC $AO / $AE"; exit 1; }
printf '{"peers":[]}\n' > "$NS/peers.json"
NF=$NFA
# The owner (111) can no longer write anywhere: a removal of the channels that listed them, when no channel left lets them
# (an open channel does). The main channel (900, config.env) no longer listened in is warned of by itself.
NFB='{"dmPolicy":"allowlist","allowFrom":["333"],"groups":{"900":{"requireMention":true,"allowFrom":["222"]},"905":{"requireMention":true,"allowFrom":["111"]},"906":{"requireMention":true,"allowFrom":[]}}}'
NFO='warning: 111 is the owner of this bot (DISCORD_USER_ID) and no channel it listens in lets them write to it any more$'
NFM='warning: the main channel of the bot, #900, is no longer one it listens in: its session prompt, its hooks and health still use it$'
NF=$NFB; nt_reset; nt channel-905 channel-906
nt_refused "for the owner's last channels removed" "^$NFO" 'it has a warning (above)$'
! grep -q 'main channel' <<<"$AO" || { echo "FAIL: the main channel is still listened in: $AO"; exit 1; }
NF=$NFB; nt_reset; nt channel-900
nt_refused "for the main channel removed while others stay" "^$NFM"
! grep -q 'owner of this bot' <<<"$AO" || { echo "FAIL: the owner can still write: $AO"; exit 1; }
NF=$NFB; nt_reset; nt channel-905
[ "$ARC" = 0 ] && [ "$(jq -c '.groups | keys' "$ND/access.json")" = '["900","906"]' ] && [ ! -s "$CURL_LOG" ] ||
  { echo "FAIL: the owner's channel removed while an open one stays is no warning: rc=$ARC $AO / $AE"; exit 1; }
NF=$(jq -c '.groups["900"].allowFrom = ["111","222"]' <<<"$NFB"); nt_reset; nt channel-905
[ "$ARC" = 0 ] || { echo "FAIL: the owner's channel removed while another lists them is no warning: rc=$ARC $AO / $AE"; exit 1; }
# Narrowing counts as removal: the open channel the owner had is cut down to others, or removed, and none lets them write.
NFN='{"dmPolicy":"allowlist","allowFrom":["333"],"groups":{"900":{"requireMention":true,"allowFrom":["222"]},"906":{"requireMention":true,"allowFrom":[]}}}'
NF=$NFN; nt_reset; nt channel-906
nt_refused "for the owner's only open channel removed" "^$NFO" 'it has a warning (above)$'
NF=$NFN; nt_reset; nt allow:906+222
nt_refused "for the owner's open channel narrowed to others" "^$NFO" 'it has a warning (above)$'
NF=$(jq -c '.groups["900"].allowFrom = ["111","222"]' <<<"$NFN"); nt_reset; nt allow:906+222
[ "$ARC" = 0 ] && ! grep -q 'owner of this bot' <<<"$AO" || { echo "FAIL: an open channel narrowed while another still lists the owner is no warning: rc=$ARC $AO / $AE"; exit 1; }
NF=$NFA; nt_reset; nt channel-900 channel-901
nt_refused "for every channel removed" "^$NFO" && grep -q "^$NFM" <<<"$AO" || { echo "FAIL: every channel removed warns of the owner and of the main channel: $AO"; exit 1; }
NF=$NFA
# The Discord calls share the one budget a_own began (12 s; here 2): a post past it is not sent and is logged as failed.
# Every call takes 2 s: the budget counts whole seconds ($SECONDS), so the first call starts at 0 or 1 (a tick may fall
# just after a_t0) and the post at 2 or later.
nt_reset; queue_line "200 $NCH"; queue_line '200 {"id":"1"}'; echo 2 > "$HOME/curl.delay"
CLAUDE_DISCORD_ACCESS_BUDGET=2 nt channel+902 allow:902+222
rm -f "$HOME/curl.delay"
[ "$ARC" = 0 ] && grep -q 'guilds/5/channels$' "$CURL_LOG" && ! grep -q 'channels/902/messages' "$CURL_LOG" && [ "$(jq -c '.groups["902"].allowFrom' "$ND/access.json")" = '["111","222"]' ] &&
  [ "$(tail -n 1 "$ND/access.log" | cut -d' ' -f4-)" = "the post in 902 failed (HTTP 000)" ] ||
  { echo "FAIL: a post past the budget the channel check began is not sent, is logged as failed, and the change stays written: rc=$ARC $AO / $AE / $(cat "$ND/access.log" "$CURL_LOG" 2>&1)"; exit 1; }
nt_reset
# With a terminal nothing changes: the same words are asked about, and no is no.
nt_reset; queue_line "200 $NCH"
ARC=0; AO=$(printf 'n\nn\n' | python3 -c 'import os, pty, sys; sys.exit(os.waitstatus_to_exitcode(pty.spawn(sys.argv[1:])))' bash -c 'cd "$1" && exec bash "$2" access nt set channel+902 allow:902+222' x "$NP" "$S" 2>&1) || ARC=$?
[ "$ARC" = 4 ] && grep -q '^Apply this change? \[y/N\]' <<<"$AO" && [ "$(<"$ND/access.json")" = "$NF" ] && [ ! -s "$CURL_LOG" ] && [ ! -e "$ND/access.log" ] ||
  { echo "FAIL: at a terminal a change that widens nothing is still asked about: rc=$ARC $AO"; exit 1; }
nt_reset; rm -rf "${ND:?}" "${NP:?}"
echo "ok: access set with no terminal writes with no question when nothing widens (no new sender, no open channel, no @mention dropped, no mode, no warning) and every added channel is in the bot's own server: logged as such, one post in each new channel (a refused post is logged, not a failure); a new sender, an open or mention-free channel, a mode, a warning, another server or one nobody can name keep exit 3 with nothing written; at a terminal the question is still asked"

# Nothing this suite started is still running at the end: a case that detached a keeper or a monitor and did not stop it fails
# here, by name of the process (sandbox_pids: the sandbox in its argv or as its HOME; an orphaned
# `/bin/sleep 30` names no path of the suite's). Then the reaping itself, which every exit path runs (the EXIT trap): a decoy
# detached the way a keeper is (a subshell that exits, so init adopts it; the sandbox in its argv) must be seen first, or the
# last check could not fail, and reap_sandbox must take it down. Without the reaping that check fails.
strays() { local p; for p in $(sandbox_pids); do ps -o pid=,ppid=,args= -p "$p" || :; done; }
kill $KILL_AT_EXIT 2>/dev/null || :; KILL_AT_EXIT=""
for _ in $(seq 20); do left=$(strays); [ -z "$left" ] && break; nap 0.1; done
[ -z "$left" ] || { echo "FAIL: processes left behind: $(strays)"; exit 1; }
printf '/bin/sleep 3.%s; :\n' $$ > "$HOME/reapme.sh"
( bash "$HOME/reapme.sh" </dev/null >/dev/null 2>&1 & )
for _ in $(seq 20); do [ -z "$(sandbox_pids)" ] || break; nap 0.05; done
[ -n "$(strays)" ] || { echo "FAIL: a detached decoy with the sandbox in its argv is not seen, so the check below proves nothing"; exit 1; }
reap_sandbox
[ -z "$(strays)" ] || { echo "FAIL: reap_sandbox left behind: $(strays)"; exit 1; }
echo "ok: no process is left behind"

echo "ALL PASS"
