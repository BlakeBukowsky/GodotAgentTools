@tool
extends RefCounted

# fs.list — enumerate project files by type, with optional glob filter.
# Params: {type?: "all"|"scene"|"script"|"resource"|"shader"|"image"|"audio",
#          glob?: "res://scenes/**/*.tscn",
#          include_addons?: false}
# Returns: {type, count, files: [paths]}
static func list(params: Dictionary) -> Dictionary:
	var type_filter: String = params.get("type", "all")
	var glob: String = params.get("glob", "")
	var include_addons: bool = params.get("include_addons", false)

	var exts: Array
	match type_filter:
		"", "all":
			exts = ["gd", "cs", "tscn", "tres", "res", "gdshader", "gdshaderinc",
				"png", "jpg", "jpeg", "svg", "webp",
				"ogg", "wav", "mp3",
				"json", "cfg"]
		"scene":
			exts = ["tscn"]
		"script":
			exts = ["gd", "cs"]
		"resource":
			exts = ["tres", "res"]
		"shader":
			exts = ["gdshader", "gdshaderinc"]
		"image":
			exts = ["png", "jpg", "jpeg", "svg", "webp"]
		"audio":
			exts = ["ogg", "wav", "mp3"]
		_:
			return _err(-32602, "unknown type: %s (use all|scene|script|resource|shader|image|audio)" % type_filter)

	var files: Array = []
	_walk("res://", exts, files, include_addons)

	if glob != "":
		var filtered: Array = []
		for f in files:
			if f.matchn(glob):  # case-insensitive glob match
				filtered.append(f)
		files = filtered

	files.sort()
	return _ok({
		"type": type_filter,
		"count": files.size(),
		"files": files,
	})


static func _walk(dir_path: String, exts: Array, out: Array, include_addons: bool) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	while true:
		var name := d.get_next()
		if name == "":
			break
		if name.begins_with("."):
			continue
		var full := dir_path.path_join(name)
		if d.current_is_dir():
			if not include_addons and full == "res://addons/agent_tools":
				continue  # always skip our own addon
			_walk(full, exts, out, include_addons)
		else:
			for e in exts:
				if name.ends_with("." + e):
					out.append(full)
					break
	d.list_dir_end()


static func _ok(data) -> Dictionary:
	return {"data": data}


static func _err(code: int, msg: String) -> Dictionary:
	return {"error": {"code": code, "message": msg}}
