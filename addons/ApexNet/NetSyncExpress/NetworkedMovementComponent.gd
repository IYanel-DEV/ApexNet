@tool
class_name NetworkedMovementComponent
extends Node


@export var enable_visual_debugger: bool = false
@export var debug_print: bool = false
@export var buffer_size: int = 128
@export var reconciliation_threshold: float = 1.5
@export var target_node_path: NodePath = NodePath()

# Internal calibration (advanced — change via const overrides if needed)
const TELEPORT_THRESHOLD := 5.0
const MISSING_TICK_GRACE := 0.4
const MAX_REPLAY_FRAMES := 64
const INTERPOLATION_DELAY_TICKS := 6

var target_body: Node3D = null

var _client_tick: int = 0
var _server_tick: int = 0

var input_buffer: NetSyncRingBuffer
var state_buffer: NetSyncRingBuffer
var _ghost: VisualDebuggerGhost = null

# Diagnostics UI
var _diag_canvas: Control = null
var _diag_labels: Dictionary = {}
var _reconciliation_count: int = 0
var _last_prediction_error: float = 0.0

# Server-side: queue of incoming InputSnapshots from remote clients
var server_pending_inputs: Array[InputSnapshot] = []
var _last_input: InputSnapshot = null
var _last_processed_client_tick: int = 0  # highest client tick processed by server

# Remote-interpolation: ordered server states for non-authority players
var _interp_states: Array[StateSnapshot] = []
var _interp_highest_tick: int = 0


func _ready() -> void:
	if target_node_path.is_empty():
		target_body = owner as Node3D
	else:
		target_body = get_node(target_node_path) as Node3D

	if not target_body:
		push_error("NetworkedMovementComponent: target_body not found — disable or remove this component.")
		set_process(false)
		set_physics_process(false)
		return

	input_buffer = NetSyncRingBuffer.new(buffer_size)
	state_buffer = NetSyncRingBuffer.new(buffer_size)

	if enable_visual_debugger:
		_setup_debug.call_deferred()


func _setup_debug() -> void:
	if not is_inside_tree():
		return
	if not is_multiplayer_authority():
		return
	_spawn_ghost()
	_spawn_diagnostics_ui()


func _exit_tree() -> void:
	if _diag_canvas:
		_diag_canvas.queue_free()
		_diag_canvas = null
		_diag_labels.clear()


func _spawn_ghost() -> void:
	if not target_body:
		return

	var ghost_scene: PackedScene = preload("res://addons/ApexNet/NetSyncExpress/VisualDebuggerGhost.tscn")
	_ghost = ghost_scene.instantiate() as VisualDebuggerGhost
	_ghost.top_level = true
	_ghost.process_mode = Node.PROCESS_MODE_DISABLED
	add_child(_ghost)
	_ghost.setup_from_parent(target_body)

	if multiplayer.get_unique_id() == 1:
		_ghost.visible = false


func _spawn_diagnostics_ui() -> void:
	var root_ctrl := Control.new()
	root_ctrl.name = "NetDiagnostics"
	root_ctrl.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	root_ctrl.offset_left = -248.0
	root_ctrl.offset_right = -8.0
	root_ctrl.offset_top = 8.0
	root_ctrl.offset_bottom = 220.0
	root_ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root_ctrl)
	_diag_canvas = root_ctrl

	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	root_ctrl.add_child(panel)

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.7)
	style.border_color = Color(0.3, 0.7, 1.0, 0.8)
	style.border_width_left = 1
	style.border_width_right = 1
	style.border_width_top = 1
	style.border_width_bottom = 1
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_left = 6
	style.corner_radius_bottom_right = 6
	style.content_margin_left = 12.0
	style.content_margin_right = 12.0
	style.content_margin_top = 8.0
	style.content_margin_bottom = 8.0
	panel.add_theme_stylebox_override("panel", style)

	var vbox := VBoxContainer.new()
	vbox.name = "VBox"
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_theme_constant_override("separation", 2)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "APEXNET DIAGNOSTICS"
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title.add_theme_font_size_override("font_size", 13)
	title.add_theme_color_override("font_color", Color(0.3, 0.7, 1.0))
	vbox.add_child(title)

	var sep := HSeparator.new()
	sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sep.add_theme_constant_override("separation", 4)
	vbox.add_child(sep)

	var entries: Array[Array] = [
		["role", "Role"],
		["client_tick", "Client Tick"],
		["ping", "Ping / RTT"],
		["latency_delay", "Latency Delay"],
		["prediction_error", "Prediction Error"],
		["reconciliations", "Reconciliations"],
	]

	for entry in entries:
		var row := HBoxContainer.new()
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_theme_constant_override("separation", 8)
		vbox.add_child(row)

		var lbl_name := Label.new()
		lbl_name.text = entry[1] + ":"
		lbl_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
		lbl_name.add_theme_font_size_override("font_size", 12)
		lbl_name.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
		lbl_name.custom_minimum_size.x = 130.0
		row.add_child(lbl_name)

		var lbl_val := Label.new()
		lbl_val.text = "---"
		lbl_val.mouse_filter = Control.MOUSE_FILTER_IGNORE
		lbl_val.add_theme_font_size_override("font_size", 12)
		lbl_val.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
		row.add_child(lbl_val)

		_diag_labels[entry[0]] = lbl_val


