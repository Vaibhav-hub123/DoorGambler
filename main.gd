extends Node3D

enum Door { CLOSED, OPENING, OPEN, CLOSING }
enum Location { PLATFORM, INSIDE }
enum Phase { PLAYING, LEAVING, DEPARTING, RIDING, ARRIVING }

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
@export var ride_time := 6.0              # cruising through the tunnel
@export var station_travel := 60.0        # how far the station slides, in units
@export var arrival_open_delay := 0.8     # pause before the doors open at the next stop
@export var sway_amount := 0.015          # camera shake while the train moves
@export var tunnel_light_count := 20
@export var tunnel_light_spacing := 3.5

@export_group("Rounds")
@export var leave_close_delay := 0.8      # after a round ends, how soon the doors close
@export var banner_hold := 2.0            # how long "Round N" stays fully visible

@onready var camera: Camera3D = $Camera3D
@onready var train: Node3D = $Train
@onready var station: Node3D = $Station
@onready var door_left: MeshInstance3D = $Train/DoorLeft
@onready var door_right: MeshInstance3D = $Train/DoorRight
@onready var platform_spot: Marker3D = $PlatformSpot
@onready var inside_spot: Marker3D = $InsideSpot
@onready var status_label: Label = $CanvasLayer/StatusLabel
@onready var round_label: Label = $CanvasLayer/RoundLabel

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
var walk_tween: Tween
var banner_tween: Tween
var tunnel: Node3D
var tunnel_lights: Array[MeshInstance3D] = []


func _ready() -> void:
	# The closed door positions and starting camera pose are authored in the scene.
	left_closed_x = door_left.position.x
	right_closed_x = door_right.position.x
	door_timer = initial_wait
	round_label.modulate.a = 0.0
	build_tunnel()
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
		Phase.RIDING:
			scroll_tunnel(delta)


# ---------------------------------------------------------------- doors

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
			if phase == Phase.LEAVING:
				door_timer = leave_close_delay   # the round is over: close up quickly
			else:
				door_timer = randf_range(open_time_min, open_time_max)
		Door.OPEN:
			door_state = Door.CLOSING
			door_timer = door_move_time
			slide_doors(false)
		Door.CLOSING:
			door_state = Door.CLOSED
			door_timer = closed_time
			# Doors just shut after the round ended: the train leaves.
			if phase == Phase.LEAVING:
				begin_departure()


func slide_doors(open: bool) -> void:
	var left_target := left_open_x if open else left_closed_x
	var right_target := right_open_x if open else right_closed_x
	var tween := create_tween().set_parallel(true)
	tween.tween_property(door_left, "position:x", left_target, door_move_time)
	tween.tween_property(door_right, "position:x", right_target, door_move_time)


func doors_passable() -> bool:
	return door_left.position.x <= passable_left_x


func check_doorway_crush() -> void:
	var depth := absf(camera.global_position.z - train.global_position.z)
	if is_moving and depth < doorway_half_depth and not doors_passable():
		fail("The doors got you!")


# --------------------------------------------------------------- rounds

func complete_round() -> void:
	phase = Phase.LEAVING
	update_label("")
	show_banner("Round %d complete" % round_number)
	# The doors may be in any phase right now. Each case needs a different nudge.
	match door_state:
		Door.OPEN:
			door_timer = minf(door_timer, leave_close_delay)
		Door.CLOSED:
			begin_departure()
		# OPENING and CLOSING are handled inside advance_doors().


func start_next_round() -> void:
	round_number += 1
	phase = Phase.PLAYING
	crossings = 0
	door_state = Door.CLOSED
	door_timer = arrival_open_delay
	show_banner("Round %d" % round_number)
	update_label("Next stop. The doors open.")


func show_banner(text: String) -> void:
	# Kill the previous banner first, or two fades would fight over the alpha.
	if banner_tween and banner_tween.is_valid():
		banner_tween.kill()
	round_label.text = text
	banner_tween = create_tween()
	banner_tween.tween_property(round_label, "modulate:a", 1.0, 0.4)
	banner_tween.tween_interval(banner_hold)
	banner_tween.tween_property(round_label, "modulate:a", 0.0, 0.6)


# ----------------------------------------------------------------- ride
# The ride is the transition between rounds.

func begin_departure() -> void:
	phase = Phase.DEPARTING
	update_label("The train pulls out.")

	# One tween, run step by step: slide out, ride, slide in, next round.
	var t := create_tween()
	t.tween_property(station, "position:x", -station_travel, depart_time) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	t.tween_callback(_start_riding)
	t.tween_interval(ride_time)
	t.tween_callback(_start_arriving)
	t.tween_property(station, "position:x", 0.0, depart_time) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	t.tween_callback(start_next_round)


func _start_riding() -> void:
	phase = Phase.RIDING
	tunnel.visible = true
	update_label("")


func _start_arriving() -> void:
	phase = Phase.ARRIVING
	tunnel.visible = false
	station.position.x = station_travel   # the next station waits ahead, out of view
	update_label("Approaching the next stop.")


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
	if in_transit:
		camera.v_offset = sin(Time.get_ticks_msec() * 0.009) * sway_amount
	else:
		camera.v_offset = 0.0


# --------------------------------------------------------------- player

func can_player_act() -> bool:
	return phase == Phase.PLAYING


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
			complete_round()
		else:
			update_label("Back on the platform.")
	else:
		crossings += 1
		update_label("Crossings: %d" % crossings)


func fail(reason: String) -> void:
	failed = true
	is_moving = false
	if walk_tween and walk_tween.is_valid():
		walk_tween.kill()
	update_label("%s  Crossings: %d" % [reason, crossings] + char(10) + "Click to retry")


func update_label(text: String) -> void:
	status_label.text = text
