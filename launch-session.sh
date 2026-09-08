#!/usr/bin/env bash
# Запуск делегированной сессии Claude Code в tmux.
# Использование: claude-kit/launch-session.sh <task-slug>
# Ожидает, что tasks/<task-slug>/TASK.md уже заполнен по шаблону SESSION-REQUEST.md.

set -euo pipefail

SLUG="${1:-}"
if [ -z "$SLUG" ]; then
  echo "использование: launch-session.sh <task-slug>" >&2
  exit 1
fi

# Значение переменной окружения снимается ДО чтения настроек: kit-common.sh
# делает source project.conf, и файл перетёр бы переданное разово имя.
ORCH_ENV="${ORCHESTRATOR_NAME:-}"

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$KIT/kit-common.sh"
ROOT="$KIT_ROOT"
DIR="$ROOT/tasks/$SLUG"

# Адрес оркестратора — три источника по убыванию доверия:
#
#   1. переменная окружения — разовое переопределение, ничего не трогая;
#   2. .kit-state/orchestrator.name — имя, которое оркестратор записал о себе сам;
#   3. ORCHESTRATOR_NAME из project.conf — имя, под которым его собирались запускать.
#
# Порядок именно такой, потому что имя сессии автогенерируемое, если оркестратор
# запущен без --name, и МЕНЯЕТСЯ при каждом перезапуске. Значение из настроек тогда
# устаревает молча: сессии получают мёртвый адрес и работают без живого канала,
# ничего об этом не зная. Файл состояния пишет живая сессия, и он свежее.
ORCH_FILE="$KIT_STATE_DIR/orchestrator.name"
if [ -n "$ORCH_ENV" ]; then
  ORCH="$ORCH_ENV"
elif [ -s "$ORCH_FILE" ]; then
  ORCH="$(tr -d '[:space:]' < "$ORCH_FILE")"
else
  kit_require ORCHESTRATOR_NAME
  ORCH="$ORCHESTRATOR_NAME"
fi

# Бинарь Claude Code. Версия критична: живой канал между сессиями (unix-сокет
# в /tmp/cc-socks/<pid>.sock) поднимают только сборки от 2.1.261. На 2.1.224
# сокет не создаётся вовсе, и SendMessage не находит ни одного адресата —
# проверено прямым опытом. Поэтому по умолчанию берём самую свежую сборку,
# какая есть на машине, включая ту, что поставляется с расширением VSCode.
if [ -z "${CLAUDE_BIN:-}" ]; then
  CLAUDE_BIN="$(ls -d "$HOME"/.vscode/extensions/anthropic.claude-code-*/resources/native-binary/claude 2>/dev/null | sort -V | tail -1)"
  [ -x "${CLAUDE_BIN:-}" ] || CLAUDE_BIN="$(command -v claude)"
fi
[ -x "$CLAUDE_BIN" ] || { echo "не найден исполняемый claude (задай CLAUDE_BIN)" >&2; exit 1; }

[ -f "$DIR/TASK.md" ] || { echo "нет файла $DIR/TASK.md — сначала заполни шаблон" >&2; exit 1; }

if grep -qE '<task-slug>|<ГГГГ|<имя главной сессии|<Одно-два предложения|<Какую задачу' "$DIR/TASK.md"; then
  echo "в $DIR/TASK.md остались незаполненные плейсхолдеры — заполни перед запуском" >&2
  exit 1
fi

if tmux has-session -t "$SLUG" 2>/dev/null; then
  echo "сессия tmux «${SLUG}» уже существует — сначала закрой её" >&2
  exit 1
fi

echo "ToDo" > "$DIR/STATUS"
[ -f "$DIR/OUTBOX.md" ] || printf '# OUTBOX — %s\n\nСообщения сессии оркестратору. Дублирует SendMessage.\n' "$SLUG" > "$DIR/OUTBOX.md"

# Правила кладём в CLAUDE.md директории задачи: харнесс подхватывает такой файл
# автоматически, поэтому сессия не может их не прочитать и не спрашивает разрешения
# на чтение выше своей директории. Раньше правила шли промптом — сессии дважды
# вставали на диалоге «Read outside the working directories».
#
# RULES.md — шаблон с метками @@…@@: имя оркестратора и корень проекта у каждого
# проекта свои. Подставляем при копировании, а не объясняем сессии в промпте,
# что «вместо orchestrator читай такое-то имя»: указание сделать мысленную замену
# по всему тексту правил сессия может и не выполнить, а подставленный файл
# двусмысленности не оставляет.
KIT_PROJECT_NAME="${PROJECT_NAME:-$(basename "$ROOT")}" \
KIT_ORCH="$ORCH" KIT_ROOT_PATH="$ROOT" \
python3 - "$KIT/RULES.md" "$DIR/CLAUDE.md" <<'PY'
import os, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()

# Ведущий HTML-комментарий RULES.md адресован тому, кто правит шаблон, а не сессии.
# Выбрасываем: в CLAUDE.md задачи он только сбивает с толку — объясняет механизм
# подстановки, следов которого в готовом файле уже нет.
if text.lstrip().startswith("<!--"):
    text = text.split("-->", 1)[1].lstrip()

for token, value in (("@@PROJECT_NAME@@", os.environ["KIT_PROJECT_NAME"]),
                     ("@@ORCHESTRATOR@@", os.environ["KIT_ORCH"]),
                     ("@@PROJECT_ROOT@@", os.environ["KIT_ROOT_PATH"])):
    text = text.replace(token, value)
