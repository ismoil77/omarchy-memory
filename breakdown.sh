#!/bin/sh
# Split one row of the popup's list into what is inside it.
#
#   breakdown.sh NAME
#
# Same matching rule as kill_group.py (basename of argv[0]). Each process gets
# a label, and processes with the same label are summed:
#   - Chromium/Electron helpers: their --type (renderer, gpu-process, ...),
#     with extension and browser-UI renderers told apart from tabs;
#   - everything else: the script it runs (first non-flag argument) and the
#     folder it runs in (/proc/PID/cwd), e.g. "vite · amberflip".
#
# Prints: rss_kb \t count \t label \t pids   (sorted by rss, largest first)

name=$1
[ -n "$name" ] || { echo "breakdown.sh: no name given" >&2; exit 2; }

ps -eo pid=,rss=,args= | want=$name awk '$2 > 0 { n = $3; sub(/.*\//, "", n); sub(/:$/, "", n); if (n == ENVIRON["want"]) print $1, $2 }' |
while read -r pid rss; do
  # Chromium rewrites its argv into one space-separated string, so split on spaces too.
  args=$(tr '\0 ' '\n\n' < "/proc/$pid/cmdline" 2>/dev/null) || continue
  dir=$(readlink "/proc/$pid/cwd" 2>/dev/null)
  # First line: Chromium process type (or empty). Then up to 4 non-flag arguments.
  info=$(printf '%s\n' "$args" | awk '
    NR == 1 { next }
    /^--type=/ { t = substr($0, 8) }
    /^--utility-sub-type=/ { u = substr($0, 20); sub(/.*\./, "", u) }
    /^--extension-process$/ { ext = 1 }
    /^--top-chrome-webui$/ { ui = 1 }
    !/^-/ && NF && n < 4 { a[++n] = $0 }
    END {
      if (t == "renderer") print ext ? "extensions" : ui ? "browser UI" : "tab"
      else if (t == "utility") print "utility" (u ? ": " u : "")
      else print t
      for (i = 1; i <= n; i++) print a[i]
    }')
  label=$(printf '%s\n' "$info" | head -n 1)
  if [ -z "$label" ]; then
    # The script is the first argument that is a real file (flag values are not),
    # plus the word after it when that is a subcommand: "artisan serve".
    # Unreadable cwd (another user's process) -> trust the first argument.
    script=$(printf '%s\n' "$info" | tail -n +2 | {
      found=
      while read -r a; do
        if [ -n "$found" ]; then
          case $a in */*) ;; *) found="$found $a" ;; esac
          break
        fi
        case $a in /*) f=$a ;; *) f="$dir/$a" ;; esac
        # /proc/PID/root also finds scripts inside containers.
        if [ -z "$dir" ] || { [ -f "$f" ] || [ -f "/proc/$pid/root$f" ]; } 2>/dev/null; then
          found=${a##*/}
        fi
      done
      printf '%s\n' "$found"
    })
    case $dir in ""|/|"$HOME") place= ;; *) place=${dir##*/} ;; esac
    label="${script}${script:+${place:+ · }}${place}"
  fi
  [ -n "$label" ] || label="(main)"
  # Each tab is its own line so one heavy tab can be stopped alone.
  [ "$label" = tab ] && label="tab · pid $pid"
  printf '%s\t%s\t%s\n' "$rss" "$pid" "$label"
done | awk -F '\t' '{ r[$3] += $1; c[$3]++; p[$3] = p[$3] " " $2 } END { for (k in r) printf "%d\t%d\t%s\t%s\n", r[k], c[k], k, substr(p[k], 2) }' | sort -rn
