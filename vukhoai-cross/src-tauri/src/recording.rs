use std::fs::{self, File};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::thread::{self, JoinHandle};

use chrono::{DateTime, Utc};
use serde::Serialize;
use uuid::Uuid;

const RECORDING_SAMPLE_RATE: usize = 48_000;
const RECORDING_CHANNELS: usize = 2;
const RECORDING_BYTES_PER_SAMPLE: usize = 4;
const RECORDING_BYTES_PER_FRAME: usize = RECORDING_CHANNELS * RECORDING_BYTES_PER_SAMPLE;

#[derive(Debug, Clone, Serialize)]
pub struct RecordingSnapshot {
    pub active: bool,
    pub id: Option<String>,
    pub title: Option<String>,
    pub started_at: Option<DateTime<Utc>>,
    pub elapsed_seconds: Option<f64>,
    pub system_device: Option<String>,
    pub microphone_device: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct RecordingDevice {
    pub id: String,
    pub name: String,
    pub is_default: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct RecordingDevices {
    pub system_devices: Vec<RecordingDevice>,
    pub microphone_devices: Vec<RecordingDevice>,
}

#[derive(Debug, Clone)]
pub struct FinishedRecording {
    pub path: PathBuf,
    pub duration_seconds: Option<f64>,
}

#[derive(Debug)]
struct CaptureSummary {
    bytes_written: u64,
}

struct ActiveRecording {
    id: String,
    title: String,
    started_at: DateTime<Utc>,
    system_device: String,
    microphone_device: String,
    temp_dir: PathBuf,
    system_raw_path: PathBuf,
    microphone_raw_path: PathBuf,
    output_path: PathBuf,
    stop_flag: Arc<AtomicBool>,
    system_handle: JoinHandle<Result<CaptureSummary, String>>,
    microphone_handle: JoinHandle<Result<CaptureSummary, String>>,
}

pub struct RecordingManager {
    active: Mutex<Option<ActiveRecording>>,
}

impl RecordingManager {
    pub fn new() -> Self {
        Self {
            active: Mutex::new(None),
        }
    }

    pub fn snapshot(&self) -> RecordingSnapshot {
        let Ok(guard) = self.active.lock() else {
            return inactive_snapshot();
        };
        let Some(active) = guard.as_ref() else {
            return inactive_snapshot();
        };

        RecordingSnapshot {
            active: true,
            id: Some(active.id.clone()),
            title: Some(active.title.clone()),
            started_at: Some(active.started_at),
            elapsed_seconds: Some(elapsed_seconds(active.started_at)),
            system_device: Some(active.system_device.clone()),
            microphone_device: Some(active.microphone_device.clone()),
        }
    }

    pub fn start(
        &self,
        title: &str,
        recordings_dir: &Path,
        temp_root: &Path,
        system_device_id: Option<String>,
        microphone_device_id: Option<String>,
    ) -> Result<RecordingSnapshot, String> {
        let mut guard = self
            .active
            .lock()
            .map_err(|_| "Failed to lock recording state.".to_string())?;
        if guard.is_some() {
            return Err("A recording is already in progress.".to_string());
        }

        let title = sanitize_recording_title(title);
        fs::create_dir_all(recordings_dir)
            .map_err(|e| format!("Unable to create recordings folder: {e}"))?;
        fs::create_dir_all(temp_root)
            .map_err(|e| format!("Unable to create recording temp folder: {e}"))?;

        let system_device_id = normalize_device_id(system_device_id);
        let microphone_device_id = normalize_device_id(microphone_device_id);
        let (system_device, microphone_device) =
            selected_device_names(system_device_id.clone(), microphone_device_id.clone())?;
        let id = Uuid::new_v4().to_string();
        let started_at = Utc::now();
        let temp_dir = temp_root.join(&id);
        fs::create_dir_all(&temp_dir)
            .map_err(|e| format!("Unable to create recording workspace: {e}"))?;

        let system_raw_path = temp_dir.join("system.f32le");
        let microphone_raw_path = temp_dir.join("microphone.f32le");
        let output_path = unique_recording_path(recordings_dir, &title, started_at);
        let stop_flag = Arc::new(AtomicBool::new(false));
        let (startup_tx, startup_rx) = mpsc::channel::<Result<(), String>>();

        let system_handle = spawn_capture_thread(
            CaptureKind::SystemLoopback {
                device_id: system_device_id,
            },
            system_raw_path.clone(),
            stop_flag.clone(),
            startup_tx.clone(),
        );
        let microphone_handle = spawn_capture_thread(
            CaptureKind::Microphone {
                device_id: microphone_device_id,
            },
            microphone_raw_path.clone(),
            stop_flag.clone(),
            startup_tx,
        );

        for _ in 0..2 {
            match startup_rx.recv_timeout(std::time::Duration::from_secs(5)) {
                Ok(Ok(())) => {}
                Ok(Err(error)) => {
                    stop_flag.store(true, Ordering::SeqCst);
                    let _ = system_handle.join();
                    let _ = microphone_handle.join();
                    let _ = fs::remove_dir_all(&temp_dir);
                    return Err(error);
                }
                Err(_) => {
                    stop_flag.store(true, Ordering::SeqCst);
                    let _ = system_handle.join();
                    let _ = microphone_handle.join();
                    let _ = fs::remove_dir_all(&temp_dir);
                    return Err("Timed out while starting audio capture.".to_string());
                }
            }
        }

        *guard = Some(ActiveRecording {
            id,
            title,
            started_at,
            system_device,
            microphone_device,
            temp_dir,
            system_raw_path,
            microphone_raw_path,
            output_path,
            stop_flag,
            system_handle,
            microphone_handle,
        });

        Ok(guard
            .as_ref()
            .map(active_to_snapshot)
            .unwrap_or_else(inactive_snapshot))
    }

    pub fn stop(&self, ffmpeg_binary: &str) -> Result<FinishedRecording, String> {
        let active = {
            let mut guard = self
                .active
                .lock()
                .map_err(|_| "Failed to lock recording state.".to_string())?;
            guard
                .take()
                .ok_or_else(|| "No recording is currently active.".to_string())?
        };

        active.stop_flag.store(true, Ordering::SeqCst);
        let system = join_capture("System audio", active.system_handle)?;
        let microphone = join_capture("Microphone", active.microphone_handle)?;

        let duration_seconds = encode_recording_to_m4a(
            ffmpeg_binary,
            &active.system_raw_path,
            system.bytes_written,
            &active.microphone_raw_path,
            microphone.bytes_written,
            &active.output_path,
            &active.title,
        )?;

        let _ = fs::remove_dir_all(&active.temp_dir);

        Ok(FinishedRecording {
            path: active.output_path,
            duration_seconds,
        })
    }

    pub fn cancel(&self) -> Result<(), String> {
        let active = {
            let mut guard = self
                .active
                .lock()
                .map_err(|_| "Failed to lock recording state.".to_string())?;
            guard
                .take()
                .ok_or_else(|| "No recording is currently active.".to_string())?
        };

        active.stop_flag.store(true, Ordering::SeqCst);
        let _ = active.system_handle.join();
        let _ = active.microphone_handle.join();
        let _ = fs::remove_file(&active.output_path);
        let _ = fs::remove_dir_all(&active.temp_dir);
        Ok(())
    }
}

#[derive(Debug, Clone)]
enum CaptureKind {
    SystemLoopback { device_id: Option<String> },
    Microphone { device_id: Option<String> },
}

fn inactive_snapshot() -> RecordingSnapshot {
    RecordingSnapshot {
        active: false,
        id: None,
        title: None,
        started_at: None,
        elapsed_seconds: None,
        system_device: None,
        microphone_device: None,
    }
}

fn active_to_snapshot(active: &ActiveRecording) -> RecordingSnapshot {
    RecordingSnapshot {
        active: true,
        id: Some(active.id.clone()),
        title: Some(active.title.clone()),
        started_at: Some(active.started_at),
        elapsed_seconds: Some(elapsed_seconds(active.started_at)),
        system_device: Some(active.system_device.clone()),
        microphone_device: Some(active.microphone_device.clone()),
    }
}

fn elapsed_seconds(started_at: DateTime<Utc>) -> f64 {
    (Utc::now() - started_at).num_milliseconds().max(0) as f64 / 1000.0
}

fn sanitize_recording_title(title: &str) -> String {
    let cleaned = title
        .trim()
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' || ch == ' ' {
                ch
            } else {
                '-'
            }
        })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");

    if cleaned.is_empty() {
        "Recording".to_string()
    } else {
        cleaned.chars().take(80).collect()
    }
}

