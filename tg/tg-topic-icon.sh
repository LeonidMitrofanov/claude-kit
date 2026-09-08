#!/usr/bin/env bash
# Поставить теме её значок.
#
# Использование:
#   tg-topic-icon.sh <topic_id> <эмодзи>     поставить значок
#   tg-topic-icon.sh <topic_id> --clear      снять значок
#   tg-topic-icon.sh --list                  показать весь допустимый набор
#
# Четыре вещи, которых нет в документации Bot API и на которые уже наступали:
#
# 1. Значок — это НЕ эмодзи в названии темы, а отдельное поле icon_custom_emoji_id
#    метода editForumTopic. Набор закрытый, 112 штук; свой эмодзи подставить нельзя.
#
# 2. Поле name передавать НЕ НУЖНО и вредно. Оно необязательное, и опущенное —
#    сохраняется. Передача «прежнего» названия вместе со значком выглядит
#    безобиднее, но опаснее: промахнёшься в букве — название молча заменится.
#    Поэтому здесь name не передаётся никогда.
#
# 3. Идентификаторы значков не зашиты в скрипт. Набор запрашивается каждый раз
#    и ищется по самому эмодзи: вызов читается как «поставь 🎓», а не «поставь
#    5357419403325481346», и список из 112 значений не устаревает молча.
#
#    Тонкость: Telegram отдаёт часть значков с селектором варианта U+FE0F (⚡️),
#    а набирают их обычно без него (⚡). Сравнение идёт после нормализации,
#    иначе существующий значок просто не находится.
#
# 4. ЗАКРЕПИТЬ ТЕМУ через Bot API НЕЛЬЗЯ — такого метода нет вовсе
#    (pinForumTopic отвечает Not Found). Это клиентская операция, её делает человек.
#
# И ещё: наборы эмодзи для значков тем и для реакций РАЗНЫЕ. «❓» Telegram принимает
# как значок темы, но отклоняет как реакцию (REACTION_INVALID) — проверять надо порознь.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

list_icons() {
  tg_api getForumTopicIconStickers | python3 -c '
import json, sys
d = json.load(sys.stdin)
if not d.get("ok"):
    sys.exit("ОШИБКА: " + str(d.get("description")))
for s in d["result"]:
    print(s.get("emoji", "?") + "\t" + s.get("custom_emoji_id", ""))
print("всего значков: %d" % len(d["result"]), file=sys.stderr)
'
}

if [ "${1:-}" = "--list" ]; then
  list_icons
  exit 0
fi

TOPIC="${1:-}"
EMOJI="${2:-}"
[ -n "$TOPIC" ] && [ -n "$EMOJI" ] || {
  echo "использование: tg-topic-icon.sh <topic_id> <эмодзи|--clear>" >&2
  echo "               tg-topic-icon.sh --list" >&2
  exit 1
}

if [ "$EMOJI" = "--clear" ]; then
  ICON_ID=""
else
  # Пустая строка допустима как ответ (значка нет), поэтому отличаем «не нашли»
  # по коду возврата, а не по пустоте вывода.
  ICON_ID="$(tg_api getForumTopicIconStickers | EMOJI="$EMOJI" python3 -c '
import json, os, sys

def norm(e):
    # Селектор варианта U+FE0F и соединитель нулевой ширины ничего не значат
    # для глаза, но делают строки неравными. Сравниваем без них.
    return (e or "").replace("️", "").replace("‍", "").strip()

d = json.load(sys.stdin)
if not d.get("ok"):
    sys.exit("ОШИБКА: " + str(d.get("description")))
want = norm(os.environ["EMOJI"])
for s in d["result"]:
    if norm(s.get("emoji")) == want:
        print(s["custom_emoji_id"])
        break
else:
    sys.exit("эмодзи %r нет в наборе значков тем (%d шт.); "
             "посмотреть весь набор: tg-topic-icon.sh --list"
             % (os.environ["EMOJI"], len(d["result"])))
')"
fi

# name НЕ передаём — см. пункт 2 в шапке.
tg_api editForumTopic \
  -X POST \
  --data-urlencode "chat_id=${TG_CHAT_ID}" \
  --data-urlencode "message_thread_id=${TOPIC}" \
  --data-urlencode "icon_custom_emoji_id=${ICON_ID}" \
| python3 -c "
import json,sys
d=json.load(sys.stdin)
print('значок темы ${TOPIC} обновлён' if d.get('ok') else 'ОШИБКА: '+str(d.get('description')))
sys.exit(0 if d.get('ok') else 1)
"
