@tool
extends RefCounted
## The shape every editor toolset shares. A toolset overrides toolset_id(),
## toolset_description(), tool_specs() and run(); `t` is the add-on's tools.gd
## (its guards, results and editor helpers), set by the registry.

const Values := preload("res://addons/mixar_link/toolsets/values.gd")
const MAX_LIST := 200

var t: RefCounted


func toolset_id() -> String:
	return ""


func toolset_description() -> String:
	return ""


func tool_specs() -> Array:
	return []


## A CallToolResult (may be a coroutine).
func run(_tool: String, _args: Dictionary):
	return err("Not implemented.")


func spec(name: String, description: String, props: Dictionary, required: Array = []) -> Dictionary:
	var schema := {"type": "object", "properties": props}
	if not required.is_empty():
		schema["required"] = required
	return {"name": name, "description": description, "inputSchema": schema}


func ok(data: Dictionary) -> Dictionary:
	return t._ok(data)


func err(message: String, data := {}) -> Dictionary:
	return t._err(message, data)


## The open scene's root, or "" in `why` (an error message) when edits are not
## allowed: no scene, or a plugin-mode scene Mixar may not edit.
func edit_root(for_write := true) -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return {"error": "No scene is open; godot.editor.open_scene one first."}
	if for_write and t._scene_refusal() != "":
		return {"error": t._scene_refusal()}
	return {"root": root}


## A node of the open scene by path relative to its root ("." is the root).
func node_at(path) -> Node:
	return t._scene_node(String(path))


func path_of(node: Node) -> String:
	var root := EditorInterface.get_edited_scene_root()
	return String(root.get_path_to(node)) if root and (node == root or root.is_ancestor_of(node)) else ""


## The editor's undo history action name for the open scene, after a commit.
func last_action() -> String:
	var undo: EditorUndoRedoManager = t.plugin.get_undo_redo()
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return ""
	return undo.get_history_undo_redo(undo.get_object_history_id(root)).get_current_action_name()


## A plain node name Godot accepts.
static func valid_node_name(name: String) -> bool:
	if name == "" or name.length() > 96:
		return false
	for ch in [".", ":", "@", "/", "\"", "%"]:
		if name.contains(ch):
			return false
	return true


static func str_array(value) -> Array:
	if typeof(value) == TYPE_ARRAY:
		return value.map(func(x): return String(x) if typeof(x) == TYPE_STRING else str(x))
	if typeof(value) == TYPE_STRING or typeof(value) == TYPE_STRING_NAME:
		return [String(value)]
	return []
