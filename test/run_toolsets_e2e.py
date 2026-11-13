#!/usr/bin/env python3
"""End-to-end test of the editor toolsets (list_toolsets, describe_toolset,
call_tool and every tool of godot.classes / .scene / .resources / .files /
.editor) against a real, headless Godot editor on a throwaway project, plus a
plugin-mode project.

    python3 test/run_toolsets_e2e.py --godot /path/to/Godot

Exit code 0 = every check passed. Reuses run_e2e.py's client and helpers; the
editor runs with HOME pointed into a temp folder.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run_e2e as e2e  # noqa: E402
from run_e2e import check  # noqa: E402

TOOLSETS = ["godot.classes", "godot.scene", "godot.resources", "godot.files", "godot.editor"]
PROP_SCENE = ('[gd_scene format=3]\n\n[node name="Prop" type="Node3D"]\n\n'
              '[node name="Part" type="Node3D" parent="."]\n')
RECEIVER = "extends Node\nvar pings := 0\nfunc on_ping() -> void:\n\tpings += 1\n"
UNDO = ("func run(editor):\n"
        "\tvar ur = editor.get_editor_undo_redo()\n"
        "\tvar root = editor.get_edited_scene_root()\n"
        "\treturn ur.get_history_undo_redo(ur.get_object_history_id(root)).undo()\n")


class Toolsets:
    def __init__(self, client: e2e.Client):
        self.client = client

    def call(self, toolset: str, tool: str, args: dict | None = None, timeout: float = 120.0) -> dict:
        return self.client.call("call_tool", {"toolset_name": toolset, "tool_name": tool, "arguments": args or {}},
                                timeout)

    def data(self, toolset: str, tool: str, args: dict | None = None) -> dict:
        """The tool's JSON result (the text block), or {"$error": text}."""
        r = self.call(toolset, tool, args)
        text = r["content"][0]["text"]
        return {"$error": text} if r["isError"] else json.loads(text)

    def scene(self, tool, args=None):
        return self.data("godot.scene", tool, args)

    def undo(self) -> bool:
        r = self.data("godot.editor", "run_script", {"source": UNDO, "approved_by_user": True})
        return r.get("result") is True


def err_text(r: dict) -> str:
    return r.get("$error", "")


def paths(ts: Toolsets, **kw) -> list[str]:
    return [n["path"] for n in ts.scene("get_nodes", dict(kw)).get("nodes", [])]


def write_project(project: str, plugin_mode: bool = False) -> None:
    os.makedirs(project)
    shutil.copytree(os.path.join(e2e.ROOT, "addons"), os.path.join(project, "addons"))
    cfg = e2e.PROJECT_GODOT.replace('[autoload]\n\nTestPrinter="*res://test_printer.gd"\n', "")
    if plugin_mode:
        cfg += '\n[mixar_link]\n\nproject_mode="plugin"\n'
        with open(os.path.join(project, "studio_level.tscn"), "w") as fh:
            fh.write('[gd_scene format=3]\n\n[node name="Root" type="Node3D"]\n\n[node name="Hero" type="Node3D" parent="."]\n')
    with open(os.path.join(project, "project.godot"), "w") as fh:
        fh.write(cfg)


