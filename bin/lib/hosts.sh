# sourced by bin/claude-discord: the hosts verb
if [ "${1:-}" = hosts ]; then
  shift
  h_usage="usage: claude-discord hosts [--bot <manager>] list [--json] | add [--no-probe|--dry-run] <alias> [laptop] [KEY=VALUE...] | set <alias> name=<display>|KEY=VALUE|KEY=... | set <alias> --stdin | laptop <alias> on|off | rm [--no-probe] <alias>"
  hb="" h_json="" h_probe=yes h_stdin="" h_dry="" h_flags="" hw=()
  while [ $# -gt 0 ]; do
    case $1 in
      --bot) [ $# -ge 2 ] || { echo "$h_usage" >&2; exit 2; }; hb=$2; shift;;
      --json) h_json=1 h_flags="$h_flags $1";;
      --no-probe) h_probe="" h_flags="$h_flags $1";;
      --stdin) h_stdin=1 h_flags="$h_flags $1";;
      --dry-run) h_dry=1 h_flags="$h_flags $1";;
      -*) echo "$h_usage" >&2; exit 2;;   # an ssh alias never starts with "-": ssh would read it as an option
      *) hw+=("$1");;
    esac
    shift
  done
  # A flag that means nothing for the verb is a usage error, not ignored: `rm --dry-run` would remove.
  case ${hw[0]:-} in list) h_ok=" --json ";; add) h_ok=" --no-probe --dry-run ";; set) h_ok=" --stdin ";; rm) h_ok=" --no-probe ";; *) h_ok=" ";; esac
  for w in $h_flags; do case $h_ok in *" $w "*) ;; *) echo "$h_usage" >&2; exit 2;; esac; done
  h_manager hosts --bot
  # h_alias <word>: an ssh alias as the monitor's pass takes one (a line whose first word is anything else is skipped
  # there): letters, digits and . _ @ - only, never a leading "-" (ssh would read it as an option), 255 at most. Or
  # exit 2. It is the word after the verb, and like any refused word it is never echoed, only where it stands and what
  # it must be: it may be a secret that landed in the wrong place (`hosts set KEY=secret <alias>`).
  h_alias() {
    c_match "$1" "$alias_re" || { echo "claude-discord: hosts: the alias (argument 2) is not an ssh alias: letters, digits, . _ @ -, not starting with -, 255 at most" >&2; exit 2; }
  }
  # h_word <where> <word>: a KEY=VALUE word (name=<display> too) that a ledger line can hold and the monitor will read,
  # or exit 2 naming <where> it stands ("argument 4", "line 2 of stdin") and the rule. Nothing of the word is echoed,
  # not its key either: a word that ends in "=" may be a token. A value holds no whitespace or control character (the
  # word would end there) and no quote (the ledger has no quoting: the quote would travel as part of the value). A
  # display name may hold any other character and is 40 at most, counted in the user's locale.
  h_word() {
    local k=${2%%=*} v=${2#*=}
    case $2 in *=*) ;; *) k="";; esac
    c_match "$k" '^[A-Za-z_][A-Za-z0-9_]{0,63}$' || { echo "claude-discord: hosts: $1 is not KEY=VALUE (KEY: letters, digits and _, not starting with a digit, 64 at most)" >&2; exit 2; }
    case $v in
      *[[:space:]]*|*[[:cntrl:]]*|*[\'\"]*) echo "claude-discord: hosts: $1: a value holds no space, control character or quote (a ledger word is not shell-quoted: write the value bare)" >&2; exit 2;;
    esac
    [ ${#v} -le 1024 ] || { echo "claude-discord: hosts: $1: a value is 1024 characters at most" >&2; exit 2; }
    [ "$k" != name ] || [ ${#v} -le 40 ] || { echo "claude-discord: hosts: $1: a display name is 40 characters at most" >&2; exit 2; }
  }
  # h_lock: one writer of the ledger at a time (a TUI save while `hosts set` runs would otherwise lose one of the two:
  # both read, then both write). flock through perl, as the monitor's lock, on <ledger>.lock: the lock stays with fd 7
  # of this shell after perl is gone, and the kernel drops it on any death, so it is never stale. 5 s of tries, then
  # exit 1. The ledger itself cannot be the lock: it is replaced by rename, so two writers would lock two files.
  # 6 is LOCK_EX | LOCK_NB, written out: loading Fcntl for the two names costs 3 ms of every write.
  h_lock() {
    exec 7>>"$hf.lock"
    perl -e 'open(my $l, ">&=", 7) or exit 1; for (1 .. 50) { exit 0 if flock($l, 6); select(undef, undef, undef, 0.1) } exit 1' ||
      { echo "claude-discord: hosts: $hf is being changed by another claude-discord hosts; nothing was changed" >&2; exit 1; }
  }
  # h_edit <alias> add|set|rm <word>...: the ledger read and written back under the lock, in one rename (ledger_write).
  # A line that is not <alias>'s keeps its bytes, CRLF included. Sets h_changed to the number of lines it changed.
  # add: <alias> must not be there (exit 3); the new line is the last.
  # set: on EVERY line of <alias> (two lines for one host: the monitor runs it twice and the second wins), each <word>
  #   in turn: "laptop on" makes laptop the second word (the one place the monitor reads it) and "laptop off" removes
  #   it from there; KEY=VALUE replaces the first KEY= word where it stands and drops any later one, or becomes the
  #   last word; KEY= removes them (name= is one more key here). The other words keep their place, the ones the
  #   monitor skips too. A changed line is written with one space between words and keeps its CRLF; a line that comes
  #   out the same keeps its bytes, and when none changes nothing is written.
  # rm: every line of <alias> goes, unless no host line would be left (exit 2). set and rm: exit 3 when <alias> has no line.
  h_edit() {
    local alias=$1 how=$2 out="" line cr hit=0 changed=0 others=0 op w k seen was i
    local -a words nw
    shift 2
    h_lock
    while IFS= read -r line || [ -n "$line" ]; do
      cr=""; case $line in *$'\r') cr=$'\r'; line=${line%$'\r'};; esac
      set -f; words=($line); set +f
      if [ "${words[0]:-}" != "$alias" ]; then
        out="$out$line$cr"$'\n'
        case ${words[0]:-} in ''|-*|*[!A-Za-z0-9._@-]*) ;; *) others=$((others + 1));; esac   # a host line, as the monitor's pass tells one
        continue
      fi
      hit=$((hit + 1))
      [ "$how" != add ] || { echo "claude-discord: hosts: $alias is already in $hf" >&2; exit 3; }
      if [ "$how" = rm ]; then changed=$((changed + 1)); continue; fi
      was=${words[*]}
      for op in "$@"; do
        nw=("${words[0]}")
        case $op in
          "laptop on"|"laptop off")
            i=1; [ "${words[1]:-}" != laptop ] || i=2
            [ "$op" = "laptop off" ] || nw+=(laptop)
            for w in "${words[@]:$i}"; do nw+=("$w"); done;;
          *)
            k=${op%%=*} seen=""
            for w in "${words[@]:1}"; do
              case $w in
                "$k="*) [ -n "$seen" ] || [ "$op" = "$k=" ] || nw+=("$op"); seen=1;;
                *) nw+=("$w");;
              esac
            done
            [ -n "$seen" ] || [ "$op" = "$k=" ] || nw+=("$op");;
        esac
        words=("${nw[@]}")
      done
      if [ "${words[*]}" = "$was" ]; then out="$out$line$cr"$'\n'; else out="$out${words[*]}$cr"$'\n'; changed=$((changed + 1)); fi
    done < "$hf"
    case $how in
      add) out="$out$alias${*:+ $*}"$'\n'; changed=1;;
      *) [ "$hit" != 0 ] || { echo "claude-discord: hosts: $alias is not in $hf" >&2; exit 3; };;
    esac
    # Only a ledger with no local line (hand-edited) can come to this: its monitor would run with no host and say nothing.
    [ "$how" != rm ] || [ "$others" != 0 ] || { echo "claude-discord: hosts: $alias is not removed: the ledger would be empty: the monitor needs at least one host" >&2; exit 2; }
    [ "$changed" = 0 ] || ledger_write "$hf" "$out" || { echo "claude-discord: hosts: could not write $hf; it is as it was" >&2; exit 1; }
    exec 7>&-
    h_changed=$changed
  }
  # h_has <alias>: the ledger has a line for it. Read without the lock: a hint before a slow probe; h_edit decides.
  h_has() {
    local line; local -a x
    while IFS= read -r line || [ -n "$line" ]; do
      set -f; x=(${line%$'\r'}); set +f
      [ "${x[0]:-}" != "$1" ] || return 0
    done < "$hf"
    return 1
  }
  # h_ask <alias>: asks the host who it is. Sets h_ver (its claude-discord version; empty when it printed no version
  # line), h_id (its home's host-id; empty from a claude-discord before 1.12.0) and h_last (the last line of the answer:
  # ssh's own error when it failed). No byte of the answer is trusted: h_ssh made its lines safe to print, and here
  # they are only read into variables and matched: a version is N.N.N, an id 32 hex digits. Nothing of it is run or
  # becomes a command's word.
  h_who='~/.local/bin/claude-discord --version --host-id'
  h_ask() {
    local l a b c d e rest re_v='^[0-9]+\.[0-9]+\.[0-9]+$' re_t='^[0-9TZ:-]{1,20}$'
    h_ssh "$1" "$h_who"
    h_ver="" h_id="" h_last="" h_watch=""   # h_watch: the host's watcher records, "<manager> <host-id> <alias> <time>" a line
    while IFS= read -r l; do
      [ -n "$l" ] || continue
      h_last=$l a="" b="" c="" d="" e=""
      read -r a b c d e rest <<<"$l" || :
      case $a in
        claude-discord) if [ -z "$h_ver" ] && [[ $b =~ $re_v ]]; then h_ver=$b; fi;;
        host-id) if c_match "$b" "$hid_re"; then h_id=$b; fi;;
        watcher) if c_match "$b" "$mgr_re" && c_match "$c" "$hid_re" && c_match "$d" "$alias_re" && [[ $e =~ $re_t ]] && [ -z "$rest" ]; then h_watch="$h_watch$b $c $d $e"$'\n'; fi;;
      esac
    done <<<"$h_out"
  }
  case ${hw[0]:-} in
    list)
      [ "${#hw[@]}" = 1 ] || { echo "$h_usage" >&2; exit 2; }
      # Each line as the monitor's pass reads it (monitor/monitor.sh, run_pass), so this shows what the monitor will do.
      rows="" ign=0
      while IFS= read -r line || [ -n "$line" ]; do
        line=${line%$'\r'}
        set -f; set -- $line; set +f
        [ $# -gt 0 ] || continue
        case $1 in '#'*) continue;; -*|*[!A-Za-z0-9._@-]*) ign=$((ign + 1)); continue;; esac
        a=$1 lap=false nm="" keys="" skip=0; shift
        [ "${1:-}" != laptop ] || { lap=true; shift; }
        for w in "$@"; do
          case $w in name=*) nm=${w#name=}; nm=${nm//[[:cntrl:]]/}; continue;; esac
          if [[ $w =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then keys="$keys${keys:+ }${w%%=*}"; else skip=$((skip + 1)); fi
        done
        rows="$rows$a"$'\x1f'"$lap"$'\x1f'"$nm"$'\x1f'"$keys"$'\x1f'"$skip"$'\n'
      done < "$hf"
      if [ -n "$h_json" ]; then
        printf '%s' "$rows" | jq -Rn --arg m "$hb" --arg f "$hf" --argjson ign "$ign" '{manager: $m, ledger: $f, ignored: $ign,
          hosts: [inputs | split("\u001f") | {alias: .[0], laptop: (.[1] == "true"), name: .[2], env: (.[3] | split(" ")), skipped: (.[4] | tonumber)}]}'
      else
        while IFS=$'\x1f' read -r a lap nm keys skip; do
          [ -n "$a" ] || continue
          kind=server; [ "$lap" != true ] || kind=laptop
          keys=${keys// /,}; note=""; [ "$skip" = 0 ] || note=" ($skip words the monitor skips)"
          printf '%-20s %-7s name=%s env=%s%s\n' "$a" "$kind" "${nm:--}" "${keys:--}" "$note"
        done <<<"$rows"
      fi;;
    add)
      [ "${#hw[@]}" -ge 2 ] || { echo "$h_usage" >&2; exit 2; }
      a=${hw[1]}; h_alias "$a"
      # laptop is the third word or none; a KEY comes once (two words of one key on a line: the monitor takes the last).
      i=2 keys=" "
      for w in "${hw[@]:2}"; do
        i=$((i + 1))
        [ "$w" = laptop ] && [ "$i" = 3 ] && continue
        h_word "argument $i" "$w"
        case $w in *=) echo "claude-discord: hosts: argument $i: add takes KEY=VALUE, a value that is not empty" >&2; exit 2;; esac
        case $keys in *" ${w%%=*} "*) echo "claude-discord: hosts: argument $i: its KEY was already given" >&2; exit 2;; esac
        keys="$keys${w%%=*} "
      done
      ! h_has "$a" || { echo "claude-discord: hosts: $a is already in $hf" >&2; exit 3; }
      if [ -n "$h_dry" ]; then
        # The line `add` is about to run, for a person or the TUI to read first. local is this machine: nobody is asked.
        # The second line: what the two calls leave on that machine (the TUI shows both lines before the second Enter).
        [ -z "$h_probe" ] || [ "$a" = local ] || printf '%s\n' "ssh -o BatchMode=yes -o ConnectTimeout=8 -- $a '$h_who'" \
          "checks it and writes ~/.claude-discord/host-id there if missing; adding it writes ~/.claude-discord/watchers/$hb"
        exit 0
      fi
      h_id=""
      if [ -n "$h_probe" ] && [ "$a" != local ]; then
        h_ask "$a"
        unchecked="Not added; to add it unchecked: claude-discord hosts add --no-probe $a"
        if [ "$h_rc" = 255 ]; then
          echo "claude-discord: hosts: $a did not answer (ssh exit 255, also with ControlPath=none): ${h_last:-no output}. $unchecked" >&2; exit 5
        elif [ "$h_rc" = 142 ]; then
          echo "claude-discord: hosts: $a gave no answer within ${h_cap}s. $unchecked" >&2; exit 5
        elif [ -z "$h_ver" ]; then
          echo "claude-discord: hosts: $a answered, but not as claude-discord (exit $h_rc): ${h_last:-no output}. Install it there first (README, Install): a host without it is reported blind. $unchecked" >&2; exit 5
        elif [ -z "$h_id" ] && ver_ge "$h_ver" 1.12.0; then
          echo "claude-discord: hosts: warning: claude-discord $h_ver on $a answered but could not create its host-id (is ~/.claude-discord writable there?): it could not be checked for being this same home" >&2
        elif [ -z "$h_id" ]; then
          echo "claude-discord: hosts: warning: claude-discord $h_ver on $a is older than 1.12.0 and has no host-id: it could not be checked for being this same home" >&2
        else
          mine=$(host_id) || { echo "claude-discord: hosts: could not make $helpers/host-id" >&2; exit 1; }
          # One home behind two ledger lines: every bot of it would be reported twice, one side as down.
          [ "$h_id" != "$mine" ] || { echo "claude-discord: hosts: $a is the same home as local (it answered with this home's host-id): not added. Its bots are already checked through local" >&2; exit 4; }
          while read -r wm wi wa ws; do
            [ -n "$wm" ] || continue
            if [ "$wm" = "$hb" ] && [ "$wi" = "$mine" ]; then
              # This manager's own record: the home is in this ledger already, under that alias, unless that line is gone
              # (an rm that could not reach the host left the record: stale, and overwritten below).
              if [ "$wa" != "$a" ] && h_has "$wa"; then
                echo "claude-discord: hosts: $a is the same home as $wa (this manager's own record is there under that alias): not added. Its bots are already checked through $wa" >&2; exit 4
              fi
            elif [ "$wm" = "$hb" ]; then
              echo "claude-discord: hosts: warning: $a is already watched by a manager also named $wm, from another home (since $ws): both will report its bots, and this add takes over its record there" >&2
            else
              echo "claude-discord: hosts: warning: $a is already watched by $wm (since $ws): both managers will report its bots" >&2
            fi
          done <<<"$h_watch"
        fi
      fi
      h_edit "$a" add "${hw[@]:2}"
      echo "claude-discord: hosts: added $a to $hf"
      # This manager's record on the host, for the next manager that adds it. Only a claude-discord that printed a
      # host-id knows --watch (1.12.0); its failure is a warning, the host is added and checked all the same.
      if [ -n "$h_id" ]; then
        if c_match "$hb" "$mgr_re"; then
          h_ssh "$a" "~/.local/bin/claude-discord --version --watch $hb $mine $a"
          [ "$h_rc" = 0 ] || echo "claude-discord: hosts: warning: $a is added, but this manager could not be recorded there (ssh exit $h_rc): another manager adding it will not be warned" >&2
        else
          echo "claude-discord: hosts: warning: no watcher record is written for a manager named '$hb' (letters, digits and . _ - only): another manager adding $a will not be warned" >&2
        fi
      fi;;
    set|laptop)
      [ "${#hw[@]}" -ge 2 ] || { echo "$h_usage" >&2; exit 2; }
      a=${hw[1]}; h_alias "$a"
      ops=()
      if [ "${hw[0]}" = laptop ]; then
        [ "${#hw[@]}" = 3 ] || { echo "$h_usage" >&2; exit 2; }
        case ${hw[2]} in on|off) ops=("laptop ${hw[2]}");; *) echo "$h_usage" >&2; exit 2;; esac
      elif [ -n "$h_stdin" ]; then
        # One change a line; all of them are checked before the ledger is touched.
        [ "${#hw[@]}" = 2 ] || { echo "$h_usage" >&2; exit 2; }
        i=0
        while IFS= read -r w || [ -n "$w" ]; do
          w=${w%$'\r'}; i=$((i + 1))
          [ -n "$w" ] || continue
          case $w in "laptop on"|"laptop off") ;; *) h_word "line $i of stdin" "$w";; esac
          ops+=("$w")
        done
      else
        i=2
        for w in "${hw[@]:2}"; do i=$((i + 1)); h_word "argument $i" "$w"; ops+=("$w"); done
      fi
      [ "${#ops[@]}" != 0 ] || { echo "$h_usage" >&2; exit 2; }
      h_edit "$a" set "${ops[@]}"
      if [ "$h_changed" = 0 ]; then echo "claude-discord: hosts: $a is already so in $hf"
      else echo "claude-discord: hosts: changed $a in $hf ($h_changed line$([ "$h_changed" = 1 ] || echo s))"; fi;;
    rm)
      [ "${#hw[@]}" = 2 ] || { echo "$h_usage" >&2; exit 2; }
      a=${hw[1]}; h_alias "$a"
      # The monitor's own Discord calls take their environment from the local line, and the README promises it is there.
      [ "$a" != local ] || { echo "claude-discord: hosts: local is this machine and stays in the ledger (to turn the monitor off: claude-discord monitor --stop $hb)" >&2; exit 2; }
      h_edit "$a" rm
      echo "claude-discord: hosts: removed $a from $hf (the monitor keeps it a day as 'left the ledger', then drops it)"
      # This manager's watcher record on the host goes too, when it can be reached; the ledger line is already gone
      # either way. A home with no host-id never wrote a record anywhere, and makes no id for this.
      mine=""; { read -r mine < "$helpers/host-id"; } 2>/dev/null || :
      if [ -n "$h_probe" ] && c_match "$mine" "$hid_re" && c_match "$hb" "$mgr_re"; then
        h_ssh "$a" "~/.local/bin/claude-discord --version --unwatch $hb $mine"
        [ "$h_rc" = 0 ] || echo "claude-discord: hosts: warning: $a did not answer (ssh exit $h_rc), so this manager's watcher record stays there. It only makes another manager's add warn; to remove it later: ssh $a '~/.local/bin/claude-discord --version --unwatch $hb $mine'" >&2
      fi;;
    *) echo "$h_usage" >&2; exit 2;;
  esac
  exit 0
fi
