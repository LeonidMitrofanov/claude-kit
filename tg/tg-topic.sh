#!/usr/bin/env bash
# Завести тему в группе и напечатать её идентификатор.
#
# Использование:
#   tg-topic.sh <название>
#
# Бот должен быть администратором группы с правом «управление темами»,
# иначе Telegram вернёт «not enough rights to manage forum topics».
#
# Идентификатор темы после создания записывается в project.conf — иначе он
# потеряется: у Bot API нет метода, чтобы перечислить темы группы, и узнать
# номер задним числом можно только по входящему из неё сообщению.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

NAME="${*:-}"
[ -n "$NAME" ] || { echo "использование: tg-topic.sh <название>" >&2; exit 1; }

tg_api createForumTopic \
  -X POST \
  --data-urlencode "chat_id=${TG_CHAT_ID}" \
  --data-urlencode "name=${NAME}" \
| python3 -c "
import json,sys
d=json.load(sys.stdin)
if d.get('ok'):
    print('создана «${NAME}», id темы: %s' % d['result']['message_thread_id'])
else:
    print('ОШИБКА: '+str(d.get('description')), file=sys.stderr)
    sys.exit(1)
"