def discovery_checks(c: e2e.Client, ts: Toolsets) -> None:
    _, _, listed = c.rpc("tools/list")
    names = {t["name"] for t in listed["result"]["tools"]}
    check({"list_toolsets", "describe_toolset", "call_tool"} <= names, "tools/list has the three toolset tools")
    check({"status", "place", "set_property", "write_file", "build_info"} <= names, "the existing top-level tools stay")
    st = c.call("status")["structuredContent"]
    check(st.get("toolsets") is True and st.get("adapter_version") == "0.5.0", "status says toolsets: true, 0.5.0", st)
    r = c.call("list_toolsets")
    sets = json.loads(r["content"][0]["text"])["toolsets"]
    check(not r["isError"] and [s["name"] for s in sets] == TOOLSETS and all(s["tools"] > 0 for s in sets),
          "list_toolsets names the five toolsets with tool counts", sets)
    for s in sets:
        r = c.call("describe_toolset", {"toolset_name": s["name"]})
        d = json.loads(r["content"][0]["text"])
        ok = (d["name"] == s["name"] and d["version"] == "0.5.0" and len(d["tools"]) == s["tools"]
              and all(t["description"] and t["inputSchema"]["type"] == "object" and "." not in t["name"]
                      for t in d["tools"]))
        check(ok, f"describe_toolset {s['name']} ({len(d['tools'])} tools, short names, schemas)")
    r = c.call("describe_toolset", {"toolset_name": "godot.nope"})
    check(r["isError"] and "godot.scene" in r["content"][0]["text"], "an unknown toolset lists the valid names", r)
    r = ts.call("godot.scene", "nope")
    check(r["isError"] and "get_nodes" in r["content"][0]["text"], "an unknown tool lists the toolset's tools", r)
    r = c.call("call_tool", {"toolset_name": "", "tool_name": "godot.classes.class_info",
                             "arguments": {"class_name": "Node3D"}})
    check(not r["isError"] and json.loads(r["content"][0]["text"])["class_name"] == "Node3D",
          "a full tool name with an empty toolset_name is accepted", r)
    r = ts.call("godot.scene", "set_properties", {})
    check(r["isError"] and "edits" in r["content"][0]["text"], "a missing required argument is named", r)


def classes_checks(ts: Toolsets) -> None:
    d = ts.data("godot.classes", "class_info", {"class_name": "MeshInstance3D"})
    props = {p["name"]: p for p in d.get("properties", [])}
    check("Node3D" in d.get("parents", []) and props.get("mesh", {}).get("type") == "Mesh"
          and "skeleton" in props, "class_info: parents and typed properties", list(props)[:8])
    methods = {m["name"]: m for m in d.get("methods", [])}
    check("create_trimesh_collision" in methods and "position" not in props, "class_info: own methods, no inherited props")
    d = ts.data("godot.classes", "class_info", {"class_name": "Node3D", "sections": ["signals", "enums", "methods"],
                                                "filter": "look"})
    look = {m["name"]: m for m in d.get("methods", [])}.get("look_at", {})
    check(look and look["args"][0]["type"] == "Vector3" and "default" in look["args"][1],
          "class_info: method args with types and defaults", look)
    d = ts.data("godot.classes", "class_info", {"class_name": "Node3D", "sections": ["signals", "enums"]})
    check(any(s["name"] == "visibility_changed" for s in d.get("signals", [])) and "RotationEditMode" in d.get("enums", {}),
          "class_info: signals and enums", d)
    d = ts.data("godot.classes", "class_info", {"class_name": "MeshInstance3D", "inherited": True, "filter": "position",
                                                "sections": ["properties"]})
    check(any(p["name"] == "position" for p in d.get("properties", [])), "class_info inherited=true reaches Node3D")
    d = ts.data("godot.classes", "search_classes", {"query": "material", "base": "Material"})
    names = {c["name"] for c in d.get("classes", [])}
    check({"StandardMaterial3D", "ShaderMaterial"} <= names and "MeshInstance3D" not in names,
          "search_classes with a base", sorted(names)[:10])
    check("No class" in err_text(ts.data("godot.classes", "class_info", {"class_name": "Nope3D"})),
          "class_info of an unknown class says how to search")


