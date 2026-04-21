@tool
extends RefCounted

const Coerce := preload("res://addons/agent_tools/tools/_coerce.gd")

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
# Params: {path, property, value} — same coercion as scene.set_property.
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
	if int(prop_info.get("usage", 0)) & PROPERTY_USAGE_READ_ONLY:
		return _err(-32602, "property '%s' on %s is read-only" % [property_name, res.get_class()])

	var coerced = Coerce.coerce(params.get("value"), prop_info.type)
	if coerced is Dictionary and coerced.has("_error"):
		return _err(-32602, coerced._error)

	res.set(property_name, coerced)
	var stored = res.get(property_name)
	if coerced != null and stored == null and prop_info.type == TYPE_OBJECT:
		return _err(-32001,
			"property '%s' on %s was not accepted (assignment silently dropped — target expects a %s; passed value type didn't match)" %
			[property_name, res.get_class(), prop_info.get("hint_string", "Resource")])
	var save_err := ResourceSaver.save(res, path)
	if save_err != OK:
		return _err(-32001, "save failed: %d" % save_err)
	EditorInterface.get_resource_filesystem().update_file(path)
	return _ok({"path": path, "property": property_name, "value": Coerce.to_json(stored)})


# resource.call_method — load a .tres, invoke a method, save, return the method's result.
# Useful for helper methods that aren't properties — e.g. StyleBoxFlat.set_border_width_all(4)
# or set_corner_radius_all(14). Args are coerced against the method's declared types.
# Params: {path, method, args?: [], save?: true}
static func call_method(params: Dictionary) -> Dictionary:
	var path: String = params.get("path", "")
	var method_name: String = params.get("method", "")
	var args: Array = params.get("args", [])
	var should_save: bool = params.get("save", true)
	if path == "" or method_name == "":
		return _err(-32602, "missing 'path' or 'method'")

	var res := ResourceLoader.load(path)
	if res == null:
		return _err(-32001, "failed to load: %s" % path)
	if not res.has_method(method_name):
		return _err(-32602, "method not found: %s.%s" % [res.get_class(), method_name])

	var coerced_args = _coerce_args(res, method_name, args)
	if coerced_args is Dictionary:
		return coerced_args  # error passthrough (same reason as scene.call_method: no type annotation)
	var result = res.callv(method_name, coerced_args)

	if should_save:
		var save_err := ResourceSaver.save(res, path)
		if save_err != OK:
			return _err(-32001, "save failed: %d" % save_err)
		EditorInterface.get_resource_filesystem().update_file(path)

	return _ok({
		"path": path,
		"method": method_name,
		"return": Coerce.to_json(result),
		"saved": should_save,
	})


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


static func _apply_properties(res: Resource, props: Dictionary) -> Dictionary:
	var by_name: Dictionary = {}
	for p in res.get_property_list():
		by_name[p.name] = p
	for key in props:
		if not by_name.has(key):
			return _err(-32602, "property not found on %s: %s" % [res.get_class(), key])
		var coerced = Coerce.coerce(props[key], by_name[key].type)
		if coerced is Dictionary and coerced.has("_error"):
			return _err(-32602, "property %s: %s" % [key, coerced._error])
		res.set(key, coerced)
	return {}


static func _ok(data) -> Dictionary:
	return {"data": data}


static func _err(code: int, msg: String) -> Dictionary:
	return {"error": {"code": code, "message": msg}}
