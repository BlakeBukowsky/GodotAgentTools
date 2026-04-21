@tool
extends RefCounted

# theme.* — thin wrappers around Godot's awkward Theme API. Theme uses the
# three-argument shape `(item_name, type_name, value)` where type_name is a
# Control subclass like "Button", "Label", "LineEdit". resource.call_method
# works but these helpers save the lookup.

# theme.set_color — {path, item, type, color}
#   color accepts [r,g,b(,a)] or '#rrggbb(aa)' (Coerce handles it).
static func set_color(params: Dictionary) -> Dictionary:
	return _set_entry(params, "color", "set_color", TYPE_COLOR)


# theme.set_constant — {path, item, type, value: int}
static func set_constant(params: Dictionary) -> Dictionary:
	return _set_entry(params, "constant", "set_constant", TYPE_INT)


# theme.set_font_size — {path, item, type, value: int}
static func set_font_size(params: Dictionary) -> Dictionary:
	return _set_entry(params, "font_size", "set_font_size", TYPE_INT)


# theme.set_stylebox_flat — {path, item, type, properties: {bg_color, corner_radius_*, border_width_*, ...}}
# Creates (or replaces) a StyleBoxFlat with the given properties and assigns
# it to theme.<item>.<type>. Saves the two-step "create stylebox, set props,
# assign" dance.
static func set_stylebox_flat(params: Dictionary) -> Dictionary:
	var path: String = params.get("path", "")
	var item_name: String = params.get("item", "")
	var type_name: String = params.get("type", "")
	var props: Dictionary = params.get("properties", {})
	if path == "" or item_name == "" or type_name == "":
		return _err(-32602, "missing 'path', 'item', or 'type'")

	var theme := ResourceLoader.load(path) as Theme
	if theme == null:
		return _err(-32001, "failed to load theme: %s" % path)

	var sb := StyleBoxFlat.new()
	const Coerce := preload("res://addons/agent_tools/tools/_coerce.gd")
	for k in props:
		var prop_info := _find_property(sb, k)
		if prop_info.is_empty():
			return _err(-32602, "StyleBoxFlat has no property '%s'" % k)
		var coerced = Coerce.coerce(props[k], prop_info.type)
		if coerced is Dictionary and coerced.has("_error"):
			return _err(-32602, "property %s: %s" % [k, coerced._error])
		sb.set(k, coerced)

	theme.set_stylebox(item_name, type_name, sb)
	var save_err := ResourceSaver.save(theme, path)
	if save_err != OK:
		return _err(-32001, "theme save failed: %d" % save_err)
	EditorInterface.get_resource_filesystem().update_file(path)
	return _ok({
		"path": path,
		"item": item_name,
		"type": type_name,
		"applied_properties": props.keys(),
	})


static func _set_entry(params: Dictionary, expected_kind: String, setter_name: String, expected_type: int) -> Dictionary:
	var path: String = params.get("path", "")
	var item_name: String = params.get("item", "")
	var type_name: String = params.get("type", "")
	if path == "" or item_name == "" or type_name == "":
		return _err(-32602, "missing 'path', 'item', or 'type'")

	var theme := ResourceLoader.load(path) as Theme
	if theme == null:
		return _err(-32001, "failed to load theme: %s" % path)

	const Coerce := preload("res://addons/agent_tools/tools/_coerce.gd")
	var key := "color" if expected_kind == "color" else "value"
	var raw = params.get(key)
	if raw == null:
		return _err(-32602, "missing '%s'" % key)
	var coerced = Coerce.coerce(raw, expected_type)
	if coerced is Dictionary and coerced.has("_error"):
		return _err(-32602, coerced._error)

	theme.call(setter_name, item_name, type_name, coerced)
	var save_err := ResourceSaver.save(theme, path)
	if save_err != OK:
		return _err(-32001, "theme save failed: %d" % save_err)
	EditorInterface.get_resource_filesystem().update_file(path)
	return _ok({
		"path": path,
		"item": item_name,
		"type": type_name,
		"kind": expected_kind,
	})


static func _find_property(obj: Object, name: String) -> Dictionary:
	for p in obj.get_property_list():
		if p.name == name:
			return p
	return {}


static func _ok(data) -> Dictionary:
	return {"data": data}


static func _err(code: int, msg: String) -> Dictionary:
	return {"error": {"code": code, "message": msg}}
