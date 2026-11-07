fn main() {
    println!("cargo:rerun-if-changed=native/recorder.m");
    cc::Build::new()
        .file("native/recorder.m")
        .flags(["-fobjc-arc", "-fblocks", "-mmacosx-version-min=14.2"])
        .compile("bicord_recorder");
    for framework in [
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
