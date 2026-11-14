extends Node3D

enum Door { CLOSED, OPENING, OPEN, CLOSING }
enum Location { PLATFORM, INSIDE }
enum Phase { PLAYING, LEAVING, DEPARTING, RIDING, ARRIVING, GLITCHING, THINKING, FAULT }

@export_group("Door animation")
@export var door_move_time := 1.0
@export var left_open_x := -1.5
@export var right_open_x := 1.5

@export_group("Door timing")
@export var initial_wait := 1.5
@export var closed_time := 2.0
@export var open_time_min := 2.5
@export var open_time_max := 4.0

@export_group("Crossing")
@export var walk_time := 1.2
@export var doorway_half_depth := 0.3
@export var passable_left_x := -0.75
@export var doorway_half_width := 1.0
@export var doorway_height := 2.0

@export_group("Ride")
@export var depart_time := 3.0            # used for BOTH accelerating away and braking in
@export var ride_time := 2.0              # tunnel lights streak past before the screen fades out
@export var station_travel := 60.0        # how far the station slides, in units
@export var sway_amount := 0.015          # camera shake while the train moves
@export var tunnel_light_count := 20
@export var tunnel_light_spacing := 3.5

@export_group("Rounds")
@export var leave_close_delay := 0.8      # after the player boards, how soon the doors close
@export var banner_hold := 2.0            # how long "Round N" stays fully visible
@export var fade_time := 1.0              # fade to black and back
@export var black_hold := 3.5             # how long the screen stays black between rounds

@export_group("Glitch (round 2)")
@export var glitch_count := 2
@export var glitch_gap := 2.5             # calm before each glitch
@export var glitch_shake := 0.05          # peak camera shake of the jolt
@export var glitch_shake_decay := 1.0     # how long the rumble takes to die out
@export var glitch_open_time := 0.25      # doors fly open
@export var glitch_open_hold := 0.35      # ...hang open...
@export var glitch_close_time := 0.2      # ...and snap shut

@export_group("Thought (manga moment)")
@export var thought_lines: Array[String] = [
	"The doors are going haywire...",
	"Heh. Anyone else would panic. I could slip out and back in before they shut.",
]
@export var type_time_per_char := 0.035   # typewriter speed
@export var thought_hold := 1.2           # pause after each line finishes typing

@export_group("Fault (round 2)")
@export var fault_cycles_min := 5         # open+close cycles, picked once per run
@export var fault_cycles_max := 10
@export var fault_start_delay := 1.0      # extra pause before the first cycle
@export var fault_closed_min := 0.4       # doors stay shut for a random time in this range
@export var fault_closed_max := 1.2
@export var fault_open_min := 0.7         # ...and stay open for a random time in this range
@export var fault_open_max := 1.5

@onready var camera: Camera3D = $Camera3D
@onready var train: Node3D = $Train
@onready var station: Node3D = $Station
@onready var door_left: MeshInstance3D = $Train/DoorLeft
@onready var door_right: MeshInstance3D = $Train/DoorRight
@onready var platform_spot: Marker3D = $PlatformSpot
@onready var inside_spot: Marker3D = $InsideSpot
@onready var status_label: Label = $CanvasLayer/StatusLabel
@onready var round_label: Label = $CanvasLayer/RoundLabel
@onready var fade: ColorRect = $CanvasLayer/Fade

var left_closed_x: float
var right_closed_x: float
var door_state: Door = Door.CLOSED
var door_timer: float
var location: Location = Location.PLATFORM
var phase: Phase = Phase.PLAYING
var round_number: int = 1
var is_moving: bool = false
var failed: bool = false
var crossings: int = 0
var shake_strength: float = 0.0
var fault_cycles_left: int = 0
var fault_over: bool = false              # the last cycle is done; waiting for the player to land
var walk_tween: Tween
var fault_tween: Tween
var banner_tween: Tween
var tunnel: Node3D
var tunnel_lights: Array[MeshInstance3D] = []

# Built in code (see build_thought_ui)
var thought_layer: CanvasLayer
var vignette: TextureRect
var exclaim: Label
var dialogue_box: PanelContainer
var dialogue_label: Label


