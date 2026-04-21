#!/usr/bin/env node
// One-shot exercise of editor.game_screenshot + logs.read against a running game.
import net from "node:net";

function call(method, params = {}) {
  return new Promise((resolve, reject) => {
    const s = new net.Socket();
    let buf = "";
    s.setEncoding("utf8");
    s.on("data", (d) => {
      buf += d;
      const nl = buf.indexOf("\n");
      if (nl < 0) return;
      try {
        const msg = JSON.parse(buf.slice(0, nl));
        s.end();
        if (msg.error) reject(new Error(`${msg.error.code}: ${msg.error.message}`));
        else resolve(msg.result);
      } catch (e) { reject(e); }
    });
    s.on("error", reject);
    s.connect(9920, "127.0.0.1", () => {
      s.write(JSON.stringify({ id: 1, method, params }) + "\n");
    });
  });
}

console.log("=== editor.state ===");
const state = await call("editor.state");
console.log("playing_scene:", state.playing_scene);
console.log("playing_scene_path:", state.playing_scene_path);

console.log("\n=== editor.game_screenshot ===");
try {
  const shot = await call("editor.game_screenshot", {
    output: "res://.godot/agent_tools/live_test.png",
    timeout_ms: 8000,
  });
  console.log("result:", shot);
} catch (e) {
  console.log("FAILED:", e.message);
}

console.log("\n=== logs.read ===");
try {
  const logs = await call("logs.read", { max_lines: 50 });
  console.log("count:", logs.count);
  if (logs.note) console.log("note:", logs.note);
  for (const entry of logs.entries) {
    const t = new Date(entry.time_ms).toISOString().split("T")[1].slice(0, 8);
    console.log(`  [${entry.level.padEnd(7)}] ${entry.message.slice(0, 120)}`);
  }
} catch (e) {
  console.log("FAILED:", e.message);
}
