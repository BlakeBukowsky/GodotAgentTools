@tool
extends RefCounted

# script.create — write a new .gd file with an extends/class_name header.
# Params: {path: "res://scripts/Player.gd", extends?: "Node", class_name?: "Player",
#          attach_to_node?: "Player", overwrite?: false}
static func create(params: Dictionary) -> Dictionary:
	var path: String = params.get("path", "")
	var base_class: String = params.get("extends", "Node")
	var class_name_val: String = params.get("class_name", "")
	var overwrite: bool = params.get("overwrite", false)
	var attach_to: String = params.get("attach_to_node", "")

	if path == "" or not path.begins_with("res://") or not path.ends_with(".gd"):
		return _err(-32602, "'path' must be 'res://...' ending in .gd")
	if FileAccess.file_exists(path) and not overwrite:
		return _err(-32602, "file exists (pass overwrite:true to replace): %s" % path)

	var dir_path := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		var derr := DirAccess.make_dir_recursive_absolute(dir_path)
		if derr != OK:
			return _err(-32001, "mkdir failed (%d): %s" % [derr, dir_path])

	var body := "extends %s\n" % base_class
	if class_name_val != "":
		body += "class_name %s\n" % class_name_val
	body += "\n"

	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return _err(-32001, "failed to open for write: %s" % path)
	f.store_string(body)
	f.close()

	# Let the editor discover the new file so load() succeeds immediately.
	EditorInterface.get_resource_filesystem().update_file(path)

	var data := {"path": path, "extends": base_class, "class_name": class_name_val}

	if attach_to != "":
		var attach_res := _attach_script_to_node(attach_to, path)
		if attach_res.has("error"):
			return attach_res
		data["attached_to"] = attach_to

	return _ok(data)


# script.attach — attach an existing script to a node in the currently-edited scene.
# Params: {node_path, script_path}
static func attach(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	var script_path: String = params.get("script_path", "")
	if node_path == "" or script_path == "":
		return _err(-32602, "missing 'node_path' or 'script_path'")
	return _attach_script_to_node(node_path, script_path)


# script.patch — targeted edits to an existing .gd file. Two modes:
#   replacements: [{old, new}] — each 'old' must appear exactly once in the file;
#                                 fails atomically if any replacement is ambiguous
#                                 or missing. Useful for surgical edits.
#   full_source:  string       — overwrite the whole file (same as script.create
#                                 overwrite, kept here for symmetry).
# After writing, the tool parse-checks the result via ResourceLoader.load(); if
# that fails, the original file is restored and an error is returned.
# Params: {path, replacements?: [{old, new}], full_source?: string, dry_run?: false}
static func patch(params: Dictionary) -> Dictionary:
	var path: String = params.get("path", "")
	var replacements: Array = params.get("replacements", [])
	var full_source: String = params.get("full_source", "")
	var dry_run: bool = params.get("dry_run", false)

	if path == "" or not path.ends_with(".gd"):
		return _err(-32602, "'path' must be a .gd file")
	if not FileAccess.file_exists(path):
		return _err(-32001, "file not found: %s" % path)
	if replacements.is_empty() and full_source == "":
		return _err(-32602, "provide either 'replacements' or 'full_source'")

	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return _err(-32001, "could not read %s" % path)
	var original := f.get_as_text()
	f.close()

	var patched: String = original
	var applied: Array = []
	if full_source != "":
		patched = full_source
		applied.append("full_source")
	else:
		for entry in replacements:
			if typeof(entry) != TYPE_DICTIONARY or not entry.has("old") or not entry.has("new"):
				return _err(-32602, "each replacement needs {old, new}")
			var needle: String = str(entry.old)
			var replacement: String = str(entry.new)
			var count := patched.count(needle)
			if count == 0:
				return _err(-32602, "'old' string not found (would leave file unchanged): %s" % needle.substr(0, 60))
			if count > 1:
				return _err(-32602, "'old' string appears %d times — ambiguous. Include more context to make it unique: %s" % [count, needle.substr(0, 60)])
			patched = patched.replace(needle, replacement)
			applied.append("replaced %d chars" % needle.length())

	if patched == original:
		return _ok({"path": path, "changed": false, "note": "patched content identical to original"})

	if dry_run:
		return _ok({
			"path": path,
			"changed": true,
			"applied": applied,
			"new_length": patched.length(),
			"original_length": original.length(),
		})

	# Write, then parse-check. If parse fails, restore.
	var wf := FileAccess.open(path, FileAccess.WRITE)
	if wf == null:
		return _err(-32001, "could not write %s" % path)
	wf.store_string(patched)
	wf.close()

	EditorInterface.get_resource_filesystem().update_file(path)
	# Force a fresh parse — ResourceLoader.load returns a cached/placeholder
	# Script for malformed sources, so we can't just null-check. Call reload()
	# which actually re-parses and returns an Error.
	var check := ResourceLoader.load(path, "Script", ResourceLoader.CACHE_MODE_REPLACE)
	var parse_ok := false
	if check != null and check is GDScript:
		parse_ok = (check.reload(true) == OK)
	if not parse_ok:
		# Restore original to keep the file loadable.
		var rf := FileAccess.open(path, FileAccess.WRITE)
		if rf:
			rf.store_string(original)
			rf.close()
			EditorInterface.get_resource_filesystem().update_file(path)
		return _err(-32001, "patched script failed to parse — changes rolled back. Check Godot's Output panel for the exact error.")

	return _ok({
		"path": path,
		"changed": true,
		"applied": applied,
		"new_length": patched.length(),
	})


static func _attach_script_to_node(node_path: String, script_path: String) -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return _err(-32001, "no scene open")
	var node: Node = root if node_path == "." else root.get_node_or_null(node_path)
	if node == null:
		return _err(-32001, "node not found: %s" % node_path)
	var script := ResourceLoader.load(script_path, "Script") as Script
	if script == null:
		return _err(-32001, "failed to load script: %s" % script_path)
	node.set_script(script)
	EditorInterface.mark_scene_as_unsaved()
	return _ok({"node_path": node_path, "script": script_path})


static func _ok(data) -> Dictionary:
	return {"data": data}


static func _err(code: int, msg: String) -> Dictionary:
	return {"error": {"code": code, "message": msg}}
