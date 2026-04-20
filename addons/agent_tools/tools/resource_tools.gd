@tool
extends RefCounted

# resource.create — create a new .tres file.
# Params: {path, type, script?, properties?, overwrite?: false}
# 'type' must be a built-in Resource subclass (StyleBoxFlat, Theme, Curve, etc.).
# For custom Resource subclasses written in GDScript, pass 'script' pointing at the
# class's .gd file instead of 'type'.
static func create(params: Dictionary) -> Dictionary:
	var path: String = params.get("path", "")
	var type_name: String = params.get("type", "")
	var script_path: String = params.get("script", "")
	var properties: Dictionary = params.get("properties", {})
	var overwrite: bool = params.get("overwrite", false)

	if path == "" or not path.begins_with("res://") or not path.ends_with(".tres"):
		return _err(-32602, "'path' must be 'res://...' ending in .tres")
	if FileAccess.file_exists(path) and not overwrite:
		return _err(-32602, "file exists (pass overwrite:true to replace): %s" % path)

	var res: Resource
	if script_path != "":
		var s := ResourceLoader.load(script_path, "Script") as Script
		if s == null:
			return _err(-32001, "failed to load script: %s" % script_path)
		var inst = s.new()
		if not (inst is Resource):
			return _err(-32602, "script does not produce a Resource")
		res = inst
	elif type_name != "":
		if not ClassDB.class_exists(type_name):
			return _err(-32602, "unknown class: %s (use 'script' for custom Resource types)" % type_name)
		if not ClassDB.is_parent_class(type_name, "Resource"):
			return _err(-32602, "not a Resource subclass: %s" % type_name)
		if not ClassDB.can_instantiate(type_name):
			return _err(-32602, "class is not instantiable: %s" % type_name)
		res = ClassDB.instantiate(type_name) as Resource
	else:
		return _err(-32602, "provide either 'type' (built-in Resource class) or 'script' (path to custom Resource .gd)")

	var apply_res := _apply_properties(res, properties)
	if apply_res.has("error"):
		return apply_res

	var dir_path := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		var derr := DirAccess.make_dir_recursive_absolute(dir_path)
		if derr != OK:
			return _err(-32001, "mkdir failed (%d): %s" % [derr, dir_path])

	var save_err := ResourceSaver.save(res, path)
	if save_err != OK:
		return _err(-32001, "ResourceSaver.save failed: %d" % save_err)

	EditorInterface.get_resource_filesystem().update_file(path)
	return _ok({"path": path, "class": res.get_class()})


# resource.set_property — load a .tres, set one property, save it back.
# Params: {path, property, value}
static func set_property(params: Dictionary) -> Dictionary:
	var path: String = params.get("path", "")
	var property_name: String = params.get("property", "")
	if path == "" or property_name == "":
		return _err(-32602, "missing 'path' or 'property'")

	var res := ResourceLoader.load(path)
	if res == null:
		return _err(-32001, "failed to load: %s" % path)

	var prop_info: Dictionary = {}
	for p in res.get_property_list():
		if p.name == property_name:
			prop_info = p
			break
	if prop_info.is_empty():
		return _err(-32602, "property not found on %s: %s" % [res.get_class(), property_name])

	var coerced = _coerce(params.get("value"), prop_info.type)
	if coerced is Dictionary and coerced.has("_error"):
		return _err(-32602, coerced._error)

	res.set(property_name, coerced)
	var save_err := ResourceSaver.save(res, path)
	if save_err != OK:
		return _err(-32001, "save failed: %d" % save_err)
	EditorInterface.get_resource_filesystem().update_file(path)
	return _ok({"path": path, "property": property_name, "value": res.get(property_name)})


static func _apply_properties(res: Resource, props: Dictionary) -> Dictionary:
	var by_name: Dictionary = {}
	for p in res.get_property_list():
		by_name[p.name] = p
	for key in props:
		if not by_name.has(key):
			return _err(-32602, "property not found on %s: %s" % [res.get_class(), key])
		var coerced = _coerce(props[key], by_name[key].type)
		if coerced is Dictionary and coerced.has("_error"):
			return _err(-32602, "property %s: %s" % [key, coerced._error])
		res.set(key, coerced)
	return {}


static func _coerce(value, target_type: int):
	match target_type:
		TYPE_BOOL: return bool(value)
		TYPE_INT: return int(value)
		TYPE_FLOAT: return float(value)
		TYPE_STRING, TYPE_STRING_NAME: return String(value)
		TYPE_NODE_PATH: return NodePath(String(value))
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
