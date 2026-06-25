class_name Player
extends CharacterBody3D


# -------------------------------------------------------------------------- #
#  Exports
# -------------------------------------------------------------------------- #
@export_group("Movement")
@export var walk_speed: float = 5.0
@export var sprint_speed: float = 8.0
@export var acceleration: float = 10.0
@export var deceleration: float = 10.0
@export var jump_velocity: float = 4.5
@export var air_control: float = 0.3

@export_group("Dash")
@export var dash_speed: float = 22.0
@export var dash_cooldown: float = 0.8

@export_group("Mouse Look")
@export var mouse_sensitivity: float = 0.002
@export var invert_y: bool = false
@export var pitch_limit_degrees: float = 90.0

@export_group("Headbob")
@export var headbob_enabled: bool = true
@export var headbob_frequency: float = 2.0
@export var headbob_amplitude: Vector2 = Vector2(0.02, 0.04)


# -------------------------------------------------------------------------- #
#  Node references
# -------------------------------------------------------------------------- #
@onready var _cam_holder: Node3D = $CamHolder
@onready var _camera: Camera3D = $CamHolder/Camera3D


# -------------------------------------------------------------------------- #
#  Signals
# -------------------------------------------------------------------------- #
signal mouse_capture_changed(captured: bool)


# -------------------------------------------------------------------------- #
#  State
# -------------------------------------------------------------------------- #
var _mouse_rotation: Vector2
var _headbob_timer: float
var _headbob_rest: Vector3

var _input_vector: Vector2
var _wants_jump: bool
var _wants_sprint: bool
var _dash_cooldown_timer: float = 0.0

var _movement_component: Node


# -------------------------------------------------------------------------- #
#  Lifecycle
# -------------------------------------------------------------------------- #
func _ready() -> void:
	if _cam_holder:
		_headbob_rest = _cam_holder.position

	for child in get_children():
		if child is NetworkedMovementComponent:
			_movement_component = child
			break

	if not Engine.is_editor_hint() and is_multiplayer_authority():
		_camera.current = true
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return
	if not is_multiplayer_authority():
		return
	if event.is_action_pressed(&"ui_cancel"):
		var captured := Input.mouse_mode != Input.MOUSE_MODE_CAPTURED
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if captured else Input.MOUSE_MODE_VISIBLE
		mouse_capture_changed.emit(captured)
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_mouse_rotation.x -= event.relative.x * mouse_sensitivity
		_mouse_rotation.y -= event.relative.y * mouse_sensitivity * (-1.0 if invert_y else 1.0)
		_mouse_rotation.y = clampf(
			_mouse_rotation.y,
			deg_to_rad(-pitch_limit_degrees),
			deg_to_rad(pitch_limit_degrees),
		)

		rotation.y = _mouse_rotation.x
		_cam_holder.rotation.x = _mouse_rotation.y


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if not is_multiplayer_authority():
		return

	_input_vector = Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_back")
	_wants_sprint = Input.is_action_pressed(&"sprint")
	if Input.is_action_just_pressed(&"jump"):
		_wants_jump = true

	_dash_cooldown_timer = maxf(_dash_cooldown_timer - delta, 0.0)

	if Input.is_action_just_pressed(&"latency_1"):
		_set_simulated_latency(100.0)
	elif Input.is_action_just_pressed(&"latency_2"):
		_set_simulated_latency(150.0)
	elif Input.is_action_just_pressed(&"latency_3"):
		_set_simulated_latency(200.0)
	elif Input.is_action_just_pressed(&"latency_4"):
		_set_simulated_latency(0.0)

	if headbob_enabled and _cam_holder:
		_update_headbob(delta)


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return

	if is_instance_valid(_movement_component):
		_movement_component.process_tick(delta)
	elif is_multiplayer_authority():
		var snap := get_input_snapshot(0)
		apply_net_movement(snap, delta)


