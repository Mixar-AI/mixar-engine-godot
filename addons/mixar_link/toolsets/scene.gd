@tool
extends "res://addons/mixar_link/toolsets/base.gd"
## godot.scene: the OPEN edited scene, through EditorUndoRedoManager (every
## edit is one Ctrl+Z step) and never saved here (godot.editor.save_scene).
## Reads, property edits and method calls live in this file; structural edits
## (add, remove, reparent, duplicate, signals, editable instances) in
## scene_edit.gd.

const SceneEdit := preload("res://addons/mixar_link/toolsets/scene_edit.gd")
const MAX_PROPS := 60
const MAX_EDITS := 100
## Methods call_method never runs: each changes the tree or attaches code
## outside undo, or has its own tool.
const BLOCKED_METHODS := {
	"free": "remove_nodes", "queue_free": "remove_nodes", "remove_child": "remove_nodes",
	"add_child": "add_nodes", "add_sibling": "add_nodes", "replace_by": "remove_nodes and add_nodes",
	"reparent": "reparent", "move_child": "reparent", "set_owner": "", "set_script": "set_properties (script)",
	"set": "set_properties", "set_deferred": "set_properties", "set_indexed": "set_properties",
	"connect": "connect_signal", "disconnect": "disconnect_signal", "call": "", "callv": "", "call_deferred": "",
	"propagate_call": "", "notification": "", "propagate_notification": "", "emit_signal": "",
	"set_editable_instance": "edit_instance", "duplicate": "duplicate", "request_ready": "",
}


func toolset_id() -> String:
	return "godot.scene"


func toolset_description() -> String:
	return "The scene open in the editor: read nodes and properties, set properties, add/remove/reparent/duplicate nodes, connect signals, call methods. Every edit is one undo step and nothing is saved until godot.editor.save_scene. Node paths are relative to the scene root (\".\" is the root); units and axes are Godot's (Y up, metres)."


func tool_specs() -> Array:
	var value_doc := "JSON coerced to the property's type: numbers, strings, [x, y, z] for vectors, [r, g, b, a] or \"#rrggbb\" for colours, [[x], [y], [z], [origin]] for Transform3D, enum names, \"res://...\" for a resource, {\"$new\": \"StandardMaterial3D\", \"properties\": {..}} for a new embedded resource, {\"$godot\": \"Vector3(1, 2, 3)\"} for any Godot literal."
	return [
		spec("get_nodes", "The open scene's nodes under root (default the scene root) to a depth: path, type, child count, script, instance_of (an instanced scene) and the listed properties. Nodes inside instanced scenes are listed only when the instance has editable children.",
			{"root": {"type": "string"}, "depth": {"type": "integer", "description": "levels below root (default 3, max 20)"},
			 "filter_type": {"type": "string", "description": "only nodes of this class (or a subclass / script class_name)"},
			 "properties": {"type": "array", "items": {"type": "string"}, "description": "property values to include per node"},
			 "max_nodes": {"type": "integer"}}),
		spec("get_properties", "One node's properties. Without names: the editable properties that differ from their defaults (compact). With names: exactly those. Also its type, script, groups and outgoing signal connections.",
			{"node": {"type": "string"}, "names": {"type": "array", "items": {"type": "string"}}}, ["node"]),
		spec("set_properties", "Set several properties on any nodes in one undo step (all or nothing: one bad edit and none apply). Values: " + value_doc,
			{"edits": {"type": "array", "items": {"type": "object", "properties": {
				"node": {"type": "string"}, "property": {"type": "string"}, "value": {}},
				"required": ["node", "property", "value"]}}}, ["edits"]),
		spec("call_method", "Call a method on a node (built-in methods, or script methods of @tool scripts) and return its result. NOT undoable; to change state prefer set_properties. Arguments are coerced to the method's parameter types.",
			{"node": {"type": "string"}, "method": {"type": "string"}, "args": {"type": "array", "items": {}}},
			["node", "method"]),
		spec("add_nodes", "Add several nodes in one undo step: each is a built-in type, or an instance of a scene (res://...tscn/.glb), under parent (default the root; a node added earlier in the same call may be a parent), with a name and properties (values as in set_properties). Returns the actual paths (Godot renames on a clash).",
			{"nodes": {"type": "array", "items": {"type": "object", "properties": {
				"parent": {"type": "string"}, "type": {"type": "string"}, "scene": {"type": "string"},
				"name": {"type": "string"}, "properties": {"type": "object"}}, "required": ["name"]}}}, ["nodes"]),
		spec("remove_nodes", "Remove several nodes (not the root, not nodes inside an instanced scene) in one undo step.",
			{"nodes": {"type": "array", "items": {"type": "string"}}}, ["nodes"]),
		spec("reparent", "Move a node under a new parent, keeping its global transform unless keep_global_transform=false; index places it among the new siblings. One undo step.",
			{"node": {"type": "string"}, "parent": {"type": "string"}, "keep_global_transform": {"type": "boolean"},
			 "index": {"type": "integer"}}, ["node", "parent"]),
		spec("duplicate", "Duplicate a node and its children (scripts, groups, signals kept) next to it or under parent, optionally renamed. One undo step.",
			{"node": {"type": "string"}, "name": {"type": "string"}, "parent": {"type": "string"}}, ["node"]),
		spec("connect_signal", "Connect node's signal to target's method (saved with the scene). The method must exist on the target (write it into the target's script first). One undo step.",
			{"node": {"type": "string"}, "signal": {"type": "string"}, "target": {"type": "string"},
			 "method": {"type": "string"}, "binds": {"type": "array", "items": {}},
			 "deferred": {"type": "boolean"}, "one_shot": {"type": "boolean"}}, ["node", "signal", "target", "method"]),
		spec("disconnect_signal", "Remove a connection made in the scene (get_properties lists them). One undo step.",
			{"node": {"type": "string"}, "signal": {"type": "string"}, "target": {"type": "string"},
			 "method": {"type": "string"}}, ["node", "signal", "target", "method"]),
		spec("edit_instance", "Turn on (or off) Editable Children for an instanced scene, so nodes inside it can be edited and saved with this scene. One undo step.",
			{"node": {"type": "string"}, "editable": {"type": "boolean"}}, ["node"]),
	]


