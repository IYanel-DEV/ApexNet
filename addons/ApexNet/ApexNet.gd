@tool
extends EditorPlugin


const AUTOLOAD_NET_SYNC := &"NetSyncManager"
const AUTOLOAD_NET_SYNC_PATH := "res://addons/ApexNet/NetSyncExpress/NetSyncManager.gd"

const AUTOLOAD_GAME := &"GameManager"
const AUTOLOAD_GAME_PATH := "res://Demo/GameManager.gd"

const COMPONENT_CLASS := &"NetworkedMovementComponent"
const COMPONENT_BASE := &"Node"
const COMPONENT_PATH := "res://addons/ApexNet/NetSyncExpress/NetworkedMovementComponent.gd"
const ICON_PATH := "res://addons/ApexNet/NetSyncExpress/icon.svg"


func _enter_tree() -> void:
	add_autoload_singleton(AUTOLOAD_NET_SYNC, AUTOLOAD_NET_SYNC_PATH)
	add_autoload_singleton(AUTOLOAD_GAME, AUTOLOAD_GAME_PATH)
	add_custom_type(
		COMPONENT_CLASS,
		COMPONENT_BASE,
		load(COMPONENT_PATH) as GDScript,
		load(ICON_PATH) as Texture2D
	)


func _exit_tree() -> void:
	remove_custom_type(COMPONENT_CLASS)
	remove_autoload_singleton(AUTOLOAD_NET_SYNC)
	remove_autoload_singleton(AUTOLOAD_GAME)
