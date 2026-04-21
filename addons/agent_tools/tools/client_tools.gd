@tool
extends RefCounted

# client.* — manage MCP client config files so users don't have to hand-edit them.
# Each client has its own config schema; we handle three shapes:
#   "mcp_servers"           → {"mcpServers": {"<name>": {command, args}}}
#                             Used by Claude Code, Claude Desktop, Cursor, Windsurf.
#   "vscode_servers"        → {"servers": {"<name>": {command, args}}}
#                             VS Code's native MCP config.
#   "continue_experimental" → {"experimental": {"modelContextProtocolServers":
#                                [{"transport": {"type": "stdio", command, args}}]}}
#                             Continue.dev's MCP config shape (array, not dict).
#
# Clients requiring JSONC (with comments) or non-file storage — Zed, VS Code
# user-scope settings.json, Cline — aren't supported yet. Use manual config
# for those; see the README per-client section.

const SERVER_NAME := "godot-agent-tools"
const SERVER_COMMAND := "npx"
const SERVER_ARGS := ["-y", "godot-agent-tools-mcp"]


static func list_clients(_params: Dictionary) -> Dictionary:
	var out: Array = []
	for client_id in _client_ids():
		var info := _client_info(client_id)
		if info.has("_error"):
			out.append({"client": client_id, "error": info._error})
			continue
		var cfg := _read_config(info.path)
		var installed := _has_server_entry(cfg, info.format)
		out.append({
			"client": client_id,
			"config_path": info.path,
			"exists": _path_exists(info.path),
			"configured": installed,
		})
	return _ok({"clients": out})


static func configure(params: Dictionary) -> Dictionary:
	var client_id: String = params.get("client", "")
	var overwrite: bool = params.get("overwrite", false)
	if client_id == "":
		return _err(-32602, "missing 'client' (supported: %s)" % ", ".join(_client_ids()))
	var info := _client_info(client_id)
	if info.has("_error"):
		return _err(-32602, info._error)

	var cfg := _read_config(info.path)
	if _has_server_entry(cfg, info.format) and not overwrite:
		return _ok({"client": client_id, "path": info.path, "status": "already_configured"})

	_set_server_entry(cfg, info.format)
	var write_err := _write_config(info.path, cfg)
	if write_err != "":
		return _err(-32001, write_err)
	return _ok({"client": client_id, "path": info.path, "status": "configured"})


static func remove(params: Dictionary) -> Dictionary:
	var client_id: String = params.get("client", "")
	if client_id == "":
		return _err(-32602, "missing 'client'")
	var info := _client_info(client_id)
	if info.has("_error"):
		return _err(-32602, info._error)

	var cfg := _read_config(info.path)
	if not _has_server_entry(cfg, info.format):
		return _ok({"client": client_id, "path": info.path, "status": "not_present"})

	_clear_server_entry(cfg, info.format)
	var write_err := _write_config(info.path, cfg)
	if write_err != "":
		return _err(-32001, write_err)
	return _ok({"client": client_id, "path": info.path, "status": "removed"})


static func _client_ids() -> Array:
	return [
		"claude_code_project",
		"claude_code_user",
		"claude_desktop",
		"cursor_project",
		"cursor_user",
		"windsurf_user",
		"continue_user",
		"vscode_project",
	]


static func _client_info(client_id: String) -> Dictionary:
	var home := OS.get_environment("USERPROFILE")
	if home == "":
		home = OS.get_environment("HOME")
	if home == "":
		return {"_error": "cannot resolve home directory (neither USERPROFILE nor HOME set)"}

	match client_id:
		"claude_code_project":
			return {"path": ProjectSettings.globalize_path("res://.mcp.json"), "format": "mcp_servers"}
		"claude_code_user":
			return {"path": home.path_join(".claude.json"), "format": "mcp_servers"}
		"cursor_project":
			return {"path": ProjectSettings.globalize_path("res://.cursor/mcp.json"), "format": "mcp_servers"}
		"cursor_user":
			return {"path": home.path_join(".cursor").path_join("mcp.json"), "format": "mcp_servers"}
		"windsurf_user":
			return {"path": home.path_join(".codeium").path_join("windsurf").path_join("mcp_config.json"), "format": "mcp_servers"}
		"continue_user":
			return {"path": home.path_join(".continue").path_join("config.json"), "format": "continue_experimental"}
		"vscode_project":
			return {"path": ProjectSettings.globalize_path("res://.vscode/mcp.json"), "format": "vscode_servers"}
		"claude_desktop":
			var os_name := OS.get_name()
			var path: String
			if os_name == "macOS":
				path = home.path_join("Library").path_join("Application Support").path_join("Claude").path_join("claude_desktop_config.json")
			elif os_name == "Windows":
				var appdata := OS.get_environment("APPDATA")
				if appdata == "":
					return {"_error": "APPDATA env var not set on Windows"}
				path = appdata.path_join("Claude").path_join("claude_desktop_config.json")
			else:
				path = home.path_join(".config").path_join("Claude").path_join("claude_desktop_config.json")
			return {"path": path, "format": "mcp_servers"}
		_:
			return {"_error": "unknown client: %s (supported: %s)" % [client_id, ", ".join(_client_ids())]}