func _get_game_manager() -> Node:
	return get_node_or_null("/root/GameManager")


func _update_diagnostics() -> void:
	if _diag_labels.is_empty():
		return

	var is_server := multiplayer.get_unique_id() == 1

	_diag_labels["role"].text = "Server" if is_server else "Client (Owner)"
	_diag_labels["client_tick"].text = str(_client_tick)
	_diag_labels["ping"].text = "%.0f ms" % _get_ping_ms()
	_diag_labels["latency_delay"].text = _get_latency_delay_text()
	_diag_labels["prediction_error"].text = "%.3f m" % _last_prediction_error
	_diag_labels["reconciliations"].text = str(_reconciliation_count)


func _get_ping_ms() -> float:
	var mp: MultiplayerPeer = multiplayer.multiplayer_peer
	if mp == null:
		return 0.0
	if not mp is ENetMultiplayerPeer:
		return 0.0
	if mp.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return 0.0

	var target_id: int
	if multiplayer.is_server():
		target_id = get_multiplayer_authority()
		if target_id == 1:
			return 0.0
	else:
		target_id = 1

	# Safely check the multiplayer system array instead of the nonexistent enet method
	if not multiplayer.get_peers().has(target_id):
		return 0.0

	var enet: ENetMultiplayerPeer = mp
	var peer: ENetPacketPeer = enet.get_peer(target_id)
	if peer == null:
		return 0.0
	return float(peer.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME))


func _get_latency_delay_text() -> String:
	var gm := _get_game_manager()
	if gm and gm.has_method("get_simulated_latency"):
		var ms: float = gm.simulated_latency_ms
		if ms > 0.0:
			var frames := ms / (1000.0 / Engine.physics_ticks_per_second)
			return "%.0f ms (%d frames)" % [ms, int(roundi(frames))]
		return "0 ms"
	return "N/A"


# Called every physics frame from Player._physics_process on every peer.
# Behaviour depends on the role of this peer relative to this player:
#   authority  → sample input, predict locally, transmit to server
#                (host also broadcasts authoritative state directly)
#   server     → process pending inputs from remote clients, broadcast state
#   remote     → interpolate between server states for smooth movement
func process_tick(delta: float) -> void:
	if not target_body:
		return

	var is_server := multiplayer.get_unique_id() == 1
	var dt := 1.0 / Engine.physics_ticks_per_second

	if is_multiplayer_authority():
		_client_tick += 1

		var snap: InputSnapshot
		if target_body.has_method("get_input_snapshot"):
			snap = target_body.call("get_input_snapshot", _client_tick) as InputSnapshot
		else:
			push_error("NetworkedMovementComponent: target_body must implement get_input_snapshot(tick)")
			return
		input_buffer.push(snap)

		if target_body.has_method("apply_net_movement"):
			target_body.call("apply_net_movement", snap, dt)
		else:
			push_error("NetworkedMovementComponent: target_body must implement apply_net_movement(snapshot, delta)")
			return

		var st := StateSnapshot.new()
		st.tick = _client_tick
		st.position = target_body.global_position
		st.rotation = target_body.rotation
		st.velocity = target_body.velocity
		state_buffer.push(st)

		var authority_id := target_body.get_multiplayer_authority()

		var gm := _get_game_manager()
		if gm:
			gm.send_with_latency(_send_input.rpc, [authority_id, snap.to_variant()])
		else:
			_send_input.rpc(authority_id, snap.to_variant())

		if is_server:
			if gm:
				gm.send_with_latency(_receive_state.rpc, [authority_id, st.to_variant()])
			else:
				_receive_state.rpc(authority_id, st.to_variant())

		if debug_print:
			printt("[TICK]", "cli=%d" % _client_tick,
				"pos=%s" % str(target_body.global_position),
				"vel=%.2f" % target_body.velocity.length(),
				"buf=%d/%d" % [input_buffer.get_count(), state_buffer.get_count()])

		_update_diagnostics()

	elif is_server:
		_process_server_tick(dt)

	else:
		_process_interpolation(delta)


