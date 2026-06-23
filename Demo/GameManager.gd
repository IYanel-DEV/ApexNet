extends Node


const PORT := 25565
const MAX_PLAYERS := 4
const PLAYER_SCENE := preload("res://Demo/Player/FP_Player.tscn")

@export var simulated_latency_ms: float = 0.0

var players: Dictionary = {}  # peer_id -> Player node


signal player_spawned(peer_id: int, player: Node)
signal player_despawned(peer_id: int)


func get_simulated_latency() -> float:
	return simulated_latency_ms / 1000.0


func send_with_latency(target: Callable, args: Array = []) -> void:
	var delay := get_simulated_latency()
	if delay <= 0.0:
		target.callv(args)
	else:
		get_tree().create_timer(delay).timeout.connect(
			func() -> void: target.callv(args),
			CONNECT_ONE_SHOT,
		)


func host_game() -> void:
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer = null

	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, MAX_PLAYERS)
	if err != OK:
		push_error("GameManager: failed to create server - ", err)
		return

	multiplayer.multiplayer_peer = peer
	_call_spawn.call_deferred()


func _call_spawn() -> void:
	_spawn_player.rpc(multiplayer.get_unique_id())


func join_game(address: String) -> bool:
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer = null

	if address.is_empty():
		address = "127.0.0.1"

	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, PORT)
	if err != OK:
		push_error("GameManager: failed to create client - ", err)
		return false

	multiplayer.multiplayer_peer = peer
	return true


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connection_failed.connect(_on_connection_failed)


func _on_connection_failed() -> void:
	multiplayer.multiplayer_peer = null


func _on_peer_connected(peer_id: int) -> void:
	if not is_multiplayer_authority():
		return

	var existing_ids: Array[int] = []
	for id in players.keys():
		existing_ids.append(id as int)

	_spawn_player.rpc(peer_id)

	for existing_id in existing_ids:
		if existing_id != peer_id:
			_spawn_player.rpc_id(peer_id, existing_id)


func _on_peer_disconnected(peer_id: int) -> void:
	if players.has(peer_id):
		players[peer_id].queue_free()
		players.erase(peer_id)
		player_despawned.emit(peer_id)


@rpc(&"authority", &"call_local", &"reliable")
func _spawn_player(peer_id: int) -> void:
	if not is_inside_tree():
		return

	var scene_root := get_tree().current_scene
	if scene_root == null:
		return

	var player_name := "Player_%d" % peer_id
	if scene_root.has_node(player_name):
		return

	var spawns: Array[Node] = get_tree().get_nodes_in_group(&"spawn_points")
	var spawn: Node3D = spawns.pick_random() as Node3D if spawns.size() > 0 else null

	var player: Node = PLAYER_SCENE.instantiate()
	player.name = player_name
	player.set_multiplayer_authority(peer_id)

	scene_root.add_child(player, true)

	if spawn != null:
		var body := player as Node3D
		if body:
			body.global_position = spawn.global_position
			body.global_rotation = spawn.global_rotation

	players[peer_id] = player
	player_spawned.emit(peer_id, player)
