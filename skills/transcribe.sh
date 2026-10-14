#!/usr/bin/env bash
# Расшифровка голосового сообщения в текст.
#
# ВКонтакте расшифровывает голосовые сам, но боту поле transcript не отдаёт:
# 12.10 проверено живьём — приходит только файл. Поэтому распознаём у себя.
#
# whisper.cpp собран в /opt/whisper.cpp. Модель выбирается по свободной памяти:
# small (465 МБ) точнее, base (141 МБ) — запасной путь, когда памяти мало.
#
# Имена переменных латиницей: bash не принимает кириллицу в именах.
# Запуск:  transcribe.sh путь-к-файлу.ogg
# Печатает распознанный текст в stdout. Молчит, если не вышло.

set -euo pipefail

WHISPER=/opt/whisper.cpp/build/bin/whisper-cli
MODEL_SMALL=/opt/whisper.cpp/models/ggml-small.bin
MODEL_BASE=/opt/whisper.cpp/models/ggml-base.bin

# Модель выбирается по свободной памяти. small слышит русский заметно лучше
# (base выдал «в телеверном проверке Магарадин» там, где small — «в телеграмм,
# проверка номер один»), но держит ~700 МБ и работает вчетверо дольше.
# На машине всего 1,9 ГБ и сессии Claude занимают половину, поэтому когда
# свободного меньше 900 МБ — берём base: хуже расшифровка лучше, чем падение
# приёмника от нехватки памяти.
svobodno=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
if [ "${svobodno:-0}" -ge 900 ] && [ -f "$MODEL_SMALL" ]; then
  MODEL="$MODEL_SMALL"
else
  MODEL="$MODEL_BASE"
fi

fayl="${1:-}"
[ -n "$fayl" ] || { echo "использование: transcribe.sh файл.ogg" >&2; exit 1; }
[ -f "$fayl" ] || { echo "нет файла: $fayl" >&2; exit 1; }

if [ ! -x "$WHISPER" ] || [ ! -f "$MODEL" ]; then
  echo "whisper.cpp не установлен — расшифровать нечем" >&2
  exit 1
fi

# Whisper принимает только 16 кГц моно WAV, а ВК отдаёт ogg.
wav="$(mktemp --suffix=.wav)"
trap 'rm -f "$wav"' EXIT
ffmpeg -v error -i "$fayl" -ar 16000 -ac 1 -c:a pcm_s16le "$wav" -y

# -nt убирает отметки времени, они здесь не нужны.
# Один поток: на двух ядрах распознавание и так укладывается в секунды,
# а свободная память дороже скорости.
"$WHISPER" -m "$MODEL" -l ru -t 1 -nt -f "$wav" 2>/dev/null | sed 's/^[[:space:]]*//' | sed '/^$/d'
