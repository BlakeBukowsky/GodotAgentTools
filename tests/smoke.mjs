#!/usr/bin/env node
// Smoke test — exercises each tool against a running Godot editor with the
// agent_tools plugin enabled. Uses the raw TCP protocol directly (not MCP)
// to keep the harness small.
//
// Run:
//   1. Open Godot editor on this project with the plugin enabled
//   2. node tests/smoke.mjs
//
// Exits non-zero on the first failure. Creates and cleans up its own
// temp scenes under res://__smoketest/.

import net from "node:net";
import fs from "node:fs/promises";
import path from "node:path";

const HOST = process.env.GODOT_AGENT_HOST || "127.0.0.1";
const PORT = parseInt(process.env.GODOT_AGENT_PORT || "9920", 10);

// ---- tiny client --------------------------------------------------------

class Client {
  constructor() {
    this.socket = null;
    this.buffer = "";
    this.pending = new Map();
    this.nextId = 0;
  }

  async connect() {
    return new Promise((resolve, reject) => {
      const s = new net.Socket();
      s.setEncoding("utf8");
      s.on("data", (d) => this._onData(d));
      s.on("error", reject);
      s.connect(PORT, HOST, () => {
        this.socket = s;
        resolve();
      });
    });
  }

  call(method, params = {}) {
    const id = ++this.nextId;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      const timer = setTimeout(() => {
        if (this.pending.has(id)) {
          this.pending.delete(id);
          reject(new Error(`timeout: ${method}`));
        }
      }, 20000);
      this.pending.get(id).timer = timer;
      this.socket.write(JSON.stringify({ id, method, params }) + "\n");
    });
  }

  _onData(data) {
    this.buffer += data;
    while (true) {
      const nl = this.buffer.indexOf("\n");
      if (nl < 0) break;
      const line = this.buffer.slice(0, nl);
      this.buffer = this.buffer.slice(nl + 1);
      if (!line) continue;
      let msg;
      try { msg = JSON.parse(line); } catch { continue; }
      const p = this.pending.get(msg.id);
      if (!p) continue;
      this.pending.delete(msg.id);
      clearTimeout(p.timer);
      if (msg.error) p.reject(new Error(`${msg.error.code}: ${msg.error.message}`));
      else p.resolve(msg.result);
    }
  }

  close() { if (this.socket) this.socket.end(); }
}

// ---- tiny harness -------------------------------------------------------

const RESULTS = [];
let PASSED = 0;
let FAILED = 0;

async function test(name, fn) {
  process.stdout.write(`  ${name.padEnd(48)} `);
  try {
    await fn();
    console.log("\x1b[32mOK\x1b[0m");
    PASSED++;
    RESULTS.push({ name, ok: true });
  } catch (e) {
    console.log(`\x1b[31mFAIL\x1b[0m — ${e.message}`);
    FAILED++;
    RESULTS.push({ name, ok: false, error: e.message });
  }
}

function assert(cond, msg) {
  if (!cond) throw new Error(msg || "assertion failed");
}

