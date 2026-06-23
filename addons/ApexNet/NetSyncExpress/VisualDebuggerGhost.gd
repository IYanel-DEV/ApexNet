@tool
class_name VisualDebuggerGhost
extends Node3D


const GHOST_ALPHA := 0.3
const GHOST_COLOR := Color(0.2, 0.6, 1.0, GHOST_ALPHA)


func setup_from_parent(parent: Node3D) -> void:
	for child in parent.get_children():
		if child is MeshInstance3D:
			var ghost_mesh := MeshInstance3D.new()
			ghost_mesh.mesh = child.mesh.duplicate()
			ghost_mesh.name = "GhostMesh"
			add_child(ghost_mesh)
			ghost_mesh.owner = get_tree().edited_scene_root if Engine.is_editor_hint() else null

			var mat := StandardMaterial3D.new()
			mat.albedo_color = GHOST_COLOR
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mat.no_depth_test = true
			mat.render_priority = 100

			for surface_idx in range(ghost_mesh.mesh.get_surface_count()):
				ghost_mesh.set_surface_override_material(surface_idx, mat)

			break


func snap_to(server_position: Vector3, server_rotation: Vector3) -> void:
	global_position = server_position
	rotation = server_rotation
