@tool
extends RefCounted

# test.run — detect and run a GDScript test framework, return structured results.
#
# Supports GUT (addons/gut) and GdUnit4 (addons/gdUnit4). Auto-detects which is
# installed; caller can force with 'framework'. Runs via headless subprocess so
# it doesn't block the editor.
#
# Params: {
#   framework?: "auto" | "gut" | "gdunit4",
#   directory?: "res://test",   # test directory; defaults by framework
#   pattern?: "test_*.gd",       # file name pattern; defaults by framework
#   timeout_seconds?: 60,
# }
#
# Returns: {
#   framework: "gut" | "gdunit4",
#   total, passed, failed, skipped,
#   failures: [{name, file, line, message}],
#   raw_output: string,
#   exit_code,
# }
static func run(params: Dictionary) -> Dictionary:
	var framework: String = params.get("framework", "auto")
	var directory: String = params.get("directory", "")
	var pattern: String = params.get("pattern", "")
	var timeout_seconds: int = int(params.get("timeout_seconds", 60))

	if framework == "auto":
		framework = _detect_framework()
		if framework == "":
			return _err(-32001,
				"no test framework detected. Install GUT (addons/gut) or GdUnit4 (addons/gdUnit4), " +
				"or pass 'framework' explicitly.")

	var runner_info := _runner_for(framework, directory, pattern)
	if runner_info.has("_error"):
		return _err(-32001, runner_info._error)

	var exe := OS.get_executable_path()
	var project_dir := ProjectSettings.globalize_path("res://")
	var args: Array = ["--path", project_dir, "--headless"]
	for a in runner_info.args:
		args.append(str(a))

	var output: Array = []
	var exit_code := OS.execute(exe, args, output, true)
	var stdout: String = ""
	if output.size() > 0:
		stdout = str(output[0])

	var parsed: Dictionary
	match framework:
		"gut": parsed = _parse_gut_output(stdout)
		"gdunit4": parsed = _parse_gdunit4_output(stdout)
		_: parsed = {"total": 0, "passed": 0, "failed": 0, "skipped": 0, "failures": []}

	parsed["framework"] = framework
	parsed["exit_code"] = exit_code
	# Strip ANSI escape codes from raw_output so the JSON wire is always clean.
	# Godot's JSON.stringify doesn't escape every control char; leaving \x1b in
	# the string breaks strict JSON parsers downstream.
	parsed["raw_output"] = _strip_ansi(stdout)
	parsed["command"] = "%s %s" % [exe, " ".join(args)]
	return _ok(parsed)


static func _detect_framework() -> String:
	if DirAccess.dir_exists_absolute("res://addons/gut"):
		return "gut"
	if DirAccess.dir_exists_absolute("res://addons/gdUnit4"):
		return "gdunit4"
	return ""


static func _runner_for(framework: String, directory: String, pattern: String) -> Dictionary:
	match framework:
		"gut":
			var gut_cmdln := "res://addons/gut/gut_cmdln.gd"
			if not FileAccess.file_exists(gut_cmdln):
				return {"_error": "GUT framework dir exists but gut_cmdln.gd not found — GUT install may be broken"}
			var args: Array = ["-s", gut_cmdln, "-gexit"]
			if directory != "":
				args.append("-gdir=%s" % directory)
			else:
				args.append("-gdir=res://test")
			if pattern != "":
				args.append("-gprefix=%s" % pattern)
			return {"args": args}
		"gdunit4":
			# GdUnit4 ships GdUnitRunner.gd for CLI execution.
			var runner := "res://addons/gdUnit4/bin/GdUnitCmdTool.gd"
			if not FileAccess.file_exists(runner):
				return {"_error": "GdUnit4 framework dir exists but GdUnitCmdTool.gd not found"}
			var args: Array = ["-s", runner]
			if directory != "":
				args.append("--add=%s" % directory)
			else:
				args.append("--add=res://test")
			return {"args": args}
		_:
			return {"_error": "unknown framework: %s (supported: gut, gdunit4)" % framework}


