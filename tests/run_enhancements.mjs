#!/usr/bin/env node
// Exercises the v0.2.1 run.scene_headless enhancements:
//   - resolution
//   - multi-frame screenshots
//   - structured error/warning extraction
//   - final scene-tree state_dump
//   - deterministic seed
//
// Uses raw TCP (not MCP) so the local plugin edits are tested even while the
// published npm MCP shim schema is still at 0.2.0.
//
// Requires the editor open with the plugin enabled. Creates res://__runtest/
// and cleans up after itself.

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
        if (msg.error) p.reject(new Error(`${msg.error.code}: ${msg.error.message}`));
        else p.resolve(msg.result);
      } catch {}
    }
  }
  close() { if (this.s) this.s.end(); }
}

const PASS = [];
const FAIL = [];
async function test(name, fn) {
  process.stdout.write(`  ${name.padEnd(54)} `);
  try { await fn(); console.log("\x1b[32mOK\x1b[0m"); PASS.push(name); }
  catch (e) { console.log(`\x1b[31mFAIL\x1b[0m — ${e.message}`); FAIL.push({ name, err: e.message }); }
}
const assert = (cond, msg) => { if (!cond) throw new Error(msg || "assertion failed"); };
const assertEq = (a, b, msg) => { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(msg || `expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`); };

const TEST_DIR = "res://__runtest";
const TEST_SCENE = `${TEST_DIR}/scene.tscn`;
const TEST_SCRIPT = `${TEST_DIR}/driver.gd`;
const SHOT_DIR = "res://.godot/agent_tools";

const PLUGIN_SCRIPT = `extends Node2D

@onready var _label: Label = $Label
var _frame := 0
var _random_value := 0

func _ready() -> void:
	# Use randi so seed determinism is observable.
	_random_value = randi() % 1000
	_label.text = "boot rand=%d" % _random_value
	push_warning("test warning from _ready")

func _process(_delta: float) -> void:
	_frame += 1
	if _frame == 20:
		_label.text = "frame 20"
	elif _frame == 50:
		_label.text = "frame 50 rand=%d" % _random_value
		push_error("test error at frame 50")
	elif _frame == 100:
		_label.text = "frame 100 rand=%d" % _random_value
`;

async function setup(c) {
  // Fresh test scene + attached script. Can't rely on scene.new writing the
  // scene structure we want, so build_tree after scene.new.
  await c.call("scene.new", { path: TEST_SCENE, root_type: "Node2D", root_name: "Root", overwrite: true });
  await c.call("scene.build_tree", {
    nodes: [
      { type: "Label", name: "Label", properties: { text: "initial", position: [80, 100] } },
      { type: "ColorRect", name: "BG", properties: { color: [0.1, 0.1, 0.2, 1], size: [640, 480] } },
    ],
  });
  // Write the driver script directly; script_create would overwrite body we want.
  const projectRoot = path.resolve(process.cwd());
  const scriptDiskPath = path.join(projectRoot, "__runtest", "driver.gd");
  await fs.mkdir(path.dirname(scriptDiskPath), { recursive: true });
  await fs.writeFile(scriptDiskPath, PLUGIN_SCRIPT);
  await c.call("editor.reload_filesystem");
  await c.call("script.attach", { node_path: ".", script_path: TEST_SCRIPT });
  await c.call("scene.save");
}

async function cleanup(c) {
  const projectRoot = path.resolve(process.cwd());
  try { await fs.rm(path.join(projectRoot, "__runtest"), { recursive: true, force: true }); } catch {}
  try { await fs.rm(path.join(projectRoot, ".godot", "agent_tools"), { recursive: true, force: true }); } catch {}
  await c.call("editor.reload_filesystem");
}

