#!/usr/bin/env node
// MCP server that bridges stdio tool calls to the agent_tools plugin running
// inside the Godot editor (TCP JSON-RPC on 127.0.0.1:9920 by default).

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import net from "node:net";

const HOST = process.env.GODOT_AGENT_HOST || "127.0.0.1";
const PORT = parseInt(process.env.GODOT_AGENT_PORT || "9920", 10);
const TIMEOUT_MS = parseInt(process.env.GODOT_AGENT_TIMEOUT_MS || "15000", 10);

const TOOLS = [
  {
    name: "scene_inspect",
    method: "scene.inspect",
    description:
      "Return the node tree of a scene as JSON (name, class, node_path, script, children). Omit 'path' to inspect the currently-edited scene. Read-only.",
    inputSchema: {
      type: "object",
      properties: {
        path: {
          type: "string",
          description:
            "Scene resource path (e.g. 'res://Main.tscn'). If omitted, uses the currently-edited scene.",
        },
      },
    },
  },
  {
    name: "scene_new",
    method: "scene.new",
    description:
      "Create a new .tscn file from scratch with a root node of the given type. Opens the scene in the editor by default so subsequent scene.* calls target it.",
    inputSchema: {
      type: "object",
      required: ["path"],
      properties: {
        path: { type: "string", description: "'res://...' ending in .tscn" },
        root_type: { type: "string", default: "Node", description: "Godot class name for the root node." },
        root_name: { type: "string", description: "Root node name; defaults to the class name." },
        overwrite: { type: "boolean", default: false },
        open_after: { type: "boolean", default: true },
      },
    },
  },
  {
    name: "scene_instance_packed",
    method: "scene.instance_packed",
    description:
      "Add an existing .tscn as a sub-scene child of a node in the currently-edited scene. Refuses to instance a scene into itself.",
    inputSchema: {
      type: "object",
      required: ["scene_path"],
      properties: {
        scene_path: { type: "string", description: "Path to the .tscn to instance." },
        parent_path: { type: "string", description: "Parent NodePath; '.' for root. Defaults to '.'.", default: "." },
        name: { type: "string", description: "Instance node name; defaults to the scene's root name." },
      },
    },
  },
  {
    name: "scene_add_node",
    method: "scene.add_node",
    description:
      "Add a new node to the currently-edited scene. Sets owner so the node persists on save.",
    inputSchema: {
      type: "object",
      required: ["type"],
      properties: {
        type: { type: "string", description: "Godot class name, e.g. 'Node2D', 'Sprite2D', 'Label'." },
        name: { type: "string", description: "Node name; defaults to the class name." },
        parent_path: {
          type: "string",
          description: "NodePath of parent relative to scene root. '.' means root. Defaults to '.'.",
        },
      },
    },
  },
  {
    name: "scene_remove_node",
    method: "scene.remove_node",
    description: "Remove a node (and its descendants) from the currently-edited scene. Cannot remove the root.",
    inputSchema: {
      type: "object",
      required: ["node_path"],
      properties: { node_path: { type: "string" } },
    },
  },
  {
    name: "scene_duplicate_node",
    method: "scene.duplicate_node",
    description:
      "Clone a node (with descendants) in the currently-edited scene. Owner is set recursively so the duplicated subtree serializes. Defaults to adding under the source's parent; override with parent_path.",
    inputSchema: {
      type: "object",
      required: ["node_path"],
      properties: {
        node_path: { type: "string", description: "Source node to clone." },
        new_name: { type: "string", description: "Name for the copy; defaults to auto-generated '<name>2' style." },
        parent_path: { type: "string", description: "Destination parent; defaults to the source's parent." },
      },
    },
  },
  {
    name: "scene_reparent",
    method: "scene.reparent",
    description:
      "Move a node under a new parent in the currently-edited scene. Preserves global transform by default; refuses cycles.",
    inputSchema: {
      type: "object",
      required: ["node_path", "new_parent_path"],
      properties: {
        node_path: { type: "string" },
        new_parent_path: { type: "string" },
        keep_global_transform: { type: "boolean", default: true },
      },
    },
  },
  {
    name: "scene_set_property",
    method: "scene.set_property",
    description:
      "Set a property on a node. JSON-to-Godot coercion: " +
      "primitives (bool/int/float/String/StringName) pass through; " +
      "NodePath from a string; " +
      "Vector2/2i/3/3i/4/4i from [x, y(, z(, w))]; " +
      "Rect2/2i from [x, y, width, height]; " +
      "Quaternion from [x, y, z, w]; " +
      "Color from [r, g, b(, a)] or '#rrggbb(aa)'; " +
      "Transform2D from {origin: [x,y], rotation: radians, scale: [x,y], skew?}; " +
      "Transform3D from {origin: [x,y,z], rotation: [x,y,z] (euler rad), scale: [x,y,z]}; " +
      "Basis from {rotation, scale} (same shape as Transform3D minus origin); " +
      "AABB from {position: [x,y,z], size: [x,y,z]}; " +
      "Plane from {normal: [x,y,z], d: float}; " +
      "Resource-typed properties (e.g. a CollisionShape2D's 'shape') auto-load from 'res://...' or 'uid://...' path strings; " +
      "Packed{String,Int32,Int64,Float32,Float64,Vector2,Vector3,Color}Array from plain JSON arrays (element-wise coerced); " +
      "other types pass through as-is. " +
      "Returns an error if Godot drops the assignment (e.g. type mismatch) instead of echoing a misleading null.",
    inputSchema: {
      type: "object",
      required: ["node_path", "property"],
      properties: {
        node_path: { type: "string" },
        property: { type: "string" },
        value: { description: "Value, JSON-native. See description for coercion rules." },
      },
    },
  },
  {
    name: "scene_get_property",
    method: "scene.get_property",
    description:
      "Read a property from a node in the currently-edited scene. Mirror of scene_set_property — useful for 'what's the current value?' queries without dumping the whole tree.",
    inputSchema: {
      type: "object",
      required: ["node_path", "property"],
      properties: {
        node_path: { type: "string" },
        property: { type: "string" },
      },
    },
  },
  {
    name: "scene_build_tree",
    method: "scene.build_tree",
    description:
      "Build a subtree in the currently-edited scene in one call — recursive spec instead of dozens of scene_add_node + scene_set_property + script_attach round trips. " +
      "Each tree entry: {type: 'ClassName' (required), name?: string, properties?: {propname: value, ...}, script?: 'res://...', children?: [entry, ...]}. " +
      "Properties are coerced via the same rules as scene_set_property (Vectors from arrays, Resources auto-loaded from res:// paths, Transforms from {origin,rotation,scale}, etc.). " +
      "Script is attached before properties so script-exported vars are settable in the same call. " +
      "Atomic: if any entry fails (unknown type, missing property, coercion error, read-only slot, silent-null assignment), every node created during this call is rolled back — the scene is left in its pre-call state.",
    inputSchema: {
      type: "object",
      required: ["nodes"],
      properties: {
        parent_path: { type: "string", default: ".", description: "Where to attach the new subtree. '.' = scene root." },
        nodes: {
          type: "array",
          description: "Top-level tree entries (each may have arbitrarily nested children).",
          items: {
            type: "object",
            required: ["type"],
            properties: {
              type: { type: "string", description: "Godot class name (e.g. 'PanelContainer', 'Button')." },
              name: { type: "string" },
              script: { type: "string", description: "Path to a .gd to attach before properties are applied." },
              properties: { type: "object", additionalProperties: true, description: "Property → value pairs; values use the scene_set_property coercion rules." },
              children: { type: "array", description: "Nested entries using the same shape as this one." },
            },
          },
        },
      },
    },
  },
  {
    name: "scene_call_method",
    method: "scene.call_method",
    description:
      "Invoke a method on a node in the currently-edited scene (e.g. a custom helper, or Godot built-ins like 'queue_free', 'add_to_group'). Args are coerced against the method's declared parameter types using the same rules as scene_set_property — including 'res://...' → Resource auto-load. Return value is JSON-native. Useful when properties alone can't express what you need — e.g. calling a script method with multiple args.",
    inputSchema: {
      type: "object",
      required: ["node_path", "method"],
      properties: {
        node_path: { type: "string" },
        method: { type: "string" },
        args: {
          type: "array",
          description: "Method arguments in order. Each is coerced based on the method's declared parameter type.",
        },
      },
    },
  },
  {
    name: "scene_open",
    method: "scene.open",
    description: "Open a scene in the editor so subsequent scene.* calls target it.",
    inputSchema: {
      type: "object",
      required: ["path"],
      properties: { path: { type: "string" } },
    },
  },
  {
    name: "scene_save",
    method: "scene.save",
    description:
      "Save the currently-edited scene. Pass 'path' to save-as (rebinds the scene to that path). " +
      "REQUIRED for fresh scenes: if the scene has never been saved (no backing file), the tool returns an error rather than triggering Godot's native Save-As dialog (which would block the editor waiting for a human click). Always pass 'path' when you built the scene from scratch via scene.build_tree / scene.add_node without going through scene.new.",
    inputSchema: {
      type: "object",
      properties: { path: { type: "string", description: "Save-as target, required when the scene has no existing file." } },
    },
  },
  {
    name: "scene_current",
    method: "scene.current",
    description: "Describe the currently-edited scene, or return {open: false} if none is open.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "scene_capture_screenshot",
    method: "scene.capture_screenshot",
    description:
      "Save a PNG of the editor viewport for the open scene (2D or 3D selected automatically). Clean capture — no editor grid/gizmos. Empty scenes render as the viewport background color. Default output: res://.godot/agent_tools/<scene-name>.png.",
    inputSchema: {
      type: "object",
      properties: {
        output: {
          type: "string",
          description: "Optional output path (res://...). Defaults to res://.godot/agent_tools/<scene>.png.",
        },
      },
    },
  },
  {
    name: "signal_connect",
    method: "signal.connect",
    description:
      "Connect a signal between two nodes in the currently-edited scene. Connection is persistent (serialized into the .tscn as a [connection] block). Validates signal name, method existence, and arity.",
    inputSchema: {
      type: "object",
      required: ["from", "signal", "to", "method"],
      properties: {
        from: { type: "string", description: "Source node path." },
        signal: { type: "string" },
        to: { type: "string", description: "Target node path." },
        method: { type: "string", description: "Method name on the target's script." },
      },
    },
  },
  {
    name: "signal_disconnect",
    method: "signal.disconnect",
    description: "Disconnect a specific signal wiring from the currently-edited scene.",
    inputSchema: {
      type: "object",
      required: ["from", "signal", "to", "method"],
      properties: {
        from: { type: "string" },
        signal: { type: "string" },
        to: { type: "string" },
        method: { type: "string" },
      },
    },
  },
  {
    name: "signal_list",
    method: "signal.list",
    description:
      "List outgoing signal connections on a node. Each entry includes flags and a 'persistent' boolean so you can filter editor-serialized connections from runtime ones.",
    inputSchema: {
      type: "object",
      required: ["node_path"],
      properties: {
        node_path: { type: "string" },
        persistent_only: { type: "boolean", default: false },
      },
    },
  },
  {
    name: "script_create",
    method: "script.create",
    description:
      "Create a new .gd file with 'extends' and optional 'class_name', and optionally attach it to a node in the currently-edited scene.",
    inputSchema: {
      type: "object",
      required: ["path"],
      properties: {
        path: { type: "string", description: "Target path, e.g. 'res://scripts/Player.gd'." },
        extends: { type: "string", default: "Node" },
        class_name: { type: "string" },
        attach_to_node: { type: "string", description: "NodePath in the currently-edited scene." },
        overwrite: { type: "boolean", default: false },
      },
    },
  },
  {
    name: "script_attach",
    method: "script.attach",
    description: "Attach an existing script to a node in the currently-edited scene.",
    inputSchema: {
      type: "object",
      required: ["node_path", "script_path"],
      properties: {
        node_path: { type: "string" },
        script_path: { type: "string" },
      },
    },
  },
  {
    name: "resource_create",
    method: "resource.create",
    description:
      "Create a new .tres file. Use 'type' for built-in Resource subclasses (StyleBoxFlat, Theme, Curve, etc.) or 'script' pointing at a custom Resource .gd file. Optional 'properties' are applied before saving.",
    inputSchema: {
      type: "object",
      required: ["path"],
      properties: {
        path: { type: "string", description: "Target path, e.g. 'res://themes/main.tres'." },
        type: { type: "string", description: "Built-in Resource class name." },
        script: { type: "string", description: "Path to a custom Resource .gd (use instead of 'type')." },
        properties: {
          type: "object",
          description: "Initial property values. Same coercion rules as scene_set_property.",
          additionalProperties: true,
        },
        overwrite: { type: "boolean", default: false },
      },
    },
  },
  {
    name: "resource_set_property",
    method: "resource.set_property",
    description:
      "Load a .tres, set one property, and save. Same JSON-to-Godot coercion as scene_set_property: primitives, NodePath, Vector2/2i/3/3i/4/4i, Rect2/2i, Quaternion, Color, Transform2D/3D, Basis, AABB, Plane, Resource auto-load from 'res://'/'uid://' paths, and all Packed*Array variants. Errors on silently-dropped assignments.",
    inputSchema: {
      type: "object",
      required: ["path", "property"],
      properties: {
        path: { type: "string" },
        property: { type: "string" },
        value: { description: "Value, JSON-native." },
      },
    },
  },
  {
    name: "resource_call_method",
    method: "resource.call_method",
    description:
      "Load a .tres, invoke a method on it, save, return the method's result. Rounds out what set_property can't express — e.g. StyleBoxFlat.set_border_width_all(4), set_corner_radius_all(14), Curve.add_point(...). Args coerce via the same rules as resource_set_property. Pass save:false to call without persisting (read-only method calls).",
    inputSchema: {
      type: "object",
      required: ["path", "method"],
      properties: {
        path: { type: "string" },
        method: { type: "string" },
        args: { type: "array", description: "Method arguments in order, coerced per the method's parameter types." },
        save: { type: "boolean", default: true, description: "Save the resource after the call. Set false for read-only method calls." },
      },
    },
  },
  {
    name: "refs_validate_project",
    method: "refs.validate_project",
    description:
      "Project-wide scan for broken references: unparseable scripts, missing ext_resources, dangling UIDs, signal connections pointing at missing nodes or methods.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "refs_find_usages",
    method: "refs.find_usages",
    description:
      "Find every file referencing a resource. Accepts a path or a uid:// — searches for both forms so uid-indirected references are caught. Returns file path, line number, and matched text.",
    inputSchema: {
      type: "object",
      required: ["target"],
      properties: {
        target: { type: "string", description: "'res://...' or 'uid://...'" },
      },
    },
  },
  {
    name: "refs_rename",
    method: "refs.rename",
    description:
      "Move a file and rewrite every path-form reference to it. The .uid and .import sidecars are moved too so UID-form references keep resolving. Supports dry_run to preview changes without touching disk.",
    inputSchema: {
      type: "object",
      required: ["from", "to"],
      properties: {
        from: { type: "string" },
        to: { type: "string" },
        overwrite: { type: "boolean", default: false },
        dry_run: { type: "boolean", default: false },
      },
    },
  },
  {
    name: "refs_rename_class",
    method: "refs.rename_class",
    description:
      "Rename 'class_name X' to 'class_name Y' across the project — updates the defining script and every word-boundary reference in .gd / .tscn / .tres files. Best-effort (won't distinguish an X that happens to be a local variable); use dry_run first.",
    inputSchema: {
      type: "object",
      required: ["from", "to"],
      properties: {
        from: { type: "string" },
        to: { type: "string" },
        dry_run: { type: "boolean", default: false },
      },
    },
  },
  {
    name: "project_get_setting",
    method: "project.get_setting",
    description: "Read a project.godot setting by key (e.g. 'application/config/name'). Returns {exists: false} if unset.",
    inputSchema: {
      type: "object",
      required: ["key"],
      properties: { key: { type: "string" } },
    },
  },
  {
    name: "project_set_setting",
    method: "project.set_setting",
    description:
      "Write a project.godot setting and save. DESTRUCTIVE — mutates project.godot. Prefer specific tools (autoload_add, etc.) when available.",
    inputSchema: {
      type: "object",
      required: ["key", "value"],
      properties: {
        key: { type: "string" },
        value: { description: "JSON-native value." },
      },
    },
  },
  {
    name: "autoload_add",
    method: "autoload.add",
    description: "Register an autoload. Singleton by default (adds the '*' prefix so the name is globally accessible).",
    inputSchema: {
      type: "object",
      required: ["name", "path"],
      properties: {
        name: { type: "string", description: "Globally-accessible name, e.g. 'GameState'." },
        path: { type: "string", description: "Path to a .gd or .tscn, e.g. 'res://autoload/game_state.gd'." },
        singleton: { type: "boolean", default: true },
      },
    },
  },
  {
    name: "autoload_remove",
    method: "autoload.remove",
    description: "Unregister an autoload by name.",
    inputSchema: {
      type: "object",
      required: ["name"],
      properties: { name: { type: "string" } },
    },
  },
  {
    name: "autoload_list",
    method: "autoload.list",
    description: "List all registered autoloads with their paths and singleton flags.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "editor_reload_filesystem",
    method: "editor.reload_filesystem",
    description:
      "Trigger an editor filesystem rescan. Call this after creating/moving/deleting files via tools that bypass the editor, so load() and the FileSystem dock see the changes.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "editor_save_all_scenes",
    method: "editor.save_all_scenes",
    description: "Save every currently-open scene in the editor.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "docs_class_ref",
    method: "docs.class_ref",
    description:
      "Return the public API of a Godot class (methods, properties, signals, constants) so the agent can plan calls without guessing. Defaults to class-local members; pass include_inherited:true to include ancestors.",
    inputSchema: {
      type: "object",
      required: ["class_name"],
      properties: {
        class_name: { type: "string", description: "Godot class name, e.g. 'Timer', 'AnimationPlayer'." },
        include_inherited: { type: "boolean", default: false },
      },
    },
  },
  {
    name: "input_map_add_action",
    method: "input_map.add_action",
    description: "Register a new input action in project.godot.",
    inputSchema: {
      type: "object",
      required: ["name"],
      properties: {
        name: { type: "string", description: "Action name, e.g. 'jump'." },
        deadzone: { type: "number", default: 0.5 },
      },
    },
  },
  {
    name: "input_map_add_event",
    method: "input_map.add_event",
    description:
      "Attach an input event to an existing action. Every event accepts an optional 'device' field (default -1 = all devices; set 0, 1, etc. for local-multiplayer device-specific bindings). Event shapes: " +
      "{type:'key', keycode:'A'|'Space'|...}; " +
      "{type:'mouse_button', button_index:1|2|3}; " +
      "{type:'joy_button', button_index:0..}; " +
      "{type:'joy_motion', axis:0..5 or 'left_x'|'left_y'|'right_x'|'right_y'|'trigger_left'|'trigger_right', axis_value:-1.0..1.0} (axis_value sign picks direction).",
    inputSchema: {
      type: "object",
      required: ["action", "event"],
      properties: {
        action: { type: "string" },
        event: {
          type: "object",
          required: ["type"],
          properties: {
            type: { type: "string", enum: ["key", "mouse_button", "joy_button", "joy_motion"] },
            device: { type: "integer", default: -1, description: "-1 = all devices (default); 0, 1, etc. bind a specific controller for local multiplayer." },
            keycode: { description: "For type='key': 'A', 'Space', 'F1', or int keycode." },
            physical: { type: "boolean", default: true, description: "For type='key': use physical keycode (recommended)." },
            button_index: { type: "integer", description: "For mouse/joy button events." },
            axis: { description: "For type='joy_motion': int 0..5 or 'left_x'|'left_y'|'right_x'|'right_y'|'trigger_left'|'trigger_right'." },
            axis_value: { type: "number", description: "For type='joy_motion': -1.0 to 1.0; sign selects direction that triggers the action." },
          },
        },
      },
    },
  },
  {
    name: "input_map_list",
    method: "input_map.list",
    description:
      "List input actions with their events. Defaults to user-defined actions only (filters out Godot's ~90 built-in ui_* defaults). Pass include_builtins:true for the full list.",
    inputSchema: {
      type: "object",
      properties: {
        include_builtins: { type: "boolean", default: false },
      },
    },
  },
  {
    name: "input_map_remove_event",
    method: "input_map.remove_event",
    description:
      "Remove an event from an action by index. Call input_map_list first to see indices (events are listed in add order).",
    inputSchema: {
      type: "object",
      required: ["action", "event_index"],
      properties: {
        action: { type: "string" },
        event_index: { type: "integer" },
      },
    },
  },
  {
    name: "input_map_remove_action",
    method: "input_map.remove_action",
    description: "Delete a user-registered input action.",
    inputSchema: {
      type: "object",
      required: ["name"],
      properties: { name: { type: "string" } },
    },
  },
  {
    name: "run_scene_headless",
    method: "run.scene_headless",
    description:
      "Run a scene in a child Godot process with structured output. " +
      "MODES: BARE (default) runs --headless — fast, no window, good for 'does _ready not crash' checks. " +
      "DRIVEN (anything beyond path + quit_after_seconds) runs under a wrapper driver that can inject scripted input, capture screenshots at multiple frames, dump final scene state as JSON, and use a deterministic RNG seed. " +
      "SCREENSHOTS: when screenshot(s) requested the subprocess drops --headless and runs with a real (offscreen) window because Godot 4.6's headless mode uses a dummy renderer. Expect a brief window flash. " +
      "STRUCTURED RESULTS: tool parses stdout for ERROR: / USER ERROR: / SCRIPT ERROR: / WARNING: / USER WARNING: lines and returns them as result.errors and result.warnings arrays so the agent doesn't have to regex the raw output. state_dump:true adds result.final_state with the scene tree + common properties. " +
      "Event types for input_script: " +
      "{frame, type: 'action_tap',     action}; " +
      "{frame, type: 'action_press',   action, strength?}; " +
      "{frame, type: 'action_release', action}; " +
      "{frame, type: 'key',            keycode: 'Space'|int, pressed?: true}; " +
      "{frame, type: 'mouse_click',    position: [x, y], button?: 1}; " +
      "{frame, type: 'mouse_motion',   position: [x, y]}. " +
      "BLOCKS the editor for the duration — use small quit_after_seconds (1-5).",
    inputSchema: {
      type: "object",
      required: ["path"],
      properties: {
        path: { type: "string", description: "Scene to run, e.g. 'res://Main.tscn'." },
        quit_after_seconds: { type: "number", default: 2, description: "Converted to frames assuming 60 fps. In DRIVEN mode this is also the quit_frame the driver targets." },
        extra_args: {
          type: "array",
          items: { type: "string" },
          description: "Additional CLI args passed to the child godot process.",
        },
        input_script: {
          type: "array",
          description: "Optional: enters DRIVEN mode. Array of event specs keyed by frame. See description for event type shapes.",
          items: {
            type: "object",
            required: ["frame", "type"],
            properties: {
              frame: { type: "integer", description: "0-based frame to fire on." },
              type: { type: "string", enum: ["action_press", "action_release", "action_tap", "key", "mouse_click", "mouse_motion"] },
              action: { type: "string" },
              strength: { type: "number", default: 1.0 },
              keycode: { description: "For type='key': 'A', 'Space', 'F1', or int keycode." },
              pressed: { type: "boolean" },
              button: { type: "integer", description: "Mouse button (1=left, 2=right, 3=middle)." },
              position: { type: "array", description: "[x, y] viewport coordinates." },
            },
          },
        },
        screenshot: {
          type: "string",
          description: "Shorthand: one PNG saved at the final frame. Equivalent to screenshots:[{frame: quit_frame, path: ...}]. Triggers offscreen-windowed subprocess (brief window flash).",
        },
        screenshots: {
          type: "array",
          description: "Capture PNGs at multiple specific frames during the run — useful for verifying state transitions (spawn at frame 30, mid-animation at 60, final at 120).",
          items: {
            type: "object",
            required: ["frame", "path"],
            properties: {
              frame: { type: "integer" },
              path: { type: "string" },
            },
          },
        },
        resolution: {
          type: "string",
          default: "320x240",
          description: "Window resolution 'WxH' when screenshots are captured. Default is tiny to minimize offscreen footprint; bump to 1280x720 or similar for UI verification.",
        },
        state_dump: {
          type: "boolean",
          default: false,
          description: "When true, driver writes a JSON snapshot of the final scene tree (name, class, node_path, script, children, plus common props like visible/position/text/value/modulate). Returned as result.final_state. Lets agents verify end state programmatically instead of eyeballing the screenshot.",
        },
        seed: {
          type: "integer",
          description: "Optional RNG seed. Set before the target scene is instanced so randi/randf are reproducible. Useful for deterministic tests.",
        },
      },
    },
  },
  {
    name: "user_fs_read",
    method: "user_fs.read",
    description:
      "Read a text file from the user:// data directory — where games persist save files, custom-level JSON, settings, etc. Separate from fs_list (which is res://-only) because user:// is runtime-written state.",
    inputSchema: {
      type: "object",
      required: ["path"],
      properties: {
        path: { type: "string", description: "Must begin with 'user://'." },
      },
    },
  },
  {
    name: "user_fs_list",
    method: "user_fs.list",
    description:
      "List files and subdirectories under a user:// directory. Optionally recursive.",
    inputSchema: {
      type: "object",
      properties: {
        dir: { type: "string", default: "user://", description: "Must begin with 'user://'." },
        recursive: { type: "boolean", default: false },
      },
    },
  },
  {
    name: "fs_list",
    method: "fs.list",
    description:
      "Enumerate project files by type with optional glob filter. Types: all | scene | script | resource | shader | image | audio. Skips the agent_tools addon by default.",
    inputSchema: {
      type: "object",
      properties: {
        type: {
          type: "string",
          enum: ["all", "scene", "script", "resource", "shader", "image", "audio"],
          default: "all",
        },
        glob: { type: "string", description: "Optional case-insensitive glob, e.g. 'res://scenes/**/*.tscn'." },
        include_addons: { type: "boolean", default: false },
      },
    },
  },
  {
    name: "animation_list",
    method: "animation.list",
    description: "List animations on an AnimationPlayer node with their tracks.",
    inputSchema: {
      type: "object",
      required: ["node_path"],
      properties: { node_path: { type: "string" } },
    },
  },
  {
    name: "animation_add_animation",
    method: "animation.add_animation",
    description: "Create an empty animation in the player's library. Use animation_add_value_track to populate it.",
    inputSchema: {
      type: "object",
      required: ["node_path", "name"],
      properties: {
        node_path: { type: "string" },
        name: { type: "string" },
        length: { type: "number", default: 1.0 },
        library: { type: "string", default: "", description: "Library name; '' is the default library." },
      },
    },
  },
  {
    name: "animation_remove_animation",
    method: "animation.remove_animation",
    description: "Delete an animation from an AnimationPlayer.",
    inputSchema: {
      type: "object",
      required: ["node_path", "name"],
      properties: {
        node_path: { type: "string" },
        name: { type: "string" },
        library: { type: "string", default: "" },
      },
    },
  },
  {
    name: "animation_add_value_track",
    method: "animation.add_value_track",
    description:
      "Add a value track to an animation that animates a property on a target node. target_node is resolved relative to the AnimationPlayer's root. Auto-extends the animation's length if keyframes go past it.",
    inputSchema: {
      type: "object",
      required: ["node_path", "animation", "target_node", "property", "keyframes"],
      properties: {
        node_path: { type: "string", description: "AnimationPlayer node path." },
        animation: { type: "string", description: "Animation name — use 'lib/anim' for non-default libraries." },
        target_node: { type: "string", description: "NodePath to animated node, relative to the player's root." },
        property: { type: "string", description: "Property name to animate." },
        keyframes: {
          type: "array",
          items: {
            type: "object",
            required: ["time", "value"],
            properties: {
              time: { type: "number" },
              value: { description: "Property value at this time." },
              easing: { type: "number", default: 1.0, description: "Transition curve; 1.0 = linear." },
            },
          },
        },
      },
    },
  },
];

