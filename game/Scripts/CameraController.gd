# open-tabletop
# Copyright (c) 2020 Benjamin 'drwhut' Beddows
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

extends Spatial

signal adding_cards_to_hand(cards, id) # If id is 0, add to nearest hand.
signal collect_pieces_requested(pieces)
signal dealing_cards(stack, n)
signal hover_piece_requested(piece, offset)
signal pop_stack_requested(stack, n)
signal selecting_all_pieces()
signal setting_spawn_point(position)
signal spawning_piece_at(position)
signal stack_collect_all_requested(stack, collect_stacks)

onready var _box_selection_rect = $BoxSelectionRect
onready var _camera = $Camera
onready var _cursors = $Cursors
onready var _piece_context_menu = $PieceContextMenu
onready var _piece_context_menu_container = $PieceContextMenu/VBoxContainer

const CURSOR_LERP_SCALE = 100.0
const GRABBING_SLOW_TIME = 0.25
const HOVER_Y_MIN = 1.0
const MOVEMENT_ACCEL_SCALAR = 0.125
const MOVEMENT_DECEL_SCALAR = 0.25
const RAY_LENGTH = 1000
const ROTATION_Y_MAX = -0.2
const ROTATION_Y_MIN = -1.5
const ZOOM_ACCEL_SCALAR = 3.0
const ZOOM_DISTANCE_MIN = 2.0
const ZOOM_DISTANCE_MAX = 200.0

export(bool) var hold_left_click_to_move: bool = false
export(float) var lift_sensitivity: float = 1.0
export(float) var max_speed: float = 10.0
export(bool) var piece_rotate_invert: bool = false
export(bool) var piece_rotate_alt: bool = true
export(float) var rotation_sensitivity_x: float = -0.01
export(float) var rotation_sensitivity_y: float = -0.01
export(float) var zoom_sensitivity: float = 1.0

var send_cursor_position: bool = false

var _box_select_init_pos = Vector2()
var _cursor_position = Vector3()
var _drag_camera_anchor = Vector3()
var _grabbing_time = 0.0
var _hover_y_pos = 10.0
var _initial_transform = Transform.IDENTITY
var _initial_zoom = 0.0
var _is_box_selecting = false
var _is_dragging_camera = false
var _is_grabbing_selected = false
var _is_hovering_selected = false
var _last_sent_cursor_position = Vector3()
var _movement_accel = 0.0
var _movement_dir = Vector3()
var _movement_vel = Vector3()
var _perform_box_select = false
var _piece_mouse_is_over: Piece = null
var _piece_rotation_amount = 1.0
var _right_click_pos = Vector2()
var _rotation = Vector2()
var _selected_pieces = []
var _spawn_point_position = Vector3()
var _target_zoom = 0.0
var _viewport_size_original = Vector2()

# Append an array of pieces to the list of selected pieces.
# pieces: The array of pieces to now be selected.
func append_selected_pieces(pieces: Array) -> void:
	for piece in pieces:
		if piece is Piece and (not piece in _selected_pieces):
			_selected_pieces.append(piece)
			piece.set_appear_selected(true)

# Apply options from the options menu.
# config: The options to apply.
func apply_options(config: ConfigFile) -> void:
	_camera.fov = config.get_value("video", "fov")
	
	rotation_sensitivity_x = -0.1 * config.get_value("controls", "mouse_horizontal_sensitivity")
	if config.get_value("controls", "mouse_horizontal_invert"):
		rotation_sensitivity_x *= -1
	
	rotation_sensitivity_y = -0.1 * config.get_value("controls", "mouse_vertical_sensitivity")
	if config.get_value("controls", "mouse_vertical_invert"):
		rotation_sensitivity_y *= -1
	
	max_speed = 10.0 + 190.0 * config.get_value("controls", "camera_movement_speed")
	
	hold_left_click_to_move = config.get_value("controls", "left_click_to_move")
	
	zoom_sensitivity = 1.0 + 15.0 * config.get_value("controls", "zoom_sensitivity")
	if config.get_value("controls", "zoom_invert"):
		zoom_sensitivity *= -1
	
	lift_sensitivity = 0.5 + 4.5 * config.get_value("controls", "piece_lift_sensitivity")
	if config.get_value("controls", "piece_lift_invert"):
		lift_sensitivity *= -1
	
	piece_rotate_invert = config.get_value("controls", "piece_rotation_invert")
	piece_rotate_alt = config.get_value("controls", "alt_to_rotate")
	
	_cursors.visible = not config.get_value("multiplayer", "hide_cursors")

# Clear the list of selected pieces.
func clear_selected_pieces() -> void:
	for piece in _selected_pieces:
		piece.set_appear_selected(false)
	
	_selected_pieces.clear()

# Erase a piece from the list of selected pieces.
# piece: The piece to erase from the list.
func erase_selected_pieces(piece: Piece) -> void:
	if _selected_pieces.has(piece):
		_selected_pieces.erase(piece)
		piece.set_appear_selected(false)

