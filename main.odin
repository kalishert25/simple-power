package main


import "core:mem"
import "core:fmt"
import "core:thread"
import "core:sync"
import "core:time"

import rl "vendor:raylib"
import ble "simpleble"


MAX_DEVICES :: 10
DATA_ARRAY_SIZE :: 2 * mem.Megabyte

BG_COLOR 				:: rl.Color{20, 20, 50, 255}
HOVER_COLOR 		:: rl.Color{60, 60, 100, 255}
TEXT_COLOR 			:: rl.Color{190, 190, 230, 255}
SELECT_COLOR    :: rl.Color{50, 120, 90, 255}

GRAPH_LOOKBACK_SECONDS :: 60 * 5

global_arena: mem.Arena
global_buffer: [32 * mem.Megabyte]byte

State :: struct {
	ble_devices_mu: sync.Mutex,
	ble_devices: [dynamic; MAX_DEVICES]DeviceView,
	mouse_pos: [2]f32,
	screen_size: [2]f32,
	mouse_pressed: bool,
	selected_power_meter_index: i32,
	stop_scanning_for_ble_devices: bool,
	font: rl.Font,
	font_big: rl.Font,
	mode: Mode,
	power_data: RideDataArray,
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
	time: u32, // in unix seconds
	value: i32,
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


		rl.BeginDrawing()
		defer rl.EndDrawing()
		rl.ClearBackground(BG_COLOR)

		switch state.mode {
			case .PAIRING:
				draw_pairing_mode_ui(state)
			case .RIDING:
				{

					/*for {

						current_start_time := state.ride_data[state.graph_start_index]
						if current_start_time
					}*/
					pos := [2]f32{40, 40}
					current_power := ride_data_get_current_value(&state.power_data)
					text := fmt.ctprintf("%d W", current_power)
					font_size := f32(64)
					do_ui_element(state, pos, text, font_size)
				}

				starting_y_axis_maximum := 100
				max_value := i32(starting_y_axis_maximum)
				for i := state.power_data.graph_starting_index;
					i < i32(len(state.power_data.array)); i += 1 {
					value := state.power_data.array[i].value
					if value > max_value {
						max_value = value
					}
				}


				graph_top 		: f32	= state.screen_size.y - 400
				graph_bottom 	: f32 = state.screen_size.y - 50
				graph_right 	: f32 = 50
				graph_left 		: f32 = state.screen_size.x - 50

				graph_width  := graph_right - graph_left
				graph_height := graph_bottom - graph_top

				graph_rect := rl.Rectangle{graph_left, graph_top, graph_width, graph_height}


				// draw graph
				{

					graph_pos_from_data_point := proc(state: ^State, data_point: RideDataPoint, graph_rect: rl.Rectangle, max_value: i32) -> [2]f32 {


						graph_right := graph_rect.x + graph_rect.width
						graph_bottom := graph_rect.y + graph_rect.height

						now := u32(time.to_unix_seconds(time.now()))
						graph_start_cuttoff_time := now - GRAPH_LOOKBACK_SECONDS
						width_per_second := graph_rect.width/GRAPH_LOOKBACK_SECONDS

						seconds_after_duration_start := data_point.time - graph_start_cuttoff_time
						xvalue := graph_rect.width * f32(seconds_after_duration_start) / f32(GRAPH_LOOKBACK_SECONDS)
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
	export_to_gpx(state, "testfile.gpx", "Afternoon Ride")
	thread.create_and_start_with_poly_data(data = state, fn = scan_for_ble_devices)
	return state
}
