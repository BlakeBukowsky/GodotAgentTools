@tool
extends Node

# Line-delimited JSON-RPC over TCP on localhost.
# One request per line: {"id": <any>, "method": "<name>", "params": {...}}
# One response per line: {"id": <echoed>, "result": <data>}  OR  {"id": ..., "error": {"code": int, "message": str, "data"?: any}}

const MAX_MESSAGE_BYTES := 1_048_576  # 1 MiB per line — safety cap

var _tcp: TCPServer
var _clients: Array = []  # Array of {peer: StreamPeerTCP, buf: PackedByteArray}
var _registry


func _init(registry) -> void:
	_registry = registry


func start(port: int) -> bool:
	_tcp = TCPServer.new()
	var err := _tcp.listen(port, "127.0.0.1")
	if err != OK:
		_tcp = null
		return false
	set_process(true)
	return true


func stop() -> void:
	set_process(false)
	for c in _clients:
		(c.peer as StreamPeerTCP).disconnect_from_host()
	_clients.clear()
	if _tcp:
		_tcp.stop()
		_tcp = null


func _process(_delta: float) -> void:
	if _tcp == null:
		return

	while _tcp.is_connection_available():
		var peer := _tcp.take_connection()
		_clients.append({"peer": peer, "buf": PackedByteArray()})

	var still_alive: Array = []
	for c in _clients:
		var peer: StreamPeerTCP = c.peer
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			continue
		var available := peer.get_available_bytes()
		if available > 0:
			var chunk := peer.get_data(available)
			if chunk[0] == OK:
				c.buf.append_array(chunk[1])
		_drain_messages(c)
		if (c.buf as PackedByteArray).size() > MAX_MESSAGE_BYTES:
			_send_error(peer, null, -32700, "message exceeds %d bytes" % MAX_MESSAGE_BYTES)
			peer.disconnect_from_host()
			continue
		still_alive.append(c)
	_clients = still_alive


func _drain_messages(c: Dictionary) -> void:
	while true:
		var buf: PackedByteArray = c.buf
		var nl := buf.find(0x0A)  # \n
		if nl < 0:
			return
		var line_bytes := buf.slice(0, nl)
		c.buf = buf.slice(nl + 1)
		var line := line_bytes.get_string_from_utf8().strip_edges()
		if line == "":
			continue
		_handle_line(c.peer, line)


func _handle_line(peer: StreamPeerTCP, line: String) -> void:
	var parsed = JSON.parse_string(line)
	if typeof(parsed) != TYPE_DICTIONARY:
		_send_error(peer, null, -32700, "parse error — expected JSON object")
		return
	var id = parsed.get("id")
	var method: String = parsed.get("method", "")
	var params: Dictionary = parsed.get("params", {})
	if method == "":
		_send_error(peer, id, -32600, "missing 'method'")
		return

	var result: Dictionary = _registry.dispatch(method, params)
	# Guard against silent tool-module failures: when a tool's .gd file has a parse
	# error, preload() returns null, calls on it produce no output, and dispatch
	# returns its default {}. Surface that instead of sending {"result": null}.
	if result.is_empty():
		_send_error(peer, id, -32000,
			"tool returned empty response — likely a parse error in the tool module. Check Godot's Output panel for the actual error.",
			{"method": method})
	elif result.has("error"):
		var e: Dictionary = result.error
		_send_error(peer, id, e.get("code", -32000), e.get("message", ""), e.get("data"))
	elif result.has("data"):
		_send_result(peer, id, result.data)
	else:
		_send_error(peer, id, -32000,
			"tool returned malformed response (missing both 'data' and 'error')",
			{"method": method})


func _send_result(peer: StreamPeerTCP, id, data) -> void:
	_write(peer, {"id": id, "result": data})


func _send_error(peer: StreamPeerTCP, id, code: int, msg: String, data = null) -> void:
	var err := {"code": code, "message": msg}
	if data != null:
		err["data"] = data
	_write(peer, {"id": id, "error": err})


func _write(peer: StreamPeerTCP, obj: Dictionary) -> void:
	var line := JSON.stringify(obj) + "\n"
	peer.put_data(line.to_utf8_buffer())
