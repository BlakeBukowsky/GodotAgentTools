@tool
extends RefCounted

# refs.validate_project — project-wide sweep. No params.
# Returns {checked: int, issues: [{path, kind, ...}]}.
# Kinds: script_parse_error, scene_load_failed, scene_instantiate_failed,
#        resource_load_failed, missing_ext_resource, missing_uid,
#        signal_method_missing, signal_target_missing.
static func validate_project(_params: Dictionary) -> Dictionary:
	var issues: Array = []
	var files: Array = []
	_walk("res://", ["gd", "tscn", "tres"], files)

	for path in files:
		if path.begins_with("res://addons/agent_tools/"):
			continue  # don't validate ourselves
		if path.ends_with(".gd"):
			_check_script(path, issues)
		elif path.ends_with(".tscn"):
			_check_scene(path, issues)
		elif path.ends_with(".tres"):
			_check_resource(path, issues)

	return {"data": {"checked": files.size(), "issues": issues}}


static func _walk(dir_path: String, exts: Array, out: Array) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	while true:
		var name := d.get_next()
		if name == "":
			break
		if name.begins_with("."):
			continue
		var full := dir_path.path_join(name)
		if d.current_is_dir():
			_walk(full, exts, out)
		else:
			for e in exts:
				if name.ends_with("." + e):
					out.append(full)
					break
	d.list_dir_end()


static func _check_script(path: String, issues: Array) -> void:
	# Go through the normal loader so class_name / preload chains resolve against
	# the real global registry. A detached GDScript.new() + reload() would false-positive
	# on any script with class_name (duplicate global class registration).
	var script := ResourceLoader.load(path, "Script")
	if script == null:
		issues.append({"path": path, "kind": "script_load_failed"})


static func _check_scene(path: String, issues: Array) -> void:
	_check_ext_resources_text(path, issues)

	var packed := ResourceLoader.load(path, "PackedScene") as PackedScene
	if packed == null:
		issues.append({"path": path, "kind": "scene_load_failed"})
		return
	var root := packed.instantiate(PackedScene.GEN_EDIT_STATE_DISABLED)
	if root == null:
		issues.append({"path": path, "kind": "scene_instantiate_failed"})
		return
	_walk_scene_signals(root, root, path, issues)
	root.free()


static func _walk_scene_signals(node: Node, scene_root: Node, scene_path: String, issues: Array) -> void:
	for sig in node.get_signal_list():
		var sig_name: String = sig.name
		for c in node.get_signal_connection_list(sig_name):
			var flags: int = c.flags
			if not (flags & CONNECT_PERSIST):
				continue  # ignore runtime-only connections
			var cb: Callable = c.callable
			var target: Object = cb.get_object()
			var method: String = cb.get_method()
			if target == null:
				issues.append({
					"path": scene_path,
					"kind": "signal_target_missing",
					"node": String(scene_root.get_path_to(node)),
					"signal": sig_name,
				})
			elif not target.has_method(method):
				issues.append({
					"path": scene_path,
					"kind": "signal_method_missing",
					"node": String(scene_root.get_path_to(node)),
					"signal": sig_name,
					"method": method,
				})
	for child in node.get_children():
		if child.owner == scene_root or child == scene_root:
			_walk_scene_signals(child, scene_root, scene_path, issues)


static func _check_resource(path: String, issues: Array) -> void:
	var res := ResourceLoader.load(path)
	if res == null:
		issues.append({"path": path, "kind": "resource_load_failed"})


# refs.find_usages — find every file that references a given resource.
# Target may be either a path ("res://player.gd") or a uid ("uid://abc123").
# Searches for both forms so you catch uid-indirected references too.
# Params: {target: "res://..." | "uid://..."}
static func find_usages(params: Dictionary) -> Dictionary:
	var target: String = params.get("target", "")
	if target == "":
		return _err(-32602, "missing 'target'")

	var terms: Array = [target]
	if target.begins_with("uid://"):
		var id := ResourceUID.text_to_id(target)
		if id != -1 and ResourceUID.has_id(id):
			var p := ResourceUID.get_id_path(id)
			if p != "" and p != target:
				terms.append(p)
	else:
		var id := ResourceLoader.get_resource_uid(target)
		if id != -1:
			terms.append(ResourceUID.id_to_text(id))

	var files: Array = []
	_walk("res://", ["gd", "tscn", "tres", "cfg", "gdshader", "gdshaderinc", "cs", "godot"], files)

	var matches: Array = []
	for path in files:
		if path.begins_with("res://addons/agent_tools/"):
			continue
		if path == target:
			continue  # skip the file itself
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		var line_num := 0
		while not f.eof_reached():
			line_num += 1
			var line := f.get_line()
			for term in terms:
				if term in line:
					matches.append({
						"path": path,
						"line": line_num,
						"matched": term,
						"text": line.strip_edges(),
					})
					break

	return _ok({"target": target, "terms_searched": terms, "matches": matches})