if "@@" in text:
    sys.exit("в RULES.md осталась неподставленная метка @@…@@ — допиши подстановку "
             "в launch-session.sh, иначе сессия прочитает её буквально")
open(dst, "w", encoding="utf-8").write(text)
PY

PROMPT="Прочитай файл ./TASK.md в текущей директории и выполни описанную в нём задачу. Но самым первым действием, до всего остального, прочитай ./CLAUDE.md в этой же директории — это правила работы, они обязательны и важнее твоих привычных способов работы. Ключевое: с пользователем не общайся, все итоги и вопросы шли сессии «${ORCH}» через SendMessage и дублируй в ./OUTBOX.md, статус веди в файле ./STATUS."

# Режим разрешений. Рядом с сессией нет человека, поэтому режим должен и не подвешивать
# её на запросах, и не отказывать в рутине. Проверено на практике:
#   bypassPermissions — запрещён управляемой политикой организации, работать не будет;
#   manual            — сессия встаёт намертво на первом же запросе;
#   dontAsk           — не спрашивает, а ОТКАЗЫВАЕТ: сессия не может даже писать свой STATUS;
#   auto              — рутина проходит без вопросов, рискованное отклоняется классификатором.
# Отказ, в отличие от зависания, сессия может обработать: по правилам она сообщает
# оркестратору и переводит STATUS в Blocked.
MODE="${PERMISSION_MODE:-auto}"

# Корень проекта в разрешённые директории: сессии нужно читать docs/ и claude-kit/,
# которые лежат выше её рабочей директории. Без этого — тот же диалог разрешений,
# а отвечать на него некому.
#
# EXTRA_DIRS — дополнительные пути через пробел, когда задача осознанно выходит
# за пределы проекта (например разворачивает кит на соседний проект). Обычным
# задачам это не нужно: границы из RULES.md держатся именно тем, что расширять
# их приходится явно, отдельным решением при запуске.
addargs=(--add-dir "$ROOT")
for d in ${EXTRA_DIRS:-}; do
  [ -d "$d" ] || { echo "EXTRA_DIRS: нет директории ${d}" >&2; exit 1; }
  addargs+=(--add-dir "$d")
  echo "  расширенный доступ: $d"
done

addstr=""
for a in "${addargs[@]}"; do addstr="${addstr} $(printf %q "$a")"; done

tmux new-session -d -s "$SLUG" -c "$DIR" \
  "$(printf %q "$CLAUDE_BIN") --name $(printf %q "$SLUG") --permission-mode $(printf %q "$MODE")${addstr} $(printf %q "$PROMPT")"

# Задание, переданное аргументом, доезжает НЕ ВСЕГДА: сессия поднимается, показывает
# приветственный экран с пустой строкой ввода и стоит так вечно. Проверено дорого —
# две сессии простояли десять часов, ничего не начав. Поэтому доставку проверяем,
# а не предполагаем: смотрим экран и при необходимости дошлём задание клавишами.
sleep 8
# ВАЖНО: capture-pane по имени сессии не работает («can't find pane») даже с «=»,
# нужен идентификатор пейна из list-panes. Прежняя версия этой проверки использовала
# имя, молча возвращала пустоту, и запасная доставка не срабатывала ни разу.
#
# «|| true» здесь обязателен. При set -e и pipefail неудача этого конвейера
# обрывает скрипт молча — без единой строки вывода и с кодом 1. А неудача тут
# означает ровно одно: сессия уже умерла, и это как раз тот случай, когда нужен
# не тихий выход, а сообщение о нём.
PANE="$(tmux list-panes -t "=$SLUG" -F '#{pane_id}' 2>/dev/null | head -1)" || true
if [ -z "$PANE" ]; then
  echo "  ВНИМАНИЕ: сессии tmux «${SLUG}» уже нет — claude завершился сразу после запуска" >&2
  echo "  проверь CLAUDE_BIN и запусти вручную, чтобы увидеть ошибку" >&2
elif tmux capture-pane -p -t "$PANE" 2>/dev/null | grep -q "Claude Code v"; then
  echo "  задание не доехало аргументом — досылаю клавишами"
  # Текст и Enter отправляем раздельно: длинная строка приходит в CLI как вставка,
  # и Enter в той же посылке часто съедается как её часть.
  tmux send-keys -t "$PANE" -l "$PROMPT"
  sleep 1
  tmux send-keys -t "$PANE" C-m
  sleep 1
  tmux send-keys -t "$PANE" C-m
  sleep 3
  if tmux capture-pane -p -t "$PANE" 2>/dev/null | grep -q "Claude Code v"; then
    echo "  ВНИМАНИЕ: задание не доехало и клавишами — сессия стоит пустой" >&2
  else
    echo "  доставлено клавишами"
  fi
fi

echo "запущена сессия tmux «${SLUG}» (оркестратор: ${ORCH})"
echo "  ПОДПИШИСЬ НА ПРОСТОЙ: SendMessage к «${SLUG}» с notify_when_idle: true —"
echo "  иначе об остановке узнаешь только на обходе, через час"
echo "  директория: $DIR"
echo "  подключиться:  tmux attach -t $SLUG"
echo "  посмотреть:    tmux list-panes -t \"=$SLUG\" -F '#{pane_id}' | head -1 | xargs -I{} tmux capture-pane -p -t {} | tail -40"
echo "  убить:         tmux kill-session -t $SLUG"
