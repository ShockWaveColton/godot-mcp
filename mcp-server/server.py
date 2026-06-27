"""MCP server bridging an MCP client (e.g. Claude Code) to the Godot 4.7 editor.

Architecture:

    Claude Code  <--stdio/MCP-->  THIS SERVER  <--ws://127.0.0.1:9081-->  Godot @tool plugin

This process hosts the WebSocket *server*; the Godot editor plugin
(addons/godot_mcp/mcp_bridge.gd) connects OUT to it as a client. Each tool below
forwards a JSON request to the editor and awaits the reply correlated by `id`.

Run via:  uv run --directory mcp-server server.py
"""

from __future__ import annotations

import asyncio
import base64
import itertools
import json
import os
import sys
from contextlib import asynccontextmanager

import websockets
from mcp.server.fastmcp import FastMCP, Image


def _pid_alive(pid: int) -> bool:
    """Cross-platform 'is this process still running' check (no psutil dependency)."""
    if sys.platform == "win32":
        import ctypes
        PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
        STILL_ACTIVE = 259
        h = ctypes.windll.kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
        if not h:
            return False
        try:
            code = ctypes.c_ulong()
            ok = ctypes.windll.kernel32.GetExitCodeProcess(h, ctypes.byref(code))
            return bool(ok) and code.value == STILL_ACTIVE
        finally:
            ctypes.windll.kernel32.CloseHandle(h)
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def _watch_parent(pid: int) -> None:
    """Exit when the editor that auto-started us goes away. Without this, a force-closed editor
    leaves an orphan server holding the port — and the editor's auto-start skips a port already
    in use, so the next session adopts the stale orphan instead of launching fresh code."""
    import threading
    import time

    def _poll():
        while True:
            time.sleep(3)
            if not _pid_alive(pid):
                print(f"[godot-mcp] parent editor (pid {pid}) exited; shutting down server.", flush=True)
                os._exit(0)

    threading.Thread(target=_poll, daemon=True).start()

HOST = os.environ.get("GODOT_MCP_HOST", "127.0.0.1")
PORT = int(os.environ.get("GODOT_MCP_PORT", "9081"))
CALL_TIMEOUT = float(os.environ.get("GODOT_MCP_TIMEOUT", "30"))
MAX_MSG = int(os.environ.get("GODOT_MCP_MAX_MSG", str(32 * 1024 * 1024)))  # 32 MiB, for screenshots/large payloads

# --- bridge state (single connected editor) ---
_editor_ws = None
_pending: dict[str, asyncio.Future] = {}
_ids = itertools.count(1)


async def _ws_handler(ws):
    """Handle the Godot editor's WebSocket connection; route replies to pending calls."""
    global _editor_ws
    _editor_ws = ws
    print(f"[godot-mcp] editor connected: {ws.remote_address}", flush=True)
    try:
        async for raw in ws:
            try:
                msg = json.loads(raw)
            except (ValueError, TypeError):
                continue
            fut = _pending.pop(str(msg.get("id")), None)
            if fut is not None and not fut.done():
                fut.set_result(msg)
    except websockets.ConnectionClosed:
        pass
    finally:
        if _editor_ws is ws:
            _editor_ws = None
        print("[godot-mcp] editor disconnected", flush=True)


async def _call_editor(method: str, params: dict | None = None):
    """Send a request to the editor and await its correlated reply."""
    if _editor_ws is None:
        raise RuntimeError(
            "Godot editor is not connected. Open this project in Godot 4.7 with the "
            "'Godot MCP Bridge' plugin enabled (Project > Project Settings > Plugins)."
        )
    rid = str(next(_ids))
    loop = asyncio.get_running_loop()
    fut: asyncio.Future = loop.create_future()
    _pending[rid] = fut
    await _editor_ws.send(json.dumps({"id": rid, "method": method, "params": params or {}}))
    try:
        msg = await asyncio.wait_for(fut, CALL_TIMEOUT)
    except asyncio.TimeoutError:
        _pending.pop(rid, None)
        raise RuntimeError(f"Timed out after {CALL_TIMEOUT}s waiting for the Godot editor.")
    if isinstance(msg, dict) and msg.get("error"):
        err = msg["error"]
        raise RuntimeError(err.get("message", str(err)) if isinstance(err, dict) else str(err))
    return msg.get("result") if isinstance(msg, dict) else None