fn unique_recording_path(recordings_dir: &Path, title: &str, started_at: DateTime<Utc>) -> PathBuf {
    let timestamp = started_at.format("%Y%m%d-%H%M%S").to_string();
    let stem = format!("{}-{}", title.replace(' ', "-"), timestamp);
    let mut candidate = recordings_dir.join(format!("{stem}.m4a"));
    let mut index = 2;
    while candidate.exists() {
        candidate = recordings_dir.join(format!("{stem}-{index}.m4a"));
        index += 1;
    }
    candidate
}

fn join_capture(
    label: &str,
    handle: JoinHandle<Result<CaptureSummary, String>>,
) -> Result<CaptureSummary, String> {
    handle
        .join()
        .map_err(|_| format!("{label} capture thread crashed."))?
        .map_err(|error| format!("{label} capture failed: {error}"))
}

fn frames_from_bytes(bytes: u64) -> u64 {
    bytes / RECORDING_BYTES_PER_FRAME as u64
}

fn duration_from_bytes(bytes: u64) -> Option<f64> {
    let frames = frames_from_bytes(bytes);
    if frames == 0 {
        None
    } else {
        Some(frames as f64 / RECORDING_SAMPLE_RATE as f64)
    }
}

fn encode_recording_to_m4a(
    ffmpeg_binary: &str,
    system_raw_path: &Path,
    system_bytes: u64,
    microphone_raw_path: &Path,
    microphone_bytes: u64,
    output_path: &Path,
    title: &str,
) -> Result<Option<f64>, String> {
    if system_bytes == 0 && microphone_bytes == 0 {
        return Err("No audio samples were captured.".to_string());
    }

    let mut command = Command::new(ffmpeg_binary);
    command
        .arg("-y")
        .arg("-hide_banner")
        .arg("-loglevel")
        .arg("error");

    let mut input_count = 0;
    if system_bytes > 0 {
        add_raw_input(&mut command, system_raw_path);
        input_count += 1;
    }
    if microphone_bytes > 0 {
        add_raw_input(&mut command, microphone_raw_path);
        input_count += 1;
    }

    if input_count == 2 {
        command
            .arg("-filter_complex")
            .arg("[0:a][1:a]amix=inputs=2:duration=longest:dropout_transition=0,volume=2[a]")
            .arg("-map")
            .arg("[a]");
    }

    command
        .arg("-c:a")
        .arg("aac")
        .arg("-b:a")
        .arg("192k")
        .arg("-movflags")
        .arg("+faststart")
        .arg("-metadata")
        .arg(format!("title={title}"))
        .arg(output_path);

    let output = command
        .output()
        .map_err(|e| format!("Unable to start ffmpeg for recording finalization: {e}"))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Err(if stderr.is_empty() {
            "ffmpeg failed to finalize the recording.".to_string()
        } else {
            format!("ffmpeg failed to finalize the recording: {stderr}")
        });
    }

    Ok(duration_from_bytes(system_bytes.max(microphone_bytes)))
}

