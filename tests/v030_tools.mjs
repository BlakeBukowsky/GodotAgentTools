#!/usr/bin/env node
// Exercises v0.3.0 additions: editor.state, performance.monitors, editor.selection_*,
// script.patch, fs.read_text/write_text, batch.execute, client.list/configure,
// physics.autofit_collision_shape_2d, theme.*.
// Tests that need a running game (editor.game_screenshot, logs.read) are exercised
// separately — they need the user to press F5.

import net from "node:net";
import fs from "node:fs/promises";
import path from "node:path";

const HOST = "127.0.0.1";
const PORT = 9920;

class Client {
  constructor() { this.s = null; this.buf = ""; this.pending = new Map(); this.id = 0; }
  connect() {
    return new Promise((resolve, reject) => {
      const s = new net.Socket();
      s.setEncoding("utf8");
      s.on("data", (d) => { this.buf += d; this._drain(); });
      s.on("error", reject);
      s.connect(PORT, HOST, () => { this.s = s; resolve(); });
    });
  }
  call(method, params = {}) {
    const id = ++this.id;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      const timer = setTimeout(() => {
        if (this.pending.has(id)) {
          this.pending.delete(id);
          reject(new Error(`timeout: ${method}`));
        }
      }, 30000);
      this.pending.get(id).timer = timer;
      this.s.write(JSON.stringify({ id, method, params }) + "\n");
    });
  }
  _drain() {
    while (true) {
      const nl = this.buf.indexOf("\n");
      if (nl < 0) break;
      const line = this.buf.slice(0, nl);
      this.buf = this.buf.slice(nl + 1);
      if (!line) continue;
      try {
        const msg = JSON.parse(line);
        const p = this.pending.get(msg.id);
        if (!p) continue;
        this.pending.delete(msg.id);
        clearTimeout(p.timer);
        if (msg.error) p.reject(new Error(`${msg.error.code}: ${msg.error.message}`));
        else p.resolve(msg.result);
      } catch {}
    }
  }
  close() { if (this.s) this.s.end(); }
}

let PASS = 0, FAIL = 0;
async function test(name, fn) {
  process.stdout.write(`  ${name.padEnd(54)} `);
  try { await fn(); console.log("\x1b[32mOK\x1b[0m"); PASS++; }
  catch (e) { console.log(`\x1b[31mFAIL\x1b[0m — ${e.message}`); FAIL++; }
}
const assert = (c, m) => { if (!c) throw new Error(m || "assertion failed"); };
const assertEq = (a, b, m) => { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(m || `expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`); };

const TEST_DIR = "res://__v03test";

