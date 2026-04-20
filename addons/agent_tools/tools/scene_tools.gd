@tool
extends RefCounted

# scene.inspect — read-only. Accepts {"path": "res://..."} or omits path to use the currently-edited scene.
#   Returns {root: <NodeDict>, path: "<scene_file_path>"} where NodeDict = {name, class, node_path, script, children}.
static func inspect(params: Dictionary) -> Dictionary:
	var path: String = params.get("path", "")
	var root: Node
	var owns_root := false
	var scene_file_path: String

	if path == "":
		root = EditorInterface.get_edited_scene_root()
		if root == null:
			return _err(-32001, "no scene open and no 'path' provided")
		scene_file_path = root.scene_file_path
	else:
		var packed := ResourceLoader.load(path, "PackedScene") as PackedScene
		if packed == null:
			return _err(-32001, "failed to load scene: %s" % path)
		root = packed.instantiate(PackedScene.GEN_EDIT_STATE_DISABLED)
		if root == null:
			return _err(-32001, "instantiate failed: %s" % path)
		owns_root = true
		scene_file_path = path

	var tree := _node_to_dict(root, root)
	if owns_root:
		root.free()
	return _ok({"path": scene_file_path, "root": tree})


static func _node_to_dict(node: Node, scene_root: Node) -> Dictionary:
	var d := {
		"name": String(node.name),
		"class": node.get_class(),
		"node_path": "." if node == scene_root else String(scene_root.get_path_to(node)),
		"script": "",
		"children": [],
	}
	var scr := node.get_script() as Script
	if scr:
		d.script = scr.resource_path
	for child in node.get_children():
		# Only include nodes belonging to this scene (skip runtime-added children of instanced sub-scenes).
		if child.owner == scene_root or child == scene_root:
			d.children.append(_node_to_dict(child, scene_root))
	return d


# scene.add_node — operates on the currently-edited scene.
# Params: {type: "Node2D", name?: "Foo", parent_path?: "."}
static func add_node(params: Dictionary) -> Dictionary:
	var node_type: String = params.get("type", "")
	var node_name: String = params.get("name", "")
	var parent_path: String = params.get("parent_path", ".")

	if node_type == "":
		return _err(-32602, "missing 'type'")
	if not ClassDB.class_exists(node_type):
		return _err(-32602, "unknown class: %s" % node_type)
	if not ClassDB.is_parent_class(node_type, "Node"):
		return _err(-32602, "type must derive from Node: %s" % node_type)
	if not ClassDB.can_instantiate(node_type):
		return _err(-32602, "class is not instantiable: %s" % node_type)

	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return _err(-32001, "no scene open")

	var parent: Node = root if parent_path == "." or parent_path == "" else root.get_node_or_null(parent_path)
	if parent == null:
		return _err(-32001, "parent not found: %s" % parent_path)

	var inst := ClassDB.instantiate(node_type) as Node
	if inst == null:
		return _err(-32001, "failed to instantiate %s" % node_type)

	parent.add_child(inst)
	if node_name != "":
		inst.name = node_name
	# Owner MUST be set to the scene root, otherwise the node won't be saved.
	inst.owner = root

	EditorInterface.mark_scene_as_unsaved()
	return _ok({
		"node_path": String(root.get_path_to(inst)),
		"name": String(inst.name),
		"class": inst.get_class(),
	})


