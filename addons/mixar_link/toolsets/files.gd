@tool
extends "res://addons/mixar_link/toolsets/base.gd"
## godot.files: project text files. Reading and listing anywhere in res://
## (the .godot cache skipped); writing, moving and deleting only under
## res://mixar/, with the add-on's checks (.gd must compile, .tscn/.tres must
## load) before anything is written.

const MAX_LINES := 2000
## Editor-time code runs only through godot.editor.run_script, which the user
## approves each time; a written @tool script would run unasked.
const TOOL_ANNOTATION := "(?m)^\\s*@tool\\b"


func toolset_id() -> String:
	return "godot.files"


func toolset_description() -> String:
	return "Project files: read and list anywhere in res:// (not the .godot cache); write, move and delete text files only under res://mixar/. A .gd must compile, a .tscn/.tres must load, a .json must parse, or nothing is written."


func tool_specs() -> Array:
	return [
		spec("read_file", "A text file's content (up to 200 KB), optionally a line range.",
			{"path": {"type": "string"}, "start_line": {"type": "integer", "description": "1-based"},
			 "max_lines": {"type": "integer"}}, ["path"]),
		spec("list_files", "Files under dir (default res://mixar, recursive) with byte sizes for text files; pattern filters names (e.g. *.tscn).",
			{"dir": {"type": "string"}, "pattern": {"type": "string"}, "max_files": {"type": "integer"}}),
		spec("write_file", "Write a text file (.gd .tscn .tres .gdshader .json .txt .md .cfg .csv) under res://mixar/, checked first; a file that fails is not written and the errors come back. @tool scripts are refused (editor-time code goes through godot.editor.run_script). An open scene rewritten here is reloaded.",
			{"path": {"type": "string"}, "content": {"type": "string"}}, ["path", "content"]),
		spec("move_file", "Move or rename a file under res://mixar/ to another path under res://mixar/ (its .import and .uid sidecars move with it; references by uid keep working).",
			{"from": {"type": "string"}, "to": {"type": "string"}, "overwrite": {"type": "boolean"}}, ["from", "to"]),
		spec("delete_file", "Delete a file under res://mixar/ (and its .import / .uid sidecars). Not undoable.",
			{"path": {"type": "string"}}, ["path"]),
		spec("rescan", "Rescan the project's files so the editor sees files changed outside it, and wait for the scan.", {}),
	]


func run(tool: String, args: Dictionary):
	match tool:
		"read_file": return _read_file(args)
		"list_files": return _list_files(args)
		"write_file": return _write_file(args)
		"move_file": return _move_file(args)
		"delete_file": return _delete_file(args)
		"rescan": return await _rescan()
	return err("Unknown tool " + tool)


func _read_file(args: Dictionary):
	var result: Dictionary = t._read_file(args)
	if result.isError or not (args.has("start_line") or args.has("max_lines")):
		return result
	var lines: PackedStringArray = String(result.structuredContent.content).split("\n")
	var start := clampi(int(args.get("start_line", 1)), 1, maxi(1, lines.size()))
	var count := clampi(int(args.get("max_lines", MAX_LINES)), 1, MAX_LINES)
	var part := lines.slice(start - 1, start - 1 + count)
	return ok({"path": result.structuredContent.path, "content": "\n".join(part), "start_line": start,
		"lines": part.size(), "total_lines": lines.size(), "truncated": start - 1 + part.size() < lines.size()})


func _list_files(args: Dictionary):
	var result: Dictionary = t._list_files(args)
	var pattern := String(args.get("pattern", ""))
	if result.isError or pattern == "":
		return result
	var data: Dictionary = result.structuredContent
	data.files = data.files.filter(func(f): return String(f.path).get_file().matchn(pattern))
	return ok(data)


func _write_file(args: Dictionary):
	var path := String(args.get("path", ""))
	var content := String(args.get("content", ""))
	var ext := path.get_extension().to_lower()
	if (ext == "gd" and RegEx.create_from_string(TOOL_ANNOTATION).search(content) != null) \
			or (ext in ["tscn", "tres"] and content.contains("@tool")):
		return err("@tool scripts run inside the editor, so they are not written here; editor-time code goes through godot.editor.run_script (the user approves each run). Remove @tool and write it again.")
	var root := EditorInterface.get_edited_scene_root()
	if ext == "tscn" and root and root.scene_file_path == path and t._scene_refusal() != "":
		return err(t._scene_refusal())
	return t._write_file(args, t.MIXAR_DIR)


## Why `path` is not a file Mixar may move or delete, else "".
func _mixar_path(path: String) -> String:
	if not path.begins_with(t.MIXAR_DIR + "/") or path.contains("..") or path.substr(6).contains("//"):
		return "Mixar moves and deletes files only under %s/; %s is outside it." % [t.MIXAR_DIR, path]
	return ""


func _open_scene_paths() -> Array:
	return Array(EditorInterface.get_open_scenes())


func _move_file(args: Dictionary):
	var from := String(args.get("from", ""))
	var to := String(args.get("to", ""))
	for p in [from, to]:
		if _mixar_path(p) != "":
			return err(_mixar_path(p))
	if to.get_extension().to_lower() != from.get_extension().to_lower():
		return err("A move keeps the file's extension (.%s)." % from.get_extension())
	if not FileAccess.file_exists(from):
		return err("No such file: " + from)
	if from in _open_scene_paths() or to in _open_scene_paths():
		return err("%s is open in the editor; close it before moving it." % (from if from in _open_scene_paths() else to))
	if FileAccess.file_exists(to) and not bool(args.get("overwrite", false)):
		return err("%s exists; pass overwrite=true to replace it." % to)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(to.get_base_dir()))
	var moved: Array = []
	for suffix in ["", ".import", ".uid"]:
		if suffix != "" and not FileAccess.file_exists(from + suffix):
			continue
		if DirAccess.rename_absolute(ProjectSettings.globalize_path(from + suffix), ProjectSettings.globalize_path(to + suffix)) != OK:
			return err("Could not move %s to %s." % [from + suffix, to + suffix], {"moved": moved})
		moved.append(to + suffix)
	# An .import sidecar names its source file; the scan re-imports at the new path.
	var fs := EditorInterface.get_resource_filesystem()
	fs.scan()
	return ok({"from": from, "to": to, "moved": moved,
		"note": "Files that reference the old path (not by uid) still name it; read_file and fix them if needed."})


func _delete_file(args: Dictionary):
	var path := String(args.get("path", ""))
	if _mixar_path(path) != "":
		return err(_mixar_path(path).replace("moves and deletes", "deletes"))
	if path in _open_scene_paths():
		return err("%s is open in the editor; close it before deleting it." % path)
	var result: Dictionary = t._delete_file(args)
	if result.isError:
		return result
	var sidecars: Array = []
	for suffix in [".import", ".uid"]:
		if FileAccess.file_exists(path + suffix) and DirAccess.remove_absolute(ProjectSettings.globalize_path(path + suffix)) == OK:
			sidecars.append(path + suffix)
	return ok({"deleted": path, "sidecars": sidecars, "undoable": false})


func _rescan():
	var fs := EditorInterface.get_resource_filesystem()
	var tree: SceneTree = t.plugin.get_tree()
	var t0 := Time.get_ticks_msec()
	fs.scan()
	await tree.process_frame
	while fs.is_scanning() and Time.get_ticks_msec() - t0 < 60000:
		await tree.process_frame
	return ok({"scanning": fs.is_scanning(), "seconds": snappedf((Time.get_ticks_msec() - t0) / 1000.0, 0.1)})