def resource_and_file_checks(ts: Toolsets, project: str) -> None:
    red = "res://mixar/materials/red.tres"
    d = ts.data("godot.resources", "create_resource", {"type": "StandardMaterial3D", "path": red,
                                                         "properties": {"albedo_color": [1, 0, 0], "roughness": 0.25}})
    check(d.get("path") == red and os.path.exists(os.path.join(project, "mixar", "materials", "red.tres")),
          "create_resource under res://mixar", d)
    for bad in ("res://red.tres", "res://addons/red.tres", "res://mixar/../red.tres"):
        r = ts.data("godot.resources", "create_resource", {"type": "StandardMaterial3D", "path": bad})
        check("res://mixar" in err_text(r) and not os.path.exists(os.path.join(project, "red.tres")),
              f"create_resource refuses {bad}", r)
    check("exists" in err_text(ts.data("godot.resources", "create_resource", {"type": "StandardMaterial3D", "path": red})),
          "create_resource refuses to overwrite")
    check("not a Resource" in err_text(ts.data("godot.resources", "create_resource",
                                               {"type": "Node3D", "path": "res://mixar/x.tres"})),
          "create_resource refuses a non-Resource class")
    check("write_file" in err_text(ts.data("godot.resources", "create_resource",
                                           {"type": "GDScript", "path": "res://mixar/x.tres"})),
          "create_resource refuses scripts")
    d = ts.data("godot.resources", "set_resource_properties", {"path": red, "edits": [{"property": "albedo_color",
                                                                                         "value": "#0000ff"}]})
    text = open(os.path.join(project, "mixar", "materials", "red.tres")).read()
    check(d.get("saved") and "albedo_color = Color(0, 0, 1, 1)" in text, "set_resource_properties saves the file", d)
    r = ts.data("godot.resources", "set_resource_properties", {"path": red, "edits": {"roughness": "rough"}})
    check("float" in err_text(r).lower() or "expects" in err_text(r), "a bad value is refused with the expected type", r)
    r = ts.data("godot.resources", "set_resource_properties", {"path": "res://addons/mixar_link/plugin.cfg",
                                                               "edits": {"x": 1}})
    check("res://mixar" in err_text(r), "set_resource_properties refuses outside res://mixar", r)
    d = ts.data("godot.resources", "get_resource", {"path": red})
    props = d.get("properties", {})
    check(d.get("type") == "StandardMaterial3D" and props.get("roughness") == 0.25
          and props.get("albedo_color") == {"$godot": "Color(0, 0, 1, 1)"}, "get_resource reads changed properties", d)
    d = ts.data("godot.resources", "list_resources", {"type": "Material", "dir": "res://mixar"})
    check(any(x["path"] == red for x in d.get("resources", [])), "list_resources by type", d)

    # Files.
    f = ts.data("godot.files", "write_file", {"path": "res://mixar/notes/a.txt", "content": "one\ntwo\nthree\n"})
    check(f.get("path") == "res://mixar/notes/a.txt", "files.write_file under res://mixar", f)
    for bad in ("res://a.txt", "res://addons/mixar_link/x.gd"):
        r = ts.data("godot.files", "write_file", {"path": bad, "content": "x"})
        check("res://mixar" in err_text(r), f"files.write_file refuses {bad}", r)
    r = ts.data("godot.files", "write_file", {"path": "res://mixar/scripts/tool.gd",
                                              "content": "@tool\nextends Node\n"})
    check("run_script" in err_text(r) and not os.path.exists(os.path.join(project, "mixar", "scripts", "tool.gd")),
          "files.write_file refuses an @tool script", r)
    r = ts.data("godot.files", "write_file", {"path": "res://mixar/scripts/bad.gd", "content": "extends Node\nfunc (:\n"})
    check("compile" in err_text(r), "files.write_file returns compile errors", r)
    d = ts.data("godot.files", "read_file", {"path": "res://mixar/notes/a.txt", "start_line": 2, "max_lines": 1})
    check(d.get("content") == "two" and d.get("truncated"), "files.read_file with a line range", d)
    d = ts.data("godot.files", "read_file", {"path": "res://project.godot"})
    check("config_version" in d.get("content", ""), "files.read_file reads anywhere in res://")
    d = ts.data("godot.files", "move_file", {"from": "res://mixar/notes/a.txt", "to": "res://mixar/notes/b.txt"})
    check(os.path.exists(os.path.join(project, "mixar", "notes", "b.txt"))
          and not os.path.exists(os.path.join(project, "mixar", "notes", "a.txt")), "files.move_file", d)
    r = ts.data("godot.files", "move_file", {"from": "res://mixar/notes/b.txt", "to": "res://b.txt"})
    check("res://mixar" in err_text(r) and not os.path.exists(os.path.join(project, "b.txt")),
          "files.move_file refuses a destination outside res://mixar", r)
    r = ts.data("godot.files", "move_file", {"from": "res://project.godot", "to": "res://mixar/p.godot"})
    check("res://mixar" in err_text(r), "files.move_file refuses a source outside res://mixar", r)
    r = ts.data("godot.files", "delete_file", {"path": "res://project.godot"})
    check("res://mixar" in err_text(r) and os.path.exists(os.path.join(project, "project.godot")),
          "files.delete_file refuses outside res://mixar", r)
    d = ts.data("godot.files", "delete_file", {"path": "res://mixar/notes/b.txt"})
    check(d.get("deleted") and not os.path.exists(os.path.join(project, "mixar", "notes", "b.txt")), "files.delete_file", d)
    d = ts.data("godot.files", "list_files", {"dir": "res://mixar", "pattern": "*.tres"})
    check([x["path"] for x in d.get("files", [])] == [red], "files.list_files with a pattern", d)
    d = ts.data("godot.files", "rescan")
    check(d.get("scanning") is False, "files.rescan waits for the scan", d)
    check(not err_text(ts.data("godot.files", "write_file", {"path": "res://mixar/scenes/prop.tscn",
                                                             "content": PROP_SCENE})), "write a prop scene")
    check(not err_text(ts.data("godot.files", "write_file", {"path": "res://mixar/scripts/receiver.gd",
                                                             "content": RECEIVER})), "write a receiver script")


