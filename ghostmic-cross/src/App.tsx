import { useCallback, useEffect, useMemo, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { open, save } from "@tauri-apps/plugin-dialog";
import "./App.css";

type JobStatus = "queued" | "processing" | "done" | "failed" | "cancelled";
type Profile = "maximum_quality" | "balanced" | "fast_economy";
type LanguageMode = "auto" | "ukrainian";

interface ImportJob {
  id: string;
  input_path: string;
  input_filename: string;
  normalized_audio_path?: string | null;
  status: JobStatus;
  created_at: string;
  duration_seconds?: number | null;
  profile: Profile;
  language_mode: LanguageMode;
  diarization_enabled: boolean;
  output_txt_path?: string | null;
  meta_json_path?: string | null;
  error_message?: string | null;
  notice_message?: string | null;
  processing_elapsed_seconds?: number | null;
  audio_to_processing_ratio?: number | null;
  progress_percent?: number | null;
  progress_stage?: string | null;
  progress_eta_seconds?: number | null;
  processing_started_at?: string | null;
  is_paused?: boolean;
}

interface AppSettings {
  default_profile: Profile;
  language_mode: LanguageMode;
  diarization_enabled: boolean;
  output_folder_path: string;
  python_path?: string | null;
  diarization_python_path?: string | null;
  huggingface_token?: string | null;
  openai_model: string;
  openai_api_key?: string | null;
}

interface AppSnapshot {
  jobs: ImportJob[];
  settings: AppSettings;
}

type ListFilter = "all" | "completed_only";

const JOBS_EVENT = "ghostmic://jobs-updated";
const SETTINGS_EVENT = "ghostmic://settings-updated";

const profileLabels: Record<Profile, string> = {
  maximum_quality: "Maximum Quality",
  balanced: "Balanced",
  fast_economy: "Fast / Economy",
};

const languageLabels: Record<LanguageMode, string> = {
  auto: "Auto",
  ukrainian: "Force Ukrainian",
};

function App() {
  const [jobs, setJobs] = useState<ImportJob[]>([]);
  const [settings, setSettings] = useState<AppSettings | null>(null);
  const [selectedInputPath, setSelectedInputPath] = useState<string>("");
  const [listFilter, setListFilter] = useState<ListFilter>("all");
  const [errorMessage, setErrorMessage] = useState<string>("");
  const [liveTick, setLiveTick] = useState<number>(Date.now());

  const [settingsOpen, setSettingsOpen] = useState(false);
  const [settingsDraft, setSettingsDraft] = useState<AppSettings | null>(null);
  const [settingsStatus, setSettingsStatus] = useState<string>("");

  const [transcriptJobId, setTranscriptJobId] = useState<string | null>(null);
  const [showSpeakers, setShowSpeakers] = useState(true);
  const [showTimestamps, setShowTimestamps] = useState(true);
  const [transcriptText, setTranscriptText] = useState("");
  const [transcriptLoading, setTranscriptLoading] = useState(false);

  const activeTranscriptJob = useMemo(
    () => jobs.find((job) => job.id === transcriptJobId) ?? null,
    [jobs, transcriptJobId],
  );

  const filteredJobs = useMemo(() => {
    if (listFilter === "completed_only") {
      return jobs.filter((job) => job.status === "done");
    }
    return jobs;
  }, [jobs, listFilter]);

  const loadInitialState = useCallback(async () => {
    const snapshot = await invoke<AppSnapshot>("get_state");
    setJobs(snapshot.jobs);
    setSettings(snapshot.settings);
    setSettingsDraft(snapshot.settings);
  }, []);

  const loadTranscript = useCallback(
    async (jobId: string, withTimestamps: boolean, withSpeakers: boolean) => {
      setTranscriptLoading(true);
      setErrorMessage("");
      try {
        const text = await invoke<string>("read_transcript", {
          jobId,
          showTimestamps: withTimestamps,
          showSpeakers: withSpeakers,
        });
        setTranscriptText(text);
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        setErrorMessage(message);
      } finally {
        setTranscriptLoading(false);
      }
    },
    [],
  );

  useEffect(() => {
    void loadInitialState();

    const interval = setInterval(() => {
      setLiveTick(Date.now());
    }, 5000);

    let stopJobs: (() => void) | null = null;
    let stopSettings: (() => void) | null = null;

    void (async () => {
      stopJobs = await listen<ImportJob[]>(JOBS_EVENT, (event) => {
        setJobs(event.payload);
      });

      stopSettings = await listen<AppSettings>(SETTINGS_EVENT, (event) => {
        setSettings(event.payload);
        setSettingsDraft(event.payload);
      });
    })();

    return () => {
      clearInterval(interval);
      stopJobs?.();
      stopSettings?.();
    };
  }, [loadInitialState]);

  useEffect(() => {
    if (!transcriptJobId) {
      return;
    }
    void loadTranscript(transcriptJobId, showTimestamps, showSpeakers);
  }, [transcriptJobId, showTimestamps, showSpeakers, loadTranscript]);

  async function pickInputFile() {
    setErrorMessage("");
    const picked = await open({
      multiple: false,
      filters: [
        {
          name: "Audio/Video",
          extensions: ["m4a", "mp4"],
        },
      ],
    });

    if (typeof picked === "string") {
      setSelectedInputPath(picked);
    }
  }

  async function enqueueSelected() {
    if (!selectedInputPath) {
      setErrorMessage("Select file first.");
      return;
    }

    const duplicate = jobs.some(
      (job) =>
        job.input_path.toLowerCase() === selectedInputPath.toLowerCase() ||
        job.input_filename.toLowerCase() === basename(selectedInputPath).toLowerCase(),
    );

    if (duplicate) {
      const accepted = window.confirm(
        "This file (or filename) is already in the list. Transcribe anyway?",
      );
      if (!accepted) {
        return;
      }
    }

    setErrorMessage("");
    try {
      await invoke("enqueue_job", { inputPath: selectedInputPath });
      setSelectedInputPath("");
    } catch (error) {
      setErrorMessage(error instanceof Error ? error.message : String(error));
    }
  }

  async function retryJob(jobId: string) {
    setErrorMessage("");
    try {
      await invoke("retry_job", { jobId });
    } catch (error) {
      setErrorMessage(error instanceof Error ? error.message : String(error));
    }
  }

  async function reTranscribe(jobId: string) {
    setErrorMessage("");
    try {
      await invoke("re_transcribe", { jobId });
    } catch (error) {
      setErrorMessage(error instanceof Error ? error.message : String(error));
    }
  }

  async function cancelJob(jobId: string) {
    setErrorMessage("");
    try {
      await invoke("cancel_job", { jobId });
    } catch (error) {
      setErrorMessage(error instanceof Error ? error.message : String(error));
    }
  }

  async function pauseJob(jobId: string) {
    setErrorMessage("");
    try {
      await invoke("pause_job", { jobId });
    } catch (error) {
      setErrorMessage(error instanceof Error ? error.message : String(error));
    }
  }

  async function resumeJob(jobId: string) {
    setErrorMessage("");
    try {
      await invoke("resume_job", { jobId });
    } catch (error) {
      setErrorMessage(error instanceof Error ? error.message : String(error));
    }
  }

  async function deleteJob(job: ImportJob) {
    const prompt =
      job.status === "processing"
        ? `Delete ${job.input_filename}? It will be cancelled and fully removed.`
        : `Delete ${job.input_filename}? This removes it from queue and list.`;

    if (!window.confirm(prompt)) {
      return;
    }

    setErrorMessage("");
    try {
      await invoke("delete_job", { jobId: job.id });
      if (transcriptJobId === job.id) {
        closeTranscript();
      }
    } catch (error) {
      setErrorMessage(error instanceof Error ? error.message : String(error));
    }
  }

  async function openTranscript(jobId: string) {
    setShowSpeakers(true);
    setShowTimestamps(true);
    setTranscriptText("");
    setTranscriptJobId(jobId);
    await loadTranscript(jobId, true, true);
  }

  function closeTranscript() {
    setTranscriptJobId(null);
    setTranscriptText("");
    setTranscriptLoading(false);
  }

  async function copyTranscript() {
    try {
      await navigator.clipboard.writeText(transcriptText);
    } catch {
      setErrorMessage("Unable to copy transcript to clipboard.");
    }
  }

  async function exportTranscript() {
    if (!transcriptJobId || !activeTranscriptJob) {
      return;
    }

    const base = basename(activeTranscriptJob.input_filename).replace(/\.[^.]+$/, "");
    const suggested = `${base}-export.txt`;

    const destination = await save({
      defaultPath: suggested,
      filters: [{ name: "Text", extensions: ["txt"] }],
    });

    if (!destination) {
      return;
    }

    setErrorMessage("");
    try {
      await invoke("export_transcript", {
        jobId: transcriptJobId,
        destinationPath: destination,
        showTimestamps,
        showSpeakers,
      });
    } catch (error) {
      setErrorMessage(error instanceof Error ? error.message : String(error));
    }
  }

  function openSettings() {
    if (settings) {
      setSettingsDraft(settings);
      setSettingsStatus("");
    }
    setSettingsOpen(true);
  }

  function closeSettings() {
    setSettingsOpen(false);
    setSettingsStatus("");
    setErrorMessage("");
  }

  async function pickOutputFolder() {
    if (!settingsDraft) {
      return;
    }

    const picked = await open({
      directory: true,
      multiple: false,
      defaultPath: settingsDraft.output_folder_path,
    });

    if (typeof picked === "string") {
      setSettingsDraft({ ...settingsDraft, output_folder_path: picked });
    }
  }

  async function saveSettings() {
    if (!settingsDraft) {
      return;
    }

    setErrorMessage("");
    setSettingsStatus("");

    try {
      const updated = await invoke<AppSettings>("update_settings", {
        payload: settingsDraft,
      });
      setSettings(updated);
      setSettingsDraft(updated);
      setSettingsStatus("Settings saved.");
    } catch (error) {
      setErrorMessage(error instanceof Error ? error.message : String(error));
    }
  }

  return (
    <div className="app-shell">
      <header className="topbar">
        <div>
          <h1>Vukho.AI</h1>
          <p>Offline transcription (.m4a/.mp4) for macOS and Windows.</p>
        </div>
        <button onClick={openSettings}>Settings</button>
      </header>

      <section className="panel import-panel">
        <h2>Import</h2>
        <div className="import-controls">
          <input
            type="text"
            value={selectedInputPath}
            placeholder="No file selected"
            readOnly
          />
          <button onClick={pickInputFile}>Import File...</button>
          <button className="primary" onClick={enqueueSelected}>
            Transcribe
          </button>
        </div>
      </section>

      <section className="panel list-panel">
        <div className="list-header">
          <h2>Queue and Transcriptions</h2>
          <div className="filters">
            <button
              className={listFilter === "all" ? "active" : ""}
              onClick={() => setListFilter("all")}
            >
              All
            </button>
            <button
              className={listFilter === "completed_only" ? "active" : ""}
              onClick={() => setListFilter("completed_only")}
            >
              Completed only
            </button>
          </div>
        </div>

        <div className="job-list">
          {filteredJobs.length === 0 && <p className="empty">No items yet.</p>}

          {filteredJobs.map((job) => {
            const etaSeconds = estimatedEtaSeconds(job, liveTick);

            return (
              <article className="job-row" key={job.id}>
                <div className="job-main">
                  <div className="job-title">{job.input_filename}</div>
                  <div className="job-meta">
                    <span>{formatDate(job.created_at)}</span>
                    <span>{durationText(job, liveTick)}</span>
                    {processingTimeText(job) && <span>{processingTimeText(job)}</span>}
                    {processingRatioText(job) && <span>{processingRatioText(job)}</span>}
                    <span>{profileLabels[job.profile]}</span>
                  </div>

                  {job.status === "processing" && (
                    <div className="progress-wrap">
                      <progress
                        max={100}
                        value={Math.max(0, Math.min(100, job.progress_percent ?? 0))}
                      />
                      <div className="progress-meta">
                        <span>{Math.round(job.progress_percent ?? 0)}%</span>
                        {etaSeconds !== null && <span>ETA ~ {formatClock(etaSeconds)}</span>}
                        {job.progress_stage && <span>{job.progress_stage}</span>}
                      </div>
                    </div>
                  )}

                  {job.error_message && (
                    <div className="error-text">{job.error_message}</div>
                  )}
                  {job.notice_message && !job.error_message && (
                    <div className="notice-text">{job.notice_message}</div>
                  )}
                </div>

                <div className="job-side">
                  <span
                    className={`status ${job.status} ${
                      job.status === "processing" && job.is_paused ? "paused" : ""
                    }`}
                  >
                    {statusText(job)}
                  </span>
                  <div className="actions">
                    {job.status === "done" && (
                      <>
                        <button onClick={() => openTranscript(job.id)}>Open</button>
                        <button onClick={() => reTranscribe(job.id)}>Re-transcribe</button>
                      </>
                    )}

                    {job.status === "queued" && (
                      <button onClick={() => cancelJob(job.id)}>Cancel</button>
                    )}

                    {job.status === "processing" && (
                      <>
                        {job.is_paused ? (
                          <button onClick={() => resumeJob(job.id)}>Resume</button>
                        ) : (
                          <button onClick={() => pauseJob(job.id)}>Pause</button>
                        )}
                        <button onClick={() => cancelJob(job.id)}>Cancel</button>
                      </>
                    )}

                    {(job.status === "failed" || job.status === "cancelled") && (
                      <button onClick={() => retryJob(job.id)}>Retry</button>
                    )}

                    <button className="danger" onClick={() => deleteJob(job)}>
                      Delete
                    </button>
                  </div>
                </div>
              </article>
            );
          })}
        </div>
      </section>

      {errorMessage && <div className="banner error">{errorMessage}</div>}

      {transcriptJobId && (
        <div className="modal-backdrop" onClick={closeTranscript}>
          <div className="modal transcript-modal" onClick={(e) => e.stopPropagation()}>
            <div className="modal-header">
              <h3>Transcript</h3>
              <button onClick={closeTranscript}>Close</button>
            </div>

            <div className="toggle-row">
              <label>
                <input
                  type="checkbox"
                  checked={showSpeakers}
                  onChange={(e) => setShowSpeakers(e.target.checked)}
                />
                Show speakers
              </label>
              <label>
                <input
                  type="checkbox"
                  checked={showTimestamps}
                  onChange={(e) => setShowTimestamps(e.target.checked)}
                />
                Show timestamps
              </label>
            </div>

            <div className="transcript-body">
              {transcriptLoading ? "Loading..." : transcriptText || "Transcript is empty."}
            </div>

            <div className="modal-actions">
              <button onClick={copyTranscript}>Copy</button>
              <button onClick={exportTranscript}>Export TXT</button>
            </div>
          </div>
        </div>
      )}

      {settingsOpen && settingsDraft && (
        <div className="modal-backdrop" onClick={closeSettings}>
          <div className="modal settings-modal" onClick={(e) => e.stopPropagation()}>
            <div className="modal-header">
              <h3>Settings</h3>
              <button onClick={closeSettings}>Close</button>
            </div>

            <div className="settings-grid">
              <label>
                Quality profile
                <select
                  value={settingsDraft.default_profile}
                  onChange={(e) =>
                    setSettingsDraft({
                      ...settingsDraft,
                      default_profile: e.target.value as Profile,
                    })
                  }
                >
                  <option value="maximum_quality">Maximum Quality</option>
                  <option value="balanced">Balanced</option>
                  <option value="fast_economy">Fast / Economy</option>
                </select>
              </label>

              <label>
                Language
                <select
                  value={settingsDraft.language_mode}
                  onChange={(e) =>
                    setSettingsDraft({
                      ...settingsDraft,
                      language_mode: e.target.value as LanguageMode,
                    })
                  }
                >
                  <option value="auto">Auto</option>
                  <option value="ukrainian">Force Ukrainian</option>
                </select>
              </label>

              <label className="checkbox-row">
                <input
                  type="checkbox"
                  checked={settingsDraft.diarization_enabled}
                  onChange={(e) =>
                    setSettingsDraft({
                      ...settingsDraft,
                      diarization_enabled: e.target.checked,
                    })
                  }
                />
                Enable diarization
              </label>

              <label>
                Output folder
                <div className="path-row">
                  <input
                    type="text"
                    value={settingsDraft.output_folder_path}
                    onChange={(e) =>
                      setSettingsDraft({
                        ...settingsDraft,
                        output_folder_path: e.target.value,
                      })
                    }
                  />
                  <button onClick={pickOutputFolder}>Browse...</button>
                </div>
              </label>

              <label>
                Python path (optional)
                <input
                  type="text"
                  value={settingsDraft.python_path ?? ""}
                  onChange={(e) =>
                    setSettingsDraft({
                      ...settingsDraft,
                      python_path: e.target.value,
                    })
                  }
                  placeholder="Leave empty to use python3/python"
                />
              </label>

              <label>
                Diarization Python (optional)
                <input
                  type="text"
                  value={settingsDraft.diarization_python_path ?? ""}
                  onChange={(e) =>
                    setSettingsDraft({
                      ...settingsDraft,
                      diarization_python_path: e.target.value,
                    })
                  }
                  placeholder="Recommended: separate Python 3.11/3.12 env with whisperx + pyannote"
                />
              </label>

              <label>
                Hugging Face token (for pyannote)
                <input
                  type="password"
                  value={settingsDraft.huggingface_token ?? ""}
                  onChange={(e) =>
                    setSettingsDraft({
                      ...settingsDraft,
                      huggingface_token: e.target.value,
                    })
                  }
                  placeholder="Needed if pyannote models are not already cached"
                />
              </label>

              <label>
                OpenAI model (stored)
                <input
                  type="text"
                  value={settingsDraft.openai_model}
                  onChange={(e) =>
                    setSettingsDraft({
                      ...settingsDraft,
                      openai_model: e.target.value,
                    })
                  }
                />
              </label>

              <label>
                OpenAI API key (stored)
                <input
                  type="password"
                  value={settingsDraft.openai_api_key ?? ""}
                  onChange={(e) =>
                    setSettingsDraft({
                      ...settingsDraft,
                      openai_api_key: e.target.value,
                    })
                  }
                />
              </label>
            </div>

            <div className="settings-note">
              Speaker diarization needs a Python env with `whisperx` + `pyannote.audio`.
              The app will auto-try `.venv-diarization`, but you can point to any ready env here.
            </div>

            {settingsStatus && <div className="banner ok">{settingsStatus}</div>}

            <div className="modal-actions">
              <button className="primary" onClick={saveSettings}>
                Save
              </button>
            </div>
          </div>
        </div>
      )}

      <footer className="footnote">
        <span>
          Cross-platform mode uses the local Python pipeline and runs jobs one-by-one.
        </span>
        <span>
          Language: {settings ? languageLabels[settings.language_mode] : "-"}
        </span>
      </footer>
    </div>
  );
}

function basename(path: string): string {
  const normalized = path.replace(/\\/g, "/");
  return normalized.split("/").filter(Boolean).pop() ?? path;
}

function formatDate(value: string): string {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return value;
  }
  return date.toLocaleString();
}

