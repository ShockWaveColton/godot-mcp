# Godot MCP Bridge

Drive the **Godot editor** from an MCP client (e.g. **Claude Code**) — inspect the scene
tree, create/edit/delete nodes, set properties, attach scripts, run the project, screenshot
the editor *or the running game* — all editor mutations undoable with **Ctrl+Z**.

It's the Godot equivalent of Unity MCP: a pure-GDScript `@tool` EditorPlugin talking to a
small Python (FastMCP) server over a localhost WebSocket.

```
Claude Code  <--stdio/MCP-->  mcp-server/server.py  <--ws://127.0.0.1:9081-->  addons/godot_mcp (in-editor @tool plugin)
```

The Python server hosts the WebSocket listener; the Godot editor plugin connects out to it
as a client and reconnects automatically. Developed on **Godot 4.7**; the addon code is
**Godot 4.2+** compatible.

## Pieces

| Path | What it is |
|---|---|
| `addons/godot_mcp/` | The in-editor `@tool` EditorPlugin (pure GDScript) |
| `mcp-server/server.py` | The MCP server (Python + FastMCP) that the MCP client launches |
| `.mcp.json` | Tells a project-scoped MCP client (Claude Code) how to launch the server |

## Install into your project

1. **Copy the addon in.** Drop `addons/godot_mcp/` into your Godot project's `addons/`
   folder, and put `mcp-server/` and `.mcp.json` somewhere your MCP client can reach (the
   project root is simplest — that's what `.mcp.json`'s relative `--directory mcp-server`
   assumes; adjust that path if you place it elsewhere).

2. **Enable the Godot plugin.** **Project → Project Settings → Plugins** → toggle
   **"Godot MCP Bridge"** on. The **Output** panel shows:
   ```
   [godot-mcp] bridge enabled; connecting to ws://127.0.0.1:9081
   ```
   It retries until the server is up — that's expected.

