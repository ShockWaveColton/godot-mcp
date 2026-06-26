@tool
extends RefCounted

## Dispatches MCP requests (forwarded by mcp_bridge.gd) to Godot editor APIs.
##
## Conventions:
##  - Every scene/node MUTATION goes through EditorUndoRedoManager so the user can
##    Ctrl+Z anything the agent does (and the scene never gets corrupted by raw edits).
##  - Node paths are relative to the edited scene root; "." or "" means the root.
##  - Returns {"result": ...} on success or {"error": {"code", "message"}} on failure.

## Security gate for run_in_editor (sandboxed Expression eval). Default OFF — flip to true to
## enable. Changing this hot-reloads the router (~1s), so no plugin toggle is needed to enable it.
const ALLOW_EVAL := false

var _plugin: EditorPlugin


func _init(plugin: EditorPlugin) -> void:
	_plugin = plugin


func dispatch(method: String, params: Dictionary) -> Dictionary:
	match method:
		"ping":              return _ping()
		"get_project_info":  return _get_project_info()
		"get_scene_tree":    return _get_scene_tree()
		"list_open_scenes":  return _list_open_scenes()
		"get_node_property": return _get_node_property(params)
		"open_scene":        return _open_scene(params)
		"reload_scene_from_disk": return _reload_scene_from_disk(params)
		"save_scene":        return _save_scene()
		"create_node":       return _create_node(params)
		"set_node_property": return _set_node_property(params)
		"set_sprite_texture": return _set_sprite_texture(params)
		"delete_node":       return _delete_node(params)
		"reparent_node":     return _reparent_node(params)
		"run_project":       return _run_project()
		"play_scene":        return _play_scene(params)
		"stop_project":      return _stop_project()
		"read_script":       return _read_script(params)
		"create_script":     return _create_script(params)
		"edit_script":       return _edit_script(params)
		"attach_script":     return _attach_script(params)
		"instance_scene":    return _instance_scene(params)
		"screenshot":        return await _screenshot(params)
		"read_log":          return _read_log(params)
		"create_scene":      return _create_scene(params)
		"refresh_filesystem": return await _refresh_filesystem(params)
		"set_main_scene":    return _set_main_scene(params)
		"validate_script":   return _validate_script(params)
		"list_signals":      return _list_signals(params)
		"connect_signal":    return _connect_signal(params)
		"search_nodes":      return _search_nodes(params)
		"get_project_settings": return _get_project_settings(params)
		"set_project_settings": return _set_project_settings(params)
		"is_plugin_enabled":  return _is_plugin_enabled(params)
		"set_plugin_enabled": return _set_plugin_enabled(params)
		"reload_plugin":      return _reload_plugin(params)
		"run_in_editor":     return _run_in_editor(params)
		_:                   return {"error": {"code": -32601, "message": "Unknown method: %s" % method}}


# ---------------------------------------------------------------- helpers ----

func _ok(value = null) -> Dictionary:
	return {"result": {"ok": true, "value": value}}


func _err(message: String) -> Dictionary:
	return {"error": {"code": -32000, "message": message}}


func _root() -> Node:
	# EditorInterface is a global singleton in Godot 4.2+.
	return EditorInterface.get_edited_scene_root()


func _resolve(root: Node, path: String) -> Node:
	if root == null:
		return null
	if path == "" or path == ".":
		return root
	return root.get_node_or_null(NodePath(path))


## Convert a JSON array into a common Godot math type, based on the property's current type.
func _coerce(current_value, new_value):
	if typeof(new_value) == TYPE_ARRAY:
		match typeof(current_value):
			TYPE_VECTOR2:  return Vector2(new_value[0], new_value[1])
			TYPE_VECTOR2I: return Vector2i(int(new_value[0]), int(new_value[1]))
			TYPE_VECTOR3:  return Vector3(new_value[0], new_value[1], new_value[2])
			TYPE_VECTOR3I: return Vector3i(int(new_value[0]), int(new_value[1]), int(new_value[2]))
			TYPE_VECTOR4:  return Vector4(new_value[0], new_value[1], new_value[2], new_value[3])
			TYPE_COLOR:
				var a := 1.0
				if new_value.size() > 3:
					a = float(new_value[3])
				return Color(new_value[0], new_value[1], new_value[2], a)
	return new_value


## Convert a Godot Variant into something JSON.stringify can serialize cleanly.
func _to_json(v):
	match typeof(v):
		TYPE_VECTOR2, TYPE_VECTOR2I:  return [v.x, v.y]
		TYPE_VECTOR3, TYPE_VECTOR3I:  return [v.x, v.y, v.z]
		TYPE_VECTOR4, TYPE_VECTOR4I:  return [v.x, v.y, v.z, v.w]
		TYPE_COLOR:                   return [v.r, v.g, v.b, v.a]
		TYPE_OBJECT:
			# Surface a Resource by its path (a null/<Object#null> echo is exactly the
			# confusing false-positive this bridge is trying to avoid).
			if v is Resource and (v as Resource).resource_path != "":
				return (v as Resource).resource_path
			return str(v)
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING, TYPE_ARRAY, TYPE_DICTIONARY:
			return v
		_: return str(v)