func run(tool: String, args: Dictionary):
	match tool:
		"get_nodes": return _get_nodes(args)
		"get_properties": return _get_properties(args)
		"set_properties": return _set_properties(args)
		"call_method": return await _call_method(args)
	var edit = SceneEdit.new()
	edit.t = t
	return edit.run(tool, args)


func _get_nodes(args: Dictionary):
	var r := edit_root(false)
	if r.has("error"):
		return err(r.error)
	var root: Node = r.root
	var start := node_at(args.get("root", "."))
	if start == null:
		return err("No node at '%s'." % args.get("root"))
	var depth := clampi(int(args.get("depth", 3)), 0, 20)
	var limit := clampi(int(args.get("max_nodes", MAX_LIST)), 1, 1000)
	var filter := String(args.get("filter_type", ""))
	var props: Array = str_array(args.get("properties", []))
	var nodes: Array = []
	var total := 0
	var queue: Array = [[start, 0]]
	while not queue.is_empty():
		var item: Array = queue.pop_front()
		var node: Node = item[0]
		if filter == "" or _is_type(node, filter):
			total += 1
			if nodes.size() < limit:
				nodes.append(_node_entry(root, node, props))
		if item[1] < depth:
			for child in node.get_children():
				if child.owner == root or (child.owner != null and root.is_editable_instance(child.owner)):
					queue.append([child, item[1] + 1])
	return ok({"scene": root.scene_file_path, "nodes": nodes, "total": total, "truncated": total > nodes.size()})


func _node_entry(root: Node, node: Node, props: Array) -> Dictionary:
	var entry := {"path": path_of(node), "type": node.get_class(), "children": node.get_child_count()}
	var script = node.get_script()
	if script is Script:
		entry["script"] = script.resource_path if script.resource_path != "" else "(embedded)"
	if node != root and node.scene_file_path != "":
		entry["instance_of"] = node.scene_file_path
		entry["editable_children"] = root.is_editable_instance(node)
	if node.owner != root and node != root:
		entry["inside_instance"] = true
	if not props.is_empty():
		var values := {}
		for p in props:
			if p in node:
				values[p] = Values.to_json(node.get(p), root)
		entry["properties"] = values
	return entry


func _is_type(node: Node, type: String) -> bool:
	if node.is_class(type):
		return true
	var script = node.get_script()
	while script is Script:
		if script.get_global_name() == type:
			return true
		script = script.get_base_script()
	return false


func _get_properties(args: Dictionary):
	var r := edit_root(false)
	if r.has("error"):
		return err(r.error)
	var node := node_at(args.get("node", ""))
	if node == null:
		return err("No node at '%s' (godot.scene.get_nodes lists paths)." % args.get("node"))
	var names: Array = str_array(args.get("names", []))
	var values := {}
	var unknown: Array = []
	if names.is_empty():
		values = Values.changed_properties(node, r.root, 0, MAX_PROPS)
		values.erase("name")
	else:
		for n in names:
			if n in node:
				values[n] = Values.to_json(node.get(n), r.root)
			else:
				unknown.append(n)
	var out := {"node": path_of(node), "type": node.get_class(), "properties": values}
	var script = node.get_script()
	if script is Script:
		out["script"] = script.resource_path
	var groups := node.get_groups().filter(func(g): return not String(g).begins_with("_"))
	if not groups.is_empty():
		out["groups"] = groups.map(func(g): return String(g))
	var conns: Array = []
	for s in node.get_signal_list():
		for c in node.get_signal_connection_list(s.name):
			if c.flags & CONNECT_PERSIST and c.callable.get_object() is Node and conns.size() < 40:
				conns.append({"signal": String(s.name), "target": path_of(c.callable.get_object()), "method": String(c.callable.get_method())})
	if not conns.is_empty():
		out["connections"] = conns
	if not unknown.is_empty():
		out["unknown"] = unknown
	return ok(out)