# Get the current position that pieces should hover at, given the camera and
# mouse positions.
# Returns: The position that hovering pieces should hover at.
func get_hover_position() -> Vector3:
	return _calculate_hover_position(get_viewport().get_mouse_position(), _hover_y_pos)

# Get the list of selected pieces.
# Returns: The list of selected pieces.
func get_selected_pieces() -> Array:
	return _selected_pieces

# Request the server to set your cursor to the "grabbing" cursor on all other
# clients.
# grabbing: Whether the cursor should be the "grabbing" cursor.
master func request_set_cursor_grabbing(grabbing: bool) -> void:
	var id = get_tree().get_rpc_sender_id()
	rpc("set_player_cursor_grabbing", id, grabbing)

# Request the server to set your 3D cursor position to all other players.
# position: Your new 3D cursor position.
# x_basis: The x-basis of your camera.
master func request_set_cursor_position(position: Vector3, x_basis: Vector3) -> void:
	var id = get_tree().get_rpc_sender_id()
	for other_id in Lobby.get_player_list():
		if other_id != id:
			rpc_unreliable_id(other_id, "set_player_cursor_position", id, position, x_basis)

# Set if the camera is hovering it's selected pieces.
# is_hovering: If the camera is hovering it's selected pieces.
func set_is_hovering(is_hovering: bool) -> void:
	_is_hovering_selected = is_hovering
	
	var cursor = Input.CURSOR_ARROW
	if is_hovering:
		cursor = Input.CURSOR_DRAG
		
		# If we have started hovering, we have stopped grabbing.
		_is_grabbing_selected = false
	
	Input.set_default_cursor_shape(cursor)
	
	rpc_id(1, "request_set_cursor_grabbing", is_hovering)

# Called by the server when a player updates their hovering state.
# id: The ID of the player.
# grabbing: Whether the cursor should be the "grabbing" shape.
puppet func set_player_cursor_grabbing(id: int, grabbing: bool) -> void:
	if get_tree().get_rpc_sender_id() != 1:
		return
	
	if id == get_tree().get_network_unique_id():
		return
	
	if not _cursors.has_node(str(id)):
		return
	
	var cursor = _cursors.get_node(str(id))
	if not cursor:
		return
	if not cursor is TextureRect:
		return
	
	cursor.texture = _create_player_cursor_texture(id, grabbing)

# Called by the server when a player updates their 3D cursor position.
# id: The ID of the player.
# position: The position of the player's 3D cursor.
# x_basis: The x-basis of the player's camera.
puppet func set_player_cursor_position(id: int, position: Vector3, x_basis: Vector3) -> void:
	if get_tree().get_rpc_sender_id() != 1:
		return
	
	if id == get_tree().get_network_unique_id():
		return
	
	if not _cursors.has_node(str(id)):
		return
	
	var cursor = _cursors.get_node(str(id))
	if not cursor:
		return
	if not cursor is TextureRect:
		return
	
	cursor.set_meta("cursor_position", position)
	cursor.set_meta("x_basis", x_basis)

# Set the controller's piece rotation amount.
# rotation_amount: The piece rotation amount in radians.
func set_piece_rotation_amount(rotation_amount: float) -> void:
	_piece_rotation_amount = min(max(rotation_amount, 0.0), 2 * PI)

# Set the list of selected pieces.
# pieces: The new list of selected pieces.
func set_selected_pieces(pieces: Array) -> void:
	clear_selected_pieces()
	append_selected_pieces(pieces)

func _ready():
	_viewport_size_original.x = ProjectSettings.get_setting("display/window/size/width")
	_viewport_size_original.y = ProjectSettings.get_setting("display/window/size/height")
	get_viewport().connect("size_changed", self, "_on_Viewport_size_changed")
	
	Lobby.connect("player_added", self, "_on_Lobby_player_added")
	Lobby.connect("player_modified", self, "_on_Lobby_player_modified")
	Lobby.connect("player_removed", self, "_on_Lobby_player_removed")
	
	# Get the initial transform and zoom of the camera so we can set it back
	# to these values later.
	_initial_transform = transform
	_initial_zoom = _camera.translation.z
	_reset_camera()

