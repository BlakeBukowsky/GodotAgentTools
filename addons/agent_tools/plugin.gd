@tool
extends EditorPlugin

const Server := preload("res://addons/agent_tools/server.gd")
const Registry := preload("res://addons/agent_tools/registry.gd")

const DEFAULT_PORT := 9920
const PORT_RANGE_END := 9929  # scan 9920..9929 inclusive
const PORT_SETTING := "agent_tools/port"
const BRIDGE_AUTOLOAD_NAME := "_MCPGameBridge"
const BRIDGE_AUTOLOAD_PATH := "res://addons/agent_tools/runtime/game_bridge.gd"

const DEFAULT_INTERFACE := "127.0.0.1"
const INTERFACE_SETTING := "agent_tools/interface"

var _server: Server
var _registry: Registry
var _bound_port: int = -1
var _session_file_path: String = ""


func _enter_tree() -> void:
	_registry = Registry.new()
	_server = Server.new(_registry)
	add_child(_server)

	# Interface resolution
	# Defaults to 127.0.0.1, override with project.godot agent_tools/interface
	var forced_interface := DEFAULT_INTERFACE
	if ProjectSettings.has_setting(INTERFACE_SETTING):
		forced_interface = ProjectSettings.get_setting(INTERFACE_SETTING)

	# Port resolution:
	#   1. If 'agent_tools/port' is set in project.godot, honor it strictly (fail if busy).
	#   2. Otherwise try DEFAULT_PORT..PORT_RANGE_END and use the first free one.
	# This lets multiple Godot editors coexist: first-to-start takes 9920, second takes 9921, etc.
	var forced_port := -1
	if ProjectSettings.has_setting(PORT_SETTING):
		forced_port = int(ProjectSettings.get_setting(PORT_SETTING))

	if forced_port != -1:
		if _server.start(forced_port, forced_interface):
			_bound_port = forced_port
		else:
			push_error("[agent_tools] configured port %s:%d is busy. Either close the other process or change 'agent_tools/port' in project.godot." % [forced_interface, forced_port])
	else:
		for p in range(DEFAULT_PORT, PORT_RANGE_END + 1):
			if _server.start(p, forced_interface):
				_bound_port = p
				break
		if _bound_port == -1:
			push_error("[agent_tools] all ports %d-%d are busy on %s. Close other Godot editors running agent_tools, or set 'agent_tools/port' in project.godot." % [DEFAULT_PORT, PORT_RANGE_END, forced_interface])

	if _bound_port != -1:
		print("[agent_tools] listening on %s:%d" % [forced_interface, _bound_port])
		print("[agent_tools] If you haven't already, configure your MCP client (Claude Code, Cursor, Cline, etc.) to use these tools.")
		print("[agent_tools] Setup guide: https://github.com/BlakeBukowsky/GodotTools#configure-your-agent")
		_write_session_registry()

	# Register the runtime bridge autoload so editor.game_screenshot / logs.read
	# can reach the running game. add_autoload_singleton() writes an entry to
	# project.godot; remove_autoload_singleton() in _exit_tree cleans it up.
	if not ProjectSettings.has_setting("autoload/" + BRIDGE_AUTOLOAD_NAME):
		add_autoload_singleton(BRIDGE_AUTOLOAD_NAME, BRIDGE_AUTOLOAD_PATH)


func _exit_tree() -> void:
	_remove_session_registry()
	if _server:
		_server.stop()
		_server.queue_free()
		_server = null
	_registry = null
	_bound_port = -1
	if ProjectSettings.has_setting("autoload/" + BRIDGE_AUTOLOAD_NAME):
		remove_autoload_singleton(BRIDGE_AUTOLOAD_NAME)


# Session registry is a per-PID JSON file under a cross-project, user-scoped
# directory. The MCP shim reads these on startup so `session.list` can discover
# every running Godot editor + which port to talk to each.
func _write_session_registry() -> void:
	var dir_path := _session_registry_dir()
	if dir_path == "":
		return
	if not DirAccess.dir_exists_absolute(dir_path):
		var derr := DirAccess.make_dir_recursive_absolute(dir_path)
		if derr != OK:
			push_warning("[agent_tools] could not create session registry dir: %s" % dir_path)
			return
	var pid := OS.get_process_id()
	_session_file_path = dir_path.path_join("%d.json" % pid)

	var project_name := ""
	if ProjectSettings.has_setting("application/config/name"):
		project_name = str(ProjectSettings.get_setting("application/config/name"))
	var version := Engine.get_version_info()

	var entry := {
		"pid": pid,
		"port": _bound_port,
		"project_path": ProjectSettings.globalize_path("res://"),
		"project_name": project_name,
		"godot_version": "%d.%d.%d-%s" % [version.major, version.minor, version.patch, version.status],
		"started_at_unix": int(Time.get_unix_time_from_system()),
	}
	var f := FileAccess.open(_session_file_path, FileAccess.WRITE)
	if f == null:
		push_warning("[agent_tools] could not write session file: %s" % _session_file_path)
		return
	f.store_string(JSON.stringify(entry, "  "))
	f.close()


func _remove_session_registry() -> void:
	if _session_file_path == "":
		return
	if FileAccess.file_exists(_session_file_path):
		@warning_ignore("return_value_discarded")
		DirAccess.remove_absolute(_session_file_path)
	_session_file_path = ""


# Cross-project location: <user home>/.godot-agent-tools/sessions/. Chosen to
# sit outside any single project's res:// or user:// tree.
func _session_registry_dir() -> String:
	var home := OS.get_environment("USERPROFILE")
	if home == "":
		home = OS.get_environment("HOME")
	if home == "":
		return ""
	return home.path_join(".godot-agent-tools").path_join("sessions")
