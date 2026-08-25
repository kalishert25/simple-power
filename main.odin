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
LOCATION_SAMPLE_RATE :: 200 * time.Millisecond


BG_COLOR 				:: rl.Color{20, 20, 50, 255}
HOVER_COLOR 		:: rl.Color{60, 60, 100, 255}
TEXT_COLOR 			:: rl.Color{190, 190, 230, 255}
SELECT_COLOR    :: rl.Color{50, 120, 90, 255}

LAT_LON_ORIGIN :: [2]f64{0, 0}

EARTH_MEAN_RADIUS :: 6_371_000.0

GRAPH_LOOKBACK_SECONDS :: 30 * 1
PATH_ANCHOR_POINTS := [?][2]f64{
	{0, 0},
	{200, 0},
	{200, 200},
	{120, 200},
	{120, 100},
	{60, 100},
	{0, 150},
}

earth_lat_lon_from_world_space :: proc(pos: [2]f64) -> [2]f64 {

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
	selected_power_meter_index: int,
	font: rl.Font,
	font_big: rl.Font,
	mode: Mode,
	ride_data_array: [dynamic]RideDataPoint,
	ride_data_mu: sync.Mutex,
	distance_traveled: f64,
	velocity: f64,
	path: [][2]f64,
	path_total_distance: f64,
	arc_length_lookup_table: []ArcLengthLookupTableEntry,
	current_pos: [2]f64,
	current_pos_mu: sync.Mutex,
	timer: time.Stopwatch,
	path_bounding_box: rl.Rectangle,
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

RideDataType :: enum {
	LOCATION,
	POWER,
	CADENCE,
}

RideDataType_Set :: bit_set[RideDataType]


RideDataPoint :: struct {
	time: time.Time,
	data_types: RideDataType_Set,
	power: i32,
	cadence: i32,
	location: [2]f64,
}



sample_current_location :: proc(state: ^State) {
	for {

		now := time.now()
		current_pos : [2]f64
		{
			sync.lock(&state.current_pos_mu)
			defer sync.unlock(&state.current_pos_mu)
			current_pos = state.current_pos
		}

		location := earth_lat_lon_from_world_space(current_pos)

		data_point := RideDataPoint{
			time = now,
			data_types = {.LOCATION},
			location = location,
		}
		ride_data_array_append(state, data_point)

		time.sleep(LOCATION_SAMPLE_RATE)
	}
}

// Generates a path which includes the anchor points and the
// control points that define a series of cubic bezier curves
path_from_anchor_points :: proc(anchor_points: [][2]f64, allocator: mem.Allocator ) -> [][2]f64 {

	total_point_count : int
	{
		control_point_count := len(anchor_points) * 2
		total_point_count = control_point_count + len(anchor_points)
	}

	path := make([][2]f64, total_point_count, allocator)

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
	arc_length: f64,
	offset: i32,
	t: f64,
}

pos_from_total_distance_traveled :: proc(state: ^State, total_distance_traveled: f64) -> [2]f64 {
	assert(total_distance_traveled >= 0)

	arc_length := math.mod(total_distance_traveled, state.path_total_distance)

	compare :: proc(entry: ArcLengthLookupTableEntry, arc_length: f64) -> slice.Ordering {
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


arc_length_lookup_table_from_path :: proc(path: [][2]f64, sample_point_count: int, allocator: mem.Allocator) -> ([]ArcLengthLookupTableEntry, f64) {
	arc_length_lookup_table := make([]ArcLengthLookupTableEntry, sample_point_count, allocator)
	assert(len(path) % 3 == 0)
	anchor_point_count := len(path) / 3

	t_max := f64(anchor_point_count)

	t_step_size := t_max / f64(sample_point_count)

	offset : i32 = 0
	total_arc_length := f64(0)
	prev_pos := path[0]
	index := 0
	t : f64 = 0

	fmt.printfln("\n")
	n := i32(len(path))

	for offset < n {

		arc_length_lookup_table[index] = ArcLengthLookupTableEntry{arc_length=total_arc_length, offset=offset, t=t}

		pos := sample_path(path, offset, t)

		distance := linalg.vector_length(prev_pos - pos)

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

sample_path :: proc(path: [][2]f64, offset: i32, t: f64) -> [2]f64 {
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


bounding_box_from_path :: proc(path: [][2]f64) -> rl.Rectangle {

	min_x, min_y, max_x, max_y: f64

	for offset := i32(0); offset < i32(len(path)); offset += 3 {
		for t := f64(0); t < 1; t += 0.001 {
			pos := sample_path(path, offset, t)
			if pos.x > max_x do max_x = pos.x
			if pos.x < min_x do min_x = pos.x
			if pos.y > max_y do max_y = pos.y
			if pos.y < min_y do min_y = pos.y
		}
	}
	width := max_x - min_x
	height := max_y - min_y
	return rl.Rectangle{f32(min_x), f32(min_y), f32(width), f32(height)}
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

	thread.create_and_start_with_poly_data(data = state, fn = sample_current_location)
	time.stopwatch_start(&state.timer)
}

main :: proc() {
	state := init()
	for !rl.WindowShouldClose() {
		defer free_all(context.temp_allocator)

		update(state)
		draw(state)
	}
}

update ::proc(state: ^State) {

	state.mouse_pos = rl.GetMousePosition();
	state.mouse_pressed = rl.IsMouseButtonPressed(.LEFT)
	state.screen_size.x = f32(rl.GetScreenWidth())
	state.screen_size.y = f32(rl.GetScreenHeight())

	if rl.IsKeyPressed(.ENTER) {
		if state.selected_power_meter_index >= 0 && state.mode == .PAIRING {
			enter_ride_mode_from_pairing_mode(state)
		}
	}


	if rl.IsKeyPressed(.G) {
		if state.mode == .RIDING {
			filename := fmt.tprintf("export-%d.gpx", time.now()._nsec)
			export_to_gpx(state, filename, "Simple Power Ride")
		}
	}

	delta_time := cast(f64)rl.GetFrameTime()

	current_power := ride_data_get_current_value(state, .POWER).power
	drivetrain_efficiency : f64 = 0.98
	rolling_resistance : f64 = 0.003
	mass : f64 = 58 //kg
	g : f64 = 9.8
	cda : f64 = 0.32
	air_density : f64 = 1.225
	force_propulsion_max : f64 = 800
	min_velocity : f64 = 1 // m/s

	force_propulsion : f64 = 0

	if current_power > 0 {
		force_propulsion = f64(current_power) * drivetrain_efficiency / state.velocity

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

	{
		sync.lock(&state.current_pos_mu)
		defer sync.unlock(&state.current_pos_mu)
		state.current_pos = pos_from_total_distance_traveled(state, state.distance_traveled)
	}

}

ride_data_get_current_value :: proc(state: ^State, data_type: RideDataType) -> RideDataPoint {
	sync.lock(&state.ride_data_mu)
	defer sync.unlock(&state.ride_data_mu)

	result := RideDataPoint{}
	for i := len(state.ride_data_array) - 1; i >= 0; i -= 1 {
		data_point := state.ride_data_array[i]

		if data_type in data_point.data_types {
			result = data_point
			break
		}
	}

	cutoff_time := 5 * time.Second
	if time.diff(result.time, time.now()) > cutoff_time {
		result.power = 0
	}

	return result
}


draw :: proc(state: ^State) {
	rl.BeginDrawing()
	defer rl.EndDrawing()

	rl.ClearBackground(BG_COLOR)

	switch state.mode {

	case .PAIRING:
		draw_pairing_mode_ui(state)

	case .RIDING:
		draw_riding_mode_ui(state)
	}
}



init :: proc() -> ^State {

	mem.arena_init(&global_arena, global_buffer[:])

	global_allocator := mem.arena_allocator(&global_arena)
	state := new(State, allocator = global_allocator)
	state.selected_power_meter_index = -1
	state.ride_data_array = make([dynamic]RideDataPoint, 0, DATA_ARRAY_SIZE)
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .WINDOW_ALWAYS_RUN})
	rl.InitWindow(800, 600, "window")
	rl.SetTargetFPS(60)
	font_path : cstring = "assets/verdana.ttf"
	state.font = rl.LoadFontEx(font_path, 32, nil, 250);
	state.font_big = rl.LoadFontEx(font_path, 64, nil, 250);
	state.path = path_from_anchor_points(PATH_ANCHOR_POINTS[:], global_allocator)

	sample_point_count : int
	{
		total_anchor_point_distance := f64(0)
		for index := 0; index < len(PATH_ANCHOR_POINTS); index += 1 {
			next_index := (index + 1) % len(PATH_ANCHOR_POINTS)
			p0 := PATH_ANCHOR_POINTS[index]
			p1 := PATH_ANCHOR_POINTS[next_index]
			distance := linalg.vector_length(p1 - p0)
			total_anchor_point_distance += distance
		}
		sample_point_count = int(2 * total_anchor_point_distance)
	}

	state.arc_length_lookup_table, state.path_total_distance = arc_length_lookup_table_from_path(state.path, sample_point_count, global_allocator)
	state.path_bounding_box = bounding_box_from_path(state.path)
	thread.create_and_start_with_poly_data(data = state, fn = scan_for_ble_devices)
	return state
}


evaluate_cubic_bezier :: proc(p0, p1, p2, p3: [2]f64, t: f64) -> [2]f64 {
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


ride_data_array_append :: proc(state: ^State, data_point: RideDataPoint) {
	ensure(len(state.ride_data_array) < DATA_ARRAY_SIZE)
	fmt.printfln("Appending datapoint: %v", data_point)
	sync.lock(&state.ride_data_mu)
	defer sync.unlock(&state.ride_data_mu)

	if len(state.ride_data_array) == 0 {
		append(&state.ride_data_array, data_point)
		return
	}

	i := len(state.ride_data_array)
	for ; i >= 0; i -= 1 {
		previous := state.ride_data_array[i - 1]
		if time.diff(previous.time, data_point.time) >= 0 {
			break
		}
	}

	inject_at(&state.ride_data_array, i, data_point)
}