3. **Register the server with your MCP client.** With the project-scoped `.mcp.json` in
   place, Claude Code picks it up automatically; run `/mcp` to confirm `godot` is connected.
   Manual equivalent:
   ```
   claude mcp add godot -- uv run --directory mcp-server server.py
   ```
   [`uv`](https://docs.astral.sh/uv/) resolves and installs `mcp` + `websockets` on first run.

## Smoke test

With the editor open on a scene and the plugin enabled, ask the agent:

1. Call `ping` → expects `{ "pong": true, "godot_version": "4.x" }`.
2. Get the scene tree → returns the node hierarchy.
3. "Create a `Node3D` named `TestNode` under the root, set its position to `[0, 1, 0]`."
4. Look in the **Scene** dock — `TestNode` is there. Press **Ctrl+Z** — it's gone.

If `ping` errors with *"editor not connected"*, the plugin isn't enabled or the editor isn't
open. If a tool times out, check the Godot **Output** panel.

## Running multiple clients at once (shared HTTP server)

By default each MCP client spawns its own `server.py` over stdio — and since the server binds
the editor WebSocket port, only **one** client can run at a time. To let several clients (e.g.
Claude Code **and** Codex) drive the same editor concurrently, run **one** shared server in
HTTP mode and point them all at its URL:

1. Stop any per-client (stdio) godot servers (close those sessions) so the WS port is free.
2. Start the shared server once — `mcp-server\serve-http.bat` (editor WS on `GODOT_MCP_PORT`,
   MCP served on `GODOT_MCP_HTTP_PORT`, default `9100`). Equivalent manual command:
   ```
   GODOT_MCP_TRANSPORT=http GODOT_MCP_PORT=9081 GODOT_MCP_HTTP_PORT=9100 uv run --directory mcp-server server.py
   ```
3. Point each client at the URL instead of spawning:
   - **Claude Code** `.mcp.json`:
     ```json
     { "mcpServers": { "godot": { "type": "http", "url": "http://127.0.0.1:9100/mcp" } } }
     ```
   - **Codex** `~/.codex/config.toml`:
     ```toml
     [mcp_servers.godot]
     url = "http://127.0.0.1:9100/mcp"

     [features]
     rmcp_client = true   # Codex needs this for HTTP-transport MCP servers
     ```

The shared server keeps the single editor connection; requests from all clients are correlated
by id and serialized through the editor's main thread (editor APIs are single-threaded anyway).
Bonus: the server outlives client restarts, so reconnects are seamless. Set `GODOT_MCP_PORT` to
match your project's `[mcp] bridge/port`.

## Tools (37)

**Read:** `ping`, `get_project_info`, `get_scene_tree`, `list_open_scenes`,
`get_node_property`, `read_script`, `read_log`, `screenshot`, `list_signals`, `search_nodes`,
`get_project_settings`.

**Scene / node (undoable):** `open_scene`, `reload_scene_from_disk`, `save_scene`,
`create_node`, `set_node_property`, `set_sprite_texture`, `delete_node`, `reparent_node`,
`instance_scene`, `connect_signal`.

**Scripts:** `create_script`, `edit_script`, `attach_script`, `validate_script`.

**Project / authoring:** `create_scene` (make a new scene + open it — needed before
`create_node` works), `refresh_filesystem` (rescan res:// after direct file edits),
`set_main_scene`, `set_project_settings`.

**Run:** `run_project`, `play_scene`, `stop_project`.

**Bridge / meta:** `reload_bridge` (hot-reload the in-editor `command_router.gd` so new tool
handlers go live without a plugin toggle — the bridge also auto-reloads it on change, ~1s),
`is_plugin_enabled`, `set_plugin_enabled`, `reload_plugin` (cycle any addon to reload its
EditorPlugin scripts; see below).

**Gated (off by default):** `run_in_editor` — evaluate a sandboxed GDScript `Expression`.
Disabled until you set `ALLOW_EVAL = true` in `addons/godot_mcp/command_router.gd`.

### Notable behaviors

- **Resource-typed properties.** `set_node_property` (and the `set_sprite_texture` shortcut)
  accept a `res://`/`uid://` path for Object/Resource properties (texture, material, mesh, …):
  the path is loaded via `ResourceLoader`, type-checked, and the write is **verified** — a bad
  path or type mismatch returns an error instead of a false-positive success. Pass `""` to clear.
- **`screenshot(which="game")`** captures the *running* project window (what actually renders
  at runtime), not the editor. The editor can't read another process's framebuffer, so the
  first call installs a tiny inert `MCPGameCapture` autoload and asks you to (re)start the game;
  thereafter the running game answers capture requests over `user://`. `which` is otherwise
  `auto` (default), `2d`, or `3d`. If an editor capture is blank, the viewport hasn't rendered.
- **`reload_scene_from_disk`** re-reads an open scene from disk, discarding the editor's
  in-memory copy. Use it after editing a `.tscn` directly on disk — otherwise the editor keeps
  its stale copy and silently overwrites your edits on the next save. (`open_scene` on an
  already-open scene only focuses the tab; it does *not* re-read disk.)
- **`refresh_filesystem(wait=true, paths=[...])`** blocks until the rescan/reimport settles
  (yielding editor frames, never freezing it) and returns a per-path `ready` map — no need to
  poll `.godot/imported/*.ctex` after writing PNGs.
- **`read_log`** returns the tail of the newest `user://logs` file (editor + last run). The
  editor's live **Output** panel has no read API, so this is the closest equivalent; it needs
  file logging (on by default on desktop).
- **`edit_script`** takes either full `content` or a `find`/`replace` pair. After any script
  change, call `read_log` (or `validate_script`) to check for parse/compile errors.
- **`reload_plugin(name)`** disables then re-enables an addon so its `EditorPlugin` scripts
  reload — the one thing `reload_bridge` can't do (it only refreshes `command_router.gd`; the
  running plugin still holds `mcp_bridge.gd`/`poller.gd`). Reliable for other plugins. For the
  bridge itself it self-cycles: you get a normal reply, then the connection briefly drops and
  reconnects (~1-2s) — wait a moment before the next call. (`set_plugin_enabled` refuses to
  disable the bridge directly, since that would strand the connection.)

## Extending it

Add a capability in two places:

1. **`mcp-server/server.py`** — a new `@mcp.tool()` async function that calls
   `await _call_editor("<method>", { ...params })`.
2. **`addons/godot_mcp/command_router.gd`** — add `"<method>": _my_handler(params)` to the
   `match` in `dispatch()`, and implement `_my_handler`. Wrap any scene mutation in
   `_plugin.get_undo_redo().create_action(...) / commit_action()` so it stays undoable. A
   handler may be a coroutine (use `await`); add it as `return await _my_handler(params)` and
   the bridge awaits dispatch for you.

`command_router.gd` hot-reloads on change (~1s) so editor-side handlers go live without a
plugin toggle; the MCP client relaunches `server.py` to register new Python tools. Edits to
`mcp_bridge.gd`/`poller.gd` themselves need a plugin disable→re-enable.

## Security notes (read before exposing beyond localhost)

- The server binds **127.0.0.1 only**. Don't set `GODOT_MCP_HOST` to `0.0.0.0` without adding
  authentication.
- There is **no auth token** in this v1 — loopback is the only barrier. A malicious local
  process (or a browser DNS-rebinding attack) could reach the port. Before non-trivial use, add
  a shared-secret check on connect.
- This v1 deliberately ships **no arbitrary-code-execution tool** (`run_in_editor` is sandboxed
  via `Expression` *and* gated off). The editor has full filesystem/OS access — don't add a raw
  "run this GDScript" tool casually; if you do, gate it behind an opt-in flag + confirmation.
- All editor mutations are undoable — that's your safety net. Keep it that way.

## Config (env vars on the server)

| Var | Default | Meaning |
|---|---|---|
| `GODOT_MCP_HOST` | `127.0.0.1` | WebSocket bind address (keep loopback) |
| `GODOT_MCP_PORT` | `9081` | WebSocket port (must match `mcp/bridge/port` / `DEFAULT_PORT` in `mcp_bridge.gd`) |
| `GODOT_MCP_TIMEOUT` | `30` | Seconds to wait for an editor reply |
| `GODOT_MCP_MAX_MSG` | `33554432` | Max WebSocket message bytes (32 MiB) for screenshots/large payloads |
| `GODOT_MCP_TRANSPORT` | `stdio` | `stdio` (spawned per client) or `http` (one shared server many clients connect to) |
| `GODOT_MCP_HTTP_PORT` | `9100` | HTTP-mode port clients connect to (`http://HOST:PORT/mcp`) |

Per-project port override: set `mcp/bridge/port` in Project Settings and match `GODOT_MCP_PORT`
in `.mcp.json` — lets a 2D and a 3D editor run side-by-side on different ports.

## Troubleshooting

- **`uv` install fails on Python 3.14** — `pyproject.toml` pins `<3.14`; uv auto-fetches a
  managed 3.13. Force it with `uv python install 3.13`.
- **Plugin enabled but never connects** — confirm the server is running (`/mcp` shows `godot`)
  and the port matches on both sides.
- **Port already in use / silently blocked** — change `GODOT_MCP_PORT` (in `.mcp.json`) and the
  port on the editor side to the same new value. The default is `9081`; it was moved off `9080`
  because Windows **NahimicService** (an audio-driver service) squats on `127.0.0.1:9080` with
  its own HTTP listener, silently blocking the bridge.
- **A large reply times out (e.g. `screenshot`)** — the message exceeded the WebSocket limits.
  The editor uses 16 MiB buffers (`MAX_BUFFER` in `mcp_bridge.gd`) and the server allows 32 MiB
  (`GODOT_MCP_MAX_MSG`); raise both. WebSocketPeer's default buffer is only 64 KiB, so these
  must be set or any non-trivial image silently fails to send.

## License

[MIT](LICENSE) © Colton McGrath.
