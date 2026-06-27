@echo off
REM ── Shared Godot MCP server (HTTP mode) ───────────────────────────────────────
REM Run this ONCE, then point multiple MCP clients (Claude Code, Codex, ...) at
REM   http://127.0.0.1:9100/mcp  so they can drive the SAME editor concurrently.
REM (Default stdio mode spawns one server per client, which can't share the port.)
REM
REM   GODOT_MCP_PORT       = editor WebSocket port — must match [mcp] bridge/port in
REM                          your project.godot (or DEFAULT_PORT 9081 if unset there)
REM   GODOT_MCP_HTTP_PORT  = where MCP clients connect (the URL above)
REM
REM Stop any per-client (stdio) godot servers first — only one process can bind the WS port.
set GODOT_MCP_TRANSPORT=http
if "%GODOT_MCP_PORT%"==""      set GODOT_MCP_PORT=9081
if "%GODOT_MCP_HTTP_PORT%"=="" set GODOT_MCP_HTTP_PORT=9100
uv run --directory "%~dp0" server.py
