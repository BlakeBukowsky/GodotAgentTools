@tool
extends RefCounted

# input_map.add_action — register a new input action in project.godot.
# Params: {name, deadzone?: 0.5}
static func add_action(params: Dictionary) -> Dictionary:
	var action_name: String = params.get("name", "")
	if action_name == "":
		return _err(-32602, "missing 'name'")
	var deadzone: float = float(params.get("deadzone", 0.5))
	var key := "input/" + action_name
	if ProjectSettings.has_setting(key):
		return _err(-32602, "action already exists: %s" % action_name)
	ProjectSettings.set_setting(key, {
		"deadzone": deadzone,
		"events": [],
	})
	var err := ProjectSettings.save()
	if err != OK:
		return _err(-32001, "save failed: %d" % err)
	# Keep the runtime InputMap in sync with the on-disk project settings —
	# ProjectSettings.save() only writes the file; it doesn't register actions
	# with InputMap until editor restart.
	if not InputMap.has_action(action_name):
		InputMap.add_action(action_name, deadzone)
	return _ok({"added": action_name})


# input_map.add_event — attach an input event to an existing action.
# Supported event shapes (pick one via 'type'):
#   {type: "key",          keycode: "A" | "Space" | "F1" ...,  physical?: true}
#   {type: "mouse_button", button_index: 1 (left) | 2 (right) | 3 (middle)}
#   {type: "joy_button",   button_index: 0..}
# Params: {action, event: <shape above>}
static func add_event(params: Dictionary) -> Dictionary:
	var action_name: String = params.get("action", "")
	var event_spec: Dictionary = params.get("event", {})
	if action_name == "":
		return _err(-32602, "missing 'action'")
	if event_spec.is_empty():
		return _err(-32602, "missing 'event'")
	var key := "input/" + action_name
	if not ProjectSettings.has_setting(key):
		return _err(-32001, "action not found: %s" % action_name)

	var event := _build_event(event_spec)
	if event == null:
		return _err(-32602, "invalid event spec — see tool description for supported shapes")

	var current: Dictionary = ProjectSettings.get_setting(key)
	var events_arr: Array = current.get("events", [])
	events_arr.append(event)
	current["events"] = events_arr
	ProjectSettings.set_setting(key, current)
	var err := ProjectSettings.save()
	if err != OK:
		return _err(-32001, "save failed: %d" % err)
	# Sync InputMap so Input.is_action_pressed() etc. see the event without restart.
	if InputMap.has_action(action_name):
		InputMap.action_add_event(action_name, event)
	return _ok({"action": action_name, "event": event_spec})


# input_map.list — return registered input actions with their events.
# Params: {include_builtins?: false}
# Defaults to user-defined only (parses the [input] section of project.godot,
# which contains only user overrides — Godot's ~90 ui_* builtins live in-memory).
# When include_builtins, falls back to InputMap which has the full union.
static func list_actions(params: Dictionary) -> Dictionary:
	var include_builtins: bool = params.get("include_builtins", false)
	var items: Array = []

	if include_builtins:
		for a in InputMap.get_actions():
			var described: Array = []
			for e in InputMap.action_get_events(a):
				described.append(_describe_event(e))
			items.append({
				"name": String(a),
				"deadzone": InputMap.action_get_deadzone(a),
				"events": described,
			})
	else:
		# Read straight from project.godot so newly-added actions show up even
		# if they haven't been registered with the runtime InputMap yet.
		var cf := ConfigFile.new()
		var err := cf.load("res://project.godot")
		if err == OK and cf.has_section("input"):
			for action_name in cf.get_section_keys("input"):
				var value: Dictionary = cf.get_value("input", action_name)
				var described: Array = []
				for e in value.get("events", []):
					described.append(_describe_event(e))
				items.append({
					"name": action_name,
					"deadzone": value.get("deadzone", 0.5),
					"events": described,
				})

	return _ok({"actions": items})


