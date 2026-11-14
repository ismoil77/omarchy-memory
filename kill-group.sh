#!/bin/sh
# Signal every process in one row of the popup's list.
#
#   kill-group.sh NAME SIGNAL [PID...]     (SIGNAL: TERM or KILL)
#
# Rows group by basename of argv[0], so the PIDs are looked up again here with
# the same rule instead of trusting a list that may be seconds old. Nothing is
# filtered by name: the kernel decides what may be signalled. A refused kill
# (EPERM) is reported with the owner of the process, as the system reports it.
#
# Prints: NAME \t signalled \t denied \t owners-of-denied (space separated)
# An empty NAME or a SIGNAL other than TERM/KILL signals nothing, prints
# nothing and exits 2.

name=$1
sig=${2:-TERM}
self=$$

[ -n "$name" ] || { echo "kill-group.sh: no name given" >&2; exit 2; }
case "$sig" in
  TERM|KILL) ;;
  *) echo "kill-group.sh: signal must be TERM or KILL" >&2; exit 2 ;;
esac

# The name travels in the environment: awk -v would expand backslash escapes in it.
pids=$(ps -eo pid=,rss=,args= | want=$name awk '$2 > 0 { n = $3; sub(/.*\//, "", n); sub(/:$/, "", n); if (n == ENVIRON["want"]) print $1 }')

# Extra arguments are PIDs: only those of the row's processes are signalled
# (an inner line of the popup). A PID that is not one of them any more is skipped.
shift 2 2>/dev/null || shift $#
if [ $# -gt 0 ]; then
  only=" $* "
  kept=""
  for p in $pids; do
    case "$only" in *" $p "*) kept="$kept $p" ;; esac
  done
  pids=$kept
fi

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