@asynccontextmanager
async def _lifespan(_server):
    try:
        ws_server = await websockets.serve(_ws_handler, HOST, PORT, max_size=MAX_MSG)
    except OSError as e:
        # Fail fast and loud rather than dying on a cryptic traceback — and never silently
        # move to another port (the editor + clients dial a fixed one; a silent move just
        # makes everything look configured while nothing connects).
        print(
            f"[godot-mcp] FATAL: could not bind the editor WebSocket on {HOST}:{PORT} ({e}). "
            f"Likely another godot server is already running on that port, or it's taken "
            f"(Windows NahimicService squats on 9080). Pick a free port: set GODOT_MCP_PORT and "
            f"match it in your project's [mcp] bridge/port.",
            flush=True,
        )
        raise
    print(f"[godot-mcp] listening for the Godot editor on ws://{HOST}:{PORT}", flush=True)
    try:
        yield
    finally:
        ws_server.close()
        await ws_server.wait_closed()


mcp = FastMCP("godot", lifespan=_lifespan)


# =================================== read tools ===================================

@mcp.tool()
async def ping() -> dict:
    """Health check: confirm the Godot editor bridge is connected and responsive."""
    return await _call_editor("ping")


@mcp.tool()
async def get_project_info() -> dict:
    """Get the open project's name, Godot version, main scene, and absolute path."""
    return await _call_editor("get_project_info")


@mcp.tool()
async def get_scene_tree() -> dict:
    """Get the node hierarchy (name, type, path, script, children) of the currently edited scene."""
    return await _call_editor("get_scene_tree")


@mcp.tool()
async def list_open_scenes() -> dict:
    """List the file paths of all scenes currently open in the editor."""
    return await _call_editor("list_open_scenes")


@mcp.tool()
async def get_node_property(path: str, property: str) -> dict:
    """Read a single `property` from the node at `path` (relative to the edited scene root; '.' = root)."""
    return await _call_editor("get_node_property", {"path": path, "property": property})


# ============================ scene / node mutation tools ============================
# All mutations are undoable via Godot's EditorUndoRedoManager (Ctrl+Z in the editor).

@mcp.tool()
async def open_scene(path: str) -> dict:
    """Open the scene at `path` (e.g. 'res://main.tscn') in the editor.

    Note: if the scene is already open this only focuses its tab — it does NOT re-read disk
    (the result's `already_open`/`note` flag this). Use reload_scene_from_disk to load on-disk edits.
    """
    return await _call_editor("open_scene", {"path": path})


@mcp.tool()
async def reload_scene_from_disk(path: str = "") -> dict:
    """Reload an already-open scene from disk, discarding the editor's in-memory copy.

    Use this after editing a .tscn directly on disk: otherwise the editor keeps its stale
    in-memory version and silently overwrites your edits on the next save/play. Defaults to
    the currently edited scene when `path` is empty. The scene must already be open.
    """
    return await _call_editor("reload_scene_from_disk", {"path": path})


@mcp.tool()
async def save_scene() -> dict:
    """Save the currently edited scene."""
    return await _call_editor("save_scene")


@mcp.tool()
async def create_node(type: str, name: str, parent: str = ".") -> dict:
    """Create a node of class `type` named `name` under `parent` (node path; '.' = scene root).

    Example: create_node(type="Node3D", name="Player", parent=".")
    """
    return await _call_editor("create_node", {"type": type, "name": name, "parent": parent})


@mcp.tool()
async def set_node_property(path: str, property: str, value) -> dict:
    """Set `property` on the node at `path` to `value`.

    Arrays of 2-4 numbers automatically coerce to Vector2/3/4 or Color based on the
    property's current type, e.g. set_node_property("Player", "position", [0, 1, 0]).

    For Object/Resource-typed properties (texture, material, mesh, …), pass a res:// or
    uid:// path as `value` — it is loaded via ResourceLoader and the write is verified.
    A bad/unloadable path or a type mismatch returns an error (no false-positive success).
    Pass "" to clear a resource property. See also set_sprite_texture for the common case.
    """
    return await _call_editor("set_node_property", {"path": path, "property": property, "value": value})