def scene_checks(ts: Toolsets, c: e2e.Client, project: str) -> None:
    r = c.call("new_scene", {"name": "Tools", "with_defaults": False})
    check(not r["isError"], "a level to edit (top-level new_scene)", r)
    level = os.path.join(project, "mixar", "levels", "Tools.tscn")
    red = "res://mixar/materials/red.tres"

    # A batch with one bad node adds nothing.
    r = ts.scene("add_nodes", {"nodes": [{"type": "Node3D", "name": "Ok"}, {"type": "EditorPlugin", "name": "Bad"}]})
    check("not a node type" in err_text(r) and "Ok" not in paths(ts), "add_nodes refuses EditorPlugin, adds nothing", r)
    r = ts.scene("add_nodes", {"nodes": [{"type": "NotAType", "name": "X"}]})
    check("not a node type" in err_text(r), "add_nodes refuses an unknown type")
    r = ts.scene("add_nodes", {"nodes": [{"type": "Node3D", "name": "X", "properties": {"position": "up"}}]})
    check("Vector3" in err_text(r), "add_nodes names the type a bad value needs", r)

    d = ts.scene("add_nodes", {"nodes": [
        {"type": "Node3D", "name": "Group"},
        {"parent": "Group", "type": "MeshInstance3D", "name": "Box", "properties": {
            "mesh": {"$new": "BoxMesh", "properties": {"size": [2, 1, 1]}}, "position": [1, 2, 3]}},
        {"parent": "Group", "type": "MeshInstance3D", "name": "Box2"},
        {"type": "OmniLight3D", "name": "Lamp", "properties": {"light_color": "#ff8800", "light_energy": 2}},
        {"type": "Node", "name": "Receiver", "properties": {"script": "res://mixar/scripts/receiver.gd"}},
        {"scene": "res://mixar/scenes/prop.tscn", "name": "Prop1"},
    ]})
    added = [a["path"] for a in d.get("added", [])]
    check(added == ["Group", "Group/Box", "Group/Box2", "Lamp", "Receiver", "Prop1"] and d.get("saved") is False,
          "add_nodes batch (nested parent, scene instance, script)", d)
    check("Box" not in open(level).read(), "add_nodes does not save the scene")

    d = ts.scene("set_properties", {"edits": [
        {"node": "Group/Box", "property": "position", "value": [0, 1, 0]},
        {"node": "Lamp", "property": "light_color", "value": [0.25, 0.5, 0.75]},
        {"node": "Group/Box", "property": "material_override",
         "value": {"$new": "StandardMaterial3D", "properties": {"albedo_color": [0, 1, 0, 1], "metallic": 0.5}}},
        {"node": "Group/Box2", "property": "material_override", "value": red},
        {"node": "Lamp", "property": "shadow_enabled", "value": True},
    ]})
    check(len(d.get("set", [])) == 5 and d.get("undo", "").startswith("Mixar:"), "set_properties batch, one undo step", d)
    r = ts.scene("set_properties", {"edits": [{"node": "Lamp", "property": "light_energy", "value": 9},
                                              {"node": "Lamp", "property": "nope", "value": 1}]})
    check("nope" in err_text(r) and "Nothing was changed" in err_text(r), "a bad edit in a batch changes nothing", r)
    r = ts.scene("set_properties", {"edits": [{"node": "Group/Box", "property": "material_override",
                                               "value": "res://mixar/scenes/prop.tscn"}]})
    check("does not fit" in err_text(r), "a resource of the wrong class is refused", r)

    d = ts.scene("get_properties", {"node": "Group/Box"})
    p = d.get("properties", {})
    mat = p.get("material_override", {})
    check(p.get("position") == {"$godot": "Vector3(0, 1, 0)"}, "get_properties: Vector3 round-trips", p.get("position"))
    check(mat.get("$resource") == "StandardMaterial3D" and mat.get("properties", {}).get("albedo_color")
          == {"$godot": "Color(0, 1, 0, 1)"} and mat["properties"].get("metallic") == 0.5,
          "get_properties: an embedded $new material", mat)
    check(p.get("mesh", {}).get("$resource") == "BoxMesh", "get_properties: the embedded mesh", p.get("mesh"))
    d = ts.scene("get_properties", {"node": "Lamp", "names": ["light_color", "light_energy", "shadow_enabled", "zzz"]})
    p = d.get("properties", {})
    check(p.get("light_color") == {"$godot": "Color(0.25, 0.5, 0.75, 1)"} and p.get("light_energy") == 2
          and p.get("shadow_enabled") is True and d.get("unknown") == ["zzz"], "get_properties by name: Color", d)
    d = ts.scene("get_properties", {"node": "Group/Box2", "names": ["material_override"]})
    check(d.get("properties", {}).get("material_override") == red, "get_properties: a res:// resource", d)
    # A value read back is written back unchanged ($godot round-trip).
    ts.scene("set_properties", {"edits": [{"node": "Lamp", "property": "light_color",
                                          "value": {"$godot": "Color(0.25, 0.5, 0.75, 1)"}},
                                         {"node": "Lamp", "property": "omni_shadow_mode", "value": "Cube"}]})
    d = ts.scene("get_properties", {"node": "Lamp", "names": ["light_color", "omni_shadow_mode"]})
    check(d.get("properties", {}).get("light_color") == {"$godot": "Color(0.25, 0.5, 0.75, 1)"}
          and d["properties"].get("omni_shadow_mode") == 1, "$godot literals and enum names are accepted", d)
    r = ts.scene("set_properties", {"edits": [{"node": "Lamp", "property": "light_color",
                                               "value": {"$godot": "Object(Node, \"name\": \"x\")"}}]})
    check("Object" in err_text(r), "Object(...) literals are refused", r)

    d = ts.scene("get_nodes", {"filter_type": "MeshInstance3D", "properties": ["position"]})
    check([n["path"] for n in d.get("nodes", [])] == ["Group/Box", "Group/Box2"]
          and d["nodes"][0]["properties"]["position"] == {"$godot": "Vector3(0, 1, 0)"}, "get_nodes filter + properties", d)
    d = ts.scene("get_nodes", {"depth": 1})
    check("Group/Box" not in [n["path"] for n in d.get("nodes", [])] and any(
        n["path"] == "Prop1" and n.get("instance_of") == "res://mixar/scenes/prop.tscn" for n in d.get("nodes", [])),
          "get_nodes depth and instance_of", d)
    d = ts.scene("get_nodes", {"max_nodes": 2})
    check(d.get("truncated") is True and len(d.get("nodes", [])) == 2, "get_nodes caps and says truncated", d)

    d = ts.scene("call_method", {"node": "Group/Box", "method": "to_global", "args": [[1, 0, 0]]})
    check(d.get("result") == {"$godot": "Vector3(1, 1, 0)"} and d.get("undoable") is False,
          "call_method coerces args and returns a Godot value", d)
    d = ts.scene("call_method", {"node": "Lamp", "method": "get_class"})
    check(d.get("result") == "OmniLight3D", "call_method with no args", d)
    check("remove_nodes" in err_text(ts.scene("call_method", {"node": "Lamp", "method": "queue_free"})),
          "call_method refuses queue_free and names remove_nodes")
    check("arguments" in err_text(ts.scene("call_method", {"node": "Lamp", "method": "to_global"})),
          "call_method checks the argument count")

    # Reparent, with undo.
    d = ts.scene("reparent", {"node": "Lamp", "parent": "Group"})
    check(d.get("node") == "Group/Lamp" and "Group/Lamp" in paths(ts), "reparent", d)
    check(ts.undo() and "Lamp" in paths(ts) and "Group/Lamp" not in paths(ts), "reparent undoes")
    check("itself" in err_text(ts.scene("reparent", {"node": "Group", "parent": "Group/Box"})),
          "reparent refuses a move under its own child")
    # Duplicate, with undo; the copy's children are saved with the scene.
    d = ts.scene("duplicate", {"node": "Group", "name": "Group2"})
    check(d.get("node") == "Group2" and {"Group2/Box", "Group2/Box2"} <= set(paths(ts)),
          "duplicate copies the subtree (owned, listed)", d)
    check(ts.undo() and "Group2" not in paths(ts), "duplicate undoes")
    # Remove nodes, then undo: back in place, children owned.
    before = paths(ts)
    d = ts.scene("remove_nodes", {"nodes": ["Group/Box2", "Group", "Lamp"]})
    check(set(d.get("removed", [])) == {"Group", "Lamp"} and "Group" not in paths(ts), "remove_nodes batch", d)
    check(ts.undo() and paths(ts) == before, "remove_nodes undoes (order and owners kept)", (before, paths(ts)))
    check("root" in err_text(ts.scene("remove_nodes", {"nodes": ["."]})), "remove_nodes refuses the root")
    check("instanced" in err_text(ts.scene("remove_nodes", {"nodes": ["Prop1/Part"]})),
          "remove_nodes refuses a node inside an instance")

    # Signals.
    r = ts.scene("connect_signal", {"node": "Lamp", "signal": "visibility_changed", "target": "Receiver", "method": "nope"})
    check("no method" in err_text(r), "connect_signal needs an existing method", r)
    d = ts.scene("connect_signal", {"node": "Lamp", "signal": "visibility_changed", "target": "Receiver",
                                    "method": "on_ping"})
    check(d.get("connected") is True, "connect_signal", d)
    conns = ts.scene("get_properties", {"node": "Lamp", "names": []}).get("connections", [])
    check({"signal": "visibility_changed", "target": "Receiver", "method": "on_ping"} in conns,
          "get_properties lists the connection", conns)
    d = ts.scene("disconnect_signal", {"node": "Lamp", "signal": "visibility_changed", "target": "Receiver",
                                       "method": "on_ping"})
    check("disconnected" in d, "disconnect_signal", d)
    ts.scene("connect_signal", {"node": "Lamp", "signal": "visibility_changed", "target": "Receiver", "method": "on_ping"})
    d = ts.scene("edit_instance", {"node": "Prop1"})
    check(d.get("editable_children") is True and "Prop1/Part" in paths(ts), "edit_instance", d)
    check("not an instanced" in err_text(ts.scene("edit_instance", {"node": "Lamp"})), "edit_instance needs an instance")

    # Saving is explicit.
    check("Lamp" not in open(level).read(), "nothing is saved before save_scene")
    d = ts.data("godot.editor", "save_scene")
    saved = open(level).read()
    check(d.get("saved") == "res://mixar/levels/Tools.tscn" and "Lamp" in saved and "on_ping" in saved
          and "StandardMaterial3D" in saved and red in saved and 'editable path="Prop1"' in saved,
          "save_scene writes the edits, connection, materials and editable instance", d)