static func _path_exists(path: String) -> bool:
	return FileAccess.file_exists(path)


static func _read_config(path: String) -> Dictionary:
	var content := ""
	if _path_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		if f:
			content = f.get_as_text()
			f.close()
	if content.strip_edges() == "":
		return {}
	var parsed = JSON.parse_string(content)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed


static func _write_config(path: String, cfg: Dictionary) -> String:
	var dir_path := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		var derr := DirAccess.make_dir_recursive_absolute(dir_path)
		if derr != OK:
			return "mkdir failed for %s (%d)" % [dir_path, derr]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return "could not open for write: %s (error %d)" % [path, FileAccess.get_open_error()]
	f.store_string(JSON.stringify(cfg, "  "))
	f.close()
	return ""


# --- Format-specific readers/writers -----------------------------------------

static func _has_server_entry(cfg: Dictionary, format: String) -> bool:
	match format:
		"mcp_servers":
			var servers = cfg.get("mcpServers")
			return typeof(servers) == TYPE_DICTIONARY and (servers as Dictionary).has(SERVER_NAME)
		"vscode_servers":
			var servers = cfg.get("servers")
			return typeof(servers) == TYPE_DICTIONARY and (servers as Dictionary).has(SERVER_NAME)
		"continue_experimental":
			var exp = cfg.get("experimental")
			if typeof(exp) != TYPE_DICTIONARY:
				return false
			var arr = exp.get("modelContextProtocolServers")
			if typeof(arr) != TYPE_ARRAY:
				return false
			for entry in arr:
				if typeof(entry) == TYPE_DICTIONARY and _entry_matches_continue(entry):
					return true
			return false
		_:
			return false


static func _set_server_entry(cfg: Dictionary, format: String) -> void:
	match format:
		"mcp_servers":
			if typeof(cfg.get("mcpServers")) != TYPE_DICTIONARY:
				cfg["mcpServers"] = {}
			(cfg["mcpServers"] as Dictionary)[SERVER_NAME] = {
				"command": SERVER_COMMAND,
				"args": SERVER_ARGS.duplicate(),
			}
		"vscode_servers":
			if typeof(cfg.get("servers")) != TYPE_DICTIONARY:
				cfg["servers"] = {}
			(cfg["servers"] as Dictionary)[SERVER_NAME] = {
				"command": SERVER_COMMAND,
				"args": SERVER_ARGS.duplicate(),
			}
		"continue_experimental":
			if typeof(cfg.get("experimental")) != TYPE_DICTIONARY:
				cfg["experimental"] = {}
			var exp: Dictionary = cfg["experimental"]
			if typeof(exp.get("modelContextProtocolServers")) != TYPE_ARRAY:
				exp["modelContextProtocolServers"] = []
			var arr: Array = exp["modelContextProtocolServers"]
			# Remove any existing match so we don't duplicate.
			var kept: Array = []
			for entry in arr:
				if typeof(entry) != TYPE_DICTIONARY or not _entry_matches_continue(entry):
					kept.append(entry)
			kept.append({
				"transport": {
					"type": "stdio",
					"command": SERVER_COMMAND,
					"args": SERVER_ARGS.duplicate(),
				},
			})
			exp["modelContextProtocolServers"] = kept


static func _clear_server_entry(cfg: Dictionary, format: String) -> void:
	match format:
		"mcp_servers":
			var servers = cfg.get("mcpServers")
			if typeof(servers) == TYPE_DICTIONARY:
				(servers as Dictionary).erase(SERVER_NAME)
		"vscode_servers":
			var servers = cfg.get("servers")
			if typeof(servers) == TYPE_DICTIONARY:
				(servers as Dictionary).erase(SERVER_NAME)
		"continue_experimental":
			var exp = cfg.get("experimental")
			if typeof(exp) != TYPE_DICTIONARY:
				return
			var arr = exp.get("modelContextProtocolServers")
			if typeof(arr) != TYPE_ARRAY:
				return
			var kept: Array = []
			for entry in arr:
				if typeof(entry) != TYPE_DICTIONARY or not _entry_matches_continue(entry):
					kept.append(entry)
			exp["modelContextProtocolServers"] = kept


# Continue's config uses a flat array with no `name` field — identify our entry
# by the transport command+args combo.
static func _entry_matches_continue(entry: Dictionary) -> bool:
	var transport = entry.get("transport")
	if typeof(transport) != TYPE_DICTIONARY:
		return false
	if transport.get("command") != SERVER_COMMAND:
		return false
	var a = transport.get("args")
	if typeof(a) != TYPE_ARRAY or (a as Array).size() < 2:
		return false
	return a[1] == SERVER_ARGS[1]


static func _ok(data) -> Dictionary:
	return {"data": data}


static func _err(code: int, msg: String) -> Dictionary:
	return {"error": {"code": code, "message": msg}}