func _process(delta):
	if _is_grabbing_selected:
		_grabbing_time += delta
		
		# Have we been grabbing this piece for a long time?
		if _grabbing_time > GRABBING_SLOW_TIME:
			_start_hovering_grabbed_piece(false)
	
	for cursor in _cursors.get_children():
		if cursor is TextureRect:
			if cursor.has_meta("cursor_position") and cursor.has_meta("x_basis"):
				var current_position = cursor.rect_position
				var target_position = _camera.unproject_position(cursor.get_meta("cursor_position"))
				cursor.rect_position = current_position.linear_interpolate(target_position, CURSOR_LERP_SCALE * delta)
				
				var our_basis = transform.basis.x.normalized()
				var their_basis = cursor.get_meta("x_basis").normalized()
				var cos_theta = our_basis.dot(their_basis)
				var cross = our_basis.cross(their_basis)
				var sin_theta = cross.length()
				if cross.y < 0:
					sin_theta = -sin_theta
				var target_theta = acos(cos_theta)
				# If the camera goes one way, the cursor needs to go the other
				# way. This is why the if statement isn't < 0.
				if sin_theta > 0:
					target_theta = -target_theta
				var current_theta = deg2rad(cursor.rect_rotation)
				cursor.rect_rotation = rad2deg(lerp_angle(current_theta, target_theta, CURSOR_LERP_SCALE * delta))

func _physics_process(delta):
	_process_input(delta)
	_process_movement(delta)
	
	# Perform a raycast out into the world from the camera.
	var mouse_pos = get_viewport().get_mouse_position()
	var from = _camera.project_ray_origin(mouse_pos)
	var to = from + _camera.project_ray_normal(mouse_pos) * RAY_LENGTH
	
	var space_state = get_world().direct_space_state
	var result = space_state.intersect_ray(from, to)
	
	_piece_mouse_is_over = null
	
	if result.has("collider"):
		_cursor_position = result["position"]
		if result.collider is Piece:
			_piece_mouse_is_over = result.collider
	
	if send_cursor_position and _cursor_position:
		if _cursor_position != _last_sent_cursor_position:
			if _is_hovering_selected and (not _selected_pieces.empty()):
				if _piece_mouse_is_over and _selected_pieces.has(_piece_mouse_is_over):
					_cursor_position = _piece_mouse_is_over.transform.origin
				else:
					var total = Vector3()
					for piece in _selected_pieces:
						total += piece.transform.origin
					_cursor_position = total / _selected_pieces.size()
			rpc_unreliable_id(1, "request_set_cursor_position", _cursor_position,
				transform.basis.x)
			_last_sent_cursor_position = _cursor_position
	
	if _perform_box_select:
		var query_params = PhysicsShapeQueryParameters.new()
		
		var box_rect = Rect2(_box_selection_rect.rect_position, _box_selection_rect.rect_size)
		
		# Create a frustum from the box position and size.
		var shape = ConvexPolygonShape.new()
		var points = []
		
		var middle = box_rect.position + box_rect.size / 2
		var box_from = _camera.project_ray_origin(middle)
		points.append(box_from)
		
		for dx in [0, 1]:
			for dy in [0, 1]:
				var size = Vector2(box_rect.size.x * dx, box_rect.size.y * dy)
				var box_pos = box_rect.position + size
				var box_to = box_from + _camera.project_ray_normal(box_pos) * RAY_LENGTH
				points.append(box_to)
		
		shape.points = points
		query_params.set_shape(shape)
		
		var results = space_state.intersect_shape(query_params, 1024)
		
		for box_result in results:
			if box_result.has("collider"):
				if box_result.collider is Piece:
					append_selected_pieces([box_result.collider])
		
		_perform_box_select = false

func _process_input(delta):
	
	# Calculating the direction the user wants to move parallel to the table.
	var movement_input = Vector2()
	
	if not Input.is_key_pressed(KEY_CONTROL):
		if Input.is_action_pressed("game_left"):
			movement_input.x -= 1
		if Input.is_action_pressed("game_right"):
			movement_input.x += 1
		if Input.is_action_pressed("game_up"):
			movement_input.y += 1
		if Input.is_action_pressed("game_down"):
			movement_input.y -= 1
	
	movement_input = movement_input.normalized()
	
	_movement_dir = Vector3()
	
	# Moving side-to-side is fine, since the x basis should always be parallel
	# to the table...
	_movement_dir += transform.basis.x * movement_input.x
	
	# ... but we want to move forward along the horizontal plane parallel to
	# the table, and since we can move the camera to be looking at the table,
	# we need to adjust the z basis here.
	var z_basis = transform.basis.z
	z_basis.y = 0
	z_basis = z_basis.normalized()
	_movement_dir += -z_basis * movement_input.y
	
	var is_accelerating = _movement_dir.dot(_movement_vel) > 0
	
	_movement_accel = max_speed
	if is_accelerating:
		_movement_accel *= MOVEMENT_ACCEL_SCALAR
	else:
		_movement_accel *= MOVEMENT_DECEL_SCALAR

func _process_movement(delta):
	var target_vel = _movement_dir * max_speed
	_movement_vel = _movement_vel.linear_interpolate(target_vel, _movement_accel * delta)
	
	# A global translation, as we want to move on the plane parallel to the
	# table, regardless of the direction we are facing.
	var old_translation = translation
	translation += _movement_vel * delta
	
	# If we ended up moving...
	if translation != old_translation:
		_on_moving()
	
	# Go towards the target zoom level.
	var target_offset = Vector3(0, 0, _target_zoom)
	var zoom_accel = zoom_sensitivity * ZOOM_ACCEL_SCALAR
	_camera.translation = _camera.translation.linear_interpolate(target_offset, zoom_accel * delta)