## Look up a property's metadata (type, hint, hint_string) from a node's property list.
## Returns {} when the property doesn't exist on the node.
func _find_property_info(obj: Object, prop: String) -> Dictionary:
	for pi in obj.get_property_list():
		if String(pi.get("name", "")) == prop:
			return pi
	return {}


# --------------------------------------------------------------- handlers ----

func _ping() -> Dictionary:
	return {"result": {"pong": true, "godot_version": Engine.get_version_info().get("string", "")}}


func _get_project_info() -> Dictionary:
	return {"result": {
		"name": ProjectSettings.get_setting("application/config/name", ""),
		"godot_version": Engine.get_version_info().get("string", ""),
		"main_scene": ProjectSettings.get_setting("application/run/main_scene", ""),
		"project_path": ProjectSettings.globalize_path("res://"),
	}}


func _get_scene_tree() -> Dictionary:
	var root := _root()
	if root == null:
		return {"result": null}
	return {"result": _describe(root, root)}


func _describe(node: Node, root: Node) -> Dictionary:
	var children: Array = []
	for child in node.get_children():
		children.append(_describe(child, root))
	var script_path := ""
	var scr = node.get_script()
	if scr != null and scr.resource_path != "":
		script_path = scr.resource_path
	return {
		"name": String(node.name),
		"type": node.get_class(),
		"path": "." if node == root else String(root.get_path_to(node)),
		"script": script_path,
		"children": children,
	}


func _list_open_scenes() -> Dictionary:
	var result: Array = []
	for s in EditorInterface.get_open_scenes():
		result.append(String(s))
	return {"result": result}


func _get_node_property(p: Dictionary) -> Dictionary:
	var root := _root()
	if root == null:
		return _err("No scene is open")
	var node := _resolve(root, String(p.get("path", ".")))
	if node == null:
		return _err("Node not found: %s" % p.get("path", ""))
	var prop := String(p.get("property", ""))
	return {"result": {"property": prop, "value": _to_json(node.get(prop))}}


func _open_scene(p: Dictionary) -> Dictionary:
	var path := String(p.get("path", ""))
	if not ResourceLoader.exists(path):
		return _err("Scene does not exist: %s" % path)
	var already_open := _is_scene_open(path)
	EditorInterface.open_scene_from_path(path)
	var result := {"path": path, "already_open": already_open}
	if already_open:
		# open_scene_from_path just focuses the existing tab — it does NOT re-read disk. If the
		# .tscn was edited on disk, the editor still holds (and will re-save) its in-memory copy.
		result["note"] = ("Scene was already open; the editor shows its in-memory copy and external "
			+ "disk edits are NOT loaded. Call reload_scene_from_disk to pick up on-disk changes.")
	return {"result": result}


func _is_scene_open(path: String) -> bool:
	for s in EditorInterface.get_open_scenes():
		if String(s) == path:
			return true
	return false


## Reload an already-open scene from disk, discarding the editor's in-memory copy. The fix for
## external .tscn edits getting silently clobbered when the editor re-saves its stale copy.
func _reload_scene_from_disk(p: Dictionary) -> Dictionary:
	var path := String(p.get("path", ""))
	if path == "":
		var r := _root()
		if r != null:
			path = r.scene_file_path
	if path == "":
		return _err("No path given and the current scene has no file path (save it first).")
	if not ResourceLoader.exists(path):
		return _err("Scene does not exist: %s" % path)
	if not _is_scene_open(path):
		return _err("Scene is not open: %s. Open it with open_scene first." % path)
	EditorInterface.reload_scene_from_path(path)
	return _ok({"reloaded": path})


func _save_scene() -> Dictionary:
	if _root() == null:
		return _err("No scene is open")
	var err := EditorInterface.save_scene()
	if err != OK:
		return _err("save_scene failed (error %d)" % err)
	return _ok()


func _create_node(p: Dictionary) -> Dictionary:
	var root := _root()
	if root == null:
		return _err("No scene is open. Open or create a scene first.")
	var parent := _resolve(root, String(p.get("parent", ".")))
	if parent == null:
		return _err("Parent not found: %s" % p.get("parent", "."))
	var type := String(p.get("type", "Node"))
	if not ClassDB.class_exists(type) or not ClassDB.can_instantiate(type):
		return _err("Cannot instantiate class: %s" % type)
	var obj = ClassDB.instantiate(type)
	if obj == null or not (obj is Node):
		return _err("Class is not a Node: %s" % type)
	var node: Node = obj
	node.name = String(p.get("name", type))
	var ur := _plugin.get_undo_redo()
	ur.create_action("MCP: create %s" % node.name)
	ur.add_do_method(_plugin, "_mcp_add_node", parent, node, root)  # owner set so it serializes
	ur.add_do_reference(node)
	ur.add_undo_method(_plugin, "_mcp_remove_node", parent, node)
	ur.commit_action()
	return {"result": {"path": String(root.get_path_to(node))}}


