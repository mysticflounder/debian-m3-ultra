#![allow(dead_code)]
#![allow(non_camel_case_types)]

use std::ffi::{c_void, CString};
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

fn fail(message: &str) -> ! {
    eprintln!("FAIL: {message}");
    std::process::exit(1);
}

fn make_tree(value: &[u8]) -> [u32; 128] {
    let padded = (value.len() + 3) & !3;
    // Guarantee ADT alignment and pad beyond the pinned parser's inaccurate
    // DST metadata. This fixture does not validate the parser's bounds model.
    let mut backing = [0u32; 128];
    assert!(8 + 32 + 4 + padded + 256 <= std::mem::size_of_val(&backing));
    let tree = unsafe {
        std::slice::from_raw_parts_mut(
            backing.as_mut_ptr().cast::<u8>(), std::mem::size_of_val(&backing))
    };
    tree[0..4].copy_from_slice(&1u32.to_ne_bytes());
    tree[4..8].copy_from_slice(&0u32.to_ne_bytes());
    tree[8..13].copy_from_slice(b"probe");
    tree[40..44].copy_from_slice(&(value.len() as u32).to_ne_bytes());
    tree[44..44 + value.len()].copy_from_slice(value);
    backing
}

fn install(tree: &[u32]) {
    unsafe {
        ADT_SIZE = std::mem::size_of_val(tree) as u32;
        adt = tree.as_ptr() as *const c_void;
    }
}

fn copy_at(tree: &[u32], offset: i32, name: &str, out: *mut u8, len: usize) -> i32 {
    install(tree);
    let name = CString::new(name).unwrap();
    unsafe {
        source::adt_getprop_copy(
            ptr::null(),
            offset,
            name.as_ptr(),
            out as *mut c_void,
            len,
        )
    }
}

fn copy(tree: &[u32], name: &str, out: *mut u8, len: usize) -> i32 {
    copy_at(tree, 0, name, out, len)
}

fn assert_unchanged(label: &str, before: &[u8], after: &[u8]) {
    if before != after {
        fail(label);
    }
}

fn main() {
    let exact_tree = make_tree(&[1, 2, 3, 4]);
    let mut exact = [0xa5u8; 8];
    let result = copy(&exact_tree, "probe", exact.as_mut_ptr(), 4);
    if result != 4 || exact[..4] != [1, 2, 3, 4] || exact[4..] != [0xa5; 4] {
        fail("exact-length copy contract changed");
    }

    // Physical backing is larger than the requested buffer, so the original
    // writes forbidden bytes deterministically without overflowing allocation.
    let long_tree = make_tree(&[8, 9, 10, 11, 12]);
    let mut long = [0xa5u8; 8];
    let before = long;
    let result = copy(&long_tree, "probe", long.as_mut_ptr(), 4);
    if result != -20 {
        fail("long property did not return BadLength");
    }
    assert_unchanged("long mismatch modified destination", &before, &long);

    let short_tree = make_tree(&[5, 6, 7]);
    let mut short = [0xa5u8; 8];
    let before = short;
    let result = copy(&short_tree, "probe", short.as_mut_ptr(), 4);
    if result != -20 {
        fail("short property did not return BadLength");
    }
    assert_unchanged("short mismatch modified destination", &before, &short);

    let zero_tree = make_tree(&[]);
    let result = copy(&zero_tree, "probe", ptr::null_mut(), 0);
    if result != 0 {
        fail("zero-length property did not return success");
    }

    let mut zero = [0xa5u8; 4];
    if copy(&zero_tree, "probe", zero.as_mut_ptr(), 0) != 0 || zero != [0xa5; 4] {
        fail("zero-length copy modified destination");
    }
    if copy(&zero_tree, "probe", zero.as_mut_ptr(), 4) != -20 || zero != [0xa5; 4] {
        fail("empty property mismatch modified destination");
    }
    if copy(&exact_tree, "probe", zero.as_mut_ptr(), 0) != -20 || zero != [0xa5; 4] {
        fail("zero request mismatch modified destination");
    }
    if copy(&exact_tree, "probe", ptr::null_mut(), 0) != -20 {
        fail("nonempty property with zero request was accepted");
    }

    let mut missing = [0xa5u8; 4];
    let result = copy(&exact_tree, "missing", missing.as_mut_ptr(), 4);
    if result != -1 || missing != [0xa5; 4] {
        fail("missing property error changed");
    }
    println!("ADT copy ABI: exact/zero success, mismatch preservation, and errors passed");
}
