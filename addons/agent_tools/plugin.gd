@tool
extends EditorPlugin

const Server := preload("res://addons/agent_tools/server.gd")
const Registry := preload("res://addons/agent_tools/registry.gd")

const DEFAULT_PORT := 9920

var _server: Server
var _registry: Registry


func _enter_tree() -> void:
	_registry = Registry.new()
	_server = Server.new(_registry)
	add_child(_server)
	_server.start(DEFAULT_PORT)
	print("[agent_tools] listening on 127.0.0.1:%d" % DEFAULT_PORT)
	print("[agent_tools] If you haven't already, configure your MCP client (Claude Code, Cursor, Cline, etc.) to use these tools.")
	print("[agent_tools] Setup guide: https://github.com/BlakeBukowsky/GodotTools#configure-your-agent")


func _exit_tree() -> void:
	if _server:
		_server.stop()
		_server.queue_free()
		_server = null
	_registry = null