## Validates every edit; {"edits": [[node, prop, value, old]]} or {"error"}.
func _prepare(root: Node, edits) -> Dictionary:
	if typeof(edits) != TYPE_ARRAY or edits.is_empty() or edits.size() > MAX_EDITS:
		return {"error": "edits must be a list of 1 to %d {node, property, value}." % MAX_EDITS}
	var out: Array = []
	for i in edits.size():
		var e = edits[i]
		if typeof(e) != TYPE_DICTIONARY or not e.has("node") or not e.has("property") or not e.has("value"):
			return {"error": "edit %d needs node, property and value." % i}
		var node := node_at(e.node)
		if node == null:
			return {"error": "edit %d: no node at '%s'." % [i, e.node]}
		var prop := String(e.property)
		var info := Values.prop_info(node, prop)
		if not Values.is_editable(info):
			return {"error": "edit %d: %s (%s) has no editable property '%s'; godot.classes.class_info lists them." % [
				i, e.node, node.get_class(), prop]}
		var current = node.get(prop)
		var conv := Values.from_json(e.value, current, info)
		if conv.has("error"):
			return {"error": "edit %d: %s.%s %s" % [i, e.node, prop, conv.error]}
		if prop == "script" and conv.value != null:
			if not conv.value is Script or not ClassDB.is_parent_class(node.get_class(), conv.value.get_instance_base_type()):
				return {"error": "edit %d: that script does not extend %s." % [i, node.get_class()]}
		out.append([node, prop, conv.value, current])
	return {"edits": out}


func _set_properties(args: Dictionary):
	var r := edit_root()
	if r.has("error"):
		return err(r.error)
	var prepared := _prepare(r.root, args.get("edits"))
	if prepared.has("error"):
		return err(prepared.error + " Nothing was changed.")
	var undo: EditorUndoRedoManager = t.plugin.get_undo_redo()
	undo.create_action("Mixar: set %d propert%s" % [prepared.edits.size(), "y" if prepared.edits.size() == 1 else "ies"])
	for e in prepared.edits:
		t._make_editable(e[0])
		undo.add_do_property(e[0], e[1], e[2])
		undo.add_undo_property(e[0], e[1], e[3])
	undo.commit_action()
	var results: Array = []
	for e in prepared.edits:
		results.append({"node": path_of(e[0]), "property": e[1], "value": Values.to_json(e[0].get(e[1]), r.root)})
	return ok({"set": results, "undo": last_action(), "saved": false})


func _call_method(args: Dictionary):
	var r := edit_root()
	if r.has("error"):
		return err(r.error)
	var node := node_at(args.get("node", ""))
	if node == null:
		return err("No node at '%s'." % args.get("node"))
	var method := String(args.get("method", ""))
	if BLOCKED_METHODS.has(method) or method.begins_with("_"):
		var instead: String = BLOCKED_METHODS.get(method, "")
		return err("call_method does not run %s: it changes the scene outside undo or runs code.%s" % [
			method, " Use godot.scene.%s instead." % instead if instead != "" else ""])
	if not node.has_method(method):
		return err("%s (%s) has no method '%s'; godot.classes.class_info lists them." % [args.node, node.get_class(), method])
	var info := {}
	for m in node.get_method_list():
		if m.name == method:
			info = m
	var given: Array = args.get("args", []) if typeof(args.get("args")) == TYPE_ARRAY else []
	var call_args: Array = []
	if not info.is_empty():
		var params: Array = info.args
		var required: int = params.size() - info.get("default_args", []).size()
		if given.size() < required or (given.size() > params.size() and not int(info.flags) & METHOD_FLAG_VARARG):
			return err("%s takes %d to %d arguments (%s); %d given." % [method, required, params.size(),
				", ".join(params.map(func(a): return "%s: %s" % [a.name, Values.type_label(a.type, String(a.class_name))])), given.size()])
		for i in given.size():
			var conv := Values.from_json(given[i], null, params[i] if i < params.size() else {})
			if conv.has("error"):
				return err("argument %d %s" % [i, conv.error])
			call_args.append(conv.value)
	else:
		call_args = given
	var mark: int = t.log_buffer.latest()
	var result = await node.callv(method, call_args)
	var data := {"node": path_of(node), "method": method, "result": Values.to_json(result, r.root), "undoable": false}
	var errors: Array = t._errors_since(mark)
	if not errors.is_empty():
		data["errors"] = errors
	EditorInterface.mark_scene_as_unsaved()
	return ok(data)
