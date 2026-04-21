@tool
extends RefCounted

# run.scene_headless — run a scene in a child process and capture structured results.
#
# MODES
#   BARE (no input_script / screenshot / screenshots / state_dump):
#     Runs the target directly with --headless. Fast, no window. Right for
#     "does _ready not crash" checks.
#
#   DRIVEN (anything beyond "path" and "quit_after_seconds"):
#     Runs the target under a shipped wrapper driver (addons/agent_tools/headless/
#     driver.tscn) that reads a per-call config, injects scripted input per frame,
#     captures one or more screenshots, and dumps final scene state on quit.
#
# SCREENSHOT NOTE
#   Godot 4.6's --headless forces a Dummy renderer that makes captures impossible.
#   When any screenshot is requested the subprocess runs WITH a visible window
#   positioned at -9999,-9999 (offscreen on multi-monitor setups) and the real
#   Vulkan/OpenGL renderer. Brief window flash is unavoidable.
#
# Params:
#   path:                required, "res://scene.tscn"
#   quit_after_seconds:  default 2.0
#   extra_args:          additional CLI args passed to the child godot process
#   input_script:        [{frame, type, ...}, ...]  see event shapes below
#   screenshot:          single output PNG path (shorthand for one capture at quit_frame)
#   screenshots:         [{frame, path}, ...]  multiple captures at specific frames
#   resolution:          "WxH", default "320x240". Only applies when screenshots requested.
#   state_dump:          bool, default false. When true, driver writes a JSON snapshot
#                        of the final scene tree (name/class/node_path/script/common
#                        properties) that the tool returns as result.final_state.
#   seed:                int, optional. Seeds the global RNG before instancing the
#                        target so runs are reproducible.
#
# Event types for input_script:
#   {frame, type: "action_tap",     action}
#   {frame, type: "action_press",   action, strength?}
#   {frame, type: "action_release", action}
#   {frame, type: "key",            keycode, pressed?: true}
#   {frame, type: "mouse_click",    position: [x, y], button?: 1}
#   {frame, type: "mouse_motion",   position: [x, y]}
#
# Return includes: exit_code, output (stdout/stderr), command, errors, warnings,
#   screenshots (array of {frame, path, captured: bool}), final_state (if state_dump),
#   mode, quit_after_frames.

const STATE_DUMP_PATH := "res://.godot/agent_tools/headless/state_dump.json"


static func scene_headless(params: Dictionary) -> Dictionary:
	var scene_path: String = params.get("path", "")
	var quit_after_seconds: float = float(params.get("quit_after_seconds", 2.0))
	var extra_args: Array = params.get("extra_args", [])
	var input_script = params.get("input_script", null)
	var resolution: String = params.get("resolution", "320x240")
	var state_dump: bool = params.get("state_dump", false)
	var rng_seed = params.get("seed", null)

	# Normalize both screenshot forms into a single list.
	var screenshots: Array = []
	var single_shot: String = params.get("screenshot", "")
	if single_shot != "":
		screenshots.append({"frame": int(round(quit_after_seconds * 60.0)), "path": single_shot})
	var multi: Array = params.get("screenshots", [])
	for s in multi:
		if typeof(s) != TYPE_DICTIONARY or not s.has("frame") or not s.has("path"):
			return _err(-32602, "each 'screenshots' entry needs {frame, path}")
		screenshots.append({"frame": int(s.frame), "path": str(s.path)})

	if scene_path == "":
		return _err(-32602, "missing 'path'")
	if not ResourceLoader.exists(scene_path, "PackedScene"):
		return _err(-32001, "scene not found: %s" % scene_path)

	var frames: int = max(1, int(round(quit_after_seconds * 60.0)))
	var use_driver := input_script != null or not screenshots.is_empty() or state_dump or rng_seed != null
	var needs_window := not screenshots.is_empty()

	var run_scene_path := scene_path
	if use_driver:
		# Wipe any stale state dump from prior run so "file exists" is a reliable signal.
		if FileAccess.file_exists(STATE_DUMP_PATH):
			@warning_ignore("return_value_discarded")
			DirAccess.remove_absolute(STATE_DUMP_PATH)
		# Strict-typed arg: can't pass a Variant-valued ternary directly into an
		# Array param (parse error). Normalize first.
		var script_list: Array = []
		if input_script is Array:
			script_list = input_script
		var prep := _prepare_driver_config(scene_path, script_list, frames, screenshots, state_dump, rng_seed)
		if prep.has("_error"):
			return _err(-32001, prep._error)
		run_scene_path = "res://addons/agent_tools/headless/driver.tscn"

	var exe := OS.get_executable_path()
	var project_dir := ProjectSettings.globalize_path("res://")
	var hard_quit_frames: int = frames + 30

	var args: Array = ["--path", project_dir]
	if needs_window:
		# Real renderer required for screenshots; run windowed but offscreen.
		args.append("--windowed")
		args.append("--resolution")
		args.append(resolution)
		args.append("--position")
		args.append("-9999,-9999")
	else:
		args.append("--headless")
	args.append("--quit-after")
	args.append(str(hard_quit_frames))
	for a in extra_args:
		args.append(str(a))
	args.append(run_scene_path)

	var output: Array = []
	var exit_code := OS.execute(exe, args, output, true)
	# str() always returns a String; avoids Variant-via-ternary parse issue.
	var stdout: String = ""
	if output.size() > 0:
		stdout = str(output[0])

	var diagnostics := _extract_diagnostics(stdout)

	var result: Dictionary = {
		"exit_code": exit_code,
		"output": stdout,
		"command": "%s %s" % [exe, " ".join(args)],
		"quit_after_frames": frames,
		"mode": "driven" if use_driver else "bare",
		"errors": diagnostics.errors,
		"warnings": diagnostics.warnings,
	}
	if use_driver:
		result["driver_scene"] = run_scene_path
	if not screenshots.is_empty():
		var shot_results: Array = []
		for s in screenshots:
			shot_results.append({
				"frame": s.frame,
				"path": s.path,
				"captured": FileAccess.file_exists(s.path),
			})
		result["screenshots"] = shot_results
	if state_dump:
		# = not := — _load_state_dump has no return annotation so := can't infer.
		var state = _load_state_dump()
		if state != null:
			result["final_state"] = state
	return _ok(result)


