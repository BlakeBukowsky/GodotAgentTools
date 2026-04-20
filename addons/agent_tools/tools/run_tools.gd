@tool
extends RefCounted

# run.scene_headless — run a scene in a headless child process and capture combined
# stdout/stderr. Uses the current editor executable with --headless.
# Params: {path, quit_after_seconds?: 2, extra_args?: []}
# Returns: {exit_code, output, command}
#
# NOTE: This blocks the editor for the duration of the child process. Use small
# quit_after_seconds values (1-3) for smoke tests; longer runs freeze the editor UI.
static func scene_headless(params: Dictionary) -> Dictionary:
	var scene_path: String = params.get("path", "")
	var quit_after_seconds: float = float(params.get("quit_after_seconds", 2.0))
	var extra_args: Array = params.get("extra_args", [])
	if scene_path == "":
		return _err(-32602, "missing 'path'")
	if not ResourceLoader.exists(scene_path, "PackedScene"):
		return _err(-32001, "scene not found: %s" % scene_path)

	# --quit-after takes frames. Assume 60 fps for the conversion; close enough for smoke tests.
	var frames: int = max(1, int(round(quit_after_seconds * 60.0)))

	var exe := OS.get_executable_path()
	var project_dir := ProjectSettings.globalize_path("res://")
	var args: Array = [
		"--path", project_dir,
		"--headless",
		"--quit-after", str(frames),
	]
	for a in extra_args:
		args.append(str(a))
	args.append(scene_path)

	var output: Array = []
	var exit_code := OS.execute(exe, args, output, true)  # read_stderr = true

	return _ok({
		"exit_code": exit_code,
		"output": output[0] if output.size() > 0 else "",
		"command": "%s %s" % [exe, " ".join(args)],
		"quit_after_frames": frames,
	})


static func _ok(data) -> Dictionary:
	return {"data": data}


static func _err(code: int, msg: String) -> Dictionary:
	return {"error": {"code": code, "message": msg}}