func _set_node_property(p: Dictionary) -> Dictionary:
	var root := _root()
	if root == null:
		return _err("No scene is open")
	var node := _resolve(root, String(p.get("path", "")))
	if node == null:
		return _err("Node not found: %s" % p.get("path", ""))
	var prop := String(p.get("property", ""))
	if prop == "":
		return _err("`property` is required")
	var info := _find_property_info(node, prop)
	if info.is_empty():
		return _err("%s (%s) has no settable property '%s'." % [node.name, node.get_class(), prop])
	var current = node.get(prop)
	var value = _coerce(current, p.get("value"))
	var prop_type := int(info.get("type", TYPE_NIL))

	# Object/Resource-typed properties can't take a raw string. A res://|uid:// path must be
	# run through ResourceLoader, or the assignment silently no-ops (set says ok, get says null).
	# This was the headline bug: coerce here, or fail loudly — never echo a fake success.
	var is_resource_set := false
	if prop_type == TYPE_OBJECT and typeof(value) == TYPE_STRING:
		var path_str := String(value)
		if path_str == "":
			value = null  # explicit clear of the property
		elif path_str.begins_with("res://") or path_str.begins_with("uid://"):
			if not ResourceLoader.exists(path_str):
				return _err("Cannot set %s.%s: no resource at %s (not imported yet? try refresh_filesystem(wait=true))."
					% [node.name, prop, path_str])
			var loaded = ResourceLoader.load(path_str)
			if loaded == null:
				return _err("Cannot set %s.%s: failed to load resource at %s." % [node.name, prop, path_str])
			var want := String(info.get("hint_string", ""))
			# Only block a clear mismatch against a known engine class; stay lenient for custom types.
			if want != "" and ClassDB.class_exists(want) and not loaded.is_class(want):
				return _err("Cannot set %s.%s: %s loaded as %s, but the property expects %s."
					% [node.name, prop, path_str, loaded.get_class(), want])
			value = loaded
			is_resource_set = true
		else:
			return _err("Cannot set %s.%s: it is Object-typed, so value must be a res:// or uid:// path (got %s)."
				% [node.name, prop, path_str])

	var ur := _plugin.get_undo_redo()
	ur.create_action("MCP: set %s.%s" % [node.name, prop])
	ur.add_do_property(node, prop, value)
	ur.add_undo_property(node, prop, current)
	ur.commit_action()

	# Verify a resource assignment actually took (Godot silently ignores a type-mismatched set),
	# so we report the truth instead of a false positive the caller can't tell apart.
	if is_resource_set and node.get(prop) == null:
		return _err("Set %s.%s did not stick: property is still null after assignment (type mismatch?)."
			% [node.name, prop])
	return _ok({"property": prop, "value": _to_json(node.get(prop))})


## One-call convenience: put a texture on a sprite-like node (Sprite2D/Sprite3D/TextureRect/…).
## Thin wrapper over set_node_property's resource coercion, so it's undoable and verified too.
func _set_sprite_texture(p: Dictionary) -> Dictionary:
	var tex := String(p.get("texture_path", ""))
	if tex == "":
		return _err("`texture_path` is required (a res:// or uid:// path to an image/texture).")
	return _set_node_property({
		"path": p.get("path", ""),
		"property": p.get("property", "texture"),
		"value": tex,
	})


func _delete_node(p: Dictionary) -> Dictionary:
	var root := _root()
	if root == null:
		return _err("No scene is open")
	var node := _resolve(root, String(p.get("path", "")))
	if node == null:
		return _err("Node not found: %s" % p.get("path", ""))
	if node == root:
		return _err("Refusing to delete the scene root")
	var parent := node.get_parent()
	var index := node.get_index()
	var ur := _plugin.get_undo_redo()
	ur.create_action("MCP: delete %s" % node.name)
	ur.add_do_method(_plugin, "_mcp_remove_node", parent, node)
	ur.add_undo_method(_plugin, "_mcp_re_add_node", parent, node, root, index)
	ur.add_undo_reference(node)
	ur.commit_action()
	return _ok()


func _reparent_node(p: Dictionary) -> Dictionary:
	var root := _root()
	if root == null:
		return _err("No scene is open")
	var node := _resolve(root, String(p.get("path", "")))
	if node == null or node == root:
		return _err("Invalid node: %s" % p.get("path", ""))
	var new_parent := _resolve(root, String(p.get("new_parent", ".")))
	if new_parent == null:
		return _err("New parent not found: %s" % p.get("new_parent", ""))
	var old_parent := node.get_parent()
	var ur := _plugin.get_undo_redo()
	ur.create_action("MCP: reparent %s" % node.name)
	ur.add_do_method(_plugin, "_mcp_move_node", node, new_parent, root)
	ur.add_undo_method(_plugin, "_mcp_move_node", node, old_parent, root)
	ur.add_undo_reference(node)
	ur.commit_action()
	return {"result": {"path": String(root.get_path_to(node))}}


func _run_project() -> Dictionary:
	EditorInterface.play_main_scene()
	return _ok()


