fn main() {
    println!("cargo:rerun-if-changed=native/recorder.m");
    println!("cargo:rerun-if-changed=native/diagnostics.m");
    println!("cargo:rerun-if-changed=native/diagnostics.h");
    cc::Build::new()
        .files(["native/recorder.m", "native/diagnostics.m"])
        .flags(["-fobjc-arc", "-fblocks", "-mmacosx-version-min=14.2"])
        .compile("bicord_recorder");
    for framework in [
        "AppKit",
        "Foundation",
        "AVFoundation",
        "AudioToolbox",
        "CoreAudio",
        "CoreMedia",
    ] {
        println!("cargo:rustc-link-lib=framework={framework}");
    }
    tauri_build::build();
}
