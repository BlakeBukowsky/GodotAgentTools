#!/usr/bin/env node
// One-shot test of test.run against GUT. Expects addons/gut installed and
// res://test/test_smoke.gd present.
import net from "node:net";

const s = new net.Socket();
let buf = "";
s.setEncoding("utf8");
s.on("data", (d) => {
  buf += d;
  const nl = buf.indexOf("\n");
  if (nl < 0) return;
  const line = buf.slice(0, nl);
  const msg = JSON.parse(line);
  if (msg.error) {
    console.log("ERROR:", msg.error);
    process.exit(1);
  }
  const r = msg.result;
  console.log("framework:         ", r.framework);
  console.log("exit_code:         ", r.exit_code);
  console.log("total:             ", r.total);
  console.log("passed:            ", r.passed);
  console.log("failed:            ", r.failed);
  console.log("skipped:           ", r.skipped);
  console.log("failures:");
  for (const f of r.failures) {
    console.log(`  - ${f.name} @ ${f.file}:${f.line}`);
    console.log(`    ${f.message}`);
  }
  s.end();
  process.exit(0);
});
s.on("error", (e) => { console.error("connection:", e.message); process.exit(2); });
s.connect(9920, "127.0.0.1", () => {
  s.write(JSON.stringify({
    id: 1,
    method: "test.run",
    params: { framework: "gut", directory: "res://test", timeout_seconds: 60 },
  }) + "\n");
});