@mcp.tool()
async def set_sprite_texture(node_path: str, texture_path: str, property: str = "texture") -> dict:
    """Put an image/texture on a sprite-like node in one call (Sprite2D/Sprite3D/TextureRect/…).

    `texture_path` is a res:// or uid:// path; it is loaded and assigned to `property`
    (default "texture"), undoably and with the assignment verified. Collapses the usual
    download → import → set dance into a single step. If the image was just written to disk,
    call refresh_filesystem(wait=true, paths=[texture_path]) first so it's imported.
    """
    return await _call_editor("set_sprite_texture",
                              {"path": node_path, "texture_path": texture_path, "property": property})


@mcp.tool()
async def delete_node(path: str) -> dict:
    """Delete the node at `path` from the edited scene."""
    return await _call_editor("delete_node", {"path": path})


@mcp.tool()
async def reparent_node(path: str, new_parent: str) -> dict:
    """Move the node at `path` to become a child of `new_parent`."""
    return await _call_editor("reparent_node", {"path": path, "new_parent": new_parent})


# =================================== run / play tools ===================================

@mcp.tool()
async def run_project() -> dict:
    """Run the project's main scene in the editor."""
    return await _call_editor("run_project")


@mcp.tool()
async def play_scene(path: str) -> dict:
    """Run a specific scene file `path` in the editor."""
    return await _call_editor("play_scene", {"path": path})


@mcp.tool()
async def stop_project() -> dict:
    """Stop the currently running scene."""
    return await _call_editor("stop_project")


# ============================ scripts & instancing tools ============================

@mcp.tool()
async def read_script(path: str) -> dict:
    """Read the full text of a script file (e.g. 'res://player.gd')."""
    return await _call_editor("read_script", {"path": path})


@mcp.tool()
async def create_script(
    path: str,
    content: str = "",
    base_class: str = "Node",
    attach_to: str = "",
    overwrite: bool = False,
) -> dict:
    """Create a new GDScript at `path` (must be a res:// path ending in .gd).

    If `content` is empty, a stub extending `base_class` is written. Optionally
    `attach_to` a node (path in the edited scene). Set `overwrite=True` to replace.
    """
    return await _call_editor("create_script", {
        "path": path, "content": content, "base_class": base_class,
        "attach_to": attach_to, "overwrite": overwrite,
    })


@mcp.tool()
async def edit_script(
    path: str,
    content: str | None = None,
    find: str | None = None,
    replace: str | None = None,
) -> dict:
    """Edit an existing script. Either pass full `content`, or a `find`/`replace` pair
    for a targeted change. Check for parse errors afterward via `read_log`.
    """
    params: dict = {"path": path}
    if content is not None:
        params["content"] = content
    if find is not None:
        params["find"] = find
    if replace is not None:
        params["replace"] = replace
    return await _call_editor("edit_script", params)


@mcp.tool()
async def attach_script(node_path: str, script_path: str) -> dict:
    """Attach an existing script (`script_path`) to the node at `node_path`. Undoable."""
    return await _call_editor("attach_script", {"path": node_path, "script_path": script_path})


@mcp.tool()
async def instance_scene(scene_path: str, parent: str = ".", name: str = "") -> dict:
    """Instance a PackedScene (`scene_path`, e.g. 'res://enemy.tscn') under `parent`. Undoable."""
    return await _call_editor("instance_scene", {"scene_path": scene_path, "parent": parent, "name": name})


# ================================ view & logging tools ================================

@mcp.tool()
async def screenshot(which: str = "auto", max_width: int = 1280) -> Image:
    """Capture a viewport as a PNG.

    `which`:
      - 'auto' (default): capture whichever editor panel is currently active (2D
        canvas or 3D viewport); falls back to the project's "mcp/screenshot/default".
      - '2d': force the 2D canvas viewport.
      - '3d': force the 3D viewport.
      - 'game': capture the RUNNING game window (what actually renders at runtime), not the
        editor. First use installs a tiny 'MCPGameCapture' autoload and asks you to (re)start
        the game; subsequent calls return the live frame. Requires a running project.
    """
    res = await _call_editor("screenshot", {"which": which, "max_width": max_width})
    return Image(data=base64.b64decode(res["base64"]), format="png")


