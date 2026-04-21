@tool
extends RefCounted

# performance.monitors — read Godot's built-in performance monitors.
# Params: {monitors?: [string]}   — specific monitor names, default = common set
# Returns: {fps, frame_time_ms, process_time_ms, physics_time_ms, mem_static_mb,
#           mem_dynamic_mb, objects, resources, nodes, draw_calls, ...}
static func monitors(params: Dictionary) -> Dictionary:
	var requested: Array = params.get("monitors", [])
	var out: Dictionary = {}

	# Default set — the monitors agents actually want for quick perf snapshots.
	if requested.is_empty():
		out["fps"] = Performance.get_monitor(Performance.TIME_FPS)
		out["frame_time_ms"] = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		out["physics_time_ms"] = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		out["mem_static_mb"] = Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0
		out["mem_static_max_mb"] = Performance.get_monitor(Performance.MEMORY_STATIC_MAX) / 1048576.0
		out["object_count"] = int(Performance.get_monitor(Performance.OBJECT_COUNT))
		out["resource_count"] = int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT))
		out["node_count"] = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
		out["orphan_node_count"] = int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
		out["draw_calls"] = int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	else:
		for name in requested:
			var enum_value := _resolve_monitor_name(String(name))
			if enum_value == -1:
				out[name] = null
			else:
				out[name] = Performance.get_monitor(enum_value)

	return _ok({"monitors": out})


# Map friendly strings to Performance.* enum values so callers don't have to
# remember the integer IDs.
static func _resolve_monitor_name(name: String) -> int:
	match name:
		"fps": return Performance.TIME_FPS
		"frame_time": return Performance.TIME_PROCESS
		"physics_time": return Performance.TIME_PHYSICS_PROCESS
		"mem_static": return Performance.MEMORY_STATIC
		"mem_static_max": return Performance.MEMORY_STATIC_MAX
		"objects": return Performance.OBJECT_COUNT
		"resources": return Performance.OBJECT_RESOURCE_COUNT
		"nodes": return Performance.OBJECT_NODE_COUNT
		"orphan_nodes": return Performance.OBJECT_ORPHAN_NODE_COUNT
		"draw_calls": return Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME
		"audio_latency": return Performance.AUDIO_OUTPUT_LATENCY
		"physics_2d_active_objects": return Performance.PHYSICS_2D_ACTIVE_OBJECTS
		"physics_3d_active_objects": return Performance.PHYSICS_3D_ACTIVE_OBJECTS
		_: return -1


static func _ok(data) -> Dictionary:
	return {"data": data}
