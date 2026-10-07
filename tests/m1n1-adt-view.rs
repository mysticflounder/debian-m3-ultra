#![allow(dead_code)]
#![allow(non_camel_case_types)]

use std::ffi::{c_void, CString};
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

const VALUE_OFFSET: usize = 44;
const CANARY: [u8; 16] = [
    0, 0xd1, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xdb, 0xdc, 0xdd,
    0xde, 0xdf,
];

fn fail(message: &str) -> ! {
    eprintln!("FAIL: {message}");
    std::process::exit(1);
}

fn make_value(size: usize) -> Vec<u8> {
    if size == 0 {
        return Vec::new();
    }
    if size == 3 {
        return b"abc".to_vec();
    }
    if size == 4 {
        return 0x1234_5678u32.to_ne_bytes().to_vec();
    }
    let mut value = vec![b'x'; size];
    value[..8].copy_from_slice(b"one\0two\0");
    value
}

fn make_tree(value: &[u8], flagged: bool) -> (Vec<u32>, Vec<u8>) {
    let total_bytes = VALUE_OFFSET + value.len() + CANARY.len() + 512;
    let words = (total_bytes + 3) / 4;
    let mut backing = vec![0xa5a5_a5a5u32; words];
    let bytes = unsafe {
        std::slice::from_raw_parts_mut(
            backing.as_mut_ptr().cast::<u8>(),
            backing.len() * std::mem::size_of::<u32>(),
        )
    };
    bytes[0..4].copy_from_slice(&1u32.to_le_bytes());
    bytes[4..8].copy_from_slice(&0u32.to_le_bytes());
    bytes[8..40].fill(0);
    bytes[8..13].copy_from_slice(b"probe");
    let raw_size = value.len() as u32 | if flagged { 0x8000_0000 } else { 0 };
    bytes[40..44].copy_from_slice(&raw_size.to_le_bytes());
    bytes[VALUE_OFFSET..VALUE_OFFSET + value.len()].copy_from_slice(value);
    bytes[VALUE_OFFSET + value.len()..VALUE_OFFSET + value.len() + CANARY.len()]
        .copy_from_slice(&CANARY);
    (backing, bytes.to_vec())
}

fn make_flagged_tree() -> (Vec<u32>, Vec<u8>) {
    const SECOND_PROPERTY_OFFSET: usize = 48;
    const SECOND_VALUE_OFFSET: usize = 84;
    const TOTAL_BYTES: usize = SECOND_VALUE_OFFSET + 4 + CANARY.len() + 512;
    let mut backing = vec![0xa5a5_a5a5u32; (TOTAL_BYTES + 3) / 4];
    let bytes = unsafe {
        std::slice::from_raw_parts_mut(
            backing.as_mut_ptr().cast::<u8>(),
            backing.len() * std::mem::size_of::<u32>(),
        )
    };
    bytes[0..4].copy_from_slice(&2u32.to_le_bytes());
    bytes[4..8].copy_from_slice(&0u32.to_le_bytes());
    bytes[8..40].fill(0);
    bytes[8..13].copy_from_slice(b"templ");
    bytes[40..44].copy_from_slice(&0x8000_0003u32.to_le_bytes());
    bytes[44..47].copy_from_slice(b"abc");
    bytes[SECOND_PROPERTY_OFFSET..SECOND_PROPERTY_OFFSET + 32].fill(0);
    bytes[SECOND_PROPERTY_OFFSET..SECOND_PROPERTY_OFFSET + 6].copy_from_slice(b"scalar");
    bytes[SECOND_PROPERTY_OFFSET + 32..SECOND_PROPERTY_OFFSET + 36]
        .copy_from_slice(&4u32.to_le_bytes());
    bytes[SECOND_VALUE_OFFSET..SECOND_VALUE_OFFSET + 4]
        .copy_from_slice(&0x1234_5678u32.to_ne_bytes());
    bytes[SECOND_VALUE_OFFSET + 4..SECOND_VALUE_OFFSET + 4 + CANARY.len()]
        .copy_from_slice(&CANARY);
    (backing, bytes.to_vec())
}