@mcp.tool()
async def read_log(limit: int = 100) -> dict:
    """Read the last `limit` lines of Godot's newest log file (user://logs) — includes
    errors and prints from the editor and the most recent run. Requires file logging
    (on by default). The editor's live Output panel has no read API, so this is the
    closest equivalent.
    """
    return await _call_editor("read_log", {"limit": limit})


# ============================ project & scene authoring tools ============================

@mcp.tool()
async def create_scene(
    path: str,
    root_type: str = "Node",
    name: str = "",
    open_in_editor: bool = True,
    overwrite: bool = False,
) -> dict:
    """Create a new scene file at `path` (res:// path ending in .tscn) with a `root_type`
    root node, and open it in the editor. This is how you start a scene from scratch —
    `create_node` needs a scene open first. Not undoable (it writes a file).
    """
    return await _call_editor("create_scene", {
        "path": path, "root_type": root_type, "name": name,
        "open": open_in_editor, "overwrite": overwrite,
    })


@mcp.tool()
async def refresh_filesystem(
    wait: bool = False,
    paths: list[str] | None = None,
    timeout_ms: int = 15000,
) -> dict:
    """Rescan res:// so the editor notices files changed/added/removed on disk (e.g. after
    direct file edits) and reimports as needed. Use this to bridge plain file editing and
    the live editor.

    By default the rescan/reimport runs in the background. Pass `wait=True` to block until it
    finishes (yields editor frames, doesn't freeze it), and optionally `paths` — a list of
    res:// resources to wait for — to get a per-path `ready` map confirming the import landed
    (so you don't have to poll .godot/imported/*.ctex yourself). Bounded by `timeout_ms`.
    """
    return await _call_editor(
        "refresh_filesystem",
        {"wait": wait, "paths": paths or [], "timeout_ms": timeout_ms},
    )


@mcp.tool()
async def set_main_scene(path: str) -> dict:
    """Set the project's main scene (the run target). Pass '' to clear it. Persists to
    project.godot so `run_project` launches the right scene.
    """
    return await _call_editor("set_main_scene", {"path": path})


@mcp.tool()
async def validate_script(path: str) -> dict:
    """Check whether the GDScript at `path` parses/compiles. Returns valid=true/false;
    on failure call `read_log` for the error detail. Use after `create_script`/`edit_script`.
    """
    return await _call_editor("validate_script", {"path": path})


@mcp.tool()
async def reload_bridge() -> dict:
    """Hot-reload the in-editor command router so newly added/changed tool handlers go live
    without disabling/re-enabling the plugin. The bridge also auto-reloads command_router.gd
    on change (~1s), so this is a manual backstop. (Editing mcp_bridge.gd/poller.gd themselves
    still needs a plugin toggle.)
    """
    return await _call_editor("reload_bridge")


# ============================ signals, search, settings tools ============================

@mcp.tool()
async def list_signals(path: str = ".") -> dict:
    """List the signals of the node at `path` (relative to the edited scene root), with their
    argument names and any existing connections.
    """
    return await _call_editor("list_signals", {"path": path})


@mcp.tool()
async def connect_signal(from_node: str, signal: str, to_node: str, method: str) -> dict:
    """Connect `signal` on `from_node` to `method` on `to_node` (both node paths in the edited
    scene). The connection is persisted into the scene and is undoable.
    """
    return await _call_editor("connect_signal",
                              {"from": from_node, "signal": signal, "to": to_node, "method": method})


@mcp.tool()
async def search_nodes(query: str, by: str = "name", limit: int = 200) -> dict:
    """Find nodes in the edited scene. by='name' (case-insensitive substring match) or
    by='type' (is-a match, e.g. 'Node3D' matches Camera3D).
    """
    return await _call_editor("search_nodes", {"query": query, "by": by, "limit": limit})


@mcp.tool()
async def get_project_settings(setting: str = "", prefix: str = "") -> dict:
    """Read project settings. Pass `setting` for one key (e.g. 'application/config/name'), or
    `prefix` to filter a group (e.g. 'application/').
    """
    return await _call_editor("get_project_settings", {"setting": setting, "prefix": prefix})


