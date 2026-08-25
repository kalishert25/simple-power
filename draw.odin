package main

import rl "vendor:raylib"
import "core:time"
import "core:sync"
import "core:fmt"


do_ui_element :: proc(state: ^State, pos: [2]f32, text: cstring, font_size: f32 = 32, bg_color: rl.Color = {0, 0, 0, 0}, animate_hover: bool = false) -> bool {
	assert(font_size == 32 || font_size == 64, "dynamic scaling is not supported")
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
		if state.selected_power_meter_index == i do bg_color = SELECT_COLOR

		clicked := do_ui_element(state, pos, pm.name, 32, bg_color, true)
		if clicked {
			if state.selected_power_meter_index == i {
				state.selected_power_meter_index = -1
			} else {
				state.selected_power_meter_index = i
			}
		}
	}
}


draw_riding_mode_ui :: proc(state: ^State) {

	{ // current stats
		pos := [2]f32{40, 40}
		current_power := ride_data_get_current_value(state, .POWER).power
		current_cadence := ride_data_get_current_value(state, .CADENCE).cadence


		buf: [16]u8
		timer_duration := time.stopwatch_duration(state.timer)
		formatted_duration := time.to_string_hms(timer_duration, buf[:])

		text := fmt.ctprintf("%.2f mi\n%.2f mph\n%d W\n%d rpm\n%v",
			state.distance_traveled * 0.000621371,
			state.velocity * 2.237,
			current_power,
			current_cadence,
			formatted_duration
		)
		font_size := f32(64)
		do_ui_element(state, pos, text, font_size)
	}


	{ // draw map
		padding : f32 = 20
		scale : f32 = 2.5
		map_offset := [2]f32{
			padding-scale*state.path_bounding_box.x + 400,
			padding-scale*state.path_bounding_box.y}
		prev_pos := state.path[0]
		for offset := i32(0); offset < i32(len(state.path)); offset += 3 {
			for t := f64(0); t < 1; t += 0.1 {

				pos := sample_path(state.path, offset, t)
				if offset > 0 || t > 0 {
					start_pos := scale * cast([2]f32)prev_pos + map_offset
					end_pos := scale * cast([2]f32)pos + map_offset
					rl.DrawLineEx(start_pos, end_pos, 10, HOVER_COLOR)
				}
				prev_pos = pos
			}
		}



		current_pos : [2]f64
		{
			sync.lock(&state.current_pos_mu)
			defer sync.unlock(&state.current_pos_mu)
			current_pos = state.current_pos
		}

		rl.DrawCircleV(map_offset + cast([2]f32)current_pos * scale, 10, rl.RED)
		r := rl.Rectangle{
			state.path_bounding_box.x*scale + map_offset.x - padding,
			state.path_bounding_box.y*scale + map_offset.y - padding,
			state.path_bounding_box.width*scale + padding*2,
			state.path_bounding_box.height*scale + padding*2
		}
		rl.DrawRectangleLinesEx(r, 10, rl.BLACK)
	}



	starting_y_axis_maximum := 100
	max_value := i32(starting_y_axis_maximum)
	for i := len(state.ride_data_array) - 1; i >= 0; i -= 1 {

		data_point := state.ride_data_array[i]

		{
			graph_start_cuttoff_time := time.time_add(time.now(), -GRAPH_LOOKBACK_SECONDS * time.Second)
			if time.diff(graph_start_cuttoff_time, data_point.time) < 0 {
				break
			}
		}

		if .POWER not_in data_point.data_types {
			continue
		}

		value := data_point.power
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

		graph_pos_from_data_point :: proc(state: ^State, data_point_time: time.Time, value: i32, graph_rect: rl.Rectangle, max_value: i32) -> [2]f32 {


			graph_right := graph_rect.x + graph_rect.width
			graph_bottom := graph_rect.y + graph_rect.height

			graph_start_cuttoff_time := time.time_add(time.now(), -GRAPH_LOOKBACK_SECONDS * time.Second)
			width_per_second := graph_rect.width/GRAPH_LOOKBACK_SECONDS

			seconds_after_duration_start := cast(f32)time.duration_seconds(time.diff(graph_start_cuttoff_time, data_point_time))
			xvalue := graph_rect.width * seconds_after_duration_start / f32(GRAPH_LOOKBACK_SECONDS)
			height := graph_rect.height * f32(value) / f32(max_value)
			pos := [2]f32{(graph_rect.x + xvalue), (graph_bottom - height)}
			return pos
		}

		previous_value : i32 = -1
		previous_time : time.Time
		for i := i32(len(state.ride_data_array)) - 1; i >= 0; i -= 1 {

			data_point := state.ride_data_array[i]
			if .POWER not_in data_point.data_types {
				continue
			}

			graph_start_cuttoff_time := time.time_add(time.now(), -GRAPH_LOOKBACK_SECONDS * time.Second)
			if time.diff(graph_start_cuttoff_time, data_point.time) < 0 {
				break
			}

			value := data_point.power

			if previous_value != -1 {
				pos0 := graph_pos_from_data_point(state, previous_time, previous_value, graph_rect, max_value)
				pos1 := graph_pos_from_data_point(state, data_point.time, value, graph_rect, max_value)
			  rl.DrawLineEx(pos0, pos1, 2, rl.PURPLE)
			}

			previous_value = value
			previous_time = data_point.time

		}
	}
}



vec2_in_rect :: proc(vec2: [2]f32, rect: rl.Rectangle) -> bool {
	return 	vec2.x > rect.x &&
					vec2.y > rect.y &&
				 	vec2.x < (rect.x + rect.width) &&
					vec2.y < (rect.y + rect.height)
}
