# MCPGameBridge — runtime autoload registered by the Agent Tools plugin.
#
# Bridges the editor-side agent tools to the *running* game via a file-based
# request/response channel under res://.godot/agent_tools/bridge/. Currently:
#   - screenshot: capture the running viewport, save to a path
#   - logs:       append print/push_error/push_warning output to a buffer
#
# This script ONLY runs in the game process (checks Engine.is_editor_hint()
# on startup and disables itself in the editor). The editor plugin registers
# it via add_autoload_singleton() on _enter_tree and removes it on _exit_tree.

extends Node

const BridgeLogger := preload("res://addons/agent_tools/runtime/bridge_logger.gd")
const BRIDGE_DIR := "res://.godot/agent_tools/bridge"
const REQUEST_PATH := BRIDGE_DIR + "/request.json"
const RESPONSE_PATH := BRIDGE_DIR + "/response.json"
const LOGS_PATH := BRIDGE_DIR + "/logs.json"
const POLL_INTERVAL_SEC := 0.05  # 20 Hz — cheap enough, responsive enough
const LOG_BUFFER_MAX := 500

var _timer: Timer
var _log_buffer: Array = []
var _initialized := false


func _ready() -> void:
	if Engine.is_editor_hint():
		# Tool mode — don't do anything inside the editor. The bridge only
		# makes sense in the running game.
		return
	_initialized = true
	_ensure_bridge_dir()
	# Poll for editor requests on a timer so we don't eat a _process callback.
	_timer = Timer.new()
	_timer.wait_time = POLL_INTERVAL_SEC
	_timer.one_shot = false
	_timer.autostart = true
	_timer.timeout.connect(_poll_request)
	add_child(_timer)
	# Attach our custom logger to capture print / push_error / push_warning
	# from the game and mirror them to the log buffer file so logs.read can
	# pick them up from the editor side.
	var logger := BridgeLogger.new(self)
	OS.add_logger(logger)


func _ensure_bridge_dir() -> void:
	if not DirAccess.dir_exists_absolute(BRIDGE_DIR):
		@warning_ignore("return_value_discarded")
		DirAccess.make_dir_recursive_absolute(BRIDGE_DIR)


# Called by MCPBridgeLogger whenever the game writes to stdout/stderr.
func log_entry(level: String, message: String) -> void:
	_log_buffer.append({
		"level": level,
		"message": message,
		"time_ms": Time.get_ticks_msec(),
	})
	if _log_buffer.size() > LOG_BUFFER_MAX:
		_log_buffer = _log_buffer.slice(_log_buffer.size() - LOG_BUFFER_MAX)
	# Flush to disk so editor-side logs.read sees it. Debounced by poll interval
	# in practice because each log call flushes but writes are cheap.
	_flush_logs()


func _flush_logs() -> void:
	var f := FileAccess.open(LOGS_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(_log_buffer))
	f.close()


func _poll_request() -> void:
	if not FileAccess.file_exists(REQUEST_PATH):
		return
	var f := FileAccess.open(REQUEST_PATH, FileAccess.READ)
	if f == null:
		return
	var body := f.get_as_text()
	f.close()
	@warning_ignore("return_value_discarded")
	DirAccess.remove_absolute(REQUEST_PATH)

	var parsed = JSON.parse_string(body)
	if typeof(parsed) != TYPE_DICTIONARY:
		_write_response({"id": "", "error": "malformed request"})
		return
	var req_id: String = parsed.get("id", "")
	match parsed.get("type", ""):
		"screenshot":
			_handle_screenshot(req_id, parsed)
		_:
			_write_response({"id": req_id, "error": "unknown request type: %s" % parsed.get("type", "<missing>")})


func _handle_screenshot(req_id: String, req: Dictionary) -> void:
	var output_path: String = req.get("output", "")
	if output_path == "":
		_write_response({"id": req_id, "error": "missing 'output'"})
		return
	var vp := get_viewport()
	if vp == null:
		_write_response({"id": req_id, "error": "no viewport available"})
		return
	var tex := vp.get_texture()
	if tex == null:
		_write_response({"id": req_id, "error": "viewport has no texture"})
		return
	var img := tex.get_image()
	if img == null or img.is_empty():
		_write_response({"id": req_id, "error": "failed to capture image"})
		return
	var dir := output_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		@warning_ignore("return_value_discarded")
		DirAccess.make_dir_recursive_absolute(dir)
	var save_err := img.save_png(output_path)
	if save_err != OK:
		_write_response({"id": req_id, "error": "save_png failed: %d" % save_err})
		return
	_write_response({"id": req_id, "path": output_path})


func _write_response(payload: Dictionary) -> void:
	var f := FileAccess.open(RESPONSE_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(payload))
	f.close()


