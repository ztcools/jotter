// Suppress the console window that Windows would otherwise attach in release.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    jotter_lib::run()
}
