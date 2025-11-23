@tool
extends Node3D

# ─────────────────────────────────────
# ▌ Base
# ─────────────────────────────────────
@export_category("Base")
@export_group("Debug")
@export var debug : bool = false : 
	set(value):
		debug = value
		notify_property_list_changed()
@export_group("Global Settings")
@export var global_loop : bool = false  # Master toggle to loop all animations
@export_group("Position", "Position Settings")
@export var enable_position := false
@export var position_speed := 1.0  # Speed of position movement
@export var position_amplitude := 1.0  # Radius of the circle
@export var position_axis_x := false
@export var position_axis_y := false
@export var position_axis_z := false
@export_group("Rotation", "Rotation Settings")
@export var enable_rotation := false
@export var rotation_speed_deg := 90.0  # Rotation speed in degrees per second
@export var rotate_x_axis := false
@export var rotate_y_axis := false
@export var rotate_z_axis := false
@export var custom_axis := Vector3.ZERO  # Custom axis if non-zero
@export_group("Scale", "Scale Settings")
@export var enable_scale := false
@export var scale_speed := 1.0  # Speed of scale oscillation
@export var scale_amplitude := 0.2  # Magnitude of scale change
@export var scale_uniform := true
@export var scale_axis_x := false
@export var scale_axis_y := false
@export var scale_axis_z := false

# ─────────────────────────────────────
# ▌ Lights
# ─────────────────────────────────────
@export_category("Lights")
@export_group("Light Flicker", "Light Flicker Settings")
@export var enable_light_flicker := false
@export var base_energy := 5.0  # Base light intensity
@export var flicker_amplitude := 1.0  # Flicker intensity variation
@export var flicker_speed := 1.5  # Flicker speed
@export var flicker_offset := 0.0  # Flicker time offset
@export_node_path("OmniLight3D") var light_node_path := NodePath("OmniLight3D")  # Path to light node

# ─────────────────────────────────────
# ▌ Motion
# ─────────────────────────────────────
@export_category("Motion")
@export_group("Presets", "Preset Settings")
@export_enum("None", "Circle") var motion_preset := 0  # Select motion pattern
@export_group("Easing In", "Easing In Settings")
@export_enum("Linear (Flat)", "EaseIn (Gradual)", "EaseOut (Slow End)", "EaseInOut (Smooth)", "QuadIn (Fast Start)", "QuadOut (Slow Start)") var easing_in := "Linear (Flat)"  # Easing for animation start; see docs/curves.pdf for visuals
@export_group("Easing Out", "Easing Out Settings")
@export_enum("Linear (Flat)", "EaseIn (Gradual)", "EaseOut (Slow End)", "EaseInOut (Smooth)", "QuadIn (Fast Start)", "QuadOut (Slow Start)") var easing_out := "Linear (Flat)"  # Easing for animation end; see docs/curves.pdf for visuals
@export_group("Sway", "Sway Settings")
@export var enable_sway := false
@export var sway_amount := 5.0  # Maximum sway angle in degrees
@export var sway_speed := 0.5  # Sway speed
@export_group("Bobbing", "Bobbing Settings")
@export var enable_bobbing := false
@export var bob_speed := 1.25  # Speed of bobbing
@export var bob_amplitude := 0.056  # Distance of bobbing movement
@export_group("Wave", "Wave Settings")
@export var enable_wave := false
@export var wave_strength := 0.1  # Intensity of wave effect
@export var wave_speed := 2.0  # Speed of wave
@export var wave_y_top := 1.0  # Upper Y bound for wave
@export var wave_y_bottom := -1.0  # Lower Y bound for wave

# ─────────────────────────────────────
# ▌ Something else (Placeholder)
# ─────────────────────────────────────
@export_category("Something else")
# Add future options here

var _time := 0.0
var _sway_t := 0.0
var _angle := 0.0
var _motion_progress := 0.0  # Global progress for all animations

var _t0: Transform3D                # original transform
var _b0: Basis                      # original orthonormal basis (rotation only)
var _s0: Vector3                    # original local scale
var _p0: Vector3                    # original local position

var initial_rotation_degrees: Vector3
var noise := FastNoiseLite.new()

var base_mesh: ArrayMesh
var base_vertices: PackedVector3Array = PackedVector3Array()
var light_node: Node = null

func _ready():
	_t0 = transform
	_b0 = _t0.basis.orthonormalized()
	_s0 = _t0.basis.get_scale()
	_p0 = _t0.origin
	initial_rotation_degrees = rotation_degrees

	noise.seed = randi()
	noise.frequency = 0.1

	if enable_wave and has_node(".") and get_node(".") is MeshInstance3D:
		var mesh_instance = get_node(".") as MeshInstance3D
		base_mesh = mesh_instance.mesh
		if base_mesh and base_mesh.get_surface_count() > 0:
			var surface := base_mesh.surface_get_arrays(0)
			base_vertices = surface[Mesh.ARRAY_VERTEX]
		else:
			push_warning("Wave: no valid mesh/surface found on ", mesh_instance.name)

	if enable_light_flicker and has_node(light_node_path):
		light_node = get_node(light_node_path)
		if not light_node or not light_node is OmniLight3D:
			push_warning("Light Flicker: Node at ", light_node_path, " is not an OmniLight3D")
			light_node = null

