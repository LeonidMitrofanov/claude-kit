#!/usr/bin/env bash
# Обвязка моста Telegram: пути и вызов API. Подключается остальными
# tg-*.sh через source. Ничего проектного здесь нет — всё проектное лежит
# в project.conf в корне проекта.
#
# Токен НЕ хранится ни здесь, ни где-либо ещё в репозитории — только в macOS
# Keychain, под именем из TG_KEYCHAIN_SERVICE.

TG_TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TG_TOOLS_DIR/../kit-common.sh"

kit_require TG_CHAT_ID TG_KEYCHAIN_SERVICE

# Идентификатор чата без префикса -100 — в таком виде он входит в ссылки
# вида https://t.me/c/<short>/<тема>/<сообщение>. Выводится, а не хранится,
# чтобы не было двух источников правды об одном чате.
TG_CHAT_SHORT="${TG_CHAT_ID#-100}"

# Куда мост складывает переписку: по файлу на тему.
TG_ROOT="$KIT_ROOT"
TG_DIALOG_DIR="${TG_ROOT}/dialog"
TG_STATE_DIR="$KIT_STATE_DIR"

tg_token() {
  security find-generic-password -a "$USER" -s "$TG_KEYCHAIN_SERVICE" -w 2>/dev/null || {
    echo "токен Telegram не найден в Keychain (служба «${TG_KEYCHAIN_SERVICE}»)" >&2
    echo "положить: security add-generic-password -a \"\$USER\" -s ${TG_KEYCHAIN_SERVICE} -w '<ТОКЕН>' -U" >&2
    return 1
  }
}

tg_api() {
  local method="$1"; shift
  local token
  token="$(tg_token)" || return 1
  # Таймаут переопределяется через TG_TIMEOUT: загрузка файла идёт много дольше
  # отправки текста, и общих 25 секунд ей не хватает — обрывалась на середине.
  curl -sS -m "${TG_TIMEOUT:-25}" "https://api.telegram.org/bot${token}/${method}" "$@"
}
