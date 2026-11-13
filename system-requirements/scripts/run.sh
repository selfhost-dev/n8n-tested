#!/usr/bin/env bash
# One measured run: samples container cgroup stats on the n8n host while k6 drives
# load from this machine, then writes everything to results/<label>/.
#
# The stack publishes its ports on the server's loopback only, so reach it through
# an SSH tunnel and point BASE_URL at localhost:
#
#   ssh -N -L 5678:127.0.0.1:5678 -L 18081:127.0.0.1:18081 user@server &
#   N8N_SSH=user@server SSH_KEY=~/.ssh/key BASE_URL=http://localhost:5678 \
#     scripts/run.sh <label> <wf> [k6 -e args...]
#
#   e.g. scripts/run.sh cpx42-sqlite-w2-vus5 w2 -e MODE=vus -e VUS=5 -e ITERATIONS=50
#   wf "idle" runs no load: it only samples for IDLE_BEFORE seconds.
#   label: letters, digits, dot, dash and underscore only.
#
# Env: IDLE_BEFORE / IDLE_AFTER seconds of sampling around the load (default 30/30).
#      SIZER_URL (default http://<BASE_URL host>:18081/) to record data-volume bytes before/after.
#
# Results are meant to be shareable: meta.txt does not record BASE_URL, k6_args keeps
# only the known load settings, and IPv4 addresses in k6.txt become <ip>.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
label=${1:?label}; wf=${2:?workflow (w1..w5|idle)}; shift 2
[[ $label =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]*$ ]] || { echo "bad label: use letters, digits, . _ - only" >&2; exit 2; }
[[ $wf =~ ^(w[1-5]|idle)$ ]] || { echo "bad workflow: w1..w5 or idle" >&2; exit 2; }
out="$here/results/$label"; mkdir -p "$out"
base=${BASE_URL:?BASE_URL=http://localhost:5678}
host=${base#*://}; host=${host%%[:/]*}
sizer=${SIZER_URL:-http://$host:18081/}
remote=${N8N_SSH:?N8N_SSH=user@host}
ssh_opts=(-o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes); [[ -n ${SSH_KEY:-} ]] && ssh_opts+=(-i "$SSH_KEY")
# Cloud IPs get reused: keep bench host keys out of ~/.ssh/known_hosts (KNOWN_HOSTS, default next to the key).
# accept-new trusts a new server's key on first connect; check it against your provider's console if that matters.
ssh_opts+=(-o UserKnownHostsFile="${KNOWN_HOSTS:-${SSH_KEY:-$HOME/.ssh/bench}.known_hosts}")
rsh() { ssh "${ssh_opts[@]}" "$remote" "$@"; }

# A private directory on the server for the sampler, its CSV and its pid.
rdir=$(rsh 'mktemp -d /tmp/bench.XXXXXXXX')
[[ $rdir =~ ^/tmp/bench\.[A-Za-z0-9]+$ ]] || { echo "unexpected remote dir: $rdir" >&2; exit 1; }
scp -q "${ssh_opts[@]}" "$here/scripts/stats-cgroup.sh" "$remote:$rdir/stats-cgroup.sh"
rsh "nohup sh $rdir/stats-cgroup.sh $rdir/stats.csv 1 >/dev/null 2>&1 & echo \$! > $rdir/pid"
stopped=0
stop_stats() {
  [[ $stopped == 1 ]] && return; stopped=1
  rsh "kill \$(cat $rdir/pid) 2>/dev/null; true"
  scp -q "${ssh_opts[@]}" "$remote:$rdir/stats.csv" "$out/stats.csv" || true
  rsh "rm -rf $rdir" || true
}
trap stop_stats EXIT

# Record only known load settings from the k6 args; anything else is redacted.
recorded=()
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [[ ${args[i]} == -e && $((i + 1)) -lt ${#args[@]} ]]; then
    kv=${args[i + 1]}; key=${kv%%=*}; i=$((i + 1))
    case $key in
      MODE|RATE|VUS|ITERATIONS|DURATION|TIMEOUT|MAX_DURATION|PRE_VUS|MAX_VUS) recorded+=(-e "$kv") ;;
      *) recorded+=(-e "$key=<redacted>") ;;
    esac
  else
    recorded+=("<redacted>")
  fi
done

{
  echo "label=$label"; echo "workflow=$wf"
  echo "started_utc=$(date -u +%FT%TZ)"; echo "k6_args=${recorded[*]:-}"
} >"$out/meta.txt"
curl -s -m 20 "$sizer" >"$out/volumes-before.json" || true

sleep "${IDLE_BEFORE:-30}"
echo "load_start=$(date +%s)" >>"$out/meta.txt"
if [[ $wf != idle ]]; then
  TZ=UTC k6 run --quiet -e BASE_URL="$base" -e WF="$wf" "$@" \
    --summary-export "$out/k6-summary.json" "$here/scripts/load.js" >"$out/k6.txt" 2>&1 || true
  # k6 logs the target URL on failed requests, and on resets this machine's address too.
  perl -pi -e 's/\b(?!127\.0\.0\.1\b)(?:\d{1,3}\.){3}\d{1,3}\b/<ip>/g' "$out/k6.txt"
fi
echo "load_end=$(date +%s)" >>"$out/meta.txt"
sleep "${IDLE_AFTER:-30}"
stop_stats; trap - EXIT
curl -s -m 20 "$sizer" >"$out/volumes-after.json" || true
echo "ended_utc=$(date -u +%FT%TZ)" >>"$out/meta.txt"

bun "$here/scripts/analyze.mjs" "$out" | tee "$out/summary.txt"
