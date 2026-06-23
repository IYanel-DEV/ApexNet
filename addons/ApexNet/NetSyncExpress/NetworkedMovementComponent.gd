@tool
class_name NetworkedMovementComponent
extends Node


@export var enable_visual_debugger: bool = false

const BUFFER_SIZE := 128

# Reconciliation thresholds (meters)
const RECONCILIATION_THRESHOLD := 0.1
const TELEPORT_THRESHOLD := 5.0

var _client_tick: int = 0
var _server_tick: int = 0

var input_buffer: NetSyncRingBuffer
var state_buffer: NetSyncRingBuffer
var _ghost: VisualDebuggerGhost = null

# Server-side: queue of incoming InputSnapshots from remote clients
var server_pending_inputs: Array[InputSnapshot] = []
var _last_input: InputSnapshot = null

# Remote-interpolation: ordered server states for non-authority players
const INTERPOLATION_DELAY_TICKS := 6
var _interp_states: Array[StateSnapshot] = []
var _interp_highest_tick: int = 0


func _ready() -> void:
	input_buffer = NetSyncRingBuffer.new(BUFFER_SIZE)
	state_buffer = NetSyncRingBuffer.new(BUFFER_SIZE)

	if enable_visual_debugger and is_multiplayer_authority():
		_spawn_ghost()


func _spawn_ghost() -> void:
	var player := owner as Player
	if not player:
		return

	var ghost_scene: PackedScene = preload("res://addons/ApexNet/NetSyncExpress/VisualDebuggerGhost.tscn")
	_ghost = ghost_scene.instantiate() as VisualDebuggerGhost
	_ghost.top_level = true
	_ghost.setup_from_parent(player)
	add_child(_ghost)


func _get_game_manager() -> Node:
	return get_node_or_null("/root/GameManager")


# Called every physics frame from Player._physics_process on every peer.
# Behaviour depends on the role of this peer relative to this player:
#   authority  → sample input, predict locally, transmit to server
#                (host also broadcasts authoritative state directly)
#   server     → process pending inputs from remote clients, broadcast state
#   remote     → interpolate between server states for smooth movement
func process_tick(delta: float) -> void:
	var player := owner as Player
	if not player:
		return

	var is_server := multiplayer.get_unique_id() == 1

	if is_multiplayer_authority():
		# ── Authority path ──────────────────────────────────────────
		_client_tick += 1

		var snap := player.get_input_snapshot(_client_tick)
		input_buffer.push(snap)

		player.apply_movement(snap, delta)

		var st := StateSnapshot.new()
		st.tick = _client_tick
		st.position = player.global_position
		st.rotation = player.rotation
		st.velocity = player.velocity
		state_buffer.push(st)

		# Send input to the server for authoritative processing
		var gm := _get_game_manager()
		if gm:
			gm.send_with_latency(_send_input.rpc, [snap.to_variant()])
		else:
			_send_input.rpc(snap.to_variant())

		# Host is both authority and server — broadcast state directly
		if is_server:
			if gm:
				gm.send_with_latency(_receive_state.rpc, [st.to_variant()])
			else:
				_receive_state.rpc(st.to_variant())

	elif is_server:
		# ── Server path (for remote players whose authority is a client) ──
		_process_server_tick(delta)

	else:
		# ── Remote path ──
		_process_interpolation(delta)


# -------------------------------------------------------------------------- #
# Server reconciliation for the owning client
# -------------------------------------------------------------------------- #
func _reconcile(server_snap: StateSnapshot) -> void:
	var player := owner as Player
	if not player:
		return

	# Visual debugger: snap ghost to raw server position before reconciliation
	if _ghost:
		_ghost.snap_to(server_snap.position, server_snap.rotation)

	# 1. Find our predicted state at the server's tick
	var idx := state_buffer.find_tick(server_snap.tick)
	var predicted_snap: StateSnapshot = null

	if idx >= 0:
		predicted_snap = state_buffer.get_at(idx) as StateSnapshot
	else:
		# Tick evicted from ring buffer — soft-snap to server state
		_soft_apply(player, server_snap)
		return

	# 2. Error threshold check
	var error := predicted_snap.position.distance_to(server_snap.position)

	if error < RECONCILIATION_THRESHOLD:
		# Minor jitter — absorb with gentle lerp
		_soft_apply(player, server_snap)
		return

	if error > TELEPORT_THRESHOLD:
		# Teleport (respawn, etc.) — instant snap, skip replay
		_hard_snap(player, server_snap)
		return

	# 3. Hard reconciliation: rewind + replay
	_hard_rewind_and_replay(player, server_snap)


func _soft_apply(player: Player, target: StateSnapshot) -> void:
	var alpha := 0.25
	player.global_position = player.global_position.lerp(target.position, alpha)
	player.velocity = player.velocity.lerp(target.velocity, alpha)


func _hard_snap(player: Player, snap: StateSnapshot) -> void:
	player.global_position = snap.position
	player.velocity = snap.velocity
	player.rotation = snap.rotation