async function run() {
  const c = new Client();
  try { await c.connect(); } catch (e) {
    console.error("Cannot reach Godot plugin. Is the editor open with agent_tools enabled?");
    process.exit(2);
  }
  console.log(`\nConnected. Setting up test scene + driver script...`);
  await setup(c);
  console.log("Running enhancement tests:\n");

  let r1, r2;

  await test("bare run — structured errors from push_error", async () => {
    const r = await c.call("run.scene_headless", {
      path: TEST_SCENE,
      quit_after_seconds: 2,
    });
    assertEq(r.mode, "bare", "should be bare mode");
    assertEq(r.exit_code, 0);
    assert(Array.isArray(r.errors));
    assert(Array.isArray(r.warnings));
    // push_error() produces "ERROR:" lines in stdout (the "USER ERROR" prefix
    // only shows in the editor's Errors panel, not the captured stdout).
    const pushedErr = r.errors.find((e) => e.message.includes("test error at frame 50"));
    assert(pushedErr, `expected to find 'test error at frame 50' in errors, got ${JSON.stringify(r.errors)}`);
    assert(pushedErr.category === "ERROR" || pushedErr.category === "USER ERROR",
      `unexpected category: ${pushedErr.category}`);
    const pushedWarn = r.warnings.find((w) => w.message.includes("test warning from _ready"));
    assert(pushedWarn, `expected to find 'test warning from _ready' in warnings, got ${JSON.stringify(r.warnings)}`);
  });

  await test("driven run — custom resolution + multi-frame screenshots", async () => {
    const r = await c.call("run.scene_headless", {
      path: TEST_SCENE,
      quit_after_seconds: 2,
      resolution: "640x480",
      screenshots: [
        { frame: 25, path: `${SHOT_DIR}/frame25.png` },
        { frame: 60, path: `${SHOT_DIR}/frame60.png` },
        { frame: 110, path: `${SHOT_DIR}/frame110.png` },
      ],
    });
    assertEq(r.mode, "driven");
    assertEq(r.exit_code, 0);
    assertEq(r.screenshots.length, 3);
    for (const shot of r.screenshots) {
      assert(shot.captured, `screenshot for frame ${shot.frame} should exist at ${shot.path}`);
    }
  });

  await test("state_dump returns final scene tree JSON", async () => {
    const r = await c.call("run.scene_headless", {
      path: TEST_SCENE,
      quit_after_seconds: 2,
      state_dump: true,
    });
    assertEq(r.mode, "driven");
    assert(r.final_state, "should have final_state");
    assertEq(r.final_state.name, "Root");
    assertEq(r.final_state.class, "Node2D");
    const labelChild = r.final_state.children.find((ch) => ch.name === "Label");
    assert(labelChild, "Label child should be in state dump");
    // At quit_frame (120), _process has run the frame 100 branch most recently.
    assert(labelChild.properties.text && labelChild.properties.text.startsWith("frame 100"),
      `Label should show frame-100 text, got "${labelChild.properties.text}"`);
  });

  await test("seed determinism — same seed yields same random value in label", async () => {
    r1 = await c.call("run.scene_headless", {
      path: TEST_SCENE,
      quit_after_seconds: 2,
      state_dump: true,
      seed: 42,
    });
    r2 = await c.call("run.scene_headless", {
      path: TEST_SCENE,
      quit_after_seconds: 2,
      state_dump: true,
      seed: 42,
    });
    const t1 = r1.final_state.children.find((ch) => ch.name === "Label").properties.text;
    const t2 = r2.final_state.children.find((ch) => ch.name === "Label").properties.text;
    assertEq(t1, t2, `seed=42 runs should produce identical label text; got "${t1}" vs "${t2}"`);
  });

  await test("seed changes → different random value", async () => {
    const r3 = await c.call("run.scene_headless", {
      path: TEST_SCENE,
      quit_after_seconds: 2,
      state_dump: true,
      seed: 9999,
    });
    const t1 = r1.final_state.children.find((ch) => ch.name === "Label").properties.text;
    const t3 = r3.final_state.children.find((ch) => ch.name === "Label").properties.text;
    assert(t1 !== t3, `different seeds should produce different text; both were "${t1}"`);
  });

  await test("single-shot screenshot shorthand still works", async () => {
    const r = await c.call("run.scene_headless", {
      path: TEST_SCENE,
      quit_after_seconds: 1,
      screenshot: `${SHOT_DIR}/single.png`,
      resolution: "320x240",
    });
    assertEq(r.mode, "driven");
    assertEq(r.screenshots.length, 1);
    assert(r.screenshots[0].captured);
  });

  console.log("\nCleanup:");
  await cleanup(c);
  c.close();
  console.log(`\n${PASS.length} passed, ${FAIL.length} failed`);
  process.exit(FAIL.length === 0 ? 0 : 1);
}

run().catch((e) => { console.error("fatal:", e); process.exit(2); });