# -------------------------------------------------------------------------- #
# Server reconciliation for the owning client
# -------------------------------------------------------------------------- #
func _reconcile(server_snap: StateSnapshot) -> void:
	if not target_body:
		return

	if _ghost:
		_ghost.snap_to(server_snap.position, server_snap.rotation)

	# 1. Find predicted state at the server's tick
	var idx := state_buffer.find_tick(server_snap.tick)
	var predicted_snap: StateSnapshot = null
	var tick_missing := idx < 0

	if not tick_missing:
		predicted_snap = state_buffer.get_at(idx) as StateSnapshot

	# 2. Compute error: compare server state against prediction
	var error := 0.0
	if predicted_snap:
		error = predicted_snap.position.distance_to(server_snap.position)
	else:
		error = target_body.global_position.distance_to(server_snap.position)
	_last_prediction_error = error

	# Adaptive threshold: widen grace when tick was evicted from buffer
	var effective_threshold := reconciliation_threshold
	if tick_missing:
		effective_threshold += MISSING_TICK_GRACE

	if debug_print:
		printt("[RECONCILE]", "srv_tick=%d" % server_snap.tick,
			"cli_tick=%d" % _client_tick,
			"err=%.4f" % error,
			"thresh=%.4f" % effective_threshold,
			"tick_missing=%s" % tick_missing,
			"reconciles=%d" % _reconciliation_count)

	if error < effective_threshold:
		if debug_print:
			printt("[RECONCILE]", "→ SOFT (jitter absorbed)")
		_soft_apply(server_snap)
		return

	if error > TELEPORT_THRESHOLD:
		if debug_print:
			printt("[RECONCILE]", "→ TELEPORT (error > 5m)")
		_hard_snap(server_snap)
		return

	# 3. Hard reconciliation: rewind + replay
	_reconciliation_count += 1
	if debug_print:
		printt("[RECONCILE]", "→ REWIND+REPLAY (%d frames)" % (_client_tick - server_snap.tick))
	_hard_rewind_and_replay(server_snap)


func _soft_apply(target: StateSnapshot) -> void:
	var dt := 1.0 / Engine.physics_ticks_per_second
	var alpha := 1.0 - exp(-8.0 * dt)
	target_body.global_position = target_body.global_position.lerp(target.position, alpha)
	target_body.velocity = target_body.velocity.lerp(target.velocity, alpha)


func _hard_snap(snap: StateSnapshot) -> void:
	target_body.global_position = snap.position
	target_body.velocity = snap.velocity
	target_body.rotation = snap.rotation

	if target_body.has_method("reset_net_state"):
		target_body.call("reset_net_state")

	state_buffer.push(snap)


func _hard_rewind_and_replay(server_snap: StateSnapshot) -> void:
	_hard_snap(server_snap)

	var dt := 1.0 / Engine.physics_ticks_per_second
	var replay_tick := server_snap.tick + 1
	var steps := 0
	var missed := 0

	while replay_tick <= _client_tick and steps < MAX_REPLAY_FRAMES:
		var input_idx := input_buffer.find_tick(replay_tick)
		if input_idx >= 0:
			var historical_input := input_buffer.get_at(input_idx) as InputSnapshot
			if target_body.has_method("apply_net_movement"):
				target_body.call("apply_net_movement", historical_input, dt)

			var replayed := StateSnapshot.new()
			replayed.tick = replay_tick
			replayed.position = target_body.global_position
			replayed.rotation = target_body.rotation
			replayed.velocity = target_body.velocity
			state_buffer.push(replayed)
		else:
			missed += 1
		replay_tick += 1
		steps += 1

	if debug_print:
		printt("[REPLAY]", "server_tick=%d → client_tick=%d" % [server_snap.tick, _client_tick],
			"steps=%d" % steps, "missed_inputs=%d" % missed,
			"final_pos=%s" % str(target_body.global_position))


