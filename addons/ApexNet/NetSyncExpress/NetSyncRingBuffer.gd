class_name NetSyncRingBuffer
extends RefCounted


var _buf: Array = []
var _cap: int
var _start: int = 0
var _count: int = 0


func _init(capacity: int) -> void:
	_cap = maxi(capacity, 1)
	_buf.resize(_cap)


func push(item) -> void:
	var idx: int = (_start + _count) % _cap
	_buf[idx] = item
	if _count == _cap:
		_start = (_start + 1) % _cap
	else:
		_count += 1


func get_at(idx: int):
	if idx < 0 or idx >= _count:
		return null
	return _buf[(_start + idx) % _cap]


func latest():
	if _count == 0:
		return null
	return get_at(_count - 1)


func oldest():
	if _count == 0:
		return null
	return get_at(0)


func find_tick(tick: int) -> int:
	for i in range(_count):
		var item = get_at(i)
		if item != null and item.tick == tick:
			return i
	return -1


func clear() -> void:
	_start = 0
	_count = 0


func get_count() -> int:
	return _count


func get_capacity() -> int:
	return _cap
