use std::collections::{BTreeMap, HashSet};
use std::fs;
use std::io::{BufRead, BufReader, Read};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Instant;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use tauri::path::BaseDirectory;
use tauri::{AppHandle, Emitter, Manager, State};
use uuid::Uuid;

const JOBS_EVENT: &str = "ghostmic://jobs-updated";
const SETTINGS_EVENT: &str = "ghostmic://settings-updated";
const PORTABLE_STATE_FILE_NAME: &str = "portable-state.json";

#[cfg(windows)]
const FFMPEG_BINARY_NAME: &str = "ffmpeg.exe";
#[cfg(not(windows))]
const FFMPEG_BINARY_NAME: &str = "ffmpeg";

#[cfg(windows)]
const FFPROBE_BINARY_NAME: &str = "ffprobe.exe";
#[cfg(not(windows))]
const FFPROBE_BINARY_NAME: &str = "ffprobe";

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
        Self::Ukrainian
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
    notice_message: Option<String>,
    processing_elapsed_seconds: Option<f64>,
    audio_to_processing_ratio: Option<f64>,
    progress_percent: Option<f64>,
    progress_stage: Option<String>,
    progress_eta_seconds: Option<f64>,
    processing_started_at: Option<DateTime<Utc>>,
    #[serde(default)]
    is_paused: bool,
    #[serde(default)]
    speaker_aliases: BTreeMap<String, String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct AppSettings {
    default_profile: TranscriptionProfile,
    language_mode: LanguageMode,
    diarization_enabled: bool,
    output_folder_path: String,
    python_path: Option<String>,
    diarization_python_path: Option<String>,
    huggingface_token: Option<String>,
    openai_model: String,
    openai_api_key: Option<String>,
}

