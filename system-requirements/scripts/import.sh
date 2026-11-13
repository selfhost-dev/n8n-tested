#!/usr/bin/env bash
# Imports and publishes the test workflows into the running n8n container.
#
#   scripts/import.sh [container] [w1-light w2-code ...]
#
# W5 is skipped unless named, since it needs the "bench-openai" credential first.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
container=${1:-$(docker ps --format '{{.Names}}' | grep -E '(^|[-_])n8n([-_][0-9a-z]+)?$' | grep -v runner | head -1)}
shift || true
names=("$@")
[[ ${#names[@]} -gt 0 ]] || names=(w1-light w2-code w3-big-json w4-binary)

for n in "${names[@]}"; do
  f="$here/workflows/$n.json"
  id=$(jq -r .id "$f")
  docker cp "$f" "$container:/tmp/$n.json"
  docker exec "$container" n8n import:workflow --input="/tmp/$n.json" >/dev/null
  docker exec "$container" n8n publish:workflow --id="$id" >/dev/null
  echo "imported + published $n ($id)"
done
echo "restart n8n so published webhooks register: docker restart $container"
