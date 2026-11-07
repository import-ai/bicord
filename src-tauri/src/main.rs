use chrono::Local;
use serde::{Deserialize, Serialize};
use std::{
    ffi::{c_char, c_void, CStr, CString},
    fs,
    os::unix::{ffi::OsStrExt, fs::DirBuilderExt},
    path::{Path, PathBuf},
    process::Command,
    ptr::{null_mut, NonNull},
    sync::{
        atomic::{AtomicBool, Ordering},
        Mutex,
    },
    time::Instant,
};
use tauri::{AppHandle, Emitter, Manager};

extern "C" {
    fn sy_start(path: *const c_char, mic: bool, error: *mut *mut c_char) -> *mut c_void;
    fn sy_snapshot(handle: *mut c_void) -> *mut c_char;
    fn sy_stop(
        handle: *mut c_void,
        path: *const c_char,
        error: *mut *mut c_char,
        warning: *mut *mut c_char,
    );
    fn sy_duration(path: *const c_char) -> f64;
    fn sy_free(value: *mut c_char);
}

struct NativeRecorder(NonNull<c_void>);

// Commands serialize ownership through the session mutex. The native recorder serializes route changes.
unsafe impl Send for NativeRecorder {}

struct Session {
    native: NativeRecorder,
    started: Instant,
    directory: PathBuf,
    name: String,
    microphone: bool,
}

