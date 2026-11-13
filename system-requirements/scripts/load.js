// k6 load for one webhook workflow. Run from a machine other than the n8n server.
//
// Two modes:
//   rate  fixed arrival rate:  RATE=10 DURATION=3m        (requests per second)
//   vus   fixed parallelism:   VUS=5 ITERATIONS=50       (each VU runs ITERATIONS/VUS)
//
//   k6 run -e BASE_URL=http://host:5678 -e WF=w1 -e MODE=rate -e RATE=10 -e DURATION=3m \
//     --summary-export results/<label>/k6-summary.json scripts/load.js
import http from "k6/http";
import { check } from "k6";

const BASE = __ENV.BASE_URL || "http://localhost:5678";
const WF = __ENV.WF || "w1";
const MODE = __ENV.MODE || "rate";
const TIMEOUT = __ENV.TIMEOUT || "120s";

const scenario =
  MODE === "vus"
    ? {
        executor: "shared-iterations",
        vus: Number(__ENV.VUS || 1),
        iterations: Number(__ENV.ITERATIONS || 10),
        maxDuration: __ENV.MAX_DURATION || "30m",
      }
    : {
        executor: "constant-arrival-rate",
        rate: Number(__ENV.RATE || 5),
        timeUnit: "1s",
        duration: __ENV.DURATION || "3m",
        preAllocatedVUs: Number(__ENV.PRE_VUS || 50),
        maxVUs: Number(__ENV.MAX_VUS || 500),
      };

export const options = {
  scenarios: { load: scenario },
  summaryTrendStats: ["min", "med", "avg", "p(90)", "p(95)", "p(99)", "max"],
};

export default function () {
  const res = http.post(`${BASE}/webhook/${WF}`, "{}", {
    headers: { "content-type": "application/json" },
    timeout: TIMEOUT,
  });
  check(res, { "status 200": (r) => r.status === 200 });
}
