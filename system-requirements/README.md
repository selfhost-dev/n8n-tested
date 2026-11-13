# n8n system requirements: test kit

The files behind the "n8n system requirements, measured" post: the stack, the test
workflows, the load and sampling scripts, and every raw result. They measure the RAM,
CPU and disk n8n 2.40.7 uses. The n8n and task runner settings mirror the Selfhost.dev
n8n one-click template.

All the numbers are in [`results/numbers.csv`](results/numbers.csv), one row per run.
Each `results/<run>/` folder holds what that run produced:

| File | What |
|---|---|
| `summary.txt` | Idle and peak memory, CPU, OOM kills and restarts per container, the k6 numbers and data-volume growth |
| `stats.csv` | Per-second cgroup samples for every container, plus a `host` row for the whole server |
| `k6.txt`, `k6-summary.json` | The k6 output |
| `meta.txt` | The workflow, the k6 arguments and when the load started and ended |
| `volumes-before.json`, `volumes-after.json` | Data-volume sizes from the `sizer` service |

`results/_scenarios/bench-*.yml` are the exact compose files each scenario deployed.
Run names start with the Hetzner server type they ran on: cpx22 (2 vCPU, 4 GB),
cpx32 (4 vCPU, 8 GB) and cpx42 (8 vCPU, 16 GB).

## Layout

| Path | What |
|---|---|
| `compose/docker-compose.yml` | n8n main, the task runner, a `fixtures` server for the test payloads and a `sizer` that reports data-volume sizes. Knobs: `N8N_MEM_LIMIT`, `N8N_CPUS`, `RUNNER_MEM_LIMIT`, `RUNNER_CPUS`, `N8N_DEFAULT_BINARY_DATA_MODE`, `EXECUTIONS_DATA_SAVE_ON_SUCCESS`, `N8N_NODE_OPTIONS`, host ports. |
| `compose/docker-compose.postgres.yml` | Override that runs n8n on Postgres 16. |
| `compose/fixtures-only.yml` | The fixtures server alone, to run next to an existing n8n. |
| `workflows/build.mjs` | Generates the `w1`–`w5` JSON (`bun workflows/build.mjs`; env `FIXTURES_URL`, `OUT_DIR`, `W5_MODEL`). |
| `scripts/render.mjs` | Renders the compose with concrete values (`DB=postgres` adds Postgres). |
| `scripts/setup-http.sh` | Sets up a fresh n8n over HTTP: owner account, W5 credential, workflows, publish. |
| `scripts/run.sh` | One measured run: starts the cgroup sampler on the server over SSH, runs k6 from your machine, writes `results/<label>/`. |
| `scripts/stats-cgroup.sh` | Per-container cgroup v2 sampler. Needs no docker access. |
| `scripts/analyze.mjs` | Summarizes one run folder (`--json` too). |
| `scripts/load.js` | k6 script: `MODE=rate` (RATE, DURATION) or `MODE=vus` (VUS, ITERATIONS). |
| `scripts/import.sh`, `scripts/stats.sh` | Local variants that use `docker exec` and `docker stats`. |

## Workflows

| | Shape | Stresses |
|---|---|---|
| W1 light | Webhook → HTTP (1 KB JSON) → Set | a typical glue workflow |
| W2 code | Webhook → Code (10,000 × 1 KB items) → Code → Code | the task runner |
| W3 big JSON | Webhook → HTTP (20 MB JSON) → Set | n8n main memory |
| W4 binary | Webhook → HTTP (50 MB file) → NoOp → NoOp → Set | binary data handling |
| W5 AI agent | Webhook → AI Agent with an OpenAI-compatible chat model | an agent waiting on a cloud model |

Every webhook is `POST /webhook/w1` to `w5` and answers with a small summary, so the
load generator never downloads the payload. W5 needs `W5_API_KEY` (and `W5_BASE_URL`,
default OpenRouter). The post used OpenRouter's free `nvidia/nemotron-3.5-lightning:free`.

## Run it locally

Needs Docker, [bun](https://bun.sh), [k6](https://k6.io), `jq` and `curl`.

```sh
cd system-requirements
bun workflows/build.mjs
bun scripts/render.mjs > /tmp/bench.yml          # N8N_MEM_LIMIT=1g DB=postgres ... to vary
docker compose -p n8nbench -f /tmp/bench.yml up -d
BASE_URL=http://localhost:5678 N8N_OWNER_PASSWORD='Choose-a-password-1' scripts/setup-http.sh
k6 run -e BASE_URL=http://localhost:5678 -e WF=w1 -e MODE=rate -e RATE=5 -e DURATION=1m scripts/load.js
```

To measure on a server like the post did, deploy the rendered compose there and use
`scripts/run.sh` from another machine. It needs SSH access to the server
(`N8N_SSH=user@host`, `SSH_KEY`), and the `sizer` port reachable for volume sizes.

## Things that tripped us up

- **Binary data mode.** n8n 2.x uses `filesystem` when `N8N_DEFAULT_BINARY_DATA_MODE` is
  unset. This kit's compose sets in-memory `default` instead, for the early runs. Pass
  `filesystem` to match a stock install.
- **Retained memory.** n8n keeps heap between runs, so measure each workload on a fresh instance.
- **Publishing.** `POST /rest/workflows/:id/activate {versionId}` publishes a workflow. Give
  webhooks a second to register. Re-importing a workflow with the same id does not change
  the published version.
- **File nodes.** n8n 2.x limits them to `~/.n8n-files`, which the image does not create
  (`ENOENT … realpath '/home/node/.n8n-files'`). W4 avoids disk writes for this reason.
- **Database service name.** On a docker network shared with other stacks, name the
  database uniquely (`n8nbench-db`). A bare `postgres` can resolve to someone else's.
- **SSH with several keys.** Pass `IdentitiesOnly=yes` (run.sh does), or the agent offers
  every key and the server answers "Too many authentication failures".
- **Free model limits.** OpenRouter's free tier allows about 20 requests a minute and
  50 a day without credits.
- **Laptop sleep** pauses the load generator. Run long series under `caffeinate` on macOS.
