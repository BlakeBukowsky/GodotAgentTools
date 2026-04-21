@tool
extends RefCounted

# Shared JSON-to-Godot type coercion for scene.set_property, resource.set_property,
# and any other tool that assigns a user-provided value into a typed property slot.
#
# Contract:
#   coerce(value, target_type: int) -> Variant
#
#   Returns the coerced value on success. On mismatch, returns a Dictionary with
#   a single "_error" key describing the failure — callers check `is Dictionary`
#   and forward the message as a tool-level error.
#
# New types go here. Don't re-add `_coerce` to individual tool files; route
# through Coerce.coerce() instead.

static func coerce(value, target_type: int):
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
		TYPE_VECTOR3I:
			if value is Array and value.size() == 3:
				return Vector3i(int(value[0]), int(value[1]), int(value[2]))
			return {"_error": "Vector3i expects [x, y, z]"}
		TYPE_VECTOR4:
			if value is Array and value.size() == 4:
				return Vector4(value[0], value[1], value[2], value[3])
			return {"_error": "Vector4 expects [x, y, z, w]"}
		TYPE_VECTOR4I:
			if value is Array and value.size() == 4:
				return Vector4i(int(value[0]), int(value[1]), int(value[2]), int(value[3]))
			return {"_error": "Vector4i expects [x, y, z, w]"}
		TYPE_RECT2:
			if value is Array and value.size() == 4:
				return Rect2(value[0], value[1], value[2], value[3])
			return {"_error": "Rect2 expects [x, y, width, height]"}
		TYPE_RECT2I:
			if value is Array and value.size() == 4:
				return Rect2i(int(value[0]), int(value[1]), int(value[2]), int(value[3]))
			return {"_error": "Rect2i expects [x, y, width, height]"}
		TYPE_QUATERNION:
			if value is Array and value.size() == 4:
				return Quaternion(value[0], value[1], value[2], value[3])
			return {"_error": "Quaternion expects [x, y, z, w]"}
		TYPE_TRANSFORM2D:
			# TRS form: {origin: [x,y], rotation: radians, scale: [x,y]} — all optional.
			if value is Dictionary:
				var origin = value.get("origin", [0, 0])
				var rotation: float = float(value.get("rotation", 0.0))
				var scale_v = value.get("scale", [1, 1])
				var skew: float = float(value.get("skew", 0.0))
				if not (origin is Array and origin.size() == 2 and scale_v is Array and scale_v.size() == 2):
					return {"_error": "Transform2D origin/scale expect [x, y]"}
				return Transform2D(
					rotation,
					Vector2(scale_v[0], scale_v[1]),
					skew,
					Vector2(origin[0], origin[1])
				)
			return {"_error": "Transform2D expects {origin: [x,y], rotation: radians, scale: [x,y], skew?}"}
		TYPE_TRANSFORM3D:
			# TRS form: {origin: [x,y,z], rotation: [x,y,z] euler radians, scale: [x,y,z]}.
			if value is Dictionary:
				var origin = value.get("origin", [0, 0, 0])
				var rotation = value.get("rotation", [0, 0, 0])
				var scale_v = value.get("scale", [1, 1, 1])
				if not (origin is Array and origin.size() == 3
						and rotation is Array and rotation.size() == 3
						and scale_v is Array and scale_v.size() == 3):
					return {"_error": "Transform3D origin/rotation/scale expect [x, y, z]"}
				var basis := Basis.from_euler(Vector3(rotation[0], rotation[1], rotation[2]))
				basis = basis.scaled(Vector3(scale_v[0], scale_v[1], scale_v[2]))
				return Transform3D(basis, Vector3(origin[0], origin[1], origin[2]))
			return {"_error": "Transform3D expects {origin: [x,y,z], rotation: [x,y,z] (euler rad), scale: [x,y,z]}"}
		TYPE_BASIS:
			if value is Dictionary:
				var rotation = value.get("rotation", [0, 0, 0])
				var scale_v = value.get("scale", [1, 1, 1])
				if not (rotation is Array and rotation.size() == 3
						and scale_v is Array and scale_v.size() == 3):
					return {"_error": "Basis rotation/scale expect [x, y, z]"}
				return Basis.from_euler(Vector3(rotation[0], rotation[1], rotation[2])).scaled(
					Vector3(scale_v[0], scale_v[1], scale_v[2]))
			return {"_error": "Basis expects {rotation: [x,y,z] (euler rad), scale: [x,y,z]}"}
		TYPE_AABB:
			if value is Dictionary:
				var pos = value.get("position", [0, 0, 0])
				var size = value.get("size", [0, 0, 0])
				if not (pos is Array and pos.size() == 3 and size is Array and size.size() == 3):
					return {"_error": "AABB position/size expect [x, y, z]"}
				return AABB(Vector3(pos[0], pos[1], pos[2]), Vector3(size[0], size[1], size[2]))
			return {"_error": "AABB expects {position: [x,y,z], size: [x,y,z]}"}
		TYPE_PLANE:
			if value is Dictionary:
				var normal = value.get("normal", [0, 1, 0])
				var d: float = float(value.get("d", 0.0))
				if not (normal is Array and normal.size() == 3):
					return {"_error": "Plane normal expects [x, y, z]"}
				return Plane(Vector3(normal[0], normal[1], normal[2]), d)
			return {"_error": "Plane expects {normal: [x,y,z], d: float}"}
		TYPE_COLOR:
			if value is Array and (value.size() == 3 or value.size() == 4):
				var a := float(value[3]) if value.size() == 4 else 1.0
				return Color(value[0], value[1], value[2], a)
			if value is String:
				return Color(value)
			return {"_error": "Color expects [r,g,b(,a)] or '#rrggbb(aa)'"}
		TYPE_PACKED_STRING_ARRAY:
			if value is Array:
				var out := PackedStringArray()
				for s in value:
					out.append(String(s))
				return out
			return {"_error": "PackedStringArray expects an array of strings"}
		TYPE_PACKED_INT32_ARRAY:
			if value is Array:
				var out := PackedInt32Array()
				for i in value:
					out.append(int(i))
				return out
			return {"_error": "PackedInt32Array expects an array of numbers"}
		TYPE_PACKED_INT64_ARRAY:
			if value is Array:
				var out := PackedInt64Array()
				for i in value:
					out.append(int(i))
				return out
			return {"_error": "PackedInt64Array expects an array of numbers"}
		TYPE_PACKED_FLOAT32_ARRAY:
			if value is Array:
				var out := PackedFloat32Array()
				for f in value:
					out.append(float(f))
				return out
			return {"_error": "PackedFloat32Array expects an array of numbers"}
		TYPE_PACKED_FLOAT64_ARRAY:
			if value is Array:
				var out := PackedFloat64Array()
				for f in value:
					out.append(float(f))
				return out
			return {"_error": "PackedFloat64Array expects an array of numbers"}
		TYPE_PACKED_VECTOR2_ARRAY:
			if value is Array:
				var out := PackedVector2Array()
				for v in value:
					if v is Array and v.size() == 2:
						out.append(Vector2(v[0], v[1]))
					else:
						return {"_error": "PackedVector2Array expects [[x, y], ...]"}
				return out
			return {"_error": "PackedVector2Array expects an array of [x, y] pairs"}
		TYPE_PACKED_VECTOR3_ARRAY:
			if value is Array:
				var out := PackedVector3Array()
				for v in value:
					if v is Array and v.size() == 3:
						out.append(Vector3(v[0], v[1], v[2]))
					else:
						return {"_error": "PackedVector3Array expects [[x, y, z], ...]"}
				return out
			return {"_error": "PackedVector3Array expects an array of [x, y, z] triples"}
		TYPE_PACKED_COLOR_ARRAY:
			if value is Array:
				var out := PackedColorArray()
				for c in value:
					if c is Array and (c.size() == 3 or c.size() == 4):
						var a := float(c[3]) if c.size() == 4 else 1.0
						out.append(Color(c[0], c[1], c[2], a))
					elif c is String:
						out.append(Color(c))
					else:
						return {"_error": "PackedColorArray expects [[r,g,b(,a)], ...] or ['#hex', ...]"}
				return out
			return {"_error": "PackedColorArray expects an array of colors"}
		TYPE_OBJECT:
			# Auto-load a Resource when the caller passes a "res://..." or "uid://..." path string.
			# Without this, Godot silently drops the assignment and leaves the slot null.
			if value is String and (value.begins_with("res://") or value.begins_with("uid://")):
				var loaded := ResourceLoader.load(value)
				if loaded == null:
					return {"_error": "failed to load resource: %s" % value}
				return loaded
			return value
		_:
			return value


