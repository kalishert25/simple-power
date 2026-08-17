package main


import "core:mem"
import "core:fmt"
import "core:thread"
import "core:sync"
import "core:time"
import "core:math/linalg"
import "core:math"
import "core:slice"
import rl "vendor:raylib"
import ble "simpleble"

MAX_DEVICES :: 10
DATA_ARRAY_SIZE :: 2 * mem.Megabyte

BG_COLOR 				:: rl.Color{20, 20, 50, 255}
HOVER_COLOR 		:: rl.Color{60, 60, 100, 255}
TEXT_COLOR 			:: rl.Color{190, 190, 230, 255}
SELECT_COLOR    :: rl.Color{50, 120, 90, 255}

LAT_LON_ORIGIN :: [2]f32{0, 0}

EARTH_MEAN_RADIUS :: 6_371_000.0

GRAPH_LOOKBACK_SECONDS :: 60 * 5
PATH_ANCHOR_POINTS := [?][2]f32{
	{0, 0},
	{0, 50},
	{50, 50},
	{25, 0},
}

earth_lat_lon_from_world_space :: proc(pos: [2]f32) -> [2]f32 {

	rho := linalg.vector_length(pos)

	if rho == 0 do return LAT_LON_ORIGIN

	lat_lon_origin_radians := LAT_LON_ORIGIN * math.PI / 180

	theta := math.atan(rho / EARTH_MEAN_RADIUS)


 // could use identity sin(atan(x))	== x/sqrt(x^2 + 1)
	s_theta, c_theta := math.sincos(theta)

	s_lat0, c_lat0 := math.sincos(lat_lon_origin_radians.x)

	lat_radians := math.asin(c_theta * s_lat0 + (pos.y * s_theta * c_lat0) / rho)
	lon_radians := lat_lon_origin_radians.y + math.atan2(
		pos.x * s_theta,
		rho * c_lat0 * c_theta - pos.y * s_lat0 * s_theta
	)

	lat := math.to_degrees(lat_radians)
	lon := math.to_degrees(lon_radians)

	lon = math.mod(lon + 180, 360) - 180

	return {lat, lon}
}


global_arena: mem.Arena
global_buffer: [32 * mem.Megabyte]byte

State :: struct {
	ble_devices_mu: sync.Mutex,
	ble_devices: [dynamic; MAX_DEVICES]DeviceView,
	mouse_pos: [2]f32,
	screen_size: [2]f32,
	mouse_pressed: bool,
	selected_power_meter_index: i32,
	font: rl.Font,
	font_big: rl.Font,
	mode: Mode,
	power_data: RideDataArray,
	longitude_latitude_data: RideDataArray,
	distance_traveled: f32,
	velocity: f32,
	path: [][2]f32,
	path_total_distance: f32,
	arc_length_lookup_table: []ArcLengthLookupTableEntry,
	current_pos: [2]f32,
}

DeviceView :: struct {
	name: cstring,
	mac_address: cstring,
	handle: ble.Peripheral,
}

Mode :: enum {
	PAIRING,
	RIDING,
}

RideDataArray :: struct {
	mutex: sync.Mutex,
	array: [dynamic]RideDataPoint,
	graph_starting_index: i32,
}

RideDataPoint :: struct {
	time: time.Time,
	value: i64,
}


path_from_anchor_points :: proc(anchor_points: [][2]f32, allocator: mem.Allocator ) -> [][2]f32 {

	total_point_count : int
	{
		control_point_count := len(anchor_points) * 2
		total_point_count = control_point_count + len(anchor_points)
	}

	path := make([][2]f32, total_point_count, allocator)

	for index in 0..<len(anchor_points) {
		current_anchor := anchor_points[index]
		prev_anchor := anchor_points[(index - 1) %% len(anchor_points)]
		next_anchor := anchor_points[(index + 1) %% len(anchor_points)]

		prev_displacement := prev_anchor - current_anchor
		next_displacement := current_anchor - next_anchor

		control_point_dir := linalg.vector_normalize(prev_displacement + next_displacement)

		{
			prev_control_point_distance := linalg.vector_length(prev_displacement) * 0.5
			prev_control_point := current_anchor + control_point_dir * prev_control_point_distance
			path[(index * 3 - 1) %% total_point_count] = prev_control_point
		}

		{
			next_control_point_distance := linalg.vector_length(next_displacement) * 0.5
			next_control_point := current_anchor - control_point_dir * next_control_point_distance
			path[(index * 3 + 1) %% total_point_count] = next_control_point
		}

		path[index * 3] = current_anchor

	}
	return path
}

ArcLengthLookupTableEntry :: struct {
	arc_length: f32,
	offset: i32,
	t: f32,
}