function assertEq(a, b, msg) {
  if (a !== b) throw new Error(msg || `expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
}

// ---- tests --------------------------------------------------------------

const TEST_DIR = "res://__smoketest";
const TEST_SCENE = `${TEST_DIR}/main.tscn`;
const TEST_SUBSCENE = `${TEST_DIR}/sub.tscn`;
const TEST_SCRIPT = `${TEST_DIR}/player.gd`;
const TEST_RESOURCE = `${TEST_DIR}/theme.tres`;

async function run() {
  const c = new Client();
  try {
    await c.connect();
  } catch (e) {
    console.error(`Cannot connect to ${HOST}:${PORT} — is the Godot editor open with the plugin enabled?`);
    process.exit(2);
  }

  console.log(`\nConnected to Godot at ${HOST}:${PORT}\n`);

  // --- read-only probes ---
  console.log("Read-only probes:");

  await test("scene.current responds", async () => {
    const r = await c.call("scene.current");
    assert(typeof r.open === "boolean", "scene.current missing 'open' field");
  });

  await test("refs.validate_project runs", async () => {
    const r = await c.call("refs.validate_project");
    assert(Array.isArray(r.issues), "missing issues array");
    assert(typeof r.checked === "number", "missing checked count");
  });

  await test("docs.class_ref on Timer", async () => {
    const r = await c.call("docs.class_ref", { class_name: "Timer" });
    assertEq(r.class, "Timer");
    assertEq(r.parent, "Node");
    assert(r.methods.some((m) => m.name === "start"), "Timer should have 'start' method");
    assert(r.signals.some((s) => s.name === "timeout"), "Timer should have 'timeout' signal");
  });

  await test("docs.class_ref rejects unknown class", async () => {
    try {
      await c.call("docs.class_ref", { class_name: "ThisClassDoesNotExist" });
      throw new Error("should have errored");
    } catch (e) {
      assert(e.message.includes("unknown class"), `unexpected: ${e.message}`);
    }
  });

  await test("autoload.list responds", async () => {
    const r = await c.call("autoload.list");
    assert(Array.isArray(r.autoloads));
  });

  await test("project.get_setting reads config/name", async () => {
    const r = await c.call("project.get_setting", { key: "application/config/name" });
    assertEq(r.exists, true);
    assert(typeof r.value === "string");
  });

  await test("fs.list all types", async () => {
    const r = await c.call("fs.list");
    assert(Array.isArray(r.files));
    assert(r.count === r.files.length);
  });

  await test("fs.list scripts only", async () => {
    const r = await c.call("fs.list", { type: "script" });
    for (const f of r.files) {
      assert(f.endsWith(".gd") || f.endsWith(".cs"), `non-script in script list: ${f}`);
    }
  });

  // --- constructive flow ---
  console.log("\nMutation flow (creates res://__smoketest/):");

  await test("scene.new creates main scene", async () => {
    const r = await c.call("scene.new", {
      path: TEST_SCENE,
      root_type: "Node2D",
      root_name: "World",
      overwrite: true,
    });
    assertEq(r.path, TEST_SCENE);
  });

  await test("scene.current reflects new scene", async () => {
    const r = await c.call("scene.current");
    assertEq(r.open, true);
    assertEq(r.path, TEST_SCENE);
    assertEq(r.root_class, "Node2D");
  });

  await test("scene.add_node adds a Sprite2D", async () => {
    const r = await c.call("scene.add_node", { type: "Sprite2D", name: "Hero" });
    assertEq(r.name, "Hero");
    assertEq(r.class, "Sprite2D");
  });

  await test("scene.add_node adds a Label", async () => {
    await c.call("scene.add_node", { type: "Label", name: "Title" });
  });

  await test("scene.set_property sets Label text", async () => {
    const r = await c.call("scene.set_property", {
      node_path: "Title",
      property: "text",
      value: "Hello",
    });
    assertEq(r.value, "Hello");
  });

  await test("scene.get_property reads Label text back", async () => {
    const r = await c.call("scene.get_property", {
      node_path: "Title",
      property: "text",
    });
    assertEq(r.value, "Hello");
    assertEq(r.type, "String");
  });

  await test("scene.inspect shows two children", async () => {
    const r = await c.call("scene.inspect");
    assertEq(r.root.children.length, 2);
  });

  await test("script.create with attach", async () => {
    const r = await c.call("script.create", {
      path: TEST_SCRIPT,
      extends: "Node2D",
      class_name: "SmoketestPlayer",
      attach_to_node: ".",
      overwrite: true,
    });
    assertEq(r.path, TEST_SCRIPT);
    assertEq(r.attached_to, ".");
  });

  await test("scene.reparent moves Title under Hero", async () => {
    const r = await c.call("scene.reparent", {
      node_path: "Title",
      new_parent_path: "Hero",
    });
    assertEq(r.node_path, "Hero/Title");
  });

  await test("scene.remove_node removes Title", async () => {
    await c.call("scene.remove_node", { node_path: "Hero/Title" });
  });

  await test("scene.save", async () => {
    await c.call("scene.save");
  });

  await test("refs.find_usages finds script in scene", async () => {
    const r = await c.call("refs.find_usages", { target: TEST_SCRIPT });
    assert(r.matches.some((m) => m.path === TEST_SCENE), "scene should reference the script");
  });

  await test("scene.new creates subscene (no open)", async () => {
    await c.call("scene.new", {
      path: TEST_SUBSCENE,
      root_type: "Control",
      root_name: "HUD",
      open_after: false,
      overwrite: true,
    });
  });

  await test("scene.instance_packed adds subscene", async () => {
    const r = await c.call("scene.instance_packed", {
      scene_path: TEST_SUBSCENE,
      parent_path: ".",
      name: "HUD",
    });
    assertEq(r.name, "HUD");
  });

  await test("scene.capture_screenshot writes PNG", async () => {
    const r = await c.call("scene.capture_screenshot", {
      output: `${TEST_DIR}/screen.png`,
    });
    assert(typeof r.width === "number" && r.width > 0);
    assert(typeof r.height === "number" && r.height > 0);
  });

  await test("resource.create StyleBoxFlat", async () => {
    const r = await c.call("resource.create", {
      path: TEST_RESOURCE,
      type: "StyleBoxFlat",
      properties: { corner_radius_top_left: 4 },
      overwrite: true,
    });
    assertEq(r.path, TEST_RESOURCE);
  });

  await test("resource.set_property updates .tres", async () => {
    await c.call("resource.set_property", {
      path: TEST_RESOURCE,
      property: "corner_radius_top_right",
      value: 8,
    });
  });

  await test("input_map add/list/remove cycle", async () => {
    await c.call("input_map.add_action", { name: "smoketest_action" });
    await c.call("input_map.add_event", {
      action: "smoketest_action",
      event: { type: "key", keycode: "J" },
    });
    const r = await c.call("input_map.list");
    const found = r.actions.find((a) => a.name === "smoketest_action");
    assert(found, "action not found in list");
    assertEq(found.events.length, 1);
    await c.call("input_map.remove_action", { name: "smoketest_action" });
  });

  await test("input_map remove_event by index", async () => {
    await c.call("input_map.add_action", { name: "smoketest_multi" });
    await c.call("input_map.add_event", {
      action: "smoketest_multi",
      event: { type: "key", keycode: "A" },
    });
    await c.call("input_map.add_event", {
      action: "smoketest_multi",
      event: { type: "key", keycode: "B" },
    });
    await c.call("input_map.remove_event", { action: "smoketest_multi", event_index: 0 });
    const r = await c.call("input_map.list");
    const action = r.actions.find((a) => a.name === "smoketest_multi");
    assertEq(action.events.length, 1);
    await c.call("input_map.remove_action", { name: "smoketest_multi" });
  });

  await test("scene.get_property reads position", async () => {
    // re-add Title under root since we removed it earlier
    await c.call("scene.add_node", { type: "Node2D", name: "Pivot" });
    await c.call("scene.set_property", {
      node_path: "Pivot",
      property: "position",
      value: [50, 75],
    });
    const r = await c.call("scene.get_property", {
      node_path: "Pivot",
      property: "position",
    });
    assertEq(r.type, "Vector2");
    assert(String(r.value).includes("50"));
  });

  await test("scene.duplicate_node clones Pivot", async () => {
    const r = await c.call("scene.duplicate_node", {
      node_path: "Pivot",
      new_name: "PivotClone",
    });
    assertEq(r.name, "PivotClone");
    const current = await c.call("scene.inspect");
    assert(current.root.children.some((c) => c.name === "PivotClone"), "clone should be in tree");
  });

  await test("animation.add_animation + list", async () => {
    await c.call("scene.add_node", { type: "AnimationPlayer", name: "Anim" });
    await c.call("animation.add_animation", {
      node_path: "Anim",
      name: "bounce",
      length: 1.5,
    });
    const r = await c.call("animation.list", { node_path: "Anim" });
    assert(r.animations.some((a) => a.name === "bounce"));
  });

  await test("animation.add_value_track + keyframes", async () => {
    const r = await c.call("animation.add_value_track", {
      node_path: "Anim",
      animation: "bounce",
      target_node: "Pivot",
      property: "position",
      keyframes: [
        { time: 0, value: [0, 0] },
        { time: 0.5, value: [100, 50] },
        { time: 1, value: [0, 0] },
      ],
    });
    assertEq(r.keyframes_added, 3);
    const list = await c.call("animation.list", { node_path: "Anim" });
    const bounce = list.animations.find((a) => a.name === "bounce");
    assertEq(bounce.tracks.length, 1);
    assertEq(bounce.tracks[0].key_count, 3);
  });

  await test("animation.remove_animation", async () => {
    await c.call("animation.remove_animation", { node_path: "Anim", name: "bounce" });
    const r = await c.call("animation.list", { node_path: "Anim" });
    assert(!r.animations.some((a) => a.name === "bounce"));
  });

  await test("scene.capture_screenshot writes PNG", async () => {
    const r = await c.call("scene.capture_screenshot", {
      output: `${TEST_DIR}/shot.png`,
    });
    assert(r.width > 0 && r.height > 0);
  });

  await test("editor.save_all_scenes", async () => {
    const r = await c.call("editor.save_all_scenes");
    assertEq(r.saved, true);
  });

  await test("fs.list with glob", async () => {
    const r = await c.call("fs.list", {
      type: "scene",
      glob: `${TEST_DIR}/*.tscn`,
    });
    assert(r.files.length > 0, "should find at least the test scene");
  });

  await test("refs.rename_class dry_run", async () => {
    // Attach a script with class_name so we have something to rename
    await c.call("script.create", {
      path: `${TEST_DIR}/smoke_class.gd`,
      extends: "Node",
      class_name: "SmokeTempClass",
      overwrite: true,
    });
    const r = await c.call("refs.rename_class", {
      from: "SmokeTempClass",
      to: "SmokeRenamed",
      dry_run: true,
    });
    assertEq(r.from, "SmokeTempClass");
    assert(r.would_update.length >= 1);
  });

  // --- cleanup ---
  console.log("\nCleanup:");
  await test("delete __smoketest dir", async () => {
    const projectRoot = path.resolve(process.cwd());
    const dir = path.join(projectRoot, "__smoketest");
    try {
      await fs.rm(dir, { recursive: true, force: true });
    } catch {}
    await c.call("editor.reload_filesystem");
  });

  c.close();

  console.log(`\n${PASSED} passed, ${FAILED} failed`);
  process.exit(FAILED === 0 ? 0 : 1);
}

run().catch((e) => {
  console.error("fatal:", e);
  process.exit(2);
});
