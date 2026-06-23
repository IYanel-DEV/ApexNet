class_name StateSnapshot
extends RefCounted


var tick: int
var position: Vector3
var rotation: Vector3
var velocity: Vector3


func to_variant() -> Dictionary:
	return {
		"t": tick,
		"p": [position.x, position.y, position.z],
		"r": [rotation.x, rotation.y, rotation.z],
		"v": [velocity.x, velocity.y, velocity.z],
	}


static func from_variant(data: Dictionary) -> StateSnapshot:
	var snap := StateSnapshot.new()
	snap.tick = data.get("t", 0)
	snap.position = _v3(data.get("p", [0.0, 0.0, 0.0]))
	snap.rotation = _v3(data.get("r", [0.0, 0.0, 0.0]))
	snap.velocity = _v3(data.get("v", [0.0, 0.0, 0.0]))
	return snap


static func _v3(arr: Array) -> Vector3:
	return Vector3(arr[0], arr[1], arr[2])
