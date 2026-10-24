import { readFileSync } from "node:fs";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { load as loadYaml } from "js-yaml";

interface Interaction {
  request: { method: string; path: string };
  response: {
    status: { code: number };
    headers: Record<string, string>;
    body: { encoding: BufferEncoding; data: string; compression?: string };
  };
}

/** Consume each recorded completion once, regardless of prompt/schema changes.
 * Fuzzy request matching can select the same old completion forever. */
export class ReplayTape {
  private cursor = 0;

  private interactions: Interaction[];

  constructor(interactions: Interaction[]) {
    this.interactions = interactions;
  }

  static load(file: string): ReplayTape {
    const tape = loadYaml(readFileSync(file, "utf8")) as { http_interactions: Interaction[] };
    return new ReplayTape(tape.http_interactions);
  }

  next(method: string, path: string): Interaction["response"] {
    const interaction = this.interactions[this.cursor];
    if (!interaction) throw new Error(`Replay exhausted after ${this.cursor} requests; unexpected ${method} ${path}`);
    if (method !== interaction.request.method || path !== interaction.request.path) {
      throw new Error(`Replay request ${this.cursor + 1}: expected ${interaction.request.method} ${interaction.request.path}, got ${method} ${path}`);
    }
    this.cursor++;
    return interaction.response;
  }
}

export async function startReplayServer(file: string): Promise<{ port: number; stop: () => void }> {
  const tape = ReplayTape.load(file);
  const server = createServer((request, response) => {
    request.resume();
    try {
      const recorded = tape.next(request.method ?? "", request.url ?? "");
      if (recorded.body.compression && recorded.body.compression !== "none") {
        throw new Error(`Unsupported tape compression: ${recorded.body.compression}`);
      }
      response.writeHead(recorded.status.code, {
        "content-type": recorded.headers["content-type"] ?? "text/event-stream",
      });
      response.end(Buffer.from(recorded.body.data, recorded.body.encoding));
    } catch (error) {
      response.writeHead(500, { "content-type": "application/json" });
      response.end(JSON.stringify({ error: { message: String(error), type: "fixture_error" } }));
    }
  });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  return {
    port: (server.address() as AddressInfo).port,
    stop: () => { server.closeAllConnections(); server.close(); },
  };
}