# Parse GUT's text output. GUT's actual format (not the documented :-separated form):
#
#   Totals
#   ------
#   Scripts               1
#   Tests                 3
#   Passing Tests         2
#   Failing Tests         1
#   Pending Tests         0     <- optional, only if tests are pending
#   Asserts             2/3
#
# Failures appear under a per-file header in the "Run Summary" section:
#
#   res://test/foo.gd
#   - test_failing_case
#       [Failed]:  <assertion message>
#             at line 14
#
# Output has ANSI color escapes; strip them first so regex matches cleanly.
static func _parse_gut_output(raw: String) -> Dictionary:
	var text := _strip_ansi(raw)
	var total := _gut_extract_count(text, "Tests")
	var passed := _gut_extract_count(text, "Passing Tests")
	var failed := _gut_extract_count(text, "Failing Tests")
	var skipped := _gut_extract_count(text, "Pending Tests")

	var failures: Array = _extract_gut_failures(text)

	return {"total": total, "passed": passed, "failed": failed, "skipped": skipped, "failures": failures}


# Match either "Label    12" (space-aligned) or "Label: 12" (colon form) on its own line.
static func _gut_extract_count(text: String, label: String) -> int:
	var re := RegEx.new()
	re.compile("(?m)^\\s*" + label.replace(" ", "\\s+") + "\\s*[:\\s]\\s*(\\d+)\\s*$")
	var m := re.search(text)
	if m == null:
		return 0
	return int(m.get_string(1))


# Walk the text top-to-bottom, tracking current test file (file headers are plain
# `res://...` lines), collecting failing tests (`- test_name` with a following
# `[Failed]:` assertion and `at line N`).
static func _extract_gut_failures(text: String) -> Array:
	var failures: Array = []
	var lines: PackedStringArray = text.split("\n")
	var current_file := ""
	var current_test := ""
	var current_message := ""
	var i := 0
	while i < lines.size():
		var line: String = lines[i].trim_suffix("\r").strip_edges(false, true)  # strip only trailing
		if line.begins_with("res://") and line.ends_with(".gd"):
			current_file = line.strip_edges()
			i += 1
			continue
		var trimmed := line.strip_edges()
		if trimmed.begins_with("- "):
			current_test = trimmed.substr(2).strip_edges()
			current_message = ""
		elif trimmed.begins_with("[Failed]:"):
			current_message = trimmed.substr("[Failed]:".length()).strip_edges()
		elif trimmed.begins_with("at line"):
			var n_str := trimmed.substr("at line".length()).strip_edges()
			var line_num := int(n_str)
			if current_test != "" and current_file != "":
				failures.append({
					"name": current_test,
					"file": current_file,
					"line": line_num,
					"message": current_message,
				})
				current_test = ""
				current_message = ""
		i += 1
	return failures


# Remove ANSI terminal escape codes (colors) from GUT's output so regex matches
# don't get tripped up on things like "\x1b[32m".
static func _strip_ansi(text: String) -> String:
	var re := RegEx.new()
	re.compile("\\x1b\\[[0-9;]*[A-Za-z]")
	return re.sub(text, "", true)


# GdUnit4's default output ends with a summary like:
#   "| Tests | Executed | 12 | passed | 10 | skipped | 0 | failed | 2 | ... |"
# and per-failure blocks with file:line.
static func _parse_gdunit4_output(text: String) -> Dictionary:
	var total := 0
	var passed := 0
	var failed := 0
	var skipped := 0

	var summary_re := RegEx.new()
	summary_re.compile("Executed\\s*\\|\\s*(\\d+).*?passed\\s*\\|\\s*(\\d+).*?skipped\\s*\\|\\s*(\\d+).*?failed\\s*\\|\\s*(\\d+)")
	var m := summary_re.search(text)
	if m:
		total = int(m.get_string(1))
		passed = int(m.get_string(2))
		skipped = int(m.get_string(3))
		failed = int(m.get_string(4))

	var failures: Array = []
	var fail_re := RegEx.new()
	fail_re.compile("(?m)FAILED\\s+(.+?)\\s*\\(at:\\s*(.+?):(\\d+)")
	for fm in fail_re.search_all(text):
		failures.append({
			"name": fm.get_string(1),
			"file": fm.get_string(2),
			"line": int(fm.get_string(3)),
			"message": "",
		})

	return {"total": total, "passed": passed, "failed": failed, "skipped": skipped, "failures": failures}


static func _ok(data) -> Dictionary:
	return {"data": data}


static func _err(code: int, msg: String) -> Dictionary:
	return {"error": {"code": code, "message": msg}}
