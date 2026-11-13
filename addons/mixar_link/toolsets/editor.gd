@tool
extends "res://addons/mixar_link/toolsets/base.gd"
## godot.editor: the editor itself: open and save scenes, selection, a view of
## the viewport, the editor's state, and run_script (GDScript run once inside
## the editor, only after the user approves that run in Mixar).

const MAX_OUTPUT := 300
const TOOL_ANNOTATION := "(?m)^\\s*@tool\\b"


func toolset_id() -> String:
	return "godot.editor"


func toolset_description() -> String:
	return "The Godot editor: open a scene, save it (the scene and resource tools never save on their own), save all, select nodes, capture the 2D or 3D viewport, read the editor's state, and run a GDScript once in the editor (the user approves every run; not undoable)."


func tool_specs() -> Array:
	return [
		spec("open_scene", "Open a scene file (res://....tscn) in the editor, or switch to it when it is open; it becomes the scene godot.scene edits.",
			{"scene": {"type": "string"}}, ["scene"]),
		spec("save_scene", "Save the open scene, or another open scene by path. Plugin-mode projects save only scenes Mixar may edit.",
			{"scene": {"type": "string"}}),
		spec("save_all", "Save every open scene with unsaved changes (refused in plugin mode when one of them is a scene Mixar may not edit; save those one by one).", {}),
		spec("select", "Select nodes of the open scene in the editor (an empty list clears the selection).",
			{"nodes": {"type": "array", "items": {"type": "string"}}}, ["nodes"]),
		spec("capture_editor", "A JPEG of the editor's 3D (default) or 2D viewport as it is drawn now. A headless editor draws nothing and says so.",
			{"view": {"type": "string", "enum": ["3d", "2d"]}, "max_width": {"type": "integer"}}),
		spec("editor_state", "The editor's state: open scenes, the edited scene and whether Mixar may edit it, unsaved scenes, selection, whether the game runs, the last undo step, Godot and add-on versions, project mode.", {}),
		spec("run_script", "Run GDScript once inside the editor. The source defines func run(editor: EditorInterface) (it may use await); it is compiled first (errors come back and nothing runs), then run, returning {result, output (printed lines), errors}. Not undoable. The user is asked to approve every run; use the godot.scene / godot.resources tools for ordinary edits.",
			{"source": {"type": "string"}}, ["source"]),
	]


func run(tool: String, args: Dictionary):
	match tool:
		"open_scene": return t._open_scene(args)
		"save_scene": return _save_scene(args)
		"save_all": return _save_all()
		"select": return _select(args)
		"capture_editor": return _capture(args)
		"editor_state": return _state()
		"run_script": return await _run_script(args)
	return err("Unknown tool " + tool)


func _save_scene(args: Dictionary):
	var root := EditorInterface.get_edited_scene_root()
	var current := root.scene_file_path if root else ""
	var path := String(args.get("scene", current))
	if path == "":
		return err("No scene is open; godot.editor.open_scene one first." if root == null
			else "The open scene has never been saved and has no path; write it under res://mixar/ with the top-level new_scene instead.")
	if path not in Array(EditorInterface.get_open_scenes()):
		return err("%s is not open in the editor (editor_state lists the open scenes)." % path)
	var refusal: String = t._scene_refusal(path)
	if refusal != "":
		return err(refusal)
	if path != current:
		EditorInterface.open_scene_from_path(path)
	var saved := EditorInterface.save_scene() == OK
	if path != current and current != "":
		EditorInterface.open_scene_from_path(current)
	if not saved:
		return err("Saving %s failed; read the log." % path)
	return ok({"saved": path})


func _save_all():
	var unsaved: Array = Array(EditorInterface.get_unsaved_scenes())
	var refused: Array = unsaved.filter(func(p): return t._scene_refusal(String(p)) != "")
	if not refused.is_empty():
		return err("Plugin mode: %s %s not Mixar's to save. Save Mixar's scenes one by one with save_scene." % [
			", ".join(refused), "is" if refused.size() == 1 else "are"])
	EditorInterface.save_all_scenes()
	return ok({"saved": unsaved, "unsaved": Array(EditorInterface.get_unsaved_scenes())})


func _select(args: Dictionary):
	var r := edit_root(false)
	if r.has("error"):
		return err(r.error)
	var nodes: Array = []
	for p in str_array(args.get("nodes", [])):
		var node := node_at(p)
		if node == null:
			return err("No node at '%s'; the selection is unchanged." % p)
		nodes.append(node)
	var selection := EditorInterface.get_selection()
	selection.clear()
	for node in nodes:
		selection.add_node(node)
	return ok({"selected": nodes.map(func(n): return path_of(n))})