const BY_NAME = Object.fromEntries(TOOLS.map((t) => [t.name, t]));

// Persistent Godot TCP client. One socket reused across tool calls; outstanding
// requests are tracked by id so multiple in-flight calls don't interleave data.
class GodotClient {
  constructor(host, port) {
    this.host = host;
    this.port = port;
    this.socket = null;
    this.buffer = "";
    this.pending = new Map(); // id -> { resolve, reject, timer }
    this.nextId = 0;
    this.connecting = null;
  }

  async _ensureConnected() {
    if (this.socket && !this.socket.destroyed) return;
    if (this.connecting) return this.connecting;

    this.connecting = new Promise((resolve, reject) => {
      const s = new net.Socket();
      s.setEncoding("utf8");
      s.setNoDelay(true);

      const onConnect = () => {
        s.removeListener("error", onErrorPreConnect);
        this.socket = s;
        this.connecting = null;
        resolve();
      };

      const onErrorPreConnect = (e) => {
        this.connecting = null;
        if (e.code === "ECONNREFUSED") {
          reject(new Error(
            `Godot editor not reachable on ${this.host}:${this.port}. ` +
            `Open the project in the Godot editor with the 'Agent Tools' plugin enabled.`
          ));
        } else {
          reject(e);
        }
      };

      s.once("connect", onConnect);
      s.once("error", onErrorPreConnect);

      s.on("data", (data) => this._onData(data));
      s.on("error", (e) => this._onFatalError(e));
      s.on("close", () => this._onClose());

      s.connect(this.port, this.host);
    });

    return this.connecting;
  }

