package main

import "core:os"
import "core:bufio"
import "core:fmt"
import "core:sync"
import "core:time"
import "core:mem"
import "core:slice"

ride_data_array_sample_time_interval :: proc(ride_data_array: ^RideDataArray, start_time, end_time: time.Time, start_index: i32 = 0) -> (value: f64, end_index: i32) {
	assert(time.diff(start_time, end_time) >= 0)
	data := ride_data_array.array
	total := i64(0)
	num_data_points : i32 = 0
	for index := start_index; index < i32(len(data)); index += 1 {
		before_start_of_interval := time.diff(data[index].time, start_time) > 0
		if before_start_of_interval {
			continue
		}

		after_end_of_interval := time.diff(end_time, data[index].time) >= 0
		if after_end_of_interval {
			break
		}

		num_data_points += 1
		total += data[index].value

	}

	if num_data_points == 0 {
		return 0, start_index
	}

	avg := f64(total) / f64(num_data_points)

	return avg, start_index + num_data_points


}


export_to_gpx :: proc(state: ^State, filename: string, ride_name: string) -> (success: bool) {

	defer free_all(context.temp_allocator)

	sync.lock(&state.power_data.mutex)
	defer sync.unlock(&state.power_data.mutex)

	sync.lock(&state.location_data.mutex)
	defer sync.unlock(&state.location_data.mutex)

	if len(state.location_data.array) == 0 {
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

	first_trackpoint_time := state.location_data.array[0].time
	start_time : time.Time
	{
		epoch := time.unix(0, 0)
		duration_since_epoch := time.diff(epoch, now)
		rounded_duration := time.duration_round(dur_since_epoch, time.Second)
		start_time := time.time_add(epoch, rounded_duration)
	}



	// track points
	track_point_format_string := `<trkpt lat="%f" lon="%f">
    <ele>0</ele>
    <time>%s</time>
    <extensions>
     <power>%v</power>
     <gpxtpx:TrackPointExtension>
      <gpxtpx:atemp>24</gpxtpx:atemp>
      <gpxtpx:cad>%v</gpxtpx:cad>
     </gpxtpx:TrackPointExtension>
    </extensions>
  </trkpt>
  `
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
	return true
}
