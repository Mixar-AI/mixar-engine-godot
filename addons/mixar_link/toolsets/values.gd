@tool
extends RefCounted
## JSON <-> Variant for the editor toolsets, in Godot's own units and axes.
##
## In: plain JSON coerced to the property's declared (or current) type;
## {"$godot": "<var_to_str literal>"} for anything else; {"$new": "<Resource
## class>", "properties": {...}} for an inline sub-resource; a "res://" string
## loads a Resource for a Resource-typed property.
## Out: JSON-native values as-is; other Variants as {"$godot": var_to_str(v)};
## Resources as their resource_path, or {"$resource": class, "properties"} when
## embedded; nodes as {"$node": path}.

const MAX_ITEMS := 64
const MAX_LITERAL := 2000
const MAX_RESOURCE_PROPS := 24
const VECTOR_SIZES := {
	TYPE_VECTOR2: 2, TYPE_VECTOR2I: 2, TYPE_VECTOR3: 3, TYPE_VECTOR3I: 3, TYPE_VECTOR4: 4, TYPE_VECTOR4I: 4,
	TYPE_QUATERNION: 4, TYPE_RECT2: 4, TYPE_RECT2I: 4, TYPE_PLANE: 4, TYPE_AABB: 6,
}
const PACKED_ELEMENT := {
	TYPE_PACKED_BYTE_ARRAY: TYPE_INT, TYPE_PACKED_INT32_ARRAY: TYPE_INT, TYPE_PACKED_INT64_ARRAY: TYPE_INT,
	TYPE_PACKED_FLOAT32_ARRAY: TYPE_FLOAT, TYPE_PACKED_FLOAT64_ARRAY: TYPE_FLOAT,
	TYPE_PACKED_STRING_ARRAY: TYPE_STRING, TYPE_PACKED_VECTOR2_ARRAY: TYPE_VECTOR2,
	TYPE_PACKED_VECTOR3_ARRAY: TYPE_VECTOR3, TYPE_PACKED_COLOR_ARRAY: TYPE_COLOR,
	TYPE_PACKED_VECTOR4_ARRAY: TYPE_VECTOR4,
}


## A class the toolsets never create: editor-only classes, scripts (code goes
## through godot.files.write_file or run_script) and the add-on's own plugin.
static func forbidden_class(cls: String) -> bool:
	if not ClassDB.class_exists(cls):
		return true
	if ClassDB.class_get_api_type(cls) in [ClassDB.API_EDITOR, ClassDB.API_EDITOR_EXTENSION]:
		return true
	for base in ["EditorPlugin", "Script", "EditorInterface", "EditorSettings"]:
		if cls == base or ClassDB.is_parent_class(cls, base):
			return true
	return false


## The property-list entry for `prop` on `obj` ({} when there is none).
static func prop_info(obj: Object, prop: String) -> Dictionary:
	for p in obj.get_property_list():
		if String(p.name) == prop:
			return p
	return {}


## Properties a tool may read or write: shown in the inspector or saved.
static func is_editable(info: Dictionary) -> bool:
	return not info.is_empty() and int(info.usage) & (PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_STORAGE) != 0 \
		and int(info.usage) & (PROPERTY_USAGE_CATEGORY | PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP) == 0


