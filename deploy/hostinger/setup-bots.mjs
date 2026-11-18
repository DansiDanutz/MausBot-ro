#!/usr/bin/env node
// Runs inside the server container, next to the `openmausbot` CLI: one bot for
// every engine that is ready, and a room with all of them. Safe to run again:
// it matches bots by name and leaves existing ones alone. `--bots-only` in
// install.sh calls it after engine keys or CLI sign-ins change.
import { execFileSync } from "node:child_process";

const CLI = process.env.OMB_CLI || "openmausbot";

const LABELS = {
  claude: ["Claude", "Claude Code"],
  codex: ["Codex", "Codex"],
  grok: ["Grok", "Grok Build"],
  openai: ["OpenAI", "OpenAI API"],
  xai: ["Grok API", "xAI API"],
  openrouter: ["OpenRouter", "OpenRouter"],
  "openai-compat": ["Custom", "OpenAI-compatible endpoint"],
  groq: ["Groq", "Groq"],
  mistral: ["Mistral", "Mistral"],
  cerebras: ["Cerebras", "Cerebras"],
  greenference: ["Greenference", "Greenference"],
  modelgo: ["ModelGo", "ModelGo"],
};

function cli(args) {
  return execFileSync(CLI, [...args, "--json"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    timeout: 120_000,
  });
}

function json(args) {
  const out = cli(args).trim();
  const start = out.indexOf("{");
  if (start < 0) throw new Error(`${args[0]} printed no JSON`);
  return JSON.parse(out.slice(start));
}

function label(instanceId) {
  return LABELS[instanceId]?.[0] ?? instanceId;
}

function title(instanceId) {
  return LABELS[instanceId]?.[1] ?? instanceId;
}

function defaultModel(instance) {
  if (typeof instance.models?.default === "string" && instance.models.default) return instance.models.default;
  const first = instance.models?.options?.[0];
  if (typeof first?.id === "string" && first.id) return first.id;
  return undefined;
}

let models;
let bots;
try {
  models = json(["models"]);
  bots = json(["bots"]);
} catch (error) {
  console.error(`Could not read the server: ${error instanceof Error ? error.message : String(error)}`);
  console.error("Is the server healthy? cd /opt/openmausbot && docker compose ps");
  process.exit(1);
}

const byName = new Map((bots.bots ?? []).map((bot) => [String(bot.name).toLowerCase(), String(bot.name)]));
const ready = (models.instances ?? []).filter((instance) => instance.snapshot?.state === "available");
const made = [];
const skipped = [];

for (const instance of ready) {
  const instanceId = String(instance.instanceId ?? "");
  const model = defaultModel(instance);
  if (!instanceId || !model) continue;
  const name = label(instanceId);
  if (byName.has(name.toLowerCase())) {
    skipped.push(`${name} (already there)`);
    continue;
  }
  try {
    cli(["new-bot", name, "--title", title(instanceId), "--model", `${instanceId}/${model}`]);
    byName.set(name.toLowerCase(), name);
    made.push(`${name} → ${instanceId}/${model}`);
  } catch (error) {
    const detail = error?.stderr?.toString().trim() || error?.message || String(error);
    skipped.push(`${name} (${detail.split("\n")[0]})`);
  }
}

if (!ready.length) {
  console.log("No engine is ready yet, so there are no bots:");
  console.log("  cd /opt/openmausbot");
  console.log("  docker compose exec omb claude          # or: codex login, grok");
  console.log("  docker compose exec omb openmausbot engine set claude --key-env ANTHROPIC_API_KEY --install");
  console.log("Then run: sudo sh install.sh --bots-only");
}

for (const line of made) console.log(`  created  ${line}`);
for (const line of skipped) console.log(`  kept     ${line}`);

const names = [...byName.values()];
if (names.length >= 2) {
  try {
    const channels = json(["channels"]);
    const hasRoom = (channels.channels ?? []).some((room) => String(room.name).toLowerCase() === "all bots");
    if (!hasRoom) {
      cli(["new-channel", "All Bots", "--members", names.join(",")]);
      console.log("  created  room \"All Bots\"");
    }
  } catch (error) {
    console.log(`  warn     the "All Bots" room was not made: ${error?.message ?? error}`);
  }
}

console.log(`Bots ready: ${names.length}${made.length ? `, ${made.length} new` : ""}`);
