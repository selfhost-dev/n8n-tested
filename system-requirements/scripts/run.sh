#!/usr/bin/env bash
# One measured run: samples container cgroup stats on the n8n host while k6 drives
# load from this machine, then writes everything to results/<label>/.
#
#   N8N_SSH=user@1.2.3.4 SSH_KEY=~/.ssh/key BASE_URL=http://1.2.3.4:5678 \
#     scripts/run.sh <label> <wf> [k6 -e args...]
#
#   e.g. scripts/run.sh cpx42-sqlite-w2-vus5 w2 -e MODE=vus -e VUS=5 -e ITERATIONS=50
#   wf "idle" runs no load: it only samples for IDLE_BEFORE seconds.
#
# Env: IDLE_BEFORE / IDLE_AFTER seconds of sampling around the load (default 30/30).
#      SIZER_URL (default http://<host>:18081/) to record data-volume bytes before/after.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
label=${1:?label}; wf=${2:?workflow (w1..w5|idle)}; shift 2
out="$here/results/$label"; mkdir -p "$out"
base=${BASE_URL:?BASE_URL=http://host:5678}
host=${base#http://}; host=${host%%:*}
sizer=${SIZER_URL:-http://$host:18081/}
remote=${N8N_SSH:?N8N_SSH=user@host}
ssh_opts=(-o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes); [[ -n ${SSH_KEY:-} ]] && ssh_opts+=(-i "$SSH_KEY")
# Cloud IPs get reused: keep bench host keys out of ~/.ssh/known_hosts (KNOWN_HOSTS, default next to the key).
ssh_opts+=(-o UserKnownHostsFile="${KNOWN_HOSTS:-${SSH_KEY:-$HOME/.ssh/bench}.known_hosts}")
rsh() { ssh "${ssh_opts[@]}" "$remote" "$@"; }

scp -q "${ssh_opts[@]}" "$here/scripts/stats-cgroup.sh" "$remote:/tmp/stats-cgroup.sh"
rsh "rm -f /tmp/bench-$label.csv; nohup sh /tmp/stats-cgroup.sh /tmp/bench-$label.csv 1 >/dev/null 2>&1 & echo \$! > /tmp/bench-$label.pid"
stop_stats() {
  rsh "kill \$(cat /tmp/bench-$label.pid) 2>/dev/null; true"
  scp -q "${ssh_opts[@]}" "$remote:/tmp/bench-$label.csv" "$out/stats.csv"
}
trap stop_stats EXIT

{
  echo "label=$label"; echo "workflow=$wf"; echo "base_url=$base"
  echo "started_utc=$(date -u +%FT%TZ)"; echo "k6_args=$*"
} >"$out/meta.txt"
curl -s -m 20 "$sizer" >"$out/volumes-before.json" || true

sleep "${IDLE_BEFORE:-30}"
echo "load_start=$(date +%s)" >>"$out/meta.txt"
if [[ $wf != idle ]]; then
  k6 run --quiet -e BASE_URL="$base" -e WF="$wf" "$@" \
    --summary-export "$out/k6-summary.json" "$here/scripts/load.js" >"$out/k6.txt" 2>&1 || true
fi
echo "load_end=$(date +%s)" >>"$out/meta.txt"
sleep "${IDLE_AFTER:-30}"
stop_stats; trap - EXIT
curl -s -m 20 "$sizer" >"$out/volumes-after.json" || true
echo "ended_utc=$(date -u +%FT%TZ)" >>"$out/meta.txt"

bun "$here/scripts/analyze.mjs" "$out" | tee "$out/summary.txt"