# -------------------------------------------------------------------------- #
#  Input interface  (called by NetworkedMovementComponent)
# -------------------------------------------------------------------------- #
func get_input_snapshot(tick: int) -> InputSnapshot:
	var snap := InputSnapshot.new()
	snap.tick = tick
	snap.input_vector = _input_vector
	snap.camera_yaw = _mouse_rotation.x
	snap.camera_pitch = _mouse_rotation.y
	snap.actions[&"jump"] = _wants_jump
	snap.actions[&"sprint"] = _wants_sprint
	snap.actions[&"dash"] = Input.is_action_just_pressed(&"dash") and _dash_cooldown_timer <= 0.0
	_wants_jump = false
	return snap


# -------------------------------------------------------------------------- #
#  Movement interface  (called by NetworkedMovementComponent)
# -------------------------------------------------------------------------- #
func apply_net_movement(snap: InputSnapshot, _delta: float) -> void:
	rotation.y = snap.camera_yaw
	if _cam_holder:
		_cam_holder.rotation.x = snap.camera_pitch

	var input_dir := snap.input_vector
	if input_dir.length_squared() > 1.0:
		input_dir = input_dir.normalized()

	var sprinting: bool = snap.actions.get(&"sprint", false)
	var target_speed := sprint_speed if sprinting else walk_speed

	var wish_dir := Vector3.ZERO
	if input_dir != Vector2.ZERO:
		var forward_dir := -transform.basis.z
		var right := transform.basis.x
		forward_dir.y = 0.0
		right.y = 0.0
		forward_dir = forward_dir.normalized()
		right = right.normalized()
		wish_dir = forward_dir * (-input_dir.y) + right * input_dir.x

	var on_floor := is_on_floor()
	var is_dashing := false

	# Dash — one-frame velocity burst
	if snap.actions.get(&"dash", false) and on_floor:
		var dash_dir := wish_dir if wish_dir != Vector3.ZERO else (-transform.basis.z)
		velocity.x = dash_dir.x * dash_speed
		velocity.z = dash_dir.z * dash_speed
		is_dashing = true
		_dash_cooldown_timer = dash_cooldown

	var accel := acceleration if on_floor else acceleration * air_control
	var decel := deceleration if on_floor else deceleration * air_control

	# Horizontal velocity
	var h_vel := Vector3(velocity.x, 0.0, velocity.z)

	if not is_dashing:
		if wish_dir != Vector3.ZERO:
			var cur_speed := h_vel.dot(wish_dir)
			var add := clampf(target_speed - cur_speed, 0.0, accel * _delta)
			h_vel += wish_dir * add
		else:
			var cur_speed := h_vel.length()
			var reduce := minf(cur_speed, decel * _delta)
			if cur_speed > 0.0001:
				h_vel *= (cur_speed - reduce) / cur_speed
			else:
				h_vel = Vector3.ZERO

	# Clamp horizontal
	if not is_dashing:
		var h_speed := h_vel.length()
		if h_speed > target_speed:
			h_vel *= target_speed / h_speed

	velocity.x = h_vel.x
	velocity.z = h_vel.z

	# Gravity
	if not on_floor:
		velocity.y -= ProjectSettings.get_setting(&"physics/3d/default_gravity", 9.8) * _delta

	# Jump
	if on_floor and snap.actions.get(&"jump", false):
		velocity.y = jump_velocity

	move_and_slide()


# -------------------------------------------------------------------------- #
#  Network state reset  (called by NetworkedMovementComponent on hard snap)
# -------------------------------------------------------------------------- #
func reset_net_state() -> void:
	_dash_cooldown_timer = 0.0


# -------------------------------------------------------------------------- #
#  Headbob
# -------------------------------------------------------------------------- #
func _update_headbob(delta: float) -> void:
	var speed := Vector3(velocity.x, 0.0, velocity.z).length()
	if speed > 0.1 and is_on_floor():
		_headbob_timer += speed * delta * headbob_frequency
		var x := sin(_headbob_timer) * headbob_amplitude.x
		var y := sin(_headbob_timer * 2.0) * headbob_amplitude.y
		_cam_holder.position = _headbob_rest + Vector3(x, y, 0.0)
	else:
		_headbob_timer = 0.0
		_cam_holder.position = _cam_holder.position.lerp(
			_headbob_rest,
			delta * headbob_frequency * 5.0,
		)


func _set_simulated_latency(ms: float) -> void:
	var gm := get_node_or_null("/root/GameManager")
	if gm:
		gm.simulated_latency_ms = ms
