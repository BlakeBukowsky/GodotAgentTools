@tool
extends RefCounted

# signal.connect — operates on the currently-edited scene.
# Params: {from: "Player", signal: "died", to: ".", method: "_on_player_died"}
# Uses CONNECT_PERSIST so the connection is serialized into the .tscn as a [connection] block.
static func connect_signal(params: Dictionary) -> Dictionary:
	var from_path: String = params.get("from", "")
	var signal_name: String = params.get("signal", "")
	var to_path: String = params.get("to", "")
	var method_name: String = params.get("method", "")

	for required in ["from", "signal", "to", "method"]:
		if params.get(required, "") == "":
			return _err(-32602, "missing '%s'" % required)

	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return _err(-32001, "no scene open")

	var source: Node = root if from_path == "." else root.get_node_or_null(from_path)
	if source == null:
		return _err(-32001, "source node not found: %s" % from_path)
	var target: Node = root if to_path == "." else root.get_node_or_null(to_path)
	if target == null:
		return _err(-32001, "target node not found: %s" % to_path)

	if not source.has_signal(signal_name):
		return _err(-32602, "%s has no signal '%s'" % [source.get_class(), signal_name])
	if not target.has_method(method_name):
		return _err(-32602, "target has no method '%s' — attach a script with it first" % method_name)

	# Arity check: number of non-default signal args must be <= target method arg count.
	var sig_info := _find_signal(source, signal_name)
	var method_info := _find_method(target, method_name)
	if sig_info and method_info:
		var sig_args: int = (sig_info.args as Array).size()
		var method_args: int = (method_info.args as Array).size()
		if method_args < sig_args:
			return _err(-32602, "arity mismatch: signal '%s' emits %d args, method '%s' accepts %d" %
				[signal_name, sig_args, method_name, method_args])

	var callable := Callable(target, method_name)
	if source.is_connected(signal_name, callable):
		return _ok({"already_connected": true})

	var err := source.connect(signal_name, callable, CONNECT_PERSIST)
	if err != OK:
		return _err(-32001, "connect() returned %d" % err)

	EditorInterface.mark_scene_as_unsaved()
	return _ok({
		"from": from_path,
		"signal": signal_name,
		"to": to_path,
		"method": method_name,
	})


# signal.disconnect — remove a specific wiring in the currently-edited scene.
# Params: {from, signal, to, method} — same shape as signal.connect.
static func disconnect_signal(params: Dictionary) -> Dictionary:
	for required in ["from", "signal", "to", "method"]:
		if params.get(required, "") == "":
			return _err(-32602, "missing '%s'" % required)

	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return _err(-32001, "no scene open")

	var from_path: String = params["from"]
	var to_path: String = params["to"]
	var source: Node = root if from_path == "." else root.get_node_or_null(from_path)
	var target: Node = root if to_path == "." else root.get_node_or_null(to_path)
	if source == null:
		return _err(-32001, "source not found: %s" % from_path)
	if target == null:
		return _err(-32001, "target not found: %s" % to_path)

	var callable := Callable(target, params["method"])
	if not source.is_connected(params["signal"], callable):
		return _err(-32001, "no such connection")
	source.disconnect(params["signal"], callable)
	EditorInterface.mark_scene_as_unsaved()
	return _ok({"disconnected": true})


# signal.list — list outgoing connections on a node in the currently-edited scene.
# Params: {node_path, persistent_only?: false}
# Returns connections with their flags so callers can distinguish editor-serialized
# connections from runtime ones.
static func list_signals(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	var persistent_only: bool = params.get("persistent_only", false)
	if node_path == "":
		return _err(-32602, "missing 'node_path'")

	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return _err(-32001, "no scene open")
	var node: Node = root if node_path == "." else root.get_node_or_null(node_path)
	if node == null:
		return _err(-32001, "node not found: %s" % node_path)

	var outgoing: Array = []
	for sig in node.get_signal_list():
		var sig_name: String = sig.name
		for c in node.get_signal_connection_list(sig_name):
			var flags: int = c.flags
			var is_persistent: bool = bool(flags & CONNECT_PERSIST)
			if persistent_only and not is_persistent:
				continue
			var cb: Callable = c.callable
			var target: Object = cb.get_object()
			var target_path := ""
			if target is Node and (target == root or root.is_ancestor_of(target)):
				target_path = String(root.get_path_to(target))
			outgoing.append({
				"signal": sig_name,
				"to": target_path,
				"to_object": str(target) if target_path == "" else "",
				"method": cb.get_method(),
				"flags": flags,
				"persistent": is_persistent,
			})
	return _ok({"node_path": node_path, "outgoing": outgoing})


static func _find_signal(obj: Object, name: String) -> Dictionary:
	for s in obj.get_signal_list():
		if s.name == name:
			return s
	return {}


static func _find_method(obj: Object, name: String) -> Dictionary:
	for m in obj.get_method_list():
		if m.name == name:
			return m
	return {}


static func _ok(data) -> Dictionary:
	return {"data": data}


static func _err(code: int, msg: String) -> Dictionary:
	return {"error": {"code": code, "message": msg}}
