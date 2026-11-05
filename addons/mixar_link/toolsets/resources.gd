@tool
extends "res://addons/mixar_link/toolsets/base.gd"
## godot.resources: Resource files (.tres). Reading anywhere in res://;
## creating and editing only under res://mixar/. A resource on disk has no
## "open" state, so set_resource_properties saves the file it edits (not
## undoable); scenes that use it see the change at once.

const MAX_FILES := 300


func toolset_id() -> String:
	return "godot.resources"


func toolset_description() -> String:
	return "Resource files: list the project's resources by type, read a resource's properties, create a .tres under res://mixar/ (a material, mesh, curve, environment...) and edit one there. Values as in godot.scene.set_properties."


func tool_specs() -> Array:
	return [
		spec("create_resource", "Create a resource of a built-in Resource class with properties and save it as a .tres under res://mixar/. Refuses an existing file unless overwrite=true. Use it in a scene by setting a property to its path.",
			{"type": {"type": "string", "description": "e.g. StandardMaterial3D, BoxMesh, Environment"},
			 "path": {"type": "string", "description": "res://mixar/....tres"},
			 "properties": {"type": "object"}, "overwrite": {"type": "boolean"}}, ["type", "path"]),
		spec("get_resource", "A resource file's class and properties: without names the ones that differ from defaults, with names exactly those. Anywhere in res:// (imported files such as .glb and .png too).",
			{"path": {"type": "string"}, "properties": {"type": "array", "items": {"type": "string"}}}, ["path"]),
		spec("set_resource_properties", "Set several properties of a .tres under res://mixar/ and save it (all or nothing; not undoable). edits is [{property, value}] or {property: value}.",
			{"path": {"type": "string"}, "edits": {}}, ["path", "edits"]),
		spec("list_resources", "Resource files under dir (default res://) whose type is or derives from type (e.g. Material, Mesh, PackedScene, Texture2D, Script), from the editor's file index: path and type.",
			{"type": {"type": "string"}, "dir": {"type": "string"}, "max_results": {"type": "integer"}}),
	]


func run(tool: String, args: Dictionary):
	match tool:
		"create_resource": return _create(args)
		"get_resource": return _read(args)
		"set_resource_properties": return _edit(args)
		"list_resources": return await _list(args)
	return err("Unknown tool " + tool)


## Why `path` cannot be written as a .tres, else "".
func _refusal(path: String) -> String:
	if not path.begins_with(t.MIXAR_DIR + "/") or path.contains("..") or path.substr(6).contains("//"):
		return "Mixar writes resources only under %s/ (e.g. %s/materials/red.tres)." % [t.MIXAR_DIR, t.MIXAR_DIR]
	if path.get_extension().to_lower() != "tres":
		return "Resources are written as .tres (text) files."
	return ""


func _create(args: Dictionary):
	var path := String(args.get("path", ""))
	var refusal := _refusal(path)
	if refusal != "":
		return err(refusal)
	var type := String(args.get("type", ""))
	if not ClassDB.class_exists(type) or not ClassDB.is_parent_class(type, "Resource") or not ClassDB.can_instantiate(type):
		return err("'%s' is not a Resource class that can be created (godot.classes.search_classes with base Resource)." % type)
	if Values.forbidden_class(type) or type == "PackedScene":
		return err("%s files are not made here: scripts and scenes go through godot.files.write_file." % type)
	if FileAccess.file_exists(path) and not bool(args.get("overwrite", false)):
		return err("%s exists; set_resource_properties edits it, or pass overwrite=true." % path)
	var props = args.get("properties", {})
	var made := Values.new_resource(type, props if typeof(props) == TYPE_DICTIONARY else {})
	if made.has("error"):
		return err(made.error + " Nothing was written.")
	var res: Resource = made.value
	var new_dir := not DirAccess.dir_exists_absolute(path.get_base_dir())
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	if ResourceSaver.save(res, path) != OK:
		return err("Saving %s failed; read the log." % path)
	res.take_over_path(path)
	var fs := EditorInterface.get_resource_filesystem()
	if new_dir:
		fs.scan()  # update_file does not add a new folder to the index
	else:
		fs.update_file(path)
	return ok({"path": path, "type": type, "properties": Values.changed_properties(res)})