func _play_scene(p: Dictionary) -> Dictionary:
	var path := String(p.get("path", ""))
	if not ResourceLoader.exists(path):
		return _err("Scene does not exist: %s" % path)
	EditorInterface.play_custom_scene(path)
	return _ok(path)


func _stop_project() -> Dictionary:
	EditorInterface.stop_playing_scene()
	return _ok()


# ---------------------------------------------------- scripts & instancing ----

func _read_script(p: Dictionary) -> Dictionary:
	var path := String(p.get("path", ""))
	if not FileAccess.file_exists(path):
		return _err("File does not exist: %s" % path)
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return _err("Could not open %s (error %d)" % [path, FileAccess.get_open_error()])
	var text := f.get_as_text()
	f.close()
	return {"result": {"path": path, "content": text}}


func _create_script(p: Dictionary) -> Dictionary:
	var path := String(p.get("path", ""))
	if not path.begins_with("res://") or not path.ends_with(".gd"):
		return _err("Script path must be a res:// path ending in .gd : %s" % path)
	if FileAccess.file_exists(path) and not bool(p.get("overwrite", false)):
		return _err("File already exists (pass overwrite=true to replace): %s" % path)
	var content := String(p.get("content", ""))
	if content.strip_edges() == "":
		var base := String(p.get("base_class", "Node"))
		content = "extends %s\n\n\nfunc _ready() -> void:\n\tpass\n" % base
	var abs_dir := ProjectSettings.globalize_path(path.get_base_dir())
	if not DirAccess.dir_exists_absolute(abs_dir):
		DirAccess.make_dir_recursive_absolute(abs_dir)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return _err("Could not create %s (error %d)" % [path, FileAccess.get_open_error()])
	f.store_string(content)
	f.close()
	EditorInterface.get_resource_filesystem().scan()  # let the editor pick up the new file
	var result := {"path": path, "created": true}
	var attach_to := String(p.get("attach_to", ""))
	if attach_to != "":
		var ar := _attach_script({"path": attach_to, "script_path": path})
		if ar.has("error"):
			result["attach_error"] = ar["error"]["message"]
		else:
			result["attached_to"] = attach_to
	return {"result": result}


func _edit_script(p: Dictionary) -> Dictionary:
	var path := String(p.get("path", ""))
	if not FileAccess.file_exists(path):
		return _err("File does not exist: %s" % path)
	var new_content: String
	if p.has("content"):
		new_content = String(p["content"])
	elif p.has("find") and p.has("replace"):
		var rf := FileAccess.open(path, FileAccess.READ)
		if rf == null:
			return _err("Could not open %s" % path)
		var current := rf.get_as_text()
		rf.close()
		var find_str := String(p["find"])
		if not current.contains(find_str):
			return _err("`find` text not found in script")
		new_content = current.replace(find_str, String(p["replace"]))
	else:
		return _err("Provide either `content`, or both `find` and `replace`")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return _err("Could not write %s (error %d)" % [path, FileAccess.get_open_error()])
	f.store_string(new_content)
	f.close()
	EditorInterface.get_resource_filesystem().update_file(path)
	return {"result": {"path": path, "ok": true,
		"note": "Check for parse/compile errors before relying on the new code."}}


func _attach_script(p: Dictionary) -> Dictionary:
	var root := _root()
	if root == null:
		return _err("No scene is open")
	var node := _resolve(root, String(p.get("path", "")))
	if node == null:
		return _err("Node not found: %s" % p.get("path", ""))
	var sp := String(p.get("script_path", ""))
	if not ResourceLoader.exists(sp):
		return _err("Script does not exist: %s" % sp)
	var scr = load(sp)
	if scr == null or not (scr is Script):
		return _err("Not a Script: %s" % sp)
	var ur := _plugin.get_undo_redo()
	ur.create_action("MCP: attach script to %s" % node.name)
	ur.add_do_property(node, "script", scr)
	ur.add_undo_property(node, "script", node.get_script())
	ur.commit_action()
	return _ok({"node": String(root.get_path_to(node)), "script": sp})


func _instance_scene(p: Dictionary) -> Dictionary:
	var root := _root()
	if root == null:
		return _err("No scene is open")
	var scene_path := String(p.get("scene_path", ""))
	if not ResourceLoader.exists(scene_path):
		return _err("Scene does not exist: %s" % scene_path)
	var packed = load(scene_path)
	if packed == null or not (packed is PackedScene):
		return _err("Not a PackedScene: %s" % scene_path)
	var parent := _resolve(root, String(p.get("parent", ".")))
	if parent == null:
		return _err("Parent not found: %s" % p.get("parent", "."))
	var inst: Node = packed.instantiate()
	if inst == null:
		return _err("Failed to instantiate: %s" % scene_path)
	var nm := String(p.get("name", ""))
	if nm != "":
		inst.name = nm
	var ur := _plugin.get_undo_redo()
	ur.create_action("MCP: instance %s" % scene_path.get_file())
	ur.add_do_method(_plugin, "_mcp_add_node", parent, inst, root)
	ur.add_do_reference(inst)
	ur.add_undo_method(_plugin, "_mcp_remove_node", parent, inst)
	ur.commit_action()
	return {"result": {"path": String(root.get_path_to(inst))}}


