@tool
extends RefCounted

const SceneTools := preload("res://addons/agent_tools/tools/scene_tools.gd")
const SignalTools := preload("res://addons/agent_tools/tools/signal_tools.gd")
const ScriptTools := preload("res://addons/agent_tools/tools/script_tools.gd")
const ResourceTools := preload("res://addons/agent_tools/tools/resource_tools.gd")
const RefsTools := preload("res://addons/agent_tools/tools/refs_tools.gd")
const ProjectTools := preload("res://addons/agent_tools/tools/project_tools.gd")
const EditorTools := preload("res://addons/agent_tools/tools/editor_tools.gd")
const DocsTools := preload("res://addons/agent_tools/tools/docs_tools.gd")
const InputTools := preload("res://addons/agent_tools/tools/input_tools.gd")
const RunTools := preload("res://addons/agent_tools/tools/run_tools.gd")
const FsTools := preload("res://addons/agent_tools/tools/fs_tools.gd")
const AnimationTools := preload("res://addons/agent_tools/tools/animation_tools.gd")
const UserFsTools := preload("res://addons/agent_tools/tools/user_fs_tools.gd")
const PerformanceTools := preload("res://addons/agent_tools/tools/performance_tools.gd")
const TestTools := preload("res://addons/agent_tools/tools/test_tools.gd")
const ClientTools := preload("res://addons/agent_tools/tools/client_tools.gd")
const PhysicsTools := preload("res://addons/agent_tools/tools/physics_tools.gd")
const ThemeTools := preload("res://addons/agent_tools/tools/theme_tools.gd")


# Returns {"data": <any>} on success, {"error": {"code": int, "message": str}} on failure.
func dispatch(method: String, params: Dictionary) -> Dictionary:
	match method:
		"scene.new":              return SceneTools.new_scene(params)
		"scene.add_node":         return SceneTools.add_node(params)
		"scene.instance_packed":  return SceneTools.instance_packed(params)
		"scene.duplicate_node":   return SceneTools.duplicate_node(params)
		"scene.remove_node":      return SceneTools.remove_node(params)
		"scene.reparent":         return SceneTools.reparent(params)
		"scene.set_property":     return SceneTools.set_property(params)
		"scene.get_property":     return SceneTools.get_property(params)
		"scene.call_method":      return SceneTools.call_method(params)
		"scene.build_tree":       return SceneTools.build_tree(params)
		"scene.open":             return SceneTools.open_scene(params)
		"scene.save":             return SceneTools.save_scene(params)
		"scene.current":          return SceneTools.current(params)
		"scene.inspect":          return SceneTools.inspect(params)
		"scene.capture_screenshot": return SceneTools.capture_screenshot(params)
		"signal.connect":         return SignalTools.connect_signal(params)
		"signal.disconnect":      return SignalTools.disconnect_signal(params)
		"signal.list":            return SignalTools.list_signals(params)
		"script.create":          return ScriptTools.create(params)
		"script.attach":          return ScriptTools.attach(params)
		"script.patch":           return ScriptTools.patch(params)
		"resource.create":        return ResourceTools.create(params)
		"resource.set_property":  return ResourceTools.set_property(params)
		"resource.call_method":   return ResourceTools.call_method(params)
		"refs.validate_project":  return RefsTools.validate_project(params)
		"refs.find_usages":       return RefsTools.find_usages(params)
		"refs.rename":            return RefsTools.rename(params)
		"refs.rename_class":      return RefsTools.rename_class(params)
		"project.get_setting":    return ProjectTools.get_setting(params)
		"project.set_setting":    return ProjectTools.set_setting(params)
		"autoload.add":           return ProjectTools.autoload_add(params)
		"autoload.remove":        return ProjectTools.autoload_remove(params)
		"autoload.list":          return ProjectTools.autoload_list(params)
		"editor.reload_filesystem": return EditorTools.reload_filesystem(params)
		"editor.save_all_scenes": return EditorTools.save_all_scenes(params)
		"editor.state":           return EditorTools.state(params)
		"editor.selection_get":   return EditorTools.selection_get(params)
		"editor.selection_set":   return EditorTools.selection_set(params)
		"editor.game_screenshot": return EditorTools.game_screenshot(params)
		"logs.read":              return EditorTools.logs_read(params)
		"logs.clear":             return EditorTools.logs_clear(params)
		"docs.class_ref":         return DocsTools.class_ref(params)
		"input_map.add_action":   return InputTools.add_action(params)
		"input_map.add_event":    return InputTools.add_event(params)
		"input_map.list":         return InputTools.list_actions(params)
		"input_map.remove_action": return InputTools.remove_action(params)
		"input_map.remove_event": return InputTools.remove_event(params)
		"run.scene_headless":     return RunTools.scene_headless(params)
		"fs.list":                return FsTools.list(params)
		"fs.read_text":           return FsTools.read_text(params)
		"fs.write_text":          return FsTools.write_text(params)
		"user_fs.read":           return UserFsTools.read(params)
		"user_fs.list":           return UserFsTools.list(params)
		"animation.list":         return AnimationTools.list_animations(params)
		"animation.add_animation": return AnimationTools.add_animation(params)
		"animation.remove_animation": return AnimationTools.remove_animation(params)
		"animation.add_value_track": return AnimationTools.add_value_track(params)
		"performance.monitors":   return PerformanceTools.monitors(params)
		"test.run":               return TestTools.run(params)
		"client.list":            return ClientTools.list_clients(params)
		"client.configure":       return ClientTools.configure(params)
		"client.remove":          return ClientTools.remove(params)
		"physics.autofit_collision_shape_2d": return PhysicsTools.autofit_collision_shape_2d(params)
		"theme.set_color":        return ThemeTools.set_color(params)
		"theme.set_constant":     return ThemeTools.set_constant(params)
		"theme.set_font_size":    return ThemeTools.set_font_size(params)
		"theme.set_stylebox_flat": return ThemeTools.set_stylebox_flat(params)
		"batch.execute":          return batch_execute(params)
		_:
			return {"error": {"code": -32601, "message": "method not found: %s" % method}}


# batch.execute — run multiple tool calls in one round trip.
# Params: {calls: [{method, params?}, ...], stop_on_error?: false}
# Returns: {results: [{method, ok, data|error, index}, ...]}
func batch_execute(params: Dictionary) -> Dictionary:
	var calls: Array = params.get("calls", [])
	var stop_on_error: bool = params.get("stop_on_error", false)
	if calls.is_empty():
		return {"error": {"code": -32602, "message": "missing 'calls' (array of {method, params})"}}

	var results: Array = []
	for i in calls.size():
		var entry = calls[i]
		if typeof(entry) != TYPE_DICTIONARY or not entry.has("method"):
			results.append({"index": i, "ok": false, "error": "each call needs {method, params?}"})
			if stop_on_error:
				break
			continue
		var sub_method: String = entry.method
		var sub_params: Dictionary = entry.get("params", {})
		var sub_result: Dictionary = dispatch(sub_method, sub_params)
		var row := {"index": i, "method": sub_method}
		if sub_result.has("error"):
			row["ok"] = false
			row["error"] = sub_result.error
		else:
			row["ok"] = true
			row["data"] = sub_result.get("data")
		results.append(row)
		if stop_on_error and not row.ok:
			break
	return {"data": {"results": results, "count": results.size(), "requested": calls.size()}}
