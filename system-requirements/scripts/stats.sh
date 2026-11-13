#!/usr/bin/env bash
# Samples per-container CPU and memory into a CSV until killed. Read-only: it
# only calls `docker stats`.
#
#   scripts/stats.sh <out.csv> [filter-regex]      # e.g. 'n8n|task-runners|postgres'
#
# Columns: unix_ts,container,cpu_pct,mem_used_mib,mem_limit_mib,mem_pct
# Each `docker stats --no-stream` call takes ~1-2 s, which sets the sample interval.
set -euo pipefail
out=${1:?usage: stats.sh <out.csv> [filter-regex]}
filter=${2:-.}

to_mib() { # "512.3MiB" | "1.2GiB" | "800KiB" | "1.5GB" -> MiB
  awk -v v="$1" 'BEGIN{
    n=v; sub(/[A-Za-z]+$/,"",n); u=v; sub(/^[0-9.]+/,"",u);
    f=1; if(u~/^Ki|^kB|^KB/)f=1/1024; else if(u~/^Gi|^GB/)f=1024; else if(u~/^B$/)f=1/1048576;
    printf "%.1f", n*f }'
}

[[ -s $out ]] || echo "unix_ts,container,cpu_pct,mem_used_mib,mem_limit_mib,mem_pct" >"$out"
while true; do
  ts=$(date +%s)
  docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}' |
    grep -E "$filter" |
    while IFS='|' read -r name cpu mem memp; do
      used=${mem%% / *}; limit=${mem##* / }
      echo "$ts,$name,${cpu%\%},$(to_mib "$used"),$(to_mib "$limit"),${memp%\%}"
    done >>"$out"
done
