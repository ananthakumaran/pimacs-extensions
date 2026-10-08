import { appendFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import * as yaml from "js-yaml";
import { spawn } from "node:child_process";
import { createServer } from "node:net";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { ReplayAnchors, recordedResults } from "./replay-anchors.ts";
import type { AddressInfo } from "node:net";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const dumpYaml = (yaml as unknown as { dump(value: unknown): string }).dump;
const loadYaml = yaml.load;

const directory = path.dirname(fileURLToPath(import.meta.url));
const fixtureDirectory = path.resolve(directory, "..");
const tapesDirectory = path.join(fixtureDirectory, "tapes");
const proxayBinary = path.join(fixtureDirectory, "node_modules/.bin/proxay");
const scenario = process.env.FIXTURE_SCENARIO || "hashline";
const mode = process.env.FIXTURE_MODE || "replay";
const upstreamHost = process.env.OLLAMA_HOST || "http://127.0.0.1:11434";
const logFile = process.env.FIXTURE_LOG || "/tmp/pimacs-extensions-proxay.log";


const replayDirectory = path.join("/tmp", `pimacs-hashline-replay-${process.pid}`);

function prepareReplayTape(): string {
  const tapePath = path.join(tapesDirectory, `${scenario}.yml`);
  const tape = loadYaml(readFileSync(tapePath, "utf8")) as {
    http_interactions?: Array<{ response?: { body?: { data?: string } } }>;
  };
  for (const interaction of tape.http_interactions ?? []) {
    const data = interaction.response?.body?.data;
    if (typeof data !== "string") continue;
    interaction.response!.body!.data = data.split("\n").map((line) => {
      if (!line.startsWith("data: ")) return line;
      try {
        const chunk = JSON.parse(line.slice(6)) as {
          choices?: Array<{ delta?: { tool_calls?: Array<{ function?: { name?: string; arguments?: string } }> } }>;
        };
        for (const choice of chunk.choices ?? []) {
          for (const call of choice.delta?.tool_calls ?? []) {
            const fn = call.function;
            if (!fn?.arguments) continue;
            const args = JSON.parse(fn.arguments) as Record<string, unknown>;
            if (fn.name === "replace" && Array.isArray(args.replacement_lines)) {
              args.text = args.replacement_lines.join("\n");
              delete args.replacement_lines;
            } else if (fn.name === "insert" && Array.isArray(args.lines)) {
              args.text = args.lines.join("\n");
              delete args.lines;
            } else if (fn.name === "replace_match") {
              if (typeof args.replace_old === "string") {
                args.old_string = args.replace_old;
                delete args.replace_old;
              }
              if (typeof args.replace_new === "string") {
                args.new_string = args.replace_new;
                delete args.replace_new;
              }
            }
            fn.arguments = JSON.stringify(args);
          }
        }
        return `data: ${JSON.stringify(chunk)}`;
      } catch {
        return line;
      }
    }).join("\n");
  }
  mkdirSync(replayDirectory, { recursive: true });
  writeFileSync(path.join(replayDirectory, `${scenario}.yml`), dumpYaml(tape));
  return replayDirectory;
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
    ? new ReplayAnchors(recordedResults(path.join(tapesDirectory, `${scenario}.yml`)))
    : undefined;

  pi.on("tool_result", (event) => {
    if (!replayAnchors) return;
    const details = event.details as { diff?: string } | undefined;
    const output = details?.diff || event.content
      .filter((part): part is { type: "text"; text: string } => part.type === "text")
      .map((part) => part.text)
      .join("");
    replayAnchors.observe(event.toolName, output);
  });

  pi.on("tool_call", (event) => {
    replayAnchors?.translate(event.toolName, event.input);
  });

  const proxay = spawn(proxayBinary, [
    "--mode",
    mode,
    "--tapes-dir",
    mode === "replay" ? prepareReplayTape() : tapesDirectory,
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
