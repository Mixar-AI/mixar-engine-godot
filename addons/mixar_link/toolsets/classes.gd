@tool
extends "res://addons/mixar_link/toolsets/base.gd"
## godot.classes: Godot's class reference from ClassDB (and the project's own
## class_name scripts), so the agent knows the exact property, method and
## signal names before it edits.

const SECTIONS := ["properties", "methods", "signals", "constants", "enums"]
const MAX_SECTION := 300
const HINTS := {
	PROPERTY_HINT_RANGE: "range", PROPERTY_HINT_ENUM: "enum", PROPERTY_HINT_FLAGS: "flags",
	PROPERTY_HINT_FILE: "file", PROPERTY_HINT_DIR: "dir", PROPERTY_HINT_RESOURCE_TYPE: "resource_type",
	PROPERTY_HINT_MULTILINE_TEXT: "multiline", PROPERTY_HINT_COLOR_NO_ALPHA: "color_no_alpha",
	PROPERTY_HINT_LAYERS_3D_PHYSICS: "layers_3d_physics", PROPERTY_HINT_LAYERS_2D_PHYSICS: "layers_2d_physics",
	PROPERTY_HINT_LAYERS_3D_RENDER: "layers_3d_render", PROPERTY_HINT_NODE_PATH_VALID_TYPES: "node_path_types",
	PROPERTY_HINT_ARRAY_TYPE: "array_type", PROPERTY_HINT_EXP_EASING: "easing", PROPERTY_HINT_ENUM_SUGGESTION: "enum_suggestion",
}


func toolset_id() -> String:
	return "godot.classes"


func toolset_description() -> String:
	return "Godot's class reference (engine classes and the project's class_name scripts): properties with types and hints, methods with arguments, signals, constants, enums, the parent chain; and class search. Read-only."


func tool_specs() -> Array:
	return [
		spec("class_info", "One class: parent chain, and the sections asked for (default all): properties (name, type, hint, default), methods (name, args with types and defaults, return), signals, constants, enums. inherited=true adds the parents' members (large: narrow it with filter).",
			{"class_name": {"type": "string", "description": "e.g. MeshInstance3D, or a project class_name"},
			 "sections": {"type": "array", "items": {"type": "string", "enum": SECTIONS}},
			 "inherited": {"type": "boolean", "description": "include members from parent classes (default false)"},
			 "filter": {"type": "string", "description": "only members whose name contains this (case-insensitive)"}},
			["class_name"]),
		spec("search_classes", "Classes whose name contains query (case-insensitive), optionally only those deriving from base (e.g. Node3D, Resource, Material). Returns name, parent, whether it can be created, and editor_only.",
			{"query": {"type": "string"}, "base": {"type": "string"}, "max_results": {"type": "integer"}},
			["query"]),
	]


func run(tool: String, args: Dictionary):
	match tool:
		"class_info": return _class_info(args)
		"search_classes": return _search(args)
	return err("Unknown tool " + tool)


func _class_info(args: Dictionary):
	var cls := String(args.get("class_name", ""))
	var sections: Array = str_array(args.get("sections", SECTIONS))
	var own := not bool(args.get("inherited", false))
	var filter := String(args.get("filter", "")).to_lower()
	if ClassDB.class_exists(cls):
		return ok(_native(cls, sections, own, filter))
	var script := _global_script(cls)
	if script != null:
		return ok(_scripted(cls, script, sections, filter))
	return err("No class '%s'. godot.classes.search_classes finds class names." % cls)


func _native(cls: String, sections: Array, own: bool, filter: String) -> Dictionary:
	var out := {"class_name": cls, "parents": _native_chain(cls), "can_instantiate": ClassDB.can_instantiate(cls),
		"editor_only": ClassDB.class_get_api_type(cls) in [ClassDB.API_EDITOR, ClassDB.API_EDITOR_EXTENSION]}
	if "properties" in sections:
		var props: Array = []
		for info in ClassDB.class_get_property_list(cls, own):
			if Values.is_editable(info) and _match(info.name, filter):
				var entry := _prop(info)
				entry["default"] = Values.to_json(ClassDB.class_get_property_default_value(cls, info.name))
				props.append(entry)
		_put(out, "properties", props)
	if "methods" in sections:
		var methods: Array = []
		for m in ClassDB.class_get_method_list(cls, own):
			if _match(m.name, filter) and (not String(m.name).begins_with("_") or m.flags & METHOD_FLAG_VIRTUAL):
				methods.append(_method(m))
		_put(out, "methods", methods)
	if "signals" in sections:
		var signals: Array = []
		for s in ClassDB.class_get_signal_list(cls, own):
			if _match(s.name, filter):
				signals.append({"name": s.name, "args": s.args.map(func(a): return _arg(a))})
		_put(out, "signals", signals)
	var in_enums := {}
	if "enums" in sections or "constants" in sections:
		var enums := {}
		for e in ClassDB.class_get_enum_list(cls, own):
			var values := {}
			for c in ClassDB.class_get_enum_constants(cls, e, own):
				values[c] = ClassDB.class_get_integer_constant(cls, c)
				in_enums[c] = true
			if _match(e, filter) or values.keys().any(func(c): return _match(c, filter)):
				enums[e] = values
		if "enums" in sections:
			out["enums"] = enums
	if "constants" in sections:
		var constants := {}
		for c in ClassDB.class_get_integer_constant_list(cls, own):
			if not in_enums.has(c) and _match(c, filter):
				constants[c] = ClassDB.class_get_integer_constant(cls, c)
		out["constants"] = constants
	return out


