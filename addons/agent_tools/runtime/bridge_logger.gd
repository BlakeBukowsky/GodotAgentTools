# Custom Logger that forwards every captured message to the game bridge's
# log buffer. Has to live in its own top-level file — nested classes don't
# reliably register Logger's virtual overrides (_log_error / _log_message).

extends Logger

var _bridge: Node


func _init(bridge: Node) -> void:
	_bridge = bridge


func _log_error(function: String, file: String, line: int, code: String, rationale: String, editor_notify: bool, error_type: int, script_backtraces: Array) -> void:
	# error_type is Logger.ErrorType: 0=ERROR, 1=WARNING, 2=SCRIPT, 3=SHADER.
	var level: String
	match error_type:
		1: level = "WARNING"
		2: level = "SCRIPT"
		3: level = "SHADER"
		_: level = "ERROR"
	var msg: String = rationale if rationale != "" else code
	if file != "" and line > 0:
		msg += "  (at %s:%d in %s)" % [file, line, function]
	if _bridge and _bridge.has_method("log_entry"):
		_bridge.log_entry(level, msg)


func _log_message(message: String, error: bool) -> void:
	if _bridge and _bridge.has_method("log_entry"):
		_bridge.log_entry("ERROR" if error else "INFO", message.strip_edges())