func _hard_rewind_and_replay(player: Player, server_snap: StateSnapshot) -> void:
	# 1. Hard rewind to authoritative server state
	_hard_snap(player, server_snap)

	# 2. Fast-forward: replay all inputs from server_tick + 1 to current client tick
	var dt := 1.0 / Engine.physics_ticks_per_second
	var replay_tick := server_snap.tick + 1

	while replay_tick <= _client_tick:
		var input_idx := input_buffer.find_tick(replay_tick)
		if input_idx >= 0:
			var historical_input := input_buffer.get_at(input_idx) as InputSnapshot
			player.apply_movement(historical_input, dt)
		replay_tick += 1

	# 3. Store the corrected prediction so future reconciliations compare accurately
	var corrected := StateSnapshot.new()
	corrected.tick = _client_tick
	corrected.position = player.global_position
	corrected.rotation = player.rotation
	corrected.velocity = player.velocity
	state_buffer.push(corrected)


# -------------------------------------------------------------------------- #
# Server-tick processing
# -------------------------------------------------------------------------- #
func _process_server_tick(delta: float) -> void:
	var player := owner as Player
	if not player:
		return

	_server_tick += 1

	var snap: InputSnapshot = null

	if server_pending_inputs.size() > 0:
		snap = server_pending_inputs.pop_front() as InputSnapshot
		_last_input = snap

	elif _last_input != null:
		# Packet-loss fallback: re-apply the last known input with
		# the current server tick so the client can detect the gap.
		snap = InputSnapshot.new()
		snap.tick = _server_tick
		snap.input_vector = _last_input.input_vector
		snap.camera_yaw = _last_input.camera_yaw
		snap.camera_pitch = _last_input.camera_pitch
		snap.actions = _last_input.actions.duplicate()

	if snap == null:
		return

	player.apply_movement(snap, delta)

	var st := StateSnapshot.new()
	st.tick = snap.tick
	st.position = player.global_position
	st.rotation = player.rotation
	st.velocity = player.velocity

	var gm := _get_game_manager()
	if gm:
		gm.send_with_latency(_receive_state.rpc, [st.to_variant()])
	else:
		_receive_state.rpc(st.to_variant())


# -------------------------------------------------------------------------- #
# RPC ─ called remotely by the owning client to deliver input to the server
# -------------------------------------------------------------------------- #
@rpc(&"any_peer", &"unreliable")
func _send_input(data: Dictionary) -> void:
	if multiplayer.get_unique_id() != 1:
		return

	var snap := InputSnapshot.from_variant(data)
	server_pending_inputs.append(snap)


# -------------------------------------------------------------------------- #
# RPC ─ called BY the server TO broadcast authoritative state to all peers
# -------------------------------------------------------------------------- #
@rpc(&"any_peer", &"unreliable")
func _receive_state(data: Dictionary) -> void:
	var snap := StateSnapshot.from_variant(data)

	if is_multiplayer_authority():
		_reconcile(snap)
		return

	# Remote path — push into interpolation buffer
	_interp_states.append(snap)
	if snap.tick > _interp_highest_tick:
		_interp_highest_tick = snap.tick

	if _interp_states.size() > BUFFER_SIZE:
		_interp_states.pop_front()


# -------------------------------------------------------------------------- #
# Interpolation for non-authority, non-server peers (remote players)
# -------------------------------------------------------------------------- #
func _process_interpolation(_delta: float) -> void:
	var player := owner as Player
	if not player:
		return

	if _interp_states.is_empty():
		return

	var render_tick := _interp_highest_tick - INTERPOLATION_DELAY_TICKS

	var snap_before: StateSnapshot = _interp_states[0]
	var snap_after: StateSnapshot = null

	# Walk newest → oldest to find bracketing snapshots
	for i in range(_interp_states.size() - 1, -1, -1):
		if _interp_states[i].tick <= render_tick:
			snap_before = _interp_states[i]
			if i < _interp_states.size() - 1:
				snap_after = _interp_states[i + 1]
			break

	if snap_after == null:
		# render_tick at or past the newest state — hold at latest
		var latest := _interp_states[_interp_states.size() - 1]
		player.global_position = latest.position
		player.rotation = latest.rotation
		return

	var t := 0.0
	var dt := snap_after.tick - snap_before.tick
	if dt > 0:
		t = float(render_tick - snap_before.tick) / float(dt)
	t = clampf(t, 0.0, 1.0)

	player.global_position = snap_before.position.lerp(snap_after.position, t)
	player.rotation.x = lerp_angle(snap_before.rotation.x, snap_after.rotation.x, t)
	player.rotation.y = lerp_angle(snap_before.rotation.y, snap_after.rotation.y, t)
	player.rotation.z = lerp_angle(snap_before.rotation.z, snap_after.rotation.z, t)

	# Garbage-collect states that are safely behind the render window
	var min_tick := render_tick - INTERPOLATION_DELAY_TICKS
	while _interp_states.size() > 2 and _interp_states[1].tick < min_tick:
		_interp_states.pop_front()
