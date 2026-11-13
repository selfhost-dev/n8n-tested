// Renders the compose (plus the Postgres override when DB=postgres) into one
// concrete file: every ${VAR:-default} is replaced from the environment or its
// default, so the deployed compose holds exact values for each scenario.
//
// ${VAR:?message} must be set: rendering stops with the message otherwise.
//
//   N8N_MEM_LIMIT=1g DB=postgres bun scripts/render.mjs > bench.rendered.yml
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const dir = join(dirname(fileURLToPath(import.meta.url)), "..", "compose");
const fail = (msg) => { console.error(msg); process.exit(2); };
const sub = (text) =>
  text.replace(/\$\{([A-Z0-9_]+)(?::([-?])([^}]*))?\}/g, (_, name, op, arg = "") => {
    const value = process.env[name];
    if (value != null && /[\r\n]/.test(value)) fail(`${name} must not contain a newline`);
    if (op === "?" && !value) fail(`${name}: ${arg}`);
    return value ?? (op === "-" ? arg : "");
  });

let base = sub(readFileSync(join(dir, "docker-compose.yml"), "utf8"));

if (process.env.DB === "postgres") {
  // Merge by hand (no YAML dependency): append the Postgres env lines to the n8n
  // service, add its depends_on, and add the postgres service + volume.
  const pgEnv = [
    "DB_TYPE=postgresdb", "DB_POSTGRESDB_HOST=n8nbench-db", "DB_POSTGRESDB_PORT=5432",
    "DB_POSTGRESDB_DATABASE=n8n", "DB_POSTGRESDB_USER=n8n",
    "DB_POSTGRESDB_PASSWORD=test-only-password", "DB_POSTGRESDB_SCHEMA=public",
  ].map((l) => `      - ${l}`).join("\n");
  base = base.replace("      - N8N_DIAGNOSTICS_ENABLED=false", `${pgEnv}\n      - N8N_DIAGNOSTICS_ENABLED=false`);
  base = base.replace(
    "    volumes:\n      - n8n-data:/home/node/.n8n",
    "    depends_on:\n      n8nbench-db:\n        condition: service_healthy\n    volumes:\n      - n8n-data:/home/node/.n8n",
  );
  base = base.replace("      - n8n-data:/vol/n8n-data:ro", "      - n8n-data:/vol/n8n-data:ro\n      - pg-data:/vol/pg-data:ro");
  base = base.replace(
    "\nvolumes:\n  n8n-data:\n",
    `
  # Unique name: on a shared docker network a bare 'postgres' can resolve
  # to another stack's database.
  n8nbench-db:
    image: postgres:16-alpine
    environment:
      - POSTGRES_USER=n8n
      - POSTGRES_PASSWORD=test-only-password
      - POSTGRES_DB=n8n
    volumes:
      - pg-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U n8n -d n8n"]
      interval: 5s
      timeout: 5s
      retries: 20

volumes:
  n8n-data:
  pg-data:
`,
  );
}

// Unset limits render as the compose's "no limit" placeholders; drop them so the
// deployed file carries only limits a scenario actually sets.
base = base.replace(/^\s+(mem_limit|memswap_limit): 64g\n/gm, "").replace(/^\s+cpus: 0\n/gm, "");

// Drop header comments.
process.stdout.write(base.replace(/^#.*\n/gm, ""));