func _ready() -> void:
	# The closed door positions and starting camera pose are authored in the scene.
	left_closed_x = door_left.position.x
	right_closed_x = door_right.position.x
	door_timer = initial_wait
	round_label.modulate.a = 0.0
	fade.modulate.a = 0.0
	build_tunnel()
	build_thought_ui()
	show_banner("Round %d" % round_number)
	update_label("Wait for the doors to open, then click the doorway.")


func _process(delta: float) -> void:
	update_sway()
	if failed:
		return

	match phase:
		Phase.PLAYING, Phase.LEAVING:
			run_door_cycle(delta)
			check_doorway_crush()
		Phase.FAULT:
			check_doorway_crush()   # the fault doors run on their own tween
		Phase.RIDING:
			scroll_tunnel(delta)


# ---------------------------------------------------------------- doors
# The normal door cycle: closed, opening, open, closing, repeat.

func run_door_cycle(delta: float) -> void:
	door_timer -= delta
	if door_timer <= 0.0:
		advance_doors()


func advance_doors() -> void:
	match door_state:
		Door.CLOSED:
			door_state = Door.OPENING
			door_timer = door_move_time
			slide_doors(true)
		Door.OPENING:
			door_state = Door.OPEN
			door_timer = open_hold()
		Door.OPEN:
			door_state = Door.CLOSING
			door_timer = door_move_time
			slide_doors(false)
		Door.CLOSING:
			door_state = Door.CLOSED
			door_timer = closed_time
			# Doors just shut after the player boarded: the train leaves.
			if phase == Phase.LEAVING:
				begin_departure()


func open_hold() -> float:
	if phase == Phase.LEAVING:
		return leave_close_delay   # the player is aboard: close up quickly
	return randf_range(open_time_min, open_time_max)


func slide_doors(open: bool, duration: float = -1.0) -> void:
	if duration < 0.0:
		duration = door_move_time
	var left_target := left_open_x if open else left_closed_x
	var right_target := right_open_x if open else right_closed_x
	var tween := create_tween().set_parallel(true)
	tween.tween_property(door_left, "position:x", left_target, duration)
	tween.tween_property(door_right, "position:x", right_target, duration)


func doors_passable() -> bool:
	return door_left.position.x <= passable_left_x


func check_doorway_crush() -> void:
	var depth := absf(camera.global_position.z - train.global_position.z)
	if is_moving and depth < doorway_half_depth and not doors_passable():
		fail("The doors got you!")


# --------------------------------------------------------------- rounds

func end_round() -> void:
	# Nothing is announced yet. The "complete" banner waits for the black screen.
	phase = Phase.LEAVING
	update_label("")
	# The doors may be in any phase right now. Each case needs a different nudge.
	match door_state:
		Door.OPEN:
			door_timer = minf(door_timer, leave_close_delay)
		Door.CLOSED:
			begin_departure()
		# OPENING and CLOSING are handled inside advance_doors().


func start_round() -> void:
	crossings = 0
	if round_number == 2:
		begin_glitches()
	else:
		phase = Phase.PLAYING   # placeholder until round 3 has its own content


func show_banner(text: String, hold: float = -1.0) -> void:
	if hold < 0.0:
		hold = banner_hold
	# Kill the previous banner first, or two fades would fight over the alpha.
	if banner_tween and banner_tween.is_valid():
		banner_tween.kill()
	round_label.text = text
	banner_tween = create_tween()
	banner_tween.tween_property(round_label, "modulate:a", 1.0, 0.4)
	banner_tween.tween_interval(hold)
	banner_tween.tween_property(round_label, "modulate:a", 0.0, 0.6)


# ----------------------------------------------------------------- ride
# The ride is the transition between rounds. The screen goes black in the
# middle of it, and the round-complete banner is shown on the black.

