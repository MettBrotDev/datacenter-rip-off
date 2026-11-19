extends Node3D
## A glowing panel showing the ops board. Origin at its centre, facing -Z (like item fronts).

const Shapes = preload("res://scripts/shapes.gd")


func setup(board: SubViewport, width: float, framed: bool) -> void:
	var height := width * 9.0 / 16.0
	var picture := StandardMaterial3D.new()
	picture.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	picture.albedo_texture = board.get_texture()
	var quad := QuadMesh.new()
	quad.size = Vector2(width, height)
	quad.material = picture
	var face := MeshInstance3D.new()
	face.mesh = quad
	face.rotation.y = PI   # a quad faces +Z; screens face -Z
	face.position.z = -0.012
	add_child(face)
	if framed:
		var frame := StandardMaterial3D.new()
		frame.albedo_color = Color(0.07, 0.08, 0.1)
		frame.roughness = 0.4
		add_child(Shapes.instance(Shapes.rounded_box(Vector3(width + 0.12, height + 0.12, 0.08), 0.03, 2), frame, Vector3(0, 0, 0.04)))
	var spill := OmniLight3D.new()   # a little glow onto whatever stands in front of it
	spill.light_color = Color(0.5, 0.7, 1.0)
	spill.light_energy = 0.5
	spill.omni_range = width * 1.6
	spill.position.z = -0.6
	spill.distance_fade_enabled = true
	spill.distance_fade_begin = 25.0
	add_child(spill)
