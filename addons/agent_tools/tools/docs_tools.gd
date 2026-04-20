@tool
extends RefCounted

# docs.class_ref — return the public API of a Godot class so the agent can plan
# work without guessing method/property/signal names.
# Params: {class_name, include_inherited?: false}
# Returns: {class, parent, methods: [{name, args, return}], properties, signals, constants}
static func class_ref(params: Dictionary) -> Dictionary:
	var cname: String = params.get("class_name", "")
	var include_inherited: bool = params.get("include_inherited", false)
	if cname == "":
		return _err(-32602, "missing 'class_name'")
	if not ClassDB.class_exists(cname):
		return _err(-32602, "unknown class: %s" % cname)

	var no_inheritance := not include_inherited

	var methods: Array = []
	for m in ClassDB.class_get_method_list(cname, no_inheritance):
		# Skip internal / editor-only methods — they're noise for an agent.
		if (m.flags as int) & METHOD_FLAG_OBJECT_CORE:
			continue
		var args: Array = []
		for a in m.args:
			args.append({"name": a.name, "type": type_string(a.type)})
		methods.append({
			"name": m.name,
			"args": args,
			"return": type_string(m.return.type) if m.has("return") else "void",
			"virtual": bool((m.flags as int) & METHOD_FLAG_VIRTUAL),
			"static": bool((m.flags as int) & METHOD_FLAG_STATIC),
		})

	var properties: Array = []
	for p in ClassDB.class_get_property_list(cname, no_inheritance):
		# Only user-facing properties (storage + editor). Internal group markers have usage=0.
		if not ((p.usage as int) & PROPERTY_USAGE_EDITOR):
			continue
		properties.append({
			"name": p.name,
			"type": type_string(p.type),
			"hint": p.get("hint_string", ""),
		})

	var signals: Array = []
	for s in ClassDB.class_get_signal_list(cname, no_inheritance):
		var args: Array = []
		for a in s.args:
			args.append({"name": a.name, "type": type_string(a.type)})
		signals.append({"name": s.name, "args": args})

	var constants: Array = []
	for c in ClassDB.class_get_integer_constant_list(cname, no_inheritance):
		constants.append({"name": c, "value": ClassDB.class_get_integer_constant(cname, c)})

	return _ok({
		"class": cname,
		"parent": ClassDB.get_parent_class(cname),
		"inherited_included": include_inherited,
		"methods": methods,
		"properties": properties,
		"signals": signals,
		"constants": constants,
	})


static func _ok(data) -> Dictionary:
	return {"data": data}


static func _err(code: int, msg: String) -> Dictionary:
	return {"error": {"code": code, "message": msg}}
