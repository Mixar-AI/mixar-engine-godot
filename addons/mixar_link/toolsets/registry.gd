@tool
extends RefCounted
## The editor toolsets behind three MCP tools: list_toolsets, describe_toolset
## and call_tool (the same shape as Epic's Unreal server). Each toolset is a
## file in this folder built on Godot's own reflection; Mixar's top-level
## tools are unchanged.

const SETS := [
	preload("res://addons/mixar_link/toolsets/classes.gd"),
	preload("res://addons/mixar_link/toolsets/scene.gd"),
	preload("res://addons/mixar_link/toolsets/resources.gd"),
	preload("res://addons/mixar_link/toolsets/files.gd"),
	preload("res://addons/mixar_link/toolsets/editor.gd"),
]

var t: RefCounted
var _sets := {}
var _order: Array = []


func _init(p_tools: RefCounted) -> void:
	t = p_tools
	for script in SETS:
		var ts = script.new()
		ts.t = p_tools
		_sets[ts.toolset_id()] = ts
		_order.append(ts.toolset_id())


## Breaks the tools.gd <-> toolset reference cycle when the plugin unloads.
func close() -> void:
	for id in _sets:
		_sets[id].t = null
	_sets.clear()
	t = null


func top_level_tools() -> Array:
	return [
		_tool("list_toolsets", "The Godot editor toolsets (name, description, tool count). describe_toolset gives a toolset's tools; call_tool runs one.", {}),
		_tool("describe_toolset", "A toolset's tools with their descriptions and JSON input schemas.",
			{"toolset_name": {"type": "string"}}, ["toolset_name"]),
		_tool("call_tool", "Run one tool of a toolset: toolset_name (e.g. godot.scene), tool_name (short, or the full godot.scene.set_properties with toolset_name empty) and its arguments.",
			{"toolset_name": {"type": "string"}, "tool_name": {"type": "string"}, "arguments": {"type": "object"}},
			["tool_name"]),
	]


func list_toolsets() -> Dictionary:
	var out: Array = []
	for id in _order:
		out.append({"name": id, "description": _sets[id].toolset_description(), "tools": _sets[id].tool_specs().size()})
	return t._ok({"toolsets": out})


func describe_toolset(args: Dictionary) -> Dictionary:
	var id := String(args.get("toolset_name", ""))
	if not _sets.has(id):
		return t._err("Unknown toolset '%s'. Toolsets: %s." % [id, ", ".join(_order)])
	return t._ok({"name": id, "version": t.ADAPTER_VERSION, "description": _sets[id].toolset_description(),
		"tools": _sets[id].tool_specs()})


func call_tool(args: Dictionary):
	var id := String(args.get("toolset_name", ""))
	var name := String(args.get("tool_name", ""))
	if id == "" or name.begins_with(id + "."):
		# A full name: godot.scene.set_properties.
		var cut := name.rfind(".")
		if cut > 0 and _sets.has(name.substr(0, cut)):
			id = name.substr(0, cut)
			name = name.substr(cut + 1)
	if not _sets.has(id):
		return t._err("Unknown toolset '%s'. Toolsets: %s." % [id, ", ".join(_order)])
	var ts = _sets[id]
	var spec: Dictionary = {}
	for s in ts.tool_specs():
		if s.name == name:
			spec = s
	if spec.is_empty():
		return t._err("%s has no tool '%s'. Its tools: %s." % [id, name,
			", ".join(ts.tool_specs().map(func(s): return s.name))])
	var tool_args: Dictionary = args.arguments if typeof(args.get("arguments")) == TYPE_DICTIONARY else {}
	var missing: Array = spec.inputSchema.get("required", []).filter(func(r): return not tool_args.has(r))
	if not missing.is_empty():
		return t._err("%s.%s needs %s (describe_toolset %s gives the schema)." % [id, name, ", ".join(missing), id])
	var result = await ts.run(name, tool_args)
	if typeof(result) != TYPE_DICTIONARY:
		return t._err("%s.%s failed inside Godot; read the log." % [id, name])
	return result


func _tool(name: String, description: String, props: Dictionary, required: Array = []) -> Dictionary:
	return t._tool(name, description, props, required)