# ---------------------------------------------------------- view & logging ----

func _screenshot(p: Dictionary) -> Dictionary:
	var which := String(p.get("which", "auto"))
	if which == "game":
		return await _screenshot_game(p)
	if which == "auto":
		which = _active_viewport_kind()
	var vp: Viewport
	if which == "2d":
		vp = EditorInterface.get_editor_viewport_2d()
	else:
		vp = EditorInterface.get_editor_viewport_3d(0)
	if vp == null:
		return _err("Could not get the %s editor viewport" % which)
	var tex := vp.get_texture()
	if tex == null:
		return _err("Viewport has no texture yet")
	var img := tex.get_image()
	if img == null or img.is_empty():
		return _err("Could not capture the viewport image")
	var max_w := int(p.get("max_width", 1280))
	if max_w > 0 and img.get_width() > max_w:
		var ratio := float(max_w) / float(img.get_width())
		img.resize(max_w, int(img.get_height() * ratio))
	var png := img.save_png_to_buffer()
	return {"result": {
		"format": "png",
		"width": img.get_width(),
		"height": img.get_height(),
		"base64": Marshalls.raw_to_base64(png),
		"which": which,
	}}


## Decide whether to capture the 2D or 3D editor viewport for which="auto":
## return the kind of the currently-visible main-screen editor panel. When neither the
## 2D nor 3D editor is showing (e.g. Script/AssetLib is open), fall back to the
## per-project default setting "mcp/screenshot/default" (2D projects set this to "2d").
func _active_viewport_kind() -> String:
	var main := EditorInterface.get_editor_main_screen()
	if main != null:
		for child in main.get_children():
			if not (child is Control) or not (child as Control).visible:
				continue
			var cls := child.get_class()
			if cls.find("CanvasItemEditor") != -1:
				return "2d"
			if cls.find("Node3DEditor") != -1:
				return "3d"
	return String(ProjectSettings.get_setting("mcp/screenshot/default", "3d"))


# --- running-game capture ----------------------------------------------------
# The editor can't read another process's framebuffer, so a tiny autoload
# (game_capture.gd) injected into the project answers capture requests over user://:
# the editor drops a request file, the running game writes back a PNG. This is what
# lets screenshot(which="game") verify what actually renders at runtime.
const _GAME_AUTOLOAD := "autoload/MCPGameCapture"
const _GAME_HELPER := "*res://addons/godot_mcp/game_capture.gd"
const _GAME_REQ := "user://mcp_game_capture.req"
const _GAME_OUT := "user://mcp_game_capture.png"
const _GAME_DONE := "user://mcp_game_capture.done"


func _screenshot_game(p: Dictionary) -> Dictionary:
	# Make sure the capture helper is installed as an autoload so the running game can answer.
	if String(ProjectSettings.get_setting(_GAME_AUTOLOAD, "")) != _GAME_HELPER:
		ProjectSettings.set_setting(_GAME_AUTOLOAD, _GAME_HELPER)
		var serr := ProjectSettings.save()
		if serr != OK:
			return _err("Could not install the game-capture autoload (error %d)." % serr)
		return _err("Installed the 'MCPGameCapture' autoload. (Re)start the game (run_project/play_scene), "
			+ "then call screenshot(which=\"game\") again.")
	if not EditorInterface.is_playing_scene() and EditorInterface.get_playing_scene() == "":
		return _err("No game is running. Start it with run_project or play_scene, then capture.")

	# Clear any stale handshake files, then post a fresh request (payload = max_width).
	_rm_user(_GAME_OUT)
	_rm_user(_GAME_DONE)
	var max_w := int(p.get("max_width", 1280))
	var rf := FileAccess.open(_GAME_REQ, FileAccess.WRITE)
	if rf == null:
		return _err("Could not write capture request (error %d)." % FileAccess.get_open_error())
	rf.store_string(str(max_w))
	rf.close()

	# Wait (yielding frames, never blocking the editor) for the game to write the PNG.
	var timeout_ms := int(p.get("timeout_ms", 4000))
	var tree := _plugin.get_tree()
	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < timeout_ms:
		await tree.process_frame
		if FileAccess.file_exists(_GAME_DONE):
			break
	if not FileAccess.file_exists(_GAME_DONE):
		_rm_user(_GAME_REQ)
		return _err("Timed out waiting for the running game to respond. Restart it after installing "
			+ "the autoload so MCPGameCapture is active, and check read_log.")
	var f := FileAccess.open(_GAME_OUT, FileAccess.READ)
	if f == null:
		return _err("Game reported done but the capture file is missing.")
	var bytes := f.get_buffer(f.get_length())
	f.close()
	_rm_user(_GAME_DONE)
	return {"result": {"format": "png", "base64": Marshalls.raw_to_base64(bytes), "which": "game"}}


