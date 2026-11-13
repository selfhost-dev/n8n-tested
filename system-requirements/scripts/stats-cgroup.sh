#!/bin/sh
# Samples every Docker container's cgroup v2 counters into a CSV until killed.
# Needs no docker access: cgroup files are world-readable, so this runs as an
# unprivileged user on the server.
#
#   sh stats-cgroup.sh <out.csv> [interval_seconds]
#
# Columns: unix_ts,container,role,cpu_usec,mem_current_mib,mem_peak_mib,oom_kill
#   role       guessed from the container's processes: n8n-main, task-runner, postgres, fixtures, sizer, other
#              (another Postgres on the server also reads as postgres: filter by container id, see analyze.mjs)
#   cpu_usec   cumulative CPU time; CPU% = delta(cpu_usec) / delta(ts) / 1e4
#   mem_peak   kernel high-water mark since the container started (memory.peak)
#   oom_kill   OOM kills inside the container so far (memory.events)
#   A "host" row per sample carries the whole box: MemTotal - MemAvailable, in mem_current_mib.
out=${1:?usage: stats-cgroup.sh <out.csv> [interval]}
interval=${2:-1}
[ -s "$out" ] || echo "unix_ts,container,role,cpu_usec,mem_current_mib,mem_peak_mib,oom_kill" >"$out"

role_of() {
  for p in $(cat "$1/cgroup.procs" 2>/dev/null); do
    cmd=$(tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null)
    case "$cmd" in
      *task-runner*|*runners*) echo task-runner; return ;;
      *"fixtures ready"*) echo fixtures; return ;;
      *readdirSync*) echo sizer; return ;;
      *bin/n8n*|*n8n\ start*|*/n8n\ *) echo n8n-main; return ;;
      postgres*|*bin/postgres*) echo postgres; return ;;
    esac
  done
  echo other
}

while :; do
  ts=$(date +%s)
  for d in /sys/fs/cgroup/system.slice/docker-*.scope; do
    [ -d "$d" ] || continue
    id=$(basename "$d" .scope); id=${id#docker-}; id=$(echo "$id" | cut -c1-12)
    role=$(role_of "$d")
    cpu=$(awk '/^usage_usec/{print $2}' "$d/cpu.stat" 2>/dev/null)
    cur=$(awk '{printf "%.1f", $1/1048576}' "$d/memory.current" 2>/dev/null)
    peak=$(awk '{printf "%.1f", $1/1048576}' "$d/memory.peak" 2>/dev/null)
    oom=$(awk '/^oom_kill /{print $2}' "$d/memory.events" 2>/dev/null)
    echo "$ts,$id,$role,${cpu:-},${cur:-},${peak:-},${oom:-0}"
  done >>"$out"
  # whole-box memory in use (MemTotal - MemAvailable), as role "host"
  awk -v ts="$ts" '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{printf "%s,host,host,,%.1f,,0\n", ts, (t-a)/1024}' /proc/meminfo >>"$out"
  sleep "$interval"
done