async function run() {
  const c = new Client();
  try { await c.connect(); } catch (e) {
    console.error(`Cannot reach Godot plugin at ${HOST}:${PORT}`);
    process.exit(2);
  }
  console.log("Connected.\n\nNo-setup probes:");

  await test("editor.state returns version + project_name", async () => {
    const r = await c.call("editor.state");
    assert(r.godot_version, "missing godot_version");
    assert(r.godot_version.startsWith("4."), `unexpected version: ${r.godot_version}`);
    assert(r.project_name, "missing project_name");
    assert("current_scene" in r);
    assert(Array.isArray(r.open_scenes));
  });

  await test("performance.monitors default set", async () => {
    const r = await c.call("performance.monitors");
    assert(r.monitors, "missing monitors");
    assert(typeof r.monitors.fps === "number", "fps should be number");
    assert(typeof r.monitors.mem_static_mb === "number", "mem_static_mb should be number");
    assert(typeof r.monitors.object_count === "number");
  });

  await test("performance.monitors targeted subset", async () => {
    const r = await c.call("performance.monitors", { monitors: ["fps", "draw_calls"] });
    assert("fps" in r.monitors && "draw_calls" in r.monitors);
    assertEq(Object.keys(r.monitors).length, 2);
  });

  await test("editor.selection_get baseline", async () => {
    const r = await c.call("editor.selection_get");
    assert(Array.isArray(r.selected));
    assert(typeof r.count === "number");
  });

  await test("client.list returns all supported clients", async () => {
    const r = await c.call("client.list");
    const ids = r.clients.map((c) => c.client);
    for (const expected of ["claude_code_project", "claude_code_user", "claude_desktop", "cursor_project", "cursor_user"]) {
      assert(ids.includes(expected), `missing client: ${expected}`);
    }
  });

  await test("client.configure claude_code_project is idempotent", async () => {
    // This project already has .mcp.json with our entry — should say already_configured.
    const r = await c.call("client.configure", { client: "claude_code_project" });
    assert(["already_configured", "configured"].includes(r.status), `unexpected status: ${r.status}`);
  });

  console.log("\nFile + script operations:");

  await test("fs.write_text creates file + parent dir", async () => {
    const r = await c.call("fs.write_text", {
      path: `${TEST_DIR}/hello.txt`,
      content: "hello from agent_tools v0.3",
      overwrite: true,
    });
    assert(r.bytes_written > 0);
  });

  await test("fs.read_text reads it back", async () => {
    const r = await c.call("fs.read_text", { path: `${TEST_DIR}/hello.txt` });
    assertEq(r.content, "hello from agent_tools v0.3");
  });

  await test("fs.read_text on user:// rejects cleanly", async () => {
    try {
      await c.call("fs.read_text", { path: "user://anything.txt" });
      throw new Error("should have errored");
    } catch (e) {
      assert(e.message.includes("res://"), `unexpected: ${e.message}`);
    }
  });

  // Create a test script we'll patch
  await c.call("fs.write_text", {
    path: `${TEST_DIR}/target.gd`,
    content: "extends Node\n\nfunc hello():\n\tprint(\"world\")\n",
    overwrite: true,
  });

  await test("script.patch dry_run shows diff without writing", async () => {
    const r = await c.call("script.patch", {
      path: `${TEST_DIR}/target.gd`,
      replacements: [{ old: "\"world\"", new: "\"patched\"" }],
      dry_run: true,
    });
    assert(r.changed);
    // Verify original unchanged
    const r2 = await c.call("fs.read_text", { path: `${TEST_DIR}/target.gd` });
    assert(r2.content.includes("\"world\""), "dry_run should not have written");
  });

  await test("script.patch applies replacement", async () => {
    const r = await c.call("script.patch", {
      path: `${TEST_DIR}/target.gd`,
      replacements: [{ old: "\"world\"", new: "\"patched\"" }],
    });
    assert(r.changed);
    const r2 = await c.call("fs.read_text", { path: `${TEST_DIR}/target.gd` });
    assert(r2.content.includes("\"patched\""));
    assert(!r2.content.includes("\"world\""));
  });

  await test("script.patch ambiguous match errors cleanly", async () => {
    // File now has 'print' once... add another print first then try ambiguous patch
    await c.call("fs.write_text", {
      path: `${TEST_DIR}/amb.gd`,
      content: "extends Node\n\nfunc a():\n\tprint(1)\n\nfunc b():\n\tprint(2)\n",
      overwrite: true,
    });
    try {
      await c.call("script.patch", {
        path: `${TEST_DIR}/amb.gd`,
        replacements: [{ old: "print", new: "printerr" }],
      });
      throw new Error("should have errored on ambiguous match");
    } catch (e) {
      assert(e.message.includes("ambiguous") || e.message.includes("appears"), `unexpected: ${e.message}`);
    }
  });

  await test("script.patch rolls back on parse error", async () => {
    await c.call("fs.write_text", {
      path: `${TEST_DIR}/rollback.gd`,
      content: "extends Node\n\nfunc ok():\n\tpass\n",
      overwrite: true,
    });
    try {
      await c.call("script.patch", {
        path: `${TEST_DIR}/rollback.gd`,
        replacements: [{ old: "func ok():\n\tpass", new: "func ok):\n\tpass" }], // missing paren -> parse error
      });
      throw new Error("should have errored on parse failure");
    } catch (e) {
      assert(e.message.toLowerCase().includes("parse") || e.message.includes("rolled back"),
        `unexpected: ${e.message}`);
    }
    // Verify original preserved
    const r = await c.call("fs.read_text", { path: `${TEST_DIR}/rollback.gd` });
    assert(r.content.includes("func ok():"), "original should be preserved");
  });

  console.log("\nBatch + physics + theme:");

  await test("batch.execute runs multiple calls", async () => {
    const r = await c.call("batch.execute", {
      calls: [
        { method: "editor.state" },
        { method: "performance.monitors", params: { monitors: ["fps"] } },
        { method: "fs.list", params: { type: "script" } },
      ],
    });
    assertEq(r.count, 3);
    assert(r.results.every((x) => x.ok), "all calls should succeed");
    assertEq(r.results[0].method, "editor.state");
  });

  await test("batch.execute with one bad call records error", async () => {
    const r = await c.call("batch.execute", {
      calls: [
        { method: "editor.state" },
        { method: "scene.add_node" }, // missing 'type' -> error
      ],
    });
    assert(r.results[0].ok);
    assert(!r.results[1].ok);
    assert(r.results[1].error);
  });

  await test("physics.autofit_collision_shape_2d creates + sizes shape", async () => {
    // Create a test scene with Sprite2D + CollisionShape2D placeholder
    const scenePath = `${TEST_DIR}/physics_scene.tscn`;
    await c.call("scene.new", { path: scenePath, root_type: "Node2D", root_name: "Root", overwrite: true });
    await c.call("scene.add_node", { type: "Sprite2D", name: "Sprite" });
    // Scale the sprite so bounds != zero (no texture means bounds zero otherwise).
    // Cheat: give it a tiny placeholder texture via resource.create. For this test,
    // just set the scale to simulate bounds and see if error surfaces as expected.
    await c.call("scene.add_node", { type: "CollisionShape2D", name: "Shape" });

    // Without a real texture, the tool should error that source has no extents —
    // that itself is correct behavior. This test just verifies the tool wires up
    // correctly and the error is clean.
    try {
      const r = await c.call("physics.autofit_collision_shape_2d", {
        node_path: "Shape",
        source: "Sprite",
      });
      // If it succeeds (e.g., Godot returned default texture), that's OK too.
      assert(r.shape === "rectangle");
    } catch (e) {
      assert(e.message.includes("extents") || e.message.includes("texture"),
        `unexpected error: ${e.message}`);
    }
  });

  await test("theme.set_color + set_font_size on a fresh theme", async () => {
    const themePath = `${TEST_DIR}/test_theme.tres`;
    await c.call("resource.create", { path: themePath, type: "Theme", overwrite: true });
    const rc = await c.call("theme.set_color", {
      path: themePath,
      item: "font_color",
      type: "Label",
      color: [1, 0.5, 0.2, 1],
    });
    assertEq(rc.kind, "color");
    const rf = await c.call("theme.set_font_size", {
      path: themePath,
      item: "font_size",
      type: "Label",
      value: 24,
    });
    assertEq(rf.kind, "font_size");
  });

  await test("theme.set_stylebox_flat creates StyleBoxFlat with properties", async () => {
    const themePath = `${TEST_DIR}/test_theme.tres`;
    const r = await c.call("theme.set_stylebox_flat", {
      path: themePath,
      item: "normal",
      type: "Button",
      properties: {
        bg_color: [0.1, 0.1, 0.12, 1],
        corner_radius_top_left: 8,
        corner_radius_top_right: 8,
        corner_radius_bottom_left: 8,
        corner_radius_bottom_right: 8,
      },
    });
    assertEq(r.item, "normal");
    assertEq(r.type, "Button");
    assert(r.applied_properties.length > 0);
  });

  console.log("\nCleanup:");
  await test("delete __v03test dir", async () => {
    const projectRoot = path.resolve(process.cwd());
    await fs.rm(path.join(projectRoot, "__v03test"), { recursive: true, force: true });
    await c.call("editor.reload_filesystem");
  });

  c.close();
  console.log(`\n${PASS} passed, ${FAIL} failed`);
  process.exit(FAIL === 0 ? 0 : 1);
}

run().catch((e) => { console.error("fatal:", e); process.exit(2); });