func _unhandled_input(event):
	if event.is_action_pressed("game_reset_camera"):
		_reset_camera()
	elif event.is_action_pressed("game_delete_piece"):
		_delete_selected_pieces()
	elif event.is_action_pressed("game_lock_piece"):
		var all_locked = true
		for piece in _selected_pieces:
			if piece is Piece:
				if not piece.is_locked():
					all_locked = false
					break
		if all_locked:
			_unlock_selected_pieces()
		else:
			_lock_selected_pieces()
	elif event.is_action_pressed("game_flip_piece"):
		for piece in _selected_pieces:
			if piece is Piece:
				piece.rpc_id(1, "flip_vertically")
	elif event.is_action_pressed("game_reset_piece"):
		for piece in _selected_pieces:
			if piece is Piece:
				piece.rpc_id(1, "reset_orientation")
	
	if event is InputEventKey:
		if event.scancode == KEY_A and event.control:
			if event.is_pressed():
				# Select all of the pieces on the table.
				emit_signal("selecting_all_pieces")
	
	elif event is InputEventMouseButton:
		
		if event.button_index == BUTTON_LEFT:
			if event.is_pressed():
				if _piece_mouse_is_over:
					if event.control:
						append_selected_pieces([_piece_mouse_is_over])
					else:
						if not _selected_pieces.has(_piece_mouse_is_over):
							set_selected_pieces([_piece_mouse_is_over])
						_is_grabbing_selected = true
						_grabbing_time = 0.0
				else:
					if not event.control:
						clear_selected_pieces()
					
					if hold_left_click_to_move:
						# Start dragging the camera with the mouse.
						_drag_camera_anchor = _calculate_hover_position(event.position, 0.0)
						_is_dragging_camera = true
					else:
						# Start box selecting.
						_box_select_init_pos = event.position
						_is_box_selecting = true
						
						_box_selection_rect.rect_position = _box_select_init_pos
						_box_selection_rect.rect_size = Vector2()
						_box_selection_rect.visible = true
			else:
				_is_dragging_camera = false
				_is_grabbing_selected = false
				
				if _is_hovering_selected:
					var cards = []
					var adding_card_to_hand = false
					for piece in _selected_pieces:
						if piece.get("over_hand") != null:
							cards.append(piece)
							if piece.over_hand > 0:
								adding_card_to_hand = true
						piece.rpc_id(1, "stop_hovering")
					
					set_is_hovering(false)
					
					if adding_card_to_hand:
						emit_signal("adding_cards_to_hand", cards, 0)
				
				# Stop box selecting.
				if _is_box_selecting:
					_box_selection_rect.visible = false
					_is_box_selecting = false
					_perform_box_select = true
		
		elif event.button_index == BUTTON_RIGHT:
			if _is_hovering_selected:
				# TODO: Consider doing something here, like randomizing dice
				# or shuffling stacks?
				pass
			else:
				# Only bring up the context menu if the mouse didn't move
				# between the press and the release of the RMB.
				if event.is_pressed():
					if _piece_mouse_is_over:
						if not _selected_pieces.has(_piece_mouse_is_over):
							set_selected_pieces([_piece_mouse_is_over])
					else:
						clear_selected_pieces()
					_right_click_pos = event.position
				else:
					if event.position == _right_click_pos:
						if _selected_pieces.empty():
							_popup_table_context_menu()
							_spawn_point_position = _cursor_position
							_spawn_point_position.y += Piece.SPAWN_HEIGHT
						else:
							_popup_piece_context_menu()
		
		elif event.is_pressed() and (event.button_index == BUTTON_WHEEL_UP or
			event.button_index == BUTTON_WHEEL_DOWN):
			
			if _is_hovering_selected:
				var option1 = piece_rotate_alt and (not event.alt)
				var option2 = (not piece_rotate_alt) and event.alt
				if option1 or option2:
					# Changing the y-position of hovered pieces.
					var offset = 0
					
					if event.button_index == BUTTON_WHEEL_UP:
						offset = -lift_sensitivity
					else:
						offset = lift_sensitivity
					
					var new_y = _hover_y_pos + offset
					_hover_y_pos = max(new_y, HOVER_Y_MIN)
					
					_on_moving()
				else:
					# Changing the rotation of the hovered pieces.
					var amount = _piece_rotation_amount
					if event.button_index == BUTTON_WHEEL_DOWN:
						amount *= -1
					if piece_rotate_invert:
						amount *= -1
					for piece in _selected_pieces:
						piece.rpc_id(1, "rotate_y", amount)
			else:
				# Zooming the camera in and away from the controller.
				var offset = 0
				
				if event.button_index == BUTTON_WHEEL_UP:
					offset = -zoom_sensitivity
				else:
					offset = zoom_sensitivity
				
				var new_zoom = _target_zoom + offset
				_target_zoom = max(min(new_zoom, ZOOM_DISTANCE_MAX), ZOOM_DISTANCE_MIN)
			
			get_tree().set_input_as_handled()
	
	elif event is InputEventMouseMotion:
		# Check if by moving the mouse, we either started hovering a piece, or
		# we have moved the hovered pieces position.
		if _on_moving():
			pass
		
		elif Input.is_action_pressed("game_rotate"):
		
			# Rotating the controller-camera system to get the camera to rotate
			# around a point, where the controller is.
			_rotation.x += event.relative.x * rotation_sensitivity_x
			_rotation.y += event.relative.y * rotation_sensitivity_y
			
			# Bound the rotation along the X axis.
			_rotation.y = max(_rotation.y, ROTATION_Y_MIN)
			_rotation.y = min(_rotation.y, ROTATION_Y_MAX)
			
			transform.basis = Basis()
			rotate_x(_rotation.y)
			rotate_y(_rotation.x)
			
			get_tree().set_input_as_handled()
		
		elif _is_dragging_camera:
			var new_anchor = _calculate_hover_position(event.position, 0.0)
			var diff_anchor = new_anchor - _drag_camera_anchor
			translation -= diff_anchor
		
		elif _is_box_selecting:
			
			var pos = _box_select_init_pos
			var size = event.position - _box_select_init_pos
			
			if size.x < 0:
				pos.x += size.x
				size.x = -size.x
			
			if size.y < 0:
				pos.y += size.y
				size.y = -size.y
			
			_box_selection_rect.rect_position = pos
			_box_selection_rect.rect_size = size
			
			get_tree().set_input_as_handled()

