# sourced by hooks/turn/on-session-start and bin/lib/health.sh: pin_job
# pin_job <job id> <bot state dir> <jobs dir>: the job id into <jobs dir>/pins.json, the id this bot pinned before (its
# <state dir>/pinned-job) out of it, and pinned-job set to the new id. The rules are on-session-start's (its header
# says why each holds): the CLI's own lock (mkdir pins.json.lock, about 0.2 s, else nothing), a rename, a file that
# is not a JSON array of strings left alone, no other entry touched, and an id already listed is someone else's pin
# (a person's ctrl+t): kept, and not recorded in pinned-job, so this bot's next job change never takes it out. Status 0
# when the id is in pins.json afterwards.
pin_job() {
  local id=$1 sd=$2 pins=$3/pins.json old="" n=0 new added
  [[ $id =~ ^[0-9a-f]{8}$ ]] || return 1
  { read -r old < "$sd/pinned-job"; } 2>/dev/null || old=""
  [[ $old =~ ^[0-9a-f]{8}$ ]] || old=""   # what is no job id names nothing this bot pinned
  until mkdir "$pins.lock" 2>/dev/null; do
    n=$((n + 1)); [ "$n" -lt 5 ] || return 1
    sleep 0.05
  done
  if [ -e "$pins" ] && grep -q '[^[:space:]]' "$pins" 2>/dev/null; then
    new=$(jq -rs --arg id "$id" --arg old "$old" '
      if length == 1 and (.[0] | type == "array" and all(.[]; type == "string")) then .[0]
        | if $old != "" and $old != $id then map(select(. != $old)) else . end
        | if any(.[]; . == $id) then "kept", . else "added", . + [$id] end
      else empty end' "$pins" 2>/dev/null) || new=""
  else
    new=$(jq -rn --arg id "$id" '"added", [$id]' 2>/dev/null) || new=""
  fi
  [ -n "$new" ] || { rmdir "$pins.lock" 2>/dev/null; return 1; }
  added=${new%%$'\n'*}; new=${new#*$'\n'}
  if printf '%s' "$new" 2>/dev/null > "$pins.tmp.$$" && mv -f "$pins.tmp.$$" "$pins" 2>/dev/null; then
    if [ "$added" = added ]; then printf '%s\n' "$id" 2>/dev/null > "$sd/pinned-job"
    elif [ "$old" != "$id" ]; then rm -f "$sd/pinned-job" 2>/dev/null; fi   # someone else pinned this job
    rmdir "$pins.lock" 2>/dev/null; return 0
  fi
  rm -f "$pins.tmp.$$" 2>/dev/null; rmdir "$pins.lock" 2>/dev/null; return 1
}
