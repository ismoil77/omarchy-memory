#!/bin/sh
# Signal every process in one row of the popup's list.
#
#   kill-group.sh NAME SIGNAL      (SIGNAL: TERM or KILL)
#
# Rows group by basename of argv[0], so the PIDs are looked up again here with
# the same rule instead of trusting a list that may be seconds old. Nothing is
# filtered by name: the kernel decides what may be signalled. A refused kill
# (EPERM) is reported with the owner of the process, as the system reports it.
#
# Prints: NAME \t signalled \t denied \t owners-of-denied (space separated)

name=$1
sig=${2:-TERM}
self=$$

pids=$(ps -eo pid=,rss=,args= | awk -v want="$name" '$2 > 0 { n = $3; sub(/.*\//, "", n); sub(/:$/, "", n); if (n == want) print $1 }')

ok=0
denied=0
owners=""
for p in $pids; do
  [ "$p" = "$self" ] && continue
  if kill -s "$sig" "$p" 2>/dev/null; then
    ok=$((ok + 1))
  elif [ -d "/proc/$p" ]; then
    # Still there after a failed kill: the kernel refused it.
    denied=$((denied + 1))
    u=$(stat -c %U "/proc/$p" 2>/dev/null)
    case " $owners " in *" $u "*) ;; *) owners="$owners $u" ;; esac
  fi
  # Gone in between (ESRCH): nothing to report.
done

printf '%s\t%d\t%d\t%s\n' "$name" "$ok" "$denied" "${owners# }"
