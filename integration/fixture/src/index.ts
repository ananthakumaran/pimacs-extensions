import { appendFileSync } from "node:fs";
import { spawn } from "node:child_process";
import { createServer } from "node:net";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { ReplayAnchors, recordedResults } from "./replay-anchors.ts";
import { startReplayServer } from "./replay-tape.ts";
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
  const tapeFile = path.join(tapesDirectory, `${scenario}.yml`);
  const replay = mode === "replay" ? await startReplayServer(tapeFile) : undefined;
  const port = replay?.port ?? await freePort();
  const replayAnchors = replay ? new ReplayAnchors(recordedResults(tapeFile)) : undefined;

  pi.on("tool_result", (event) => {
    if (!replayAnchors) return;
    const details = event.details as { diff?: string } | undefined;
    const output = details?.diff || event.content
      .filter((part): part is { type: "text"; text: string } => part.type === "text")
      .map((part) => part.text)
      .join("");
    try {
      replayAnchors.observe(event.toolName, output);
    } catch (error) {
      return { isError: true, content: [{ type: "text" as const, text: String(error) }] };
    }
  });

  pi.on("tool_call", (event) => {
    replayAnchors?.translate(event.toolName, event.input);
  });

  let stop: () => void;
  if (replay) {
    stop = replay.stop;
  } else {
    const proxay = spawn(proxayBinary, [
      "--mode", mode, "--tapes-dir", tapesDirectory, "--default-tape", scenario,
      "--host", upstreamHost, "--port", String(port),
    ]);
    proxay.stdout.on("data", (data) => appendFileSync(logFile, `[stdout] ${data}`));
    proxay.stderr.on("data", (data) => appendFileSync(logFile, `[stderr] ${data}`));
    proxay.on("exit", (code) => appendFileSync(logFile, `[exit] code=${code}\n`));
    stop = () => { proxay.kill(); };
  }
  pi.on("session_shutdown", stop);
  for (const event of ["exit", "SIGINT", "SIGTERM"] as const) process.once(event, stop);

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
