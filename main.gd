extends Node3D

enum Door { CLOSED, OPENING, OPEN, CLOSING }
enum Location { PLATFORM, INSIDE }

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

@onready var camera: Camera3D = $Camera3D
@onready var train: Node3D = $Train
@onready var door_left: MeshInstance3D = $Train/DoorLeft
@onready var door_right: MeshInstance3D = $Train/DoorRight
@onready var platform_spot: Marker3D = $PlatformSpot
@onready var inside_spot: Marker3D = $InsideSpot
@onready var status_label: Label = $CanvasLayer/StatusLabel

var left_closed_x: float
var right_closed_x: float
var door_state: Door = Door.CLOSED
var door_timer: float
var location: Location = Location.PLATFORM
var is_moving: bool = false
var failed: bool = false
var crossings: int = 0
var walk_tween: Tween


func _ready() -> void:
	# The closed door positions and starting camera pose are authored in the scene.
	left_closed_x = door_left.position.x
	right_closed_x = door_right.position.x
	door_timer = initial_wait
	update_label("Wait for the doors...")


func _process(delta: float) -> void:
	if failed:
		return

	door_timer -= delta
	if door_timer <= 0.0:
		advance_doors()

	if is_moving and absf(camera.global_position.z - train.global_position.z) < doorway_half_depth and not doors_passable():
		fail("The doors got you!")


func advance_doors() -> void:
	match door_state:
		Door.CLOSED:
			door_state = Door.OPENING
			door_timer = door_move_time
			slide_doors(true)
		Door.OPENING:
			door_state = Door.OPEN
			door_timer = randf_range(open_time_min, open_time_max)
		Door.OPEN:
			door_state = Door.CLOSING
			door_timer = door_move_time
			slide_doors(false)
		Door.CLOSING:
			door_state = Door.CLOSED
			door_timer = closed_time


func slide_doors(open: bool) -> void:
	var left_target := left_open_x if open else left_closed_x
	var right_target := right_open_x if open else right_closed_x
	var tween := create_tween().set_parallel(true)
	tween.tween_property(door_left, "position:x", left_target, door_move_time)
	tween.tween_property(door_right, "position:x", right_target, door_move_time)


func doors_passable() -> bool:
	return door_left.position.x <= passable_left_x


func doors_fully_open() -> bool:
	return door_state == Door.OPEN and is_equal_approx(door_left.position.x, left_open_x) and is_equal_approx(door_right.position.x, right_open_x)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return

	if not is_click_on_doorway(event.position):
		return
	if failed:
		get_tree().reload_current_scene()
		return
	if is_moving:
		return

	if not doors_fully_open():
		fail("You went for the doors too early or too late!")
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
