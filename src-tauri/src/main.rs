use chrono::Local;
use serde::{Deserialize, Serialize};
use std::{
    ffi::{c_char, c_void, CStr, CString},
    fs, io,
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
use tauri::{AppHandle, Manager};

extern "C" {
    fn sy_start(
        path: *const c_char,
        system: bool,
        mic: bool,
        error: *mut *mut c_char,
    ) -> *mut c_void;
    fn sy_snapshot(handle: *mut c_void) -> *mut c_char;
    fn sy_stop(
        handle: *mut c_void,
        path: *const c_char,
        error: *mut *mut c_char,
        warning: *mut *mut c_char,
    );
    fn sy_close(handle: *mut c_void);
    fn sy_export(
        directory: *const c_char,
        destination: *const c_char,
        error: *mut *mut c_char,
        warning: *mut *mut c_char,
    );
    fn sy_publish(source: *const c_char, destination: *const c_char) -> *mut c_char;
    fn sy_choose_directory(path: *const c_char) -> *mut c_char;
    fn sy_duration(path: *const c_char) -> f64;
    fn sy_free(value: *mut c_char);
}

struct NativeRecorder(NonNull<c_void>);

// Commands serialize ownership through the session mutex. The native recorder serializes route changes.
unsafe impl Send for NativeRecorder {}

impl NativeRecorder {
    fn close(self) {
        unsafe {
            sy_close(self.0.as_ptr());
        }
    }
}

struct Session {
    native: NativeRecorder,
    started: Instant,
    directory: PathBuf,
    name: String,
    system_audio: bool,
    microphone: bool,
}

#[derive(Default)]
struct Recorder {
    busy: AtomicBool,
    quitting: AtomicBool,
    exit_ready: AtomicBool,
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
    system_audio: Option<bool>,
    microphone: Option<bool>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Recording {
    name: String,
    duration: f64,
    bytes: u64,
}

#[derive(Deserialize, Serialize)]
struct Recovery {
    id: String,
    name: String,
    pid: u32,
    system_audio: bool,
    microphone: bool,
}

#[derive(Serialize)]
struct Library {
    directory: String,
    recordings: Vec<Recording>,
    pending: Vec<Recovery>,
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

fn default_library(app: &AppHandle) -> Result<PathBuf, String> {
    app.path()
        .home_dir()
        .map(|home| home.join("bicord"))
        .map_err(|error| error.to_string())
}

fn library_preference(app: &AppHandle) -> Result<PathBuf, String> {
    app.path()
        .app_config_dir()
        .map(|config| config.join("recording-directory"))
        .map_err(|error| error.to_string())
}

fn preferred_library(app: &AppHandle) -> Result<Option<PathBuf>, String> {
    match fs::read_to_string(library_preference(app)?) {
        Ok(value) if Path::new(&value).is_absolute() => Ok(Some(PathBuf::from(value))),
        Ok(_) => Err("保存目录设置无效，请重新选择目录。".into()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(format!("无法读取保存目录设置。{error}")),
    }
}

fn library(app: &AppHandle) -> Result<PathBuf, String> {
    if let Some(path) = preferred_library(app)? {
        if path.is_dir() {
            return Ok(path);
        }
        return Err(format!(
            "保存目录不可用，请重新选择目录。{}",
            path.display()
        ));
    }

    let path = default_library(app)?;
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&path)
        .map_err(|error| format!("无法创建录音目录。{error}"))?;
    Ok(path)
}

fn choose_library(app: &AppHandle) -> Result<bool, String> {
    let state = app.state::<Recorder>();
    if state.busy.load(Ordering::Acquire) {
        return Err("请先停止录音并等待文件保存。".into());
    }
    let initial = preferred_library(app)
        .ok()
        .flatten()
        .filter(|path| path.is_dir())
        .unwrap_or(default_library(app)?);
    let initial = c_path(&initial)?;
    let Some(selected) = take_string(unsafe { sy_choose_directory(initial.as_ptr()) }) else {
        return Ok(false);
    };
    let _session = state.session.lock().map_err(|error| error.to_string())?;
    if state.busy.load(Ordering::Acquire) {
        return Err("请先停止录音并等待文件保存。".into());
    }
    if !Path::new(&selected).is_dir() {
        return Err("所选保存目录不可用。".into());
    }

    let preference = library_preference(app)?;
    let temporary = preference.with_extension(std::process::id().to_string());
    fs::create_dir_all(preference.parent().ok_or("找不到设置目录。")?)
        .and_then(|_| fs::write(&temporary, selected))
        .and_then(|_| fs::rename(&temporary, &preference))
        .map_err(|error| format!("无法保存录音目录设置。{error}"))?;
    Ok(true)
}

fn start(app: &AppHandle, system_audio: bool, microphone: bool) -> Result<Status, String> {
    if !system_audio && !microphone {
        return Err("请至少开启一路音频。".into());
    }
    let state = app.state::<Recorder>();
    let mut session = state.session.lock().map_err(|error| error.to_string())?;
    if session.is_some()
        || state
            .busy
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
    {
        return Err("已有一场录音正在进行。".into());
    }

    let result = (|| {
        let now = Local::now();
        let name = format!("录音 {}.m4a", now.format("%Y-%m-%d %H.%M.%S%.3f"));
        let directory = library(app)?.join(format!(".bicord-recording-{}", now.format("%s%.9f")));
        let path = c_path(&directory)?;
        fs::DirBuilder::new()
            .mode(0o700)
            .create(&directory)
            .map_err(|error| format!("无法创建临时录音目录。{error}"))?;
        let recovery = Recovery {
            id: directory
                .file_name()
                .unwrap()
                .to_string_lossy()
                .into_owned(),
            name: name.clone(),
            pid: std::process::id(),
            system_audio,
            microphone,
        };
        fs::write(
            directory.join("session.json"),
            serde_json::to_vec(&recovery).map_err(|error| error.to_string())?,
        )
        .map_err(|error| error.to_string())?;
        let mut error = null_mut();
        let handle = unsafe { sy_start(path.as_ptr(), system_audio, microphone, &mut error) };
        let Some(handle) = NonNull::new(handle) else {
            // Preserve any audio captured before initialization failed.
            return Err(take_string(error).unwrap_or_else(|| "无法开始录音。".into()));
        };
        *session = Some(Session {
            native: NativeRecorder(handle),
            started: Instant::now(),
            directory,
            name,
            system_audio,
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
        system_audio: session.map(|session| session.system_audio),
        microphone: session.map(|session| session.microphone),
    })
}

fn publish_session(
    directory: &Path,
    name: &str,
    pending: &Path,
    notice: Option<String>,
) -> Result<Option<String>, String> {
    if recording_timestamp(name).is_none() {
        return Err("录音名称无效。".into());
    }
    let source = c_path(pending)?;
    let destination = c_path(&directory.with_file_name(name))?;
    if let Some(error) = take_string(unsafe { sy_publish(source.as_ptr(), destination.as_ptr()) }) {
        return Err(format!("无法保存 M4A。{error}"));
    }
    if notice.is_none() {
        let _ = fs::remove_dir_all(directory);
    } else {
        // Keep source audio when an incomplete export was reported.
        let _ = fs::write(directory.join("published"), name);
    }
    Ok(notice.map(|warning| {
        format!(
            "{warning}\n可用音频已导出，原始片段保留于：{}",
            directory.display()
        )
    }))
}

fn export_path(directory: &Path) -> PathBuf {
    directory.join(format!("export-{}.m4a", Local::now().format("%s%.9f")))
}

fn stop(app: &AppHandle) -> Result<Option<String>, String> {
    let state = app.state::<Recorder>();
    let session = state
        .session
        .lock()
        .map_err(|error| error.to_string())?
        .take()
        .ok_or("当前没有进行中的录音。")?;
    let result = (|| {
        let pending = export_path(&session.directory);
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
            let _ = fs::remove_file(&pending);
            return Err(error);
        }
        publish_session(&session.directory, &session.name, &pending, notice)
    })();
    state.busy.store(false, Ordering::Release);
    result.map_err(|error| {
        format!(
            "{error}\n原始片段已保留，可重试导出：{}",
            session.directory.display()
        )
    })
}

fn read_recovery(directory: &Path) -> Option<Recovery> {
    if !fs::symlink_metadata(directory).ok()?.is_dir() || directory.join("published").exists() {
        return None;
    }
    let recovery: Recovery =
        serde_json::from_slice(&fs::read(directory.join("session.json")).ok()?).ok()?;
    if !fs::read_dir(directory)
        .ok()?
        .flatten()
        .any(|entry| entry.file_name().to_string_lossy().ends_with(".caf.json"))
    {
        return None;
    }
    if directory.file_name()?.to_str()? != recovery.id
        || recording_timestamp(&recovery.name).is_none()
    {
        return None;
    }
    Some(recovery)
}

fn retry(app: &AppHandle, id: &str) -> Result<Option<String>, String> {
    if !id.starts_with(".bicord-recording-")
        || Path::new(id).file_name().and_then(|name| name.to_str()) != Some(id)
    {
        return Err("录音标识无效。".into());
    }
    let state = app.state::<Recorder>();
    if state
        .busy
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        return Err("请等待当前录音或导出完成。".into());
    }
    let result = (|| {
        let directory = library(app)?.join(id);
        let recovery = read_recovery(&directory).ok_or("找不到待恢复录音。")?;
        if recovery.pid == std::process::id() && !directory.join("capture.closed").exists() {
            return Err("音频设备仍在停止，请稍后重试，或退出并重新打开 Bicord。".into());
        }
        let pending = export_path(&directory);
        let mut error = null_mut();
        let mut warning = null_mut();
        unsafe {
            sy_export(
                c_path(&directory)?.as_ptr(),
                c_path(&pending)?.as_ptr(),
                &mut error,
                &mut warning,
            );
        }
        let notice = take_string(warning);
        if let Some(error) = take_string(error) {
            let _ = fs::remove_file(&pending);
            return Err(format!("{error} 原始片段仍保留。"));
        }
        publish_session(&directory, &recovery.name, &pending, notice)
    })();
    state.busy.store(false, Ordering::Release);
    result
}

fn recording_timestamp(name: &str) -> Option<&str> {
    if Path::new(name).file_name().and_then(|part| part.to_str()) != Some(name) {
        return None;
    }
    name.strip_prefix("录音 ")
        .or_else(|| name.strip_prefix("会议录音 "))?
        .strip_suffix(".m4a")
}

fn list(app: &AppHandle) -> Result<Library, String> {
    let path = library(app)?;
    let mut recordings = Vec::new();
    let mut pending = Vec::new();
    let state = app.state::<Recorder>();
    let active_directory = state
        .session
        .lock()
        .map_err(|error| error.to_string())?
        .as_ref()
        .map(|session| session.directory.clone());
    for entry in fs::read_dir(&path).map_err(|error| error.to_string())? {
        let entry = entry.map_err(|error| error.to_string())?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with(".bicord-recording-")
            && active_directory.as_ref() != Some(&entry.path())
        {
            if let Some(recovery) = read_recovery(&entry.path()) {
                pending.push(recovery);
            }
        }
        if recording_timestamp(&name).is_none()
            || !entry.file_type().is_ok_and(|kind| kind.is_file())
        {
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
    recordings
        .sort_unstable_by(|a, b| recording_timestamp(&b.name).cmp(&recording_timestamp(&a.name)));
    let directory = app
        .path()
        .home_dir()
        .ok()
        .and_then(|home| path.strip_prefix(home).ok())
        .map(|relative| Path::new("~").join(relative))
        .unwrap_or(path);
    Ok(Library {
        directory: directory.display().to_string(),
        recordings,
        pending,
    })
}

async fn background<T: Send + 'static>(
    work: impl FnOnce() -> Result<T, String> + Send + 'static,
) -> Result<T, String> {
    tauri::async_runtime::spawn_blocking(work)
        .await
        .map_err(|error| error.to_string())?
}

#[tauri::command]
async fn recording_start(
    app: AppHandle,
    system_audio: bool,
    microphone: bool,
) -> Result<Status, String> {
    background(move || start(&app, system_audio, microphone)).await
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
async fn recording_retry(app: AppHandle, id: String) -> Result<Option<String>, String> {
    background(move || retry(&app, &id)).await
}

#[tauri::command]
async fn recording_list(app: AppHandle) -> Result<Library, String> {
    background(move || list(&app)).await
}

#[tauri::command]
async fn recording_choose_directory(app: AppHandle) -> Result<bool, String> {
    background(move || choose_library(&app)).await
}

#[tauri::command]
async fn recording_open(app: AppHandle, name: Option<String>, reveal: bool) -> Result<(), String> {
    background(move || {
        let mut path = library(&app)?;
        let mut open = Command::new("/usr/bin/open");
        if let Some(name) = name {
            if recording_timestamp(&name).is_none() {
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
    let state = app.state::<Recorder>();
    if state.exit_ready.load(Ordering::Acquire) {
        return true;
    }
    if state.quitting.swap(true, Ordering::AcqRel) {
        return false;
    }
    let app = app.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<Recorder>();
        let deadline = Instant::now() + std::time::Duration::from_secs(1);
        let session = loop {
            match state.session.try_lock() {
                Ok(mut guard) => break guard.take(),
                Err(std::sync::TryLockError::WouldBlock) if Instant::now() < deadline => {
                    std::thread::sleep(std::time::Duration::from_millis(10));
                }
                _ => break None,
            }
        };
        if let Some(session) = session {
            session.native.close();
        }
        state.exit_ready.store(true, Ordering::Release);
        app.exit(0);
    });
    false
}

fn main() {
    tauri::Builder::default()
        .manage(Recorder::default())
        .invoke_handler(tauri::generate_handler![
            recording_start,
            recording_status,
            recording_stop,
            recording_retry,
            recording_list,
            recording_choose_directory,
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
        .expect("无法启动 Bicord")
        .run(|app, event| {
            if let tauri::RunEvent::ExitRequested { api, .. } = event {
                if !can_exit(app) {
                    api.prevent_exit();
                }
            }
        });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recovery_and_publish_preserve_sources_on_failure() {
        let root = std::env::temp_dir().join(format!(
            "bicord-rust-test-{}-{}",
            std::process::id(),
            Local::now().timestamp_nanos_opt().unwrap()
        ));
        fs::create_dir(&root).unwrap();
        let directory = root.join(".bicord-recording-test");
        fs::create_dir(&directory).unwrap();
        let name = "录音 2026-11-23 12.00.00.000.m4a";
        let recovery = Recovery {
            id: ".bicord-recording-test".into(),
            name: name.into(),
            pid: 0,
            system_audio: true,
            microphone: true,
        };
        fs::write(
            directory.join("session.json"),
            serde_json::to_vec(&recovery).unwrap(),
        )
        .unwrap();
        fs::write(directory.join("system-a.caf"), b"source").unwrap();
        fs::write(directory.join("system-a.caf.json"), b"{}").unwrap();
        assert_eq!(read_recovery(&directory).unwrap().name, name);
        let pending = directory.join("export.m4a");
        fs::write(&pending, b"encoded").unwrap();
        fs::write(root.join(name), b"existing").unwrap();
        assert!(publish_session(&directory, name, &pending, None).is_err());
        assert_eq!(fs::read(root.join(name)).unwrap(), b"existing");
        assert!(pending.exists() && directory.join("system-a.caf").exists());
        fs::remove_file(root.join(name)).unwrap();
        assert!(
            publish_session(&directory, name, &pending, Some("partial".into()))
                .unwrap()
                .is_some()
        );
        assert!(directory.join("system-a.caf").exists());
        assert!(read_recovery(&directory).is_none());
        assert!(recording_timestamp("../录音 bad.m4a").is_none());
        assert!(recording_timestamp("会议录音 old.m4a").is_some());
        fs::remove_dir_all(root).unwrap();
    }
}
