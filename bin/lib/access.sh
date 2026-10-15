# sourced by bin/claude-discord: the access verb

# access: reads and changes who may drive a bot, for people, scripts and the TUI, which changes a bot's access.json and
# mode through this verb only: the channels it listens in (access.json's groups), per channel whether an @mention is
# required and who may write, the DM policy with its allowlist, and the bot's mode.
#   access <bot> --json          one line of JSON: the policy, the guild's channels with whether the bot can read each
#                                (asked of Discord with the bot's own token, here on the bot's machine), the people
#                                known, the mode. Read-only; needs no terminal.
#   access <bot> set <change>... prints what would change, asks, writes. A change is a word a person can type, made of
#                                lower-case letters, digits and : + = - only (a_word_re), so it travels over ssh as it is:
#     channel+<channel id>  channel-<channel id>          listen there (an @mention required, from the owner alone) / stop
#     mention:<channel id>=on|off                         an @mention is required / every message is answered
#     allow:<channel id>+<user id>  allow:<channel id>-<user id>  allow:<channel id>=any    who may write there
#     dm=allowlist|pairing|off  dm+<user id>  dm-<user id>          DMs: off is an allowlist with nobody on it
#     mode=none|dev-manager|autoresearchclaw              through `setup <bot> --mode`, its questions answered by Enter
# A change that widens who can drive the bot is shown first, marked "!" (red at a terminal), then the others; one
# question is asked for all of them, naming how many widen (1.13.1). Anything but y writes nothing: the file is what
# was shown and agreed to, or as it was.
# It refuses to write unless stdin and stdout are a terminal, and has no flag to skip the question. That is a speed
# bump, not a boundary: whoever can run this can also edit the file. Without a terminal it prints the changes and exits 3.
# --project <dir>: the bot's project (default: the one above the cwd that has the bot).
# --host <alias>: the bot lives on a host of a manager's ledger (--manager <bot> when the project has several): `local`
# runs it here with that line's env words, any other alias over ssh with them (a question needs `ssh -t`, so a terminal
# here). Only hex digits, ids and change words go into the remote command; no name does.
# Exit status: 0 done, or nothing to change; 1 it could not (no such bot, access.json unreadable or changed meanwhile, a
# failed write, the lock held 5 s, no manager's ledger for --host); 2 usage, a word that is not a change, or a change
# that cannot be made; 3 no terminal: nothing written; 4 answered no: nothing written; 5 --host: no answer from the
# host, or its claude-discord is older than 1.13.0.
if [ "${1:-}" = access ]; then
  shift
  a_usage="usage: claude-discord access [--host <alias> [--manager <bot>]] [--project <dir>] <bot> --json | set <change>...
  a change: channel+<channel id> | channel-<channel id> | mention:<channel id>=on|off | allow:<channel id>+<user id> | allow:<channel id>-<user id> | allow:<channel id>=any | dm=allowlist|pairing|off | dm+<user id> | dm-<user id> | mode=none|dev-manager|autoresearchclaw"
  a_word_re='^(channel[+-][0-9]{1,20}|mention:[0-9]{1,20}=(on|off)|allow:[0-9]{1,20}([+-][0-9]{1,20}|=any)|dm=(allowlist|pairing|off)|dm[+-][0-9]{1,20}|mode=(none|dev-manager|autoresearchclaw))$'
  a_host="" a_proj="" hb=""
  while [ $# -gt 0 ]; do
    case $1 in
      --host|--manager|--project)
        [ $# -ge 2 ] || { echo "$a_usage" >&2; exit 2; }
        case $1 in --host) a_host=$2;; --manager) hb=$2;; *) a_proj=$2;; esac
        shift 2;;
      --) shift; break;;
      -*) echo "$a_usage" >&2; exit 2;;
      *) break;;
    esac
  done
  [ $# -ge 2 ] || { echo "$a_usage" >&2; exit 2; }
  bot=$1 act=$2; shift 2
  case $bot in ''|.|..|*/*) echo "claude-discord: access: the bot's name must be a plain directory name" >&2; exit 2;; esac
  case $act in
    --json) [ $# = 0 ] || { echo "$a_usage" >&2; exit 2; };;
    set)
      [ $# -gt 0 ] || { echo "$a_usage" >&2; exit 2; }
      # Never echoed: a refused word is text from somewhere else (a paste, a state file), only where it stands is said.
      i=0; for w in "$@"; do i=$((i + 1)); c_match "$w" "$a_word_re" || { echo "claude-discord: access: change $i is not one of the changes access takes (claude-discord access, with no argument, lists them)" >&2; exit 2; }; done;;
    *) echo "$a_usage" >&2; exit 2;;
  esac

  [ -z "$a_host" ] || via_host access 1.13.0 "$bot" "$act" "$@"

  if [ -n "$a_proj" ]; then
    cd "$a_proj" 2>/dev/null || { echo "claude-discord: access: no such project directory (--project)" >&2; exit 1; }
  else
    ap=$PWD
    while [ ! -d "$ap/.claude/discord-agents/$bot" ] && [ -n "$ap" ]; do ap=${ap%/*}; done
    [ -z "$ap" ] || cd "$ap"
  fi
  root=$PWD/.claude/discord-agents; d=$root/$bot; f=$d/access.json
  bn=${bot//[[:cntrl:]]/}   # the name as it is printed
  [ -f "$f" ] || { echo "claude-discord: access: no bot '$bn' set up in $root (claude-discord setup <bot>)" >&2; exit 1; }
  command -v jq >/dev/null 2>&1 || { echo "claude-discord: access needs jq" >&2; exit 1; }
  DISCORD_CHANNEL_ID="" DISCORD_USER_ID=""
  [ ! -f "$root/config.env" ] || . "$root/config.env"
  # The bot's main channel when access.json does not say which (and a part of a URL below): an id or nothing.
  [ -z "$DISCORD_CHANNEL_ID" ] || c_match "$DISCORD_CHANNEL_ID" '^[0-9]{1,20}$' ||
    { echo "claude-discord: access: DISCORD_CHANNEL_ID in $root/config.env is not a channel id (digits only); correct it there" >&2; exit 1; }
  # What names this machine keeps: the channels' (health writes channel-names), the people's (on-prompt writes
  # user-names) and the peer bots' (peers.json). They are for reading: every argument and every stored value is an id.
  # member-names: the names Discord's member list gave at the last --json, for set to show next to an id it has no
  # name of its own for (after it: a display name is anyone's to choose).
  a_cn="" a_un="" a_mn="" a_peers="" mode=""
  { a_cn=$(<"$d/channel-names"); } 2>/dev/null || :
  { a_un=$(<"$d/user-names"); } 2>/dev/null || :
  { a_mn=$(<"$d/member-names"); } 2>/dev/null || :
  { a_peers=$(<"$root/peers.json"); } 2>/dev/null || :
  { read -r mode < "$d/mode"; } 2>/dev/null || :
  mode=${mode//[[:cntrl:]]/}; mode=${mode:-none}
  a_host_name=$(uname -n); a_host_name=${a_host_name%%.*}
  # What every jq program below starts with. An id is digits and nothing else, to the end of the string (\z: Oniguruma's
  # $ also matches before a last newline). `policy` is the part of access.json this verb is about, as health --json
  # gives it (dm, dm_allow, groups: id, mention, allow), with the plugin's own defaults: no dmPolicy is pairing, no
  # requireMention is true, no allowFrom is everyone. A name is shown, never trusted: no control character, no bidi
  # override or isolate, no zero-width character or mark (the TUI's UNSAFE set), 40 characters.
  a_defs='
    def isid: type == "string" and test("\\A[0-9]{1,20}\\z");
    def ids: [arrays[] | tostring | select(isid)] | unique;
    def policy: {dm: (.dmPolicy | if type == "string" then . else "pairing" end), dm_allow: (.allowFrom | ids),
                 groups: [(.groups | if type == "object" then . else {} end) | to_entries[] | select((.key | isid) and (.value | type) == "object")
                          | {id: .key, mention: (.value.requireMention != false), allow: (.value.allowFrom | ids)}]};
    def safe: tostring | gsub("[[:cntrl:]\u200b-\u200f\u202a-\u202e\u2060\u2066-\u2069\ufeff]"; "") | .[0:40];
    def named: split("\n") | map(select(test("^[0-9]+ .")) | {key: (split(" ")[0]), value: (sub("^[0-9]+ "; "") | safe)}) | from_entries;
    def peerlist: (try fromjson catch null) | [objects | .peers | arrays | .[] | objects | {id: (.bot_id // "" | tostring), name: (.name // "" | safe)} | select(.id | isid)];
    def mainof($fb): if (.groups | length) == 1 then .groups[0].id else $fb end;'

  if [ "$act" = --json ]; then
    a_p=$(jq -r --arg fb "$DISCORD_CHANNEL_ID" "$a_defs"'policy | [mainof($fb), tojson] | join(" ")' "$f" 2>/dev/null) && [ -n "$a_p" ] ||
      { echo "claude-discord: access: $f is not valid JSON" >&2; exit 1; }
    main=${a_p%% *} a_p=${a_p#* }
    # Discord is asked as health asks it (the token on curl's stdin, never in an argument): four calls, six when the bot's
    # id (bot-id) or its server (channel-guild) is not known here yet, each 5 s at most and none started past 12 s, so
    # the answer arrives inside the cap of the ssh call that may carry it (30 s: access --host).
    a_t0=$SECONDS status=000 resp=""
    a_api() {  # $1 = path; sets $status and $resp
      local out=""
      [ $((SECONDS - a_t0)) -lt 12 ] && out=$(printf 'Authorization: Bot %s\n' "$tok" | curl -s --max-time 5 -w '\n%{http_code}' -H @- "https://discord.com/api/v10/$1" 2>/dev/null) || out=""
      status=${out##*$'\n'} resp=${out%$'\n'*}
      case $status in ''|*[!0-9]*) status=000;; esac
    }
    tok="" me="" gid="" cch="" errs="" a_g=null a_m=null a_c=null a_mm=null
    { while IFS= read -r l || [ -n "$l" ]; do case $l in DISCORD_BOT_TOKEN=*) tok=${l#DISCORD_BOT_TOKEN=};; esac; done < "$d/.env"; } 2>/dev/null || :
    { read -r me < "$d/bot-id"; } 2>/dev/null || :
    { read -r cch gid l < "$d/channel-guild"; } 2>/dev/null || :
    [ "$cch" = "$main" ] && c_match "$gid" '^[0-9]{1,20}$' || gid=""
    if [ -z "$tok" ]; then
      errs="no token in $d/.env: Discord was not asked for the channels"
    elif ! command -v curl >/dev/null 2>&1; then
      errs="no curl here: Discord was not asked for the channels"
    else
      if ! c_match "$me" '^[0-9]{1,20}$'; then
        a_api users/@me; me=$(printf '%s' "$resp" | jq -r '.id // empty' 2>/dev/null) || me=""
        c_match "$me" '^[0-9]{1,20}$' || me=""
      fi
      if [ -z "$gid" ] && [ -n "$main" ]; then
        a_api "channels/$main"; gid=$(printf '%s' "$resp" | jq -r '.guild_id // empty' 2>/dev/null) || gid=""
        c_match "$gid" '^[0-9]{1,20}$' || gid=""
      fi
      if [ -z "$me" ] || [ -z "$gid" ]; then
        errs="Discord did not say who this bot is or which server its channel is in (HTTP $status)"
      else
        a_api "guilds/$gid/channels"; case $status in 2*) a_c=$resp;; *) errs="the server's channels: HTTP $status";; esac
        a_api "guilds/$gid"; case $status in 2*) a_g=$resp;; *) errs="$errs${errs:+$'\n'}the server's roles: HTTP $status";; esac
        a_api "guilds/$gid/members/$me"; case $status in 2*) a_m=$resp;; *) errs="$errs${errs:+$'\n'}the bot's roles: HTTP $status";; esac
        # The member list answers only when the Server Members Intent is on for this bot. Off is no error and nothing
        # to turn on: the people are then the ones this machine has names for.
        a_api "guilds/$gid/members?limit=1000"; case $status in 2*) a_mm=$resp;; esac
      fi
    fi
    # Can the bot read a channel: VIEW_CHANNEL (1 << 10) and READ_MESSAGE_HISTORY (1 << 16) after Discord's own order:
    # @everyone's and the bot's roles' permissions together; then the channel's overwrites, @everyone's first, the
    # roles' next (their denies, then their allows), the bot's own last. An administrator (1 << 3) and the server's
    # owner read everything. jq only picks the numbers out, as text: its numbers are doubles and a permission set is
    # past 2^53 one day; the arithmetic is bash's (64 bits). A number that is none, or longer than 18 digits, a call
    # that failed, an answer with no @everyone role in it (jq then prints no line): not known ("?" in the TUI), never a guess.
    a_reads=""
    a_lines=$(printf '%s\n%s\n%s\n' "$a_g" "$a_m" "$a_c" | jq -rn --arg me "$me" '
      [inputs] as [$g, $m, $c]
      | ($g | objects | .id | tostring) as $gid | ($m | objects | [.roles | arrays | .[] | tostring]) as $mr
      | [$g.roles | arrays | .[] | objects] as $roles | select(any($roles[]; (.id | tostring) == $gid))
      | def ow($o): [$o[] | objects | "\(.allow // "0")/\(.deny // "0")"] | join(",") | if . == "" then "-" else . end;
        "B " + ([$roles[] | (.id | tostring) as $i | select($i == $gid or any($mr[]; . == $i)) | .permissions | tostring] | join(" ")),
        "O " + (if ($g.owner_id // "" | tostring) == $me then "1" else "0" end),
        ($c | arrays | .[] | objects | select(.type == 0 or .type == 5 or .type == 15)
         | [.permission_overwrites | arrays | .[] | objects] as $o
         | "C \(.id) \(ow([$o[] | select((.id | tostring) == $gid)])) \(ow([$o[] | (.id | tostring) as $i | select((.type == 0 or .type == "role") and $i != $gid and any($mr[]; . == $i))])) \(ow([$o[] | select((.id | tostring) == $me)]))")' 2>/dev/null) || a_lines=""
    a_num() { c_match "$1" '^[0-9]{1,18}$'; }
    a_ow() {  # $1 = "allow/deny,..." or "-": folded into p (the denies of all of them, then their allows); unsure=1 for a number that is none
      local x al=0 dn=0
      [ "$1" != - ] || return 0
      for x in ${1//,/ }; do
        if a_num "${x%/*}" && a_num "${x#*/}"; then al=$((al | 10#${x%/*})) dn=$((dn | 10#${x#*/})); else unsure=1; fi
      done
      p=$(( (p & ~dn) | al ))
    }
    base=0 sure=yes all=0
    while read -r t a b c e; do
      case $t in
        B) for x in $a $b $c $e; do if a_num "$x"; then base=$((base | 10#$x)); else sure=no; fi; done;;
        O) [ "$a" != 1 ] || all=1;;
        C) p=$base unsure=0; a_ow "$b"; a_ow "$c"; a_ow "$e"
           if [ "$sure" != yes ] || ! c_match "$a" '^[0-9]{1,20}$'; then :
           elif [ "$all" = 1 ] || [ $((base & 8)) != 0 ]; then a_reads="$a_reads$a 1"$'\n'
           elif [ "$unsure" = 1 ]; then :
           elif [ $((p & 1024)) != 0 ] && [ $((p & 65536)) != 0 ]; then a_reads="$a_reads$a 1"$'\n'
           else a_reads="$a_reads$a 0"$'\n'; fi;;
      esac
    done <<<"$a_lines"
    a_doc() {  # the document, from the three answers on stdin (null for one that did not come)
      jq -cn --arg bot "$bot" --arg me "$me" --arg host "$a_host_name" --arg project "$PWD" --arg mode "$mode" --arg owner "$DISCORD_USER_ID" \
        --arg main "$main" --arg ver "$(plugin_version "$self_root")" --arg cn "$a_cn" --arg un "$a_un" --arg peers "$a_peers" \
        --arg reads "$a_reads" --arg errs "$errs" --argjson policy "$a_p" "$a_defs"'
        [inputs] as [$g, $c, $mm]
        | ($cn | named) as $CN | ($un | named) as $UN | ($peers | peerlist) as $PL
        | ($reads | split("\n") | map(select(. != "") | split(" ") | {key: .[0], value: (.[1] == "1")}) | from_entries) as $R
        | [$c | arrays | .[] | objects | select(.type == 0 or .type == 5 or .type == 15) | . + {id: (.id | tostring)}] as $gc
        | ([$mm | arrays | .[] | objects | select(.user | type == "object")
            | {id: (.user.id | tostring), name: (.nick // .user.global_name // .user.username // "" | safe), bot: (.user.bot == true)}]) as $api
        | ([$PL[] | . + {bot: true}] + [$UN | to_entries[] | {id: .key, name: .value, bot: false}]) as $kept
        | {access: 1, version: $ver, bot: $bot, bot_id: $me, host: $host, project: $project, mode: $mode,
           owner: (if ($owner | isid) then $owner else "" end), main: $main, peers: [$PL[] | select((.name | ascii_downcase) != ($bot | ascii_downcase)) | .id],
           guild: (if ($g | type) == "object" then {id: ($g.id | tostring), name: ($g.name // "" | safe)} else null end),
           policy: $policy,
           channels: ([$gc | sort_by(.position // 0)[] | {id, name: (.name // "" | safe), kind: (if .type == 15 then "forum" elif .type == 5 then "news" else "text" end), read: $R[.id]}]
                      + [$policy.groups[] | .id as $i | select(all($gc[]; .id != $i)) | {id: $i, name: ($CN[$i] // ""), kind: "unknown", read: null}]),
           # kept: the name this machine keeps (user-names, peers.json), the only one the TUI takes a typed name for.
           people: (([$api[] | . + {k: ""}] + [$kept[] | . + {k: .name}] + [($policy.dm_allow + [$policy.groups[].allow[]])[] | {id: ., name: "", bot: false, k: ""}])
                    | map(select(.id | isid)) | group_by(.id)
                    | map({id: .[0].id, name: (map(.name | select(. != ""))[0] // ""), kept: (map(.k | select(. != ""))[0] // ""), bot: any(.[]; .bot)})),
           members: (if ($mm | type) == "array" then "api" else "names" end),
           errors: ($errs | split("\n") | map(select(. != "")))}'
    }
    if [ "$a_mm" != null ]; then
      a_mn=$(printf '%s' "$a_mm" | jq -r "$a_defs"'.[]? | objects | select(.user | type == "object")
        | [(.user.id | tostring), (.nick // .user.global_name // .user.username // "" | safe)] | select((.[0] | isid) and .[1] != "") | join(" ")' 2>/dev/null) &&
        (umask 077; printf '%s\n' "$a_mn" > "$d/member-names.$$") 2>/dev/null && mv -f "$d/member-names.$$" "$d/member-names" 2>/dev/null || rm -f "$d/member-names.$$"
    fi
    printf '%s\n%s\n%s\n' "$a_g" "$a_c" "$a_mm" | a_doc 2>/dev/null ||
      { errs="$errs${errs:+$'\n'}Discord's answer could not be read"; a_reads=""; printf 'null\nnull\nnull\n' | a_doc; } ||
      { echo "claude-discord: access: the document could not be made from $f" >&2; exit 1; }
    exit 0
  fi

  # set. One jq program does both halves: with $out = "diff" it prints what the words would change, one line a change;
  # with $out = "doc" it prints the new access.json, made from the file as it is THEN (the plugin adds its own keys to
  # it: a pending pairing), and fails when the policy in it is no longer the one the diff was made from ($seen).
  # The words are applied in order to the whole document, so every key this verb does not know stays as it is.
  # A diff line is <kind> US <where> US <text>; the kinds: P the policy the diff was made from, as JSON; W a change that
  # widens who can drive the bot (shown first, red); C any other change; N a warning; E a change that cannot be
  # made (exit 2). Widening is: an @mention no longer required; a channel opened to anyone; DMs to pairing, or back
  # from disabled; a person added to the DM allowlist (they then answer the bot's permission prompts too); a person
  # this bot listed nowhere until now.
  a_prog="$a_defs"'
    def has_grp($c): (.d.groups | type) == "object" and (.d.groups | has($c)) and (.d.groups[$c] | type) == "object";
    def without($u): [arrays[] | select(tostring != $u)];
    def with($u): [arrays[]] | if any(.[]; tostring == $u) then . else . + [$u] end;
    def step($x):
      if .err then .
      elif ($x | startswith("channel+")) then $x[8:] as $c
        | if has_grp($c) then . elif $owner == "" then .err = "channel+\($c): no owner id is known (DISCORD_USER_ID in config.env), so who may write there cannot be set"
          else .d.groups = ((.d.groups | if type == "object" then . else {} end) + {($c): {requireMention: true, allowFrom: [$owner]}}) end
      elif ($x | startswith("channel-")) then $x[8:] as $c | (if has_grp($c) then del(.d.groups[$c]) else . end) | .any -= [$c]
      elif ($x | startswith("mention:")) then ($x[8:] | split("=")) as [$c, $v]
        | if has_grp($c) then .d.groups[$c].requireMention = ($v == "on") else .err = "mention:\($c): the bot does not listen in that channel (channel+\($c) first)" end
      elif ($x | startswith("allow:")) then ($x[6:] | capture("^(?<c>[0-9]+)(?<o>[-+=])(?<u>.*)$")) as $m | $m.c as $c
        | if has_grp($c) | not then .err = "allow:\($c): the bot does not listen in that channel (channel+\($c) first)"
          elif $m.o == "=" then .d.groups[$c].allowFrom = [] | .any += [$c]
          elif $m.o == "+" then .d.groups[$c].allowFrom |= with($m.u) | .any -= [$c]
          else .d.groups[$c].allowFrom |= without($m.u) end
      elif $x == "dm=off" then .d.dmPolicy = "allowlist" | .d.allowFrom = []
      elif ($x | startswith("dm=")) then .d.dmPolicy = $x[3:]
      elif ($x | startswith("dm+")) then .d.allowFrom |= with($x[3:])
      elif ($x | startswith("dm-")) then .d.allowFrom |= without($x[3:])
      else . end;
    def dmw: if .dm == "disabled" then "disabled" elif .dm != "allowlist" then "pairing" elif .dm_allow == [] then "off" else "allowlist" end;
    . as $doc | policy as $P0
    # The mode after the call: the last mode= word, else the one the bot has.
    | ([$words | split(" ")[] | select(startswith("mode="))] | last // null | if . then .[5:] else $mode end) as $nm
    | ([$peers | peerlist[] | select((.name | ascii_downcase) != ($bot | ascii_downcase)) | .id]) as $pi
    | (reduce ($words | split(" ")[] | select(. != "")) as $x ({d: $doc, any: [], err: null}; step($x))) as $r0
    # Entering dev-manager, the peers of peers.json go into every channel that lists its senders: what `setup --mode`
    # does, done here once, after all the words (wherever mode= stands), so the diff shows it, the question is asked and
    # the file written under the lock holds it; setup is then told not to do it again (CLAUDE_DISCORD_ACCESS_PEERS).
    | (if $nm == "dev-manager" and $mode != "dev-manager" and ($r0.err | not) and (($r0.d.groups | type) == "object")
       then $r0 | .d.groups |= map_values(if (.allowFrom // []) == [] then . else .allowFrom = (.allowFrom as $a | $a + ($pi - $a)) end)
       else $r0 end) as $r
    | ($r0.d | policy | .groups | map({key: .id, value: .}) | from_entries) as $Gw
    | ($r.d | policy) as $P1
    | ($P0.groups | map({key: .id, value: .}) | from_entries) as $G0 | ($P1.groups | map({key: .id, value: .}) | from_entries) as $G1
    # The last sender taken off a list would leave it empty, and an empty list is everyone: never by a removal.
    | ([$P1.groups[] | select(.allow == [] and ((.id as $i | $r.any | index($i)) == null) and ($G0[.id] == null or $G0[.id].allow != [])) | .id][0]) as $emptied
    | (if $r.err then $r.err elif $emptied then "allow:\($emptied): that would leave no sender, and a channel with none listed takes everyone. Say allow:\($emptied)=any to mean that, or channel-\($emptied) to stop listening there" else null end) as $err
    | if $out == "doc" then
        (if $err or (($P0 | tojson) != $seen) then error("changed") else $r.d end)
      else
        ($cn | named) as $CN | ($un | named) as $UN | ($mn | named) as $MN | ($peers | peerlist) as $PL | ($PL | map({key: .id, value: .name}) | from_entries) as $PN
        | def ch: "#" + ($CN[.] // .);
          # A name kept here goes before the id; one only the Discord member list gave (the person chose it) after it.
          def who: . as $u | ($UN[$u] // $PN[$u] // "") | if . != "" then "\(.) (\($u))" else ($MN[$u] // "" | if . == "" then $u else "\($u) (\(.))" end) end;
          def whos: if . == [] then "anyone" else map(who) | join(", ") end;
          def rule: if .mention then "an @mention required" else "any message" end;
          def line($k; $l; $t): [$k, $l, $t] | join("\u001f");
          ([$P0.groups[].allow[]] + $P0.dm_allow | unique) as $known
        | line("P"; ""; $P0 | tojson),
          (if $err then line("E"; ""; $err) else
            ($P1.groups[] | . as $n | $G0[$n.id] as $o
             | if $o == null then
                 line("C"; $n.id | ch; "+ listens here: \($n | rule), from \($n.allow | whos)"),
                 (if $n.mention then empty else line("W"; $n.id | ch; "answers every message there, with no @mention") end),
                 (if $n.allow == [] then line("W"; $n.id | ch; "anyone in the channel may write to it") else empty end)
               else
                 (if $o.mention and ($n.mention | not) then line("W"; $n.id | ch; "an @mention required -> any message")
                  elif ($o.mention | not) and $n.mention then line("C"; $n.id | ch; "any message -> an @mention required") else empty end),
                 (if $o.allow != [] and $n.allow == [] then line("W"; $n.id | ch; "from \($o.allow | whos) -> from anyone in the channel")
                  elif $o.allow == [] and $n.allow != [] then line("C"; $n.id | ch; "from anyone -> from \($n.allow | whos)")
                  else (($n.allow - $o.allow)[] | select(. as $u | $known | index($u)) | line("C"; $n.id | ch; "+ \(who) may write to it there")),
                       (($o.allow - $n.allow)[] | line("C"; $n.id | ch; "- \(who) may no longer write to it there")) end)
               end),
            ($P0.groups[] | select($G1[.id] == null) | line("C"; .id | ch; "- stops listening here")),
            ([$P1.groups[] | . as $n | select($G0[$n.id] == null or $G0[$n.id].allow != []) | ($n.allow - $known)[] | {u: ., c: $n.id}] | group_by(.u)[]
             | line("W"; .[0].u | who; "new to this bot: may write to it in \(map(.c | ch) | join(", "))")),
            (($P0 | dmw) as $a | ($P1 | dmw) as $b
             | if $a == $b then empty
               elif $a == "disabled" then line("W"; "DMs"; "disabled -> \($b): the bot receives again, in its channels too (disabled drops every message)")
               elif $b == "pairing" then line("W"; "DMs"; "\($a) -> pairing: anyone who shares a server with the bot can DM it and is sent a pairing code")
               else line("C"; "DMs"; "\($a) -> \($b)") end),
            (($P1.dm_allow - $P0.dm_allow)[] | line("W"; "DMs"; "+ \(who) may DM it, and answers its permission prompts")),
            (($P0.dm_allow - $P1.dm_allow)[] | line("C"; "DMs"; "- \(who) may no longer DM it")),
            # Warnings: the owner taken off a list, the main channel moved, a dev-manager cut off from a peer.
            (select($owner != "") | $P0.groups[] | . as $o | $G1[$o.id] | select(. != null and .allow != [] and ($o.allow | index($owner)) != null and (.allow | index($owner)) == null)
             | line("N"; ""; "\($owner | who) is the owner of this bot (DISCORD_USER_ID) and can no longer write to it in \($o.id | ch)")),
            (select($owner != "" and ($P0.dm_allow | index($owner)) != null and ($P1.dm_allow | index($owner)) == null)
             | line("N"; ""; "\($owner | who) is the owner of this bot and no longer gets its DMs or its permission prompts")),
            (($P0 | mainof($fb)) as $a | ($P1 | mainof($fb)) as $b | select($a != $b)
             | line("N"; ""; "the main channel of the bot becomes \(if $b == "" then "none" else ($b | ch) end) (was \($a | ch)): its session prompt, its hooks and health use that one"
                    + (if $b != "" and $G1[$b] == null then ", and it does not listen there" else "" end))),
            (select($nm == "dev-manager") | $PL[] | . as $p | $P0.groups[] | . as $o | $G1[$o.id]
             | select(. != null and .allow != [] and ($o.allow | index($p.id)) != null and (.allow | index($p.id)) == null)
             | line("N"; ""; "\($p.id | who) is a peer dev bot (peers.json) and can no longer reach this bot in \($o.id | ch)")),
            # A peer a word took off, back on the list because the bot enters dev-manager: no removal is shown, so say why.
            ($P1.groups[] | . as $n | $pi[] | select(. as $p | ($G0[$n.id].allow // [] | index($p)) != null and ($Gw[$n.id].allow // [] | index($p)) == null and ($n.allow | index($p)) != null)
             | line("N"; ""; "\(who) is a peer dev bot (peers.json): entering dev-manager puts it back in \($n.id | ch)"))
          end)
      end'
  a_jq() {  # $1 = diff|doc, $2 = the policy the diff was made from (doc)
    jq -r --arg out "$1" --arg seen "${2:-}" --arg words "$a_words" --arg owner "$a_owner" --arg fb "$DISCORD_CHANNEL_ID" --arg bot "$bot" \
      --arg mode "$mode" --arg cn "$a_cn" --arg un "$a_un" --arg mn "$a_mn" --arg peers "$a_peers" "$a_prog" "$f"
  }
  a_owner=$DISCORD_USER_ID; c_match "$a_owner" '^[0-9]{1,20}$' || a_owner=""
  a_words=" $*"
  a_diff=$(a_jq diff 2>/dev/null) && [ -n "$a_diff" ] || { echo "claude-discord: access: $f is not valid JSON; nothing was changed" >&2; exit 1; }
  red="" yel="" off=""
  [ ! -t 1 ] || { red=$'\033[1;31m' yel=$'\033[33m' off=$'\033[0m'; }
  # The widenings are shown first, then the other changes, then the warnings; one question is asked for all of them.
  a_seen="" a_nw=0 a_n=0 a_warn="" a_sw="" a_sc=""
  while IFS=$'\x1f' read -r k where text; do
    case $k in
      P) a_seen=$text;;
      E) echo "claude-discord: access: $text" >&2; exit 2;;
      W) a_nw=$((a_nw + 1)); a_sw="$a_sw"$'\n'"$red  ! $where: $text$off";;
      C) a_n=$((a_n + 1)); a_sc="$a_sc"$'\n'"    $where: $text";;
      N) a_warn="$a_warn"$'\n'"${yel}warning: $text$off";;
    esac
  done <<<"$a_diff"
  # The mode is not in access.json: its line is made here. Out of dev-manager with a hosts ledger, `setup --mode` deletes
  # the ledger, which stops the manager's monitor: a widening.
  newmode=$mode
  for w in "$@"; do case $w in mode=*) newmode=${w#mode=};; esac; done
  a_mgr=""; [ "$newmode" != dev-manager ] || [ -f "$d/hosts" ] || a_mgr=": it gets a hosts ledger (this machine) and its monitor starts, which posts in #bot-health-check"
  if [ "$newmode" != "$mode" ] && [ "$mode" = dev-manager ] && [ -f "$d/hosts" ]; then
    a_mq="mode: dev-manager -> $newmode: its hosts ledger ($d/hosts) is deleted and its monitor and keeper stop within a minute. Nobody is told in #bot-health-check when a bot of its hosts goes down"
    a_nw=$((a_nw + 1)); a_sw="$a_sw"$'\n'"$red  ! $a_mq$off"
  elif [ "$newmode" != "$mode" ]; then
    a_n=$((a_n + 1)); a_sc="$a_sc"$'\n'"    mode: $mode -> $newmode$a_mgr"
  fi
  if [ "$a_nw" = 0 ] && [ "$a_n" = 0 ]; then echo "claude-discord: access: $bn is already so; nothing to change"; exit 0; fi
  printf '%s%s%s%s\n' "claude-discord: access: $bn on $a_host_name, $f" "$a_sw" "$a_sc" "$a_warn"
  [ -t 0 ] && [ -t 1 ] || { echo "claude-discord: access: not a terminal (stdin and stdout), so nothing was changed: run it in a terminal to answer for these changes" >&2; exit 3; }
  a_no() { echo "claude-discord: access: answered no; nothing was changed" >&2; exit 4; }
  # One question for the whole change set (1.13.1): y writes all of it; n, the end of input or anything else, none.
  a_t=$((a_nw + a_n))
  if [ "$a_nw" = 0 ]; then q="Apply $([ "$a_t" = 1 ] && echo "this change" || echo "these $a_t changes")?"
  elif [ "$a_nw" = "$a_t" ]; then q="Apply $([ "$a_t" = 1 ] && echo "this widening change" || echo "these $a_t widening changes")?"
  else q="Apply $a_t changes, $a_nw of them widening?"; fi
  # Before it, on its own line, a marker: U+2060 alone (no control character, nothing on a terminal), which no Discord
  # name can hold (safe, in a_defs, takes it out of every name). The TUI asks only after it (1.13.1): a name that ends
  # in [y/N] can never pass for the question.
  printf '\342\201\240\n' >&2
  a=""; read -r -p "$q [y/N] " a || a=""
  case $a in y|Y) ;; *) a_no;; esac
  a_file=""; case $'\n'$a_diff in *$'\n'[WC]$'\x1f'*) a_file=1;; esac   # a change of access.json itself, not of the mode alone
  # access.log: when, who (the account here), on which machine, and what was done: a line for access.json (with the
  # change words, ids only) right after its rename, before setup --mode runs, so a run stopped in setup still has its
  # write logged; then a line for the mode, set or failed.
  a_log() { (umask 077; printf '%s %s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(id -un 2>/dev/null || echo unknown)" "$a_host_name" "$1" >> "$d/access.log") 2>/dev/null || :; }
  if [ -n "$a_file" ]; then
    # One writer of ours at a time (flock through perl on <file>.lock, as the ledger's: fd 7, never stale), and the
    # file replaced by rename, never written in place: the plugin reads it at every message, and one it cannot parse it
    # moves aside and answers with its defaults (pairing, no channel). The plugin takes no lock: it rewrites the file
    # itself when a DM asks for a pairing code or one expires, which is why the new document is made from the file as
    # it is now, a moment before the rename.
    exec 7>>"$f.lock"
    perl -e 'open(my $l, ">&=", 7) or exit 1; for (1 .. 50) { exit 0 if flock($l, 6); select(undef, undef, undef, 0.1) } exit 1' ||
      { echo "claude-discord: access: $f is being changed by another claude-discord access; nothing was changed" >&2; exit 1; }
    a_new=$(a_jq doc "$a_seen" 2>/dev/null) && [ -n "$a_new" ] ||
      { echo "claude-discord: access: $f changed while you were answering (or is no longer valid JSON); nothing was changed, run it again" >&2; exit 1; }
    (umask 077; printf '%s\n' "$a_new" > "$f.cd.$$") && mv -f "$f.cd.$$" "$f" ||
      { rm -f "$f.cd.$$"; echo "claude-discord: access: could not write $f; it is as it was" >&2; exit 1; }
    a_log "access.json:$a_words"
    exec 7>&-
  fi
  [ -z "$a_file" ] || echo "claude-discord: access: $f written. The plugin reads it at the next message: no restart."
  if [ "$newmode" != "$mode" ]; then
    # setup --mode, with the mode on its stdin and nothing after it: its peers and hosts questions read the end of
    # input, which keeps both lists (README, Modes).
    if ! printf '%s\n' "$newmode" | CLAUDE_DISCORD_ACCESS_PEERS=written "$self_path" setup "$bot" --mode; then
      a_log "mode: $mode -> $newmode failed (claude-discord setup $bn --mode)"
      echo "claude-discord: access: the mode was not changed (claude-discord setup $bn --mode, above)${a_file:+; the changes to access.json stay}" >&2; exit 1
    fi
    echo "claude-discord: access: the hooks follow the new mode from their next call; the dev-manager rules reach, or leave, a running session at its next start, compact or clear."
    [ "$newmode" != dev-manager ] || echo "claude-discord: access: its peers and the hosts it checks: claude-discord setup $bn --mode, and claude-discord hosts add"
    a_log "mode: $mode -> $newmode"
  fi
  exit 0
fi
