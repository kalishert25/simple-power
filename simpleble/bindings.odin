package simpleble

import "core:c"

foreign import simpleble {
	"simplecble.lib",
	"simpleble.lib",
	"system:ole32.lib",
	"system:oleaut32.lib",
	"system:uuid.lib",
	"system:runtimeobject.lib",

}

Adapter    :: distinct rawptr
Peripheral :: distinct rawptr

Err :: enum c.int {
	SUCCESS = 0,
	FAILURE = 1,
}

UUID_STR_LEN            :: 37
CHARACTERISTIC_MAX_COUNT :: 16
DESCRIPTOR_MAX_COUNT     :: 16


UUID :: struct {
	value: [UUID_STR_LEN]c.char,
}

Descriptor :: struct {
	uuid: UUID,
}

// Field order matters here — must match types.h exactly.
Characteristic :: struct {
	uuid:               UUID,
	can_read:           bool,
	can_write_request:  bool,
	can_write_command:  bool,
	can_notify:         bool,
	can_indicate:       bool,
	descriptor_count:   c.size_t,
	descriptors:        [DESCRIPTOR_MAX_COUNT]Descriptor,
}

Service :: struct {
	uuid:                 UUID,
	data_length:          c.size_t,
	data:                 [27]c.uint8_t,
	characteristic_count: c.size_t,
	characteristics:      [CHARACTERISTIC_MAX_COUNT]Characteristic,
}

ManufacturerData :: struct {
	manufacturer_id: c.uint16_t,
	data_length:     c.size_t,
	data:            [27]c.uint8_t,
}

NotifyCallback :: #type proc "c" (
	handle:         Peripheral,
	service:        UUID,
	characteristic: UUID,
	data:           [^]c.uint8_t,
	data_length:    c.size_t,
	userdata:       rawptr,
)

@(default_calling_convention = "c")
@(link_prefix = "simpleble_")
foreign simpleble {
	adapter_get_count               :: proc() -> c.size_t ---
	adapter_get_handle              :: proc(index: c.size_t) -> Adapter ---
	adapter_release_handle          :: proc(handle: Adapter) ---

	adapter_scan_for                :: proc(handle: Adapter, timeout_ms: c.int) -> Err ---
	adapter_scan_get_results_count  :: proc(handle: Adapter) -> c.size_t ---
	adapter_scan_get_results_handle :: proc(handle: Adapter, index: c.size_t) -> Peripheral ---

	peripheral_identifier      :: proc(handle: Peripheral) -> cstring ---
	peripheral_address         :: proc(handle: Peripheral) -> cstring ---
	peripheral_is_connectable  :: proc(handle: Peripheral, connectable: ^bool) -> Err ---
	peripheral_release_handle  :: proc(handle: Peripheral) ---

	peripheral_connect    :: proc(handle: Peripheral) -> Err ---
	peripheral_disconnect :: proc(handle: Peripheral) -> Err ---

	peripheral_services_count :: proc(handle: Peripheral) -> c.size_t ---
	peripheral_services_get   :: proc(handle: Peripheral, index: c.size_t, service: ^Service) -> Err ---

	peripheral_notify      :: proc(handle: Peripheral, service: UUID, characteristic: UUID, callback: NotifyCallback, userdata: rawptr) -> Err ---
	peripheral_unsubscribe :: proc(handle: Peripheral, service: UUID, characteristic: UUID) -> Err ---

	free :: proc(handle: rawptr) ---
}