@mcp.tool()
async def set_project_settings(setting: str, value) -> dict:
    """Set a project setting and persist it to project.godot. Arrays of 2-4 numbers coerce to
    Vector/Color based on the existing value's type.
    """
    return await _call_editor("set_project_settings", {"setting": setting, "value": value})


@mcp.tool()
async def is_plugin_enabled(name: str) -> dict:
    """Check whether the editor plugin in res://addons/<name>/ is enabled. `name` is the addon
    *folder* name (e.g. 'godot_mcp', 'loopmodeler').
    """
    return await _call_editor("is_plugin_enabled", {"name": name})


@mcp.tool()
async def set_plugin_enabled(name: str, enabled: bool) -> dict:
    """Enable or disable the editor plugin in res://addons/<name>/ (addon folder name).

    Refuses to disable the MCP bridge itself (that would drop this connection with nothing left
    to re-enable it) — use reload_plugin to cycle the bridge.
    """
    return await _call_editor("set_plugin_enabled", {"name": name, "enabled": enabled})


@mcp.tool()
async def reload_plugin(name: str) -> dict:
    """Disable then re-enable the plugin in res://addons/<name>/, forcing its EditorPlugin scripts
    to reload — the one thing reload_bridge can't do (reload_bridge only refreshes
    command_router.gd; the running plugin still holds mcp_bridge.gd/poller.gd).

    Reliable for other plugins. For the MCP bridge itself it self-reloads: you DO get a normal
    success reply, then the connection briefly drops and reconnects (~1-2s) — wait a moment before
    the next godot tool call. (Small risk it lands disabled if the deferred re-enable misfires;
    re-enable manually in Project Settings > Plugins if so.)
    """
    return await _call_editor("reload_plugin", {"name": name})


@mcp.tool()
async def run_in_editor(expression: str) -> dict:
    """Evaluate a GDScript Expression in the editor (base instance = edited scene root) and
    return the value. DISABLED by default — enable by setting ALLOW_EVAL=true in
    command_router.gd. Security-sensitive: uses the sandboxed Expression class (not arbitrary
    GDScript), but still gate it deliberately.
    """
    return await _call_editor("run_in_editor", {"expression": expression})


if __name__ == "__main__":
    # When auto-started by the editor, tie our lifetime to it so we never orphan.
    _parent = os.environ.get("GODOT_MCP_PARENT_PID", "")
    if _parent.isdigit():
        _watch_parent(int(_parent))

    # Transport selection:
    #   stdio (default)         — the MCP client spawns this server; one client per process.
    #   streamable-http / http  — run ONE long-lived server that many MCP clients (Claude Code,
    #                             Codex, ...) connect to by URL, so they can drive the same editor
    #                             concurrently. The editor still connects to the WebSocket listener
    #                             started in _lifespan (GODOT_MCP_PORT), unchanged.
    transport = os.environ.get("GODOT_MCP_TRANSPORT", "stdio").lower()
    if transport in ("http", "streamable-http", "streamable_http"):
        mcp.settings.host = os.environ.get("GODOT_MCP_HTTP_HOST", "127.0.0.1")
        mcp.settings.port = int(os.environ.get("GODOT_MCP_HTTP_PORT", "9100"))
        # Plain JSON request/response, no session id — the most broadly compatible HTTP MCP mode.
        # FastMCP's default (SSE responses + a required `text/event-stream` Accept + session-id
        # tracking) trips up stricter clients (e.g. Codex's handshake). Safe here: every tool is a
        # synchronous request/response with no server-initiated streaming.
        mcp.settings.json_response = True
        mcp.settings.stateless_http = True
        print(
            f"[godot-mcp] MCP over streamable-http at "
            f"http://{mcp.settings.host}:{mcp.settings.port}{mcp.settings.streamable_http_path} "
            f"(editor WebSocket on {HOST}:{PORT}) — point multiple clients at this URL",
            flush=True,
        )
        try:
            mcp.run(transport="streamable-http")
        except OSError as e:
            print(
                f"[godot-mcp] FATAL: could not bind the HTTP MCP port {mcp.settings.port} ({e}). "
                f"Set GODOT_MCP_HTTP_PORT to a free port.",
                flush=True,
            )
            raise
    else:
        mcp.run(transport="stdio")