# Calculate the hover position of a piece, given a mouse position on the screen.
# Returns: The hover position of a piece, based on the given mouse position.
# mouse_position: The mouse position on the screen.
# y_position: The y-position of the hover position.
func _calculate_hover_position(mouse_position: Vector2, y_position: float) -> Vector3:
	# Get vectors representing a raycast from the camera.
	var from = _camera.project_ray_origin(mouse_position)
	var to = from + _camera.project_ray_normal(mouse_position) * RAY_LENGTH
	
	# Figure out at which point along this line the piece should hover at,
	# given we want it to hover at a particular Y-level.
	var lambda = (y_position - from.y) / (to.y - from.y)
	
	var x = from.x + lambda * (to.x - from.x)
	var z = from.z + lambda * (to.z - from.z)
	
	return Vector3(x, y_position, z)

# Create a cursor texture representing a given player.
# Returns: A cursor texture representing a given player.
# id: The ID of the player.
# grabbing: If the cursor should be the "grabbing" cursor.
func _create_player_cursor_texture(id: int, grabbing: bool) -> ImageTexture:
	var cursor_image: Image = null
	if grabbing:
		cursor_image = preload("res://Images/GrabbingCursor.png")
	else:
		cursor_image = preload("res://Images/ArrowCursor.png")
	
	# Create a clone of the image, so we don't modify the original.
	var clone_image = Image.new()
	cursor_image.lock()
	clone_image.create_from_data(cursor_image.get_width(),
		cursor_image.get_height(), false, cursor_image.get_format(),
		cursor_image.get_data())
	cursor_image.unlock()
	
	# Get the player's color.
	var mask_color = Color.white
	if Lobby.player_exists(id):
		var player = Lobby.get_player(id)
		if player.has("color"):
			mask_color = player["color"]
			mask_color.a = 1.0
	
	# Perform a multiply operation on the image.
	clone_image.lock()
	for x in range(clone_image.get_width()):
		for y in range(clone_image.get_height()):
			var pixel = clone_image.get_pixel(x, y)
			clone_image.set_pixel(x, y, pixel * mask_color)
	clone_image.unlock()
	
	var new_texture = ImageTexture.new()
	new_texture.create_from_image(clone_image)
	return new_texture

# Delete the currently selected pieces from the game.
func _delete_selected_pieces() -> void:
	_hide_context_menu()
	# Go in reverse order, as we are removing the pieces as we go.
	for i in range(_selected_pieces.size() - 1, -1, -1):
		var piece = _selected_pieces[i]
		if piece is Piece:
			piece.rpc_id(1, "request_remove_self")

# Get the scale nessesary to make cursors appear the same size regardless of
# resolution.
# Returns: The scale.
func _get_cursor_scale() -> Vector2:
	var from = get_viewport().size
	var to = _viewport_size_original
	
	var out = Vector2(to.x / from.x, to.y / from.y)
	
	return out

