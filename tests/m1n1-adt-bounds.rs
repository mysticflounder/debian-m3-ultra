#![allow(dead_code)]
#![allow(non_camel_case_types)]

use std::ffi::{c_void, CStr, CString};
use std::mem::size_of_val;
use std::ptr;

pub type c_size_t = usize;

#[no_mangle]
pub static mut adt: *const c_void = ptr::null();

static mut ADT_SIZE: u32 = 0;

#[no_mangle]
unsafe extern "C" fn adt_get_size() -> u32 {
    ADT_SIZE
}

mod source {
    include!("adt.rs");
}

const DT: *const c_void = ptr::null();
const CANARY: u8 = 0xcd;
const BAD_LENGTH: i32 = -20;
const RESTORE: &[u8] = include_bytes!("adt-j575d-decoded.bin");

#[derive(Clone)]
struct Node {
    props: Vec<(&'static str, Vec<u8>)>,
    children: Vec<Node>,
}

struct Installed {
    backing: Vec<u8>,
    extent: usize,
}

fn fail(message: &str) -> ! {
    eprintln!("FAIL: {message}");
    std::process::exit(1);
}

fn prop(name: &'static str, value: &[u8]) -> (&'static str, Vec<u8>) {
    (name, value.to_vec())
}

fn string(value: &str) -> Vec<u8> {
    let mut out = value.as_bytes().to_vec();
    out.push(0);
    out
}

fn cell(value: u32) -> Vec<u8> {
    value.to_le_bytes().to_vec()
}

fn emit_node(bytes: &mut Vec<u8>, node: &Node) -> usize {
    let offset = bytes.len();
    bytes.resize(offset + 8, 0);
    for (name, value) in &node.props {
        let mut name_bytes = [0u8; 32];
        if name.len() >= name_bytes.len() {
            fail("fixture property name is too long");
        }
        name_bytes[..name.len()].copy_from_slice(name.as_bytes());
        bytes.extend_from_slice(&name_bytes);
        bytes.extend_from_slice(&(value.len() as u32).to_le_bytes());
        bytes.extend_from_slice(value);
        while bytes.len() % 4 != 0 {
            bytes.push(0);
        }
    }
    for child in &node.children {
        emit_node(bytes, child);
    }
    bytes[offset..offset + 4].copy_from_slice(&(node.props.len() as u32).to_le_bytes());
    bytes[offset + 4..offset + 8]
        .copy_from_slice(&(node.children.len() as u32).to_le_bytes());
    offset
}

fn basic_image() -> (Vec<u8>, usize, usize) {
    let root = Node {
        props: vec![
            prop("name", &string("root")),
            prop("#address-cells", &cell(1)),
            prop("#size-cells", &cell(1)),
            prop("compatible", b"foo\0bar\0"),
        ],
        children: vec![
            Node {
                props: vec![
                    prop("name", &string("uart")),
                    prop("reg", &[0x00, 0x10, 0, 0, 0x20, 0, 0, 0]),
                    prop("compatible", &string("serial")),
                ],
                children: vec![],
            },
            Node {
                props: vec![prop("name", &string("gpu"))],
                children: vec![],
            },
        ],
    };
    let mut bytes = Vec::new();
    let root_offset = emit_node(&mut bytes, &root);
    let child_offset = 8 + 44 + 40 + 40 + 44;
    if root_offset != 0 || child_offset >= bytes.len() {
        fail("basic fixture layout changed unexpectedly");
    }
    let extent = bytes.len();
    (bytes, child_offset, extent)
}

fn probe_image(size: usize, flagged: bool) -> (Vec<u8>, usize, u32) {
    let padded = (size + 3) & !3;
    let extent = 8 + 36 + padded;
    let mut bytes = vec![0u8; extent];
    bytes[0..4].copy_from_slice(&1u32.to_le_bytes());
    bytes[4..8].copy_from_slice(&0u32.to_le_bytes());
    bytes[8..40].fill(0);
    bytes[8..13].copy_from_slice(b"probe");
    let raw = (size as u32) | if flagged { 0x8000_0000 } else { 0 };
    bytes[40..44].copy_from_slice(&raw.to_le_bytes());
    for (index, byte) in bytes[44..44 + size].iter_mut().enumerate() {
        *byte = (index as u8).wrapping_add(0x30);
    }
    (bytes, extent, raw)
}

fn ranges_image(ranges: &[u8]) -> (Vec<u8>, usize, usize) {
    let device = Node {
        props: vec![
            prop("name", &string("device")),
            prop("reg", &[0x10, 0x10, 0, 0, 0x20, 0, 0, 0]),
        ],
        children: vec![],
    };
    let bus = Node {
        props: vec![
            prop("name", &string("bus")),
            prop("#address-cells", &cell(1)),
            prop("#size-cells", &cell(1)),
            prop("ranges", ranges),
        ],
        children: vec![device],
    };
    let root = Node {
        props: vec![
            prop("name", &string("root")),
            prop("#address-cells", &cell(1)),
            prop("#size-cells", &cell(1)),
        ],
        children: vec![bus],
    };
    let mut bytes = Vec::new();
    emit_node(&mut bytes, &root);
    let bus_offset = 8 + 44 + 40 + 40;
    let ranges_record = 36 + ((ranges.len() + 3) & !3);
    let device_offset = bus_offset + 8 + 40 + 40 + 40 + ranges_record;
    if device_offset >= bytes.len() {
        fail("ranges fixture layout changed unexpectedly");
    }
    (bytes, bus_offset, device_offset)
}

fn chain_node(level: usize, depth: usize) -> Node {
    let mut props = vec![prop("name", &string(&format!("n{level}")))];
    props.push(prop("#address-cells", &cell(1)));
    props.push(prop("#size-cells", &cell(1)));
    if level + 1 == depth {
        props.push(prop("reg", &[0x10, 0x10, 0, 0, 0x20, 0, 0, 0]));
    }
    Node {
        props,
        children: if level + 1 < depth {
            vec![chain_node(level + 1, depth)]
        } else {
            vec![]
        },
    }
}

fn depth_image(depth: usize) -> Vec<u8> {
    let root = Node {
        props: vec![
            prop("name", &string("root")),
            prop("#address-cells", &cell(1)),
            prop("#size-cells", &cell(1)),
        ],
        children: vec![chain_node(0, depth)],
    };
    let mut bytes = Vec::new();
    emit_node(&mut bytes, &root);
    bytes
}

fn install(bytes: &[u8], declared: usize) -> Installed {
    if declared > bytes.len() {
        fail("fixture declared extent exceeds initialized bytes");
    }
    let mut backing = vec![CANARY; bytes.len() + 128];
    backing[..bytes.len()].copy_from_slice(bytes);
    if (backing.as_ptr() as usize) % 4 != 0 {
        fail("fixture backing is not four-byte aligned");
    }
    unsafe {
        ADT_SIZE = declared as u32;
        adt = backing.as_ptr() as *const c_void;
    }
    Installed { backing, extent: declared }
}

fn assert_rejected(label: &str, result: bool) {
    if result {
        fail(&format!("{label}: malformed input was accepted"));
    }
}

fn c_name(value: &str) -> CString {
    CString::new(value).unwrap()
}

fn probe_cases() {
    for flagged in [false, true] {
        for size in [0usize, 3, 4, 8, 256, 257] {
            let (bytes, extent, raw_size) = probe_image(size, flagged);
            let mut installed = install(&bytes, extent);
            let name = c_name("probe");
            let property = unsafe {
                match source::ADTNode::root().and_then(|node| node.named_prop("probe")) {
                    Ok(property) => property,
                    Err(_) => fail("public ADTNode property constructor rejected probe fixture"),
                }
            };
            let expected_dst = (36 + size + 3) & !3;
            if size_of_val(property) != expected_dst {
                fail(&format!(
                    "probe DST extent mismatch: size={size} flagged={flagged} actual={} expected={expected_dst}",
                    size_of_val(property)
                ));
            }

            unsafe {
                let mut length = 0u32;
                let value = source::adt_getprop(DT, 0, name.as_ptr(), &mut length);
                if value.is_null() || length != size as u32 {
                    fail("probe C getter length mismatch");
                }
                let mut offset_length = 0u32;
                let offset_value = source::adt_getprop_by_offset(
                    DT,
                    8,
                    ptr::null_mut(),
                    &mut offset_length,
                );
                if offset_value.is_null() || offset_length != size as u32 {
                    fail("probe offset getter length mismatch");
                }
                if size != 0
                    && std::slice::from_raw_parts(value as *const u8, size)
                        != &bytes[44..44 + size]
                {
                    fail("probe C getter bytes mismatch");
                }

                let mut copied = vec![0xa5u8; size.max(1)];
                let exact = source::adt_getprop_copy(
                    DT,
                    0,
                    name.as_ptr(),
                    copied.as_mut_ptr() as *mut c_void,
                    size,
                );
                if exact != size as i32
                    || (size != 0 && copied[..size] != bytes[44..44 + size])
                {
                    fail("probe exact copy mismatch");
                }
                for wrong_length in [size.checked_sub(1), size.checked_add(1)] {
                    let Some(wrong_length) = wrong_length else { continue };
                    let mut destination = vec![0xa5u8; size.max(wrong_length).max(1) + 1];
                    let before = destination.clone();
                    let result = source::adt_getprop_copy(
                        DT,
                        0,
                        name.as_ptr(),
                        destination.as_mut_ptr() as *mut c_void,
                        wrong_length,
                    );
                    if result != BAD_LENGTH || destination != before {
                        fail("probe rejected copy changed its destination");
                    }
                }

                let wire_before = u32::from_le_bytes(
                    installed.backing[40..44].try_into().unwrap(),
                );
                let outside_before = installed.backing[extent..].to_vec();
                let replacement = vec![0x5bu8; size.max(1)];
                let replaced = source::adt_setprop(
                    DT,
                    0,
                    name.as_ptr(),
                    replacement.as_ptr() as *const c_void,
                    size as *const c_size_t,
                );
                if replaced != size as i32
                    || u32::from_le_bytes(installed.backing[40..44].try_into().unwrap()) != wire_before
                    || installed.backing[extent..] != outside_before
                    || (size != 0 && installed.backing[44..44 + size] != replacement[..size])
                {
                    fail("probe setter changed flag/header/canary contract");
                }
                if wire_before != raw_size {
                    fail("probe wire size flag was not preserved");
                }
            }
        }
    }
}

fn valid_basic() {
    let (bytes, uart, extent) = basic_image();
    let mut installed = install(&bytes, extent);
    let uart_name = c_name("uart");
    let root_name = c_name("name");
    let compatible = c_name("foo");
    let reg_name = c_name("reg");
    unsafe {
        if source::adt_check_header(DT) != 0
            || source::adt_get_property_count(DT, 0) != 4
            || source::adt_get_child_count(DT, 0) != 2
            || source::adt_first_property_offset(DT, 0) != 8
            || source::adt_first_child_offset(DT, 0) != uart as i32
            || source::adt_subnode_offset(DT, 0, uart_name.as_ptr()) != uart as i32
        {
            fail("valid node/property/child offsets changed");
        }
        let next = source::adt_next_sibling_offset(DT, uart as i32);
        if next <= uart as i32 || source::adt_get_property_count(DT, next) != 1 {
            fail("valid sibling traversal failed");
        }
        if source::adt_is_compatible(DT, 0, compatible.as_ptr()) != true
            || source::adt_is_compatible_at(DT, 0, compatible.as_ptr(), 0) != true
        {
            fail("valid compatibility lookup failed");
        }
        let name = source::adt_get_name(DT, 0);
        if name.is_null() || CStr::from_ptr(name).to_bytes() != b"root" {
            fail("valid node name lookup failed");
        }
        let mut length = 0u32;
        let value = source::adt_getprop(DT, uart as i32, reg_name.as_ptr(), &mut length);
        if value.is_null() || length != 8 {
            fail("valid property getter failed");
        }
        if source::adt_get_property_by_offset(DT, source::adt_first_property_offset(DT, uart as i32)).is_null()
            || source::adt_get_property(DT, uart as i32, root_name.as_ptr()).is_null()
        {
            fail("valid property pointer lookup failed");
        }
        let mut out = [0u8; 8];
        if source::adt_getprop_copy(DT, uart as i32, reg_name.as_ptr(), out.as_mut_ptr() as *mut c_void, 8) != 8
            || out != [0, 0x10, 0, 0, 0x20, 0, 0, 0]
        {
            fail("valid property copy failed");
        }
        let before = installed.backing.clone();
        if source::adt_getprop_copy(DT, uart as i32, reg_name.as_ptr(), out.as_mut_ptr() as *mut c_void, 7) != BAD_LENGTH
            || installed.backing != before
        {
            fail("copy length rejection changed ADT bytes");
        }
        let replacement = b"serial\0";
        if source::adt_setprop(
            DT,
            uart as i32,
            c_name("compatible").as_ptr(),
            replacement.as_ptr() as *const c_void,
            7usize as *const c_size_t,
        ) != 7
        {
            fail("valid mutable property path failed");
        }
        let before = installed.backing.clone();
        if source::adt_setprop(
            DT,
            uart as i32,
            c_name("compatible").as_ptr(),
            b"x\0".as_ptr() as *const c_void,
            2usize as *const c_size_t,
        ) != BAD_LENGTH
            || installed.backing != before
        {
            fail("mutable length rejection changed ADT bytes");
        }
        let mut trace = [-99i32; 8];
        if source::adt_path_offset_trace(DT, c_name("/uart").as_ptr(), trace.as_mut_ptr()) != uart as i32
            || trace[0] != uart as i32
            || trace[1] != 0
            || source::adt_path_offset(DT, c_name("/uart").as_ptr()) != uart as i32
        {
            fail("valid path traversal failed");
        }
        let mut addr = 0u64;
        let mut size = 0u64;
        let mut path = [uart as i32, 0];
        if source::adt_get_reg(DT, path.as_mut_ptr(), reg_name.as_ptr(), 0, &mut addr, &mut size) != 0
            || addr != 0x1000
            || size != 0x20
        {
            fail("valid reg lookup failed");
        }
    }
    let _ = installed.extent;
}

fn valid_ranges() {
    let (empty, bus, device) = ranges_image(&[]);
    let _empty = install(&empty, empty.len());
    let mut path = [bus as i32, device as i32, 0];
    let mut addr = 0u64;
    let mut size = 0u64;
    unsafe {
        let actual_bus = source::adt_first_child_offset(DT, 0);
        let actual_device = source::adt_first_child_offset(DT, bus as i32);
        if actual_bus != bus as i32 || actual_device != device as i32
        {
            fail(&format!("ranges fixture offsets wrong: expected bus={bus} device={device}, actual bus={actual_bus} device={actual_device}"));
        }
        let result = source::adt_get_reg(DT, path.as_mut_ptr(), c_name("reg").as_ptr(), 0, &mut addr, &mut size);
        if result != 0
            || addr != 0x1010
            || size != 0x20
        {
            fail(&format!("zero-length ranges did not preserve identity translation: result={result} addr={addr:#x} size={size:#x} bus={bus} device={device}"));
        }
    }
    let ranges = [0, 0x10, 0, 0, 0, 0x20, 0, 0, 0, 1, 0, 0];
    let (complete, complete_bus, complete_device) = ranges_image(&ranges);
    let _complete = install(&complete, complete.len());
    path = [complete_bus as i32, complete_device as i32, 0];
    unsafe {
        let result = source::adt_get_reg(DT, path.as_mut_ptr(), c_name("reg").as_ptr(), 0, &mut addr, &mut size);
        if result != 0
            || addr != 0x2010
            || size != 0x20
        {
            fail(&format!("complete ranges translation failed: result={result} addr={addr:#x} size={size:#x}"));
        }
    }
    let short = [0, 0x10, 0, 0, 0, 0x20, 0, 0];
    let (truncated, truncated_bus, truncated_device) = ranges_image(&short);
    let _truncated = install(&truncated, truncated.len());
    path = [truncated_bus as i32, truncated_device as i32, 0];
    unsafe {
        assert_rejected(
            "truncated ranges",
            source::adt_get_reg(DT, path.as_mut_ptr(), c_name("reg").as_ptr(), 0, &mut addr, &mut size) == 0,
        );
    }
}

fn malformed_extents() {
    let (bytes, uart, full) = basic_image();
    for declared in [0usize, 7, 8] {
        let _installed = install(&bytes, declared);
        unsafe {
            if declared < 8 {
                assert_rejected("short root extent", source::adt_check_header(DT) == 0);
            } else if source::adt_check_header(DT) != 0 {
                fail("exact eight-byte node header was rejected");
            }
        }
    }
    let mut zero_counts = bytes.clone();
    zero_counts[0..4].copy_from_slice(&0u32.to_le_bytes());
    let _installed = install(&zero_counts, 8);
    unsafe { assert_rejected("zero property count", source::adt_check_header(DT) == 0) }
    let mut over_counts = bytes.clone();
    over_counts[0..4].copy_from_slice(&2049u32.to_le_bytes());
    let _installed = install(&over_counts, 8);
    unsafe { assert_rejected("over-limit property count", source::adt_check_header(DT) == 0) }

    let first_property = 8;
    for (label, payload, declared) in [
        ("35-byte property header", 0u32, first_property + 35),
        ("one-byte-short payload", 4u32, first_property + 39),
        ("missing alignment padding", 3u32, first_property + 39),
    ] {
        let mut malformed = bytes.clone();
        malformed[first_property + 32..first_property + 36].copy_from_slice(&payload.to_le_bytes());
        let _installed = install(&malformed, declared);
        unsafe {
            assert_rejected(
                label,
                !source::adt_get_property_by_offset(DT, first_property as i32).is_null(),
            );
        }
    }
    let mut exact_zero = bytes.clone();
    exact_zero[first_property + 32..first_property + 36].copy_from_slice(&0u32.to_le_bytes());
    let _installed = install(&exact_zero, first_property + 36);
    unsafe {
        if source::adt_get_property_by_offset(DT, first_property as i32).is_null()
            || source::adt_next_property_offset(DT, first_property as i32) != (first_property + 36) as i32
        {
            fail("exact-end zero payload property was rejected");
        }
    }
    for raw in [0x7fff_ffffu32, u32::MAX] {
        let mut huge = bytes.clone();
        huge[first_property + 32..first_property + 36].copy_from_slice(&raw.to_le_bytes());
        let _installed = install(&huge, full);
        unsafe {
            assert_rejected(
                "oversized/flagged property payload",
                !source::adt_get_property_by_offset(DT, first_property as i32).is_null(),
            );
        }
    }
    let mut flagged = bytes.clone();
    flagged[first_property + 32..first_property + 36]
        .copy_from_slice(&0x8000_0003u32.to_le_bytes());
    let _installed = install(&flagged, first_property + 40);
    unsafe {
        let mut length = 0u32;
        if source::adt_get_property_by_offset(DT, first_property as i32).is_null()
            || source::adt_getprop_by_offset(DT, first_property as i32, ptr::null_mut(), &mut length).is_null()
            || length != 3
        {
            fail("bit-31 flagged property was not normalized and bounded");
        }
    }
    let _ = uart;
}

fn malformed_offsets() {
    let (bytes, uart, extent) = basic_image();
    let _installed = install(&bytes, extent);
    let name = c_name("name");
    let mut out = [0xa5u8; 8];
    let mut len = 0u32;
    let mut trace = [0i32; 8];
    let mut path = [uart as i32; 8];
    let mut addr = 0xaaaa_u64;
    let mut size = 0xbbbb_u64;
    let val = b"root\0";
    unsafe {
        for offset in [-1i32, i32::MAX] {
            assert_rejected("first property offset", source::adt_first_property_offset(DT, offset) >= 0);
            assert_rejected("next property offset", source::adt_next_property_offset(DT, offset) >= 0);
            assert_rejected("first child offset", source::adt_first_child_offset(DT, offset) >= 0);
            assert_rejected("next sibling offset", source::adt_next_sibling_offset(DT, offset) >= 0);
            assert_rejected("child count", source::adt_get_child_count(DT, offset) >= 0);
            assert_rejected("property count", source::adt_get_property_count(DT, offset) >= 0);
            assert_rejected("property by offset", !source::adt_get_property_by_offset(DT, offset).is_null());
            assert_rejected("property", !source::adt_get_property(DT, offset, name.as_ptr()).is_null());
            assert_rejected("getprop", !source::adt_getprop(DT, offset, name.as_ptr(), &mut len).is_null());
            assert_rejected("getprop by offset", !source::adt_getprop_by_offset(DT, offset, ptr::null_mut(), &mut len).is_null());
            let before = unsafe { std::slice::from_raw_parts(adt as *const u8, extent).to_vec() };
            assert_rejected(
                "setprop",
                source::adt_setprop(DT, offset, name.as_ptr(), val.as_ptr() as *const c_void, 5usize as *const c_size_t) >= 0,
            );
            if before != unsafe { std::slice::from_raw_parts(adt as *const u8, extent) } {
                fail("rejected mutable offset changed ADT bytes");
            }
            assert_rejected("subnode", source::adt_subnode_offset(DT, offset, name.as_ptr()) >= 0);
            assert_rejected("compatible", source::adt_is_compatible(DT, offset, name.as_ptr()));
            assert_rejected("compatible at", source::adt_is_compatible_at(DT, offset, name.as_ptr(), 0));
            assert_rejected("get name", !source::adt_get_name(DT, offset).is_null());
            assert_rejected("copy", source::adt_getprop_copy(DT, offset, name.as_ptr(), out.as_mut_ptr() as *mut c_void, 5) >= 0);
            assert_rejected("path trace", source::adt_path_offset_trace(DT, name.as_ptr(), trace.as_mut_ptr()) >= 0);
            path[0] = offset;
            path[1] = 0;
            assert_rejected("get reg", source::adt_get_reg(DT, path.as_mut_ptr(), name.as_ptr(), 0, &mut addr, &mut size) == 0);
        }
        let mut unterminated = [uart as i32; 8];
        assert_rejected("unterminated depth-8 path", source::adt_get_reg(DT, unterminated.as_mut_ptr(), name.as_ptr(), 0, &mut addr, &mut size) == 0);
        let mut index_overflow = [uart as i32, 0];
        assert_rejected("negative register index", source::adt_get_reg(DT, index_overflow.as_mut_ptr(), c_name("reg").as_ptr(), -1, &mut addr, &mut size) == 0);
        assert_rejected("maximum register index", source::adt_get_reg(DT, index_overflow.as_mut_ptr(), c_name("reg").as_ptr(), i32::MAX, &mut addr, &mut size) == 0);
    }
}

fn base_guard_cases() {
    unsafe {
        ADT_SIZE = 8;
        adt = ptr::null();
        assert_rejected("null ADT base", source::adt_check_header(DT) == 0);
        adt = 3usize as *const c_void;
        assert_rejected("misaligned ADT base", source::adt_check_header(DT) == 0);
        adt = (usize::MAX - 3) as *const c_void;
        assert_rejected("wrapping ADT base", source::adt_check_header(DT) == 0);
    }
    let (bytes, _uart, extent) = basic_image();
    let _installed = install(&bytes, 8);
    unsafe {
        if source::adt_get_property_by_offset(DT, 8).is_null() == false {
            fail("constructor lower-bound accepted property at exact eight-byte extent");
        }
    }
    let _ = extent;
}

fn depth_paths() {
    let bytes = depth_image(7);
    let _installed = install(&bytes, bytes.len());
    let mut offsets = [0i32; 7];
    unsafe {
        offsets[0] = source::adt_first_child_offset(DT, 0);
        if offsets[0] < 0 {
            fail("depth-7 first child was rejected");
        }
        for index in 1..offsets.len() {
            offsets[index] = source::adt_first_child_offset(DT, offsets[index - 1]);
            if offsets[index] < 0 {
                fail("depth-7 child chain was rejected");
            }
        }
        let mut path_text = String::new();
        for index in 0..offsets.len() {
            path_text.push_str(&format!("/n{index}"));
        }
        let path_text = CString::new(path_text).unwrap();
        let mut trace = [-7i32; 8];
        if source::adt_path_offset_trace(DT, path_text.as_ptr(), trace.as_mut_ptr()) != offsets[6]
            || trace[..7] != offsets
            || trace[7] != 0
        {
            fail("terminating depth-7 path trace changed");
        }
        let mut bounded = [0i32; 8];
        bounded[..7].copy_from_slice(&offsets);
        bounded[7] = offsets[6];
        let mut address = 0xaaaa_u64;
        let mut size = 0xbbbb_u64;
        if source::adt_get_reg(
            DT,
            bounded.as_mut_ptr(),
            c_name("reg").as_ptr(),
            0,
            &mut address,
            &mut size,
        ) != -5
            || address != 0xaaaa
            || size != 0xbbbb
        {
            fail("unterminated depth-8 path was not rejected without output writes");
        }
        let mut terminating = [0i32; 8];
        terminating[..7].copy_from_slice(&offsets);
        if source::adt_get_reg(
            DT,
            terminating.as_mut_ptr(),
            c_name("reg").as_ptr(),
            0,
            &mut address,
            &mut size,
        ) != 0
            || address != 0x1010
            || size != 0x20
        {
            fail("terminating depth-7 reg path failed");
        }
    }

    let bytes = depth_image(8);
    let _installed = install(&bytes, bytes.len());
    let path_text: String = (0..8).map(|index| format!("/n{index}")).collect();
    let path = c_name(&path_text);
    let mut refs = [None; 8];
    if source::ADTNode::from_path_trace(&path_text, Some(&mut refs)).is_err()
        || refs.iter().any(Option::is_none)
    {
        fail("Rust depth-8 breadcrumb contract changed");
    }
    let mut trace = [-7i32; 8];
    let before = trace;
    unsafe {
        if source::adt_path_offset(DT, path.as_ptr()) < 0 {
            fail("untraced depth-8 C path was incorrectly rejected");
        }
        if source::adt_path_offset_trace(DT, path.as_ptr(), trace.as_mut_ptr()) != -5
            || trace != before
        {
            fail("depth-8 C trace producer did not reject before writing outputs");
        }
    }
}

fn walk_restore(offset: i32, depth: usize, nodes: &mut usize, properties: &mut usize) {
    if depth > 64 {
        fail("restore fixture traversal exceeded depth guard");
    }
    unsafe {
        let property_count = source::adt_get_property_count(DT, offset);
        let child_count = source::adt_get_child_count(DT, offset);
        if property_count <= 0 || child_count < 0 {
            fail("restore fixture node header was rejected");
        }
        *nodes += 1;
        let mut property = source::adt_first_property_offset(DT, offset);
        for _ in 0..property_count {
            if property < 0 || source::adt_get_property_by_offset(DT, property).is_null() {
                fail("restore fixture property was rejected");
            }
            *properties += 1;
            property = source::adt_next_property_offset(DT, property);
            if property < 0 {
                fail("restore fixture property end was rejected");
            }
        }
        if child_count == 0 {
            return;
        }
        let mut child = source::adt_first_child_offset(DT, offset);
        if child < 0 {
            fail("restore fixture first child was rejected");
        }
        for index in 0..child_count {
            walk_restore(child, depth + 1, nodes, properties);
            if index + 1 < child_count {
                child = source::adt_next_sibling_offset(DT, child);
                if child < 0 {
                    fail("restore fixture sibling was rejected");
                }
            }
        }
    }
}

fn restore_fixture() {
    let _installed = install(RESTORE, RESTORE.len());
    unsafe {
        if source::adt_check_header(DT) != 0 {
            fail("actual J575d restore root was rejected");
        }
    }
    let mut nodes = 0;
    let mut properties = 0;
    walk_restore(0, 0, &mut nodes, &mut properties);
    if nodes != 771 || properties != 9999 {
        fail(&format!("actual J575d restore counts changed: nodes={nodes} properties={properties}"));
    }
}

fn main() {
    base_guard_cases();
    probe_cases();
    valid_basic();
    valid_ranges();
    malformed_extents();
    malformed_offsets();
    depth_paths();
    restore_fixture();
    println!("ADT physical bounds: exact extents, records, chains, ranges, signed offsets, C wrappers, mutable rejection, bounded paths, and J575d restore traversal passed");
}
