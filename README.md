# Mixar Link for Godot

A Godot 4.5+ editor add-on that lets the [Mixar](https://mixar.app) agent work in
your Godot project. It imports Mixar export packages, places them in a level, runs
the game, and reads back frames and log lines. It runs a small
[MCP](https://modelcontextprotocol.io) server inside the editor, reachable only from
your own machine.

## Install

1. In the Mixar app, open the engine chip in the chat composer and press **Connect Godot**: it downloads the latest release and installs it into a project you pick. Or by hand: unzip [`mixar_link.zip`](https://github.com/Mixar-AI/mixar-engine-godot/releases/latest/download/mixar_link.zip) into your project's `addons/` folder.
2. Open **Project → Project Settings → Plugins** and enable **Mixar Link**.
3. Keep the project open in the editor. The Mixar desktop app finds it on its own.

Enabling the add-on also registers a `MixarLink` autoload, the first in the list.
In a game started from the editor it forwards log lines and answers frame requests.
In an exported build it does nothing.

## How Mixar connects

On start the add-on listens on the first free port between `127.0.0.1:9890` and
`127.0.0.1:9899`. It writes `~/.mixar/engine-link/godot-<pid>.json` (port and a
random token, readable only by you) and deletes the file when the editor closes.

Every request must have:

- `Authorization: Bearer <token>`;
- a loopback `Host`;
- no `Origin` header, so a web page cannot drive your editor.

Transport is MCP Streamable HTTP (`POST /mcp`, JSON responses, `Mcp-Session-Id`
after `initialize`).

## Tools

| Tool | Does |
| --- | --- |
| `status` | Engine, project, open scene, main scene, whether the game runs, and the package import queue (`imports`: `running`, `queued`, `recent`) |
| `import_package` | Copies a Mixar package folder into `res://mixar/<folder>/` (skipping `.blend` sources) and answers once it is imported. Imports run one at a time, in order (see below) |
| `new_scene` | Creates `res://mixar/levels/<name>.tscn` (sun, sky, camera by default), opens it, optionally sets it as the main scene |
| `open_scene` | Opens a scene |
| `place` | Instances an imported scene at a position and yaw, with undo, then saves |
| `scene_tree` | The open scene's own nodes: path, type, position |
| `save_scene` | Saves the open scene |
| `play` / `stop` | Runs the game from the editor and waits for it to connect; stops it |
| `capture` | A JPEG frame of the running game, or of the editor's 3D viewport |
| `log` | Editor and game log lines after a sequence number; `errors_only` filters |
| `playtest` | Scripted steps in the running game (`hold`/`press` an input action, `wait`, `walk_to` a point, `prove_loop`, `inspect` a node's live properties, `state`) with the game state after each. `walk_to` follows a navigation mesh baked from the level's colliders at that moment (`no_path` when nothing connects); `prove_loop` visits every pickup nearest-first, then the goal, and reports `won` and what it could not reach |
| `write_script` | Writes a GDScript under `res://mixar/scripts/`, compiled first (a script that fails is not written) |
| `add_node` / `set_property` | Adds a built-in node (optionally scripted) / sets a property, with undo, then saves |
| `build_web` | Exports a no-threads web build into `res://mixar_build/web/` (needs Godot's export templates) |
| `read_file` / `list_files` | Any project text file (not the `.godot` cache) / a folder's files |
| `write_file` / `delete_file` | Text files under `res://mixar/`, checked first: `.gd` must compile, `.tscn`/`.tres` must load with every node type known, `.json` must parse. A file that fails is not written and the errors come back |
| `remove_node` | Removes a node from the open scene (undo) |
| `project_setting` | Reads any setting; in owned projects sets input actions (`{keys, mouse}`), autoloads, the main scene, window, physics, environment defaults and layer names |
| `build_info` | The last web build's files and folder, for the Mixar desktop to upload a share |
| `list_toolsets` / `describe_toolset` / `call_tool` | The editor toolsets below (same shape as Epic's Unreal server): list them, get one's tools with JSON input schemas, run one |

## Package imports

Mixar runs several agents at once, and they can send packages at the same moment
(even the same package into the same folder). The editor imports them one at a
time, in the order they arrive:

1. The call is checked (folder name, manifest), then queued.
2. The package is copied into `.godot/mixar_link/staging/`, which the editor never scans.
3. When its turn comes and the editor has been idle for a few frames (not scanning, not
   importing, and not in the frames `reimport_files()` runs after it clears
   `is_importing()`), every file
   is renamed into `res://mixar/<folder>/` in one frame, textures first and the main
   file last, so the importer never reads a half-written file.
4. One scan imports the package. Its single `reimport_files()` runs in importer order,
   so textures are imported before the scene that uses them. If the editor's own
   reimport skipped files, the link reimports what is left in one `reimport_files()`
   call, while the editor is idle.
5. The call answers when the main file and every texture are imported. A rig's
   retarget reimport runs only while the editor is idle.

The answer carries `import_id`, `jobs_ahead`, `queued_seconds`, `started_ms` and
`finished_ms`. The 120 s import timeout counts from when the import starts, not
from when it was queued. A caller that stops waiting can still follow its import
in `status.imports`.

## Editor toolsets

Reach into the whole editor through Godot's own reflection (ClassDB,
EditorInterface, EditorUndoRedoManager). `call_tool` takes `toolset_name`,
`tool_name` (or the full `godot.scene.set_properties` with an empty
`toolset_name`) and `arguments`. Units and axes are Godot's own (Y up, metres);
node paths are relative to the edited scene's root (`.` is the root).

| Toolset | Tools |
| --- | --- |
| `godot.classes` | `class_info(class_name, sections?, inherited?, filter?)` (parent chain, properties with types/hints/defaults, methods with typed args, signals, constants, enums; engine classes and the project's `class_name` scripts), `search_classes(query, base?, max_results?)` |
| `godot.scene` | On the open scene, each call one undo step, never saved: `get_nodes(root?, depth?, filter_type?, properties?, max_nodes?)`, `get_properties(node, names?)`, `set_properties(edits: [{node, property, value}])`, `call_method(node, method, args?)` (not undoable), `add_nodes(nodes: [{parent?, type \| scene, name, properties?}])`, `remove_nodes(nodes)`, `reparent(node, parent, keep_global_transform?, index?)`, `duplicate(node, name?, parent?)`, `connect_signal(node, signal, target, method, binds?, deferred?, one_shot?)`, `disconnect_signal(node, signal, target, method)`, `edit_instance(node, editable?)` |
| `godot.resources` | `create_resource(type, path, properties?, overwrite?)` (a `.tres` under `res://mixar/`), `get_resource(path, properties?)`, `set_resource_properties(path, edits)` (under `res://mixar/`; saves the file), `list_resources(type?, dir?, max_results?)` |
| `godot.files` | `read_file(path, start_line?, max_lines?)`, `list_files(dir?, pattern?, max_files?)` anywhere in `res://`; `write_file(path, content)`, `move_file(from, to, overwrite?)`, `delete_file(path)` under `res://mixar/` only (checked as `write_file` is; `@tool` scripts refused); `rescan()` |
| `godot.editor` | `open_scene(scene)`, `save_scene(scene?)`, `save_all()`, `select(nodes)`, `capture_editor(view?, max_width?)`, `editor_state()`, `run_script(source)` |

Values in are plain JSON coerced to the property's type (`[x, y, z]` vectors,
`[r, g, b, a]` or `"#rrggbb"` colours, `[[x], [y], [z], [origin]]` transforms,
enum names), `"res://..."` for a resource, `{"$new": "StandardMaterial3D",
"properties": {...}}` for a new embedded resource, or `{"$godot": "<var_to_str
literal>"}` for anything else. Values out are JSON where JSON can say it,
`{"$godot": ...}` otherwise; resources come back as their path, or
`{"$resource": class, "properties"}` when embedded; long lists say `truncated`.

Batch tools are all or nothing: one bad edit and none apply, with an error
naming what to do instead. `run_script` runs a GDScript `func run(editor:
EditorInterface)` once in the editor: it is compiled first (errors come back and
nothing runs), its printed lines and errors come back with its result, and it
is not undoable. It runs only when the call carries `approved_by_user: true`,
which the Mixar backend sets after the user approves that run. The plugin-mode
rules below hold for every toolset.

`new_scene` takes a `template` that wraps the level in a game: a player, a game
manager, a HUD and the input map. Space jumps in all three:

| Template | Player |
| --- | --- |
| `third_person` | WASD / arrows relative to the camera; Q / E turn it |
| `top_down` | A camera high above; WASD / arrows move north/south/west/east |
| `platformer` | A side view (from Blender -Y): A / D run along Blender X, the player keeps its lane |

## Studio projects (plugin mode)

In an existing project, set this in `project.godot` (Project Settings, advanced):

```ini
[mixar_link]
project_mode="plugin"
editable_scenes=PackedStringArray("res://levels/shared.tscn")
```

In plugin mode Mixar keeps to `res://mixar/`. It never changes project settings
(main scene, input map, export presets), and it edits only levels under
`res://mixar/` or listed in `editable_scenes`. Everything else is refused with a
message saying what the studio can do instead. The agent cannot change the mode.
Enabling the add-on still registers its `MixarLink` autoload. The default,
`"owned"`, is for games Mixar builds from scratch.

## Game tags

Packages exported with `engine="godot"` carry `mixar_*` tags as glTF extras. On
import, the add-on gives each tagged node its tags as metadata, groups
(`mixar_<role>`, …) and a component script (`addons/mixar_link/game/`):

| Role | In the game |
| --- | --- |
| `pickup` | Spins; collected on touch |
| `door` | Opens (hinge or slide, `mixar_pivot`) once every pickup is collected |
| `goal` | Wins once the doors are open |
| `hazard` / `enemy` | Respawns the player; patrols with a `slide_*` pivot |
| `checkpoint` | Moves the respawn point |
| `spawn` | The player's start |
| `trigger` | Tells the game manager (`on_mixar_event`) |

Custom scripts use the same game manager: `get_tree().call_group("mixar_game",
"on_mixar_event", "<event>", self)` with `pickup`, `hazard`, `checkpoint`, `goal`,
`lose` or `restart`. They report their own values (a timer, a score) by joining
the group `mixar_state` and returning a Dictionary from `mixar_state()`; playtests
see those values in the game state.

Positions use Blender's frame (Z up, metres), the frame Mixar works in. Blender
`(x, y, z)` is Godot `(x, z, -y)`, and a yaw about Blender Z is the same angle about
Godot Y.

Packages exported with `engine="godot"` carry collision as Godot import hints
(`-convcolonly` / `-colonly`) and game tags (`mixar_role`, `mixar_body`, …) as glTF
extras. Godot reads the extras as node metadata.

## Test

```sh
python3 test/run_e2e.py --godot /path/to/Godot            # headless editor and game (108 checks: plays levels to a win, scripted gameplay, plugin mode)
python3 test/run_toolsets_e2e.py --godot /path/to/Godot   # every editor toolset tool, undo, refusals and plugin mode (117 checks)
python3 test/run_e2e.py --godot /path/to/Godot --windowed-game   # also checks a real frame
python3 test/run_concurrent_import_e2e.py --godot /path/to/Godot   # simultaneous imports (same folder twice, a rig): no overlap, no corrupt read, no crash
python3 test/run_concurrent_import_e2e.py --godot /path/to/Godot --windowed --tex-size 4096   # the same with an editor window (its progress dialog runs frames mid-import, the crash's path)
python3 test/run_concurrent_import_e2e.py --godot /path/to/Godot --windowed --mixed-writes --scripts 300   # imports during script-class registration (reproduces the 4.7.2 nested-progress crash without the guard)
python3 test/run_concurrent_import_e2e.py --attach ~/Games/my-game --editor-log /var/log/mixar-cloud/godot.log   # against an editor already running (a cloud workstation); imports go to res://mixar/zzLinkTest*
```

## License

MIT
