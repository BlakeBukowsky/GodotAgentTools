@tool
extends RefCounted

# Tools for working with AnimationPlayer nodes in the currently-edited scene.
# Animations live in AnimationLibrary resources attached to the player; the "" library
# is the default, named libraries prefix animations as "lib/anim".

# animation.list — list animations on an AnimationPlayer with their tracks.
# Params: {node_path}
static func list_animations(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	if node_path == "":
		return _err(-32602, "missing 'node_path'")
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return _err(-32001, "no scene open")
	var node: Node = root if node_path == "." else root.get_node_or_null(node_path)
	if node == null:
		return _err(-32001, "node not found: %s" % node_path)
	if not (node is AnimationPlayer):
		return _err(-32602, "node is not an AnimationPlayer: %s (%s)" % [node_path, node.get_class()])
	var ap: AnimationPlayer = node

	var out: Array = []
	for lib_name in ap.get_animation_library_list():
		var lib: AnimationLibrary = ap.get_animation_library(lib_name)
		for anim_name in lib.get_animation_list():
			var anim: Animation = lib.get_animation(anim_name)
			var full_name: String
			if String(lib_name) == "":
				full_name = String(anim_name)
			else:
				full_name = "%s/%s" % [lib_name, anim_name]
			var tracks: Array = []
			for i in anim.get_track_count():
				tracks.append({
					"index": i,
					"type": _track_type_name(anim.track_get_type(i)),
					"path": String(anim.track_get_path(i)),
					"key_count": anim.track_get_key_count(i),
				})
			out.append({
				"name": full_name,
				"length": anim.length,
				"loop_mode": anim.loop_mode,
				"step": anim.step,
				"tracks": tracks,
			})
	return _ok({"node_path": node_path, "animations": out})


# animation.add_animation — create an empty animation in the player's library.
# Params: {node_path, name, length?: 1.0, library?: ""}
static func add_animation(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	var anim_name: String = params.get("name", "")
	var length: float = float(params.get("length", 1.0))
	var library_name: String = params.get("library", "")
	if node_path == "" or anim_name == "":
		return _err(-32602, "missing 'node_path' or 'name'")

	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return _err(-32001, "no scene open")
	var node: Node = root if node_path == "." else root.get_node_or_null(node_path)
	if node == null:
		return _err(-32001, "node not found: %s" % node_path)
	if not (node is AnimationPlayer):
		return _err(-32602, "node is not an AnimationPlayer: %s (%s)" % [node_path, node.get_class()])
	var ap: AnimationPlayer = node

	var lib: AnimationLibrary
	if ap.has_animation_library(library_name):
		lib = ap.get_animation_library(library_name)
	else:
		lib = AnimationLibrary.new()
		var add_err: int = ap.add_animation_library(library_name, lib)
		if add_err != OK:
			return _err(-32001, "add_animation_library failed: %d" % add_err)

	if lib.has_animation(anim_name):
		return _err(-32602, "animation already exists: %s" % anim_name)

	var anim := Animation.new()
	anim.length = length
	@warning_ignore("return_value_discarded")
	lib.add_animation(anim_name, anim)
	EditorInterface.mark_scene_as_unsaved()
	return _ok({"name": anim_name, "library": library_name, "length": length})


# animation.remove_animation — delete an animation from the player.
# Params: {node_path, name, library?: ""}
static func remove_animation(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	var anim_name: String = params.get("name", "")
	var library_name: String = params.get("library", "")
	if node_path == "" or anim_name == "":
		return _err(-32602, "missing 'node_path' or 'name'")

	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return _err(-32001, "no scene open")
	var node: Node = root if node_path == "." else root.get_node_or_null(node_path)
	if node == null:
		return _err(-32001, "node not found: %s" % node_path)
	if not (node is AnimationPlayer):
		return _err(-32602, "node is not an AnimationPlayer")
	var ap: AnimationPlayer = node

	if not ap.has_animation_library(library_name):
		return _err(-32001, "library not found: '%s'" % library_name)
	var lib: AnimationLibrary = ap.get_animation_library(library_name)
	if not lib.has_animation(anim_name):
		return _err(-32001, "animation not found: %s" % anim_name)
	lib.remove_animation(anim_name)
	EditorInterface.mark_scene_as_unsaved()
	return _ok({"removed": anim_name, "library": library_name})


# animation.add_value_track — add a value track that animates a property over time.
# target_node is resolved relative to the scene root (simpler than the
# AnimationPlayer.root_node-relative resolution, which is fiddly).
# Params: {node_path, animation, target_node, property, keyframes: [{time, value, easing?}]}
static func add_value_track(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	var anim_name: String = params.get("animation", "")
	var target_node: String = params.get("target_node", "")
	var property_name: String = params.get("property", "")
	var keyframes: Array = params.get("keyframes", [])

	if node_path == "" or anim_name == "" or target_node == "" or property_name == "":
		return _err(-32602, "missing 'node_path', 'animation', 'target_node', or 'property'")
	if keyframes.is_empty():
		return _err(-32602, "'keyframes' must contain at least one entry")

	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return _err(-32001, "no scene open")
	var node: Node = root if node_path == "." else root.get_node_or_null(node_path)
	if node == null:
		return _err(-32001, "node not found: %s" % node_path)
	if not (node is AnimationPlayer):
		return _err(-32602, "node is not an AnimationPlayer")
	var ap: AnimationPlayer = node

	if not ap.has_animation(anim_name):
		return _err(-32001, "animation not found on this player: %s" % anim_name)
	var anim: Animation = ap.get_animation(anim_name)

	# Validate that the target resolves from the scene root (a simpler contract
	# than AP.root_node-relative — callers think in scene-tree terms already).
	if root.get_node_or_null(target_node) == null:
		return _err(-32001, "target_node does not resolve from scene root: %s" % target_node)

	var track_idx: int = anim.add_track(Animation.TYPE_VALUE)
	anim.track_set_path(track_idx, NodePath("%s:%s" % [target_node, property_name]))

	var max_time: float = 0.0
	for kf in keyframes:
		if typeof(kf) != TYPE_DICTIONARY or not kf.has("time") or not kf.has("value"):
			return _err(-32602, "each keyframe needs {time, value}")
		var t: float = float(kf.time)
		var transition: float = float(kf.get("easing", 1.0))
		anim.track_insert_key(track_idx, t, kf.value, transition)
		if t > max_time:
			max_time = t

	if max_time > anim.length:
		anim.length = max_time

	EditorInterface.mark_scene_as_unsaved()
	return _ok({
		"animation": anim_name,
		"track_index": track_idx,
		"target": "%s:%s" % [target_node, property_name],
		"keyframes_added": keyframes.size(),
	})


static func _track_type_name(t: int) -> String:
	match t:
		Animation.TYPE_VALUE:
			return "value"
		Animation.TYPE_POSITION_3D:
			return "position_3d"
		Animation.TYPE_ROTATION_3D:
			return "rotation_3d"
		Animation.TYPE_SCALE_3D:
			return "scale_3d"
		Animation.TYPE_BLEND_SHAPE:
			return "blend_shape"
		Animation.TYPE_METHOD:
			return "method"
		Animation.TYPE_BEZIER:
			return "bezier"
		Animation.TYPE_AUDIO:
			return "audio"
		Animation.TYPE_ANIMATION:
			return "animation"
		_:
			return "unknown(%d)" % t


static func _ok(data) -> Dictionary:
	return {"data": data}


static func _err(code: int, msg: String) -> Dictionary:
	return {"error": {"code": code, "message": msg}}