## {"value": v} or {"error": message}. `info` is a property-list entry (or
## {"type": ..}); without one the current value's type decides.
static func from_json(value, current, info: Dictionary = {}) -> Dictionary:
	var type := int(info.get("type", typeof(current)))
	if typeof(value) == TYPE_DICTIONARY and value.has("$godot"):
		return parse_literal(String(value["$godot"]), type)
	if typeof(value) == TYPE_DICTIONARY and value.has("$new"):
		return new_resource(String(value["$new"]), value.get("properties", {}), info)
	if value == null:
		return {"value": null}
	var what := type_label(type, String(info.get("class_name", "")))
	if VECTOR_SIZES.has(type) or type in [TYPE_COLOR, TYPE_BASIS, TYPE_TRANSFORM2D, TYPE_TRANSFORM3D]:
		var v = _compound(value, type)
		if v == null:
			return {"error": "expects a %s: %s, or {\"$godot\": \"%s\"}." % [what, _shape(type), var_to_str(type_convert(null, type))]}
		return {"value": v}
	match type:
		TYPE_NIL:
			return {"value": _plain(value)}
		TYPE_BOOL:
			if typeof(value) in [TYPE_BOOL, TYPE_INT, TYPE_FLOAT]:
				return {"value": bool(value)}
			if typeof(value) == TYPE_STRING and value.to_lower() in ["true", "false"]:
				return {"value": value.to_lower() == "true"}
		TYPE_INT:
			if typeof(value) in [TYPE_BOOL, TYPE_INT, TYPE_FLOAT]:
				return {"value": int(value)}
			if typeof(value) == TYPE_STRING:
				return _enum_value(value, info)
		TYPE_FLOAT:
			if typeof(value) in [TYPE_INT, TYPE_FLOAT]:
				return {"value": float(value)}
		TYPE_STRING:
			return {"value": value if typeof(value) == TYPE_STRING else JSON.stringify(value)}
		TYPE_STRING_NAME:
			if typeof(value) == TYPE_STRING:
				return {"value": StringName(value)}
		TYPE_NODE_PATH:
			if typeof(value) == TYPE_STRING:
				return {"value": NodePath(value)}
		TYPE_OBJECT:
			if typeof(value) == TYPE_STRING:
				return load_resource(value, info)
			return {"error": "expects a %s: a \"res://...\" path, {\"$new\": \"<class>\", \"properties\": {}} or null." % what}
		TYPE_DICTIONARY:
			if typeof(value) == TYPE_DICTIONARY:
				return {"value": _plain(value)}
		TYPE_ARRAY:
			if typeof(value) == TYPE_ARRAY:
				return _array(value, current)
		_:
			if PACKED_ELEMENT.has(type) and typeof(value) == TYPE_ARRAY:
				var items: Array = []
				for item in value:
					var r := from_json(item, null, {"type": PACKED_ELEMENT[type]})
					if r.has("error"):
						return r
					items.append(r.value)
				return {"value": type_convert(items, type)}
	return {"error": "expects a %s, not %s." % [what, JSON.stringify(value).left(80)]}


## A var_to_str literal; Object(...) literals are refused (use $new).
static func parse_literal(text: String, type := TYPE_NIL) -> Dictionary:
	if text.contains("Object("):
		return {"error": "Object(...) literals are not accepted; use {\"$new\": \"<Resource class>\", \"properties\": {}}."}
	var v = str_to_var(text)
	if v == null and text.strip_edges() != "null":
		return {"error": "\"%s\" is not a Godot literal (var_to_str form, e.g. \"Vector3(1, 2, 3)\")." % text.left(80)}
	if type != TYPE_NIL and v != null and typeof(v) != type:
		if type in [TYPE_INT, TYPE_FLOAT] and typeof(v) in [TYPE_INT, TYPE_FLOAT]:
			return {"value": type_convert(v, type)}
		return {"error": "\"%s\" is a %s; a %s is needed." % [text.left(80), type_string(typeof(v)), type_string(type)]}
	return {"value": v}


## {"$new": cls, "properties": {..}}: a new embedded Resource.
static func new_resource(cls: String, props, info: Dictionary = {}) -> Dictionary:
	if not ClassDB.class_exists(cls) or not ClassDB.is_parent_class(cls, "Resource") or not ClassDB.can_instantiate(cls):
		return {"error": "\"%s\" is not a Resource class that can be created (godot.classes.search_classes finds one)." % cls}
	if forbidden_class(cls):
		return {"error": "%s cannot be created here; scripts are written with godot.files.write_file." % cls}
	var ok_type := _hint_check(cls, info)
	if ok_type != "":
		return {"error": ok_type}
	var res: Resource = ClassDB.instantiate(cls)
	if typeof(props) != TYPE_DICTIONARY:
		return {"error": "$new properties must be an object {name: value}."}
	for key in props:
		var pinfo := prop_info(res, String(key))
		if not is_editable(pinfo):
			return {"error": "%s has no property '%s'." % [cls, key]}
		var r := from_json(props[key], res.get(String(key)), pinfo)
		if r.has("error"):
			return {"error": "%s.%s %s" % [cls, key, r.error]}
		res.set(String(key), r.value)
	return {"value": res}


## A "res://" (or uid://) path to an existing Resource of a fitting class.
static func load_resource(path: String, info: Dictionary = {}) -> Dictionary:
	if not (path.begins_with("res://") or path.begins_with("uid://")) or path.contains(".."):
		return {"error": "a resource is a \"res://...\" path, not \"%s\"." % path.left(80)}
	if not ResourceLoader.exists(path):
		return {"error": "no resource at %s (godot.resources.list_resources lists them)." % path}
	var res = load(path)
	if res == null:
		return {"error": "%s did not load; read the log." % path}
	var problem := _hint_check(res.get_class(), info, res)
	if problem != "":
		return {"error": problem}
	return {"value": res}


static func _hint_check(cls: String, info: Dictionary, res: Resource = null) -> String:
	if int(info.get("hint", 0)) != PROPERTY_HINT_RESOURCE_TYPE or String(info.get("hint_string", "")) == "":
		return ""
	var allowed := String(info.hint_string).split(",")
	for a in allowed:
		if cls == a or ClassDB.is_parent_class(cls, a) or (res != null and res.is_class(a)):
			return ""
	return "a %s does not fit here; this property takes %s." % [cls, " or ".join(allowed)]


