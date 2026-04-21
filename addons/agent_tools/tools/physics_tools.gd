@tool
extends RefCounted

# physics.autofit_collision_shape_2d — compute a CollisionShape2D sized to a
# sibling/child Sprite2D or AnimatedSprite2D's visual bounds. Common pattern
# that's tedious to set up by hand: you have a sprite, you want a rectangle or
# circle collider that roughly matches it.
#
# Params: {
#   node_path:         CollisionShape2D to fit (created if missing when create:true)
#   source:            NodePath to a Sprite2D / AnimatedSprite2D (auto-detected
#                      among siblings if omitted)
#   shape:             "rectangle" | "circle" | "capsule"  (default "rectangle")
#   margin:            float pixels to shrink by (default 0)
#   create:            bool — if true and node_path doesn't exist, create it as
#                      a child of the source's parent. Default false.
# }
static func autofit_collision_shape_2d(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	var source_path: String = params.get("source", "")
	var shape_type: String = params.get("shape", "rectangle")
	var margin: float = float(params.get("margin", 0.0))
	var create: bool = params.get("create", false)

	if node_path == "":
		return _err(-32602, "missing 'node_path'")

	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return _err(-32001, "no scene open")

	var target: Node = root if node_path == "." else root.get_node_or_null(node_path)
	if target == null and not create:
		return _err(-32001, "node not found: %s (pass create:true to auto-create)" % node_path)

	# Resolve the visual source.
	var source: Node = null
	if source_path != "":
		source = root.get_node_or_null(source_path)
		if source == null:
			return _err(-32001, "source not found: %s" % source_path)
	elif target != null:
		# Look among siblings for a Sprite2D / AnimatedSprite2D.
		var parent := target.get_parent()
		if parent:
			for sib in parent.get_children():
				if sib is Sprite2D or sib is AnimatedSprite2D:
					source = sib
					break
	if source == null:
		return _err(-32001, "no Sprite2D/AnimatedSprite2D source found — pass 'source'")

	# Compute visual bounds (untransformed; CollisionShape2D inherits parent's transform).
	var bounds := _sprite_bounds(source)
	if bounds.size.x <= 0 or bounds.size.y <= 0:
		return _err(-32001, "source has no visible extents (%s)" % source.get_class())

	# Create the CollisionShape2D if needed.
	if target == null and create:
		var inst := CollisionShape2D.new()
		inst.name = node_path.get_file() if "/" in node_path else node_path
		var parent := source.get_parent()
		parent.add_child(inst)
		inst.owner = root
		target = inst

	if not target is CollisionShape2D:
		return _err(-32602, "target is not a CollisionShape2D: %s (%s)" % [node_path, target.get_class()])
	var cs: CollisionShape2D = target

	# Build the requested shape sized to bounds.
	var shape_res: Shape2D
	match shape_type:
		"rectangle":
			var r := RectangleShape2D.new()
			r.size = Vector2(
				max(1.0, bounds.size.x - margin * 2.0),
				max(1.0, bounds.size.y - margin * 2.0)
			)
			shape_res = r
		"circle":
			var c := CircleShape2D.new()
			c.radius = max(1.0, min(bounds.size.x, bounds.size.y) / 2.0 - margin)
			shape_res = c
		"capsule":
			var cap := CapsuleShape2D.new()
			cap.radius = max(1.0, min(bounds.size.x, bounds.size.y) / 2.0 - margin)
			cap.height = max(cap.radius * 2.0 + 1.0, bounds.size.y - margin * 2.0)
			shape_res = cap
		_:
			return _err(-32602, "unknown shape '%s' (supported: rectangle, circle, capsule)" % shape_type)

	cs.shape = shape_res
	# Center the CollisionShape2D on the sprite's center.
	cs.position = bounds.position + bounds.size / 2.0
	EditorInterface.mark_scene_as_unsaved()

	return _ok({
		"node_path": String(root.get_path_to(cs)),
		"shape": shape_type,
		"size": [bounds.size.x - margin * 2.0, bounds.size.y - margin * 2.0],
		"center": [cs.position.x, cs.position.y],
		"source": String(root.get_path_to(source)),
	})


static func _sprite_bounds(source: Node) -> Rect2:
	if source is Sprite2D:
		var s: Sprite2D = source
		if s.texture == null:
			return Rect2(Vector2.ZERO, Vector2.ZERO)
		var tex_size: Vector2 = s.texture.get_size()
		if s.region_enabled:
			tex_size = s.region_rect.size
		var size: Vector2 = tex_size * Vector2(abs(s.scale.x), abs(s.scale.y))
		# For centered sprites, bounds are at (-size/2, -size/2).
		var offset: Vector2 = -size / 2.0 if s.centered else Vector2.ZERO
		offset += s.offset
		return Rect2(offset, size)
	if source is AnimatedSprite2D:
		var a: AnimatedSprite2D = source
		if a.sprite_frames == null or a.animation == "":
			return Rect2(Vector2.ZERO, Vector2.ZERO)
		var tex := a.sprite_frames.get_frame_texture(a.animation, a.frame)
		if tex == null:
			return Rect2(Vector2.ZERO, Vector2.ZERO)
		var size: Vector2 = tex.get_size() * Vector2(abs(a.scale.x), abs(a.scale.y))
		var offset: Vector2 = -size / 2.0 if a.centered else Vector2.ZERO
		offset += a.offset
		return Rect2(offset, size)
	return Rect2(Vector2.ZERO, Vector2.ZERO)


static func _ok(data) -> Dictionary:
	return {"data": data}


static func _err(code: int, msg: String) -> Dictionary:
	return {"error": {"code": code, "message": msg}}