# scene.set_property — operates on the currently-edited scene.
# Params: {node_path: "Player/Sprite2D", property: "position", value: [10, 20]}
# Coercion rules for common types:
#   bool/int/float/string  — JSON primitives
#   Vector2                — [x, y]
#   Vector3                — [x, y, z]
#   Color                  — [r, g, b] or [r, g, b, a] or "#rrggbb"/"#rrggbbaa"
#   NodePath               — string
# Other types are passed through as-is (useful for Dictionary/Array props).
static func set_property(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	var property_name: String = params.get("property", "")
	if node_path == "" or property_name == "":
		return _err(-32602, "missing 'node_path' or 'property'")

	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return _err(-32001, "no scene open")

	var node: Node = root if node_path == "." else root.get_node_or_null(node_path)
	if node == null:
		return _err(-32001, "node not found: %s" % node_path)

	var prop_info: Dictionary = {}
	for p in node.get_property_list():
		if p.name == property_name:
			prop_info = p
			break
	if prop_info.is_empty():
		return _err(-32602, "property not found on %s: %s" % [node.get_class(), property_name])

	var coerced = _coerce(params.get("value"), prop_info.type)
	if coerced is Dictionary and coerced.has("_error"):
		return _err(-32602, coerced._error)

	node.set(property_name, coerced)
	EditorInterface.mark_scene_as_unsaved()

	return _ok({
		"node_path": node_path,
		"property": property_name,
		"value": node.get(property_name),
	})


# scene.remove_node — operates on the currently-edited scene. Cannot remove the scene root.
# Params: {node_path: "Player/Sprite2D"}
static func remove_node(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	if node_path == "":
		return _err(-32602, "missing 'node_path'")
	if node_path == ".":
		return _err(-32602, "cannot remove scene root")

	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return _err(-32001, "no scene open")
	var node: Node = root.get_node_or_null(node_path)
	if node == null:
		return _err(-32001, "node not found: %s" % node_path)

	node.get_parent().remove_child(node)
	node.queue_free()
	EditorInterface.mark_scene_as_unsaved()
	return _ok({"removed": node_path})


# scene.reparent — move a node under a new parent in the currently-edited scene.
# Params: {node_path, new_parent_path, keep_global_transform?: true}
static func reparent(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	var new_parent_path: String = params.get("new_parent_path", "")
	var keep_xform: bool = params.get("keep_global_transform", true)
	if node_path == "" or new_parent_path == "":
		return _err(-32602, "missing 'node_path' or 'new_parent_path'")
	if node_path == ".":
		return _err(-32602, "cannot reparent scene root")

	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return _err(-32001, "no scene open")
	var node: Node = root.get_node_or_null(node_path)
	if node == null:
		return _err(-32001, "node not found: %s" % node_path)
	var new_parent: Node = root if new_parent_path == "." else root.get_node_or_null(new_parent_path)
	if new_parent == null:
		return _err(-32001, "new parent not found: %s" % new_parent_path)
	if new_parent == node or node.is_ancestor_of(new_parent):
		return _err(-32602, "cannot reparent under self or descendant (would create cycle)")

	node.reparent(new_parent, keep_xform)
	# reparent() preserves owner in 4.3+, but be explicit so the node still serializes.
	node.owner = root
	EditorInterface.mark_scene_as_unsaved()
	return _ok({"node_path": String(root.get_path_to(node))})


# scene.open — open a scene in the editor, making it the currently-edited scene.
# Params: {path: "res://Main.tscn"}
static func open_scene(params: Dictionary) -> Dictionary:
	var path: String = params.get("path", "")
	if path == "":
		return _err(-32602, "missing 'path'")
	if not ResourceLoader.exists(path, "PackedScene"):
		return _err(-32001, "scene not found: %s" % path)
	EditorInterface.open_scene_from_path(path)
	return _ok({"path": path})


# scene.save — save the currently-edited scene. Pass 'path' to save-as (rebinds the scene to that path).
static func save_scene(params: Dictionary) -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return _err(-32001, "no scene open")
	var path: String = params.get("path", "")
	if path == "":
		var err := EditorInterface.save_scene()
		if err != OK:
			return _err(-32001, "save failed: error %d" % err)
	else:
		# save_scene_as returns void in Godot 4.x — no error to check.
		EditorInterface.save_scene_as(path)
	return _ok({"path": EditorInterface.get_edited_scene_root().scene_file_path})


# scene.new — create a new .tscn file with a root node of the given type. By default
# opens the new scene in the editor so subsequent scene.* calls operate on it.
# Params: {path, root_type?: "Node", root_name?, overwrite?: false, open_after?: true}
static func new_scene(params: Dictionary) -> Dictionary:
	var path: String = params.get("path", "")
	var root_type: String = params.get("root_type", "Node")
	var root_name: String = params.get("root_name", "")
	var overwrite: bool = params.get("overwrite", false)
	var open_after: bool = params.get("open_after", true)

	if path == "" or not path.begins_with("res://") or not path.ends_with(".tscn"):
		return _err(-32602, "'path' must be 'res://...' ending in .tscn")
	if FileAccess.file_exists(path) and not overwrite:
		return _err(-32602, "file exists (pass overwrite:true to replace): %s" % path)
	if not ClassDB.class_exists(root_type):
		return _err(-32602, "unknown class: %s" % root_type)
	if not ClassDB.is_parent_class(root_type, "Node"):
		return _err(-32602, "root_type must derive from Node: %s" % root_type)
	if not ClassDB.can_instantiate(root_type):
		return _err(-32602, "class is not instantiable: %s" % root_type)

	var root := ClassDB.instantiate(root_type) as Node
	if root == null:
		return _err(-32001, "failed to instantiate %s" % root_type)
	if root_name != "":
		root.name = root_name

	var dir_path := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		var derr := DirAccess.make_dir_recursive_absolute(dir_path)
		if derr != OK:
			root.free()
			return _err(-32001, "mkdir failed (%d): %s" % [derr, dir_path])

	var packed := PackedScene.new()
	var pack_err := packed.pack(root)
	var final_name := String(root.name)
	root.free()
	if pack_err != OK:
		return _err(-32001, "PackedScene.pack failed: %d" % pack_err)
	var save_err := ResourceSaver.save(packed, path)
	if save_err != OK:
		return _err(-32001, "ResourceSaver.save failed: %d" % save_err)

	EditorInterface.get_resource_filesystem().update_file(path)
	if open_after:
		EditorInterface.open_scene_from_path(path)
	return _ok({"path": path, "root_type": root_type, "root_name": final_name})


# scene.instance_packed — add an existing .tscn as a sub-scene child in the currently-edited scene.
# Params: {scene_path, parent_path?: ".", name?}
static func instance_packed(params: Dictionary) -> Dictionary:
	var scene_path: String = params.get("scene_path", "")
	var parent_path: String = params.get("parent_path", ".")
	var node_name: String = params.get("name", "")

	if scene_path == "":
		return _err(-32602, "missing 'scene_path'")
	var packed := ResourceLoader.load(scene_path, "PackedScene") as PackedScene
	if packed == null:
		return _err(-32001, "failed to load scene: %s" % scene_path)

	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return _err(-32001, "no scene open")
	var parent: Node = root if parent_path == "." or parent_path == "" else root.get_node_or_null(parent_path)
	if parent == null:
		return _err(-32001, "parent not found: %s" % parent_path)
	if scene_path == root.scene_file_path:
		return _err(-32602, "cannot instance a scene into itself (would recurse)")

	var inst := packed.instantiate()
	if inst == null:
		return _err(-32001, "instantiate failed")

	parent.add_child(inst)
	if node_name != "":
		inst.name = node_name
	# Owner is the scene root so the sub-scene instance serializes with this scene.
	inst.owner = root
	EditorInterface.mark_scene_as_unsaved()
	return _ok({
		"node_path": String(root.get_path_to(inst)),
		"scene_path": scene_path,
		"name": String(inst.name),
	})


# scene.current — describe the currently-edited scene, or {open: false} if none.
static func current(_params: Dictionary) -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return _ok({"open": false})
	return _ok({
		"open": true,
		"path": root.scene_file_path,
		"root_name": String(root.name),
		"root_class": root.get_class(),
	})


static func _coerce(value, target_type: int):
	match target_type:
		TYPE_BOOL:
			return bool(value)
		TYPE_INT:
			return int(value)
		TYPE_FLOAT:
			return float(value)
		TYPE_STRING, TYPE_STRING_NAME:
			return String(value)
		TYPE_NODE_PATH:
			return NodePath(String(value))
		TYPE_VECTOR2:
			if value is Array and value.size() == 2:
				return Vector2(value[0], value[1])
			return {"_error": "Vector2 expects [x, y]"}
		TYPE_VECTOR2I:
			if value is Array and value.size() == 2:
				return Vector2i(int(value[0]), int(value[1]))
			return {"_error": "Vector2i expects [x, y]"}
		TYPE_VECTOR3:
			if value is Array and value.size() == 3:
				return Vector3(value[0], value[1], value[2])
			return {"_error": "Vector3 expects [x, y, z]"}
		TYPE_COLOR:
			if value is Array and (value.size() == 3 or value.size() == 4):
				var a := float(value[3]) if value.size() == 4 else 1.0
				return Color(value[0], value[1], value[2], a)
			if value is String:
				return Color(value)
			return {"_error": "Color expects [r,g,b(,a)] or '#rrggbb(aa)'"}
		_:
			return value


static func _ok(data) -> Dictionary:
	return {"data": data}


static func _err(code: int, msg: String) -> Dictionary:
	return {"error": {"code": code, "message": msg}}
