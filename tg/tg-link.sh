#!/usr/bin/env bash
# Ссылка на сообщение в теме группы.
#
# Нужна постоянно: отчёт начинается ссылкой на постановку, «Важное» копит ссылки
# на разговоры. Собирать её руками — значит помнить, что в пути стоит идентификатор
# чата БЕЗ префикса -100, и держать этот огрызок числа где-то записанным.
# Здесь он выводится из TG_CHAT_ID, поэтому источник правды один — project.conf.
#
# Использование:
#   tg-link.sh <topic_id|general> <message_id>

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

TOPIC="${1:-}"
MID="${2:-}"
[ -n "$TOPIC" ] && [ -n "$MID" ] || {
  echo "использование: tg-link.sh <topic_id|general> <message_id>" >&2; exit 1; }

if [ "$TOPIC" = "general" ] || [ "$TOPIC" = "General" ]; then
  echo "https://t.me/c/${TG_CHAT_SHORT}/${MID}"
else
  echo "https://t.me/c/${TG_CHAT_SHORT}/${TOPIC}/${MID}"
fi