func apply_easing(value: float, easing_type: String) -> float:
	match easing_type:
		"Linear (Flat)": return value
		"EaseIn (Gradual)": return ease(value, 0.5)
		"EaseOut (Slow End)": return 1.0 - ease(1.0 - value, 0.5)
		"EaseInOut (Smooth)": return ease(value, -1.0)
		"QuadIn (Fast Start)": return value * value
		"QuadOut (Slow Start)": return value * (2.0 - value)
	return value

func _physics_process(delta: float) -> void:
	_time += delta
	var progress: float = clamp(_motion_progress / (PI * 2), 0.0, 1.0)  # Normalize to 0-1 using PI * 2
	var eased_progress := apply_easing(progress, easing_in) if progress <= 1.0 else 1.0
	eased_progress = apply_easing(1.0 - (1.0 - progress) if progress > 0.0 else progress, easing_out) if progress <= 1.0 else eased_progress
	if debug:
		print("Progress: ", progress, " Eased: ", eased_progress)  # Debug progress

	# 1) Build a rotation around a stable axis
	var axis := _pick_axis()
	var rot_basis := _b0
	if enable_rotation:
		_angle = wrapf(_angle + deg_to_rad(rotation_speed_deg) * delta, 0.0, PI * 2)
		var R := Basis(axis, _angle)
		rot_basis = R * _b0

	# 2) Optional sway (small extra rotation around local X)
	if enable_sway:
		_sway_t += delta * sway_speed
		var sway_deg := noise.get_noise_1d(_sway_t) * sway_amount
		var sway_R := Basis(Vector3.RIGHT, deg_to_rad(sway_deg))
		rot_basis = sway_R * rot_basis

	# 3) Start with current global position
	var pos := global_transform.origin

	# 4) Bobbing (local Y offset)
	if enable_bobbing:
		pos.y += sin(_time * bob_speed) * bob_amplitude

	# 5) Position with presets and easing
	if enable_position:
		if motion_preset == 1:  # Circle preset
			var angle = eased_progress * (PI * 2)  # Full circle over progress
			# Counterclockwise circle in XZ plane from current position
			var circle_offset_x = cos(angle) * position_amplitude
			var circle_offset_z = sin(angle) * position_amplitude
			pos.x += circle_offset_x
			pos.z += circle_offset_z
			if debug:
				print("Circle Pos: ", pos, " Angle: ", angle)  # Debug circle position
		else:
			var pos_offset := sin(_time * position_speed) * position_amplitude
			if position_axis_x: pos.x += pos_offset
			if position_axis_y: pos.y += pos_offset
			if position_axis_z: pos.z += pos_offset

	# 6) Scale (relative to original scale)
	var scl := _s0
	if enable_scale:
		var f := 1.0 + sin(_time * scale_speed) * scale_amplitude
		if scale_uniform:
			scl = _s0 * f
		else:
			if scale_axis_x: scl.x = _s0.x * f
			if scale_axis_y: scl.y = _s0.y * f
			if scale_axis_z: scl.z = _s0.z * f

	# 7) Compose final transform
	var final_basis := rot_basis.scaled(scl)
	var new_transform = Transform3D(final_basis, pos)
	global_transform = new_transform  # Set global transform directly
	if debug:
		print("New Global Pos: ", global_transform.origin)  # Debug final position

	# 8) Light flicker
	if enable_light_flicker and light_node and light_node is OmniLight3D:
		var t = Time.get_ticks_msec() / 1000.0 + flicker_offset
		var flicker := base_energy + sin(t * flicker_speed) * flicker_amplitude
		(light_node as OmniLight3D).light_energy = clamp(flicker, 0.0, 100.0)  # Safe range

	# 9) Wave deform
	if enable_wave and base_mesh and not base_vertices.is_empty():
		var tt := Time.get_ticks_msec() / 1000.0
		var new_vertices := PackedVector3Array()
		new_vertices.resize(base_vertices.size())
		for i in base_vertices.size():
			var v := base_vertices[i]
			var mask := pow(smoothstep(wave_y_top, wave_y_bottom, v.y), 2.0)
			var sway := sin(tt * wave_speed + v.y * 4.0) * wave_strength * mask
			new_vertices[i] = Vector3(v.x + sway, v.y, v.z)

		var arrays := base_mesh.surface_get_arrays(0)
		arrays[Mesh.ARRAY_VERTEX] = new_vertices

		var updated := ArrayMesh.new()
		updated.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		if has_node(".") and get_node(".") is MeshInstance3D:
			(get_node(".") as MeshInstance3D).mesh = updated

	# 10) Update and check global progress
	_motion_progress = max(0.0, _motion_progress + delta * max(position_speed, 0.001))  # Prevent negative
	if debug:
		print("Motion Progress: ", _motion_progress)  # Debug motion progress
	if _motion_progress >= (PI * 2) and not global_loop:
		set_physics_process(false)  # Stop all animations after one cycle
	elif _motion_progress >= (PI * 2) and global_loop:
		_motion_progress = fmod(_motion_progress, PI * 2)  # Reset with fmod for precision

func _pick_axis() -> Vector3:
	if custom_axis != Vector3.ZERO:
		return custom_axis.normalized()

	var ax := 1.0 if rotate_x_axis else 0.0
	var ay := 1.0 if rotate_y_axis else 0.0
	var az := 1.0 if rotate_z_axis else 0.0
	var a := Vector3(ax, ay, az)

	if a == Vector3.ZERO:
		a = Vector3.UP
	return a.normalized()
