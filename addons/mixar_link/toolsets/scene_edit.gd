@tool
extends "res://addons/mixar_link/toolsets/base.gd"
## godot.scene's structural edits on the open scene: add, remove, reparent,
## duplicate, connect / disconnect signals, editable instances. Each call is
## one EditorUndoRedoManager action; nothing is saved here.

const MAX_NODES := 50


func run(tool: String, args: Dictionary):
	var r := edit_root()
	if r.has("error"):
		return err(r.error)
	match tool:
		"add_nodes": return _add_nodes(r.root, args)
		"remove_nodes": return _remove_nodes(r.root, args)
		"reparent": return _reparent(r.root, args)
		"duplicate": return _duplicate(r.root, args)
		"connect_signal": return _connect(r.root, args)
		"disconnect_signal": return _disconnect(r.root, args)
		"edit_instance": return _edit_instance(r.root, args)
	return err("Unknown tool " + tool)


## A node the scene itself owns (not the inside of an instanced scene).
func _owned(root: Node, node: Node) -> bool:
	return node == root or node.owner == root


func _can_hold_children(root: Node, node: Node) -> bool:
	return _owned(root, node) or (node.owner != null and root.is_editable_instance(node.owner))


func _add_nodes(root: Node, args: Dictionary):
	var specs = args.get("nodes")
	if typeof(specs) != TYPE_ARRAY or specs.is_empty() or specs.size() > MAX_NODES:
		return err("nodes must be a list of 1 to %d {parent, type | scene, name, properties}." % MAX_NODES)
	var made: Array = []  # [node, parent, parent_is_new]
	var by_path := {}
	var problem := ""
	for i in specs.size():
		var s = specs[i]
		if typeof(s) != TYPE_DICTIONARY:
			problem = "node %d is not an object." % i
			break
		var name := String(s.get("name", ""))
		if not valid_node_name(name):
			problem = "node %d: name must be a plain node name (no . : @ / \" %%)." % i
			break
		var parent_path := String(s.get("parent", ".")).trim_prefix("./")
		var parent: Node = by_path.get(parent_path)
		var parent_is_new := parent != null
		if parent == null:
			parent = node_at(parent_path)
			if parent == null:
				problem = "node %d: no parent at '%s'." % [i, parent_path]
				break
			if not _can_hold_children(root, parent):
				problem = "node %d: '%s' is inside an instanced scene; godot.scene.edit_instance its instance first." % [i, parent_path]
				break
		var made_node := _make(root, s, i)
		if made_node.has("error"):
			problem = made_node.error
			break
		var node: Node = made_node.node
		node.name = name
		made.append([node, parent, parent_is_new])
		var base := parent_path if parent_is_new else path_of(parent)
		by_path[name if base in ["", "."] else base + "/" + name] = node
	if problem != "":
		for m in made:
			m[0].free()  # none is parented yet
		return err(problem + " Nothing was added.")
	var undo: EditorUndoRedoManager = t.plugin.get_undo_redo()
	undo.create_action("Mixar: add %d node%s" % [made.size(), "" if made.size() == 1 else "s"])
	for m in made:
		undo.add_do_method(m[1], "add_child", m[0], true)
		undo.add_do_method(m[0], "set_owner", root)
		undo.add_do_reference(m[0])
	for m in made:
		if not m[2]:
			undo.add_undo_method(m[1], "remove_child", m[0])
	undo.commit_action()
	var added: Array = []
	for m in made:
		var entry := {"path": path_of(m[0]), "type": m[0].get_class()}
		if m[0].scene_file_path != "":
			entry["instance_of"] = m[0].scene_file_path
		added.append(entry)
	return ok({"added": added, "undo": last_action(), "saved": false})


## {"node"} built from one add_nodes entry (type or scene, then properties).
func _make(root: Node, s: Dictionary, i: int) -> Dictionary:
	var node: Node
	if String(s.get("scene", "")) != "":
		var path := String(s.scene)
		if not path.begins_with("res://") or not ResourceLoader.exists(path):
			return {"error": "node %d: no scene at %s." % [i, path]}
		if path == root.scene_file_path:
			return {"error": "node %d: a scene cannot contain itself." % i}
		var packed = load(path)
		if not packed is PackedScene or not packed.can_instantiate():
			return {"error": "node %d: %s is not a scene that can be instanced." % [i, path]}
		node = packed.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	else:
		var type := String(s.get("type", ""))
		if type == "":
			return {"error": "node %d needs a type (a Node class) or a scene (res://...)." % i}
		if not ClassDB.class_exists(type) or not ClassDB.is_parent_class(type, "Node") or not ClassDB.can_instantiate(type) \
				or Values.forbidden_class(type):
			return {"error": "node %d: '%s' is not a node type that can be added (godot.classes.search_classes with base Node lists them)." % [i, type]}
		node = ClassDB.instantiate(type)
	var props = s.get("properties", {})
	if typeof(props) != TYPE_DICTIONARY:
		node.free()
		return {"error": "node %d: properties must be an object {name: value}." % i}
	for key in props:
		var info := Values.prop_info(node, String(key))
		if not Values.is_editable(info) or String(key) == "name":
			node.free()
			return {"error": "node %d: %s has no editable property '%s'." % [i, node.get_class(), key]}
		var conv := Values.from_json(props[key], node.get(String(key)), info)
		if conv.has("error"):
			node.free()
			return {"error": "node %d: %s %s" % [i, key, conv.error]}
		if String(key) == "script" and conv.value is Script \
				and not ClassDB.is_parent_class(node.get_class(), conv.value.get_instance_base_type()):
			node.free()
			return {"error": "node %d: that script does not extend %s." % [i, node.get_class()]}
		node.set(String(key), conv.value)
	return {"node": node}


