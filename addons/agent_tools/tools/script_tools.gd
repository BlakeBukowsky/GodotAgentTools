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
