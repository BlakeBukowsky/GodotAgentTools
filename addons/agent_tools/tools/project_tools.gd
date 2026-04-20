@tool
extends RefCounted

# project.get_setting — read a value from project.godot. Returns {exists: false} if unset.
# Params: {key: "application/config/name"}
static func get_setting(params: Dictionary) -> Dictionary:
	var key: String = params.get("key", "")
	if key == "":
		return _err(-32602, "missing 'key'")
	if not ProjectSettings.has_setting(key):
		return _ok({"key": key, "exists": false})
	return _ok({"key": key, "exists": true, "value": ProjectSettings.get_setting(key)})


# project.set_setting — write a value to project.godot and save.
# DESTRUCTIVE: mutates project.godot. Prefer targeted tools (autoload.add, etc.) when available.
# Params: {key, value}
static func set_setting(params: Dictionary) -> Dictionary:
	var key: String = params.get("key", "")
	if key == "":
		return _err(-32602, "missing 'key'")
	if not params.has("value"):
		return _err(-32602, "missing 'value'")
	ProjectSettings.set_setting(key, params["value"])
	var err := ProjectSettings.save()
	if err != OK:
		return _err(-32001, "ProjectSettings.save() failed: %d" % err)
	return _ok({"key": key, "value": params["value"]})


# autoload.add — register an autoload (singleton by default).
# Params: {name, path, singleton?: true}
static func autoload_add(params: Dictionary) -> Dictionary:
	var autoload_name: String = params.get("name", "")
	var path: String = params.get("path", "")
	var singleton: bool = params.get("singleton", true)
	if autoload_name == "" or path == "":
		return _err(-32602, "missing 'name' or 'path'")
	if not ResourceLoader.exists(path):
		return _err(-32001, "path does not exist: %s" % path)

	var value := ("*" + path) if singleton else path
	ProjectSettings.set_setting("autoload/" + autoload_name, value)
	var err := ProjectSettings.save()
	if err != OK:
		return _err(-32001, "save failed: %d" % err)
	return _ok({"name": autoload_name, "path": path, "singleton": singleton})


# autoload.remove — unregister an autoload.
# Params: {name}
static func autoload_remove(params: Dictionary) -> Dictionary:
	var autoload_name: String = params.get("name", "")
	if autoload_name == "":
		return _err(-32602, "missing 'name'")
	var key := "autoload/" + autoload_name
	if not ProjectSettings.has_setting(key):
		return _err(-32001, "autoload not found: %s" % autoload_name)
	ProjectSettings.clear(key)
	var err := ProjectSettings.save()
	if err != OK:
		return _err(-32001, "save failed: %d" % err)
	return _ok({"removed": autoload_name})


# autoload.list — enumerate all registered autoloads.
static func autoload_list(_params: Dictionary) -> Dictionary:
	var items: Array = []
	# ProjectSettings.get_property_list() contains our autoload entries under "autoload/*".
	for p in ProjectSettings.get_property_list():
		var name: String = p.name
		if not name.begins_with("autoload/"):
			continue
		var value: String = str(ProjectSettings.get_setting(name))
		var singleton := value.begins_with("*")
		items.append({
			"name": name.trim_prefix("autoload/"),
			"path": value.trim_prefix("*") if singleton else value,
			"singleton": singleton,
		})
	return _ok({"autoloads": items})


static func _ok(data) -> Dictionary:
	return {"data": data}


static func _err(code: int, msg: String) -> Dictionary:
	return {"error": {"code": code, "message": msg}}
