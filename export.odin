package main

import "core:os"
import "core:bufio"
import "core:fmt"
import "core:sync"
import "core:time"
import "core:mem"
import "core:math"

ride_data_array_sample_time_interval :: proc(state: ^State, start_time, end_time: time.Time, start_index: i32 = 0) -> (avg: RideDataPoint, end_index: i32) {
	assert(time.diff(start_time, end_time) >= 0)
	data := state.ride_data_array
	total := RideDataPoint{}
	num_data_points_with_power : i32 = 0
	num_data_points_with_cadence : i32 = 0
	num_data_points_with_location: i32 = 0

	index := start_index
	for ; index < i32(len(data)); index += 1 {
		before_start_of_interval := time.diff(data[index].time, start_time) > 0
		if before_start_of_interval {
			continue
		}

		after_end_of_interval := time.diff(end_time, data[index].time) >= 0
		if after_end_of_interval {
			break
		}

		total.data_types |= data[index].data_types

		if .POWER in data[index].data_types {
			num_data_points_with_power += 1
			total.power += data[index].power
		}

		if .CADENCE in data[index].data_types {
			num_data_points_with_cadence += 1
			total.cadence += data[index].cadence
		}

		if .LOCATION in data[index].data_types {
			num_data_points_with_location += 1
			total.location += data[index].location
		}

	}

	avg = RideDataPoint{data_types=total.data_types}

	if .POWER in total.data_types {
		assert(num_data_points_with_power > 0)
		avg.power = i32(math.round_f64(f64(total.power) / f64(num_data_points_with_power)))
	}

	if .CADENCE in total.data_types {
		assert(num_data_points_with_cadence > 0)
		avg.cadence = i32(math.round_f64(f64(total.cadence) / f64(num_data_points_with_cadence)))
	}

	if .LOCATION in total.data_types {
		assert(num_data_points_with_location > 0)
		avg.location = total.location / f64(num_data_points_with_location)
	}

	return avg, index
}


export_to_gpx :: proc(state: ^State, filename: string, ride_name: string) -> (success: bool) {

	defer free_all(context.temp_allocator)

	sync.lock(&state.ride_data_mu)
	defer sync.unlock(&state.ride_data_mu)


	if len(state.ride_data_array) == 0 {
		return false
	}

	export_path, err := os.join_path({"exports", filename}, context.temp_allocator)
	if err != nil {
		return false
	}
	file, open_err := os.open(export_path, {.Create, .Write, .Trunc})
	defer os.close(file)

	if open_err != nil {
		fmt.printfln("Error when creating file: %v", err)
		return false
	}

	fmt.println("Writing to %s", export_path)
	file_stream := os.to_stream(file)
	writer: bufio.Writer
	bufio.writer_init(&writer, file_stream, allocator=context.temp_allocator)
	buffered_stream := bufio.writer_to_stream(&writer)

	time_buffer: [35]u8
	time_arena: mem.Arena
	mem.arena_init(&time_arena, time_buffer[:])
	time_allocator := mem.arena_allocator(&time_arena)

	{
		// push header
		file_creation_time := time.now()
		file_creation_time_formatted, _ := time.time_to_rfc3339(file_creation_time, include_nanos=false, allocator=time_allocator)
		defer free_all(time_allocator)

		header_format_string := `<?xml version="1.0" encoding="UTF-8"?>
<gpx creator="SimplePowerGPX" version="1.1" xmlns="http://www.topografix.com/GPX/1/1" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd http://www.garmin.com/xmlschemas/GpxExtensions/v3 http://www.garmin.com/xmlschemas/GpxExtensionsv3.xsd http://www.garmin.com/xmlschemas/TrackPointExtension/v1 http://www.garmin.com/xmlschemas/TrackPointExtensionv1.xsd" xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1" xmlns:gpxx="http://www.garmin.com/xmlschemas/GpxExtensions/v3">
 <metadata>
  <time>%s</time>
 </metadata>
 <trk>
 	<name>%s</name>
  <type>cycling</type>
  <trkseg>
`
		fmt.wprintfln(
			buffered_stream,
			header_format_string,
			file_creation_time_formatted,
			ride_name,
			flush=false
		)
	}

	current_second : time.Time
	{
		first_trackpoint_time := state.ride_data_array[0].time
		epoch := time.unix(0, 0)
		duration_since_epoch := time.diff(epoch, first_trackpoint_time)
		rounded_duration := time.duration_round(duration_since_epoch, time.Second)
		current_second = time.time_add(epoch, rounded_duration)
	}


	index := i32(0)
	for ; index < i32(len(state.ride_data_array));
	current_second = time.time_add(current_second, time.Second) {

		defer free_all(time_allocator)

		start_time := time.time_add(current_second, -500 * time.Millisecond)
		end_time := time.time_add(current_second, 500 * time.Millisecond)
		average_data_point: RideDataPoint
		average_data_point, index = ride_data_array_sample_time_interval(
			state, start_time, end_time, index
		)

		time_formatted, ok := time.time_to_rfc3339(current_second, include_nanos=false, allocator=time_allocator)
		assert(ok)

		track_point_format_string := `<trkpt lat="%.7f" lon="%.7f">
    <ele>0</ele>
    <time>%s</time>
    <extensions>
     <power>%v</power>
     <gpxtpx:TrackPointExtension>
      <gpxtpx:cad>%v</gpxtpx:cad>
     </gpxtpx:TrackPointExtension>
    </extensions>
  </trkpt>
  `
	  fmt.wprintfln(
			buffered_stream,
			track_point_format_string,
			average_data_point.location.x,
			average_data_point.location.y,
			time_formatted,
			average_data_point.power,
			average_data_point.cadence,
			flush=false
		)
	}

	// footer
	{

		footer_string := "  </trkseg>\n </trk>\n</gpx>"

		fmt.wprintln(
			buffered_stream,
			footer_string,
			flush=false
		)

	}

	bufio.writer_flush(&writer)
	fmt.printfln("Finished exporting file: %s", filename)
	return true
}