fn install(tree: &[u32]) {
    unsafe {
        ADT_SIZE = (tree.len() * std::mem::size_of::<u32>()) as u32;
        adt = tree.as_ptr() as *const c_void;
    }
}

fn check_property(size: usize, flagged: bool) {
    let value = make_value(size);
    let (tree, initial_bytes) = make_tree(&value, flagged);
    install(&tree);
    let name = CString::new("probe").unwrap();
    let property = unsafe { source::adt_view_harness_property(0, name.as_ptr()) };
    let property = match property {
        Some(property) => property,
        None => {
            fail(&format!("ADT property lookup failed for {size}-byte payload"));
        }
    };

    // repr(C) rounds the complete DST value to the ADT's four-byte alignment.
    let expected_view_size = (36 + size + 3) & !3;
    let actual_view_size = size_of_val(property);
    if actual_view_size != expected_view_size {
        if actual_view_size == expected_view_size + 36 {
            fail("ADT DST metadata includes the property header");
        }
        if size >= 0x100 && actual_view_size == (36 + (size & 0xff) + 3) & !3 {
            fail("ADT DST metadata read only the first size byte");
        }
        fail(&format!(
            "ADT property view length mismatch for {size}-byte payload: got {actual_view_size}, expected {expected_view_size}"
        ));
    }

    let mut reported_len = 0u32;
    let raw_value = unsafe {
        source::adt_getprop(ptr::null(), 0, name.as_ptr(), &mut reported_len as *mut u32)
    };
    if reported_len as usize != size || raw_value.is_null() {
        fail(&format!("ADT public value view length mismatch for {size}-byte payload"));
    }
    if size != 0 {
        let observed = unsafe { std::slice::from_raw_parts(raw_value as *const u8, size) };
        if observed != value.as_slice() {
            fail(&format!("ADT public value bytes changed for {size}-byte payload"));
        }
    }

    if size == 0 {
        if property.str().is_ok() || property.str_iter().next().is_some() {
            fail("ADT string view escaped the zero-byte payload");
        }
    } else if size == 3 {
        if !matches!(property.str(), Err(source::AdtError::BadValue))
            || property.str_iter().next().is_some()
        {
            fail("ADT unterminated string view escaped the three-byte payload");
        }
    } else if size == 4 {
        if !matches!(property.str(), Err(source::AdtError::BadValue))
            || property.str_iter().next().is_some()
        {
            fail("ADT scalar string view escaped the four-byte payload");
        }
        if !matches!(property.u32(), Ok(0x1234_5678)) {
            fail("ADT scalar u32 view mismatch for four-byte payload");
        }
    } else {
        if !matches!(property.str(), Ok("one")) {
            fail(&format!("ADT string view mismatch for {size}-byte payload"));
        }
        let strings: Vec<&str> = property.str_iter().collect();
        if strings != ["one", "two"] {
            fail(&format!("ADT string iterator escaped the {size}-byte payload"));
        }
    }

    let final_bytes = unsafe {
        std::slice::from_raw_parts(
            tree.as_ptr().cast::<u8>(),
            tree.len() * std::mem::size_of::<u32>(),
        )
    };
    let expected_raw_size = size as u32 | if flagged { 0x8000_0000 } else { 0 };
    if u32::from_le_bytes(final_bytes[40..44].try_into().unwrap()) != expected_raw_size {
        fail(&format!("ADT wire size flag changed for {size}-byte payload"));
    }
    let canary_start = VALUE_OFFSET + size;
    if final_bytes[canary_start..canary_start + CANARY.len()]
        != initial_bytes[canary_start..canary_start + CANARY.len()]
    {
        fail(&format!("ADT value view modified canary for {size}-byte payload"));
    }
}

