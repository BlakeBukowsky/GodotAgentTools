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


# fs.read_text — read a text file under res://. Complement to user_fs.read.
# Params: {path}
static func read_text(params: Dictionary) -> Dictionary:
	var path: String = params.get("path", "")
	if path == "":
		return _err(-32602, "missing 'path'")
	if not path.begins_with("res://"):
		return _err(-32602, "path must begin with 'res://' (use user_fs.read for user:// files)")
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return _err(-32001, "failed to open %s (error %d)" % [path, FileAccess.get_open_error()])
	var size_bytes := f.get_length()
	var content := f.get_as_text()
	f.close()
	return _ok({"path": path, "content": content, "size_bytes": size_bytes})


# fs.write_text — write a text file under res://. Creates parent directories
# if needed. Triggers the editor's filesystem rescan so the new file shows up
# in the FileSystem dock.
# Params: {path, content, overwrite?: false}
static func write_text(params: Dictionary) -> Dictionary:
	var path: String = params.get("path", "")
	var content: String = str(params.get("content", ""))
	var overwrite: bool = params.get("overwrite", false)
	if path == "":
		return _err(-32602, "missing 'path'")
	if not path.begins_with("res://"):
		return _err(-32602, "path must begin with 'res://'")
	if FileAccess.file_exists(path) and not overwrite:
		return _err(-32602, "file exists (pass overwrite:true to replace): %s" % path)

	var dir_path := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		var derr := DirAccess.make_dir_recursive_absolute(dir_path)
		if derr != OK:
			return _err(-32001, "mkdir failed (%d): %s" % [derr, dir_path])

	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return _err(-32001, "could not open for write: %s" % path)
	f.store_string(content)
	f.close()
	EditorInterface.get_resource_filesystem().update_file(path)
	return _ok({"path": path, "bytes_written": content.length()})


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
