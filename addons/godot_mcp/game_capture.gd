extends Node

## MCP game-capture helper — autoload, injected into the project by the Godot MCP bridge
## the first time screenshot(which="game") is called.
##
## The editor process can't read the running game's framebuffer (separate OS process), so this
## node bridges the gap over the shared user:// directory: when the editor drops a request file,
## this captures the root viewport and writes back a PNG. That's what lets an agent verify what
## the game *actually renders at runtime*, not just the editor viewport.
##
## It is inert unless a request file appears, so leaving it installed is harmless. Remove the
## "MCPGameCapture" autoload in Project Settings to uninstall.

const REQ := "user://mcp_game_capture.req"
const OUT := "user://mcp_game_capture.png"
const DONE := "user://mcp_game_capture.done"


func _process(_delta: float) -> void:
	if not FileAccess.file_exists(REQ):
		return

	# Read the requested max width, then consume the request so we capture exactly once.
	var max_w := 0
	var rf := FileAccess.open(REQ, FileAccess.READ)
	if rf != null:
		max_w = int(rf.get_as_text().strip_edges())
		rf.close()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(REQ))

	# Capture after the frame is fully drawn so the image isn't empty/partial.
	await RenderingServer.frame_post_draw
	var img: Image = null
	var vp := get_viewport()
	if vp != null and vp.get_texture() != null:
		img = vp.get_texture().get_image()
	if img != null and not img.is_empty():
		if max_w > 0 and img.get_width() > max_w:
			var ratio := float(max_w) / float(img.get_width())
			img.resize(max_w, int(img.get_height() * ratio))
		img.save_png(OUT)

	# Signal completion last, so the editor only reads OUT once it exists.
	var df := FileAccess.open(DONE, FileAccess.WRITE)
	if df != null:
		df.store_string("1")
		df.close()
