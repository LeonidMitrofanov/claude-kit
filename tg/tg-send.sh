#!/usr/bin/env bash
# Отправка сообщения в тему группы. Заодно дописывает его в файл переписки,
# чтобы dialog/ был полной стенограммой, а не половиной разговора.
#
# Использование:
#   tg-send.sh <topic_id|general> <текст…>
#   echo "текст" | tg-send.sh <topic_id|general>
#
# topic_id берётся из dialog/TOPICS.md или из входящего сообщения.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

TOPIC="${1:-general}"; shift || true

FILE=""
REPLY_TO=""
while true; do
  case "${1:-}" in
    --file)  FILE="${2:-}"; shift 2; [ -f "$FILE" ] || { echo "файл не найден: ${FILE}" >&2; exit 1; } ;;
    --reply) REPLY_TO="${2:-}"; shift 2 ;;
    *) break ;;
  esac
done

TEXT="${*:-}"
if [ -z "$TEXT" ] && [ -z "$FILE" ]; then TEXT="$(cat)"; fi
[ -n "$TEXT" ] || [ -n "$FILE" ] || { echo "нечего отправлять" >&2; exit 1; }

# Поля собираются разными флагами в зависимости от ветки: curl НЕ ПОЗВОЛЯЕТ смешивать
# --data-urlencode и -F в одном вызове. Прежняя версия это делала и падала молча —
# отправка файла не работала вовсе, а скрипт не говорил ни слова.
#
# Ответ на конкретное сообщение (--reply): владельцу видно, к чему относится реплика,
# и не нужно повторять её содержание.
if [ -n "$FILE" ]; then
  args=(-X POST -F "chat_id=${TG_CHAT_ID}")
  [ "$TOPIC" != "general" ] && [ "$TOPIC" != "General" ] && args+=(-F "message_thread_id=${TOPIC}")
  [ -n "$REPLY_TO" ] && args+=(-F "reply_parameters={\"message_id\":${REPLY_TO}}")
else
  args=(-X POST --data-urlencode "chat_id=${TG_CHAT_ID}")
  [ "$TOPIC" != "general" ] && [ "$TOPIC" != "General" ] && args+=(--data-urlencode "message_thread_id=${TOPIC}")
  [ -n "$REPLY_TO" ] && args+=(--data-urlencode "reply_parameters={\"message_id\":${REPLY_TO}}")
fi

if [ -n "$FILE" ]; then
  # Картинки шлём как photo — они показываются прямо в ленте. Всё прочее
  # документом: так Telegram не пережимает файл и не портит содержимое.
  # Приведение к нижнему регистру через tr, а не ${VAR,,}: в macOS bash 3.2
  # такого расширения нет, скрипт молча падал бы на файлах с ЗАГЛАВНЫМ .PNG.
  case "$(printf '%s' "$FILE" | tr '[:upper:]' '[:lower:]')" in
    *.jpg|*.jpeg|*.png|*.webp) method=sendPhoto;  field=photo ;;
    *)                         method=sendDocument; field=document ;;
  esac
  args+=(-F "${field}=@${FILE}")
  [ -n "$TEXT" ] && args+=(--form-string "caption=${TEXT}")
  # Отдельный таймаут: загрузка файла много дольше отправки текста, и общие
  # 25 секунд обрывали её на середине.
  resp="$(TG_TIMEOUT=120 tg_api "$method" "${args[@]}")"
else
  args+=(--data-urlencode "text=${TEXT}")
  resp="$(tg_api sendMessage "${args[@]}")"
fi

ok="$(printf '%s' "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("ok"))' 2>/dev/null || echo False)"
if [ "$ok" != "True" ]; then
  printf '%s\n' "$resp" | python3 -c 'import json,sys; print("ОШИБКА:", json.load(sys.stdin).get("description"))' >&2 2>/dev/null \
    || echo "ОШИБКА при отправке" >&2
  exit 1
fi

# Дописываем в стенограмму темы.
mkdir -p "$TG_DIALOG_DIR"
slug="$([ "$TOPIC" = "general" ] || [ "$TOPIC" = "General" ] && echo general || echo "topic-${TOPIC}")"
{
  printf '\n### %s — оркестратор\n\n' "$(date '+%Y-%m-%d %H:%M')"
  printf '%s\n' "$TEXT"
} >> "${TG_DIALOG_DIR}/${slug}.md"

printf '%s' "$resp" | python3 -c 'import json,sys; r=json.load(sys.stdin)["result"]; print("отправлено, message_id:", r["message_id"], "| тема:", r.get("message_thread_id","General"))'
