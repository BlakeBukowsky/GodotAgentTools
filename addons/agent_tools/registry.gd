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


# Returns {"data": <any>} on success, {"error": {"code": int, "message": str}} on failure.
# Tool funcs follow the same convention so dispatch is a straight passthrough.
func dispatch(method: String, params: Dictionary) -> Dictionary:
	match method:
		"scene.inspect":          return SceneTools.inspect(params)
		"scene.new":              return SceneTools.new_scene(params)
		"scene.add_node":         return SceneTools.add_node(params)
		"scene.instance_packed":  return SceneTools.instance_packed(params)
		"scene.remove_node":      return SceneTools.remove_node(params)
		"scene.reparent":         return SceneTools.reparent(params)
		"scene.set_property":     return SceneTools.set_property(params)
		"scene.open":             return SceneTools.open_scene(params)
		"scene.save":             return SceneTools.save_scene(params)
		"scene.current":          return SceneTools.current(params)
		"signal.connect":         return SignalTools.connect_signal(params)
		"signal.disconnect":      return SignalTools.disconnect_signal(params)
		"signal.list":            return SignalTools.list_signals(params)
		"script.create":          return ScriptTools.create(params)
		"script.attach":          return ScriptTools.attach(params)
		"resource.create":        return ResourceTools.create(params)
		"resource.set_property":  return ResourceTools.set_property(params)
		"refs.validate_project":  return RefsTools.validate_project(params)
		"refs.find_usages":       return RefsTools.find_usages(params)
		"refs.rename":            return RefsTools.rename(params)
		"project.get_setting":    return ProjectTools.get_setting(params)
		"project.set_setting":    return ProjectTools.set_setting(params)
		"autoload.add":           return ProjectTools.autoload_add(params)
		"autoload.remove":        return ProjectTools.autoload_remove(params)
		"autoload.list":          return ProjectTools.autoload_list(params)
		"editor.reload_filesystem": return EditorTools.reload_filesystem(params)
		"docs.class_ref":         return DocsTools.class_ref(params)
		"input_map.add_action":   return InputTools.add_action(params)
		"input_map.add_event":    return InputTools.add_event(params)
		"input_map.list":         return InputTools.list_actions(params)
		"input_map.remove_action": return InputTools.remove_action(params)
		"run.scene_headless":     return RunTools.scene_headless(params)
		_:
			return {"error": {"code": -32601, "message": "method not found: %s" % method}}
