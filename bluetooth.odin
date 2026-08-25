package main

import "core:fmt"
import "core:sync"
import "core:c"
import "base:runtime"
import "core:time"
import ble "simpleble"

CYCLING_POWER_SERVICE :: ble.UUID{
	value = "00001818-0000-1000-8000-00805f9b34fb\x00"
}
FTMS_SERVICE :: ble.UUID{
	value = "00001826-0000-1000-8000-00805f9b34fb\x00"
}

scan_for_ble_devices :: proc(state: ^State) {

	adapter_count := ble.adapter_get_count()
	if adapter_count == 0 {
		fmt.panicf("Bluetooth is either disabled or not supported on this device.\n")
	}

	adapter := ble.adapter_get_handle(0)
	if adapter == nil {
		fmt.panicf("Unable to open adapter.\n")
	}

	for {
		fmt.println("Doing scan...")
		new_ble_devices := [dynamic; MAX_DEVICES]DeviceView{}


		ble.adapter_scan_for(adapter, 3000)


		device_count := ble.adapter_scan_get_results_count(adapter)
		fmt.printf("Found %d devices.\n", device_count)

		for i in 0..<device_count {

			device_handle := ble.adapter_scan_get_results_handle(adapter, i)
			device := DeviceView{
				name = ble.peripheral_identifier(device_handle),
				mac_address = ble.peripheral_address(device_handle),
				handle = device_handle,
			}

			connectable := false;
			ble.peripheral_is_connectable(device_handle, &connectable)

			if !connectable || len(device.name) == 0 {
				free_device(&device)
				continue
			}

      found_relevant_service := false
      services_count := ble.peripheral_services_count(device_handle);

      look_for_services: for i in 0..<services_count {
      	service : ble.Service
        if ble.peripheral_services_get(device_handle, i, &service) == .SUCCESS {
         	switch service.uuid.value {
        		case FTMS_SERVICE.value:
          		fmt.println("Found FTMS service")
	           	found_relevant_service = true;
							break look_for_services
            case:
            	fmt.println("Found unknown service")
   	      }
        }
      }


      if !found_relevant_service {
	      free_device(&device)
				continue
			}

			is_power_meter := true

			if is_power_meter {
				append(&new_ble_devices, device)
			}

		}

		sync.lock(&state.ble_devices_mu)
		defer sync.unlock(&state.ble_devices_mu)

		original_length := len(state.ble_devices)
		outer: for new_device in new_ble_devices {
			// check for duplicates
			for i in 0..<original_length {
				existing_device := &state.ble_devices[i]

				if cstring_equals(new_device.mac_address, existing_device.mac_address) {
					// free and replace the old handle
					free_device(existing_device)
					state.ble_devices[i] = new_device
					continue outer;
				}
			}

			if len(state.ble_devices) < MAX_DEVICES {
				append(&state.ble_devices, new_device)
			}
		}
	}
}



free_device :: proc(device: ^DeviceView) {

	ble.peripheral_release_handle(device.handle)
	ble.free(rawptr(device.name))
	ble.free(rawptr(device.mac_address))
}

cstring_equals :: proc(cstr_a: cstring, cstr_b: cstring) -> bool {
	a := cast([^]byte)cstr_a
	b := cast([^]byte)cstr_b

	for i := 0 ;; i += 1  {
		if a[i] != b[i] {
			return false
		}

		if a[i] == 0 || b[i] == 0 {
			break
		}
	}
	return true
}


subscribe_to_device :: proc(state: ^State, device_handle: ble.Peripheral) -> ble.Err {
	if ble.peripheral_connect(device_handle) == .FAILURE {
		fmt.println("failed to connect")
		return .FAILURE
	}
	res := ble.peripheral_notify(device_handle, FTMS_SERVICE, INDOOR_BIKE_CHARACTERISTIC, indoor_bike_data_callback, state)
	return res
}

indoor_bike_data_callback :: proc "c" (
	handle:         ble.Peripheral,
	service:        ble.UUID,
	characteristic: ble.UUID,
	data:           [^]byte,
	data_length:    c.size_t,
	userdata:       rawptr,
) {
	state := cast(^State)userdata

	context = runtime.default_context() // needed to call Odin procs (like fmt) from a "c" proc
	if data_length < 2 do return

	flags := u16(data[0]) | (u16(data[1]) << 8)
	offset : c.size_t = 2

	// get the time
	current_time := time.now()
	data_point := RideDataPoint{
		time = current_time,
	}


	if flags & (1 << 0) == 0 do offset += 2 // Instantaneous Speed
	if flags & (1 << 1) != 0 do offset += 2 // Average Speed
	if flags & (1 << 2) != 0 { // Instantaneous Cadence
		double_cadence := i16(data[offset]) | (i16(data[offset+1]) << 8)
		data_point.data_types |= {.CADENCE}
		data_point.cadence = i32(double_cadence) / 2
		offset += 2
	}




	if flags & (1 << 3) != 0 do offset += 2 // Average Cadence
	if flags & (1 << 4) != 0 do offset += 3 // Total Distance
	if flags & (1 << 5) != 0 do offset += 2 // Resistance Level

	if flags & (1 << 6) != 0 {
		if offset + 2 > data_length do return
		power := i16(data[offset]) | (i16(data[offset+1]) << 8)

		data_point.data_types |= {.POWER}
		data_point.power = i32(power)

	}

	if data_point.data_types != {} {
		ride_data_array_append(state, data_point)
	}
}