def editor_checks(ts: Toolsets, c: e2e.Client) -> None:
    d = ts.data("godot.editor", "select", {"nodes": ["Lamp", "Group/Box"]})
    check(d.get("selected") == ["Lamp", "Group/Box"], "select", d)
    d = ts.data("godot.editor", "editor_state")
    check(d.get("edited_scene") == "res://mixar/levels/Tools.tscn" and d.get("scene_editable") is True
          and set(d.get("selection", [])) == {"Lamp", "Group/Box"} and d.get("adapter_version") == "0.5.0",
          "editor_state", d)
    for view in ("3d", "2d"):
        r = ts.call("godot.editor", "capture_editor", {"view": view, "max_width": 320})
        img = next((x for x in r.get("content", []) if x.get("type") == "image"), None)
        check((r["isError"] and "headless" in r["content"][0]["text"]) or (img and img["mimeType"] == "image/jpeg"),
              f"capture_editor {view} (an image, or headless says why)", r["content"][0]["text"][:200])
    ts.scene("set_properties", {"edits": [{"node": "Lamp", "property": "light_energy", "value": 3}]})
    d = ts.data("godot.editor", "save_all")
    check("res://mixar/levels/Tools.tscn" in d.get("saved", []) and not d.get("unsaved"), "save_all", d)
    ts.data("godot.editor", "open_scene", {"scene": "res://mixar/scenes/prop.tscn"})
    check(ts.data("godot.editor", "editor_state").get("edited_scene") == "res://mixar/scenes/prop.tscn",
          "open_scene switches the edited scene")
    ts.data("godot.editor", "open_scene", {"scene": "res://mixar/levels/Tools.tscn"})

    # run_script: approval, compile errors, output.
    src = 'func run(editor):\n\tprint("MIXAR_RUN_MARK")\n\treturn {"root": editor.get_edited_scene_root().name}\n'
    seq = c.call("status")["structuredContent"]["log_seq"]
    r = ts.data("godot.editor", "run_script", {"source": src})
    check("approv" in err_text(r), "run_script without approval is refused", r)
    r = ts.data("godot.editor", "run_script", {"source": src, "approved_by_user": "true"})
    check("approv" in err_text(r), "run_script needs approved_by_user to be the boolean true", r)
    lines = c.call("log", {"since": seq, "max_lines": 1000})["structuredContent"]["lines"]
    check(not any("MIXAR_RUN_MARK" in l["text"] for l in lines), "a refused script does not run")
    r = ts.data("godot.editor", "run_script", {"source": 'func run(editor):\n\tprint("NEVER")\n\tvar x := \n',
                                               "approved_by_user": True})
    check("does not compile" in err_text(r) and "line 3" in err_text(r), "run_script returns compile errors (line numbers)", r)
    lines = c.call("log", {"since": seq, "max_lines": 1000})["structuredContent"]["lines"]
    check(not any(l["text"] == "NEVER" for l in lines), "a script that does not compile does not run")
    d = ts.data("godot.editor", "run_script", {"source": src, "approved_by_user": True})
    check(d.get("result") == {"root": "Tools"} and "MIXAR_RUN_MARK" in d.get("output", []) and d.get("errors") == [],
          "an approved run_script returns its result and printed output", d)
    d = ts.data("godot.editor", "run_script", {"source": "func run(editor):\n\tpush_error(\"MIXAR_OOPS\")\n\treturn 7\n",
                                               "approved_by_user": True})
    check(d.get("result") == 7 and any("MIXAR_OOPS" in e for e in d.get("errors", [])), "run_script reports errors", d)
    check("func run" in err_text(ts.data("godot.editor", "run_script", {"source": "var x = 1\n",
                                                                        "approved_by_user": True})),
          "run_script needs func run")


