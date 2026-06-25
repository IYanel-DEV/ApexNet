@tool
class_name VisualDebuggerGhost
extends Node3D


const GHOST_ALPHA := 0.3
const GHOST_COLOR := Color(0.2, 0.6, 1.0, GHOST_ALPHA)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_DISABLED


func setup_from_parent(parent: Node3D) -> void:
	for child in parent.get_children():
		if child is MeshInstance3D:
			var ghost_mesh := MeshInstance3D.new()
			ghost_mesh.mesh = child.mesh.duplicate()
			ghost_mesh.name = "GhostMesh"
			ghost_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			ghost_mesh.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
			ghost_mesh.extra_cull_margin = 100000.0

			var mat := StandardMaterial3D.new()
			mat.albedo_color = GHOST_COLOR
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mat.no_depth_test = true
			mat.render_priority = 100
			mat.cull_mode = BaseMaterial3D.CULL_DISABLED

			for surface_idx in range(ghost_mesh.mesh.get_surface_count()):
				ghost_mesh.set_surface_override_material(surface_idx, mat)

			add_child(ghost_mesh)
			break


func snap_to(server_position: Vector3, server_rotation: Vector3) -> void:
	global_position = server_position
	rotation = server_rotation
