# Auto-run driver for run.scene_headless (input simulation, multi-screenshot,
# state dump, deterministic seed). Reads a per-call config from
# res://.godot/agent_tools/headless/config.json, instances the target scene,
# injects scripted input per frame, captures screenshots at specified frames,
# optionally writes a final-state JSON dump, then quits.

@tool
extends Node

const CONFIG_PATH := "res://.godot/agent_tools/headless/config.json"
const Coerce := preload("res://addons/agent_tools/tools/_coerce.gd")

var _input_script: Array = []
var _screenshots: Array = []  # [{frame, path}, ...]
var _state_dump: bool = false
var _state_dump_path: String = ""
var _quit_frame: int = 120
var _frame: int = 0
var _target_inst: Node = null


func _ready() -> void:
	var f := FileAccess.open(CONFIG_PATH, FileAccess.READ)
	if f == null:
		push_error("[headless_driver] config not found at %s" % CONFIG_PATH)
		get_tree().quit(2)
		return
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("[headless_driver] malformed config")
		get_tree().quit(2)
		return

	# Seed the global RNG before instancing so the target scene's randomness
	# (randi/randf in _ready, etc.) is deterministic per-seed.
	if parsed.has("seed"):
		seed(int(parsed.seed))

	_input_script = parsed.get("input_script", [])
	_screenshots = parsed.get("screenshots", [])
	_state_dump = bool(parsed.get("state_dump", false))
	_state_dump_path = str(parsed.get("state_dump_path", ""))
	_quit_frame = int(parsed.get("quit_frame", 120))
	var target_scene_path: String = parsed.get("target_scene", "")

	if target_scene_path == "":
		push_error("[headless_driver] config missing 'target_scene'")
		get_tree().quit(2)
		return
	var packed = load(target_scene_path)
	if packed == null:
		push_error("[headless_driver] failed to load target %s" % target_scene_path)
		get_tree().quit(2)
		return
	_target_inst = packed.instantiate()
	add_child(_target_inst)
	print("[headless_driver] driving %s for %d frames, %d events, %d screenshots%s" %
		[target_scene_path, _quit_frame, _input_script.size(), _screenshots.size(),
			", state_dump=on" if _state_dump else ""])


func _process(_delta: float) -> void:
	# 1. Inject input events scheduled for this frame.
	for spec in _input_script:
		if int(spec.get("frame", -1)) == _frame:
			_inject(spec)

	# 2. Capture screenshots scheduled for this frame.
	for shot in _screenshots:
		if int(shot.get("frame", -1)) == _frame:
			_capture(str(shot.get("path", "")))

	if _frame >= _quit_frame:
		if _state_dump and _state_dump_path != "":
			_write_state_dump()
		print("[headless_driver] done at frame %d" % _frame)
		get_tree().quit(0)
		return
	_frame += 1


func _inject(spec: Dictionary) -> void:
	match spec.get("type", ""):
		"action_press":
			Input.action_press(spec.get("action", ""), float(spec.get("strength", 1.0)))
		"action_release":
			Input.action_release(spec.get("action", ""))
		"action_tap":
			Input.action_press(spec.get("action", ""), float(spec.get("strength", 1.0)))
			Input.action_release(spec.get("action", ""))
		"key":
			var ek := InputEventKey.new()
			var kc = spec.get("keycode", 0)
			if kc is String:
				ek.physical_keycode = OS.find_keycode_from_string(kc)
			else:
				ek.physical_keycode = int(kc)
			ek.pressed = bool(spec.get("pressed", true))
			Input.parse_input_event(ek)
		"mouse_click":
			var pos = spec.get("position", [0, 0])
			var v := Vector2(pos[0], pos[1])
			var button := int(spec.get("button", 1))
			var down := InputEventMouseButton.new()
			down.button_index = button
			down.pressed = true
			down.position = v
			down.global_position = v
			Input.parse_input_event(down)
			var up := InputEventMouseButton.new()
			up.button_index = button
			up.pressed = false
			up.position = v
			up.global_position = v
			Input.parse_input_event(up)
		"mouse_motion":
			var pos = spec.get("position", [0, 0])
			var em := InputEventMouseMotion.new()
			em.position = Vector2(pos[0], pos[1])
			em.global_position = em.position
			Input.parse_input_event(em)
		_:
			push_warning("[headless_driver] unknown event type: %s" % spec.get("type", "<missing>"))


func _capture(path: String) -> void:
	if path == "":
		return
	var vp := get_tree().root.get_viewport()
	if vp == null:
		push_warning("[headless_driver] no root viewport")
		return
	var tex := vp.get_texture()
	if tex == null:
		push_warning("[headless_driver] viewport has no texture (running under dummy renderer?)")
		return
	var img := tex.get_image()
	if img == null or img.is_empty():
		push_warning("[headless_driver] failed to capture image at frame %d" % _frame)
		return
	var dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var err := img.save_png(path)
	if err != OK:
		push_warning("[headless_driver] save_png failed: %d" % err)
	else:
		print("[headless_driver] frame %d -> %s" % [_frame, path])


func _write_state_dump() -> void:
	if _target_inst == null:
		return
	var snapshot := _node_snapshot(_target_inst, _target_inst)
	var f := FileAccess.open(_state_dump_path, FileAccess.WRITE)
	if f == null:
		push_warning("[headless_driver] failed to open state dump path: %s" % _state_dump_path)
		return
	f.store_string(JSON.stringify(snapshot, "  "))
	f.close()
	print("[headless_driver] state dump -> %s" % _state_dump_path)


# Mirrors scene.inspect's shape, plus a small selection of commonly-useful
# properties. Kept narrow on purpose — full get_property_list() dumps balloon.
static func _node_snapshot(node: Node, scene_root: Node) -> Dictionary:
	var d := {
		"name": String(node.name),
		"class": node.get_class(),
		"node_path": "." if node == scene_root else String(scene_root.get_path_to(node)),
		"script": "",
		"properties": {},
		"children": [],
	}
	var scr := node.get_script() as Script
	if scr:
		d.script = scr.resource_path
	# Common props worth verifying, if present on this node type.
	for prop_name in ["visible", "position", "global_position", "size", "text",
			"value", "modulate", "color", "rotation", "scale", "disabled", "pressed"]:
		if prop_name in node:
			d.properties[prop_name] = Coerce.to_json(node.get(prop_name))
	for child in node.get_children():
		if child.owner == scene_root or child == scene_root:
			d.children.append(_node_snapshot(child, scene_root))
	return d