# refs.rename — move a file and rewrite all references to it.
# Path-form references are text-replaced; uid-form references keep working because
# the .uid sidecar moves with the file (preserving the UID → new path mapping).
# Params: {from, to, overwrite?: false, dry_run?: false}
static func rename(params: Dictionary) -> Dictionary:
	var from_path: String = params.get("from", "")
	var to_path: String = params.get("to", "")
	var overwrite: bool = params.get("overwrite", false)
	var dry_run: bool = params.get("dry_run", false)

	if from_path == "" or to_path == "":
		return _err(-32602, "missing 'from' or 'to'")
	if not (from_path.begins_with("res://") and to_path.begins_with("res://")):
		return _err(-32602, "paths must be 'res://...'")
	if from_path == to_path:
		return _err(-32602, "'from' and 'to' are the same")
	if not FileAccess.file_exists(from_path):
		return _err(-32001, "source not found: %s" % from_path)
	if FileAccess.file_exists(to_path) and not overwrite:
		return _err(-32602, "destination exists (pass overwrite:true): %s" % to_path)

	# Collect path-form usages. UID-form references are preserved automatically when
	# the .uid sidecar moves with the file, so we don't need to rewrite them.
	var usage := find_usages({"target": from_path})
	if usage.has("error"):
		return usage
	var edits: Dictionary = {}
	for m in usage.data.matches:
		if m.matched != from_path:
			continue  # uid-form match — no rewrite needed
		if not edits.has(m.path):
			edits[m.path] = true

	if dry_run:
		return _ok({
			"would_move": {"from": from_path, "to": to_path},
			"would_update": edits.keys(),
		})

	var dir_path := to_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		var derr := DirAccess.make_dir_recursive_absolute(dir_path)
		if derr != OK:
			return _err(-32001, "mkdir failed (%d): %s" % [derr, dir_path])

	var move_err := DirAccess.rename_absolute(from_path, to_path)
	if move_err != OK:
		return _err(-32001, "move failed (%d)" % move_err)

	# Move .uid sidecar so UIDs continue resolving to the new path.
	var from_uid := from_path + ".uid"
	if FileAccess.file_exists(from_uid):
		DirAccess.rename_absolute(from_uid, to_path + ".uid")
	# Move .import sidecar for imported assets (textures, audio, etc.).
	var from_import := from_path + ".import"
	if FileAccess.file_exists(from_import):
		DirAccess.rename_absolute(from_import, to_path + ".import")

	var files_updated: Array = []
	for ref_path in edits.keys():
		var rf := FileAccess.open(ref_path, FileAccess.READ)
		if rf == null:
			continue
		var content := rf.get_as_text()
		rf.close()
		var new_content := content.replace(from_path, to_path)
		if new_content == content:
			continue
		var wf := FileAccess.open(ref_path, FileAccess.WRITE)
		if wf == null:
			continue
		wf.store_string(new_content)
		wf.close()
		files_updated.append(ref_path)

	EditorInterface.get_resource_filesystem().scan()
	return _ok({
		"moved": {"from": from_path, "to": to_path},
		"files_updated": files_updated,
	})


static func _ok(data) -> Dictionary:
	return {"data": data}


static func _err(code: int, msg: String) -> Dictionary:
	return {"error": {"code": code, "message": msg}}


# Parse the raw .tscn/.tres text for [ext_resource ... path="..."] and verify each target resolves.
# Catches references to files that were deleted or moved without updating the scene.
static func _check_ext_resources_text(path: String, issues: Array) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var text := f.get_as_text()
	var regex := RegEx.new()
	regex.compile("\\[ext_resource[^\\]]*path=\"([^\"]+)\"")
	for m in regex.search_all(text):
		var ref: String = m.get_string(1)
		if ref.begins_with("uid://"):
			var id := ResourceUID.text_to_id(ref)
			if id == -1 or not ResourceUID.has_id(id):
				issues.append({"path": path, "kind": "missing_uid", "uid": ref})
			continue
		if not ResourceLoader.exists(ref):
			issues.append({"path": path, "kind": "missing_ext_resource", "target": ref})