# Get the inheritance of a piece, which is the array of classes represented as
# strings, that the piece is based on. The last element of the array should
# always represent the Piece class.
# Returns: The array of inheritance of the piece.
# piece: The piece to get the inheritance of.
func _get_piece_inheritance(piece: Piece) -> Array:
	var inheritance = []
	var script = piece.get_script()
	
	while script:
		inheritance.append(script.resource_path)
		script = script.get_base_script()
	
	return inheritance

# Hide the context menu.
func _hide_context_menu():
	_piece_context_menu.visible = false

# Check if an inheritance array has a particular class.
# Returns: If the queried class is in the inheritance array.
# inheritance: The inheritance array to check. Generated with
# _get_piece_inheritance.
# query: The class to query, as a string.
func _inheritance_has(inheritance: Array, query: String) -> bool:
	for piece_class in inheritance:
		if piece_class.ends_with("/" + query + ".gd"):
			return true
	return false

# Lock the currently selected pieces.
func _lock_selected_pieces() -> void:
	_hide_context_menu()
	for piece in _selected_pieces:
		if piece is Piece:
			piece.rpc_id(1, "request_lock")

func _on_context_collect_all_pressed() -> void:
	_hide_context_menu()
	if _selected_pieces.size() == 1:
		var piece = _selected_pieces[0]
		if piece is Stack:
			emit_signal("stack_collect_all_requested", piece, true)

func _on_context_collect_individuals_pressed() -> void:
	_hide_context_menu()
	if _selected_pieces.size() == 1:
		var piece = _selected_pieces[0]
		if piece is Stack:
			emit_signal("stack_collect_all_requested", piece, false)

func _on_context_collect_selected_pressed() -> void:
	_hide_context_menu()
	if _selected_pieces.size() > 1:
		emit_signal("collect_pieces_requested", _selected_pieces)

func _on_context_deal_cards_pressed(n: int) -> void:
	_hide_context_menu()
	emit_signal("dealing_cards", _selected_pieces[0], n)

func _on_context_delete_pressed() -> void:
	_delete_selected_pieces()

func _on_context_lock_pressed() -> void:
	_lock_selected_pieces()

func _on_context_orient_down_pressed() -> void:
	_hide_context_menu()
	for piece in _selected_pieces:
		if piece is Stack:
			piece.rpc_id(1, "request_orient_pieces", false)

func _on_context_orient_up_pressed() -> void:
	_hide_context_menu()
	for piece in _selected_pieces:
		if piece is Stack:
			piece.rpc_id(1, "request_orient_pieces", true)

func _on_context_put_in_hand_pressed() -> void:
	_hide_context_menu()
	emit_signal("adding_cards_to_hand", _selected_pieces, get_tree().get_network_unique_id())

func _on_context_shuffle_pressed() -> void:
	_hide_context_menu()
	for piece in _selected_pieces:
		if piece is Stack:
			piece.rpc_id(1, "request_shuffle")

func _on_context_sort_pressed() -> void:
	_hide_context_menu()
	for piece in _selected_pieces:
		if piece is Stack:
			piece.rpc_id(1, "request_sort")

func _on_context_spawn_object_pressed() -> void:
	_hide_context_menu()
	emit_signal("spawning_piece_at", _spawn_point_position)

func _on_context_spawn_point_pressed() -> void:
	_hide_context_menu()
	emit_signal("setting_spawn_point", _spawn_point_position)

func _on_context_take_top_pressed(n: int) -> void:
	_hide_context_menu()
	if _selected_pieces.size() == 1:
		var piece = _selected_pieces[0]
		if piece is Stack:
			clear_selected_pieces()
			emit_signal("pop_stack_requested", piece, n)

func _on_context_unlock_pressed() -> void:
	_unlock_selected_pieces()