pos_from_total_distance_traveled :: proc(state: ^State, total_distance_traveled: f32) -> [2]f32 {
	assert(total_distance_traveled >= 0)

	arc_length := math.mod(total_distance_traveled, state.path_total_distance)

	compare :: proc(entry: ArcLengthLookupTableEntry, arc_length: f32) -> slice.Ordering {
		compare_result := slice.cmp(entry.arc_length, arc_length)
		if compare_result == .Equal {
			return .Less
		}
		return compare_result
	}

	index, _ := slice.binary_search_by(state.arc_length_lookup_table, arc_length, compare)

	if index == len(state.arc_length_lookup_table) {
		index = 0
	}

	prev_index := (index - 1) %% len(state.arc_length_lookup_table)

	entry := state.arc_length_lookup_table[index]
	prev_entry := state.arc_length_lookup_table[prev_index]


	arc_length_low := prev_entry.arc_length
	arc_length_high := entry.arc_length

	if arc_length_high < arc_length_low {
		assert(arc_length_high == 0)
		arc_length_high = state.path_total_distance
	}

	interpolation_ratio := (arc_length - arc_length_low) / (arc_length_high - arc_length_low)

	t_low := prev_entry.t
	t_high := entry.t

	if entry.offset != prev_entry.offset {
		{
			n := i32(len(state.path))
			assert(entry.offset == (prev_entry.offset + 3) %% n, "not enough sample points.")
		}
		assert(entry.t == 0)
		t_high = 1
	}

	t := math.lerp(t_low, t_high, interpolation_ratio)
	pos := sample_path(state.path, prev_entry.offset, t)

	return pos
}


arc_length_lookup_table_from_path :: proc(path: [][2]f32, sample_point_count: int, allocator: mem.Allocator) -> ([]ArcLengthLookupTableEntry, f32) {
	arc_length_lookup_table := make([]ArcLengthLookupTableEntry, sample_point_count, allocator)
	assert(len(path) % 3 == 0)
	anchor_point_count := len(path) / 3

	t_max := f32(anchor_point_count)

	t_step_size := t_max / f32(sample_point_count)

	offset : i32 = 0
	total_arc_length := f32(0)
	prev_pos := path[0]
	index := 0
	t : f32 = 0

	fmt.printfln("\n")
	n := i32(len(path))

	for offset < n {

		arc_length_lookup_table[index] = ArcLengthLookupTableEntry{arc_length=total_arc_length, offset=offset, t=t}

		pos := sample_path(path, offset, t)

		distance := linalg.vector_length(prev_pos - pos)
		fmt.printf("(%.3f, %.3f),", pos.x, pos.y)

		total_arc_length += distance
		prev_pos = pos
		index += 1
		t += t_step_size
		if (1 - t) < t_step_size {
			t = 0
			offset += 3
		}

	}

	return arc_length_lookup_table, total_arc_length
}

sample_path :: proc(path: [][2]f32, offset: i32, t: f32) -> [2]f32 {
	assert(offset % 3 == 0)
	assert(offset >= 0 && offset < i32(len(path)))
	pos := evaluate_cubic_bezier(
		path[offset],
		path[offset+1],
		path[offset+2],
		path[(offset + 3) % i32(len(path))],
		t
	)

	return pos
}


enter_ride_mode_from_pairing_mode :: proc(state: ^State) {
	ensure(state.selected_power_meter_index >= 0)
	ensure(state.mode == .PAIRING)


	sync.lock(&state.ble_devices_mu)

	device_handle := state.ble_devices[state.selected_power_meter_index].handle

	// block ui thread for now:
	//thread.create_and_start_with_poly_data2(data1 = state, data2 = device_handle, fn = subscribe_to_device, self_cleanup = true)
	status := subscribe_to_device(state, device_handle)
	if status == .FAILURE {
		fmt.println("Failed to subscribe to device.")
		sync.unlock(&state.ble_devices_mu)
		return
	}
	fmt.println("Successfully subscribed to device.")
	// don't unlock the mutex while we remain in ride mode.
	// this will block the background thread from listening for new devices
	state.mode = .RIDING
}