func _remove_nodes(root: Node, args: Dictionary):
	var paths: Array = str_array(args.get("nodes", []))
	if paths.is_empty() or paths.size() > MAX_NODES:
		return err("nodes must be a list of 1 to %d node paths." % MAX_NODES)
	var nodes: Array = []
	for p in paths:
		var node := node_at(p)
		if node == null or node == root:
			return err("No removable node at '%s' (the root cannot be removed). Nothing was removed." % p)
		if node.owner != root:
			return err("'%s' is inside an instanced scene; remove the instance, or hide the node. Nothing was removed." % p)
		if node not in nodes:
			nodes.append(node)
	# A node whose ancestor also goes is removed with it.
	nodes = nodes.filter(func(n): return not nodes.any(func(o): return o != n and o.is_ancestor_of(n)))
	var undo: EditorUndoRedoManager = t.plugin.get_undo_redo()
	undo.create_action("Mixar: remove %d node%s" % [nodes.size(), "" if nodes.size() == 1 else "s"])
	for node in nodes:
		undo.add_do_method(node.get_parent(), "remove_child", node)
	# Back in ascending index order, so each index exists when it is restored.
	var by_index := nodes.duplicate()
	by_index.sort_custom(func(a, b): return a.get_index() < b.get_index())
	for node in by_index:
		var parent: Node = node.get_parent()
		undo.add_undo_method(parent, "add_child", node, true)
		undo.add_undo_method(parent, "move_child", node, node.get_index())
		# remove_child clears owners the node no longer reaches; restore them all.
		for n in [node] + node.find_children("*", "", true, false):
			if n.owner == root:
				undo.add_undo_method(n, "set_owner", root)
		undo.add_undo_reference(node)
	var removed: Array = nodes.map(func(n): return path_of(n))
	undo.commit_action()
	return ok({"removed": removed, "undo": last_action(), "saved": false})


func _reparent(root: Node, args: Dictionary):
	var node := node_at(args.get("node", ""))
	var parent := node_at(args.get("parent", ""))
	if node == null or node == root:
		return err("No movable node at '%s' (the root cannot move)." % args.get("node"))
	if not _owned(root, node):
		return err("'%s' is inside an instanced scene; only the scene's own nodes move." % args.node)
	if parent == null:
		return err("No parent at '%s'." % args.get("parent"))
	if parent == node or node.is_ancestor_of(parent):
		return err("A node cannot move under itself or its own children.")
	if not _can_hold_children(root, parent):
		return err("'%s' is inside an instanced scene; godot.scene.edit_instance its instance first." % args.parent)
	var keep := bool(args.get("keep_global_transform", true))
	var old_parent := node.get_parent()
	var old_index := node.get_index()
	var old_name := String(node.name)
	var undo: EditorUndoRedoManager = t.plugin.get_undo_redo()
	undo.create_action("Mixar: reparent " + old_name)
	undo.add_do_method(node, "reparent", parent, keep)
	if args.has("index"):
		undo.add_do_method(parent, "move_child", node, int(args.index))
	undo.add_undo_method(node, "reparent", old_parent, keep)
	undo.add_undo_method(old_parent, "move_child", node, old_index)
	undo.add_undo_method(node, "set_name", old_name)
	undo.commit_action()
	return ok({"node": path_of(node), "parent": path_of(parent), "index": node.get_index(), "undo": last_action(), "saved": false})