func _read(args: Dictionary):
	var path := String(args.get("path", ""))
	if not path.begins_with("res://") or path.contains("..") or path.begins_with("res://.godot"):
		return err("Read a res:// resource outside .godot/.")
	if not ResourceLoader.exists(path):
		return err("No resource at %s (godot.resources.list_resources lists them)." % path)
	var res = load(path)
	if res == null:
		return err("%s did not load; read the log." % path)
	var names: Array = str_array(args.get("properties", []))
	var values := {}
	var unknown: Array = []
	if names.is_empty():
		values = Values.changed_properties(res, null, 0, 60)
	else:
		for n in names:
			if n in res:
				values[n] = Values.to_json(res.get(n))
			else:
				unknown.append(n)
	var out := {"path": path, "type": res.get_class(), "properties": values}
	if res is PackedScene:
		var state: SceneState = res.get_state()
		out["scene"] = {"nodes": state.get_node_count(), "root_type": String(state.get_node_type(0)) if state.get_node_count() else ""}
	if not unknown.is_empty():
		out["unknown"] = unknown
	return ok(out)


func _edit(args: Dictionary):
	var path := String(args.get("path", ""))
	var refusal := _refusal(path)
	if refusal != "":
		return err(refusal)
	if not ResourceLoader.exists(path):
		return err("No resource at %s; create_resource makes one." % path)
	var res = load(path)
	if res == null:
		return err("%s did not load; read the log." % path)
	var edits: Array = []
	var raw = args.get("edits")
	if typeof(raw) == TYPE_DICTIONARY:
		for k in raw:
			edits.append({"property": k, "value": raw[k]})
	elif typeof(raw) == TYPE_ARRAY:
		edits = raw
	if edits.is_empty():
		return err("edits is [{property, value}] or {property: value}, with at least one edit.")
	var prepared: Array = []
	for e in edits:
		if typeof(e) != TYPE_DICTIONARY or not e.has("property") or not e.has("value"):
			return err("Each edit needs property and value. Nothing was changed.")
		var prop := String(e.property)
		var info := Values.prop_info(res, prop)
		if not Values.is_editable(info) or prop.begins_with("resource_"):
			return err("%s has no editable property '%s'. Nothing was changed." % [res.get_class(), prop])
		var conv := Values.from_json(e.value, res.get(prop), info)
		if conv.has("error"):
			return err("%s %s Nothing was changed." % [prop, conv.error])
		prepared.append([prop, conv.value])
	for e in prepared:
		res.set(e[0], e[1])
	if ResourceSaver.save(res, path) != OK:
		return err("Saving %s failed; read the log." % path)
	EditorInterface.get_resource_filesystem().update_file(path)
	var values := {}
	for e in prepared:
		values[e[0]] = Values.to_json(res.get(e[0]))
	return ok({"path": path, "set": values, "saved": true, "undoable": false})


func _list(args: Dictionary):
	var dir := String(args.get("dir", "res://")).trim_suffix("/")
	if dir == "res:/":
		dir = "res://"
	if not dir.begins_with("res://") or dir.contains(".."):
		return err("List a res:// folder.")
	var type := String(args.get("type", ""))
	if type != "" and not ClassDB.class_exists(type):
		return err("No class '%s'." % type)
	var limit := clampi(int(args.get("max_results", MAX_FILES)), 1, 2000)
	var fs := EditorInterface.get_resource_filesystem()
	var start := fs.get_filesystem_path(dir)
	if start == null and DirAccess.dir_exists_absolute(dir):
		# A folder made moments ago: wait for the index to catch up.
		var tree: SceneTree = t.plugin.get_tree()
		var t0 := Time.get_ticks_msec()
		if not fs.is_scanning():
			fs.scan()
		await tree.process_frame
		while fs.is_scanning() and Time.get_ticks_msec() - t0 < 30000:
			await tree.process_frame
		start = fs.get_filesystem_path(dir)
	if start == null:
		return err("No folder %s in the editor's file index (godot.files.rescan refreshes it)." % dir)
	var found: Array = []
	var total := 0
	var queue: Array = [start]
	while not queue.is_empty():
		var d: EditorFileSystemDirectory = queue.pop_front()
		if d.get_path().begins_with("res://.godot"):
			continue
		for i in d.get_subdir_count():
			queue.append(d.get_subdir(i))
		for i in d.get_file_count():
			var ft := String(d.get_file_type(i))
			if type != "" and ft != type and not (ClassDB.class_exists(ft) and ClassDB.is_parent_class(ft, type)):
				continue
			total += 1
			if found.size() < limit:
				found.append({"path": d.get_file_path(i), "type": ft})
	return ok({"dir": dir, "resources": found, "total": total, "truncated": total > found.size()})
