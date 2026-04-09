# Windows GTX 1070 Setup Checklist

This checklist is for running GhostMic on a Windows machine with an NVIDIA GTX 1070 and enabling GPU-accelerated transcription when possible.

## 1. Install system prerequisites

Install the following:

- Node.js 20+
- Rust stable toolchain with MSVC
- Microsoft C++ Build Tools with `Desktop development with C++`
- Microsoft Edge WebView2 Runtime

Official references:

- Tauri prerequisites: https://v2.tauri.app/start/prerequisites/

## 2. Install Python

Recommended:

- Python 3.11

PyTorch on Windows officially supports Python 3.10-3.14.

Official reference:

- PyTorch install guide: https://pytorch.org/get-started/locally/

## 3. Create the main Python environment

From the repository root:

```powershell
cd "C:\path\to\GhostMic"
py -3.11 -m venv .venv
.venv\Scripts\activate
python -m pip install --upgrade pip
pip install -r Scripts\requirements.txt
```

## 4. Verify that PyTorch can see the GPU

Run:

```powershell
python
```

Then:

```python
import torch
print(torch.__version__)
print(torch.cuda.is_available())
print(torch.cuda.get_device_name(0) if torch.cuda.is_available() else "no gpu")
```

Expected result:

- `torch.cuda.is_available()` returns `True`
- the device name shows your NVIDIA GPU, such as `GeForce GTX 1070`

## 5. If CUDA is not detected, reinstall PyTorch with a CUDA build

If `torch.cuda.is_available()` returns `False`, install a CUDA-enabled PyTorch wheel.

Use the current selector on the official PyTorch page:

- https://pytorch.org/get-started/locally/

Example command for CUDA 11.8:

```powershell
pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118
```

For a GTX 1070, CUDA 11.8 is a practical starting point if newer CUDA builds cause compatibility issues.

This is an engineering recommendation based on typical Pascal-generation GPU compatibility, not a PyTorch requirement.

## 6. Create a separate diarization environment

If you want real speaker diarization with WhisperX and pyannote, use a separate environment:

```powershell
cd "C:\path\to\GhostMic"
py -3.11 -m venv .venv-diarization
.venv-diarization\Scripts\activate
python -m pip install --upgrade pip
pip install -r Scripts/requirements-diarization.txt
```

## 7. Verify GPU support in the diarization environment

Inside `.venv-diarization`:

```powershell
python
```

```python
import torch
print(torch.cuda.is_available())
print(torch.cuda.get_device_name(0) if torch.cuda.is_available() else "no gpu")
```

## 8. Configure Hugging Face access for pyannote

For diarization, do all of the following:

- sign in to Hugging Face
- request or accept access for `pyannote/speaker-diarization-community-1`
- create a Hugging Face token with read access

Then store the token in GhostMic settings.

## 9. Configure GhostMic settings

In the app, set:

- `Python path` -> `C:\path\to\GhostMic\.venv\Scripts\python.exe`
- `Diarization Python` -> `C:\path\to\GhostMic\.venv-diarization\Scripts\python.exe`
- `Hugging Face token` -> your token

## 10. Run the Tauri app in development

```powershell
cd "C:\path\to\GhostMic\ghostmic-cross"
npm install
npm run tauri dev
```

## 11. How GhostMic uses the GPU

GhostMic currently auto-detects NVIDIA CUDA in the Python transcription pipeline:

- `faster-whisper` uses `ctranslate2` CUDA detection
- `whisperx` uses `torch.cuda.is_available()`

If CUDA is available and compatible, the app should use the GPU automatically.

## 12. How to confirm that GPU acceleration is active

Look for a runtime notice similar to:

```text
Using NVIDIA CUDA acceleration for faster-whisper (...)
```

If you do not see that, the pipeline may have fallen back to CPU.

## 13. Recommended rollout order

To reduce setup complexity:

1. Get plain transcription working first.
2. Confirm that the main environment uses the GPU.
3. Only then enable WhisperX + pyannote diarization.

## 14. If GPU acceleration still does not work

Check these in order:

1. NVIDIA drivers are installed and up to date.
2. `torch.cuda.is_available()` returns `True` in the exact environment used by the app.
3. The environment contains a CUDA-enabled PyTorch build, not a CPU-only one.
4. GhostMic settings point to the correct `python.exe`.
5. The diarization environment is separate and correctly configured.

## References

- PyTorch: https://pytorch.org/get-started/locally/
- Tauri prerequisites: https://v2.tauri.app/start/prerequisites/
- CTranslate2 installation: https://opennmt.net/CTranslate2/installation.html
