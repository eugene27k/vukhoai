use std::collections::HashSet;
use std::fs;
use std::io::{BufRead, BufReader, Read};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use tauri::path::BaseDirectory;
use tauri::{AppHandle, Emitter, Manager, State};
use uuid::Uuid;

const JOBS_EVENT: &str = "ghostmic://jobs-updated";
const SETTINGS_EVENT: &str = "ghostmic://settings-updated";

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum JobStatus {
    Queued,
    Processing,
    Done,
    Failed,
    Cancelled,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum TranscriptionProfile {
    MaximumQuality,
    Balanced,
    FastEconomy,
}

impl Default for TranscriptionProfile {
    fn default() -> Self {
        Self::MaximumQuality
    }
}

impl TranscriptionProfile {
    fn python_flag(self) -> &'static str {
        match self {
            Self::MaximumQuality => "max",
            Self::Balanced => "balanced",
            Self::FastEconomy => "fast",
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum LanguageMode {
    Auto,
    Ukrainian,
}

impl Default for LanguageMode {
    fn default() -> Self {
        Self::Auto
    }
}

impl LanguageMode {
    fn python_flag(self) -> &'static str {
        match self {
            Self::Auto => "auto",
            Self::Ukrainian => "uk",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct ImportJob {
    id: String,
    input_path: String,
    input_filename: String,
    normalized_audio_path: Option<String>,
    status: JobStatus,
    created_at: DateTime<Utc>,
    duration_seconds: Option<f64>,
    profile: TranscriptionProfile,
    language_mode: LanguageMode,
    diarization_enabled: bool,
    output_txt_path: Option<String>,
    meta_json_path: Option<String>,
    error_message: Option<String>,
    progress_percent: Option<f64>,
    progress_stage: Option<String>,
    progress_eta_seconds: Option<f64>,
    processing_started_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct AppSettings {
    default_profile: TranscriptionProfile,
    language_mode: LanguageMode,
    diarization_enabled: bool,
    output_folder_path: String,
    python_path: Option<String>,
    openai_model: String,
    openai_api_key: Option<String>,
}

impl AppSettings {
    fn defaults() -> Self {
        Self {
            default_profile: TranscriptionProfile::MaximumQuality,
            language_mode: LanguageMode::Auto,
            diarization_enabled: true,
            output_folder_path: default_output_directory().to_string_lossy().into_owned(),
            python_path: None,
            openai_model: "gpt-4o-mini".to_string(),
            openai_api_key: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PersistedState {
    settings: AppSettings,
    jobs: Vec<ImportJob>,
}

impl PersistedState {
    fn defaults() -> Self {
        Self {
            settings: AppSettings::defaults(),
            jobs: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, Serialize)]
struct AppSnapshot {
    settings: AppSettings,
    jobs: Vec<ImportJob>,
}

#[derive(Debug, Deserialize)]
struct SettingsUpdate {
    default_profile: TranscriptionProfile,
    language_mode: LanguageMode,
    diarization_enabled: bool,
    output_folder_path: String,
    python_path: Option<String>,
    openai_model: String,
    openai_api_key: Option<String>,
}

#[derive(Debug)]
struct WorkerState {
    persisted: PersistedState,
    worker_running: bool,
    active_job_id: Option<String>,
    active_child: Option<Arc<Mutex<Child>>>,
    cancellation_requests: HashSet<String>,
    deletion_requests: HashSet<String>,
}

#[derive(Clone)]
struct AppShared {
    core: Arc<AppCore>,
}

struct AppCore {
    app: AppHandle,
    store_path: PathBuf,
    normalized_dir: PathBuf,
    metadata_dir: PathBuf,
    script_path: PathBuf,
    worker: Mutex<WorkerState>,
}

#[derive(Debug, Deserialize)]
struct ProgressPayload {
    percent: f64,
    stage: String,
    eta_seconds: Option<f64>,
}

#[derive(Debug)]
struct RunResult {
    exit_code: i32,
    stdout_non_progress: String,
    stderr_output: String,
    normalized_path: String,
    duration_seconds: f64,
    output_path: String,
    meta_path: String,
}

#[tauri::command]
fn get_state(state: State<'_, AppShared>) -> AppSnapshot {
    let guard = state.core.worker.lock().expect("lock worker state");
    AppSnapshot {
        settings: guard.persisted.settings.clone(),
        jobs: guard.persisted.jobs.clone(),
    }
}

#[tauri::command]
fn update_settings(
    state: State<'_, AppShared>,
    payload: SettingsUpdate,
) -> Result<AppSettings, String> {
    let mut guard = state
        .core
        .worker
        .lock()
        .map_err(|_| "Failed to lock state".to_string())?;

    let output_folder_path = payload.output_folder_path.trim();
    if output_folder_path.is_empty() {
        return Err("Output folder cannot be empty.".to_string());
    }

    let output_path = PathBuf::from(output_folder_path);
    fs::create_dir_all(&output_path).map_err(|e| format!("Unable to create output folder: {e}"))?;

    guard.persisted.settings = AppSettings {
        default_profile: payload.default_profile,
        language_mode: payload.language_mode,
        diarization_enabled: payload.diarization_enabled,
        output_folder_path: output_path.to_string_lossy().into_owned(),
        python_path: payload
            .python_path
            .as_deref()
            .map(str::trim)
            .filter(|v| !v.is_empty())
            .map(str::to_string),
        openai_model: payload.openai_model.trim().to_string(),
        openai_api_key: payload
            .openai_api_key
            .as_deref()
            .map(str::trim)
            .filter(|v| !v.is_empty())
            .map(str::to_string),
    };

    persist_state(&state.core)?;
    emit_full_state(&state.core);

    Ok(guard.persisted.settings.clone())
}

#[tauri::command]
fn enqueue_job(state: State<'_, AppShared>, input_path: String) -> Result<ImportJob, String> {
    let path = PathBuf::from(input_path.trim());
    if !path.exists() {
        return Err("Input file does not exist.".to_string());
    }

    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    if ext != "m4a" && ext != "mp4" {
        return Err("Unsupported format. Use .m4a or .mp4.".to_string());
    }

    let mut guard = state
        .core
        .worker
        .lock()
        .map_err(|_| "Failed to lock state".to_string())?;
    let settings = guard.persisted.settings.clone();

    let job = ImportJob {
        id: Uuid::new_v4().to_string(),
        input_path: path.to_string_lossy().into_owned(),
        input_filename: path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("input")
            .to_string(),
        normalized_audio_path: None,
        status: JobStatus::Queued,
        created_at: Utc::now(),
        duration_seconds: None,
        profile: settings.default_profile,
        language_mode: settings.language_mode,
        diarization_enabled: settings.diarization_enabled,
        output_txt_path: None,
        meta_json_path: None,
        error_message: None,
        progress_percent: None,
        progress_stage: None,
        progress_eta_seconds: None,
        processing_started_at: None,
    };

    guard.persisted.jobs.push(job.clone());
    guard.persisted.jobs.sort_by_key(|j| j.created_at);
    drop(guard);

    persist_state(&state.core)?;
    emit_full_state(&state.core);
    ensure_worker_running(state.inner().clone());

    Ok(job)
}

#[tauri::command]
fn retry_job(state: State<'_, AppShared>, job_id: String) -> Result<(), String> {
    let mut guard = state
        .core
        .worker
        .lock()
        .map_err(|_| "Failed to lock state".to_string())?;
    let Some(job) = guard.persisted.jobs.iter_mut().find(|j| j.id == job_id) else {
        return Err("Job not found.".to_string());
    };

    job.status = JobStatus::Queued;
    job.error_message = None;
    job.progress_percent = None;
    job.progress_stage = None;
    job.progress_eta_seconds = None;
    job.processing_started_at = None;

    drop(guard);
    persist_state(&state.core)?;
    emit_full_state(&state.core);
    ensure_worker_running(state.inner().clone());
    Ok(())
}

#[tauri::command]
fn re_transcribe(state: State<'_, AppShared>, job_id: String) -> Result<ImportJob, String> {
    let input_path = {
        let guard = state
            .core
            .worker
            .lock()
            .map_err(|_| "Failed to lock state".to_string())?;
        let Some(source_job) = guard.persisted.jobs.iter().find(|j| j.id == job_id) else {
            return Err("Job not found.".to_string());
        };
        source_job.input_path.clone()
    };

    enqueue_job(state, input_path)
}

#[tauri::command]
fn cancel_job(state: State<'_, AppShared>, job_id: String) -> Result<(), String> {
    let mut guard = state
        .core
        .worker
        .lock()
        .map_err(|_| "Failed to lock state".to_string())?;

    if guard.active_job_id.as_deref() == Some(job_id.as_str()) {
        guard.cancellation_requests.insert(job_id.clone());
        if let Some(child) = guard.active_child.clone() {
            let _ = kill_child(child);
        }
        return Ok(());
    }

    let Some(job) = guard.persisted.jobs.iter_mut().find(|j| j.id == job_id) else {
        return Err("Job not found.".to_string());
    };

    match job.status {
        JobStatus::Queued | JobStatus::Processing => {
            job.status = JobStatus::Cancelled;
            job.error_message = Some("Cancelled by user.".to_string());
            job.progress_percent = None;
            job.progress_stage = None;
            job.progress_eta_seconds = None;
            job.processing_started_at = None;
        }
        JobStatus::Done | JobStatus::Failed | JobStatus::Cancelled => {}
    }

    drop(guard);
    persist_state(&state.core)?;
    emit_full_state(&state.core);
    Ok(())
}

#[tauri::command]
fn delete_job(state: State<'_, AppShared>, job_id: String) -> Result<(), String> {
    let mut to_cleanup: Option<ImportJob> = None;

    {
        let mut guard = state
            .core
            .worker
            .lock()
            .map_err(|_| "Failed to lock state".to_string())?;

        if guard.active_job_id.as_deref() == Some(job_id.as_str()) {
            guard.deletion_requests.insert(job_id.clone());
            guard.cancellation_requests.insert(job_id.clone());
            if let Some(child) = guard.active_child.clone() {
                let _ = kill_child(child);
            }
            return Ok(());
        }

        if let Some(index) = guard.persisted.jobs.iter().position(|j| j.id == job_id) {
            to_cleanup = Some(guard.persisted.jobs.remove(index));
        }
    }

    let Some(job) = to_cleanup else {
        return Err("Job not found.".to_string());
    };

    cleanup_job_files(&state.core, &job);
    persist_state(&state.core)?;
    emit_full_state(&state.core);

    Ok(())
}

#[tauri::command]
fn read_transcript(
    state: State<'_, AppShared>,
    job_id: String,
    show_timestamps: bool,
    show_speakers: bool,
) -> Result<String, String> {
    let output_path = {
        let guard = state
            .core
            .worker
            .lock()
            .map_err(|_| "Failed to lock state".to_string())?;
        let Some(job) = guard.persisted.jobs.iter().find(|j| j.id == job_id) else {
            return Err("Job not found.".to_string());
        };
        let Some(path) = &job.output_txt_path else {
            return Err("Transcript is not ready.".to_string());
        };
        path.clone()
    };

    let raw =
        fs::read_to_string(&output_path).map_err(|e| format!("Unable to read transcript: {e}"))?;

    Ok(format_transcript(&raw, show_timestamps, show_speakers))
}

#[tauri::command]
fn export_transcript(
    state: State<'_, AppShared>,
    job_id: String,
    destination_path: String,
    show_timestamps: bool,
    show_speakers: bool,
) -> Result<(), String> {
    let formatted = read_transcript(state, job_id, show_timestamps, show_speakers)?;
    let destination = PathBuf::from(destination_path);

    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent)
            .map_err(|e| format!("Unable to prepare export directory: {e}"))?;
    }

    fs::write(destination, formatted).map_err(|e| format!("Unable to export transcript: {e}"))
}

fn ensure_worker_running(shared: AppShared) {
    let should_start = {
        let mut guard = match shared.core.worker.lock() {
            Ok(g) => g,
            Err(_) => return,
        };

        if guard.worker_running {
            false
        } else {
            guard.worker_running = true;
            true
        }
    };

    if !should_start {
        return;
    }

    thread::spawn(move || {
        worker_loop(shared);
    });
}

fn worker_loop(shared: AppShared) {
    loop {
        let next_job_id = {
            let mut guard = match shared.core.worker.lock() {
                Ok(g) => g,
                Err(_) => return,
            };

            let mut queued_ids: Vec<_> = guard
                .persisted
                .jobs
                .iter()
                .filter(|job| job.status == JobStatus::Queued)
                .map(|job| (job.created_at, job.id.clone()))
                .collect();

            queued_ids.sort_by_key(|pair| pair.0);

            let Some((_, job_id)) = queued_ids.first() else {
                guard.worker_running = false;
                guard.active_job_id = None;
                guard.active_child = None;
                break;
            };

            if let Some(job) = guard.persisted.jobs.iter_mut().find(|j| j.id == *job_id) {
                job.status = JobStatus::Processing;
                job.error_message = None;
                job.progress_percent = Some(1.0);
                job.progress_stage = Some("Preparing audio".to_string());
                job.progress_eta_seconds = None;
                job.processing_started_at = Some(Utc::now());
            }

            guard.active_job_id = Some(job_id.clone());
            job_id.clone()
        };

        let _ = persist_state(&shared.core);
        emit_full_state(&shared.core);

        let process_result = run_job(&shared, &next_job_id);

        finalize_job_after_run(&shared, &next_job_id, process_result);
    }
}

fn finalize_job_after_run(shared: &AppShared, job_id: &str, run_result: Result<RunResult, String>) {
    let mut removed_job: Option<ImportJob> = None;

    {
        let mut guard = match shared.core.worker.lock() {
            Ok(g) => g,
            Err(_) => return,
        };

        let was_cancelled = guard.cancellation_requests.remove(job_id);
        let should_delete = guard.deletion_requests.remove(job_id);

        if let Some(job) = guard.persisted.jobs.iter_mut().find(|j| j.id == job_id) {
            match run_result {
                Ok(result) => {
                    job.normalized_audio_path = Some(result.normalized_path.clone());
                    job.duration_seconds = Some(result.duration_seconds);

                    if should_delete {
                        // handled below after remove
                    } else if was_cancelled {
                        job.status = JobStatus::Cancelled;
                        job.error_message = Some("Cancelled by user.".to_string());
                    } else if result.exit_code == 0 {
                        job.status = JobStatus::Done;
                        job.output_txt_path = Some(result.output_path.clone());
                        job.meta_json_path = Some(result.meta_path.clone());
                        job.error_message = None;
                    } else {
                        let combined = format!(
                            "{}\n{}",
                            result.stdout_non_progress.trim(),
                            result.stderr_output.trim()
                        )
                        .trim()
                        .to_string();
                        job.status = JobStatus::Failed;
                        job.error_message = Some(if combined.is_empty() {
                            format!("Transcription failed with exit code {}.", result.exit_code)
                        } else {
                            combined
                        });
                    }
                }
                Err(error) => {
                    if should_delete {
                        // handled below after remove
                    } else if was_cancelled {
                        job.status = JobStatus::Cancelled;
                        job.error_message = Some("Cancelled by user.".to_string());
                    } else {
                        job.status = JobStatus::Failed;
                        job.error_message = Some(error);
                    }
                }
            }

            job.progress_percent = None;
            job.progress_stage = None;
            job.progress_eta_seconds = None;
            job.processing_started_at = None;
        }

        if should_delete {
            if let Some(index) = guard.persisted.jobs.iter().position(|j| j.id == job_id) {
                removed_job = Some(guard.persisted.jobs.remove(index));
            }
        }

        guard.active_job_id = None;
        guard.active_child = None;
    }

    if let Some(job) = removed_job {
        cleanup_job_files(&shared.core, &job);
    }

    let _ = persist_state(&shared.core);
    emit_full_state(&shared.core);
}

fn run_job(shared: &AppShared, job_id: &str) -> Result<RunResult, String> {
    let (settings, job) = {
        let guard = shared
            .core
            .worker
            .lock()
            .map_err(|_| "Failed to lock state".to_string())?;
        let Some(job) = guard.persisted.jobs.iter().find(|j| j.id == job_id) else {
            return Err("Job disappeared from queue.".to_string());
        };
        (guard.persisted.settings.clone(), job.clone())
    };

    fs::create_dir_all(&shared.core.normalized_dir)
        .map_err(|e| format!("Unable to prepare audio cache directory: {e}"))?;
    fs::create_dir_all(&shared.core.metadata_dir)
        .map_err(|e| format!("Unable to prepare metadata directory: {e}"))?;

    let prepared = prepare_audio(&shared.core.normalized_dir, &job)?;

    {
        let mut guard = shared
            .core
            .worker
            .lock()
            .map_err(|_| "Failed to lock state".to_string())?;
        if let Some(job_mut) = guard.persisted.jobs.iter_mut().find(|j| j.id == job_id) {
            job_mut.normalized_audio_path = Some(prepared.path.clone());
            job_mut.duration_seconds = Some(prepared.duration_seconds);
            job_mut.progress_percent = Some(4.0);
            job_mut.progress_stage = Some("Starting transcription".to_string());
            job_mut.progress_eta_seconds = None;
        }
    }

    let _ = persist_state(&shared.core);
    emit_full_state(&shared.core);

    let output_path = output_txt_path(&settings, &job);
    let meta_path = shared
        .core
        .metadata_dir
        .join(format!("{}.json", job.id))
        .to_string_lossy()
        .into_owned();

    if let Some(parent) = Path::new(&output_path).parent() {
        fs::create_dir_all(parent)
            .map_err(|e| format!("Unable to prepare output directory: {e}"))?;
    }

    let python_binary = resolve_python_binary(&settings)?;

    let mut command = Command::new(&python_binary);
    command
        .arg(&shared.core.script_path)
        .arg("--input")
        .arg(&prepared.path)
        .arg("--output")
        .arg(&output_path)
        .arg("--meta")
        .arg(&meta_path)
        .arg("--profile")
        .arg(job.profile.python_flag())
        .arg("--language")
        .arg(job.language_mode.python_flag())
        .arg("--diarization")
        .arg(if job.diarization_enabled { "on" } else { "off" })
        .arg("--duration-seconds")
        .arg(format!("{:.3}", prepared.duration_seconds))
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    let child = command
        .spawn()
        .map_err(|e| format!("Unable to start transcription process: {e}"))?;

    let child_arc = Arc::new(Mutex::new(child));

    {
        let mut guard = shared
            .core
            .worker
            .lock()
            .map_err(|_| "Failed to lock state".to_string())?;
        guard.active_child = Some(child_arc.clone());
    }

    let stdout = {
        let mut child_guard = child_arc
            .lock()
            .map_err(|_| "Failed to lock process".to_string())?;
        child_guard
            .stdout
            .take()
            .ok_or_else(|| "Unable to read process stdout.".to_string())?
    };

    let stderr = {
        let mut child_guard = child_arc
            .lock()
            .map_err(|_| "Failed to lock process".to_string())?;
        child_guard
            .stderr
            .take()
            .ok_or_else(|| "Unable to read process stderr.".to_string())?
    };

    let stderr_thread = thread::spawn(move || {
        let mut reader = BufReader::new(stderr);
        let mut content = String::new();
        let _ = reader.read_to_string(&mut content);
        content
    });

    let mut stdout_reader = BufReader::new(stdout);
    let mut line = String::new();
    let mut stdout_non_progress: Vec<String> = Vec::new();

    loop {
        line.clear();
        let bytes = stdout_reader
            .read_line(&mut line)
            .map_err(|e| format!("Failed to read transcription output: {e}"))?;
        if bytes == 0 {
            break;
        }

        let trimmed = line.trim_end_matches(['\r', '\n']).to_string();
        if trimmed.is_empty() {
            continue;
        }

        if !apply_progress_line(shared, job_id, &trimmed) {
            stdout_non_progress.push(trimmed);
        }
    }

    let status = {
        let mut child_guard = child_arc
            .lock()
            .map_err(|_| "Failed to lock process".to_string())?;
        child_guard
            .wait()
            .map_err(|e| format!("Failed to wait transcription process: {e}"))?
    };

    let stderr_output = stderr_thread.join().unwrap_or_default();

    {
        let mut guard = shared
            .core
            .worker
            .lock()
            .map_err(|_| "Failed to lock state".to_string())?;
        guard.active_child = None;
    }

    Ok(RunResult {
        exit_code: status.code().unwrap_or(-1),
        stdout_non_progress: stdout_non_progress.join("\n"),
        stderr_output,
        normalized_path: prepared.path,
        duration_seconds: prepared.duration_seconds,
        output_path,
        meta_path,
    })
}

fn apply_progress_line(shared: &AppShared, job_id: &str, line: &str) -> bool {
    let Some(payload) = line.strip_prefix("GHOSTMIC_PROGRESS ") else {
        return false;
    };

    let parsed = serde_json::from_str::<ProgressPayload>(payload);
    let Ok(progress) = parsed else {
        return false;
    };

    if let Ok(mut guard) = shared.core.worker.lock() {
        if let Some(job) = guard.persisted.jobs.iter_mut().find(|j| j.id == job_id) {
            job.progress_percent = Some(progress.percent.clamp(0.0, 100.0));
            job.progress_stage = Some(progress.stage);
            job.progress_eta_seconds = progress.eta_seconds.filter(|v| *v >= 0.0);
        }
    }

    let _ = persist_state(&shared.core);
    emit_full_state(&shared.core);

    true
}

fn kill_child(child: Arc<Mutex<Child>>) -> Result<(), String> {
    let mut guard = child
        .lock()
        .map_err(|_| "Failed to lock process".to_string())?;
    guard
        .kill()
        .map_err(|e| format!("Unable to stop transcription process: {e}"))
}

struct PreparedAudio {
    path: String,
    duration_seconds: f64,
}

fn prepare_audio(normalized_dir: &Path, job: &ImportJob) -> Result<PreparedAudio, String> {
    let input_path = PathBuf::from(&job.input_path);
    let extension = input_path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();

    let normalized_path = if extension == "mp4" {
        let target = normalized_dir.join(format!("{}.m4a", job.id));
        let ffmpeg_result = Command::new("ffmpeg")
            .arg("-y")
            .arg("-i")
            .arg(&job.input_path)
            .arg("-vn")
            .arg("-acodec")
            .arg("aac")
            .arg(target.to_string_lossy().to_string())
            .output();

        match ffmpeg_result {
            Ok(output) if output.status.success() => target,
            Ok(_) | Err(_) => input_path.clone(),
        }
    } else {
        input_path.clone()
    };

    let duration_seconds = probe_duration_seconds(&normalized_path).unwrap_or(0.0);

    Ok(PreparedAudio {
        path: normalized_path.to_string_lossy().into_owned(),
        duration_seconds,
    })
}

fn probe_duration_seconds(path: &Path) -> Option<f64> {
    let output = Command::new("ffprobe")
        .arg("-v")
        .arg("error")
        .arg("-show_entries")
        .arg("format=duration")
        .arg("-of")
        .arg("default=noprint_wrappers=1:nokey=1")
        .arg(path)
        .output()
        .ok()?;

    if !output.status.success() {
        return None;
    }

    let text = String::from_utf8_lossy(&output.stdout).trim().to_string();
    text.parse::<f64>().ok()
}

fn output_txt_path(settings: &AppSettings, job: &ImportJob) -> String {
    let base = Path::new(&job.input_filename)
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("transcript");
    let short_id = job.id.chars().take(8).collect::<String>();
    Path::new(&settings.output_folder_path)
        .join(format!("{}-{}.txt", base, short_id))
        .to_string_lossy()
        .into_owned()
}

fn resolve_python_binary(settings: &AppSettings) -> Result<String, String> {
    let candidates = [
        settings
            .python_path
            .as_deref()
            .map(str::trim)
            .filter(|v| !v.is_empty())
            .map(str::to_string),
        std::env::var("GHOSTMIC_PYTHON").ok(),
        Some("python3".to_string()),
        Some("python".to_string()),
    ];

    for candidate in candidates.into_iter().flatten() {
        if Command::new(&candidate).arg("--version").output().is_ok() {
            return Ok(candidate);
        }
    }

    Err(
        "Python executable not found. Set it in Settings -> Python path or install python3."
            .to_string(),
    )
}

fn default_output_directory() -> PathBuf {
    let base = dirs::document_dir()
        .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));

    base.join("GhostMic").join("Exports")
}

fn persist_state(core: &AppCore) -> Result<(), String> {
    let persisted = {
        let guard = core
            .worker
            .lock()
            .map_err(|_| "Failed to lock state".to_string())?;
        guard.persisted.clone()
    };

    let serialized = serde_json::to_string_pretty(&persisted)
        .map_err(|e| format!("Failed to serialize state: {e}"))?;

    if let Some(parent) = core.store_path.parent() {
        fs::create_dir_all(parent)
            .map_err(|e| format!("Failed to prepare state directory: {e}"))?;
    }

    fs::write(&core.store_path, serialized).map_err(|e| format!("Failed to persist state: {e}"))
}

fn emit_full_state(core: &AppCore) {
    let snapshot = {
        let guard = match core.worker.lock() {
            Ok(g) => g,
            Err(_) => return,
        };
        (
            guard.persisted.jobs.clone(),
            guard.persisted.settings.clone(),
        )
    };

    let _ = core.app.emit(JOBS_EVENT, snapshot.0);
    let _ = core.app.emit(SETTINGS_EVENT, snapshot.1);
}

fn cleanup_job_files(core: &AppCore, job: &ImportJob) {
    maybe_remove_file(job.output_txt_path.as_deref());
    maybe_remove_file(job.meta_json_path.as_deref());

    if let Some(normalized) = &job.normalized_audio_path {
        let normalized_path = PathBuf::from(normalized);
        let input_path = PathBuf::from(&job.input_path);

        if normalized_path != input_path && normalized_path.starts_with(&core.normalized_dir) {
            maybe_remove_file(Some(normalized));
        }
    }
}

fn maybe_remove_file(path: Option<&str>) {
    let Some(path) = path else {
        return;
    };

    let file_path = PathBuf::from(path);
    if file_path.exists() {
        let _ = fs::remove_file(file_path);
    }
}

fn format_transcript(raw: &str, show_timestamps: bool, show_speakers: bool) -> String {
    raw.lines()
        .map(|line| format_transcript_line(line, show_timestamps, show_speakers))
        .collect::<Vec<_>>()
        .join("\n")
}

fn format_transcript_line(line: &str, show_timestamps: bool, show_speakers: bool) -> String {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return String::new();
    }

    if let Some(rest) = trimmed.strip_prefix('[') {
        if let Some(close_idx) = rest.find(']') {
            let timestamp_content = &rest[..close_idx];
            let remainder = rest[close_idx + 1..].trim_start();

            if let Some((speaker, text)) = remainder.split_once(':') {
                let speaker_trimmed = speaker.trim();
                let text_trimmed = text.trim();
                if speaker_trimmed.starts_with("SPEAKER_") {
                    match (show_timestamps, show_speakers) {
                        (true, true) => {
                            return format!(
                                "[{timestamp_content}] {speaker_trimmed}: {text_trimmed}"
                            );
                        }
                        (true, false) => {
                            return format!("[{timestamp_content}] {text_trimmed}");
                        }
                        (false, true) => {
                            return format!("{speaker_trimmed}: {text_trimmed}");
                        }
                        (false, false) => {
                            return text_trimmed.to_string();
                        }
                    }
                }
            }
        }
    }

    trimmed.to_string()
}

fn resolve_script_path(app: &tauri::App) -> Result<PathBuf, String> {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));

    let mut candidates = Vec::new();

    if let Ok(path) = app
        .path()
        .resolve("resources/transcribe.py", BaseDirectory::Resource)
    {
        candidates.push(path);
    }

    if let Ok(path) = app.path().resolve("transcribe.py", BaseDirectory::Resource) {
        candidates.push(path);
    }

    candidates.push(manifest_dir.join("resources").join("transcribe.py"));
    candidates.push(
        manifest_dir
            .join("..")
            .join("..")
            .join("Sources")
            .join("GhostMicApp")
            .join("Resources")
            .join("transcribe.py"),
    );

    candidates
        .into_iter()
        .find(|p| p.exists())
        .ok_or_else(|| "transcribe.py resource was not found.".to_string())
}

fn build_shared_state(app: &tauri::App) -> Result<AppShared, String> {
    let app_data = app
        .path()
        .app_data_dir()
        .map_err(|e| format!("Unable to resolve app data directory: {e}"))?;

    fs::create_dir_all(&app_data)
        .map_err(|e| format!("Unable to create app data directory: {e}"))?;

    let store_path = app_data.join("state.json");
    let normalized_dir = app_data.join("normalized_audio");
    let metadata_dir = app_data.join("metadata");

    fs::create_dir_all(&normalized_dir)
        .map_err(|e| format!("Unable to create normalized audio directory: {e}"))?;
    fs::create_dir_all(&metadata_dir)
        .map_err(|e| format!("Unable to create metadata directory: {e}"))?;

    let mut persisted = if store_path.exists() {
        let content = fs::read_to_string(&store_path)
            .map_err(|e| format!("Unable to read state file: {e}"))?;
        serde_json::from_str::<PersistedState>(&content)
            .map_err(|e| format!("Unable to parse state file: {e}"))?
    } else {
        PersistedState::defaults()
    };

    if persisted.settings.output_folder_path.trim().is_empty() {
        persisted.settings.output_folder_path =
            default_output_directory().to_string_lossy().into_owned();
    }

    fs::create_dir_all(&persisted.settings.output_folder_path)
        .map_err(|e| format!("Unable to create output directory: {e}"))?;

    let script_path = resolve_script_path(app)?;

    let shared = AppShared {
        core: Arc::new(AppCore {
            app: app.handle().clone(),
            store_path,
            normalized_dir,
            metadata_dir,
            script_path,
            worker: Mutex::new(WorkerState {
                persisted,
                worker_running: false,
                active_job_id: None,
                active_child: None,
                cancellation_requests: HashSet::new(),
                deletion_requests: HashSet::new(),
            }),
        }),
    };

    persist_state(&shared.core)?;
    Ok(shared)
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .setup(|app| {
            let shared = build_shared_state(app)?;
            app.manage(shared.clone());
            emit_full_state(&shared.core);
            ensure_worker_running(shared);
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_state,
            update_settings,
            enqueue_job,
            retry_job,
            re_transcribe,
            cancel_job,
            delete_job,
            read_transcript,
            export_transcript,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