main :: proc() {
	state := init()
	for !rl.WindowShouldClose() {
		defer free_all(context.temp_allocator)


		state.mouse_pos = rl.GetMousePosition();
		state.mouse_pressed = rl.IsMouseButtonPressed(.LEFT)
		state.screen_size.x = f32(rl.GetScreenWidth())
		state.screen_size.y = f32(rl.GetScreenHeight())

		if rl.IsKeyPressed(.ENTER) {
			if state.selected_power_meter_index >= 0 && state.mode == .PAIRING {
				enter_ride_mode_from_pairing_mode(state)
			}
		}

		delta_time := rl.GetFrameTime()

		current_power := ride_data_get_current_value(&state.power_data)
		drivetrain_efficiency : f32 = 0.98
		rolling_resistance : f32 = 0.003
		mass : f32 = 58 //kg
		g : f32 = 9.8
		cda : f32 = 0.32
		air_density : f32 = 1.225
		force_propulsion_max : f32 = 800
		min_velocity : f32 = 1 // m/s

		force_propulsion : f32 = 0

		if current_power > 0 {
			force_propulsion = f32(current_power) * drivetrain_efficiency / state.velocity

			if force_propulsion > force_propulsion_max {
				force_propulsion = force_propulsion_max
			}
		}

		force_rolling_resistance := rolling_resistance * mass * g * -math.sign(state.velocity)
		force_drag := 0.5 * cda * air_density * state.velocity * state.velocity * -math.sign(state.velocity)

		force_net := force_propulsion + force_rolling_resistance + force_drag
		acceleration := force_net / mass

		state.velocity += acceleration * delta_time

		if state.velocity < 0 || (current_power == 0 && state.velocity < min_velocity) {
			state.velocity = 0
		}

		state.distance_traveled += state.velocity * delta_time

		state.current_pos = pos_from_total_distance_traveled(state, state.distance_traveled)


		draw(state)
	}
}


ride_data_get_current_value :: proc(ride_data: ^RideDataArray) -> i64 {
	sync.lock(&ride_data.mutex)
	defer sync.unlock(&ride_data.mutex)
	count := len(ride_data.array)
	if count == 0 {
		return 0
	}
	return ride_data.array[count - 1].value
}


draw :: proc(state: ^State) {
	rl.BeginDrawing()
	defer rl.EndDrawing()

	rl.ClearBackground(BG_COLOR)

	switch state.mode {

	case .PAIRING:
		draw_pairing_mode_ui(state)

	case .RIDING:

		{
			pos := [2]f32{40, 40}
			current_power := ride_data_get_current_value(&state.power_data)
			text := fmt.ctprintf("%d W", current_power)
			font_size := f32(64)
			do_ui_element(state, pos, text, font_size)
		}

		{
			pos := [2]f32{200, 40}
			text := fmt.ctprintf("%.2f m. v=%.2f", state.distance_traveled, state.velocity * 2.237)
			font_size := f32(64)
			do_ui_element(state, pos, text, font_size)
		}

		{ // draw map
			prev_pos := state.path[0]
			for offset := i32(0); offset < i32(len(state.path)); offset += 3 {
				for t := f32(0); t < 1; t += 0.1 {

					pos := sample_path(state.path, offset, t)
					if offset > 0 || t > 0 {
						rl.DrawLineEx(100 + prev_pos * 2, 100 + pos * 2, 10, HOVER_COLOR)
					}
					prev_pos = pos
				}
			}
			rl.DrawCircleV(100 + state.current_pos * 2, 10, rl.RED)
		}



		starting_y_axis_maximum := 100
		max_value := i64(starting_y_axis_maximum)
		for i := state.power_data.graph_starting_index;
			i < i32(len(state.power_data.array)); i += 1 {
			value := state.power_data.array[i].value
			if value > max_value {
				max_value = value
			}
		}


		graph_top 		: f32	= state.screen_size.y - 400
		graph_bottom 	: f32 = state.screen_size.y - 50
		graph_right 	: f32 = state.screen_size.x - 50
		graph_left 		: f32 = 50

		graph_width  := graph_right - graph_left
		graph_height := graph_bottom - graph_top

		graph_rect := rl.Rectangle{graph_left, graph_top, graph_width, graph_height}


		// draw graph
		{

			graph_pos_from_data_point := proc(state: ^State, data_point: RideDataPoint, graph_rect: rl.Rectangle, max_value: i64) -> [2]f32 {


				graph_right := graph_rect.x + graph_rect.width
				graph_bottom := graph_rect.y + graph_rect.height

				graph_start_cuttoff_time := time.time_add(time.now(), -GRAPH_LOOKBACK_SECONDS * time.Second)
				width_per_second := graph_rect.width/GRAPH_LOOKBACK_SECONDS

				seconds_after_duration_start := cast(f32)time.duration_seconds(time.diff(graph_start_cuttoff_time, data_point.time))
				xvalue := graph_rect.width * seconds_after_duration_start / f32(GRAPH_LOOKBACK_SECONDS)
				height := graph_rect.height * f32(data_point.value) / f32(max_value)
				pos := [2]f32{(graph_right - xvalue), (graph_bottom - height)}
				return pos
			}

			for i := state.power_data.graph_starting_index;
				i < i32(len(state.power_data.array)) - 1; i += 1 {
				data_point0 := state.power_data.array[i]
				data_point1 := state.power_data.array[i+1]

				pos0 := graph_pos_from_data_point(state, data_point0, graph_rect, max_value)
				pos1 := graph_pos_from_data_point(state, data_point1, graph_rect, max_value)
			  rl.DrawLineEx(pos0, pos1, 2, rl.PURPLE)

			}
		}
	}
}


