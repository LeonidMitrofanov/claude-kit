#!/usr/bin/env bash
# Обход делегированных сессий: статус, живость, простой, диалоги разрешений.
#
# Живой канал между сессиями работает (unix-сокеты в /tmp/cc-socks/, SendMessage
# и ListAgents) — сессия зовёт оркестратора сама. Требуется claude 2.1.261+:
# на 2.1.224 сокет не создаётся вовсе.
#
# Обход при этом обязателен, потому что есть три состояния, о которых сессия
# сообщить НЕ МОЖЕТ:
#   1. стоит на диалоге разрешений — заблокирована и позвать никого не в силах;
#   2. умерла молча — процесса нет, отчитаться некому;
#   3. закончила ход и простаивает с незакрытой задачей — харнесс не продолжает
#      сессию сам, она ждёт ввода. Это самое коварное: снаружи выглядит живой.
#
# Использование:
#   claude-kit/sweep.sh          — сводка по всем задачам
#   claude-kit/sweep.sh <slug>   — подробно по одной, с полным OUTBOX

set -uo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$KIT/kit-common.sh"
ROOT="$KIT_ROOT"
TASKS="$ROOT/tasks"

# Название проекта в шапке: на машине живёт несколько проектов сразу, и по одному
# списку слагов не всегда понятно, чей обход перед глазами.
PROJ="${PROJECT_NAME:-$(basename "$ROOT")}"

# Порог простоя: дольше этого без изменений файлов при живой сессии — подозрение.
IDLE_MIN="${IDLE_MIN:-20}"

# Хвост экрана сессии. Знак «=» даёт точное совпадение имени вместо префиксного,
# но capture-pane по имени не работает («can't find pane») — нужен pane_id.
pane_tail() {
  local slug="$1" id
  id="$(tmux list-panes -t "=$slug" -F '#{pane_id}' 2>/dev/null | head -1)"
  [ -n "$id" ] || return 1
  tmux capture-pane -p -t "$id" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -1
}

# Минуты с последнего изменения любого файла задачи.
idle_minutes() {
  local d="$1" newest now mtime
  newest="$(ls -t "$d" 2>/dev/null | head -1)"
  [ -n "$newest" ] || { echo 9999; return; }
  mtime="$(stat -f %m "$d/$newest" 2>/dev/null)" || { echo 9999; return; }
  now="$(date +%s)"
  echo $(( (now - mtime) / 60 ))
}

# ── подробный режим по одной задаче ────────────────────────────────────────────
if [ $# -ge 1 ]; then
  slug="$1"
  d="$TASKS/$slug"
  [ -d "$d" ] || { echo "нет задачи «${slug}»" >&2; exit 1; }

  echo "ЗАДАЧА: ${slug}   (проект: ${PROJ})"
  echo "  директория: $d"
  printf '  статус:     '; [ -f "$d/STATUS" ] && cat "$d/STATUS" || echo "—"
  printf '  tmux:       '; tmux has-session -t "=$slug" 2>/dev/null && echo "жива" || echo "нет"
  printf '  простой:    %s мин\n' "$(idle_minutes "$d")"
  printf '  экран:      %s\n' "$(pane_tail "$slug" || echo '—')"
  echo
  echo "── OUTBOX.md ──────────────────────────────────────────────────────────────"
  [ -f "$d/OUTBOX.md" ] && cat "$d/OUTBOX.md" || echo "(пуст)"
  exit 0
fi

# ── сводка по всем ─────────────────────────────────────────────────────────────
echo "ПРОЕКТ: ${PROJ}   (${ROOT})"
echo

# Указатель на сокет оркестратора обязан совпадать с его текущим сокетом. При каждом
# перезапуске главной сессии PID меняется, указатель устаревает, и мгновенная доставка
# сообщений из Telegram молча перестаёт работать — проверено дорогой ценой: сообщение
# владельца пролежало непрочитанным больше суток.
SOCK_PTR="$KIT_STATE_DIR/orchestrator.sock"
if [ -n "${CLAUDE_CODE_MESSAGING_SOCKET:-}" ] && [ -f "$SOCK_PTR" ]; then
  if [ "$(cat "$SOCK_PTR" 2>/dev/null)" != "$CLAUDE_CODE_MESSAGING_SOCKET" ]; then
    printf '%s' "$CLAUDE_CODE_MESSAGING_SOCKET" > "$SOCK_PTR"
    echo "ИСПРАВЛЕНО: указатель на сокет оркестратора устарел, обновлён на ${CLAUDE_CODE_MESSAGING_SOCKET}"
    echo
  fi
fi
printf '%-22s %-12s %-7s %-7s %s\n' "ЗАДАЧА" "СТАТУС" "TMUX" "ПРОСТОЙ" "ПОСЛЕДНЕЕ СООБЩЕНИЕ"
printf '%.0s-' {1..96}; echo

found=0
attention=""

for d in "$TASKS"/*/; do
  [ -d "$d" ] || continue
  slug="$(basename "$d")"
  found=1

  status="—"
  [ -f "$d/STATUS" ] && status="$(tr -d '[:space:]' < "$d/STATUS")"

  if tmux has-session -t "=$slug" 2>/dev/null; then alive=1; tm="жива"; else alive=0; tm="нет"; fi

  idle="$(idle_minutes "$d")"
  idle_disp="${idle}м"
  [ "$idle" -ge 9999 ] && idle_disp="—"

  last="—"
  if [ -f "$d/OUTBOX.md" ]; then
    l="$(grep '^## ' "$d/OUTBOX.md" 2>/dev/null | tail -1 | sed 's/^## //')"
    [ -n "$l" ] && last="$l"
  fi

  printf '%-22s %-12s %-7s %-7s %s\n' "$slug" "$status" "$tm" "$idle_disp" "$last"

  # ── признаки, требующие вмешательства ──
  case "$status" in
    NeedsOwner) attention+="  • ${slug}: ЖДЁТ ВЛАДЕЛЬЦА — передать вопрос немедленно, самому не отвечать"$'\n'; continue ;;
    Blocked)    attention+="  • ${slug}: Blocked — расшить самому, сама не продолжит"$'\n'; continue ;;
    Done)       continue ;;
  esac

  if [ "$alive" -eq 0 ]; then
    attention+="  • ${slug}: ${status}, но сессии нет — умерла молча, читать OUTBOX"$'\n'
    continue
  fi

  # Сессия жива — смотрим, что на экране.
  tail_line="$(pane_tail "$slug" || echo '')"

  if [[ "$tail_line" == *"Esc to cancel"* ]]; then
    attention+="  • ${slug}: СТОИТ НА ДИАЛОГЕ разрешений — позвать не может, разблокировать"$'\n'
  elif [[ "$tail_line" != *"esc to interrupt"* ]] && [ "$idle" -ge "$IDLE_MIN" ]; then
    # Нет «esc to interrupt» — сессия не генерирует. Вместе с застывшими файлами
    # это «закончила ход и ждёт ввода», а задача не закрыта.
    attention+="  • ${slug}: жива, но ПРОСТАИВАЕТ ${idle} мин с незакрытой задачей — подтолкнуть"$'\n'
  fi
done

[ "$found" -eq 0 ] && echo "(задач нет)"

echo
if [ -n "$attention" ]; then
  echo "ТРЕБУЕТ ВНИМАНИЯ:"
  printf '%s' "$attention"
else
  echo "Стопоров не видно."
fi
echo
echo "Подробно по задаче:  claude-kit/sweep.sh <slug>"