static func _enum_value(text: String, info: Dictionary) -> Dictionary:
	if int(info.get("hint", 0)) in [PROPERTY_HINT_ENUM, PROPERTY_HINT_FLAGS]:
		var index := 0
		for item in String(info.hint_string).split(","):
			var parts := item.split(":")
			var value := int(parts[1]) if parts.size() > 1 else index
			if parts[0].strip_edges().to_lower() == text.strip_edges().to_lower():
				return {"value": value}
			index = value + 1
		return {"error": "\"%s\" is not one of %s." % [text, info.hint_string]}
	if text.is_valid_int():
		return {"value": text.to_int()}
	return {"error": "expects an integer, not \"%s\"." % text.left(80)}


static func _numbers(value, n: int):
	var out: Array = []
	if typeof(value) == TYPE_DICTIONARY:
		for key in ["x", "y", "z", "w"].slice(0, n):
			if not value.has(key):
				return null
			out.append(value[key])
	elif typeof(value) == TYPE_ARRAY and value.size() == n:
		out = value
	else:
		return null
	for x in out:
		if typeof(x) not in [TYPE_INT, TYPE_FLOAT]:
			return null
	return out


static func _compound(value, type: int):
	if type == TYPE_COLOR:
		if typeof(value) == TYPE_STRING:
			if Color.html_is_valid(value):
				return Color.html(value)
			var named := Color.from_string(value, Color(-1, -1, -1))
			return null if named.r < 0 else named
		var c = _numbers(value, 4) if (typeof(value) == TYPE_ARRAY and value.size() == 4) else _numbers(value, 3)
		if c == null and typeof(value) == TYPE_DICTIONARY and value.has("r"):
			c = [value.get("r", 0), value.get("g", 0), value.get("b", 0), value.get("a", 1)]
		return Color(c[0], c[1], c[2], c[3] if c.size() > 3 else 1.0) if c != null else null
	if type in [TYPE_BASIS, TYPE_TRANSFORM2D, TYPE_TRANSFORM3D]:
		var rows := {TYPE_BASIS: 3, TYPE_TRANSFORM2D: 3, TYPE_TRANSFORM3D: 4}[type] as int
		var width := 2 if type == TYPE_TRANSFORM2D else 3
		if typeof(value) != TYPE_ARRAY or value.size() != rows:
			return null
		var vecs: Array = []
		for row in value:
			var nums = _numbers(row, width)
			if nums == null:
				return null
			vecs.append(Vector2(nums[0], nums[1]) if width == 2 else Vector3(nums[0], nums[1], nums[2]))
		match type:
			TYPE_BASIS: return Basis(vecs[0], vecs[1], vecs[2])
			TYPE_TRANSFORM2D: return Transform2D(vecs[0], vecs[1], vecs[2])
			_: return Transform3D(vecs[0], vecs[1], vecs[2], vecs[3])
	var n: int = VECTOR_SIZES[type]
	var a = _numbers(value, n)
	if a == null:
		return null
	match type:
		TYPE_VECTOR2: return Vector2(a[0], a[1])
		TYPE_VECTOR2I: return Vector2i(int(a[0]), int(a[1]))
		TYPE_VECTOR3: return Vector3(a[0], a[1], a[2])
		TYPE_VECTOR3I: return Vector3i(int(a[0]), int(a[1]), int(a[2]))
		TYPE_VECTOR4: return Vector4(a[0], a[1], a[2], a[3])
		TYPE_VECTOR4I: return Vector4i(int(a[0]), int(a[1]), int(a[2]), int(a[3]))
		TYPE_QUATERNION: return Quaternion(a[0], a[1], a[2], a[3])
		TYPE_RECT2: return Rect2(a[0], a[1], a[2], a[3])
		TYPE_RECT2I: return Rect2i(int(a[0]), int(a[1]), int(a[2]), int(a[3]))
		TYPE_PLANE: return Plane(a[0], a[1], a[2], a[3])
		TYPE_AABB: return AABB(Vector3(a[0], a[1], a[2]), Vector3(a[3], a[4], a[5]))
	return null


static func _shape(type: int) -> String:
	match type:
		TYPE_COLOR: return "[r, g, b] or [r, g, b, a] (0-1), \"#rrggbb\" or a colour name"
		TYPE_BASIS: return "[[x axis], [y axis], [z axis]]"
		TYPE_TRANSFORM3D: return "[[x axis], [y axis], [z axis], [origin]]"
		TYPE_TRANSFORM2D: return "[[x axis], [y axis], [origin]]"
		TYPE_AABB: return "[x, y, z, size_x, size_y, size_z]"
		TYPE_RECT2, TYPE_RECT2I: return "[x, y, width, height]"
	return "an array of %d numbers" % VECTOR_SIZES.get(type, 0)