func _scripted(cls: String, script: Script, sections: Array, filter: String) -> Dictionary:
	var base := script.get_instance_base_type()
	var out := {"class_name": cls, "script": script.resource_path, "extends": String(base),
		"parents": [String(base)] + _native_chain(base), "can_instantiate": script.can_instantiate()}
	if "properties" in sections:
		var props: Array = []
		for i in script.get_script_property_list():
			if Values.is_editable(i) and _match(i.name, filter):
				var e := _prop(i)
				e["default"] = Values.to_json(script.get_property_default_value(i.name))
				props.append(e)
		_put(out, "properties", props)
	if "methods" in sections:
		_put(out, "methods", script.get_script_method_list().filter(
			func(m): return _match(m.name, filter) and not String(m.name).begins_with("@")).map(func(m): return _method(m)))
	if "signals" in sections:
		_put(out, "signals", script.get_script_signal_list().filter(func(s): return _match(s.name, filter)).map(
			func(s): return {"name": s.name, "args": s.args.map(func(a): return _arg(a))}))
	if "constants" in sections or "enums" in sections:
		var constants := {}
		var map := script.get_script_constant_map()
		for k in map:
			if _match(k, filter) and typeof(map[k]) != TYPE_OBJECT:
				constants[k] = Values.to_json(map[k])
		out["constants"] = constants
	return out


func _search(args: Dictionary):
	var query := String(args.get("query", "")).to_lower()
	var base := String(args.get("base", ""))
	var limit := clampi(int(args.get("max_results", 60)), 1, 300)
	if base != "" and not ClassDB.class_exists(base) and _global_script(base) == null:
		return err("No base class '%s'." % base)
	var found: Array = []
	var total := 0
	var names := Array(ClassDB.get_class_list())
	names.sort()
	for cls in names:
		if query != "" and not String(cls).to_lower().contains(query):
			continue
		if base != "" and cls != base and not ClassDB.is_parent_class(cls, base):
			continue
		total += 1
		if found.size() < limit:
			found.append({"name": cls, "parent": ClassDB.get_parent_class(cls), "can_instantiate": ClassDB.can_instantiate(cls),
				"editor_only": ClassDB.class_get_api_type(cls) in [ClassDB.API_EDITOR, ClassDB.API_EDITOR_EXTENSION]})
	for g in ProjectSettings.get_global_class_list():
		var name := String(g["class"])
		if query != "" and not name.to_lower().contains(query):
			continue
		if base != "" and not _script_derives(name, base):
			continue
		total += 1
		if found.size() < limit:
			found.append({"name": name, "parent": String(g.base), "script": String(g.path), "can_instantiate": true,
				"editor_only": false})
	return ok({"classes": found, "total": total, "truncated": total > found.size()})


func _script_derives(name: String, base: String) -> bool:
	var seen := 0
	while name != "" and seen < 32:
		if name == base:
			return true
		if ClassDB.class_exists(name):
			return ClassDB.is_parent_class(name, base)
		var parent := ""
		for g in ProjectSettings.get_global_class_list():
			if String(g["class"]) == name:
				parent = String(g.base)
		name = parent
		seen += 1
	return false


func _global_script(cls: String) -> Script:
	for g in ProjectSettings.get_global_class_list():
		if String(g["class"]) == cls and ResourceLoader.exists(String(g.path)):
			return load(String(g.path)) as Script
	return null


func _native_chain(cls: String) -> Array:
	var chain: Array = []
	var p := ClassDB.get_parent_class(cls)
	while p != "":
		chain.append(p)
		p = ClassDB.get_parent_class(p)
	return chain


func _prop(info: Dictionary) -> Dictionary:
	var entry := {"name": info.name, "type": Values.type_label(info.type, String(info.class_name))}
	var hint := int(info.hint)
	if hint != PROPERTY_HINT_NONE and String(info.hint_string) != "":
		entry["hint"] = HINTS.get(hint, str(hint))
		entry["hint_string"] = String(info.hint_string).left(300)
	if not int(info.usage) & PROPERTY_USAGE_EDITOR:
		entry["hidden"] = true
	return entry


func _arg(a: Dictionary) -> Dictionary:
	return {"name": a.name, "type": Values.type_label(a.type, String(a.class_name))}


func _method(m: Dictionary) -> Dictionary:
	var args: Array = m.args.map(func(a): return _arg(a))
	var defaults: Array = m.get("default_args", [])
	var first_default := args.size() - defaults.size()
	for i in range(maxi(first_default, 0), args.size()):
		args[i]["default"] = Values.to_json(defaults[i - first_default])
	var entry := {"name": m.name, "args": args, "return": Values.type_label(m.return.type, String(m.return.class_name))}
	var flags := int(m.get("flags", 0))
	for f in [[METHOD_FLAG_CONST, "const"], [METHOD_FLAG_VIRTUAL, "virtual"], [METHOD_FLAG_STATIC, "static"], [METHOD_FLAG_VARARG, "vararg"]]:
		if flags & f[0]:
			entry[f[1]] = true
	return entry


func _match(name, filter: String) -> bool:
	return filter == "" or String(name).to_lower().contains(filter)


func _put(out: Dictionary, key: String, items: Array) -> void:
	out[key] = items.slice(0, MAX_SECTION)
	if items.size() > MAX_SECTION:
		out[key + "_truncated"] = items.size()
