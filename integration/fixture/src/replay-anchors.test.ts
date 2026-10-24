import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { load as loadYaml } from "js-yaml";
import { anchoredRows, recordedResults, ReplayAnchors } from "./replay-anchors.ts";

test("live rows include reads, grep and diff context, but exclude deletions", () => {
  assert.deepEqual(anchoredRows([
    "dafox│alpha", " 11-│ emnox│context", "12:│ hdtmx│beta",
    "+qwerx│added", " hasux│unchanged", "-arvmx│deleted",
    "-     │deleted",
  ].join("\n")), [
    { anchor: "dafox", content: "alpha" },
    { anchor: "emnox", content: "context" },
    { anchor: "hdtmx", content: "beta" },
    { anchor: "qwerx", content: "added" },
    { anchor: "hasux", content: "unchanged" },
  ]);
});

test("copy/move destinations and fresh replace_match anchors are translated", () => {
  const replay = new ReplayAnchors([
    { toolName: "read", rows: anchoredRows("abcde│beta") },
    { toolName: "read", rows: anchoredRows("fghij│top\nklmno│beta") },
    { toolName: "copy", rows: anchoredRows(" fghij│top\n+pqrst│beta\n klmno│beta") },
  ]);
  replay.observe("read", "dafox│beta");
  replay.observe("read", "emnox│top\nhdtmx│beta");
  for (const tool of ["copy", "move"]) {
    const args = { source_from: "abcde", source_to: "abcde", anchor: "fghij" };
    replay.translate(tool, args);
    assert.deepEqual(args, { source_from: "dafox", source_to: "dafox", anchor: "emnox" });
  }
  replay.observe("copy", " emnox│top\n+qwerx│beta\n hdtmx│beta");
  const args = { replace_from: "pqrst", replace_to: "pqrst", match: "beta", replacement: "BETA" };
  replay.translate("replace_match", args);
  assert.deepEqual(args, {
    replace_from: "qwerx", replace_to: "qwerx", match: "beta", replacement: "BETA",
  });
});

test("replay rejects changed row content and tool order", () => {
  const results = [{ toolName: "read", rows: anchoredRows("abcde│beta") }];
  assert.throws(() => new ReplayAnchors(results).observe("grep", "dafox│beta"), /order mismatch/);
  assert.throws(() => new ReplayAnchors(results).observe("read", "dafox│changed"), /rows differ/);
});

test("recordings replay current tool names and argument schemas", () => {
  const tapes = new URL("../tapes/", import.meta.url);
  let calls = 0;
  for (const name of readdirSync(tapes).filter((name) => name.endsWith(".yml"))) {
    const tapePath = new URL(name, tapes);
    const results = recordedResults(fileURLToPath(tapePath));
    assert.ok(results.length > 0, name);
    assert.ok(results.every((result) => !["anchor_grep", "replace_within"].includes(result.toolName)));
    for (const result of results) {
      if (["read", "grep"].includes(result.toolName)) assert.ok(result.rows.length > 0, name);
      for (const row of result.rows) assert.match(row.anchor, /^[a-z]{5}$/);
    }
    const tape = loadYaml(readFileSync(tapePath, "utf8")) as {
      http_interactions: Array<{ response: { body: { data: string } } }>;
    };
    for (const interaction of tape.http_interactions) {
      for (const frame of interaction.response.body.data.split("\n")) {
        if (!frame.startsWith("data: ") || frame === "data: [DONE]") continue;
        const chunk = JSON.parse(frame.slice(6));
        for (const choice of chunk.choices ?? []) {
          for (const call of choice.delta?.tool_calls ?? []) {
            const { name, arguments: json } = call.function;
            const args = JSON.parse(json);
            assert.ok(!["anchor_grep", "replace_within"].includes(name), name);
            for (const key of ["replacement_lines", "lines", "replace_old", "replace_new", "insert_after"]) {
              assert.ok(!(key in args), `${name}: obsolete ${key}`);
            }
            const required: Record<string, string[]> = {
              replace: ["remove_from", "remove_to", "text"],
              insert: ["anchor", "direction", "text"],
              replace_match: ["replace_from", "replace_to", "match", "replacement"],
              copy: ["source_from", "source_to", "anchor", "direction"],
              move: ["source_from", "source_to", "anchor", "direction"],
            };
            for (const key of required[name] ?? []) assert.equal(typeof args[key], "string", `${name}.${key}`);
            calls++;
          }
        }
      }
    }
  }
  assert.ok(calls > 20);
});