# Popup the piece context menu.
func _popup_piece_context_menu() -> void:
	if _selected_pieces.size() == 0:
		return
	
	# Get the inheritance (e.g. Dice <- Piece) of the first piece in the array,
	# then reduce the inheritance down to the most common inheritance of all of
	# the pieces in the array.
	var inheritance = _get_piece_inheritance(_selected_pieces[0])
	
	for i in range(1, _selected_pieces.size()):
		if inheritance.size() <= 1:
			break
		
		var other_inheritance = _get_piece_inheritance(_selected_pieces[i])
		var cut_off = 0
		for piece_class in inheritance:
			if other_inheritance.has(piece_class):
				break
			cut_off += 1
		inheritance = inheritance.slice(cut_off, inheritance.size() - 1)
	
	# Populate the context menu, given the inheritance.
	for child in _piece_context_menu_container.get_children():
		_piece_context_menu_container.remove_child(child)
		child.queue_free()
	
	########
	# INFO #
	########
	
	if _inheritance_has(inheritance, "Stack"):
		
		# TODO: Figure out a way to update this label if the count changes.
		var count = 0
		for stack in _selected_pieces:
			count += stack.get_piece_count()
		
		var count_label = Label.new()
		count_label.text = "Count: %d" % count
		_piece_context_menu_container.add_child(count_label)
	
	###########
	# LEVEL 2 #
	###########
	
	if _inheritance_has(inheritance, "Card"):
		var put_in_hand_button = Button.new()
		put_in_hand_button.text = "Put in hand"
		put_in_hand_button.connect("pressed", self, "_on_context_put_in_hand_pressed")
		_piece_context_menu_container.add_child(put_in_hand_button)
	
	if _inheritance_has(inheritance, "Stack"):
		if _selected_pieces.size() == 1:
			var collect_individuals_button = Button.new()
			collect_individuals_button.text = "Collect individuals"
			collect_individuals_button.connect("pressed", self, "_on_context_collect_individuals_pressed")
			_piece_context_menu_container.add_child(collect_individuals_button)
			
			var collect_all_button = Button.new()
			collect_all_button.text = "Collect all"
			collect_all_button.connect("pressed", self, "_on_context_collect_all_pressed")
			_piece_context_menu_container.add_child(collect_all_button)
			
			var stack = _selected_pieces[0]
			var test_piece = load(stack.piece_entry["scene_path"]).instance()
			var is_card_stack = test_piece is Card
			test_piece.free()
			
			if is_card_stack:
				var deal_button = SpinBoxButton.new()
				deal_button.button.text = "Deal X cards"
				deal_button.spin_box.prefix = "X ="
				deal_button.spin_box.min_value = 1
				deal_button.spin_box.max_value = stack.get_piece_count()
				deal_button.connect("pressed", self, "_on_context_deal_cards_pressed")
				_piece_context_menu_container.add_child(deal_button)
			
			var take_top_button = SpinBoxButton.new()
			take_top_button.button.text = "Take X off top"
			take_top_button.spin_box.prefix = "X ="
			take_top_button.spin_box.min_value = 1
			take_top_button.spin_box.max_value = stack.get_piece_count()
			take_top_button.connect("pressed", self, "_on_context_take_top_pressed")
			_piece_context_menu_container.add_child(take_top_button)
		
		var orient_up_button = Button.new()
		orient_up_button.text = "Orient all up"
		orient_up_button.connect("pressed", self, "_on_context_orient_up_pressed")
		_piece_context_menu_container.add_child(orient_up_button)
		
		var orient_down_button = Button.new()
		orient_down_button.text = "Orient all down"
		orient_down_button.connect("pressed", self, "_on_context_orient_down_pressed")
		_piece_context_menu_container.add_child(orient_down_button)
		
		var shuffle_button = Button.new()
		shuffle_button.text = "Shuffle"
		shuffle_button.connect("pressed", self, "_on_context_shuffle_pressed")
		_piece_context_menu_container.add_child(shuffle_button)
		
		var sort_button = Button.new()
		sort_button.text = "Sort"
		sort_button.connect("pressed", self, "_on_context_sort_pressed")
		_piece_context_menu_container.add_child(sort_button)
	
	###########
	# LEVEL 1 #
	###########
	
	if _inheritance_has(inheritance, "StackablePiece"):
		if _selected_pieces.size() > 1:
			var collect_selected_button = Button.new()
			collect_selected_button.text = "Collect selected"
			collect_selected_button.connect("pressed", self, "_on_context_collect_selected_pressed")
			_piece_context_menu_container.add_child(collect_selected_button)
	
	###########
	# LEVEL 0 #
	###########
	
	if _inheritance_has(inheritance, "Piece"):
		var num_locked = 0
		var num_unlocked = 0
		
		for piece in _selected_pieces:
			if piece.is_locked():
				num_locked += 1
			else:
				num_unlocked += 1
		
		if num_unlocked == _selected_pieces.size():
			var lock_button = Button.new()
			lock_button.text = "Lock"
			lock_button.connect("pressed", self, "_on_context_lock_pressed")
			_piece_context_menu_container.add_child(lock_button)
		
		if num_locked == _selected_pieces.size():
			var unlock_button = Button.new()
			unlock_button.text = "Unlock"
			unlock_button.connect("pressed", self, "_on_context_unlock_pressed")
			_piece_context_menu_container.add_child(unlock_button)
		
		var delete_button = Button.new()
		delete_button.text = "Delete"
		delete_button.connect("pressed", self, "_on_context_delete_pressed")
		_piece_context_menu_container.add_child(delete_button)
	
	# We've connected a signal elsewhere that will change the size of the popup
	# to match the container.
	_piece_context_menu.rect_position = get_viewport().get_mouse_position()
	_piece_context_menu.popup()

