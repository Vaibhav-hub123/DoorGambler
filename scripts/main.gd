extends Node3D

enum State { WAITING, PLATFORM_READY, MOVING, INSIDE }

@onready var camera: Camera3D = $Camera3D
@onready var door_left: MeshInstance3D = $Train/DoorLeft
@onready var door_right: MeshInstance3D = $Train/DoorRight
@onready var platform_spot: Marker3D = $PlatformSpot
@onready var inside_spot: Marker3D = $InsideSpot

var state: State = State.WAITING


func _ready() -> void:
	# Start the player on the platform, facing the train.
	camera.global_transform = platform_spot.global_transform
	# Doors open after a short pause.
	await get_tree().create_timer(1.5).timeout
	await open_doors()
	state = State.PLATFORM_READY


func open_doors() -> void:
	var t := create_tween().set_parallel(true)
	t.tween_property(door_left, "position:x", -1.5, 1.0)
	t.tween_property(door_right, "position:x", 1.5, 1.0)
	await t.finished


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton \
			and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		match state:
			State.PLATFORM_READY:
				move_to(inside_spot, State.INSIDE)
			State.INSIDE:
				move_to(platform_spot, State.PLATFORM_READY)
			# WAITING and MOVING fall through: clicks are ignored.


func move_to(spot: Marker3D, next_state: State) -> void:
	state = State.MOVING  # locks input immediately
	var t := create_tween().set_parallel(true)
	t.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	t.tween_property(camera, "global_position", spot.global_position, 1.2)
	t.tween_property(camera, "global_rotation", spot.global_rotation, 1.2)
	await t.finished
	state = next_state