# Inverse of coerce(): convert a Godot value back to a JSON-native form so the
# response echo is unambiguous data rather than Godot's str() stringification
# (which turns Vector2 into "(x, y)", Color into "(r, g, b, a)", null Object
# into "<Object#null>", etc., all of which look like success strings).
static func to_json(value):
	match typeof(value):
		TYPE_VECTOR2:
			return [value.x, value.y]
		TYPE_VECTOR2I:
			return [int(value.x), int(value.y)]
		TYPE_VECTOR3:
			return [value.x, value.y, value.z]
		TYPE_VECTOR3I:
			return [int(value.x), int(value.y), int(value.z)]
		TYPE_VECTOR4:
			return [value.x, value.y, value.z, value.w]
		TYPE_VECTOR4I:
			return [int(value.x), int(value.y), int(value.z), int(value.w)]
		TYPE_RECT2:
			return [value.position.x, value.position.y, value.size.x, value.size.y]
		TYPE_RECT2I:
			return [int(value.position.x), int(value.position.y), int(value.size.x), int(value.size.y)]
		TYPE_COLOR:
			return [value.r, value.g, value.b, value.a]
		TYPE_QUATERNION:
			return [value.x, value.y, value.z, value.w]
		TYPE_NODE_PATH:
			return String(value)
		TYPE_STRING_NAME:
			return String(value)
		TYPE_TRANSFORM2D:
			return {
				"origin": [value.origin.x, value.origin.y],
				"x": [value.x.x, value.x.y],
				"y": [value.y.x, value.y.y],
			}
		TYPE_TRANSFORM3D:
			return {
				"origin": [value.origin.x, value.origin.y, value.origin.z],
				"basis": to_json(value.basis),
			}
		TYPE_BASIS:
			return [
				[value.x.x, value.x.y, value.x.z],
				[value.y.x, value.y.y, value.y.z],
				[value.z.x, value.z.y, value.z.z],
			]
		TYPE_AABB:
			return {
				"position": [value.position.x, value.position.y, value.position.z],
				"size": [value.size.x, value.size.y, value.size.z],
			}
		TYPE_PLANE:
			return {
				"normal": [value.normal.x, value.normal.y, value.normal.z],
				"d": value.d,
			}
		TYPE_OBJECT:
			if value == null:
				return null
			if value is Resource and value.resource_path != "":
				return {"class": value.get_class(), "resource_path": value.resource_path}
			return {"class": (value as Object).get_class()}
		TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, \
		TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY:
			return Array(value)
		TYPE_PACKED_VECTOR2_ARRAY:
			var out_v2: Array = []
			for v in value:
				out_v2.append([v.x, v.y])
			return out_v2
		TYPE_PACKED_VECTOR3_ARRAY:
			var out_v3: Array = []
			for v in value:
				out_v3.append([v.x, v.y, v.z])
			return out_v3
		TYPE_PACKED_COLOR_ARRAY:
			var out_c: Array = []
			for c in value:
				out_c.append([c.r, c.g, c.b, c.a])
			return out_c
		TYPE_ARRAY:
			var out_a: Array = []
			for item in value:
				out_a.append(to_json(item))
			return out_a
		TYPE_DICTIONARY:
			var out_d: Dictionary = {}
			for k in value:
				out_d[str(k)] = to_json(value[k])
			return out_d
		_:
			return value