# input_map.remove_event — remove an event from an action by index.
# Call input_map.list first to see indices; events are listed in the order they
# were added.
# Params: {action, event_index}
static func remove_event(params: Dictionary) -> Dictionary:
	var action_name: String = params.get("action", "")
	if action_name == "":
		return _err(-32602, "missing 'action'")
	if not params.has("event_index"):
		return _err(-32602, "missing 'event_index'")
	var idx: int = int(params.event_index)
	var key := "input/" + action_name
	if not ProjectSettings.has_setting(key):
		return _err(-32001, "action not found: %s" % action_name)
	var current: Dictionary = ProjectSettings.get_setting(key)
	var events_arr: Array = current.get("events", [])
	if idx < 0 or idx >= events_arr.size():
		return _err(-32602, "event_index %d out of range (0..%d)" % [idx, events_arr.size() - 1])
	var removed_event = events_arr[idx]
	events_arr.remove_at(idx)
	current["events"] = events_arr
	ProjectSettings.set_setting(key, current)
	var err := ProjectSettings.save()
	if err != OK:
		return _err(-32001, "save failed: %d" % err)
	if InputMap.has_action(action_name) and removed_event != null:
		InputMap.action_erase_event(action_name, removed_event)
	return _ok({"action": action_name, "removed_index": idx})


# input_map.remove_action — delete a user-registered action.
static func remove_action(params: Dictionary) -> Dictionary:
	var action_name: String = params.get("name", "")
	if action_name == "":
		return _err(-32602, "missing 'name'")
	var key := "input/" + action_name
	if not ProjectSettings.has_setting(key):
		return _err(-32001, "action not found: %s" % action_name)
	ProjectSettings.clear(key)
	var err := ProjectSettings.save()
	if err != OK:
		return _err(-32001, "save failed: %d" % err)
	if InputMap.has_action(action_name):
		InputMap.erase_action(action_name)
	return _ok({"removed": action_name})


static func _build_event(spec: Dictionary) -> InputEvent:
	# device defaults to -1 (ALL_DEVICES) matching the editor's "All Devices" default.
	# For local multiplayer bind device=0, device=1, etc. to distinguish controllers.
	var device: int = int(spec.get("device", -1))
	match spec.get("type", ""):
		"key":
			var e := InputEventKey.new()
			e.device = device
			var kc_raw = spec.get("keycode", "")
			var keycode := 0
			if kc_raw is int:
				keycode = kc_raw
			elif kc_raw is String:
				keycode = OS.find_keycode_from_string(kc_raw)
			if keycode == 0:
				return null
			if spec.get("physical", true):
				e.physical_keycode = keycode
			else:
				e.keycode = keycode
			return e
		"mouse_button":
			var e := InputEventMouseButton.new()
			e.device = device
			e.button_index = int(spec.get("button_index", 1))
			return e
		"joy_button":
			var e := InputEventJoypadButton.new()
			e.device = device
			e.button_index = int(spec.get("button_index", 0))
			return e
		"joy_motion":
			# axis accepts int 0..5 or one of:
			#   "left_x" / "left_y" / "right_x" / "right_y" / "trigger_left" / "trigger_right"
			# axis_value: -1.0 (full negative) to 1.0 (full positive); sign picks the direction
			# that triggers the action.
			var e := InputEventJoypadMotion.new()
			e.device = device
			e.axis = _coerce_axis(spec.get("axis", 0))
			e.axis_value = float(spec.get("axis_value", 1.0))
			return e
		_:
			return null


static func _coerce_axis(v) -> int:
	if v is int:
		return v
	if v is String:
		match v:
			"left_x":
				return JOY_AXIS_LEFT_X
			"left_y":
				return JOY_AXIS_LEFT_Y
			"right_x":
				return JOY_AXIS_RIGHT_X
			"right_y":
				return JOY_AXIS_RIGHT_Y
			"trigger_left":
				return JOY_AXIS_TRIGGER_LEFT
			"trigger_right":
				return JOY_AXIS_TRIGGER_RIGHT
	return 0


static func _describe_event(e) -> Dictionary:
	if e is InputEventKey:
		var kc: int = e.physical_keycode if e.physical_keycode != 0 else e.keycode
		return {
			"type": "key",
			"keycode": OS.get_keycode_string(kc),
			"physical": e.physical_keycode != 0,
			"device": e.device,
		}
	if e is InputEventMouseButton:
		return {"type": "mouse_button", "button_index": e.button_index, "device": e.device}
	if e is InputEventJoypadButton:
		return {"type": "joy_button", "button_index": e.button_index, "device": e.device}
	if e is InputEventJoypadMotion:
		return {
			"type": "joy_motion",
			"axis": e.axis,
			"axis_value": e.axis_value,
			"device": e.device,
		}
	return {"type": "unknown", "class": (e as Object).get_class() if e else "null"}


static func _ok(data) -> Dictionary:
	return {"data": data}


static func _err(code: int, msg: String) -> Dictionary:
	return {"error": {"code": code, "message": msg}}