draw_pairing_mode_ui :: proc(state: ^State) {

	sync.lock(&state.ble_devices_mu)
	defer sync.unlock(&state.ble_devices_mu)


	{ // title text
		title : cstring
		if len(state.ble_devices) == 0 {
			title = "No devices found."
		} else if state.selected_power_meter_index == -1 {
			title = "Select a power meter."
		} else {
			title = "Press enter to continue."
		}
		pos := [2]f32{20, 20}
		do_ui_element(state, pos, title)
	}

	for pm, i in state.ble_devices {
		pos := [2]f32{50, 60 * (f32(i) + 1.5) }

		bg_color : rl.Color  //HIGHLIGHT_COLOR
		if state.selected_power_meter_index == i32(i) do bg_color = SELECT_COLOR

		clicked := do_ui_element(state, pos, pm.name, 32, bg_color, true)
		if clicked {
			if state.selected_power_meter_index == i32(i) {
				state.selected_power_meter_index = -1
			} else {
				state.selected_power_meter_index = i32(i)
			}
			fmt.printfln("clicked on index %d", i)
		}
	}
}


do_ui_element :: proc(state: ^State, pos: [2]f32, text: cstring, font_size: f32 = 32, bg_color: rl.Color = {0, 0, 0, 0}, animate_hover: bool = false) -> bool {
	spacing : f32 = 1
	padding : [4]f32 = {10, 10, 10, 10}
	text_size := rl.MeasureTextEx(state.font, text, font_size, spacing)
	bounding_box := rl.Rectangle{
		pos.x - padding[0], pos.y - padding[1],
		text_size.x + padding[0] + padding[2],
		text_size.y + padding[1] + padding[3]}
	mouse_in_rect := vec2_in_rect(state.mouse_pos, bounding_box)

	if bg_color != (rl.Color{0, 0, 0, 0}) {
		rl.DrawRectangleRec(bounding_box, bg_color)
	}
	if mouse_in_rect && animate_hover {
		rl.DrawRectangleRec(bounding_box, HOVER_COLOR)
	}
	font := state.font
	if font_size != 32 {
		font = state.font_big
	}
	rl.DrawTextEx(font, text, pos, font_size, spacing, rl.WHITE)

	if mouse_in_rect {
		if state.mouse_pressed {
			return true
		}
	}
	return false
}

vec2_in_rect :: proc(vec2: [2]f32, rect: rl.Rectangle) -> bool {
	return 	vec2.x > rect.x &&
					vec2.y > rect.y &&
				 	vec2.x < (rect.x + rect.width) &&
					vec2.y < (rect.y + rect.height)
}

init :: proc() -> ^State {

	mem.arena_init(&global_arena, global_buffer[:])

	global_allocator := mem.arena_allocator(&global_arena)
	state := new(State, allocator = global_allocator)
	state.selected_power_meter_index = -1
	state.power_data.array = make([dynamic]RideDataPoint, 0, DATA_ARRAY_SIZE, allocator = global_allocator)
	rl.SetConfigFlags({.WINDOW_RESIZABLE})
	rl.InitWindow(800, 600, "window")
	rl.SetTargetFPS(60)
	font_path : cstring = "assets/verdana.ttf"
	state.font = rl.LoadFontEx(font_path, 32, nil, 250);
	state.font_big = rl.LoadFontEx(font_path, 64, nil, 250);
	state.path = path_from_anchor_points(PATH_ANCHOR_POINTS[:], global_allocator)
	state.arc_length_lookup_table, state.path_total_distance = arc_length_lookup_table_from_path(state.path, 200, global_allocator)
	pos_from_total_distance_traveled(state, 50)

	export_to_gpx(state, "testfile.gpx", "Afternoon Ride")
	thread.create_and_start_with_poly_data(data = state, fn = scan_for_ble_devices)
	return state
}


evaluate_cubic_bezier :: proc(p0, p1, p2, p3: [2]f32, t: f32) -> [2]f32 {
	u := 1-t

	a := u*u*u
	b := 3*u*u*t
	c := 3*u*t*t
	d := t*t*t

	return a*p0 + b*p1 + c*p2 + d*p3
}

desmos_print :: proc(data: [][2]f32) {
	fmt.print("[")
	for v in data {
		fmt.printf("(%v,%v),", v.x, v.y)
	}
	fmt.print("]")
}