# Popup the table context menu.
func _popup_table_context_menu() -> void:
	for child in _piece_context_menu_container.get_children():
		_piece_context_menu_container.remove_child(child)
		child.queue_free()
	
	var spawn_point_button = Button.new()
	spawn_point_button.text = "Set spawn point here"
	spawn_point_button.connect("pressed", self, "_on_context_spawn_point_pressed")
	_piece_context_menu_container.add_child(spawn_point_button)
	
	var spawn_object_button = Button.new()
	spawn_object_button.text = "Spawn object here"
	spawn_object_button.connect("pressed", self, "_on_context_spawn_object_pressed")
	_piece_context_menu_container.add_child(spawn_object_button)
	
	_piece_context_menu.rect_position = get_viewport().get_mouse_position()
	_piece_context_menu.popup()

# Reset the camera transform and zoom to their initial states.
func _reset_camera() -> void:
	transform = _initial_transform
	var euler = transform.basis.get_euler()
	_rotation = Vector2(euler.y, euler.x)
	
	_camera.translation.z = _initial_zoom
	_target_zoom = _initial_zoom

# Start hovering the grabbed pieces.
# fast: Did the user hover them quickly after grabbing them? If so, this may
# have differing behaviour, e.g. if the piece is a stack.
func _start_hovering_grabbed_piece(fast: bool) -> void:
	if _is_grabbing_selected:
		# NOTE: The server might not accept our request to hover a particular
		# piece, so we'll clear the list of selected pieces, and add the pieces
		# that are accepted back in to the list. For this reason, we'll need to
		# make a copy of the list.
		var selected = []
		for piece in _selected_pieces:
			selected.append(piece)
		
		clear_selected_pieces()
		
		if not selected.empty():
			var origin_piece = selected[0]
			if _piece_mouse_is_over:
				if selected.has(_piece_mouse_is_over):
					origin_piece = _piece_mouse_is_over
			var origin = origin_piece.transform.origin
			
			for piece in selected:
				if selected.size() == 1 and piece is Stack and fast:
					emit_signal("pop_stack_requested", piece, 1)
				else:
					var offset = piece.transform.origin - origin
					emit_signal("hover_piece_requested", piece, offset)
		
		_is_grabbing_selected = false

# Unlock the currently selected pieces.
func _unlock_selected_pieces() -> void:
	_hide_context_menu()
	for piece in _selected_pieces:
		if piece is Piece:
			piece.rpc_id(1, "request_unlock")

# Called when the camera starts moving either positionally or rotationally.
func _on_moving() -> bool:
	# If we were grabbing a piece while moving...
	if _is_grabbing_selected:
		
		# ... then send out a signal to start hovering the piece fast.
		_start_hovering_grabbed_piece(true)
		return true
	
	# Or if we were hovering a piece already...
	if _is_hovering_selected:
		
		# Set the maximum hover y-position so the pieces don't go above and
		# behind the camera.
		var max_y_pos = _camera.global_transform.origin.y - HOVER_Y_MIN
		_hover_y_pos = min(_hover_y_pos, max_y_pos)
		
		# ... then send out a signal with the new hover position.
		for piece in _selected_pieces:
			piece.rpc_unreliable_id(1, "set_hover_position", get_hover_position())
		return true
	
	return false

func _on_Lobby_player_added(id: int) -> void:
	if get_tree().is_network_server():
		return
	
	if id == get_tree().get_network_unique_id():
		return
	
	if _cursors.has_node(str(id)):
		return
	
	var cursor = TextureRect.new()
	cursor.name = str(id)
	cursor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cursor.rect_scale = _get_cursor_scale()
	cursor.texture = _create_player_cursor_texture(id, false)
	
	cursor.set_meta("cursor_position", Vector3())
	cursor.set_meta("x_basis", Vector3.RIGHT)
	
	_cursors.add_child(cursor)

func _on_Lobby_player_modified(id: int, old: Dictionary) -> void:
	if id == get_tree().get_network_unique_id():
		return
	
	if not _cursors.has_node(str(id)):
		return
	
	var cursor = _cursors.get_node(str(id))
	if not cursor:
		return
	if not cursor is TextureRect:
		return
	
	cursor.texture = _create_player_cursor_texture(id, false)

func _on_Lobby_player_removed(id: int) -> void:
	if id == get_tree().get_network_unique_id():
		return
	
	if not _cursors.has_node(str(id)):
		return
	
	var cursor = _cursors.get_node(str(id))
	if cursor:
		_cursors.remove_child(cursor)
		cursor.queue_free()

func _on_VBoxContainer_item_rect_changed():
	if _piece_context_menu and _piece_context_menu_container:
		var size = _piece_context_menu_container.rect_size
		size.x += _piece_context_menu_container.margin_left
		size.y += _piece_context_menu_container.margin_top
		size.x -= _piece_context_menu_container.margin_right
		size.y -= _piece_context_menu_container.margin_bottom
		_piece_context_menu.rect_min_size = size
		_piece_context_menu.rect_size = size

func _on_Viewport_size_changed():
	# Scale the cursors so they always appear the same size, regardless of the
	# window resolution.
	for cursor in _cursors.get_children():
		if cursor is TextureRect:
			cursor.rect_scale = _get_cursor_scale()