#[derive(Default)]
struct Recorder {
    busy: AtomicBool,
    session: Mutex<Option<Session>>,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct AudioStatus {
    system_level: f32,
    mic_level: f32,
    output_name: String,
    input_name: String,
    warning: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Status {
    #[serde(flatten)]
    audio: AudioStatus,
    elapsed: Option<f64>,
    microphone: Option<bool>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Recording {
    name: String,
    duration: f64,
    bytes: u64,
}

fn c_path(path: &Path) -> Result<CString, String> {
    CString::new(path.as_os_str().as_bytes()).map_err(|_| "录音路径无效。".into())
}

fn take_string(value: *mut c_char) -> Option<String> {
    if value.is_null() {
        return None;
    }
    // The native bridge returns a malloc-owned NUL-terminated string.
    let result = unsafe { CStr::from_ptr(value) }
        .to_string_lossy()
        .into_owned();
    unsafe { sy_free(value) };
    Some(result)
}

fn library(app: &AppHandle) -> Result<PathBuf, String> {
    let path = app
        .path()
        .home_dir()
        .map_err(|error| error.to_string())?
        .join("bicord");
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&path)
        .map_err(|error| format!("无法创建录音目录。{error}"))?;
    Ok(path)
}

fn start(app: &AppHandle, microphone: bool) -> Result<Status, String> {
    let state = app.state::<Recorder>();
    let mut session = state.session.lock().map_err(|error| error.to_string())?;
    if session.is_some() {
        return Err("已有一场录音正在进行。".into());
    }
    state.busy.store(true, Ordering::Release);

    let result = (|| {
        let now = Local::now();
        let name = format!("会议录音 {}.m4a", now.format("%Y-%m-%d %H.%M.%S%.3f"));
        let directory = library(app)?.join(format!(".bicord-recording-{}", now.format("%s%.9f")));
        let path = c_path(&directory)?;
        fs::DirBuilder::new()
            .mode(0o700)
            .create(&directory)
            .map_err(|error| format!("无法创建临时录音目录。{error}"))?;
        let mut error = null_mut();
        let handle = unsafe { sy_start(path.as_ptr(), microphone, &mut error) };
        let Some(handle) = NonNull::new(handle) else {
            let _ = fs::remove_dir_all(&directory);
            return Err(take_string(error).unwrap_or_else(|| "无法开始录音。".into()));
        };
        *session = Some(Session {
            native: NativeRecorder(handle),
            started: Instant::now(),
            directory,
            name,
            microphone,
        });
        Ok(())
    })();
    if result.is_err() {
        state.busy.store(false, Ordering::Release);
    }
    result?;
    snapshot(session.as_ref())
}

fn snapshot(session: Option<&Session>) -> Result<Status, String> {
    let handle = session.map_or(null_mut(), |session| session.native.0.as_ptr());
    let json = take_string(unsafe { sy_snapshot(handle) }).ok_or("无法读取音频状态。")?;
    Ok(Status {
        audio: serde_json::from_str(&json).map_err(|error| error.to_string())?,
        elapsed: session.map(|session| session.started.elapsed().as_secs_f64()),
        microphone: session.map(|session| session.microphone),
    })
}

fn stop(app: &AppHandle) -> Result<Option<String>, String> {
    let state = app.state::<Recorder>();
    let mut guard = state.session.lock().map_err(|error| error.to_string())?;
    let session = guard.take().ok_or("当前没有进行中的录音。")?;
    let result = (|| {
        let pending = session.directory.join("导出.m4a");
        let path = c_path(&pending)?;
        let mut error = null_mut();
        let mut warning = null_mut();
        unsafe {
            sy_stop(
                session.native.0.as_ptr(),
                path.as_ptr(),
                &mut error,
                &mut warning,
            )
        };
        let notice = take_string(warning);
        if let Some(error) = take_string(error) {
            return Err(error);
        }

        let destination = session.directory.with_file_name(&session.name);
        fs::hard_link(&pending, destination).map_err(|error| format!("无法保存 M4A。{error}"))?;
        let _ = fs::remove_dir_all(&session.directory);
        Ok(notice)
    })();
    state.busy.store(false, Ordering::Release);
    result.map_err(|error| format!("{error}\n原始片段目录：{}", session.directory.display()))
}

fn recording_name(name: &str) -> bool {
    name.starts_with("会议录音 ")
        && name.ends_with(".m4a")
        && Path::new(name).file_name().and_then(|part| part.to_str()) == Some(name)
}

fn list(app: &AppHandle) -> Result<Vec<Recording>, String> {
    let mut recordings = Vec::new();
    for entry in fs::read_dir(library(app)?).map_err(|error| error.to_string())? {
        let entry = entry.map_err(|error| error.to_string())?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if !recording_name(&name) || !entry.file_type().is_ok_and(|kind| kind.is_file()) {
            continue;
        }
        let Ok(metadata) = entry.metadata() else {
            continue;
        };
        let duration = unsafe { sy_duration(c_path(&entry.path())?.as_ptr()) };
        recordings.push(Recording {
            name,
            duration,
            bytes: metadata.len(),
        });
    }
    recordings.sort_unstable_by(|a, b| b.name.cmp(&a.name));
    Ok(recordings)
}

async fn background<T: Send + 'static>(
    work: impl FnOnce() -> Result<T, String> + Send + 'static,
) -> Result<T, String> {
    tauri::async_runtime::spawn_blocking(work)
        .await
        .map_err(|error| error.to_string())?
}

#[tauri::command]
async fn recording_start(app: AppHandle, microphone: bool) -> Result<Status, String> {
    background(move || start(&app, microphone)).await
}

#[tauri::command]
async fn recording_status(app: AppHandle) -> Result<Status, String> {
    background(move || {
        let state = app.state::<Recorder>();
        let session = state.session.lock().map_err(|error| error.to_string())?;
        snapshot(session.as_ref())
    })
    .await
}

#[tauri::command]
async fn recording_stop(app: AppHandle) -> Result<Option<String>, String> {
    background(move || stop(&app)).await
}

#[tauri::command]
async fn recording_list(app: AppHandle) -> Result<Vec<Recording>, String> {
    background(move || list(&app)).await
}

#[tauri::command]
async fn recording_open(app: AppHandle, name: Option<String>, reveal: bool) -> Result<(), String> {
    background(move || {
        let mut path = library(&app)?;
        let mut open = Command::new("/usr/bin/open");
        if let Some(name) = name {
            if !recording_name(&name) {
                return Err("录音名称无效。".into());
            }
            path.push(name);
            if !fs::symlink_metadata(&path).is_ok_and(|entry| entry.is_file()) {
                return Err("找不到这份录音，请刷新列表。".into());
            }
            if reveal {
                open.arg("-R");
            }
        }
        let status = open.arg(path).status().map_err(|error| error.to_string())?;
        if status.success() {
            Ok(())
        } else {
            Err("无法打开录音。".into())
        }
    })
    .await
}

fn can_exit(app: &AppHandle) -> bool {
    if app.state::<Recorder>().busy.load(Ordering::Acquire) {
        let _ = app.emit("recording-close-blocked", ());
        return false;
    }
    true
}

fn main() {
    tauri::Builder::default()
        .manage(Recorder::default())
        .invoke_handler(tauri::generate_handler![
            recording_start,
            recording_status,
            recording_stop,
            recording_list,
            recording_open
        ])
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                if !can_exit(window.app_handle()) {
                    api.prevent_close();
                }
            }
        })
        .build(tauri::generate_context!())
        .expect("无法启动bicord")
        .run(|app, event| {
            if let tauri::RunEvent::ExitRequested { api, .. } = event {
                if !can_exit(app) {
                    api.prevent_exit();
                }
            }
        });
}