fn check_flagged_properties() {
    const SECOND_PROPERTY_OFFSET: i32 = 48;
    const SECOND_VALUE_OFFSET: usize = 84;
    let (tree, initial_bytes) = make_flagged_tree();
    install(&tree);
    let templ_name = CString::new("templ").unwrap();

    // Check the normalized C length through the offset getter before any
    // named lookup, traversal, copy, or large logical size is attempted.
    let mut templ_len = 0u32;
    let templ_raw = unsafe {
        source::adt_getprop_by_offset(
            ptr::null(),
            8,
            ptr::null_mut(),
            &mut templ_len as *mut u32,
        )
    };
    if templ_len != 3 || templ_raw.is_null() {
        fail("ADT flagged C getter length was not normalized");
    }
    if unsafe { std::slice::from_raw_parts(templ_raw as *const u8, 3) } != b"abc" {
        fail("ADT flagged C getter bytes changed");
    }

    let mut copy_out = [0xa5u8; 8];
    let copy_result = unsafe {
        source::adt_getprop_copy(
            ptr::null(),
            0,
            templ_name.as_ptr(),
            copy_out.as_mut_ptr() as *mut c_void,
            3,
        )
    };
    if copy_result != 3 || copy_out[..3] != *b"abc" || copy_out[3..] != [0xa5; 5] {
        fail("ADT flagged exact copy contract changed");
    }
    let before_copy = copy_out;
    let mismatch_result = unsafe {
        source::adt_getprop_copy(
            ptr::null(),
            0,
            templ_name.as_ptr(),
            copy_out.as_mut_ptr() as *mut c_void,
            4,
        )
    };
    if mismatch_result != -20 || copy_out != before_copy {
        fail("ADT flagged mismatch copy modified destination");
    }

    if unsafe { source::adt_get_property_count(ptr::null(), 0) } != 2 {
        fail("ADT flagged property count changed");
    }
    let first_offset = unsafe { source::adt_first_property_offset(ptr::null(), 0) };
    let next_offset = unsafe { source::adt_next_property_offset(ptr::null(), first_offset) };
    if first_offset != 8 || next_offset != SECOND_PROPERTY_OFFSET {
        fail("ADT flagged padded property traversal changed");
    }
    let properties = unsafe { source::adt_view_harness_properties(0) };
    let properties = match properties {
        Some(properties) if properties.len() == 2 => properties,
        _ => fail("ADT flagged property iterator did not return two properties"),
    };
    let first = properties[0];
    let second = properties[1];
    if first.name() != "templ" || size_of_val(first) != 40 {
        fail("ADT flagged first property name or extent changed");
    }
    if !matches!(first.str(), Err(source::AdtError::BadValue))
        || first.str_iter().next().is_some()
    {
        fail("ADT flagged first string view escaped its three-byte payload");
    }
    if second.name() != "scalar"
        || size_of_val(second) != 40
        || !matches!(second.u32(), Ok(0x1234_5678))
    {
        fail("ADT flagged second scalar view changed");
    }

    let final_bytes = unsafe {
        std::slice::from_raw_parts(
            tree.as_ptr().cast::<u8>(),
            tree.len() * std::mem::size_of::<u32>(),
        )
    };
    if u32::from_le_bytes(final_bytes[40..44].try_into().unwrap()) != 0x8000_0003
        || u32::from_le_bytes(
            final_bytes[SECOND_PROPERTY_OFFSET as usize + 32..SECOND_PROPERTY_OFFSET as usize + 36]
                .try_into()
                .unwrap(),
        ) != 4
    {
        fail("ADT template size flag changed after getter/copy");
    }
    if final_bytes[SECOND_VALUE_OFFSET + 4..SECOND_VALUE_OFFSET + 4 + CANARY.len()]
        != initial_bytes[SECOND_VALUE_OFFSET + 4..SECOND_VALUE_OFFSET + 4 + CANARY.len()]
    {
        fail("ADT flagged property traversal modified canary");
    }
}

fn main() {
    for size in [0usize, 3, 4, 8, 0x100, 0x101] {
        check_property(size, false);
    }
    check_flagged_properties();
    for size in [0usize, 3, 4, 8, 0x100, 0x101] {
        check_property(size, true);
    }
    println!("ADT property view: public value/string/u32 views for unflagged+flagged 0/unterminated-3/4/short/0x100/0x101 lengths passed");
}