  call(method, params) {
    const id = ++this.nextId;
    return new Promise(async (resolve, reject) => {
      const timer = setTimeout(() => {
        if (this.pending.has(id)) {
          this.pending.delete(id);
          reject(new Error(`Godot tool '${method}' timed out after ${TIMEOUT_MS}ms`));
        }
      }, TIMEOUT_MS);

      this.pending.set(id, { resolve, reject, timer });

      try {
        await this._ensureConnected();
      } catch (e) {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(e);
        return;
      }

      const line = JSON.stringify({ id, method, params: params || {} }) + "\n";
      this.socket.write(line);
    });
  }

  _onData(data) {
    this.buffer += data;
    while (true) {
      const nl = this.buffer.indexOf("\n");
      if (nl < 0) break;
      const line = this.buffer.slice(0, nl);
      this.buffer = this.buffer.slice(nl + 1);
      if (!line) continue;

      let msg;
      try {
        msg = JSON.parse(line);
      } catch {
        continue; // ignore malformed lines — shouldn't happen
      }

      const pending = this.pending.get(msg.id);
      if (!pending) continue;
      this.pending.delete(msg.id);
      clearTimeout(pending.timer);

      if (msg.error) {
        pending.reject(new Error(`Godot error ${msg.error.code}: ${msg.error.message}`));
      } else {
        pending.resolve(msg.result);
      }
    }
  }

