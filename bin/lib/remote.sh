# sourced by bin/claude-discord: h_manager h_cap h_capped h_ssh via_host (hosts, access, bot)

# hosts: lists and edits a manager bot's hosts ledger (<bot dir>/hosts; write_hosts above has its format), for people,
# scripts and the TUI, which changes the ledger through this verb only. It never prints the value of a KEY=VALUE word
# (a proxy URL may hold a password): key names only.
# Exit status: 0 done (a warning goes to stderr), 1 it could not (no manager bot with a ledger, a failed write, the
# ledger locked by another writer for 5 s), 2 usage or a word that is not allowed (never echoed), 3 the alias is already in the
# ledger (add) or is not in it (set, laptop, rm), 4 add refused: the host is the same home as one already checked,
# 5 not added: the host did not answer or has no claude-discord (--no-probe adds it unchecked).
# h_manager <verb> <its flag that names the manager>: which manager bot's ledger a verb acts on (hosts, and access --host).
# In the project above the cwd: its dev-manager bots that have a ledger (only the one named, with
# --bot); none there: the same among the projects with a state dir (proj_arr), as `tui` and `monitor` find theirs.
# Exactly one must be left. This verb never asks (the TUI and scripts run it): it names the candidates and exits 2.
# Uses hb (the manager named, or empty); sets hd (its bot dir), hb and hf (its ledger).
h_manager() {
  h_cands="" h_n=0
  h_scan() {  # $1 = a project root: its manager bots with a ledger go into h_cands (one bot dir a line), each once
    local d m
    proj_dirs "$1"
    for d in "$pd_root"/*/; do
      d=${d%/}; m=""
      [ -f "$d/hosts" ] || continue
      { read -r m < "$d/mode"; } 2>/dev/null || :
      [ "$m" = dev-manager ] || continue
      [ -z "$hb" ] || [ "$hb" = "${d##*/}" ] || continue
      case $'\n'$h_cands in *$'\n'"$d"$'\n'*) continue;; esac
      h_cands=$h_cands$d$'\n'; h_n=$((h_n + 1))
    done
  }
  ! find_proj || h_scan "$pd_project"   # the project above the cwd (physical, as `project` files hold their paths)
  if [ "$h_n" = 0 ]; then
    proj_arr
    for p in ${pl[@]+"${pl[@]}"}; do h_scan "$p"; done
  fi
  [ "$h_n" != 0 ] || { echo "claude-discord: $1: no dev-manager bot${hb:+ '$hb'} with a hosts ledger in the project above $PWD or in a recorded one (claude-discord setup <bot> --mode writes the ledger)" >&2; exit 1; }
  [ "$h_n" = 1 ] || { echo "claude-discord: $1: $h_n manager bots have a ledger; name one with $2 <manager>, in its project when two share a name:" >&2; printf '%s' "$h_cands" | sed 's/^/  /' >&2; exit 2; }
  hd=${h_cands%$'\n'}; hb=${hd##*/}; hf=$hd/hosts
}
# h_ssh <alias> <remote command>: one ssh call as the monitor's pass makes it (BatchMode, ConnectTimeout=8, and after
# an exit 255 once more with ControlPath=none: a stale master refuses falsely), so a host is unreachable here when a
# pass would say so. "--" ends ssh's options: the alias can never be read as one. ConnectTimeout bounds the
# connection only, so the whole call is capped too (h_cap seconds, an integer from 1 to 300; no timeout(1) on macOS):
# ssh runs in its own process group under a perl parent (h_capped) that reads what it prints, both streams, through
# a pipe of its own, and ends, killing the group, when ssh has ended and what it wrote is read, at 65536 bytes (a
# host that prints megabytes), or at the cap (exit 142; a signal to it too, a closed terminal's HUP included).
# Never at the pipe's end alone: a process ssh leaves behind (a ControlPersist master, a ProxyCommand helper) holds
# it open for as long as it lives. Sets h_rc and h_out.
# h_out is what the host said, for h_ask: from the LAST line that reads as a version line to the end (so a banner
# before it, sshd's or the shell's, does not count), or with no such line the last line (ssh's own error); 4096
# bytes at most. It comes from another machine, so each line is first made safe to print: only printable ASCII and
# well-formed UTF-8 stay (no C0 control, DEL or stray byte), less the C1 controls and the bidi overrides and
# isolates (U+0080-009F, U+202A-202E, U+2066-2069: bash's [[:cntrl:]] misses them in the C locale), cut at 200 characters.
h_cap=${CLAUDE_DISCORD_PROBE_CAP:-20}
case $h_cap in ''|0*|*[!0-9]*|????*) h_cap=20;; esac
[ "$h_cap" -le 300 ] || h_cap=20
# The suite cannot wait a whole second for a hung probe: CLAUDE_DISCORD_PROBE_CAP_TENTHS (one digit, 1 to 9; read
# here only, not for users) is the cap in tenths of a second instead. Anything else leaves the cap above as it is.
case ${CLAUDE_DISCORD_PROBE_CAP_TENTHS:-} in [1-9]) h_cap=0.$CLAUDE_DISCORD_PROBE_CAP_TENTHS;; esac
h_capped='my ($cap, $max, $buf, $st) = (shift, $ENV{CD_RAW} ? 4194304 : 65536, "");
  pipe(my $r, my $w) or exit 127;
  my $pid = fork(); defined $pid or exit 127;
  if (!$pid) { setpgrp(0, 0); close $r; open(STDOUT, ">&", $w); open(STDERR, ">&", $w); close $w; exec { $ARGV[0] } @ARGV; exit 127 }
  setpgrp($pid, $pid); close $w;
  $SIG{ALRM} = $SIG{INT} = $SIG{TERM} = $SIG{HUP} = sub { kill "KILL", -$pid; exit 142 };
  if ($cap =~ /^\d+$/) { alarm $cap } else { require Time::HiRes; Time::HiRes::alarm($cap) }   # a fraction: the suite only
  my $rin = ""; vec($rin, fileno($r), 1) = 1;
  while (length($buf) < $max) {
    $st = $? if !defined $st && waitpid($pid, 1) == $pid;   # 1 is WNOHANG
    if (select(my $rout = $rin, undef, undef, defined $st ? 0 : 0.05) > 0) {
      next if sysread($r, $buf, $max - length($buf), length($buf));
      waitpid($pid, 0), $st = $? unless defined $st;   # the end of the pipe: ssh is ending
    }
    last if defined $st;
  }
  kill "KILL", -$pid;
  waitpid($pid, 0), $st = $? unless defined $st;
  if ($ENV{CD_RAW}) { print $buf; exit($st & 127 ? 128 + ($st & 127) : $st >> 8) }
  my ($ver, @l) = (0);
  for (split /\n/, $buf) {
    s/([\x20-\x7e]|[\xc2-\xdf][\x80-\xbf]|\xe0[\xa0-\xbf][\x80-\xbf]|[\xe1-\xef][\x80-\xbf]{2}|\xf0[\x90-\xbf][\x80-\xbf]{2}|[\xf1-\xf4][\x80-\xbf]{3})|./defined $1 ? $1 : ""/ge;
    s/\xc2[\x80-\x9f]|\xe2\x80[\xaa-\xae]|\xe2\x81[\xa6-\xa9]//g;
    ($_) = /^((?:[\x00-\x7f]|[\xc2-\xf4][\x80-\xbf]*){0,200})/;
    next unless /\S/;
    push @l, $_; $ver = @l if /^ *claude-discord +\d+\.\d+\.\d+(?: |$)/;
  }
  print substr(join("\n", @l[($ver ? $ver : @l) - 1 .. $#l]), 0, 4096) if @l;
  exit($st & 127 ? 128 + ($st & 127) : $st >> 8)'
h_ssh() {
  local t; local -a o
  for t in first retry; do
    o=(); [ "$t" = first ] || o=(-o ControlPath=none)
    h_rc=0
    h_out=$(CD_RAW=${3:+1} perl -e "$h_capped" "$h_cap" ssh -o BatchMode=yes -o ConnectTimeout=8 ${o[@]+"${o[@]}"} -- "$1" "$2" </dev/null) || h_rc=$?
    [ "$h_rc" = 255 ] && [ "$t" = first ] || return 0
  done
}

# via_host <verb> <first version> <first word> <word>...: `claude-discord <verb> --host <alias> ...` (access since 1.13.0,
# bot since 1.14.0), the bot living on a host of a manager's ledger; a_host, hb (--manager) and a_proj (--project) are
# the verb's. `local` runs the verb here with that ledger line's env words, any other alias over ssh with them, as a
# monitor pass goes. Into the remote command go hex digits (the project and the first word, which may be a bot's name)
# and the verb's own words, which it has matched as plain. Never returns.
via_host() {
  local verb=$1 minv=$2 w1=$3 line w a_hit=""
  shift 3
  c_match "$a_host" "$alias_re" || { echo "claude-discord: $verb: --host is not an ssh alias: letters, digits, . _ @ -, not starting with -, 255 at most" >&2; exit 2; }
  h_manager "$verb" --manager
  # The env words of the host's ledger line, as the monitor's pass reads them (monitor/monitor.sh, run_pass): a proxy
  # word sets both spellings, name= is no env word; of two lines for one alias the last counts.
  a_env=()
  while IFS= read -r line || [ -n "$line" ]; do
    set -f; a_w=(${line%$'\r'}); set +f
    [ "${a_w[0]:-}" = "$a_host" ] || continue
    a_hit=1 a_env=()
    for w in ${a_w[@]+"${a_w[@]:1}"}; do
      case $w in name=*) continue;; esac
      [[ $w =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
      case ${w%%=*} in
        HTTPS_PROXY|https_proxy) a_env+=("HTTPS_PROXY=${w#*=}" "https_proxy=${w#*=}");;
        HTTP_PROXY|http_proxy) a_env+=("HTTP_PROXY=${w#*=}" "http_proxy=${w#*=}");;
        ALL_PROXY|all_proxy) a_env+=("ALL_PROXY=${w#*=}" "all_proxy=${w#*=}");;
        NO_PROXY|no_proxy) a_env+=("NO_PROXY=${w#*=}" "no_proxy=${w#*=}");;
        *) a_env+=("$w");;
      esac
    done
  done < "$hf"
  [ -n "$a_hit" ] || { echo "claude-discord: $verb: $a_host is not in $hf (claude-discord hosts list)" >&2; exit 2; }
  if [ "$a_host" = local ]; then
    a_pa=(); [ -z "$a_proj" ] || a_pa=(--project "$a_proj")
    exec env ${a_env[@]+"${a_env[@]}"} "$self_path" "$verb" ${a_pa[@]+"${a_pa[@]}"} -- "$w1" "$@"
  fi
  [ -n "$a_proj" ] || { echo "claude-discord: $verb: --host $a_host needs --project <the bot's project directory on that host>" >&2; exit 2; }
  # The project and the first word travel as hex digits (a path or a name may hold anything; no quoting of ours has to
  # hold in the remote shell), behind `--version`: an older claude-discord prints its version line and exits whatever
  # follows, while a new verb would be read there as a bot's name and reach the launcher.
  a_hex() { printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n'; }
  a_remote="env $([ ${#a_env[@]} = 0 ] || printf '%q ' "${a_env[@]}")~/.local/bin/claude-discord --version --$verb $(a_hex "$a_proj") $(a_hex "$w1")${*:+ $*}"
  a_old() {  # no document: an older host printed its version line; a host new enough that could not do it said why (no such bot there)
    # A version line is a whole line, as h_capped reads one: the same words inside other text (a banner) are none.
    local l re='^ *claude-discord +([0-9]+\.[0-9]+\.[0-9]+)( |$)'
    l=$(printf '%s\n' "$h_out" | grep -E "$re" | tail -n 1) || l=""
    if [[ $l =~ $re ]]; then echo "claude-discord: $verb: $a_host needs claude-discord $minv for this (it has ${BASH_REMATCH[1]}; claude-discord update, there)" >&2; exit 5; fi
    l=$(printf '%s\n' "$h_out" | LC_ALL=C tr -d '\000-\010\013-\037\177' | grep . | tail -n 1) || l=""
    l=${l#claude-discord: $verb: }
    echo "claude-discord: $verb: $a_host: ${l:-no answer (exit $h_rc)}" >&2; exit 1
  }
  a_down() {
    case $h_rc in
      255) echo "claude-discord: $verb: $a_host did not answer (ssh exit 255, also with ControlPath=none)" >&2; exit 5;;
      142) echo "claude-discord: $verb: $a_host gave no answer within ${h_cap}s" >&2; exit 5;;
    esac
  }
  if [ "${1:-}" = --json ]; then
    # The host asks Discord, starting no call past 12 s, each 5 s at most, after ssh connected (up to 8 s): 30 s for
    # the whole call, so a slow host with a slow Discord is still an answer.
    case $h_cap in *.*) ;; *) [ "$h_cap" -ge 30 ] || h_cap=30;; esac
    h_ssh "$a_host" "$a_remote" raw; a_down
    # The document is the last line that starts as one; what the host printed around it (a banner) is not ours.
    doc=$(printf '%s\n' "$h_out" | grep '^{"access":' | tail -n 1 | jq -c 'select(.access == 1)' 2>/dev/null) || doc=""
    [ -n "$doc" ] || a_old
    printf '%s\n' "$doc"; exit 0
  fi
  h_ssh "$a_host" "~/.local/bin/claude-discord --version"; a_down
  a_v="" a_re='claude-discord ([0-9]+\.[0-9]+\.[0-9]+)'
  if [[ $h_out =~ $a_re ]]; then a_v=${BASH_REMATCH[1]}; fi
  [ -n "$a_v" ] || { echo "claude-discord: $verb: $a_host answered, but not as claude-discord (exit $h_rc)" >&2; exit 5; }
  ver_ge "$a_v" "$minv" || a_old
  if [ -t 0 ] && [ -t 1 ]; then
    # The question is asked on that host, of this terminal. No cap: a person is answering.
    a_rc=0; ssh -t -o BatchMode=yes -o ConnectTimeout=8 -- "$a_host" "$a_remote" || a_rc=$?
    [ "$a_rc" != 255 ] || { echo "claude-discord: $verb: ssh to $a_host failed (exit 255)" >&2; exit 5; }
    exit "$a_rc"
  fi
  # No terminal here: the host prints the changes and refuses (exit 3). What it printed is another machine's text.
  h_ssh "$a_host" "$a_remote" raw; a_down
  printf '%s\n' "$h_out" | LC_ALL=C tr -d '\000-\010\013-\037\177'
  exit "$h_rc"
}
