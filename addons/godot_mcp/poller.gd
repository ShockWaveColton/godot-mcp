@tool
extends Node

## A minimal @tool node whose _process() reliably fires in the editor.
## EditorPlugin's own _process is unreliable in-editor, so the bridge drives its
## per-frame socket polling from here instead.

var bridge  # set by mcp_bridge.gd before this node is added to the tree


func _ready() -> void:
	set_process(true)


func _process(delta: float) -> void:
	if is_instance_valid(bridge):
		bridge.poll(delta)
