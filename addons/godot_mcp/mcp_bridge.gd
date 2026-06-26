@tool
extends EditorPlugin

## Godot MCP Bridge — editor side.
##
## Connects OUT to the Python MCP server as a WebSocket client (the server runs the
## listener; this plugin is the client). Each frame it drains incoming JSON requests,
## dispatches them to command_router.gd on the main thread (so editor calls are
## thread-safe), and sends back a correlated reply.
##
##   Claude Code  <--stdio/MCP-->  server.py  <--ws://127.0.0.1:9081-->  THIS PLUGIN
##
## Message shape (both directions):
##   request : {"id": <any>, "method": "<name>", "params": { ... }}
##   reply   : {"id": <same>, "result": { ... }}  OR  {"id": <same>, "error": {"code", "message"}}

const SERVER_HOST := "127.0.0.1"
const DEFAULT_PORT := 9081
## Per-project override so a 2D and a 3D project's editors can run side-by-side on
## different ports. Set "mcp/bridge/port" in each project's Project Settings (and match
## GODOT_MCP_PORT in that project's .mcp.json). Defaults to DEFAULT_PORT when unset.
const PORT_SETTING := "mcp/bridge/port"
const RECONNECT_INTERVAL := 2.0  # seconds between reconnect attempts
const ROUTER_PATH := "res://addons/godot_mcp/command_router.gd"
const RELOAD_CHECK_INTERVAL := 1.0  # seconds between command_router.gd change checks
const MAX_BUFFER := 16 * 1024 * 1024  # 16 MiB WebSocket buffers, for large replies (screenshots, big scripts)

var _socket: WebSocketPeer
var _router            # command_router.gd instance (hot-reloaded on file change)
var _router_mtime := -1
var _reload_check_accum := 0.0
var _poller: Node      # @tool child node whose _process reliably fires in-editor
var _connected := false
var _reconnect_accum := 0.0


func _enter_tree() -> void:
	_register_port_setting()
	_load_router()
	_poller = preload("res://addons/godot_mcp/poller.gd").new()
	_poller.name = "MCPPoller"
	_poller.bridge = self
	add_child(_poller)
	_connect_socket()
	print("[godot-mcp] bridge enabled; connecting to ws://%s:%d" % [SERVER_HOST, _server_port()])


## The configured bridge port (project setting, falling back to DEFAULT_PORT).
func _server_port() -> int:
	return int(ProjectSettings.get_setting(PORT_SETTING, DEFAULT_PORT))


## Make the port visible/editable under Project Settings (General, Advanced) and persisted
## in project.godot. Idempotent — safe to call every time the plugin enables.
func _register_port_setting() -> void:
	if not ProjectSettings.has_setting(PORT_SETTING):
		ProjectSettings.set_setting(PORT_SETTING, DEFAULT_PORT)
	ProjectSettings.set_initial_value(PORT_SETTING, DEFAULT_PORT)
	ProjectSettings.add_property_info({
		"name": PORT_SETTING,
		"type": TYPE_INT,
		"hint": PROPERTY_HINT_RANGE,
		"hint_string": "1024,65535,1",
	})


func _exit_tree() -> void:
	if _socket != null and _socket.get_ready_state() != WebSocketPeer.STATE_CLOSED:
		_socket.close()
	if is_instance_valid(_poller):
		_poller.queue_free()
	_poller = null
	_socket = null
	_connected = false
	print("[godot-mcp] bridge disabled")


func _connect_socket() -> void:
	_socket = WebSocketPeer.new()
	# Allow multi-MB messages (screenshots, large scripts/scene trees); defaults are 64 KiB.
	_socket.inbound_buffer_size = MAX_BUFFER
	_socket.outbound_buffer_size = MAX_BUFFER
	var err := _socket.connect_to_url("ws://%s:%d" % [SERVER_HOST, _server_port()])
	if err != OK:
		# Not fatal — server may not be up yet. The poll loop will retry.
		pass


## (Re)load command_router.gd fresh from disk (bypassing the cache) and rebuild the
## dispatcher. Returns false on parse error, keeping the previous router intact.
func _load_router() -> bool:
	var script = ResourceLoader.load(ROUTER_PATH, "Script", ResourceLoader.CACHE_MODE_IGNORE)
	if script == null or not (script is GDScript):
		push_error("[godot-mcp] command_router.gd failed to load (parse error?); keeping previous handlers.")
		return false
	_router = script.new(self)
	_router_mtime = int(FileAccess.get_modified_time(ROUTER_PATH))
	return true