func _capture(args: Dictionary):
	if String(args.get("view", "3d")) != "2d":
		return t._capture({"source": "editor", "max_width": args.get("max_width", 1280)})
	var max_width := clampi(int(args.get("max_width", 1280)), 64, 3840)
	var viewport := EditorInterface.get_editor_viewport_2d()
	var image: Image = viewport.get_texture().get_image() if viewport else null
	if image == null or image.is_empty():
		return err("The editor viewport has no image (a headless editor draws nothing).")
	if image.get_width() > max_width:
		image.resize(max_width, maxi(1, image.get_height() * max_width / image.get_width()), Image.INTERPOLATE_BILINEAR)
	return t._image({"source": "editor_2d", "width": image.get_width(), "height": image.get_height()},
		image.save_jpg_to_buffer(0.85))


func _state():
	var root := EditorInterface.get_edited_scene_root()
	var selection: Array = []
	if root:
		for n in EditorInterface.get_selection().get_selected_nodes().slice(0, 50):
			selection.append(path_of(n))
	var refusal: String = t._scene_refusal() if root else ""
	var data := {
		"edited_scene": root.scene_file_path if root else "",
		"edited_scene_type": root.get_class() if root else "",
		"scene_editable": root != null and refusal == "",
		"open_scenes": Array(EditorInterface.get_open_scenes()),
		"unsaved_scenes": Array(EditorInterface.get_unsaved_scenes()),
		"selection": selection,
		"playing": EditorInterface.is_playing_scene(),
		"main_scene": String(ProjectSettings.get_setting("application/run/main_scene", "")),
		"last_undo": last_action(),
		"godot_version": Engine.get_version_info().string,
		"adapter_version": t.ADAPTER_VERSION,
		"project_mode": t._mode(),
	}
	if refusal != "":
		data["scene_refusal"] = refusal
	return ok(data)


func _run_script(args: Dictionary):
	if not (typeof(args.get("approved_by_user")) == TYPE_BOOL and args.approved_by_user):
		return err("run_script runs only after the user approves that run in Mixar; this call carries no approval, so nothing ran. Ordinary edits need no script: use the godot.scene and godot.resources tools.")
	var source := String(args.get("source", ""))
	if source.strip_edges() == "":
		return err("source is empty; it defines func run(editor: EditorInterface).")
	# Code instanced in the editor runs only from a @tool script.
	var offset := 0
	if RegEx.create_from_string(TOOL_ANNOTATION).search(source) == null:
		source = "@tool\n" + source
		offset = 1
	var mark: int = t.log_buffer.latest()
	var script := GDScript.new()
	script.source_code = source
	if script.reload() != OK:
		var errors: Array = _lines_since(mark, offset).errors
		return err("The script does not compile; nothing ran.\n" + "\n".join(errors), {"errors": errors})
	var arg_count := -1
	for m in script.get_script_method_list():
		if m.name == "run":
			arg_count = m.args.size()
	if arg_count < 0:
		return err("The script has no func run(editor: EditorInterface); nothing ran.")
	if not ClassDB.is_parent_class(script.get_instance_base_type(), "RefCounted") \
			and not ClassDB.is_parent_class(script.get_instance_base_type(), "Node") and script.get_instance_base_type() != "Object":
		return err("The script extends %s; extend RefCounted (or leave extends out)." % script.get_instance_base_type())
	var instance = script.new()
	mark = t.log_buffer.latest()
	var result
	if arg_count > 0:
		result = await instance.run(EditorInterface)
	else:
		result = await instance.run()
	var logged := _lines_since(mark, offset)
	var root := EditorInterface.get_edited_scene_root()
	var data := {"result": Values.to_json(result, root), "output": logged.output, "errors": logged.errors, "undoable": false}
	if instance is Node:
		if not instance.is_inside_tree():
			instance.free()
	elif instance is Object and not instance is RefCounted:
		instance.free()
	return ok(data)


## Printed lines and errors logged by the editor after `mark`; script error
## lines shifted back by `offset` (the @tool line run_script may add).
func _lines_since(mark: int, offset: int) -> Dictionary:
	var output: Array = []
	var errors: Array = []
	for line in t.log_buffer.since(mark, MAX_OUTPUT, false).lines:
		if line.source != "editor":
			continue
		if line.level == "info":
			output.append(line.text)
			continue
		var where := ""
		if String(line.file) != "":
			var n: int = line.line - offset if String(line.file).begins_with("gdscript://") else line.line
			where = ("line %d: " % n) if String(line.file).begins_with("gdscript://") else "%s:%d: " % [line.file, n]
		errors.append(where + String(line.text))
	return {"output": output, "errors": errors}
