@tool
extends RefCounted

# input_map.add_action — register a new input action in project.godot.
# Params: {name, deadzone?: 0.5}
static func add_action(params: Dictionary) -> Dictionary:
	var action_name: String = params.get("name", "")
	if action_name == "":
		return _err(-32602, "missing 'name'")
	var key := "input/" + action_name
	if ProjectSettings.has_setting(key):
		return _err(-32602, "action already exists: %s" % action_name)
	ProjectSettings.set_setting(key, {
		"deadzone": float(params.get("deadzone", 0.5)),
		"events": [],
	})
	var err := ProjectSettings.save()
	if err != OK:
		return _err(-32001, "save failed: %d" % err)
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
	return _ok({"action": action_name, "event": event_spec})


# input_map.list — return registered input actions with their events.
# Params: {include_builtins?: false}
# Defaults to user-defined only (parses the [input] section of project.godot, which
# contains only user overrides — Godot's ~90 ui_* builtins live in-memory). Pass
# include_builtins:true to get everything via InputMap.
static func list_actions(params: Dictionary) -> Dictionary:
	var include_builtins: bool = params.get("include_builtins", false)
	var names: Array = []

	if include_builtins:
		for a in InputMap.get_actions():
			names.append(String(a))
	else:
		var cf := ConfigFile.new()
		var err := cf.load("res://project.godot")
		if err == OK and cf.has_section("input"):
			for k in cf.get_section_keys("input"):
				names.append(k)

	var items: Array = []
	for n in names:
		if not InputMap.has_action(n):
			continue  # action exists in project.godot but hasn't loaded (shouldn't happen)
		var described: Array = []
		for e in InputMap.action_get_events(n):
			described.append(_describe_event(e))
		items.append({
			"name": n,
			"deadzone": InputMap.action_get_deadzone(n),
			"events": described,
		})
	return _ok({"actions": items})


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
	return _ok({"removed": action_name})


static func _build_event(spec: Dictionary) -> InputEvent:
	match spec.get("type", ""):
		"key":
			var e := InputEventKey.new()
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
			e.button_index = int(spec.get("button_index", 1))
			return e
		"joy_button":
			var e := InputEventJoypadButton.new()
			e.button_index = int(spec.get("button_index", 0))
			return e
		_:
			return null


static func _describe_event(e) -> Dictionary:
	if e is InputEventKey:
		var kc: int = e.physical_keycode if e.physical_keycode != 0 else e.keycode
		return {
			"type": "key",
			"keycode": OS.get_keycode_string(kc),
			"physical": e.physical_keycode != 0,
		}
	if e is InputEventMouseButton:
		return {"type": "mouse_button", "button_index": e.button_index}
	if e is InputEventJoypadButton:
		return {"type": "joy_button", "button_index": e.button_index}
	if e is InputEventJoypadMotion:
		return {"type": "joy_motion", "axis": e.axis, "axis_value": e.axis_value}
	return {"type": "unknown", "class": (e as Object).get_class() if e else "null"}


static func _ok(data) -> Dictionary:
	return {"data": data}


static func _err(code: int, msg: String) -> Dictionary:
	return {"error": {"code": code, "message": msg}}