func begin_departure() -> void:
	phase = Phase.DEPARTING
	update_label("")

	# One tween, run step by step.
	var t := create_tween()
	# 1. The station slides away.
	t.tween_property(station, "position:x", -station_travel, depart_time) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	# 2. Tunnel lights streak past, then the screen fades to black.
	t.tween_callback(_start_riding)
	t.tween_interval(ride_time)
	t.tween_property(fade, "modulate:a", 1.0, fade_time)
	# 3. Black: show the result.
	t.tween_callback(_on_black)
	t.tween_interval(black_hold)
	# 4. The next station slides in while the screen fades back up.
	t.tween_callback(_begin_arrival)
	t.tween_property(fade, "modulate:a", 0.0, fade_time)
	t.parallel().tween_property(station, "position:x", 0.0, depart_time) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	# 5. Arrived: the new round begins.
	t.tween_callback(start_round)


func _start_riding() -> void:
	phase = Phase.RIDING
	tunnel.visible = true


func _on_black() -> void:
	tunnel.visible = false
	# The banner's own fades take 1.0 s, so shorten the hold to end with the black.
	show_banner("Round %d complete" % round_number, maxf(black_hold - 1.0, 0.5))


func _begin_arrival() -> void:
	phase = Phase.ARRIVING
	round_number += 1
	station.position.x = station_travel   # the next station waits ahead, out of view
	show_banner("Round %d" % round_number, 1.0)


func cruise_speed() -> float:
	# With quadratic easing, the final speed is 2 * distance / time.
	return 2.0 * station_travel / depart_time


func build_tunnel() -> void:
	tunnel = Node3D.new()
	tunnel.position = Vector3(0.0, 2.2, 3.5)
	tunnel.visible = false
	add_child(tunnel)

	var mesh := BoxMesh.new()
	mesh.size = Vector3(1.2, 0.15, 0.15)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(1.0, 0.92, 0.65)
	mesh.material = material

	var half_span := tunnel_light_count * tunnel_light_spacing * 0.5
	for i in tunnel_light_count:
		var light := MeshInstance3D.new()
		light.mesh = mesh
		light.position.x = i * tunnel_light_spacing - half_span
		tunnel.add_child(light)
		tunnel_lights.append(light)


func scroll_tunnel(delta: float) -> void:
	var half_span := tunnel_light_count * tunnel_light_spacing * 0.5
	for light in tunnel_lights:
		light.position.x = wrapf(light.position.x - cruise_speed() * delta, -half_span, half_span)


func update_sway() -> void:
	var in_transit := phase == Phase.DEPARTING or phase == Phase.RIDING or phase == Phase.ARRIVING
	var sway := 0.0
	if in_transit:
		sway = sin(Time.get_ticks_msec() * 0.009) * sway_amount
	# shake_strength is tweened during a glitch; it is 0 the rest of the time.
	camera.v_offset = sway + randf_range(-1.0, 1.0) * shake_strength
	camera.h_offset = randf_range(-1.0, 1.0) * shake_strength


# --------------------------------------------------------------- glitch
# Round 2, part 1: the doors never open normally. Turbulence hits, the doors
# fly open by themselves, then snap shut. The player only watches.

func begin_glitches() -> void:
	phase = Phase.GLITCHING
	update_label("")

	var t := create_tween()
	for _i in glitch_count:
		t.tween_interval(glitch_gap)
		t.tween_property(self, "shake_strength", glitch_shake, 0.1)
		t.tween_callback(slide_doors.bind(true, glitch_open_time))
		t.tween_interval(glitch_open_time + glitch_open_hold)
		t.tween_callback(slide_doors.bind(false, glitch_close_time))
		t.tween_property(self, "shake_strength", 0.0, glitch_shake_decay)
	t.tween_callback(begin_thought)


# -------------------------------------------------------------- thought
# Round 2, part 2: the manga "realization" beat. Vignette closes in, a "!"
# pops, a dialogue box types out the character's thoughts.

