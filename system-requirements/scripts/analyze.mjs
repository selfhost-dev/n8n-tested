// Summarizes one results/<label>/ directory: per container role, idle memory
// (mean before load), peak memory during the run, CPU, OOM kills; plus k6 numbers
// and data-volume growth. Containers listed in results/_scenarios/baseline-ids.txt
// (containers already on the server before the test stack) are excluded.
//
//   bun scripts/analyze.mjs results/<label> [--json]
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

const dir = process.argv[2];
const asJson = process.argv.includes("--json");
const root = join(dir, "..");
const meta = Object.fromEntries(
  readFileSync(join(dir, "meta.txt"), "utf8").trim().split("\n").map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1)]),
);
const start = Number(meta.load_start), end = Number(meta.load_end);
const baselineFile = join(root, "_scenarios", "baseline-ids.txt");
const baseline = new Set(existsSync(baselineFile) ? readFileSync(baselineFile, "utf8").split(/\s+/).filter(Boolean) : []);

const rows = readFileSync(join(dir, "stats.csv"), "utf8").trim().split("\n").slice(1)
  .map((l) => l.split(","))
  .map(([ts, id, role, cpu, cur, peak, oom]) => ({ ts: +ts, id, role, cpu: +cpu, cur: +cur, peak: +peak, oom: +oom }))
  .filter((r) => !baseline.has(r.id) && ["n8n-main", "task-runner", "postgres", "host"].includes(r.role));

const byRole = {};
for (const r of rows) (byRole[`${r.role}`] ??= []).push(r);

const summary = {};
for (const [role, rs] of Object.entries(byRole)) {
  rs.sort((a, b) => a.ts - b.ts);
  const idle = rs.filter((r) => r.ts < start);
  const load = rs.filter((r) => r.ts >= start && r.ts <= end);
  const cpuPct = [];
  let processRestarts = 0; // a crash inside the same container resets its cgroup CPU counter
  for (let i = 1; i < rs.length; i++) {
    const dt = rs[i].ts - rs[i - 1].ts;
    if (rs[i].id === rs[i - 1].id && rs[i].cpu < rs[i - 1].cpu) { processRestarts++; continue; }
    if (dt > 0 && rs[i].id === rs[i - 1].id && rs[i].ts >= start && rs[i].ts <= end) cpuPct.push((rs[i].cpu - rs[i - 1].cpu) / dt / 1e4);
  }
  const mean = (a) => (a.length ? a.reduce((s, x) => s + x, 0) / a.length : null);
  summary[role] = {
    idle_mib: mean(idle.map((r) => r.cur)),
    peak_sampled_mib: Math.max(...(load.length ? load : rs).map((r) => r.cur)),
    peak_lifetime_mib: role === "host" ? null : Math.max(...rs.map((r) => r.peak)),
    cpu_avg_pct: mean(cpuPct),
    cpu_max_pct: cpuPct.length ? Math.max(...cpuPct) : null,
    oom_kills: Math.max(...rs.map((r) => r.oom)),
    restarts_seen: new Set(rs.map((r) => r.id)).size - 1 + processRestarts,
  };
}

let k6 = null;
if (existsSync(join(dir, "k6-summary.json"))) {
  const m = JSON.parse(readFileSync(join(dir, "k6-summary.json"), "utf8")).metrics;
  const d = m.http_req_duration;
  k6 = {
    requests: m.http_reqs?.count, rps: m.http_reqs?.rate,
    failed_pct: (m.http_req_failed?.value ?? 0) * 100,
    p50_ms: d?.med, p95_ms: d?.["p(95)"], p99_ms: d?.["p(99)"], max_ms: d?.max,
  };
}

const vol = (f) => { try { return JSON.parse(readFileSync(join(dir, f), "utf8")); } catch { return null; } };
const before = vol("volumes-before.json"), after = vol("volumes-after.json");
const volumes = after && Object.fromEntries(Object.entries(after).map(([k, v]) => [k, { bytes: v.bytes, delta: v.bytes - (before?.[k]?.bytes ?? 0), files: v.files }]));

const result = { label: meta.label, workflow: meta.workflow, k6_args: meta.k6_args, containers: summary, k6, volumes };
if (asJson) { console.log(JSON.stringify(result, null, 2)); process.exit(0); }

const f = (x, d = 0) => (x == null || !isFinite(x) ? "-" : x.toFixed(d));
console.log(`${meta.label}  (${meta.workflow} ${meta.k6_args})`);
console.log("role          idle_MiB  peak_MiB  lifetime_peak  cpu_avg%  cpu_max%  oom  restarts");
for (const [role, s] of Object.entries(summary))
  console.log(`${role.padEnd(13)} ${f(s.idle_mib).padStart(8)}  ${f(s.peak_sampled_mib).padStart(8)}  ${f(s.peak_lifetime_mib).padStart(13)}  ${f(s.cpu_avg_pct).padStart(8)}  ${f(s.cpu_max_pct).padStart(8)}  ${String(s.oom_kills).padStart(3)}  ${s.restarts_seen}`);
if (k6) console.log(`k6: ${k6.requests} req, ${f(k6.rps, 2)}/s, failed ${f(k6.failed_pct, 1)}%, p50 ${f(k6.p50_ms)} ms, p95 ${f(k6.p95_ms)} ms, p99 ${f(k6.p99_ms)} ms`);
if (volumes) for (const [k, v] of Object.entries(volumes)) console.log(`volume ${k}: ${f(v.bytes / 1048576, 1)} MiB (delta ${f(v.delta / 1048576, 1)} MiB)`);