## A typed Array keeps its element type.
static func _array(value: Array, current) -> Dictionary:
	var out: Array = current.duplicate() if typeof(current) == TYPE_ARRAY else []
	out.clear()
	var elem_type: int = out.get_typed_builtin() if out.is_typed() else TYPE_NIL
	for item in value:
		var r := from_json(item, null, {"type": elem_type, "class_name": String(out.get_typed_class_name())})
		if r.has("error"):
			return {"error": "an element " + r.error}
		out.append(r.value)
	return {"value": out}


## JSON from an untyped place: $godot / $new objects inside become values.
static func _plain(value):
	if typeof(value) == TYPE_DICTIONARY:
		if value.has("$godot") or value.has("$new"):
			var r := from_json(value, null)
			return r.get("value")
		var d := {}
		for k in value:
			d[k] = _plain(value[k])
		return d
	if typeof(value) == TYPE_ARRAY:
		return value.map(func(x): return _plain(x))
	return value


static func type_label(type: int, cls := "") -> String:
	if type == TYPE_OBJECT:
		return cls if cls != "" else "Object"
	return "Variant" if type == TYPE_NIL else type_string(type)


## A Variant as compact JSON (see the header). `root` names nodes by path.
static func to_json(v, root: Node = null, depth := 0):
	match typeof(v):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_STRING:
			return v
		TYPE_FLOAT:
			return v if is_finite(v) else {"$godot": var_to_str(v)}
		TYPE_STRING_NAME, TYPE_NODE_PATH:
			return String(v)
		TYPE_OBJECT:
			if not is_instance_valid(v):
				return null
			if v is Resource:
				var path: String = v.resource_path
				if path != "" and not path.contains("::"):
					return path
				var out := {"$resource": v.get_class()}
				if depth == 0:
					out["properties"] = changed_properties(v, root, depth + 1)
				return out
			if v is Node and root != null and (v == root or root.is_ancestor_of(v)):
				return {"$node": String(root.get_path_to(v))}
			return {"$object": v.get_class()}
		TYPE_ARRAY:
			var items: Array = []
			for i in mini(v.size(), MAX_ITEMS):
				items.append(to_json(v[i], root, depth + 1))
			if v.size() > MAX_ITEMS:
				return {"items": items, "size": v.size(), "truncated": true}
			return items
		TYPE_DICTIONARY:
			var d := {}
			for k in v.keys().slice(0, MAX_ITEMS):
				d[str(k)] = to_json(v[k], root, depth + 1)
			if v.size() > MAX_ITEMS:
				d["$truncated"] = v.size()
			return d
	if PACKED_ELEMENT.has(typeof(v)) and v.size() > MAX_ITEMS:
		return {"$type": type_string(typeof(v)), "size": v.size(), "truncated": true}
	var text := var_to_str(v)
	if text.length() > MAX_LITERAL:
		return {"$type": type_string(typeof(v)), "truncated": true}
	return {"$godot": text}


## The value a property has by default (class default, script default or the
## object's own revert value); [false] when unknown.
static func default_of(obj: Object, prop: String) -> Array:
	if obj.property_can_revert(prop):
		return [true, obj.property_get_revert(prop)]
	var script = obj.get_script()
	if script is Script:
		for p in script.get_script_property_list():
			if String(p.name) == prop:
				return [true, script.get_property_default_value(prop)]
	if ClassDB.class_exists(obj.get_class()) and prop in ClassDB.class_get_property_list(obj.get_class()).map(func(p): return String(p.name)):
		return [true, ClassDB.class_get_property_default_value(obj.get_class(), prop)]
	return [false]


static func same(a, b) -> bool:
	if typeof(a) in [TYPE_INT, TYPE_FLOAT] and typeof(b) in [TYPE_INT, TYPE_FLOAT]:
		return is_equal_approx(float(a), float(b))
	return typeof(a) == typeof(b) and a == b


## The editable properties of `obj` that differ from their defaults (capped).
static func changed_properties(obj: Object, root: Node = null, depth := 0, limit := MAX_RESOURCE_PROPS) -> Dictionary:
	var out := {}
	for p in obj.get_property_list():
		var name := String(p.name)
		if not is_editable(p) or name.begins_with("_") or name in ["resource_path", "resource_name", "resource_local_to_scene", "resource_scene_unique_id"]:
			continue
		var value = obj.get(name)
		var d := default_of(obj, name)
		if d[0] and same(d[1], value):
			continue
		if out.size() >= limit:
			out["$truncated"] = true
			break
		out[name] = to_json(value, root, depth)
	return out
