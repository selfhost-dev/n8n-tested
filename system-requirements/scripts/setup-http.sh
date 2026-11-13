#!/usr/bin/env bash
# Sets up a FRESH n8n over HTTP only (no docker access needed): creates the
# owner account, then creates and publishes the test workflows.
#
#   read -rs N8N_OWNER_PASSWORD; export N8N_OWNER_PASSWORD
#   BASE_URL=http://localhost:5678 scripts/setup-http.sh [w1-light w2-code ...]
#
# N8N_OWNER_PASSWORD is the password for the new owner account (n8n wants 8+ chars,
# a number and an uppercase letter). N8N_OWNER_EMAIL defaults to bench@example.com.
#
# The password, the session cookie and W5_API_KEY travel to BASE_URL. Plain http is
# accepted only for localhost (use an SSH tunnel to a server); set
# ALLOW_INSECURE_HTTP=1 to override.
#
# Uses n8n's internal REST API as the editor UI does (n8n 2.40.7):
#   POST /rest/owner/setup, POST /rest/workflows, POST /rest/workflows/:id/activate {versionId}
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
base=${BASE_URL:-http://localhost:5678}
case $base in
  https://*|http://localhost|http://localhost[:/]*|http://127.0.0.1|http://127.0.0.1[:/]*) ;;
  *) [[ ${ALLOW_INSECURE_HTTP:-} == 1 ]] || {
       echo "refusing plain http to $base: tunnel it (ssh -L 5678:127.0.0.1:5678 ...) or set ALLOW_INSECURE_HTTP=1" >&2; exit 2; } ;;
esac
jar=$(mktemp)
trap 'rm -f "$jar"' EXIT
email=${N8N_OWNER_EMAIL:-bench@example.com}
password=${N8N_OWNER_PASSWORD:?set N8N_OWNER_PASSWORD}
names=("$@")
[[ ${#names[@]} -gt 0 ]] || names=(w1-light w2-code w3-big-json w4-binary)
for n in "${names[@]}"; do
  [[ $n =~ ^[A-Za-z0-9_-]+$ ]] || { echo "bad workflow name: $n" >&2; exit 2; }
done

for _ in $(seq 1 150); do curl -sf "$base/healthz/readiness" >/dev/null && break; sleep 2; done
curl -sf "$base/healthz/readiness" >/dev/null || { echo "n8n not ready at $base" >&2; exit 1; }

# Bodies with secrets go on stdin, so they never appear in curl's command line.
post() { curl "$@" -H 'content-type: application/json' --data-binary @-; }

code=$(jq -n --arg e "$email" --arg p "$password" '{email:$e, firstName:"Bench", lastName:"Runner", password:$p}' |
  post -s -o /dev/null -w '%{http_code}' -c "$jar" -X POST "$base/rest/owner/setup")
if [[ $code != 200 ]]; then # owner exists already: log in instead
  jq -n --arg e "$email" --arg p "$password" '{emailOrLdapLoginId:$e, password:$p}' |
    post -sf -o /dev/null -c "$jar" -X POST "$base/rest/login"
fi

# W5 needs a chat-model credential: created from W5_API_KEY (+ W5_BASE_URL, default
# OpenRouter) and wired into the workflow by id. The key goes only to this n8n.
cred_id=""
if [[ " ${names[*]} " == *" w5-ai-agent "* ]]; then
  : "${W5_API_KEY:?W5 needs W5_API_KEY}"
  cred_id=$(jq -n --arg k "$W5_API_KEY" --arg u "${W5_BASE_URL:-https://openrouter.ai/api/v1}" \
    '{name:"bench-openai", type:"openAiApi", data:{apiKey:$k, url:$u}}' |
    post -sf -b "$jar" -X POST "$base/rest/credentials" | jq -r .data.id)
  [[ -n $cred_id && $cred_id != null ]] || { echo "credential create failed" >&2; exit 1; }
  echo "created credential bench-openai ($cred_id)"
fi

for n in "${names[@]}"; do
  created=$(jq --arg c "$cred_id" 'del(.id, .active, .pinData)
    | if $c != "" then .nodes |= map(if .credentials.openAiApi then .credentials.openAiApi.id = $c else . end) else . end' \
    "${WORKFLOW_DIR:-$here/workflows}/$n.json" | post -sf -b "$jar" -X POST "$base/rest/workflows")
  id=$(jq -r .data.id <<<"$created"); ver=$(jq -r .data.versionId <<<"$created")
  [[ $id =~ ^[A-Za-z0-9]+$ ]] || { echo "unexpected workflow id for $n" >&2; exit 1; }
  jq -n --arg v "$ver" '{versionId:$v}' | post -sf -o /dev/null -b "$jar" -X POST "$base/rest/workflows/$id/activate"
  echo "created + published $n ($id)"
done