  _onFatalError(e) {
    for (const { reject, timer } of this.pending.values()) {
      clearTimeout(timer);
      reject(e);
    }
    this.pending.clear();
    if (this.socket) {
      this.socket.destroy();
      this.socket = null;
    }
  }

  _onClose() {
    for (const { reject, timer } of this.pending.values()) {
      clearTimeout(timer);
      reject(new Error("Godot closed the connection"));
    }
    this.pending.clear();
    this.socket = null;
    this.buffer = "";
  }
}

const client = new GodotClient(HOST, PORT);

const server = new Server(
  { name: "godot-agent-tools", version: "0.2.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: TOOLS.map(({ name, description, inputSchema }) => ({
    name,
    description,
    inputSchema,
  })),
}));

server.setRequestHandler(CallToolRequestSchema, async (req) => {
  const tool = BY_NAME[req.params.name];
  if (!tool) {
    return {
      isError: true,
      content: [{ type: "text", text: `Unknown tool: ${req.params.name}` }],
    };
  }
  try {
    const result = await client.call(tool.method, req.params.arguments || {});
    return {
      content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
    };
  } catch (e) {
    return {
      isError: true,
      content: [{ type: "text", text: e.message }],
    };
  }
});

const transport = new StdioServerTransport();
await server.connect(transport);
