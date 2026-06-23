class_name InputSnapshot
extends RefCounted


var tick: int
var input_vector: Vector2
var camera_yaw: float
var camera_pitch: float
var actions: Dictionary = {}


func to_variant() -> Dictionary:
	return {
		"t": tick,
		"v": [input_vector.x, input_vector.y],
		"y": camera_yaw,
		"p": camera_pitch,
		"a": actions.duplicate(),
	}


static func from_variant(data: Dictionary) -> InputSnapshot:
	var snap := InputSnapshot.new()
	snap.tick = data.get("t", 0)
	var v: Array = data.get("v", [0.0, 0.0])
	snap.input_vector = Vector2(v[0], v[1])
	snap.camera_yaw = data.get("y", 0.0)
	snap.camera_pitch = data.get("p", 0.0)
	snap.actions = data.get("a", {}).duplicate()
	return snap
