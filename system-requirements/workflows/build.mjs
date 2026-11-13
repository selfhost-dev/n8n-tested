// Generates the test workflows (w1..w5 JSON) for n8n 2.40.7.
// Node type versions were read from `n8n export:nodes` on n8nio/n8n:2.40.7.
// Every workflow starts with a Webhook (POST /webhook/<path>) and answers with
// a small summary item, so the load generator never downloads the payload.
//
//   bun workflows/build.mjs            # writes w1-light.json ... w5-ai-agent.json
//
// FIXTURES_URL defaults to the compose `fixtures` service; OUT_DIR overrides the output folder.
import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const FIXTURES = process.env.FIXTURES_URL ?? "http://fixtures:8080";
const W2_ITEMS = Number(process.env.W2_ITEMS ?? 10000);

const webhook = (path) => ({
  name: "Webhook",
  type: "n8n-nodes-base.webhook",
  typeVersion: 2.1,
  webhookId: `bench-${path}`,
  parameters: { httpMethod: "POST", path, responseMode: "lastNode", options: {} },
});

const http = (name, url, asFile = false) => ({
  name,
  type: "n8n-nodes-base.httpRequest",
  typeVersion: 4.2,
  parameters: {
    url,
    options: asFile ? { response: { response: { responseFormat: "file" } } } : {},
  },
});

const code = (name, jsCode) => ({
  name,
  type: "n8n-nodes-base.code",
  typeVersion: 2,
  parameters: { jsCode },
});

const set = (name, fields) => ({
  name,
  type: "n8n-nodes-base.set",
  typeVersion: 3.4,
  parameters: {
    mode: "manual",
    assignments: {
      assignments: fields.map(([n, value, type], i) => ({ id: `f${i}`, name: n, value, type })),
    },
    options: {},
  },
});

// Chains nodes left to right, assigns ids/positions, wires main connections.
function workflow(id, name, nodes) {
  const placed = nodes.map((n, i) => ({ id: `${id}-n${i}`, position: [i * 240, 0], ...n }));
  const connections = {};
  for (let i = 0; i < placed.length - 1; i++) {
    connections[placed[i].name] = { main: [[{ node: placed[i + 1].name, type: "main", index: 0 }]] };
  }
  return { id, name, active: false, nodes: placed, connections, settings: { executionOrder: "v1" }, pinData: {} };
}

const workflows = {
  // W1: typical glue workflow.
  "w1-light": workflow("benchW1Light0001", "W1 light", [
    webhook("w1"),
    http("Fetch small JSON", `${FIXTURES}/small.json`),
    set("Shape", [["ok", true, "boolean"], ["name", "={{ $json.name }}", "string"]]),
  ]),

  // W2: Code nodes over W2_ITEMS items of ~1 KB each (runs in the task runner).
  "w2-code": workflow("benchW2Code00001", "W2 code", [
    webhook("w2"),
    code(
      "Generate items",
      `const n = ${W2_ITEMS};\nconst pad = 'z'.repeat(1000);\nreturn Array.from({ length: n }, (_, i) => ({ json: { id: i, pad } }));`,
    ),
    code(
      "Transform",
      "return $input.all().map(({ json }) => ({ json: { id: json.id, len: json.pad.length, hash: (json.id * 2654435761) % 4294967296 } }));",
    ),
    code(
      "Summarize",
      "const all = $input.all();\nreturn [{ json: { items: all.length, totalLen: all.reduce((s, i) => s + i.json.len, 0) } }];",
    ),
  ]),

  // W3: one large JSON response (FIXTURE_JSON_MB, default 20 MB).
  "w3-big-json": workflow("benchW3BigJson01", "W3 big JSON", [
    webhook("w3"),
    http("Fetch big JSON", `${FIXTURES}/big.json`),
    set("Summarize", [["items", "={{ $json.items.length }}", "number"]]),
  ]),

  // W4: download a binary file (FIXTURE_FILE_MB, default 50 MB) and pass it
  // through two nodes. No disk write: n8n 2.x limits file nodes to ~/.n8n-files,
  // which the template image does not create (ENOENT, then EACCES on a volume).
  "w4-binary": workflow("benchW4Binary001", "W4 binary", [
    webhook("w4"),
    http("Download file", `${FIXTURES}/file.bin`, true),
    { name: "Pass 1", type: "n8n-nodes-base.noOp", typeVersion: 1, parameters: {} },
    { name: "Pass 2", type: "n8n-nodes-base.noOp", typeVersion: 1, parameters: {} },
    set("Summarize", [["bytes", "={{ $binary.data.fileSize }}", "string"]]),
  ]),

  // W5: AI Agent with a cloud model through an OpenAI-compatible API (default:
  // OpenRouter's free nvidia/nemotron-3.5-lightning). Needs an openAiApi credential
  // "bench-openai" (setup-http.sh creates it from W5_API_KEY + W5_BASE_URL); the
  // model runs elsewhere, this measures n8n.
  "w5-ai-agent": (() => {
    const wf = workflow("benchW5Agent0001", "W5 AI agent", [
      webhook("w5"),
      {
        name: "AI Agent",
        type: "@n8n/n8n-nodes-langchain.agent",
        typeVersion: 2.2,
        parameters: {
          promptType: "define",
          text: "Summarize in one sentence: n8n is a workflow automation tool that connects apps and runs code.",
          options: {},
        },
      },
    ]);
    wf.nodes.push({
      id: "benchW5Agent0001-model",
      name: "Chat model",
      type: "@n8n/n8n-nodes-langchain.lmChatOpenAi",
      typeVersion: 1.2,
      position: [240, 200],
      parameters: {
        model: { __rl: true, mode: "id", value: process.env.W5_MODEL ?? "nvidia/nemotron-3.5-lightning:free" },
        options: { maxTokens: 800 },
      },
      credentials: { openAiApi: { id: "benchOpenAi00001", name: "bench-openai" } },
    });
    wf.connections["Chat model"] = { ai_languageModel: [[{ node: "AI Agent", type: "ai_languageModel", index: 0 }]] };
    return wf;
  })(),
};

for (const [file, wf] of Object.entries(workflows)) {
  writeFileSync(join(process.env.OUT_DIR ?? here, `${file}.json`), JSON.stringify(wf, null, 2) + "\n");
  console.log(`wrote ${file}.json`);
}