func build_thought_ui() -> void:
	thought_layer = CanvasLayer.new()
	thought_layer.layer = 2   # above the normal UI layer
	add_child(thought_layer)

	# Vignette: a radial gradient, clear in the middle and dark at the edges.
	var gradient := Gradient.new()
	gradient.set_color(0, Color(0, 0, 0, 0))
	gradient.set_color(1, Color(0, 0, 0, 0.9))
	gradient.add_point(0.45, Color(0, 0, 0, 0))
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	texture.fill_to = Vector2(1.0, 0.5)
	texture.width = 256
	texture.height = 256

	vignette = TextureRect.new()
	vignette.texture = texture
	vignette.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	vignette.stretch_mode = TextureRect.STRETCH_SCALE
	vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vignette.modulate.a = 0.0
	thought_layer.add_child(vignette)
	vignette.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	# The big "!"
	exclaim = Label.new()
	exclaim.text = "!"
	exclaim.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	exclaim.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	exclaim.add_theme_font_size_override("font_size", 180)
	exclaim.add_theme_color_override("font_color", Color(1.0, 0.96, 0.85))
	exclaim.add_theme_color_override("font_outline_color", Color(0.75, 0.1, 0.1))
	exclaim.add_theme_constant_override("outline_size", 28)
	exclaim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	exclaim.modulate.a = 0.0
	thought_layer.add_child(exclaim)
	exclaim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	exclaim.offset_top = -150.0       # shift it above the middle of the screen
	exclaim.offset_bottom = -150.0

	# The dialogue box along the bottom
	dialogue_box = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.04, 0.07, 0.92)
	style.border_color = Color.WHITE
	style.set_border_width_all(3)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(20)
	dialogue_box.add_theme_stylebox_override("panel", style)
	dialogue_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dialogue_box.modulate.a = 0.0
	thought_layer.add_child(dialogue_box)
	dialogue_box.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	dialogue_box.offset_left = 80.0
	dialogue_box.offset_right = -80.0
	dialogue_box.offset_top = -190.0
	dialogue_box.offset_bottom = -40.0

	dialogue_label = Label.new()
	dialogue_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	dialogue_label.add_theme_font_size_override("font_size", 28)
	dialogue_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dialogue_box.add_child(dialogue_label)


func begin_thought() -> void:
	phase = Phase.THINKING
	update_label("")

	var t := create_tween()
	# The vignette closes in.
	t.tween_property(vignette, "modulate:a", 1.0, 0.5)
	# The "!" pops with a jolt.
	t.tween_callback(_pop_exclaim)
	t.tween_interval(0.9)
	# The dialogue box appears and each line types out.
	t.tween_property(dialogue_box, "modulate:a", 1.0, 0.25)
	for line in thought_lines:
		t.tween_callback(_set_line.bind(line))
		t.tween_property(dialogue_label, "visible_ratio", 1.0, line.length() * type_time_per_char)
		t.tween_interval(thought_hold)
	# Everything clears and the fault begins.
	t.tween_property(dialogue_box, "modulate:a", 0.0, 0.3)
	t.parallel().tween_property(exclaim, "modulate:a", 0.0, 0.3)
	t.parallel().tween_property(vignette, "modulate:a", 0.0, 0.6)
	t.tween_callback(begin_fault)


func _pop_exclaim() -> void:
	exclaim.pivot_offset = exclaim.size * 0.5   # scale from the middle, not the corner
	exclaim.modulate.a = 1.0
	exclaim.scale = Vector2.ZERO
	var pop := create_tween()
	pop.tween_property(exclaim, "scale", Vector2.ONE, 0.35) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	var jolt := create_tween()
	jolt.tween_property(self, "shake_strength", glitch_shake * 0.6, 0.05)
	jolt.tween_property(self, "shake_strength", 0.0, 0.4)


func _set_line(line: String) -> void:
	dialogue_label.text = line
	dialogue_label.visible_ratio = 0.0


# ---------------------------------------------------------------- fault
# Round 2, part 3: the doors misbehave at random, 5 to 10 cycles. The player
# can cross out and back in. After the last close the train leaves, so the
# player must be aboard.
#
# Opening and closing motion stays consistent. Only the closed and open waits
# vary, so the player cannot predict when the next movement will begin.