impl AppSettings {
    fn defaults() -> Self {
        Self {
            default_profile: TranscriptionProfile::MaximumQuality,
            language_mode: LanguageMode::Ukrainian,
            diarization_enabled: true,
            output_folder_path: default_output_directory().to_string_lossy().into_owned(),
            python_path: None,
            diarization_python_path: None,
            huggingface_token: None,
            openai_model: "gpt-4o-mini".to_string(),
            openai_api_key: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PersistedState {
    #[serde(default = "legacy_state_schema_version")]
    schema_version: u32,
    settings: AppSettings,
    jobs: Vec<ImportJob>,
}

impl PersistedState {
    fn defaults() -> Self {
        Self {
            schema_version: STATE_SCHEMA_VERSION,
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
    diarization_python_path: Option<String>,
    huggingface_token: Option<String>,
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

#[derive(Debug, Deserialize)]
struct NoticePayload {
    message: String,
}

#[derive(Debug)]
struct RunResult {
    exit_code: i32,
    stdout_non_progress: String,
    stderr_output: String,
    normalized_path: String,
    duration_seconds: f64,
    processing_elapsed_seconds: f64,
    output_path: String,
    meta_path: String,
}

#[derive(Debug, Clone, Copy, Default)]
struct PythonRuntimeCapabilities {
    has_faster_whisper: bool,
    has_whisperx: bool,
    has_pyannote_audio: bool,
}

impl PythonRuntimeCapabilities {
    fn supports_transcription(self) -> bool {
        self.has_faster_whisper || self.has_whisperx
    }

    fn supports_diarization(self) -> bool {
        self.has_whisperx && self.has_pyannote_audio
    }
}

#[derive(Debug, Deserialize)]
struct PythonRuntimeCapabilitiesJson {
    #[serde(default)]
    faster_whisper: bool,
    #[serde(default)]
    whisperx: bool,
    #[serde(default)]
    pyannote_audio: bool,
}

#[derive(Debug, Deserialize)]
struct JobMetadata {
    #[serde(default)]
    diarization_requested: bool,
    #[serde(default)]
    diarization_applied: bool,
    diarization_fallback_reason: Option<String>,
    #[serde(default)]
    fallback_events: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
struct TranscriptSpeaker {
    label: String,
    alias: String,
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
    eprintln!(
        "[settings] update requested: output_folder_path={:?}, has_hf_token={}, has_openai_key={}",
        payload.output_folder_path,
        payload
            .huggingface_token
            .as_deref()
            .map(str::trim)
            .is_some_and(|value| !value.is_empty()),
        payload
            .openai_api_key
            .as_deref()
            .map(str::trim)
            .is_some_and(|value| !value.is_empty())
    );

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
        diarization_python_path: payload
            .diarization_python_path
            .as_deref()
            .map(str::trim)
            .filter(|v| !v.is_empty())
            .map(str::to_string),
        huggingface_token: payload
            .huggingface_token
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

    let updated = guard.persisted.settings.clone();
    drop(guard);

    persist_state(&state.core)?;
    emit_full_state(&state.core);

    Ok(updated)
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
        notice_message: None,
        processing_elapsed_seconds: None,
        audio_to_processing_ratio: None,
        progress_percent: None,
        progress_stage: None,
        progress_eta_seconds: None,
        processing_started_at: None,
        is_paused: false,
        speaker_aliases: BTreeMap::new(),
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
    job.notice_message = None;
    job.processing_elapsed_seconds = None;
    job.audio_to_processing_ratio = None;
    job.progress_percent = None;
    job.progress_stage = None;
    job.progress_eta_seconds = None;
    job.processing_started_at = None;
    job.is_paused = false;

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
            job.notice_message = None;
            job.processing_elapsed_seconds = None;
            job.audio_to_processing_ratio = None;
            job.progress_percent = None;
            job.progress_stage = None;
            job.progress_eta_seconds = None;
            job.processing_started_at = None;
            job.is_paused = false;
        }
        JobStatus::Done | JobStatus::Failed | JobStatus::Cancelled => {}
    }

    drop(guard);
    persist_state(&state.core)?;
    emit_full_state(&state.core);
    Ok(())
}

#[tauri::command]
fn pause_job(state: State<'_, AppShared>, job_id: String) -> Result<(), String> {
    let mut guard = state
        .core
        .worker
        .lock()
        .map_err(|_| "Failed to lock state".to_string())?;

    if guard.active_job_id.as_deref() != Some(job_id.as_str()) {
        return Err("Pause is available only for currently processing job.".to_string());
    }

    let child = guard
        .active_child
        .clone()
        .ok_or_else(|| "No active transcription process found.".to_string())?;

    pause_child_process(child)?;

    if let Some(job) = guard.persisted.jobs.iter_mut().find(|j| j.id == job_id) {
        job.is_paused = true;
        job.progress_stage = Some("Paused by user".to_string());
    }

    drop(guard);
    persist_state(&state.core)?;
    emit_full_state(&state.core);
    Ok(())
}

#[tauri::command]
fn resume_job(state: State<'_, AppShared>, job_id: String) -> Result<(), String> {
    let mut guard = state
        .core
        .worker
        .lock()
        .map_err(|_| "Failed to lock state".to_string())?;

    if guard.active_job_id.as_deref() != Some(job_id.as_str()) {
        return Err("Resume is available only for currently processing job.".to_string());
    }

    let child = guard
        .active_child
        .clone()
        .ok_or_else(|| "No active transcription process found.".to_string())?;

    resume_child_process(child)?;

    if let Some(job) = guard.persisted.jobs.iter_mut().find(|j| j.id == job_id) {
        job.is_paused = false;
        job.progress_stage = Some("Resumed".to_string());
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
fn clear_jobs(state: State<'_, AppShared>) -> Result<(), String> {
    let mut to_cleanup: Vec<ImportJob> = Vec::new();

    {
        let mut guard = state
            .core
            .worker
            .lock()
            .map_err(|_| "Failed to lock state".to_string())?;

        let active_job_id = guard.active_job_id.clone();

        if let Some(job_id) = active_job_id.as_ref() {
            guard.cancellation_requests.insert(job_id.clone());
            guard.deletion_requests.insert(job_id.clone());
            if let Some(child) = guard.active_child.clone() {
                let _ = kill_child(child);
            }
        }

        guard.persisted.jobs.retain(|job| {
            let keep_active = active_job_id.as_deref() == Some(job.id.as_str());
            if !keep_active {
                to_cleanup.push(job.clone());
            }
            keep_active
        });

        guard
            .cancellation_requests
            .retain(|job_id| active_job_id.as_deref() == Some(job_id.as_str()));
        guard
            .deletion_requests
            .retain(|job_id| active_job_id.as_deref() == Some(job_id.as_str()));
    }

    for job in &to_cleanup {
        cleanup_job_files(&state.core, job);
    }

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
    let (output_path, speaker_aliases) = {
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
        (path.clone(), job.speaker_aliases.clone())
    };

    let raw =
        fs::read_to_string(&output_path).map_err(|e| format!("Unable to read transcript: {e}"))?;

    Ok(format_transcript(
        &raw,
        show_timestamps,
        show_speakers,
        &speaker_aliases,
    ))
}

#[tauri::command]
fn get_transcript_speakers(
    state: State<'_, AppShared>,
    job_id: String,
) -> Result<Vec<TranscriptSpeaker>, String> {
    let (output_path, speaker_aliases) = {
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
        (path.clone(), job.speaker_aliases.clone())
    };

    let raw =
        fs::read_to_string(&output_path).map_err(|e| format!("Unable to read transcript: {e}"))?;

    Ok(extract_transcript_speakers(&raw, &speaker_aliases))
}

#[tauri::command]
fn update_speaker_aliases(
    state: State<'_, AppShared>,
    job_id: String,
    aliases: BTreeMap<String, String>,
) -> Result<(), String> {
    let mut guard = state
        .core
        .worker
        .lock()
        .map_err(|_| "Failed to lock state".to_string())?;

    let Some(job) = guard.persisted.jobs.iter_mut().find(|j| j.id == job_id) else {
        return Err("Job not found.".to_string());
    };

    let Some(_path) = &job.output_txt_path else {
        return Err("Transcript is not ready.".to_string());
    };

    job.speaker_aliases = normalize_speaker_aliases(aliases);

    drop(guard);
    persist_state(&state.core)?;
    emit_full_state(&state.core);
    Ok(())
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
                job.notice_message = None;
                job.processing_elapsed_seconds = None;
                job.audio_to_processing_ratio = None;
                job.progress_percent = Some(1.0);
                job.progress_stage = Some("Preparing audio".to_string());
                job.progress_eta_seconds = None;
                job.processing_started_at = Some(Utc::now());
                job.is_paused = false;
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
    let processing_metrics = match &run_result {
        Ok(result) => {
            let ratio = compute_audio_to_processing_ratio(
                result.duration_seconds,
                result.processing_elapsed_seconds,
            );
            if result.exit_code == 0 {
                persist_job_metrics_to_metadata(
                    &result.meta_path,
                    result.duration_seconds,
                    result.processing_elapsed_seconds,
                    ratio,
                );
            }
            Some((result.processing_elapsed_seconds, ratio))
        }
        Err(_) => None,
    };
    let success_notice = match &run_result {
        Ok(result) if result.exit_code == 0 => build_job_notice(&shared.core, &result.meta_path),
        _ => None,
    };

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
                    job.processing_elapsed_seconds = Some(result.processing_elapsed_seconds);
                    job.audio_to_processing_ratio =
                        processing_metrics.as_ref().and_then(|metrics| metrics.1);

                    if should_delete {
                        // handled below after remove
                    } else if was_cancelled {
                        job.status = JobStatus::Cancelled;
                        job.error_message = Some("Cancelled by user.".to_string());
                        job.is_paused = false;
                    } else if result.exit_code == 0 {
                        job.status = JobStatus::Done;
                        job.output_txt_path = Some(result.output_path.clone());
                        job.meta_json_path = Some(result.meta_path.clone());
                        job.error_message = None;
                        job.notice_message = success_notice.clone();
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
                        job.notice_message = None;
                    }
                }
                Err(error) => {
                    if should_delete {
                        // handled below after remove
                    } else if was_cancelled {
                        job.status = JobStatus::Cancelled;
                        job.error_message = Some("Cancelled by user.".to_string());
                        job.is_paused = false;
                    } else {
                        job.status = JobStatus::Failed;
                        job.error_message = Some(error);
                        job.notice_message = None;
                        job.processing_elapsed_seconds = None;
                        job.audio_to_processing_ratio = None;
                    }
                }
            }

            job.progress_percent = None;
            job.progress_stage = None;
            job.progress_eta_seconds = None;
            job.processing_started_at = None;
            job.is_paused = false;
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
    let run_started = Instant::now();
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

    let python_binary =
        resolve_python_binary(&settings, &shared.core.script_path, job.diarization_enabled)?;

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

    if let Some(token) = settings
        .huggingface_token
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        command.env("HF_TOKEN", token);
        command.env("HUGGINGFACE_HUB_TOKEN", token);
    }

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

        if !apply_runtime_line(shared, job_id, &trimmed) {
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
        processing_elapsed_seconds: run_started.elapsed().as_secs_f64(),
        output_path,
        meta_path,
    })
}

fn apply_runtime_line(shared: &AppShared, job_id: &str, line: &str) -> bool {
    if let Some(payload) = line
        .strip_prefix("VUKHOAI_NOTICE ")
        .or_else(|| line.strip_prefix("GHOSTMIC_NOTICE "))
    {
        let parsed = serde_json::from_str::<NoticePayload>(payload);
        let Ok(notice) = parsed else {
            return false;
        };

        if let Ok(mut guard) = shared.core.worker.lock() {
            if let Some(job) = guard.persisted.jobs.iter_mut().find(|j| j.id == job_id) {
                let message = notice.message.trim();
                if !message.is_empty() {
                    job.notice_message = Some(message.to_string());
                }
            }
        }

        let _ = persist_state(&shared.core);
        emit_full_state(&shared.core);
        return true;
    }

    let Some(payload) = line
        .strip_prefix("VUKHOAI_PROGRESS ")
        .or_else(|| line.strip_prefix("GHOSTMIC_PROGRESS "))
    else {
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

#[cfg(unix)]
fn pause_child_process(child: Arc<Mutex<Child>>) -> Result<(), String> {
    let guard = child
        .lock()
        .map_err(|_| "Failed to lock process".to_string())?;
    let pid = guard.id() as i32;
    let result = unsafe { libc::kill(pid, libc::SIGSTOP) };
    if result == 0 {
        Ok(())
    } else {
        Err("Unable to pause transcription process.".to_string())
    }
}

#[cfg(not(unix))]
fn pause_child_process(_child: Arc<Mutex<Child>>) -> Result<(), String> {
    Err("Pause is not supported on this platform yet.".to_string())
}

#[cfg(unix)]
fn resume_child_process(child: Arc<Mutex<Child>>) -> Result<(), String> {
    let guard = child
        .lock()
        .map_err(|_| "Failed to lock process".to_string())?;
    let pid = guard.id() as i32;
    let result = unsafe { libc::kill(pid, libc::SIGCONT) };
    if result == 0 {
        Ok(())
    } else {
        Err("Unable to resume transcription process.".to_string())
    }
}

#[cfg(not(unix))]
fn resume_child_process(_child: Arc<Mutex<Child>>) -> Result<(), String> {
    Err("Resume is not supported on this platform yet.".to_string())
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
        let ffmpeg_result = Command::new(resolve_runtime_binary(FFMPEG_BINARY_NAME))
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
    let output = Command::new(resolve_runtime_binary(FFPROBE_BINARY_NAME))
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

fn resolve_python_binary(
    settings: &AppSettings,
    script_path: &Path,
    diarization_enabled: bool,
) -> Result<String, String> {
    let mut candidates: Vec<String> = Vec::new();

    if diarization_enabled {
        if let Some(value) = settings
            .diarization_python_path
            .as_deref()
            .map(str::trim)
            .filter(|v| !v.is_empty())
        {
            candidates.push(value.to_string());
        }

        if let Ok(env_python) = std::env::var("VUKHOAI_DIARIZATION_PYTHON") {
            if !env_python.trim().is_empty() {
                candidates.push(env_python);
            }
        }

        if let Ok(env_python) = std::env::var("GHOSTMIC_DIARIZATION_PYTHON") {
            if !env_python.trim().is_empty() {
                candidates.push(env_python);
            }
        }
    }

    if let Some(value) = settings
        .python_path
        .as_deref()
        .map(str::trim)
        .filter(|v| !v.is_empty())
    {
        candidates.push(value.to_string());
    }

    if let Ok(env_python) = std::env::var("VUKHOAI_PYTHON") {
        if !env_python.trim().is_empty() {
            candidates.push(env_python);
        }
    }

    if let Ok(env_python) = std::env::var("GHOSTMIC_PYTHON") {
        if !env_python.trim().is_empty() {
            candidates.push(env_python);
        }
    }

    candidates.extend(discover_local_venv_python_candidates(script_path));
    candidates.push("python3".to_string());
    candidates.push("python".to_string());

    let mut seen: HashSet<String> = HashSet::new();
    let mut transcription_capable_fallback: Option<String> = None;
    let mut missing_transcription_for: Vec<String> = Vec::new();
    let mut missing_diarization_for: Vec<String> = Vec::new();

    for candidate in candidates {
        if !seen.insert(candidate.clone()) {
            continue;
        }

        let Some(capabilities) = inspect_python_runtime(&candidate) else {
            continue;
        };

        if diarization_enabled && capabilities.supports_diarization() {
            return Ok(candidate);
        }

        if capabilities.supports_transcription() {
            if transcription_capable_fallback.is_none() {
                transcription_capable_fallback = Some(candidate.clone());
            }

            if diarization_enabled && !capabilities.supports_diarization() {
                missing_diarization_for.push(candidate);
            }
            continue;
        }

        missing_transcription_for.push(candidate);
    }

    if let Some(candidate) = transcription_capable_fallback {
        return Ok(candidate);
    }

    if !missing_transcription_for.is_empty() {
        let preferred = missing_transcription_for
            .first()
            .cloned()
            .unwrap_or_else(|| "python3".to_string());
        let install_hint = build_requirements_install_hint(script_path, &preferred);
        return Err(format!(
            "Python found but dependency `faster_whisper` is missing. {} Or set Settings -> Python path to a ready virtualenv Python.",
            install_hint
        ));
    }

    if diarization_enabled && !missing_diarization_for.is_empty() {
        let preferred = missing_diarization_for
            .first()
            .cloned()
            .unwrap_or_else(|| "python3".to_string());
        let install_hint = build_diarization_requirements_install_hint(script_path, &preferred);
        return Err(format!(
            "Diarization is enabled, but no Python runtime with `whisperx` + `pyannote.audio` was found. {} Or set Settings -> Diarization Python to a ready environment.",
            install_hint
        ));
    }

    Err(
        "Python executable not found. Set it in Settings -> Python path or install python3."
            .to_string(),
    )
}

fn inspect_python_runtime(candidate: &str) -> Option<PythonRuntimeCapabilities> {
    if Command::new(candidate).arg("--version").output().is_err() {
        return None;
    }

    let script = r#"
import importlib.util
import json

def has_spec(name):
    try:
        return importlib.util.find_spec(name) is not None
    except ModuleNotFoundError:
        return False
    except Exception:
        return False

print(json.dumps({
    "faster_whisper": has_spec("faster_whisper"),
    "whisperx": has_spec("whisperx"),
    "pyannote_audio": has_spec("pyannote.audio"),
}))
"#;

    let output = Command::new(candidate)
        .arg("-c")
        .arg(script)
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }

    let parsed = serde_json::from_slice::<PythonRuntimeCapabilitiesJson>(&output.stdout).ok()?;

    Some(PythonRuntimeCapabilities {
        has_faster_whisper: parsed.faster_whisper,
        has_whisperx: parsed.whisperx,
        has_pyannote_audio: parsed.pyannote_audio,
    })
}

fn discover_local_venv_python_candidates(script_path: &Path) -> Vec<String> {
    let mut results: Vec<String> = Vec::new();
    let mut roots: Vec<PathBuf> = Vec::new();

    for ancestor in script_path.ancestors() {
        roots.push(ancestor.to_path_buf());
    }

    if let Ok(current_dir) = std::env::current_dir() {
        for ancestor in current_dir.ancestors() {
            roots.push(ancestor.to_path_buf());
        }
    }

    if let Ok(exe_path) = std::env::current_exe() {
        for ancestor in exe_path.ancestors() {
            roots.push(ancestor.to_path_buf());
        }
    }

    let mut dedup: HashSet<PathBuf> = HashSet::new();
    for root in roots {
        if !dedup.insert(root.clone()) {
            continue;
        }

        for env_dir in [
            ".venv-diarization",
            ".venv-whisperx",
            ".venv-pyannote",
            ".venv",
        ] {
            let unix_candidate = root.join(env_dir).join("bin").join("python3");
            if unix_candidate.exists() {
                results.push(unix_candidate.to_string_lossy().into_owned());
            }

            let win_candidate = root.join(env_dir).join("Scripts").join("python.exe");
            if win_candidate.exists() {
                results.push(win_candidate.to_string_lossy().into_owned());
            }
        }
    }

    results
}

fn find_requirements_file(script_path: &Path) -> Option<PathBuf> {
    for ancestor in script_path.ancestors() {
        let candidate = ancestor.join("Scripts").join("requirements.txt");
        if candidate.exists() {
            return Some(candidate);
        }
    }

    if let Ok(current_dir) = std::env::current_dir() {
        for ancestor in current_dir.ancestors() {
            let candidate = ancestor.join("Scripts").join("requirements.txt");
            if candidate.exists() {
                return Some(candidate);
            }
        }
    }

    None
}

fn build_requirements_install_hint(script_path: &Path, python_bin: &str) -> String {
    if let Some(requirements) = find_requirements_file(script_path) {
        return format!(
            "Install dependencies with: \"{}\" -m pip install -r \"{}\"",
            python_bin,
            requirements.to_string_lossy()
        );
    }

    format!(
        "Install dependencies with: \"{}\" -m pip install -r Scripts/requirements.txt",
        python_bin
    )
}

fn find_diarization_requirements_file(script_path: &Path) -> Option<PathBuf> {
    for ancestor in script_path.ancestors() {
        let candidate = ancestor
            .join("Scripts")
            .join("requirements-diarization.txt");
        if candidate.exists() {
            return Some(candidate);
        }
    }

    if let Ok(current_dir) = std::env::current_dir() {
        for ancestor in current_dir.ancestors() {
            let candidate = ancestor
                .join("Scripts")
                .join("requirements-diarization.txt");
            if candidate.exists() {
                return Some(candidate);
            }
        }
    }

    None
}

fn build_diarization_requirements_install_hint(script_path: &Path, python_bin: &str) -> String {
    if let Some(requirements) = find_diarization_requirements_file(script_path) {
        return format!(
            "Install diarization dependencies with: \"{}\" -m pip install -r \"{}\"",
            python_bin,
            requirements.to_string_lossy()
        );
    }

    format!(
        "Install diarization dependencies with: \"{}\" -m pip install -r Scripts/requirements-diarization.txt",
        python_bin
    )
}

fn default_output_directory() -> PathBuf {
    documents_directory().join("VukhoAI").join("Exports")
}

fn legacy_default_output_directory() -> PathBuf {
    documents_directory().join("GhostMic").join("Exports")
}

fn documents_directory() -> PathBuf {
    dirs::document_dir()
        .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")))
}

fn migrate_output_folder_path_if_needed(path: &str) -> String {
    let trimmed = path.trim();
    if trimmed.is_empty() {
        return default_output_directory().to_string_lossy().into_owned();
    }

    let candidate = PathBuf::from(trimmed);
    if candidate == legacy_default_output_directory() {
        return default_output_directory().to_string_lossy().into_owned();
    }

    trimmed.to_string()
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

fn discover_runtime_roots() -> Vec<PathBuf> {
    let mut roots: Vec<PathBuf> = Vec::new();

    if let Ok(exe_path) = std::env::current_exe() {
        for ancestor in exe_path.ancestors() {
            roots.push(ancestor.to_path_buf());
        }
    }

    if let Ok(current_dir) = std::env::current_dir() {
        for ancestor in current_dir.ancestors() {
            roots.push(ancestor.to_path_buf());
        }
    }

    let mut dedup: HashSet<PathBuf> = HashSet::new();
    roots.into_iter().filter(|path| dedup.insert(path.clone())).collect()
}

fn resolve_portable_file(relative_candidates: &[&str]) -> Option<PathBuf> {
    for root in discover_runtime_roots() {
        for relative in relative_candidates {
            let candidate = root.join(relative);
            if candidate.exists() {
                return Some(candidate);
            }
        }
    }

    None
}

fn resolve_runtime_binary(binary_name: &str) -> String {
    if let Some(path) = resolve_portable_file(&[
        binary_name,
        &format!("tools/{binary_name}"),
        &format!("bin/{binary_name}"),
    ]) {
        return path.to_string_lossy().into_owned();
    }

    binary_name.to_string()
}

fn format_transcript(
    raw: &str,
    show_timestamps: bool,
    show_speakers: bool,
    speaker_aliases: &BTreeMap<String, String>,
) -> String {
    raw.lines()
        .map(|line| {
            format_transcript_line(line, show_timestamps, show_speakers, speaker_aliases)
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn format_transcript_line(
    line: &str,
    show_timestamps: bool,
    show_speakers: bool,
    speaker_aliases: &BTreeMap<String, String>,
) -> String {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return String::new();
    }

    if let Some((timestamp_content, speaker, text)) = parse_timestamped_transcript_line(trimmed) {
        if speaker.starts_with("SPEAKER_") {
            let display_name = resolve_speaker_display_name(speaker, speaker_aliases);
            match (show_timestamps, show_speakers) {
                (true, true) => {
                    return format!("[{timestamp_content}] {display_name}: {text}");
                }
                (true, false) => {
                    return format!("[{timestamp_content}] {text}");
                }
                (false, true) => {
                    return format!("{display_name}: {text}");
                }
                (false, false) => {
                    return text.to_string();
                }
            }
        }
    }

    trimmed.to_string()
}

fn parse_timestamped_transcript_line(line: &str) -> Option<(&str, &str, &str)> {
    let rest = line.strip_prefix('[')?;
    let close_idx = rest.find(']')?;
    let timestamp_content = &rest[..close_idx];
    let remainder = rest[close_idx + 1..].trim_start();
    let (speaker, text) = remainder.split_once(':')?;
    Some((timestamp_content, speaker.trim(), text.trim()))
}

fn normalize_speaker_aliases(aliases: BTreeMap<String, String>) -> BTreeMap<String, String> {
    aliases
        .into_iter()
        .filter_map(|(label, alias)| {
            let normalized_label = label.trim();
            let normalized_alias = alias.trim();
            if !normalized_label.starts_with("SPEAKER_") || normalized_alias.is_empty() {
                return None;
            }
            Some((normalized_label.to_string(), normalized_alias.to_string()))
        })
        .collect()
}

fn resolve_speaker_display_name(
    speaker_label: &str,
    speaker_aliases: &BTreeMap<String, String>,
) -> String {
    speaker_aliases
        .get(speaker_label)
        .map(String::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or(speaker_label)
        .to_string()
}

fn extract_transcript_speakers(
    raw: &str,
    speaker_aliases: &BTreeMap<String, String>,
) -> Vec<TranscriptSpeaker> {
    let mut seen: HashSet<String> = HashSet::new();
    let mut speakers = Vec::new();

    for line in raw.lines() {
        let Some((_, speaker, _)) = parse_timestamped_transcript_line(line.trim()) else {
            continue;
        };
        if !speaker.starts_with("SPEAKER_") || !seen.insert(speaker.to_string()) {
            continue;
        }

        speakers.push(TranscriptSpeaker {
            label: speaker.to_string(),
            alias: speaker_aliases.get(speaker).cloned().unwrap_or_default(),
        });
    }

    speakers
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

    if let Some(path) = resolve_portable_file(&["resources/transcribe.py", "transcribe.py"]) {
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

fn load_portable_state_seed() -> Option<PersistedState> {
    let seed_path = resolve_portable_file(&[
        PORTABLE_STATE_FILE_NAME,
        "resources/portable-state.json",
    ])?;
    let content = fs::read_to_string(seed_path).ok()?;
    let mut persisted = serde_json::from_str::<PersistedState>(&content).ok()?;
    persisted.jobs.clear();
    Some(persisted)
}

fn ensure_output_directory(settings: &mut AppSettings) -> Result<(), String> {
    let configured = settings.output_folder_path.trim();
    let default_output = default_output_directory();

    let mut candidates: Vec<PathBuf> = Vec::new();
    if !configured.is_empty() {
        candidates.push(PathBuf::from(configured));
    }
    if candidates
        .iter()
        .all(|candidate| candidate != &default_output)
    {
        candidates.push(default_output);
    }

    let mut last_error: Option<String> = None;
    for candidate in candidates {
        match fs::create_dir_all(&candidate) {
            Ok(_) => {
                settings.output_folder_path = candidate.to_string_lossy().into_owned();
                return Ok(());
            }
            Err(error) => {
                last_error = Some(error.to_string());
            }
        }
    }

    Err(format!(
        "Unable to create output directory: {}",
        last_error.unwrap_or_else(|| "unknown error".to_string())
    ))
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
    } else if let Some(seed) = load_portable_state_seed() {
        seed
    } else {
        PersistedState::defaults()
    };

    migrate_persisted_state(&mut persisted);

    // Recover any stale processing jobs after app restart.
    for job in &mut persisted.jobs {
        if job.status == JobStatus::Processing {
            job.status = JobStatus::Queued;
            job.error_message =
                Some("Recovered after app restart. Re-queued automatically.".to_string());
            job.progress_percent = None;
            job.progress_stage = None;
            job.progress_eta_seconds = None;
            job.processing_started_at = None;
            job.is_paused = false;
        }
    }

    ensure_output_directory(&mut persisted.settings)?;

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

fn migrate_persisted_state(persisted: &mut PersistedState) {
    if persisted.schema_version < 2 {
        if persisted.settings.language_mode == LanguageMode::Auto {
            persisted.settings.language_mode = LanguageMode::Ukrainian;
        }
        persisted.schema_version = 2;
    }

    if persisted.schema_version < STATE_SCHEMA_VERSION {
        persisted.schema_version = STATE_SCHEMA_VERSION;
    }
}

fn build_job_notice(core: &AppCore, meta_path: &str) -> Option<String> {
    let metadata_text = fs::read_to_string(meta_path).ok()?;
    let metadata = serde_json::from_str::<JobMetadata>(&metadata_text).ok()?;

    if !metadata.diarization_requested || metadata.diarization_applied {
        return None;
    }

    let mut message = String::from("Diarization was skipped.");
    let fallback_event = metadata
        .fallback_events
        .iter()
        .map(|event| event.trim())
        .find(|event| !event.is_empty());

    if let Some(event) = fallback_event {
        message.push(' ');
        if let Some(detail) = event.strip_prefix("whisperx unavailable: ") {
            message.push_str("WhisperX failed: ");
            message.push_str(detail.trim());
        } else {
            message.push_str(event);
        }
    } else if let Some(reason) = metadata
        .diarization_fallback_reason
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        message.push(' ');
        message.push_str(reason);
    }

    let missing_stack = metadata
        .fallback_events
        .iter()
        .any(|event| event.contains("module not installed"));
    if missing_stack {
        message.push(' ');
        message.push_str(
            "Install whisperx + pyannote into a separate Python 3.11/3.12 env, then set Settings -> Diarization Python.",
        );
    }

    let token_related = fallback_event.is_some_and(|event| {
        let lower = event.to_ascii_lowercase();
        lower.contains("hf token")
            || lower.contains("gatedrepo")
            || lower.contains("401")
            || lower.contains("authentication token")
    }) || metadata
        .diarization_fallback_reason
        .as_deref()
        .unwrap_or_default()
        .to_ascii_lowercase()
        .contains("hf token");

    if message.contains("HF token") || token_related {
        message.push(' ');
        message.push_str("Store the token in Settings -> Hugging Face token.");
    }

    if find_diarization_requirements_file(&core.script_path).is_some() && !message.ends_with('.') {
        message.push('.');
    }

    Some(message)
}

fn compute_audio_to_processing_ratio(
    duration_seconds: f64,
    processing_elapsed_seconds: f64,
) -> Option<f64> {
    if !duration_seconds.is_finite()
        || !processing_elapsed_seconds.is_finite()
        || duration_seconds <= 0.0
        || processing_elapsed_seconds <= 0.0
    {
        return None;
    }

    Some(duration_seconds / processing_elapsed_seconds)
}

fn persist_job_metrics_to_metadata(
    meta_path: &str,
    duration_seconds: f64,
    processing_elapsed_seconds: f64,
    audio_to_processing_ratio: Option<f64>,
) {
    let Ok(content) = fs::read_to_string(meta_path) else {
        return;
    };
    let Ok(mut value) = serde_json::from_str::<serde_json::Value>(&content) else {
        return;
    };
    let Some(object) = value.as_object_mut() else {
        return;
    };

    object.insert(
        "audio_duration_seconds".to_string(),
        serde_json::Value::from(duration_seconds),
    );
    object.insert(
        "processing_elapsed_seconds".to_string(),
        serde_json::Value::from(processing_elapsed_seconds),
    );
    object.insert(
        "audio_to_processing_ratio".to_string(),
        match audio_to_processing_ratio {
            Some(value) => serde_json::Value::from(value),
            None => serde_json::Value::Null,
        },
    );

    if let Ok(serialized) = serde_json::to_string_pretty(&value) {
        let _ = fs::write(meta_path, serialized);
    }
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
            pause_job,
            resume_job,
            delete_job,
            get_transcript_speakers,
            update_speaker_aliases,
            read_transcript,
            export_transcript,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