def plugin_mode_checks(godot: str, tmp: str) -> None:
    home = os.path.join(tmp, "home-plugin")
    project = os.path.join(tmp, "studio")
    os.makedirs(home)
    write_project(project, plugin_mode=True)
    proc, client, log = e2e.launch(godot, project, home, os.path.join(tmp, "godot-plugin.log"))
    try:
        check(client is not None, "plugin-mode editor connects")
        if client is None:
            return
        ts = Toolsets(client)
        before = open(os.path.join(project, "studio_level.tscn")).read()
        ts.data("godot.editor", "open_scene", {"scene": "res://studio_level.tscn"})
        check("Hero" in paths(ts), "plugin mode still reads the studio's scene")
        for tool, args in (("set_properties", {"edits": [{"node": "Hero", "property": "visible", "value": False}]}),
                           ("add_nodes", {"nodes": [{"type": "Node3D", "name": "X"}]}),
                           ("remove_nodes", {"nodes": ["Hero"]}),
                           ("call_method", {"node": "Hero", "method": "hide"})):
            check("plugin mode" in err_text(ts.scene(tool, args)), f"plugin mode refuses scene.{tool} on the studio's scene")
        r = ts.data("godot.editor", "save_scene")
        check("plugin mode" in err_text(r), "plugin mode refuses save_scene on the studio's scene", r)
        state = ts.data("godot.editor", "editor_state")
        check(state.get("scene_editable") is False and "scene_refusal" in state,
              "editor_state says the scene is not editable", state)
        check(open(os.path.join(project, "studio_level.tscn")).read() == before, "the studio's scene is untouched")
        r = ts.data("godot.resources", "create_resource", {"type": "BoxMesh", "path": "res://mixar/box.tres"})
        check(r.get("path") == "res://mixar/box.tres", "plugin mode still creates resources under res://mixar", r)
        r = ts.data("godot.files", "write_file", {"path": "res://studio.txt", "content": "x"})
        check("res://mixar" in err_text(r) and not os.path.exists(os.path.join(project, "studio.txt")),
              "plugin mode refuses files outside res://mixar")
        client.call("new_scene", {"name": "Mine", "with_defaults": False})
        d = ts.scene("add_nodes", {"nodes": [{"type": "Node3D", "name": "Ok"}]})
        check(d.get("added", [{}])[0].get("path") == "Ok", "plugin mode edits a level of Mixar's own", d)
        check(ts.data("godot.editor", "save_scene").get("saved") == "res://mixar/levels/Mine.tscn",
              "plugin mode saves Mixar's own level")
    finally:
        proc.terminate()
        try:
            proc.wait(10)
        except subprocess.TimeoutExpired:
            proc.kill()
        log.close()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--godot", required=True)
    ap.add_argument("--keep", action="store_true", help="leave the temp folder for inspection")
    args = ap.parse_args()
    tmp = tempfile.mkdtemp(prefix="mixar-toolsets-e2e-")
    home = os.path.join(tmp, "home")
    project = os.path.join(tmp, "project")
    os.makedirs(home)
    write_project(project)
    proc, client, log = e2e.launch(args.godot, project, home, os.path.join(tmp, "godot.log"))
    try:
        check(client is not None, "editor connects")
        if client is not None:
            ts = Toolsets(client)
            discovery_checks(client, ts)
            classes_checks(ts)
            resource_and_file_checks(ts, project)
            scene_checks(ts, client, project)
            editor_checks(ts, client)
            errors = client.call("log", {"errors_only": True, "max_lines": 1000})["structuredContent"]["lines"]
            noisy = [f"{l['file']}:{l['line']}: {l['text']}" for l in errors if "mixar_link/toolsets" in l["file"]]
            check(not noisy, "the toolsets log no script errors of their own", noisy[:5])
    finally:
        proc.terminate()
        try:
            proc.wait(10)
        except subprocess.TimeoutExpired:
            proc.kill()
        log.close()
    try:
        plugin_mode_checks(args.godot, tmp)
    finally:
        if e2e.FAILURES or args.keep:
            print(f"temp folder kept: {tmp}")
        else:
            shutil.rmtree(tmp, ignore_errors=True)
    print(f"\n{'FAILED' if e2e.FAILURES else 'OK'}: {len(e2e.FAILURES)} failure(s)")
    return 1 if e2e.FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