func _duplicate(root: Node, args: Dictionary):
	var node := node_at(args.get("node", ""))
	if node == null or node == root:
		return err("No node to duplicate at '%s' (the root cannot be duplicated)." % args.get("node"))
	if not _owned(root, node):
		return err("'%s' is inside an instanced scene; duplicate the instance instead." % args.node)
	var parent := node.get_parent()
	if String(args.get("parent", "")) != "":
		parent = node_at(args.parent)
		if parent == null or not _can_hold_children(root, parent):
			return err("No parent that can hold children at '%s'." % args.parent)
	var name := String(args.get("name", node.name))
	if not valid_node_name(name):
		return err("name must be a plain node name.")
	var owned: Array = []
	for n in [node] + node.find_children("*", "", true, false):
		if n.owner == root:
			owned.append(node.get_path_to(n))
	var copy: Node = node.duplicate()
	copy.name = name
	var undo: EditorUndoRedoManager = t.plugin.get_undo_redo()
	undo.create_action("Mixar: duplicate " + String(node.name))
	undo.add_do_method(parent, "add_child", copy, true)
	for rel in owned:
		var n := copy.get_node_or_null(rel)
		if n != null:
			undo.add_do_method(n, "set_owner", root)
	if node.scene_file_path != "" and root.is_editable_instance(node):
		undo.add_do_method(root, "set_editable_instance", copy, true)
	undo.add_do_reference(copy)
	undo.add_undo_method(parent, "remove_child", copy)
	undo.commit_action()
	return ok({"node": path_of(copy), "source": path_of(node), "undo": last_action(), "saved": false})


func _connect(root: Node, args: Dictionary):
	var node := node_at(args.get("node", ""))
	var target := node_at(args.get("target", ""))
	var sig := String(args.get("signal", ""))
	var method := String(args.get("method", ""))
	if node == null or target == null:
		return err("No node at '%s'." % (args.get("node") if node == null else args.get("target")))
	if not node.has_signal(sig):
		return err("%s (%s) has no signal '%s'; godot.classes.class_info lists signals." % [args.node, node.get_class(), sig])
	var script = target.get_script()
	if not target.has_method(method) and not (script is Script and script.has_method(method)):
		return err("%s has no method '%s'; add it to its script (godot.files.write_file), then connect." % [args.target, method])
	var callable := Callable(target, method)
	var binds = args.get("binds", [])
	if typeof(binds) == TYPE_ARRAY and not binds.is_empty():
		callable = callable.bindv(Values._plain(binds))
	if node.is_connected(sig, callable):
		return err("That connection already exists.")
	var flags := CONNECT_PERSIST
	if bool(args.get("deferred", false)):
		flags |= CONNECT_DEFERRED
	if bool(args.get("one_shot", false)):
		flags |= CONNECT_ONE_SHOT
	var undo: EditorUndoRedoManager = t.plugin.get_undo_redo()
	undo.create_action("Mixar: connect %s.%s" % [node.name, sig])
	undo.add_do_method(node, "connect", sig, callable, flags)
	undo.add_undo_method(node, "disconnect", sig, callable)
	undo.commit_action()
	return ok({"node": path_of(node), "signal": sig, "target": path_of(target), "method": method,
		"connected": node.is_connected(sig, callable), "undo": last_action(), "saved": false})


func _disconnect(root: Node, args: Dictionary):
	var node := node_at(args.get("node", ""))
	var target := node_at(args.get("target", ""))
	var sig := String(args.get("signal", ""))
	var method := String(args.get("method", ""))
	if node == null or target == null or not node.has_signal(sig):
		return err("No such node or signal; godot.scene.get_properties lists a node's connections.")
	for c in node.get_signal_connection_list(sig):
		if c.callable.get_object() == target and String(c.callable.get_method()) == method:
			var undo: EditorUndoRedoManager = t.plugin.get_undo_redo()
			undo.create_action("Mixar: disconnect %s.%s" % [node.name, sig])
			undo.add_do_method(node, "disconnect", sig, c.callable)
			undo.add_undo_method(node, "connect", sig, c.callable, c.flags)
			undo.commit_action()
			return ok({"disconnected": {"node": path_of(node), "signal": sig, "target": path_of(target), "method": method},
				"undo": last_action(), "saved": false})
	return err("%s.%s is not connected to %s.%s." % [args.node, sig, args.target, method])


func _edit_instance(root: Node, args: Dictionary):
	var node := node_at(args.get("node", ""))
	if node == null or node == root or node.scene_file_path == "" or node.owner != root:
		return err("'%s' is not an instanced scene in this scene (get_nodes marks them instance_of)." % args.get("node"))
	var on := bool(args.get("editable", true))
	var undo: EditorUndoRedoManager = t.plugin.get_undo_redo()
	undo.create_action("Mixar: editable children " + String(node.name))
	undo.add_do_method(root, "set_editable_instance", node, on)
	undo.add_undo_method(root, "set_editable_instance", node, root.is_editable_instance(node))
	undo.commit_action()
	return ok({"node": path_of(node), "editable_children": root.is_editable_instance(node), "undo": last_action(), "saved": false})
