import { readFileSync } from "node:fs";
import { load as loadYaml } from "js-yaml";

export interface AnchorRow {
  anchor: string;
  content: string;
}

export function anchoredRows(content: string): AnchorRow[] {
  const rows: AnchorRow[] = [];
  for (const line of content.split("\n")) {
    // Read, numbered grep, added diff and context rows are live; deletions aren't.
    const match = /^(?:\d+\s*│\s*)?(?:[ +])?([A-Za-z0-9]{4})│(.*)$/.exec(line);
    if (match) rows.push({ anchor: match[1], content: match[2] });
  }
  return rows;
}

export interface RecordedResult {
  toolName: string;
  rows: AnchorRow[];
}

export function recordedResults(tapePath: string): RecordedResult[] {
  const tape = loadYaml(readFileSync(tapePath, "utf8")) as {
    http_interactions?: Array<{ request?: { body?: { data?: string } } }>;
  };
  const results = new Map<string, RecordedResult>();
  for (const interaction of tape.http_interactions ?? []) {
    const data = interaction.request?.body?.data;
    if (!data) continue;
    const request = JSON.parse(data) as { messages?: Array<{
      role: string;
      tool_calls?: Array<{ id: string; function: { name: string } }>;
      tool_call_id?: string;
      content?: string;
    }> };
    const calls = new Map<string, string>();
    for (const message of request.messages ?? []) {
      for (const call of message.tool_calls ?? []) calls.set(call.id, call.function.name);
      if (message.role !== "tool" || !message.tool_call_id || typeof message.content !== "string") continue;
      const toolName = calls.get(message.tool_call_id);
      if (toolName && !results.has(message.tool_call_id)) {
        results.set(message.tool_call_id, { toolName, rows: anchoredRows(message.content) });
      }
    }
  }
  return [...results.values()];
}

const anchorFields: Record<string, string[]> = {
  replace: ["remove_from", "remove_to", "replace_from", "replace_to", "from", "to"],
  insert: ["anchor"],
  replace_within: ["replace_from", "replace_to"],
  copy: ["source_from", "source_to", "insert_after"],
  move: ["source_from", "source_to", "insert_after"],
};

/** Translate per-result rows, not global content matches: duplicate lines in
 * different files and newly minted anchors in edit diffs must stay distinct. */
export class ReplayAnchors {
  private cursor = 0;
  private live = new Map<string, string>();

  private results: RecordedResult[];

  constructor(results: RecordedResult[]) {
    this.results = results;
  }

  observe(toolName: string, output: string): void {
    const expected = this.results[this.cursor];
    if (!expected || expected.toolName !== toolName) {
      throw new Error(`Replay tool order mismatch: expected ${expected?.toolName}, got ${toolName}`);
    }
    this.cursor++;
    const rows = anchoredRows(output);
    if (rows.length !== expected.rows.length || rows.some((row, i) => row.content !== expected.rows[i].content)) {
      throw new Error(`Replay anchor rows differ for ${toolName}; re-record the tape`);
    }
    rows.forEach((row, i) => this.live.set(expected.rows[i].anchor, row.anchor));
  }

  translate(toolName: string, input: Record<string, unknown>): void {
    for (const field of anchorFields[toolName] ?? []) {
      const recorded = input[field];
      if (typeof recorded !== "string") continue;
      const live = this.live.get(recorded);
      if (live) input[field] = live;
    }
  }
}
