# Vukho.AI MVP

![Vukho.AI GitHub logo](branding/vukhoai-github-logo.svg)

Локальний (офлайн) macOS застосунок для імпорту `.m4a/.mp4` і отримання TXT-транскрипції з таймкодами та спікерами.

## Cross-platform (macOS + Windows)

Додано окремий Tauri застосунок у папці `ghostmic-cross/`.

- Документація запуску: [ghostmic-cross/README.md](ghostmic-cross/README.md)
- Dev запуск:

```bash
cd ghostmic-cross
npm install
npm run tauri dev
```

## Що вміє MVP

- Імпорт через Drag & Drop або `Import File...`
- Підтримка форматів: `.m4a`, `.mp4`
- Для `.mp4` локально витягується аудіо (AVFoundation)
- Черга задач зі статусами: `queued`, `processing`, `done`, `failed`
- Керування задачами: `Pause`, `Resume`, `Cancel`
- Live-прогрес: `%` + орієнтовний `ETA`
- Для готових результатів є `Re-transcribe` (створює нову задачу на той самий файл)
- Підтримка OpenAI API для генерації протоколу зустрічі (`Generate Protocol` -> `View Protocol`)
- Простий фільтр списку: `All` / `Completed only`
- Видалення записів (`Delete`) з повним прибиранням із черги/списку
- Профілі якості:
  - `Maximum Quality` (дефолт): `large-v3`
  - `Balanced`: `medium`
  - `Fast / Economy`: `small`
- Мова: `Auto` або примусово `Ukrainian`
- Діаризація з fallback на `SPEAKER_01`, якщо недоступна
- Формат TXT:

```txt
[00:01:12.340 - 00:01:18.905] SPEAKER_01: Текст фрази...
```

- Перегляд транскрипції з toggle:
  - показувати/приховувати `SPEAKER_XX`
  - показувати/приховувати таймкоди
- `Copy` і `Export TXT` беруть саме поточний формат відображення

---

## Вимоги

- macOS 13+
- Xcode Command Line Tools (або повний Xcode)
- Python 3.10+ (для optional diarization краще окремий env на Python 3.11/3.12)
- Бажано Apple Silicon

Перевірка:

```bash
swift --version
python3 --version
```

---

## 1) Встановлення Python-залежностей

### Базовий (рекомендований для MVP)

У корені проєкту:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r Scripts/requirements.txt
```

Це встановить робочий офлайн транскрайб (`faster-whisper`).

### Optional: стек діаризації (whisperx/pyannote)

```bash
source .venv/bin/activate
pip install -r Scripts/requirements-diarization.txt
```

Примітка: цей стек може вимагати окремий Python env та додаткове налаштування моделей/токенів.

За потреби для моделей:

```bash
export HF_TOKEN=ваш_токен
```

---

## 2) Збірка та запуск

```bash
swift build
swift run VukhoAI
```

Рекомендовано запускати так:

```bash
source .venv/bin/activate
swift run VukhoAI
```

Якщо потрібно примусово вказати Python для app:

```bash
export VUKHOAI_PYTHON="/Users/admin/Documents/Development - Codex/GhostMic/.venv/bin/python3"
swift run VukhoAI
```

---

## 3) Як користуватись (MVP flow)

1. Відкрийте `Vukho.AI`.
2. Додайте файл (`.m4a` або `.mp4`) через drag & drop або `Import File...`.
3. Натисніть `Transcribe` (якщо файл уже є в списку, з'явиться підтвердження `Transcribe Anyway` / `Cancel`).
4. Дочекайтесь зміни статусу: `queued` → `processing` → `done` або `failed`.
5. Для `done` натисніть `Open`.
6. У вікні перегляду:
   - вмикайте/вимикайте `Show speakers` і `Show timestamps`;
   - `Copy` копіює поточне відображення;
   - `Export TXT` експортує поточне відображення в `.txt`.
7. Під час `processing` можна `Pause/Resume/Cancel`.
8. Для `failed` натисніть `Retry`.
9. Для `done` можна натиснути `Re-transcribe`, щоб перезапустити транскрибацію того ж файлу.
10. Кнопка `Delete` повністю видаляє запис зі списку (для `processing` спочатку скасовує, потім видаляє).
11. Над списком є фільтр `All / Completed only`.

---

## 4) Налаштування

Відкрити `Settings` можна:
- кнопкою `Settings` на головному екрані (відкриває модальне вікно в застосунку);
- через меню macOS `Vukho.AI -> Settings...`;
- шорткатом `Cmd + ,`.

В `Settings`:

- `Quality profile`: `Maximum Quality` (default), `Balanced`, `Fast / Economy`
- `Language`: `Auto` або `Force Ukrainian`
- `Enable diarization`: увімк/вимк
- `Output folder`: папка для `.txt`
- `AI Protocols`:
  - OpenAI model
  - OpenAI API key (save/clear)
  - `Test Connection`

---

## 5) Де зберігаються дані

- SQLite БД черги та службові файли: `~/Library/Application Support/VukhoAI/`
- Експортовані TXT: папка з `Settings -> Output folder`

---

## 6) Типові проблеми

### `Missing Python dependencies...`

Виконайте:

```bash
cd "/Users/admin/Documents/Development - Codex/GhostMic"
source .venv/bin/activate
pip install -r Scripts/requirements.txt
export VUKHOAI_PYTHON="/Users/admin/Documents/Development - Codex/GhostMic/.venv/bin/python3"
swift run VukhoAI
```

Після цього в UI натисніть `Retry` на failed задачі.

### Немає діаризації (всі `SPEAKER_01`)

Це fallback, якщо `whisperx/pyannote` недоступні. Транскрипція при цьому все одно генерується.

### Повільна обробка

Для `Maximum Quality` це очікувано. Для швидшої роботи перемкніть профіль на `Balanced` або `Fast / Economy`.

---

## 7) Команди швидкого старту (копіпаст)

```bash
cd "/Users/admin/Documents/Development - Codex/GhostMic"
python3 -m venv .venv
source .venv/bin/activate
pip install -r Scripts/requirements.txt
export VUKHOAI_PYTHON="/Users/admin/Documents/Development - Codex/GhostMic/.venv/bin/python3"
swift run VukhoAI
```


---

## 8) Протокол (OpenAI API)

1. У `Settings -> AI Protocols` збережіть OpenAI API key і перевірте `Test Connection`.
2. Після успішної транскрипції (`done`) натисніть `Generate Protocol`.
3. Під час генерації в рядку задачі показується індикатор.
4. Після успіху кнопка зміниться на `View Protocol`.
5. Протокол відкривається в окремому вікні (rich markdown view) і його можна скопіювати.
6. Якщо API поверне помилку, вона відобразиться в інтерфейсі (`Protocol error`).

Протоколи зберігаються у: `Output folder/Protocols/`
