# sourced by hooks/turn/on-session-start and bin/lib/health.sh: pin_job
# pin_job <job id> <bot state dir> <jobs dir>: the job id into <jobs dir>/pins.json, the id this bot pinned before (its
# <state dir>/pinned-job) out of it, and pinned-job set to the new id. The rules are on-session-start's (its header
# says why each holds): the CLI's own lock (mkdir pins.json.lock, about 0.2 s, else nothing), a rename, a file that
# is not a JSON array of strings left alone, no other entry touched, and an id already listed is someone else's pin
# (a person's ctrl+t): kept, and pinned-job is written all the same (1.19.7: person_stopped, boot and recover read it),
# with the id also in <state dir>/pin-foreign (one id a line), so this bot's next job change never takes it out. A 4th
# argument "own" (health's repair of a bot whose pinned-job was empty: the job is this bot's by its state dir) records
# nothing there. Status 0 when the id is in pins.json afterwards.
pin_job() {
  local id=$1 sd=$2 pins=$3/pins.json own=${4:-} old="" n=0 new added
  [[ $id =~ ^[0-9a-f]{8}$ ]] || return 1
  { read -r old < "$sd/pinned-job"; } 2>/dev/null || old=""
  [[ $old =~ ^[0-9a-f]{8}$ ]] || old=""   # what is no job id names nothing this bot pinned
  ! grep -qxF "$old" "$sd/pin-foreign" 2>/dev/null || old=""   # recorded as a person's pin: never taken out
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
    printf '%s\n' "$id" 2>/dev/null > "$sd/pinned-job"
    # An id this bot just added is its own: out of pin-foreign. Another job in pin-foreign stays, for pin_drop (health) to take
    # out once it no longer runs. An id already listed was pinned by someone else, unless health says it is the bot's own.
    if [ "$added" = added ]; then pin_foreign_forget "$sd" "$id"
    elif [ -z "$own" ] && [ "$old" != "$id" ] && ! grep -qxF "$id" "$sd/pin-foreign" 2>/dev/null; then printf '%s\n' "$id" 2>/dev/null >> "$sd/pin-foreign"; fi
    rmdir "$pins.lock" 2>/dev/null; return 0
  fi
  rm -f "$pins.tmp.$$" 2>/dev/null; rmdir "$pins.lock" 2>/dev/null; return 1
}
# pin_foreign_forget <bot state dir> <id>: the id out of pin-foreign (the file goes when it is empty).
pin_foreign_forget() {
  [ -f "$1/pin-foreign" ] || return 0
  grep -vxF "$2" "$1/pin-foreign" 2>/dev/null > "$1/pin-foreign.tmp.$$" || :
  if [ -s "$1/pin-foreign.tmp.$$" ]; then mv -f "$1/pin-foreign.tmp.$$" "$1/pin-foreign" 2>/dev/null; else rm -f "$1/pin-foreign.tmp.$$" "$1/pin-foreign" 2>/dev/null; fi
}
# pin_drop <bot state dir> <jobs dir> (1.19.7): the ids in pin-foreign that are not the bot's current pinned-job and whose
# job is gone (<jobs dir>/<id> no longer exists: claude rm) leave pins.json and pin-foreign (a pin of a removed job is useless);
# a job that only finished keeps its dir, and a person's ctrl+t pin of it stays. The CLI's lock and a rename, as pin_job; a pins.json that is not a JSON
# array of strings is left alone, and so is pin-foreign then.
pin_drop() {
  local sd=$1 pins=$2/pins.json cur="" f drop="" n=0 new
  [ -s "$sd/pin-foreign" ] && [ -e "$pins" ] || return 0
  { read -r cur < "$sd/pinned-job"; } 2>/dev/null || cur=""
  while IFS= read -r f || [ -n "$f" ]; do
    [[ $f =~ ^[0-9a-f]{8}$ ]] && [ "$f" != "$cur" ] || continue
    [ ! -d "$2/$f" ] || continue
    drop="$drop$f"$'\n'
  done < "$sd/pin-foreign"
  [ -n "$drop" ] || return 0
  until mkdir "$pins.lock" 2>/dev/null; do
    n=$((n + 1)); [ "$n" -lt 5 ] || return 1
    sleep 0.05
  done
  new=$(jq -s --arg d "$drop" '($d | split("\n")) as $x
    | if length == 1 and (.[0] | type == "array" and all(.[]; type == "string")) then .[0] | map(select(. as $i | $x | index($i) | not)) else empty end' "$pins" 2>/dev/null) || new=""
  if [ -n "$new" ] && printf '%s' "$new" 2>/dev/null > "$pins.tmp.$$" && mv -f "$pins.tmp.$$" "$pins" 2>/dev/null; then
    rmdir "$pins.lock" 2>/dev/null
    while IFS= read -r f; do [ -z "$f" ] || pin_foreign_forget "$sd" "$f"; done <<<"$drop"
    return 0
  fi
  rm -f "$pins.tmp.$$" 2>/dev/null; rmdir "$pins.lock" 2>/dev/null; return 1
}