## Auto hot-reload: if command_router.gd changed on disk, rebuild the dispatcher so new
## tool handlers go live without disabling/re-enabling the plugin.
func _maybe_reload_router(delta: float) -> void:
	_reload_check_accum += delta
	if _reload_check_accum < RELOAD_CHECK_INTERVAL:
		return
	_reload_check_accum = 0.0
	var mt := int(FileAccess.get_modified_time(ROUTER_PATH))
	if mt > 0 and mt != _router_mtime:
		if _load_router():
			print("[godot-mcp] command_router.gd hot-reloaded")


## Called every editor frame by the poller child node.
func poll(delta: float) -> void:
	_maybe_reload_router(delta)
	if _socket == null:
		return
	_socket.poll()
	match _socket.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if not _connected:
				_connected = true
				print("[godot-mcp] connected to server")
			while _socket.get_available_packet_count() > 0:
				var pkt := _socket.get_packet()
				if _socket.was_string_packet():
					_handle_message(pkt.get_string_from_utf8())
		WebSocketPeer.STATE_CLOSED:
			if _connected:
				_connected = false
				print("[godot-mcp] disconnected from server; retrying...")
			_reconnect_accum += delta
			if _reconnect_accum >= RECONNECT_INTERVAL:
				_reconnect_accum = 0.0
				_connect_socket()
		_:
			# STATE_CONNECTING / STATE_CLOSING — keep polling, nothing to do.
			pass


func _handle_message(text: String) -> void:
	var msg = JSON.parse_string(text)
	if typeof(msg) != TYPE_DICTIONARY:
		return
	var id = msg.get("id")
	var method := String(msg.get("method", ""))
	var params = msg.get("params", {})
	if typeof(params) != TYPE_DICTIONARY:
		params = {}

	# We are on the main thread here (poller._process), so editor APIs are safe to call.
	# `reload_bridge` is handled here (not in the router) so it works even when the
	# running router is stale — letting an agent refresh handlers without a plugin toggle.
	# dispatch() may be a coroutine (e.g. refresh_filesystem(wait=true), screenshot(which="game")
	# yield editor frames). Awaiting it here is safe for synchronous handlers too — they just
	# return immediately. This _handle_message call is fire-and-forget from poll(), so suspending
	# on an await doesn't block the editor; the reply is sent when the coroutine resumes.
	var res: Dictionary
	if method == "reload_bridge":
		res = _reload_bridge_cmd()
	elif _router == null:
		res = {"error": {"code": -32603, "message": "Bridge router not initialized"}}
	else:
		res = await _router.dispatch(method, params)

	var reply := {"id": id}
	if res.has("error"):
		reply["error"] = res["error"]
	else:
		reply["result"] = res.get("result")
	# An awaited dispatch may have suspended across a disconnect; bail if the socket went away.
	if _socket == null or _socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	var send_err := _socket.send_text(JSON.stringify(reply))
	if send_err != OK:
		push_error("[godot-mcp] reply send failed (error %d) — payload too large for the buffer?" % send_err)


func _reload_bridge_cmd() -> Dictionary:
	if _load_router():
		return {"result": {"reloaded": true, "router_mtime": _router_mtime}}
	return {"error": {"code": -32000, "message": "Router reload failed (parse error?); call read_log."}}


# --- UndoRedo helpers ---------------------------------------------------------
# Routed through single methods so each undo/redo step is atomic and order-independent
# (Godot runs undo operations in reverse order, and `owner` must be set only once the
# node is back in the tree). These live on the persistent plugin so the undo history
# always has a valid callable target.

func _mcp_add_node(parent: Node, node: Node, owner_node: Node) -> void:
	parent.add_child(node)
	node.owner = owner_node

func _mcp_remove_node(parent: Node, node: Node) -> void:
	if node.get_parent() == parent:
		parent.remove_child(node)

func _mcp_re_add_node(parent: Node, node: Node, owner_node: Node, index: int) -> void:
	parent.add_child(node)
	if index >= 0 and index < parent.get_child_count():
		parent.move_child(node, index)
	node.owner = owner_node

func _mcp_move_node(node: Node, new_parent: Node, owner_node: Node) -> void:
	var old_parent := node.get_parent()
	if old_parent != null:
		old_parent.remove_child(node)
	new_parent.add_child(node)
	node.owner = owner_node
