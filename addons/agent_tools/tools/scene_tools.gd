@tool
extends RefCounted

const Coerce := preload("res://addons/agent_tools/tools/_coerce.gd")

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
# Params: {node_path, property, value} — value is coerced via Coerce.coerce based on
# the target property's type. See _coerce.gd for the full supported-type list.
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
	# Reject read-only properties upfront — Godot would silently ignore the set().
	if int(prop_info.get("usage", 0)) & PROPERTY_USAGE_READ_ONLY:
		return _err(-32602, "property '%s' on %s is read-only" % [property_name, node.get_class()])

	var coerced = Coerce.coerce(params.get("value"), prop_info.type)
	if coerced is Dictionary and coerced.has("_error"):
		return _err(-32602, coerced._error)

	node.set(property_name, coerced)
	# Safety net: Godot silently drops assignments that don't fit the property type
	# (e.g. non-Resource assigned to a Resource-typed slot). Detect that instead of
	# returning a misleading "value": "<Object#null>" echo.
	var stored = node.get(property_name)
	if coerced != null and stored == null and prop_info.type == TYPE_OBJECT:
		return _err(-32001,
			"property '%s' on %s was not accepted (assignment silently dropped — target expects a %s; passed value type didn't match)" %
			[property_name, node.get_class(), prop_info.get("hint_string", "Resource")])
	EditorInterface.mark_scene_as_unsaved()

	return _ok({
		"node_path": node_path,
		"property": property_name,
		"value": Coerce.to_json(stored),
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


# scene.save — save the currently-edited scene. Pass 'path' to save-as (rebinds
# the scene to that path).
#
# Fresh scenes (created via `scene.add_node`-only workflows with no backing file,
# or never-saved manual scenes) have an empty `scene_file_path`. Godot's bare
# `save_scene()` responds by opening the native Save-As file dialog — blocking
# the editor and requiring a human click. We detect that case and return an
# error instead, so the agent can react cleanly by re-calling with `path`.
static func save_scene(params: Dictionary) -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return _err(-32001, "no scene open")
	var path: String = params.get("path", "")
	var current_path: String = root.scene_file_path

	if path == "" and current_path == "":
		return _err(-32602,
			"scene has never been saved and no 'path' was given. " +
			"Calling bare save would open the Save-As dialog and block the editor. " +
			"Re-call with 'path' set to a res:// target (e.g. 'res://scenes/foo.tscn').")

	if path == "":
		var err := EditorInterface.save_scene()
		if err != OK:
			return _err(-32001, "save failed: error %d" % err)
	else:
		# save_scene_as does NOT auto-create parent directories — it silently
		# fails if the target dir doesn't exist. Ensure the dir first.
		var dir_path := path.get_base_dir()
		if not DirAccess.dir_exists_absolute(dir_path):
			var derr := DirAccess.make_dir_recursive_absolute(dir_path)
			if derr != OK:
				return _err(-32001, "mkdir failed (%d): %s" % [derr, dir_path])
		# save_scene_as returns void in Godot 4.x — no error to check directly.
		EditorInterface.save_scene_as(path)

	var final_path: String = EditorInterface.get_edited_scene_root().scene_file_path
	# If we passed a path but the scene still isn't bound, the save didn't land.
	# Surface that explicitly instead of returning {"path": ""} which looks like success.
	if path != "" and final_path == "":
		return _err(-32001,
			"save_scene_as('%s') did not bind the scene — verify the path is writable and ends in .tscn" % path)
	return _ok({"path": final_path})


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
		# If the target path is already the currently-edited scene, open_scene_from_path
		# will just switch to the existing (stale) in-memory tab. Force a reload so the
		# freshly-written file is what the editor shows.
		var current_root := EditorInterface.get_edited_scene_root()
		if current_root != null and current_root.scene_file_path == path:
			EditorInterface.reload_scene_from_path(path)
		else:
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


# scene.get_property — read a property from a node. Mirror of set_property.
# Params: {node_path, property}
static func get_property(params: Dictionary) -> Dictionary:
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

	var prop_type: int = TYPE_NIL
	var found := false
	for p in node.get_property_list():
		if p.name == property_name:
			prop_type = p.type
			found = true
			break
	if not found:
		return _err(-32602, "property not found on %s: %s" % [node.get_class(), property_name])

	return _ok({
		"node_path": node_path,
		"property": property_name,
		"value": Coerce.to_json(node.get(property_name)),
		"type": type_string(prop_type),
	})


# scene.capture_screenshot — save a PNG of what the editor is currently showing
# for the open scene. Captures the appropriate editor viewport (2D for 2D/Control
# root nodes, 3D for Node3D roots). Includes the editor's grid/gizmos — this is
# "what the user sees" rather than a clean render, which is actually useful for
# the agent to spot layout problems.
# Params: {output?: "res://screenshot.png"}
# Returns: {path, width, height}
static func capture_screenshot(params: Dictionary) -> Dictionary:
	var output_path: String = params.get("output", "")

	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return _err(-32001, "no scene open — open one first with scene.open")

	var viewport: SubViewport
	if root is Node3D:
		viewport = EditorInterface.get_editor_viewport_3d(0)
	else:
		viewport = EditorInterface.get_editor_viewport_2d()
	if viewport == null:
		return _err(-32001, "could not obtain editor viewport")

	var tex := viewport.get_texture()
	if tex == null:
		return _err(-32001, "viewport has no texture yet (try again after the editor renders a frame)")
	var img := tex.get_image()
	if img == null or img.is_empty():
		return _err(-32001, "failed to capture image from viewport")

	if output_path == "":
		var base: String = "screenshot"
		if root.scene_file_path != "":
			base = root.scene_file_path.get_file().get_basename()
		output_path = "res://.godot/agent_tools/%s.png" % base

	var dir_path := output_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		var derr := DirAccess.make_dir_recursive_absolute(dir_path)
		if derr != OK:
			return _err(-32001, "mkdir failed: %d" % derr)

	var save_err := img.save_png(output_path)
	if save_err != OK:
		return _err(-32001, "save_png failed: %d" % save_err)

	return _ok({
		"path": output_path,
		"width": img.get_width(),
		"height": img.get_height(),
		"note": "clean viewport capture (no editor grid/gizmos); empty scenes render as the viewport background color",
	})


# scene.duplicate_node — clone a node (with its descendants) into the currently-edited scene.
# Owner is set recursively so the duplicated subtree serializes with the scene.
# Params: {node_path, new_name?, parent_path?: same parent}
static func duplicate_node(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	var new_name: String = params.get("new_name", "")
	var parent_path: String = params.get("parent_path", "")
	if node_path == "":
		return _err(-32602, "missing 'node_path'")
	if node_path == ".":
		return _err(-32602, "cannot duplicate scene root")

	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return _err(-32001, "no scene open")
	var src: Node = root.get_node_or_null(node_path)
	if src == null:
		return _err(-32001, "node not found: %s" % node_path)

	# DUPLICATE_SIGNALS | DUPLICATE_GROUPS | DUPLICATE_SCRIPTS — default flags.
	var copy: Node = src.duplicate(7)
	if copy == null:
		return _err(-32001, "duplicate() failed")

	var parent: Node = src.get_parent() if parent_path == "" else root.get_node_or_null(parent_path)
	if parent == null:
		return _err(-32001, "parent not found: %s" % parent_path)
	parent.add_child(copy)
	if new_name != "":
		copy.name = new_name
	_set_owner_recursive(copy, root)
	EditorInterface.mark_scene_as_unsaved()
	return _ok({
		"source": node_path,
		"node_path": String(root.get_path_to(copy)),
		"name": String(copy.name),
	})


static func _set_owner_recursive(node: Node, owner: Node) -> void:
	node.owner = owner
	for child in node.get_children():
		_set_owner_recursive(child, owner)


# scene.build_tree — build a subtree in one call.
# Spec is recursive: each entry is {type (required), name?, properties?, script?, children?}.
# Collapses what would otherwise be N scene.add_node + M scene.set_property + K script.attach
# calls into a single request, which matters for any UI-heavy scene where hand-writing the
# tree by calling the atomic tools balloons into dozens of round trips.
# Properties use the same Coerce rules as scene.set_property (Vectors from arrays, Resources
# auto-loaded from res:// paths, etc.).
# On any failure, all nodes created during the call are rolled back so the scene doesn't
# end up partly built.
# Params: {parent_path?: ".", nodes: [TreeNode, ...]}
#   TreeNode: {type: "ClassName", name?, properties?: {name: value}, script?: "res://...", children?: [TreeNode, ...]}
static func build_tree(params: Dictionary) -> Dictionary:
	var parent_path: String = params.get("parent_path", ".")
	var nodes: Array = params.get("nodes", [])
	if nodes.is_empty():
		return _err(-32602, "missing 'nodes' (array of tree entries)")

	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return _err(-32001, "no scene open")
	var parent: Node = root if parent_path == "." or parent_path == "" else root.get_node_or_null(parent_path)
	if parent == null:
		return _err(-32001, "parent not found: %s" % parent_path)

	var created_nodes: Array = []
	var created_paths: Array = []
	for spec in nodes:
		var err_msg := _build_subtree(spec, parent, root, created_nodes, created_paths)
		if err_msg != "":
			# Rollback: free everything created during this call in reverse order.
			for i in range(created_nodes.size() - 1, -1, -1):
				var n: Node = created_nodes[i]
				if is_instance_valid(n):
					if n.get_parent():
						n.get_parent().remove_child(n)
					n.queue_free()
			return _err(-32001, err_msg)

	EditorInterface.mark_scene_as_unsaved()
	return _ok({
		"parent_path": parent_path,
		"created": created_paths,
		"count": created_paths.size(),
	})


# Recursive worker. Appends to the shared created_nodes/created_paths arrays so
# the caller can roll back on failure. Returns "" on success, or an error message.
static func _build_subtree(spec, parent: Node, scene_root: Node, created_nodes: Array, created_paths: Array) -> String:
	if typeof(spec) != TYPE_DICTIONARY:
		return "tree entry must be an object, got %s" % type_string(typeof(spec))

	var node_type: String = spec.get("type", "")
	if node_type == "":
		return "tree entry missing 'type'"
	if not ClassDB.class_exists(node_type):
		return "unknown class: %s" % node_type
	if not ClassDB.is_parent_class(node_type, "Node"):
		return "type must derive from Node: %s" % node_type
	if not ClassDB.can_instantiate(node_type):
		return "class is not instantiable: %s" % node_type

	var inst := ClassDB.instantiate(node_type) as Node
	if inst == null:
		return "failed to instantiate %s" % node_type

	var node_name: String = spec.get("name", "")
	if node_name != "":
		inst.name = node_name

	parent.add_child(inst)
	inst.owner = scene_root
	created_nodes.append(inst)
	var this_path := String(scene_root.get_path_to(inst))
	created_paths.append(this_path)

	# Attach a script before applying properties so script-exported properties
	# become settable in this same call.
	var script_path: String = spec.get("script", "")
	if script_path != "":
		var script := ResourceLoader.load(script_path, "Script") as Script
		if script == null:
			return "failed to load script '%s' for '%s'" % [script_path, this_path]
		inst.set_script(script)

	var properties: Dictionary = spec.get("properties", {})
	if not properties.is_empty():
		var by_name: Dictionary = {}
		for p in inst.get_property_list():
			by_name[p.name] = p
		for prop_name in properties:
			if not by_name.has(prop_name):
				return "property not found on %s ('%s'): %s" % [node_type, this_path, prop_name]
			var prop_info: Dictionary = by_name[prop_name]
			if int(prop_info.get("usage", 0)) & PROPERTY_USAGE_READ_ONLY:
				return "property '%s' on '%s' is read-only" % [prop_name, this_path]
			var coerced = Coerce.coerce(properties[prop_name], prop_info.type)
			if coerced is Dictionary and coerced.has("_error"):
				return "property '%s' on '%s': %s" % [prop_name, this_path, coerced._error]
			inst.set(prop_name, coerced)
			if coerced != null and inst.get(prop_name) == null and prop_info.type == TYPE_OBJECT:
				return "property '%s' on '%s' was not accepted (assignment silently dropped)" % [prop_name, this_path]

	var children: Array = spec.get("children", [])
	for child_spec in children:
		var child_err := _build_subtree(child_spec, inst, scene_root, created_nodes, created_paths)
		if child_err != "":
			return child_err

	return ""


# scene.call_method — invoke a method on a node in the currently-edited scene.
# Args are coerced based on the target method's declared parameter types
# (same rules as scene.set_property — including res:// → Resource auto-load).
# Return value is serialized via Coerce.to_json so the echo is unambiguous data.
# Params: {node_path, method, args?: []}
static func call_method(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	var method_name: String = params.get("method", "")
	var args: Array = params.get("args", [])
	if node_path == "" or method_name == "":
		return _err(-32602, "missing 'node_path' or 'method'")

	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return _err(-32001, "no scene open")
	var node: Node = root if node_path == "." else root.get_node_or_null(node_path)
	if node == null:
		return _err(-32001, "node not found: %s" % node_path)
	if not node.has_method(method_name):
		return _err(-32602, "method not found: %s.%s" % [node.get_class(), method_name])

	# Not typed as Array — _coerce_args returns a Dictionary on error, and strict
	# typing would reject the assignment before we can branch on it.
	var coerced_args = _coerce_args(node, method_name, args)
	if coerced_args is Dictionary:
		return coerced_args  # error passthrough
	var result = node.callv(method_name, coerced_args)
	EditorInterface.mark_scene_as_unsaved()
	return _ok({
		"node_path": node_path,
		"method": method_name,
		"return": Coerce.to_json(result),
	})


# Look up the method's parameter types and coerce each arg accordingly.
# Returns a coerced Array, or a Dictionary with {"error": ...} on failure.
static func _coerce_args(obj: Object, method_name: String, args: Array):
	var method_info: Dictionary = {}
	for m in obj.get_method_list():
		if m.name == method_name:
			method_info = m
			break
	var arg_types: Array = method_info.get("args", [])
	var out: Array = []
	for i in args.size():
		if i < arg_types.size():
			var coerced = Coerce.coerce(args[i], arg_types[i].type)
			if coerced is Dictionary and coerced.has("_error"):
				return _err(-32602, "arg %d: %s" % [i, coerced._error])
			out.append(coerced)
		else:
			out.append(args[i])
	return out


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


static func _ok(data) -> Dictionary:
	return {"data": data}


static func _err(code: int, msg: String) -> Dictionary:
	return {"error": {"code": code, "message": msg}}
