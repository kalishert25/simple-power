package main


import "core:mem"
import "core:fmt"
import "core:thread"
import "core:sync"

import rl "vendor:raylib"
import ble "simpleble"


MAX_DEVICES :: 10

BG_COLOR 				:: rl.Color{20, 20, 50, 255}
HOVER_COLOR 		:: rl.Color{60, 60, 100, 255}
TEXT_COLOR 			:: rl.Color{190, 190, 230, 255}
SELECT_COLOR    :: rl.Color{50, 120, 90, 255}



global_arena: mem.Arena
global_buffer: [1024 * 1024 * 32]byte // 32MB

State :: struct {
	ble_devices_mu: sync.Mutex,
	ble_devices: [dynamic; MAX_DEVICES]DeviceView,
	mouse_pos: [2]f32,
	mouse_pressed: bool,
	selected_power_meter_index: i32,
	stop_scanning_for_ble_devices: bool,
	font: rl.Font,
	mode: Mode,
	current_power: i16,
	data_stream_mu: sync.Mutex
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
	fmt.println("entered ride mode")
}

main :: proc() {
	state := init()
	for !rl.WindowShouldClose() {
		defer free_all(context.temp_allocator)

		state.mouse_pos = rl.GetMousePosition();
		state.mouse_pressed = rl.IsMouseButtonPressed(.LEFT)

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
				pos := [2]f32{40, 40}
				text := fmt.ctprintf("%d W", state.current_power)
				do_ui_element(state, pos, text)
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

		clicked := do_ui_element(state, pos, pm.name, bg_color, true)
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


do_ui_element :: proc(state: ^State, pos: [2]f32, text: cstring, bg_color: rl.Color = {0, 0, 0, 0}, animate_hover: bool = false) -> bool {
	font_size : f32 = 32
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

	rl.DrawTextEx(state.font, text, pos, font_size, spacing, rl.WHITE)

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
	rl.InitWindow(800, 600, "window")
	rl.SetTargetFPS(60)
	font_path : cstring = "assets/verdana.ttf"
	state.font = rl.LoadFontEx(font_path, 32, nil, 250);
	thread.create_and_start_with_poly_data(data = state, fn = scan_for_ble_devices)
	return state
}