function processingTimeText(job: ImportJob): string | null {
  const seconds = job.processing_elapsed_seconds;
  if (typeof seconds !== "number" || !Number.isFinite(seconds) || seconds <= 0) {
    return null;
  }

  return `Processed in: ${formatClock(seconds)}`;
}

function processingRatioText(job: ImportJob): string | null {
  const ratio = job.audio_to_processing_ratio;
  if (typeof ratio !== "number" || !Number.isFinite(ratio) || ratio <= 0) {
    return null;
  }

  return `Ratio: ${ratio.toFixed(2)}x`;
}

function durationText(job: ImportJob, liveTick: number): string {
  if (job.status === "processing" && job.processing_started_at) {
    const started = new Date(job.processing_started_at).getTime();
    if (!Number.isNaN(started)) {
      const elapsedSec = Math.max(0, Math.floor((liveTick - started) / 1000));
      return `Elapsed: ${formatClock(elapsedSec)}`;
    }
  }

  if (job.duration_seconds && Number.isFinite(job.duration_seconds) && job.duration_seconds > 0) {
    return `Duration: ${formatClock(job.duration_seconds)}`;
  }

  return "Duration: --";
}

function estimatedEtaSeconds(job: ImportJob, liveTick: number): number | null {
  if (
    typeof job.progress_eta_seconds === "number" &&
    Number.isFinite(job.progress_eta_seconds) &&
    job.progress_eta_seconds > 0
  ) {
    return job.progress_eta_seconds;
  }

  if (job.status !== "processing" || !job.processing_started_at) {
    return null;
  }

  const percent = job.progress_percent ?? 0;
  if (!Number.isFinite(percent) || percent <= 1 || percent >= 99.5) {
    return null;
  }

  const started = new Date(job.processing_started_at).getTime();
  if (Number.isNaN(started)) {
    return null;
  }

  const elapsedSeconds = Math.max(0, (liveTick - started) / 1000);
  if (!Number.isFinite(elapsedSeconds) || elapsedSeconds < 3) {
    return null;
  }

  const estimatedRemaining = (elapsedSeconds * (100 - percent)) / percent;
  if (!Number.isFinite(estimatedRemaining) || estimatedRemaining < 0) {
    return null;
  }

  return estimatedRemaining;
}

function formatClock(inputSeconds: number): string {
  const total = Math.max(0, Math.floor(inputSeconds));
  const hours = Math.floor(total / 3600)
    .toString()
    .padStart(2, "0");
  const minutes = Math.floor((total % 3600) / 60)
    .toString()
    .padStart(2, "0");
  const seconds = Math.floor(total % 60)
    .toString()
    .padStart(2, "0");
  return `${hours}:${minutes}:${seconds}`;
}

function statusText(job: ImportJob): string {
  if (job.status === "processing" && job.is_paused) {
    return "paused";
  }
  return job.status;
}

export default App;