fn add_raw_input(command: &mut Command, path: &Path) {
    command
        .arg("-f")
        .arg("f32le")
        .arg("-ar")
        .arg(RECORDING_SAMPLE_RATE.to_string())
        .arg("-ac")
        .arg(RECORDING_CHANNELS.to_string())
        .arg("-i")
        .arg(path);
}

fn normalize_device_id(device_id: Option<String>) -> Option<String> {
    device_id
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

#[cfg(windows)]
pub fn list_devices() -> Result<RecordingDevices, String> {
    run_wasapi_on_thread("vukhoai-audio-device-list", list_devices_inner)
}

#[cfg(not(windows))]
pub fn list_devices() -> Result<RecordingDevices, String> {
    Err("Recording is currently implemented for Windows only.".to_string())
}

#[cfg(windows)]
fn selected_device_names(
    system_device_id: Option<String>,
    microphone_device_id: Option<String>,
) -> Result<(String, String), String> {
    run_wasapi_on_thread("vukhoai-audio-device-probe", move || {
        selected_device_names_inner(system_device_id.as_deref(), microphone_device_id.as_deref())
    })
}

#[cfg(not(windows))]
fn selected_device_names(
    _system_device_id: Option<String>,
    _microphone_device_id: Option<String>,
) -> Result<(String, String), String> {
    Err("Recording is currently implemented for Windows only.".to_string())
}

#[cfg(windows)]
fn run_wasapi_on_thread<T, F>(thread_name: &'static str, callback: F) -> Result<T, String>
where
    T: Send + 'static,
    F: FnOnce() -> Result<T, String> + Send + 'static,
{
    thread::Builder::new()
        .name(thread_name.to_string())
        .spawn(move || {
            wasapi::initialize_mta()
                .ok()
                .map_err(|e| format!("Unable to initialize Windows audio services: {e}"))?;
            let result = callback();
            wasapi::deinitialize();
            result
        })
        .map_err(|e| format!("Unable to start Windows audio worker: {e}"))?
        .join()
        .map_err(|_| "Windows audio worker crashed.".to_string())?
}

#[cfg(windows)]
fn list_devices_inner() -> Result<RecordingDevices, String> {
    use wasapi::{DeviceEnumerator, Direction};

    let enumerator =
        DeviceEnumerator::new().map_err(|e| format!("Unable to enumerate audio devices: {e}"))?;
    Ok(RecordingDevices {
        system_devices: collect_devices(&enumerator, Direction::Render, "system audio output")?,
        microphone_devices: collect_devices(&enumerator, Direction::Capture, "microphone")?,
    })
}

#[cfg(windows)]
fn selected_device_names_inner(
    system_device_id: Option<&str>,
    microphone_device_id: Option<&str>,
) -> Result<(String, String), String> {
    use wasapi::{DeviceEnumerator, Direction};

    let enumerator =
        DeviceEnumerator::new().map_err(|e| format!("Unable to enumerate audio devices: {e}"))?;
    let system_device = resolve_device(
        &enumerator,
        Direction::Render,
        system_device_id,
        "system audio output",
    )?
    .get_friendlyname()
    .map_err(|e| format!("Unable to read system audio device name: {e}"))?;
    let microphone_device = resolve_device(
        &enumerator,
        Direction::Capture,
        microphone_device_id,
        "microphone",
    )?
    .get_friendlyname()
    .map_err(|e| format!("Unable to read microphone name: {e}"))?;

    Ok((system_device, microphone_device))
}

#[cfg(windows)]
fn collect_devices(
    enumerator: &wasapi::DeviceEnumerator,
    direction: wasapi::Direction,
    label: &str,
) -> Result<Vec<RecordingDevice>, String> {
    let default_device_id = enumerator
        .get_default_device(&direction)
        .and_then(|device| device.get_id())
        .ok();
    let collection = enumerator
        .get_device_collection(&direction)
        .map_err(|e| format!("Unable to enumerate {label} devices: {e}"))?;
    let count = collection
        .get_nbr_devices()
        .map_err(|e| format!("Unable to count {label} devices: {e}"))?;
    let mut devices = Vec::with_capacity(count as usize);

    for index in 0..count {
        let device = collection
            .get_device_at_index(index)
            .map_err(|e| format!("Unable to read {label} device: {e}"))?;
        let id = device
            .get_id()
            .map_err(|e| format!("Unable to read {label} device id: {e}"))?;
        let name = device
            .get_friendlyname()
            .map_err(|e| format!("Unable to read {label} device name: {e}"))?;
        devices.push(RecordingDevice {
            is_default: default_device_id.as_deref() == Some(id.as_str()),
            id,
            name,
        });
    }

    devices.sort_by(|a, b| {
        b.is_default
            .cmp(&a.is_default)
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });
    Ok(devices)
}

#[cfg(windows)]
fn resolve_device(
    enumerator: &wasapi::DeviceEnumerator,
    direction: wasapi::Direction,
    device_id: Option<&str>,
    label: &str,
) -> Result<wasapi::Device, String> {
    if let Some(device_id) = device_id {
        let device = enumerator
            .get_device(device_id)
            .map_err(|e| format!("Unable to open selected {label}: {e}"))?;
        if device.get_direction() != direction {
            return Err(format!(
                "The selected {label} is no longer available as a {label} device."
            ));
        }
        return Ok(device);
    }

    enumerator
        .get_default_device(&direction)
        .map_err(|e| format!("Unable to open default {label}: {e}"))
}

fn spawn_capture_thread(
    kind: CaptureKind,
    raw_path: PathBuf,
    stop_flag: Arc<AtomicBool>,
    startup_tx: mpsc::Sender<Result<(), String>>,
) -> JoinHandle<Result<CaptureSummary, String>> {
    thread::spawn(move || capture_raw(kind, raw_path, stop_flag, startup_tx))
}

#[cfg(not(windows))]
fn capture_raw(
    _kind: CaptureKind,
    _raw_path: PathBuf,
    _stop_flag: Arc<AtomicBool>,
    startup_tx: mpsc::Sender<Result<(), String>>,
) -> Result<CaptureSummary, String> {
    let message = "Recording is currently implemented for Windows only.".to_string();
    let _ = startup_tx.send(Err(message.clone()));
    Err(message)
}

#[cfg(windows)]
fn capture_raw(
    kind: CaptureKind,
    raw_path: PathBuf,
    stop_flag: Arc<AtomicBool>,
    startup_tx: mpsc::Sender<Result<(), String>>,
) -> Result<CaptureSummary, String> {
    use std::collections::VecDeque;

    use wasapi::{DeviceEnumerator, Direction, SampleType, StreamMode, WaveFormat};

    wasapi::initialize_mta()
        .ok()
        .map_err(|e| format!("Unable to initialize Windows audio capture: {e}"))?;

    let result = (|| -> Result<CaptureSummary, String> {
        let enumerator = DeviceEnumerator::new()
            .map_err(|e| format!("Unable to enumerate audio devices: {e}"))?;
        let (device_direction, device_id, device_label) = match &kind {
            CaptureKind::SystemLoopback { device_id } => (
                Direction::Render,
                device_id.as_deref(),
                "system audio output",
            ),
            CaptureKind::Microphone { device_id } => {
                (Direction::Capture, device_id.as_deref(), "microphone")
            }
        };
        let device = resolve_device(&enumerator, device_direction, device_id, device_label)?;
        let mut audio_client = device
            .get_iaudioclient()
            .map_err(|e| format!("Unable to create audio client: {e}"))?;
        let desired_format = WaveFormat::new(
            32,
            32,
            &SampleType::Float,
            RECORDING_SAMPLE_RATE,
            RECORDING_CHANNELS,
            None,
        );
        let (_, min_time) = audio_client
            .get_device_period()
            .map_err(|e| format!("Unable to read audio device period: {e}"))?;
        let mode = StreamMode::EventsShared {
            autoconvert: true,
            buffer_duration_hns: min_time,
        };
        audio_client
            .initialize_client(&desired_format, &Direction::Capture, &mode)
            .map_err(|e| format!("Unable to initialize audio capture stream: {e}"))?;
        let event = audio_client
            .set_get_eventhandle()
            .map_err(|e| format!("Unable to create audio capture event: {e}"))?;
        let capture_client = audio_client
            .get_audiocaptureclient()
            .map_err(|e| format!("Unable to create audio capture client: {e}"))?;

        let mut output = File::create(&raw_path)
            .map_err(|e| format!("Unable to create recording buffer: {e}"))?;
        let mut sample_queue: VecDeque<u8> =
            VecDeque::with_capacity(RECORDING_BYTES_PER_FRAME * 48_000);
        let mut bytes_written = 0u64;

        audio_client
            .start_stream()
            .map_err(|e| format!("Unable to start audio capture stream: {e}"))?;
        let _ = startup_tx.send(Ok(()));

        while !stop_flag.load(Ordering::SeqCst) {
            if event.wait_for_event(200).is_ok() {
                capture_client
                    .read_from_device_to_deque(&mut sample_queue)
                    .map_err(|e| format!("Unable to read audio samples: {e}"))?;
                flush_sample_queue(&mut sample_queue, &mut output, &mut bytes_written)?;
            }
        }

        capture_client
            .read_from_device_to_deque(&mut sample_queue)
            .ok();
        flush_sample_queue(&mut sample_queue, &mut output, &mut bytes_written)?;
        output
            .flush()
            .map_err(|e| format!("Unable to flush recording buffer: {e}"))?;
        let _ = audio_client.stop_stream();

        Ok(CaptureSummary { bytes_written })
    })();

    wasapi::deinitialize();

    if let Err(error) = &result {
        let _ = startup_tx.send(Err(error.clone()));
    }

    result
}

fn flush_sample_queue(
    sample_queue: &mut std::collections::VecDeque<u8>,
    output: &mut File,
    bytes_written: &mut u64,
) -> Result<(), String> {
    let frame_aligned_len = sample_queue.len() - (sample_queue.len() % RECORDING_BYTES_PER_FRAME);
    if frame_aligned_len == 0 {
        return Ok(());
    }

    let mut chunk = Vec::with_capacity(frame_aligned_len);
    for _ in 0..frame_aligned_len {
        if let Some(byte) = sample_queue.pop_front() {
            chunk.push(byte);
        }
    }
    output
        .write_all(&chunk)
        .map_err(|e| format!("Unable to write recording buffer: {e}"))?;
    *bytes_written += chunk.len() as u64;
    Ok(())
}