func begin_fault() -> void:
	phase = Phase.FAULT
	fault_over = false
	fault_cycles_left = randi_range(fault_cycles_min, fault_cycles_max)
	door_state = Door.CLOSED
	update_label("Crossings: %d" % crossings)
	_run_fault_cycle(fault_start_delay)


func _run_fault_cycle(extra_wait: float = 0.0) -> void:
	fault_tween = create_tween()
	var t := fault_tween

	# Shut for a random time.
	t.tween_interval(extra_wait + randf_range(fault_closed_min, fault_closed_max))

	# The doors always open fully at the normal, fixed movement speed.
	_door_step(t, 1.0)
	t.tween_interval(randf_range(fault_open_min, fault_open_max))

	# Close fully at the same fixed movement speed.
	_door_step(t, 0.0)
	t.tween_callback(_on_fault_cycle_done)


func _door_step(t: Tween, width: float) -> void:
	# width: 0.0 = shut, 1.0 = fully open. Travel duration is always fixed.
	t.tween_property(door_left, "position:x", lerpf(left_closed_x, left_open_x, width), door_move_time)
	t.parallel().tween_property(door_right, "position:x", lerpf(right_closed_x, right_open_x, width), door_move_time)


func _on_fault_cycle_done() -> void:
	if failed:
		return
	fault_cycles_left -= 1
	if fault_cycles_left > 0:
		_run_fault_cycle()
	else:
		fault_over = true
		resolve_fault()


func resolve_fault() -> void:
	if is_moving:
		return   # wait: _on_walk_finished calls this again once the player lands
	if location == Location.INSIDE:
		end_round()   # doors are shut and the player is aboard: next round
	else:
		fail("You missed the train!")


# --------------------------------------------------------------- player

func can_player_act() -> bool:
	return phase == Phase.PLAYING or phase == Phase.FAULT


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return

	if not is_click_on_doorway(event.position):
		return
	if failed:
		get_tree().reload_current_scene()
		return
	if is_moving or not can_player_act():
		return

	if not doors_passable():
		fail("The gap was too narrow!")
	elif location == Location.PLATFORM:
		start_walk(inside_spot, Location.INSIDE)
	else:
		start_walk(platform_spot, Location.PLATFORM)


func is_click_on_doorway(screen_pos: Vector2) -> bool:
	var origin := camera.project_ray_origin(screen_pos)
	var direction := camera.project_ray_normal(screen_pos)
	if is_zero_approx(direction.z):
		return false

	var plane_z := train.global_position.z
	var distance := (plane_z - origin.z) / direction.z
	if distance < 0.0:
		return false

	var hit := origin + direction * distance
	return absf(hit.x - train.global_position.x) <= doorway_half_width and hit.y >= train.global_position.y and hit.y <= train.global_position.y + doorway_height


func start_walk(spot: Marker3D, destination: Location) -> void:
	is_moving = true
	update_label("")
	walk_tween = create_tween().set_parallel(true)
	walk_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	walk_tween.tween_property(camera, "global_position", spot.global_position, walk_time)
	walk_tween.tween_property(camera, "global_rotation", spot.global_rotation, walk_time)
	walk_tween.finished.connect(_on_walk_finished.bind(destination))


func _on_walk_finished(destination: Location) -> void:
	is_moving = false
	location = destination

	if round_number == 1:
		# Round 1 is the intro: getting inside is the whole goal.
		if destination == Location.INSIDE:
			end_round()
		else:
			update_label("Back on the platform.")
	else:
		crossings += 1
		update_label("Crossings: %d" % crossings)
		if phase == Phase.FAULT and fault_over:
			resolve_fault()


func fail(reason: String) -> void:
	failed = true
	is_moving = false
	if walk_tween and walk_tween.is_valid():
		walk_tween.kill()
	# Stop the fault doors too, or they would keep cycling behind the retry screen.
	if fault_tween and fault_tween.is_valid():
		fault_tween.kill()
	update_label("%s  Crossings: %d" % [reason, crossings] + char(10) + "Click to retry")


func update_label(text: String) -> void:
	status_label.text = text