# -------------------------------------------------------------------------- #
# Server-tick processing
# -------------------------------------------------------------------------- #
func _process_server_tick(dt: float) -> void:
	if not target_body:
		return

	_server_tick += 1

	var snap: InputSnapshot = null

	if server_pending_inputs.size() > 0:
		snap = server_pending_inputs.pop_front() as InputSnapshot
		if snap.tick <= _last_processed_client_tick:
			return
		_last_processed_client_tick = snap.tick
		_last_input = snap

	elif _last_input != null:
		snap = InputSnapshot.new()
		snap.tick = _last_processed_client_tick + 1
		snap.input_vector = _last_input.input_vector
		snap.camera_yaw = _last_input.camera_yaw
		snap.camera_pitch = _last_input.camera_pitch
		snap.actions = _last_input.actions.duplicate()
		snap.actions[&"jump"] = false
		snap.actions[&"dash"] = false
		_last_processed_client_tick = snap.tick

	if snap == null:
		return

	if target_body.has_method("apply_net_movement"):
		target_body.call("apply_net_movement", snap, dt)

	# Send state every frame — tick is client-aligned so buffer lookup succeeds.
	var st := StateSnapshot.new()
	st.tick = snap.tick
	st.position = target_body.global_position
	st.rotation = target_body.rotation
	st.velocity = target_body.velocity

	var authority_id := target_body.get_multiplayer_authority()

	var gm := _get_game_manager()
	if gm:
		gm.send_with_latency(_receive_state.rpc, [authority_id, st.to_variant()])
	else:
		_receive_state.rpc(authority_id, st.to_variant())


# -------------------------------------------------------------------------- #
# RPC ─ called remotely by the owning client to deliver input to the server
# -------------------------------------------------------------------------- #
@rpc(&"any_peer", &"unreliable")
func _send_input(authority_id: int, data: Dictionary) -> void:
	if multiplayer.get_unique_id() != 1:
		return

	var owner_node := _find_player_by_authority(authority_id)
	if owner_node == null:
		return
	var comp: NetworkedMovementComponent = owner_node.get_node_or_null("NetworkedMovementComponent")
	if comp == null:
		return

	var snap := InputSnapshot.from_variant(data)
	comp.server_pending_inputs.append(snap)


func _find_player_by_authority(peer_id: int) -> Node3D:
	for child in get_tree().current_scene.get_children():
		if child is Node3D \
				and child.get_multiplayer_authority() == peer_id \
				and child.has_node("NetworkedMovementComponent"):
			return child as Node3D
	return null


# -------------------------------------------------------------------------- #
# RPC ─ called BY the server TO broadcast authoritative state to all peers
# -------------------------------------------------------------------------- #
@rpc(&"any_peer", &"unreliable")
func _receive_state(authority_id: int, data: Dictionary) -> void:
	if not target_body:
		return
	if target_body.get_multiplayer_authority() != authority_id:
		return

	var snap := StateSnapshot.from_variant(data)

	if is_multiplayer_authority():
		if not multiplayer.is_server():
			if debug_print:
				printt("[RECV]", "srv_tick=%d" % snap.tick,
					"srv_pos=%s" % str(snap.position),
					"cli_tick=%d" % _client_tick,
					"lag=%d" % (_client_tick - snap.tick))
			_reconcile(snap)
		return

	# Remote path — push into interpolation buffer
	_interp_states.append(snap)
	if snap.tick > _interp_highest_tick:
		_interp_highest_tick = snap.tick

	if _interp_states.size() > buffer_size:
		_interp_states.pop_front()


# -------------------------------------------------------------------------- #
# Interpolation for non-authority, non-server peers (remote players)
# -------------------------------------------------------------------------- #
func _process_interpolation(_delta: float) -> void:
	if not target_body:
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
		var latest := _interp_states[_interp_states.size() - 1]
		target_body.global_position = latest.position
		target_body.rotation = latest.rotation
		return

	var t := 0.0
	var dt := snap_after.tick - snap_before.tick
	if dt > 0:
		t = float(render_tick - snap_before.tick) / float(dt)
	t = clampf(t, 0.0, 1.0)

	target_body.global_position = snap_before.position.lerp(snap_after.position, t)
	target_body.rotation.x = lerp_angle(snap_before.rotation.x, snap_after.rotation.x, t)
	target_body.rotation.y = lerp_angle(snap_before.rotation.y, snap_after.rotation.y, t)
	target_body.rotation.z = lerp_angle(snap_before.rotation.z, snap_after.rotation.z, t)

	var min_tick := render_tick - INTERPOLATION_DELAY_TICKS
	while _interp_states.size() > 2 and _interp_states[1].tick < min_tick:
		_interp_states.pop_front()
