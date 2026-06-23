extends CanvasLayer


@onready var _host_btn: Button = $Background/Center/MenuContainer/HostBtn
@onready var _join_btn: Button = $Background/Center/MenuContainer/JoinBtn
@onready var _status: Label = $Background/Center/MenuContainer/StatusLabel


func _ready() -> void:
	_host_btn.pressed.connect(_on_host)
	_join_btn.pressed.connect(_on_join)

	multiplayer.connected_to_server.connect(_on_connected, CONNECT_ONE_SHOT)
	multiplayer.connection_failed.connect(_on_connection_failed, CONNECT_ONE_SHOT)

	GameManager.player_spawned.connect(_on_own_player_spawned)


func _on_host() -> void:
	_status.text = "Starting host…"
	_host_btn.disabled = true
	_join_btn.disabled = true

	GameManager.host_game()


func _on_join() -> void:
	_status.text = "Connecting…"
	_host_btn.disabled = true
	_join_btn.disabled = true

	if not GameManager.join_game("127.0.0.1"):
		_status.text = "Connection failed."
		_host_btn.disabled = false
		_join_btn.disabled = false


func _on_connected() -> void:
	_status.text = "Connected!"


func _on_connection_failed() -> void:
	_status.text = "Connection failed."
	_host_btn.disabled = false
	_join_btn.disabled = false


func _on_own_player_spawned(peer_id: int, player: Node) -> void:
	if peer_id == multiplayer.get_unique_id():
		visible = false
		if player is Player:
			player.mouse_capture_changed.connect(_on_mouse_capture_changed)


func _on_mouse_capture_changed(captured: bool) -> void:
	visible = not captured
