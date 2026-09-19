import { appendFileSync, readFileSync } from "node:fs";
import { spawn } from "node:child_process";
import { createServer } from "node:net";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { load as loadYaml } from "js-yaml";
import type { AddressInfo } from "node:net";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const directory = path.dirname(fileURLToPath(import.meta.url));
const fixtureDirectory = path.resolve(directory, "..");
const tapesDirectory = path.join(fixtureDirectory, "tapes");
const proxayBinary = path.join(fixtureDirectory, "node_modules/.bin/proxay");
const scenario = process.env.FIXTURE_SCENARIO || "hashline";
const mode = process.env.FIXTURE_MODE || "replay";
const upstreamHost = process.env.OLLAMA_HOST || "http://127.0.0.1:11434";
const logFile = process.env.FIXTURE_LOG || "/tmp/pimacs-extensions-proxay.log";

interface RecordedAnchor {
  path: string;
  content: string;
  occurrence: number;
}

interface TapeInteraction {
  request?: { body?: { data?: string } };
}

interface Tape {
  http_interactions?: TapeInteraction[];
}

function anchoredRows(content: string): Array<{ anchor: string; content: string }> {
  const rows: Array<{ anchor: string; content: string }> = [];
  for (const line of content.split("\n")) {
    // Context and added diff rows remain valid anchors; removed rows do not.
    const match = /^(?:[ +])?([A-Za-z0-9]{4})│(.*)$/.exec(line);
    if (match) rows.push({ anchor: match[1], content: match[2] });
  }
  return rows;
}

/**
 * Tapes contain the model's old anchor arguments.  Hashline deliberately makes
 * newly allocated anchors session-specific, so replay translates those old IDs to
 * the IDs returned by this run's read/grep result immediately before execution.
 */
function recordedAnchors(tapePath: string): Map<string, RecordedAnchor> {
  const tape = loadYaml(readFileSync(tapePath, "utf8")) as Tape;
  const anchors = new Map<string, RecordedAnchor>();

  for (const interaction of tape.http_interactions ?? []) {
    const data = interaction.request?.body?.data;
    if (!data) continue;

    let request: { messages?: unknown[] };
    try {
      request = JSON.parse(data) as { messages?: unknown[] };
    } catch {
      continue;
    }
    if (!Array.isArray(request.messages)) continue;

    const calls = new Map<string, { name?: string; path?: string }>();
    for (const message of request.messages) {
      if (!message || typeof message !== "object") continue;
      const record = message as Record<string, unknown>;
      if (record.role === "assistant" && Array.isArray(record.tool_calls)) {
        for (const call of record.tool_calls) {
          if (!call || typeof call !== "object") continue;
          const toolCall = call as Record<string, unknown>;
          const fn = toolCall.function as Record<string, unknown> | undefined;
          if (typeof toolCall.id !== "string" || !fn || typeof fn.arguments !== "string") continue;
          try {
            const args = JSON.parse(fn.arguments) as Record<string, unknown>;
            calls.set(toolCall.id, {
              name: typeof fn.name === "string" ? fn.name : undefined,
              path: typeof args.path === "string" ? args.path : undefined,
            });
          } catch {
            // Ignore malformed tape entries; Proxay will report those separately.
          }
        }
      }

      if (record.role !== "tool" || typeof record.tool_call_id !== "string" || typeof record.content !== "string") continue;
      const call = calls.get(record.tool_call_id);
      if (!call?.path || (call.name !== "read" && call.name !== "anchor_grep")) continue;

      const occurrences = new Map<string, number>();
      for (const row of anchoredRows(record.content)) {
        const occurrence = occurrences.get(row.content) ?? 0;
        occurrences.set(row.content, occurrence + 1);
        if (!anchors.has(row.anchor)) {
          anchors.set(row.anchor, { path: call.path, content: row.content, occurrence });
        }
      }
    }
  }

  return anchors;
}
function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address() as AddressInfo;
      server.close(() => resolve(address.port));
    });
  });
}

export default async function fixture(pi: ExtensionAPI): Promise<void> {
  const port = await freePort();
  const replayAnchors = mode === "replay"
    ? recordedAnchors(path.join(tapesDirectory, `${scenario}.yml`))
    : new Map<string, RecordedAnchor>();
  const liveAnchors = new Map<string, string>();

  pi.on("tool_result", (event, ctx) => {
    if (event.toolName !== "read" && event.toolName !== "anchor_grep") return;
    const requestedPath = event.input.path;
    if (typeof requestedPath !== "string") return;

    const output = event.content
      .filter((part): part is { type: "text"; text: string } => part.type === "text")
      .map((part) => part.text)
      .join("");
    const occurrences = new Map<string, number>();
    for (const row of anchoredRows(output)) {
      const occurrence = occurrences.get(row.content) ?? 0;
      occurrences.set(row.content, occurrence + 1);
      for (const [recorded, expected] of replayAnchors) {
        if (
          path.resolve(ctx.cwd, expected.path) === path.resolve(ctx.cwd, requestedPath) &&
          expected.content === row.content &&
          expected.occurrence === occurrence
        ) {
          liveAnchors.set(recorded, row.anchor);
        }
      }
    }
  });

  pi.on("tool_call", (event) => {
    if (event.toolName !== "replace" && event.toolName !== "insert") return;
    for (const field of ["remove_from", "remove_to", "anchor"]) {
      const recorded = event.input[field];
      if (typeof recorded !== "string") continue;
      const live = liveAnchors.get(recorded);
      if (live) event.input[field] = live;
    }
  });

  const proxay = spawn(proxayBinary, [
    "--mode",
    mode,
    "--tapes-dir",
    tapesDirectory,
    "--default-tape",
    scenario,
    "--host",
    upstreamHost,
    "--port",
    String(port),
  ]);

  proxay.stdout.on("data", (data) => appendFileSync(logFile, `[stdout] ${data}`));
  proxay.stderr.on("data", (data) => appendFileSync(logFile, `[stderr] ${data}`));
  proxay.on("exit", (code) => appendFileSync(logFile, `[exit] code=${code}\n`));

  const stop = () => proxay.kill();
  for (const event of ["exit", "SIGINT", "SIGTERM"] as const) {
    process.once(event, stop);
  }
  process.once("uncaughtException", stop);

  pi.registerProvider("fixture", {
    api: "openai-completions",
    baseUrl: `http://127.0.0.1:${port}/v1`,
    apiKey: "fixture",
    models: [
      {
        id: "gemma4:12b",
        name: "gemma4:12b",
        reasoning: true,
        input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 200000,
        maxTokens: 100000
      }
    ]
  });
}