func _rm_user(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _read_log(p: Dictionary) -> Dictionary:
	var limit := int(p.get("limit", 100))
	var dir := DirAccess.open("user://logs")
	if dir == null:
		return _err("No user://logs directory (enable Project Settings > Debug > File Logging).")
	var newest := ""
	var newest_time := -1
	dir.list_dir_begin()
	var fn := dir.get_next()
	while fn != "":
		if not dir.current_is_dir() and fn.ends_with(".log"):
			var full := "user://logs/" + fn
			var mt := int(FileAccess.get_modified_time(full))
			if mt > newest_time:
				newest_time = mt
				newest = full
		fn = dir.get_next()
	dir.list_dir_end()
	if newest == "":
		return _err("No .log files found in user://logs")
	var f := FileAccess.open(newest, FileAccess.READ)
	if f == null:
		return _err("Could not open log %s" % newest)
	var text := f.get_as_text()
	f.close()
	var all_lines := text.split("\n", false)
	var start := maxi(0, all_lines.size() - limit)
	var out: Array = []
	for i in range(start, all_lines.size()):
		out.append(all_lines[i])
	return {"result": {"file": newest, "line_count": all_lines.size(), "lines": out}}


# ------------------------------------------------ project & scene authoring ----

func _create_scene(p: Dictionary) -> Dictionary:
	var path := String(p.get("path", ""))
	if not path.begins_with("res://") or not (path.ends_with(".tscn") or path.ends_with(".scn")):
		return _err("Scene path must be a res:// path ending in .tscn or .scn : %s" % path)
	if FileAccess.file_exists(path) and not bool(p.get("overwrite", false)):
		return _err("Scene already exists (pass overwrite=true to replace): %s" % path)
	var root_type := String(p.get("root_type", "Node"))
	if not ClassDB.class_exists(root_type) or not ClassDB.can_instantiate(root_type):
		return _err("Cannot instantiate root class: %s" % root_type)
	var obj = ClassDB.instantiate(root_type)
	if obj == null or not (obj is Node):
		return _err("Root class is not a Node: %s" % root_type)
	var root: Node = obj
	var nm := String(p.get("name", ""))
	root.name = nm if nm != "" else path.get_file().get_basename()
	var abs_dir := ProjectSettings.globalize_path(path.get_base_dir())
	if not DirAccess.dir_exists_absolute(abs_dir):
		DirAccess.make_dir_recursive_absolute(abs_dir)
	var packed := PackedScene.new()
	var pack_err := packed.pack(root)
	if pack_err != OK:
		root.free()
		return _err("Failed to pack scene (error %d)" % pack_err)
	var save_err := ResourceSaver.save(packed, path)
	root.free()
	if save_err != OK:
		return _err("Failed to save scene (error %d)" % save_err)
	EditorInterface.get_resource_filesystem().scan()
	var opened := false
	if bool(p.get("open", true)):
		EditorInterface.open_scene_from_path(path)
		opened = true
	return {"result": {"path": path, "root_type": root_type, "opened": opened}}


func _refresh_filesystem(p: Dictionary) -> Dictionary:
	var efs := EditorInterface.get_resource_filesystem()
	if efs == null:
		return _err("No EditorFileSystem available")
	efs.scan()  # async rescan + reimport of changed sources
	var wait := bool(p.get("wait", false))
	var paths_in = p.get("paths", [])
	var paths: Array = paths_in if typeof(paths_in) == TYPE_ARRAY else []
	if not wait and paths.is_empty():
		return _ok({"scanning": true, "note": "Rescan queued; reimport runs in the background. "
			+ "Pass wait=true (optionally paths=[...] of expected res:// resources) to block until it finishes."})

	# Block (yielding frames so the editor keeps importing — never busy-wait the main thread)
	# until the scan settles and any expected resources are loadable.
	var timeout_ms := int(p.get("timeout_ms", 15000))
	var tree := _plugin.get_tree()
	var start := Time.get_ticks_msec()
	# Let the scan actually begin before we start sampling is_scanning().
	while Time.get_ticks_msec() - start < 250:
		await tree.process_frame
	while Time.get_ticks_msec() - start < timeout_ms:
		if not efs.is_scanning() and _all_ready(paths):
			break
		await tree.process_frame
	var ready := {}
	for sp in paths:
		ready[String(sp)] = ResourceLoader.exists(String(sp))
	var waited := Time.get_ticks_msec() - start
	return _ok({
		"scanning": efs.is_scanning(),
		"waited_ms": waited,
		"timed_out": waited >= timeout_ms,
		"ready": ready,
	})


func _all_ready(paths: Array) -> bool:
	for sp in paths:
		if not ResourceLoader.exists(String(sp)):
			return false
	return true


func _set_main_scene(p: Dictionary) -> Dictionary:
	var path := String(p.get("path", ""))
	if path != "" and not ResourceLoader.exists(path):
		return _err("Scene does not exist: %s" % path)
	ProjectSettings.set_setting("application/run/main_scene", path)
	var err := ProjectSettings.save()
	if err != OK:
		return _err("Failed to save project settings (error %d)" % err)
	return _ok({"main_scene": path})


func _validate_script(p: Dictionary) -> Dictionary:
	var path := String(p.get("path", ""))
	if not FileAccess.file_exists(path):
		return _err("File does not exist: %s" % path)
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return _err("Could not open %s (error %d)" % [path, FileAccess.get_open_error()])
	var text := f.get_as_text()
	f.close()
	# Compile a throwaway copy from the file text. This never touches the cached/running
	# script resource, so it cannot deadlock — even when validating a script that is
	# currently loaded (e.g. the addon's own files).
	var probe := GDScript.new()
	probe.source_code = text
	var err := probe.reload()
	var result := {"path": path, "valid": err == OK}
	if err != OK:
		result["error_code"] = err
		result["hint"] = "Parse/compile failed — call read_log for the error detail."
	return {"result": result}


# ------------------------------------------------ signals, search, settings ----

func _list_signals(p: Dictionary) -> Dictionary:
	var root := _root()
	if root == null:
		return _err("No scene is open")
	var node := _resolve(root, String(p.get("path", ".")))
	if node == null:
		return _err("Node not found: %s" % p.get("path", ""))
	var out: Array = []
	for s in node.get_signal_list():
		var sig_name := String(s.get("name", ""))
		var args: Array = []
		for a in s.get("args", []):
			args.append(String(a.get("name", "")))
		var conns: Array = []
		for c in node.get_signal_connection_list(sig_name):
			var cb = c.get("callable")
			var info: Dictionary = {}
			if typeof(cb) == TYPE_CALLABLE:
				info["method"] = String(cb.get_method())
				var obj = cb.get_object()
				if obj == root:
					info["target"] = "."
				elif obj is Node and root.is_ancestor_of(obj):
					info["target"] = String(root.get_path_to(obj))
				else:
					info["target"] = str(obj)
			else:
				info["method"] = str(cb)
			conns.append(info)
		out.append({"name": sig_name, "args": args, "connections": conns})
	return {"result": {"node": ("." if node == root else String(root.get_path_to(node))), "signals": out}}


func _connect_signal(p: Dictionary) -> Dictionary:
	var root := _root()
	if root == null:
		return _err("No scene is open")
	var from_node := _resolve(root, String(p.get("from", "")))
	if from_node == null:
		return _err("Source node not found: %s" % p.get("from", ""))
	var to_node := _resolve(root, String(p.get("to", "")))
	if to_node == null:
		return _err("Target node not found: %s" % p.get("to", ""))
	var sig := String(p.get("signal", ""))
	var method := String(p.get("method", ""))
	if not from_node.has_signal(sig):
		return _err("Node '%s' has no signal '%s'" % [from_node.name, sig])
	var cb := Callable(to_node, method)
	if from_node.is_connected(sig, cb):
		return _err("Signal already connected to that method")
	var ur := _plugin.get_undo_redo()
	ur.create_action("MCP: connect %s.%s" % [from_node.name, sig])
	ur.add_do_method(from_node, "connect", sig, cb, Object.CONNECT_PERSIST)  # persist = saved in .tscn
	ur.add_undo_method(from_node, "disconnect", sig, cb)
	ur.commit_action()
	var warning := ""
	if not to_node.has_method(method):
		warning = "Target has no method '%s' yet — connection saved but will error on emit until defined." % method
	return {"result": {
		"from": ("." if from_node == root else String(root.get_path_to(from_node))),
		"signal": sig,
		"to": ("." if to_node == root else String(root.get_path_to(to_node))),
		"method": method,
		"warning": warning,
	}}


func _search_nodes(p: Dictionary) -> Dictionary:
	var root := _root()
	if root == null:
		return _err("No scene is open")
	var by := String(p.get("by", "name"))
	var query := String(p.get("query", ""))
	var limit := int(p.get("limit", 200))
	var matches: Array = []
	_search_recurse(root, root, by, query, matches, limit)
	return {"result": {"by": by, "query": query, "count": matches.size(), "matches": matches}}


func _search_recurse(node: Node, root: Node, by: String, query: String, out: Array, limit: int) -> void:
	if out.size() >= limit:
		return
	var hit := false
	if by == "type":
		hit = node.is_class(query)  # "is-a" match: Camera3D matches "Node3D"
	else:
		hit = String(node.name).to_lower().contains(query.to_lower())
	if hit:
		out.append({
			"path": "." if node == root else String(root.get_path_to(node)),
			"name": String(node.name),
			"type": node.get_class(),
		})
	for c in node.get_children():
		_search_recurse(c, root, by, query, out, limit)


func _get_project_settings(p: Dictionary) -> Dictionary:
	var setting := String(p.get("setting", ""))
	if setting != "":
		if not ProjectSettings.has_setting(setting):
			return _err("No such setting: %s" % setting)
		return {"result": {"setting": setting, "value": _to_json(ProjectSettings.get_setting(setting))}}
	var prefix := String(p.get("prefix", ""))
	if prefix == "":
		return _err("Provide `setting` (one key) or `prefix` (to filter, e.g. 'application/').")
	var out: Dictionary = {}
	for prop in ProjectSettings.get_property_list():
		var n := String(prop.get("name", ""))
		if n.begins_with(prefix) and ProjectSettings.has_setting(n):
			out[n] = _to_json(ProjectSettings.get_setting(n))
	return {"result": {"prefix": prefix, "settings": out}}


func _set_project_settings(p: Dictionary) -> Dictionary:
	var setting := String(p.get("setting", ""))
	if setting == "":
		return _err("`setting` is required")
	if not p.has("value"):
		return _err("`value` is required")
	var value = p.get("value")
	if ProjectSettings.has_setting(setting):
		value = _coerce(ProjectSettings.get_setting(setting), value)
	ProjectSettings.set_setting(setting, value)
	var err := ProjectSettings.save()
	if err != OK:
		return _err("Failed to save project settings (error %d)" % err)
	return _ok({"setting": setting, "value": _to_json(value)})


# ----------------------------------------------------- editor plugins ----

func _plugin_cfg(name: String) -> String:
	return "res://addons/%s/plugin.cfg" % name


func _plugin_exists(name: String) -> bool:
	return name != "" and FileAccess.file_exists(_plugin_cfg(name))


## This bridge's own addon folder name, derived from the router's path — so we can refuse to
## disable ourselves in a way that would strand the connection with nothing left to re-enable it.
func _self_plugin_name() -> String:
	var sp: String = get_script().resource_path  # res://addons/<name>/command_router.gd
	var rest := sp.trim_prefix("res://addons/")
	var slash := rest.find("/")
	return rest.substr(0, slash) if slash > 0 else "godot_mcp"


func _is_plugin_enabled(p: Dictionary) -> Dictionary:
	var name := String(p.get("name", ""))
	if not _plugin_exists(name):
		return _err("No plugin at %s — pass the addon folder name (e.g. 'godot_mcp')." % _plugin_cfg(name))
	return _ok({"name": name, "enabled": EditorInterface.is_plugin_enabled(name)})


func _set_plugin_enabled(p: Dictionary) -> Dictionary:
	var name := String(p.get("name", ""))
	if not _plugin_exists(name):
		return _err("No plugin at %s — pass the addon folder name (e.g. 'godot_mcp')." % _plugin_cfg(name))
	if not p.has("enabled"):
		return _err("`enabled` (true/false) is required.")
	var enabled := bool(p.get("enabled"))
	if name == _self_plugin_name() and not enabled:
		return _err("Refusing to disable the MCP bridge ('%s') from within itself — it would drop this connection with nothing left to re-enable it. Use reload_plugin to cycle it, or toggle it manually in Project Settings > Plugins." % name)
	EditorInterface.set_plugin_enabled(name, enabled)
	return _ok({"name": name, "enabled": EditorInterface.is_plugin_enabled(name)})


## Disable then re-enable a plugin so its EditorPlugin scripts reload (the one thing the
## command_router.gd hot-reload can't do, since the running plugin holds mcp_bridge.gd/poller.gd).
## The disable is deferred so THIS reply is sent first, and both timers are owned by the editor's
## SceneTree + the EditorInterface singleton so they outlive the plugin's own teardown.
func _reload_plugin(p: Dictionary) -> Dictionary:
	var name := String(p.get("name", ""))
	if not _plugin_exists(name):
		return _err("No plugin at %s — pass the addon folder name (e.g. 'godot_mcp')." % _plugin_cfg(name))
	var tree := _plugin.get_tree()
	if tree == null:
		return _err("No editor SceneTree available to schedule the reload.")
	var disable_cb := Callable(EditorInterface, "set_plugin_enabled").bind(name, false)
	var enable_cb := Callable(EditorInterface, "set_plugin_enabled").bind(name, true)
	tree.create_timer(0.3).timeout.connect(disable_cb, CONNECT_ONE_SHOT)
	tree.create_timer(1.2).timeout.connect(enable_cb, CONNECT_ONE_SHOT)
	var is_self := name == _self_plugin_name()
	var note := "Plugin '%s' will disable then re-enable (~1s), reloading its EditorPlugin scripts." % name
	if is_self:
		note += " This is the MCP bridge itself: the connection drops briefly AFTER this reply and reconnects automatically — wait ~2s before the next godot tool call."
	return _ok({"name": name, "reloading": true, "self": is_self, "note": note})


func _run_in_editor(p: Dictionary) -> Dictionary:
	if not ALLOW_EVAL:
		return _err("run_in_editor is disabled. Set ALLOW_EVAL=true at the top of command_router.gd "
			+ "to enable (security-sensitive; uses the sandboxed Expression class).")
	var expression := String(p.get("expression", ""))
	if expression == "":
		return _err("`expression` is required")
	var expr := Expression.new()
	var perr := expr.parse(expression)
	if perr != OK:
		return _err("Parse error: %s" % expr.get_error_text())
	var base: Object = EditorInterface.get_edited_scene_root()
	var value = expr.execute([], base, true)
	if expr.has_execute_failed():
		return _err("Execute failed: %s" % expr.get_error_text())
	return {"result": {"value": _to_json(value)}}
