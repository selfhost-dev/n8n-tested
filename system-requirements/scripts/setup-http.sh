#!/usr/bin/env bash
# Sets up a FRESH n8n over HTTP only (no docker access needed): creates the
# owner account, then creates and publishes the test workflows.
#
#   BASE_URL=http://HOST:5678 N8N_OWNER_PASSWORD=... scripts/setup-http.sh [w1-light w2-code ...]
#
# N8N_OWNER_PASSWORD is the password for the new owner account (n8n wants 8+ chars,
# a number and an uppercase letter). N8N_OWNER_EMAIL defaults to bench@example.com.
#
# Uses n8n's internal REST API as the editor UI does (n8n 2.40.7):
#   POST /rest/owner/setup, POST /rest/workflows, POST /rest/workflows/:id/activate {versionId}
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
base=${BASE_URL:-http://localhost:5678}
jar=$(mktemp)
trap 'rm -f "$jar"' EXIT
email=${N8N_OWNER_EMAIL:-bench@example.com}
password=${N8N_OWNER_PASSWORD:?set N8N_OWNER_PASSWORD}
names=("$@")
[[ ${#names[@]} -gt 0 ]] || names=(w1-light w2-code w3-big-json w4-binary)

for i in $(seq 1 150); do curl -sf "$base/healthz/readiness" >/dev/null && break; sleep 2; done
curl -sf "$base/healthz/readiness" >/dev/null || { echo "n8n not ready at $base" >&2; exit 1; }

owner=$(jq -n --arg e "$email" --arg p "$password" '{email:$e, firstName:"Bench", lastName:"Runner", password:$p}')
code=$(curl -s -o /dev/null -w '%{http_code}' -c "$jar" -X POST "$base/rest/owner/setup" -H 'content-type: application/json' -d "$owner")
if [[ $code != 200 ]]; then # owner exists already: log in instead
  curl -sf -o /dev/null -c "$jar" -X POST "$base/rest/login" -H 'content-type: application/json' \
    -d "$(jq -n --arg e "$email" --arg p "$password" '{emailOrLdapLoginId:$e, password:$p}')"
fi

# W5 needs a chat-model credential: created from W5_API_KEY (+ W5_BASE_URL, default
# OpenRouter) and wired into the workflow by id. The key goes only to this n8n.
cred_id=""
if [[ " ${names[*]} " == *" w5-ai-agent "* ]]; then
  : "${W5_API_KEY:?W5 needs W5_API_KEY}"
  cred=$(jq -n --arg k "$W5_API_KEY" --arg u "${W5_BASE_URL:-https://openrouter.ai/api/v1}" \
    '{name:"bench-openai", type:"openAiApi", data:{apiKey:$k, url:$u}}')
  cred_id=$(curl -sf -b "$jar" -X POST "$base/rest/credentials" -H 'content-type: application/json' -d "$cred" | jq -r .data.id)
  [[ -n $cred_id && $cred_id != null ]] || { echo "credential create failed" >&2; exit 1; }
  echo "created credential bench-openai ($cred_id)"
fi

for n in "${names[@]}"; do
  body=$(jq --arg c "$cred_id" 'del(.id, .active, .pinData)
    | if $c != "" then .nodes |= map(if .credentials.openAiApi then .credentials.openAiApi.id = $c else . end) else . end' \
    "${WORKFLOW_DIR:-$here/workflows}/$n.json")
  created=$(curl -sf -b "$jar" -X POST "$base/rest/workflows" -H 'content-type: application/json' -d "$body")
  id=$(jq -r .data.id <<<"$created"); ver=$(jq -r .data.versionId <<<"$created")
  curl -sf -o /dev/null -b "$jar" -X POST "$base/rest/workflows/$id/activate" \
    -H 'content-type: application/json' -d "{\"versionId\":\"$ver\"}"
  echo "created + published $n ($id)"
done