static func _prepare_driver_config(target: String, input_script: Array, quit_frame: int, screenshots: Array, state_dump: bool, rng_seed) -> Dictionary:
	var cfg_dir := "res://.godot/agent_tools/headless"
	if not DirAccess.dir_exists_absolute(cfg_dir):
		var derr := DirAccess.make_dir_recursive_absolute(cfg_dir)
		if derr != OK:
			return {"_error": "mkdir failed for %s (%d)" % [cfg_dir, derr]}

	var config := {
		"target_scene": target,
		"input_script": input_script,
		"quit_frame": quit_frame,
		"screenshots": screenshots,
		"state_dump": state_dump,
		"state_dump_path": STATE_DUMP_PATH,
	}
	if rng_seed != null:
		config["seed"] = int(rng_seed)

	var cfg_path := cfg_dir + "/config.json"
	var f := FileAccess.open(cfg_path, FileAccess.WRITE)
	if f == null:
		return {"_error": "failed to write driver config at %s" % cfg_path}
	f.store_string(JSON.stringify(config, "  "))
	f.close()
	return {"config_path": cfg_path}


# Parse Godot's stdout for ERROR:/WARNING:/SCRIPT ERROR:/USER ERROR:/USER WARNING: lines.
# Returns {errors: [{category, message, context}], warnings: [{category, message}]}.
# Context is the next line if it starts with whitespace (typical "at: file:line" trailer).
static func _extract_diagnostics(stdout: String) -> Dictionary:
	var errors: Array = []
	var warnings: Array = []
	var lines: PackedStringArray = stdout.split("\n")
	var i := 0
	while i < lines.size():
		var line: String = lines[i].trim_suffix("\r")
		var category := ""
		var is_error := false
		var is_warning := false
		for prefix in ["ERROR:", "USER ERROR:", "SCRIPT ERROR:"]:
			if line.begins_with(prefix):
				category = prefix.trim_suffix(":")
				is_error = true
				break
		if not is_error:
			for prefix in ["WARNING:", "USER WARNING:"]:
				if line.begins_with(prefix):
					category = prefix.trim_suffix(":")
					is_warning = true
					break
		if is_error or is_warning:
			var msg: String = line.substr(category.length() + 1).strip_edges()
			var context := ""
			if i + 1 < lines.size():
				var next := lines[i + 1].trim_suffix("\r")
				if next.begins_with("   ") or next.begins_with("\t"):
					context = next.strip_edges()
					i += 1
			if is_error:
				errors.append({"category": category, "message": msg, "context": context})
			else:
				warnings.append({"category": category, "message": msg, "context": context})
		i += 1
	return {"errors": errors, "warnings": warnings}


static func _load_state_dump():
	if not FileAccess.file_exists(STATE_DUMP_PATH):
		return null
	var f := FileAccess.open(STATE_DUMP_PATH, FileAccess.READ)
	if f == null:
		return null
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return null
	return parsed


static func _ok(data) -> Dictionary:
	return {"data": data}


static func _err(code: int, msg: String) -> Dictionary:
	return {"error": {"code": code, "message": msg}}
