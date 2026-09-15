#!/usr/bin/env python3
"""Приёмник Telegram: длинный опрос getUpdates → файлы переписки в dialog/.

Живёт в своей сессии tmux и работает постоянно. Оркестратор его не читает
напрямую — он читает файлы в dialog/, которые этот скрипт наполняет.

Зачем файлы, а не чтение из API на лету: getUpdates отдаёт каждое обновление
ровно один раз. Если бы за ним ходил оркестратор, сообщения исчезали бы после
первого прочтения и терялись при перезапуске сессии. Файл переживает всё.

Запуск (из корня проекта):
    tmux new-session -d -s tg-poll -c "$PWD" 'claude-kit/tg/tg-poll.py'

Настройки берутся из project.conf в корне проекта — того же файла, что читают
shell-скрипты рядом. Дублировать их здесь нельзя: разъедутся.
Токен берётся из macOS Keychain, в аргументах и логах не появляется.
"""

import http.client
import json
import os
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime

from kitconf import find_root, require, state_dir

HERE = os.path.dirname(os.path.abspath(__file__))

# Настройки и пути заполняет configure(), а не уровень модуля.
#
# Почему не при импорте, хотя так короче: побочный эффект при импорте — дефект
# сам по себе. Модуль с ним нельзя ни проверить (test-poll.py гоняет чистую
# quoted_ref, а падал бы на отсутствии project.conf), ни переиспользовать,
# не заведя вокруг настоящий проект. И кит должен уметь лежать в репозитории
# один, без единого проекта рядом, — а чтение настроек при импорте это ломает.
CHAT_ID = None
KEYCHAIN_SERVICE = None
ROOT = None
DIALOG_DIR = None
FILES_DIR = None
STATE_DIR = None
OFFSET_FILE = None
TOPICS_FILE = None


def configure() -> None:
    """Прочитать настройки проекта и разложить пути. Вызывается из main()."""
    global CHAT_ID, KEYCHAIN_SERVICE, ROOT, DIALOG_DIR, FILES_DIR
    global STATE_DIR, OFFSET_FILE, TOPICS_FILE

    _chat_id, KEYCHAIN_SERVICE = require("TG_CHAT_ID", "TG_KEYCHAIN_SERVICE")
    try:
        CHAT_ID = int(_chat_id)
    except ValueError:
        sys.exit(f"TG_CHAT_ID в project.conf не число: {_chat_id!r}")

    # Корень проекта берётся у kitconf, а не считается как «два каталога вверх»:
    # кит подключается подмодулем и может лежать не в корне.
    ROOT = find_root()
    DIALOG_DIR = os.path.join(ROOT, "dialog")
    FILES_DIR = os.path.join(DIALOG_DIR, "files")
    STATE_DIR = state_dir()
    OFFSET_FILE = os.path.join(STATE_DIR, "offset")
    TOPICS_FILE = os.path.join(DIALOG_DIR, "TOPICS.md")


# Где лежит секрет на машине без Keychain. Путь фиксированный и не в репозитории:
# ~/.config/claude-kit/<служба>, права 600. Это заметно хуже Keychain — файл читается
# любым процессом от того же пользователя, — но лучше переменной окружения, которая
# видна в /proc и утекает в логи дочерних процессов.
SECRET_DIR = os.path.join(os.path.expanduser("~"), ".config", "claude-kit")


def token() -> str:
    """Токен бота: Keychain на macOS, файл с правами 600 на прочих системах.

    Кит родился на macOS и звал `security` безусловно. На Linux это не «нет токена»,
    а `FileNotFoundError` — нет самой программы, — и приёмник падал трейсбеком
    в первую же секунду. Обнаружилось при переносе на сервер: инструкция переноса
    обещала переносимость, которой в живом коде не было.
    """
    if sys.platform == "darwin":
        try:
            return subprocess.run(
                ["security", "find-generic-password", "-a", os.environ.get("USER", ""),
                 "-s", KEYCHAIN_SERVICE, "-w"],
                capture_output=True, text=True, check=True,
            ).stdout.strip()
        except subprocess.CalledProcessError:
            sys.exit(
                f"токен не найден в Keychain (служба «{KEYCHAIN_SERVICE}»)\n"
                f"положить: security add-generic-password -a \"$USER\" "
                f"-s {KEYCHAIN_SERVICE} -w '<ТОКЕН>' -U"
            )

    path = os.path.join(SECRET_DIR, KEYCHAIN_SERVICE)
    try:
        with open(path, encoding="utf-8") as f:
            value = f.read().strip()
    except FileNotFoundError:
        sys.exit(
            f"токен не найден: нет файла {path}\n"
            f"положить: mkdir -p {SECRET_DIR} && umask 077 && "
            f"printf '%s' '<ТОКЕН>' > {path}"
        )
    if not value:
        sys.exit(f"файл {path} пуст")

    # Права проверяем и отказываемся работать с читаемым всеми секретом:
    # молча использовать такой файл — значит скрыть утечку, а не предотвратить её.
    mode = os.stat(path).st_mode & 0o077
    if mode:
        sys.exit(
            f"у файла {path} слишком широкие права: он доступен не только владельцу.\n"
            f"исправить: chmod 600 {path}"
        )
    return value


# Соединение и чтение живут по разным часам, и это не мелочь.
#
# Откуда взялось. В ночь на 11.09 связь с Telegram на машине владельца стала рваной:
# половина попыток соединиться зависала до самого таймаута. Сообщения владельца
# пролежали одиннадцать часов, а снаружи это выглядело как живой процесс,
# который ничего не делает.
#
# Замер показал существо дела. `curl` в те же секунды проходил там, где Python падал:
# curl соединяется с адресами параллельно (Happy Eyeballs) и берёт тот, что ответил,
# а Python перебирает их строго по очереди, и каждый мёртвый адрес стоит полного
# таймаута. Два адреса по 20 секунд — и одна попытка съедает 40 секунд вместо секунды.
#
# Параллельное соединение в стандартной библиотеке не реализовано, но главное здесь
# не оно, а цена неудачи. Соединение либо устанавливается за доли секунды, либо
# не устанавливается вовсе: ждать его 25 секунд бессмысленно. А вот ЧИТАТЬ ответ
# надо долго — на то он и длинный опрос.
#
# Поэтому таймауты разведены: на соединение несколько секунд, на чтение — сколько
# просили. Мёртвая попытка теперь стоит секунд, а не минуты, и приёмник успевает
# попробовать снова в ближайшее окно, когда сеть оживает.
CONNECT_TIMEOUT = 5


class _SplitTimeoutHTTPSConnection(http.client.HTTPSConnection):
    """HTTPS-соединение с коротким таймаутом на connect и длинным на чтение."""

    read_timeout = 70

    def connect(self):
        saved, self.timeout = self.timeout, CONNECT_TIMEOUT
        try:
            super().connect()
        finally:
            self.timeout = saved
        self.sock.settimeout(self.read_timeout)


class _SplitTimeoutHandler(urllib.request.HTTPSHandler):
    def https_open(self, req):
        return self.do_open(self._make, req)

    def _make(self, host, timeout=None, context=None, **kw):
        conn = _SplitTimeoutHTTPSConnection(host, context=self._context, **kw)
        conn.read_timeout = timeout if timeout else 70
        return conn


_opener = urllib.request.build_opener(_SplitTimeoutHandler())


def api(method: str, params: dict, tok: str, timeout: int = 70):
    url = f"https://api.telegram.org/bot{tok}/{method}?" + urllib.parse.urlencode(params)
    with _opener.open(url, timeout=timeout) as r:
        return json.load(r)


def read_offset() -> int:
    try:
        with open(OFFSET_FILE) as f:
            return int(f.read().strip())
    except (FileNotFoundError, ValueError):
        return 0


def write_offset(v: int) -> None:
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(OFFSET_FILE, "w") as f:
        f.write(str(v))


def load_topics() -> dict:
    """Соответствие id темы → её название. Копится по мере появления сообщений."""
    topics = {}
    if os.path.exists(TOPICS_FILE):
        for line in open(TOPICS_FILE, encoding="utf-8"):
            if line.startswith("| `"):
                parts = [p.strip().strip("`") for p in line.strip().strip("|").split("|")]
                if len(parts) >= 2 and parts[0].isdigit():
                    topics[int(parts[0])] = parts[1]
    return topics


def save_topics(topics: dict) -> None:
    os.makedirs(DIALOG_DIR, exist_ok=True)
    with open(TOPICS_FILE, "w", encoding="utf-8") as f:
        f.write("# Темы группы\n\n")
        f.write("Соответствие тем и файлов переписки. Заполняется приёмником\n")
        f.write("по мере появления сообщений — тема, где ещё никто не писал,\n")
        f.write("боту не видна.\n\n")
        f.write("| id | Название | Файл |\n| --- | --- | --- |\n")
        for tid, name in sorted(topics.items()):
            slug = "general" if tid == 0 else f"topic-{tid}"
            f.write(f"| `{tid}` | {name} | [{slug}.md]({slug}.md) |\n")


def seen(msg_id: int, tok: str) -> None:
    """Пометить сообщение как полученное — реакцией 👀, сразу.

    Ставит именно приёмник, а не оркестратор: приёмник видит сообщение первым,
    поэтому метка появляется через секунду после отправки. Оркестратор потом
    заменит её на 👨‍💻, 🤔 или 🏆 — реакция у бота одна и новая вытесняет прежнюю.

    Для владельца смысл в том, что отсутствие 👀 однозначно означает «не дошло»,
    а не «дошло, но ещё не прочитано».
    """
    # Повторяем при обрыве. setMessageReaction идемпотентен: повтор ставит ту же
    # реакцию, дубля не будет. Повтор здесь не роскошь — отсутствие 👀 владелец
    # читает как «сообщение не замечено», то есть единственный сигнал о доставке
    # пропадает ровно на рваной связи, когда он нужнее всего.
    last = None
    for attempt in range(1, 4):
        try:
            api("setMessageReaction", {
                "chat_id": CHAT_ID,
                "message_id": msg_id,
                "reaction": json.dumps([{"type": "emoji", "emoji": "👀"}]),
            }, tok, timeout=15)
            return
        except Exception as e:
            last = e
            if attempt < 3:
                time.sleep(attempt * 2)
    print(f"реакцию поставить не удалось после 3 попыток: {last}", flush=True)
    print("  владелец увидит отсутствие 👀 как «не замечено» — учти это", flush=True)


def quoted_ref(m: dict, tid: int) -> str:
    """Описание сообщения, на которое ответили или которое переслали.

    Ловушка форумов: в теме КАЖДОЕ сообщение технически является ответом на её
    корень, поэтому reply_to_message присутствует всегда. Настоящий ответ отличается
    тем, что цель не совпадает с идентификатором темы и не является служебным
    сообщением о её создании.

    Вторая ловушка: отвечая на выделенную фразу, Telegram кладёт её в поле quote
    РЯДОМ с reply_to_message, а не внутрь него. Читая только reply_to_message,
    видишь сообщение целиком и не понимаешь, к какой именно фразе вопрос —
    а владелец выделением пользуется.

    Формат возвращаемой строки проверяется test-poll.py целиком, а не по вхождению
    подстроки: она попадает в dialog/ и читается человеком.
    """
    def short(s: str) -> str:
        s = s.strip().replace("\n", " ")
        return s[:120] + "…" if len(s) > 120 else s

    fwd = m.get("forward_origin") or {}
    if fwd:
        who = (fwd.get("sender_user") or {}).get("first_name") or fwd.get("sender_user_name") or "?"
        return f"[переслано от {who}]"

    r = m.get("reply_to_message")
    if not r:
        return ""
    rid = r.get("message_id")
    if rid == tid or r.get("forum_topic_created"):
        return ""                                    # это корень темы, а не ответ

    author = (r.get("from") or {}).get("first_name", "?")

    quote = (m.get("quote") or {}).get("text")
    if quote:
        return f"[в ответ на #{rid} от {author}, выделено: «{short(quote)}»]"

    body = short(r.get("text") or r.get("caption") or "(без текста)")
    return f"[в ответ на #{rid} от {author}: «{body}»]"


def save_attachment(m: dict, tok: str) -> str:
    """Скачать вложение сообщения. Возвращает путь к файлу или пустую строку.

    Telegram отдаёт только идентификатор файла; чтобы оркестратор мог прочитать
    картинку или документ, файл должен лежать на диске.
    """
    file_id = name_hint = ""
    if m.get("photo"):                       # массив размеров, последний — крупнейший
        file_id = m["photo"][-1]["file_id"]
        name_hint = ".jpg"
    elif m.get("document"):
        file_id = m["document"]["file_id"]
        name_hint = m["document"].get("file_name", "")
    elif m.get("video"):
        file_id = m["video"]["file_id"]
        name_hint = ".mp4"
    elif m.get("voice"):
        file_id = m["voice"]["file_id"]
        name_hint = ".ogg"
    if not file_id:
        return ""

    try:
        d = api("getFile", {"file_id": file_id}, tok, timeout=30)
        if not d.get("ok"):
            # Молча возвращать пустоту нельзя: так 15.09 пропала картинка владельца.
            # Частая причина — файл больше 20 МБ, Bot API такие не отдаёт.
            print(f"не удалось скачать вложение #{m.get('message_id', 0)}: "
                  f"{d.get('description')}", flush=True)
            return ""
        remote = d["result"]["file_path"]
        os.makedirs(FILES_DIR, exist_ok=True)
        base = os.path.basename(name_hint) or os.path.basename(remote)
        if not os.path.splitext(base)[1]:
            base += os.path.splitext(remote)[1]
        local = os.path.join(FILES_DIR, f"{m.get('message_id', 0)}-{base}")
        url = f"https://api.telegram.org/file/bot{tok}/{remote}"
        with urllib.request.urlopen(url, timeout=60) as r, open(local, "wb") as f:
            f.write(r.read())
        return local
    except Exception as e:
        print(f"не удалось скачать вложение: {e}", flush=True)
        return ""


# Служебные сообщения: у них нет ни текста, ни вложения, и это нормально.
SERVICE_KEYS = {
    "pinned_message", "new_chat_members", "left_chat_member", "new_chat_title",
    "new_chat_photo", "delete_chat_photo", "forum_topic_created", "forum_topic_edited",
    "forum_topic_closed", "forum_topic_reopened", "general_forum_topic_hidden",
    "general_forum_topic_unhidden", "message_auto_delete_timer_changed",
    "video_chat_started", "video_chat_ended", "video_chat_scheduled",
    "video_chat_participants_invited", "boost_added", "chat_background_set",
}

# Вложения: скачиваемые save_attachment и те, что он пока не умеет.
MEDIA_KEYS = {"photo", "document", "video", "voice", "animation", "video_note", "audio", "sticker"}

# Ключи сообщения, по которым видно, что именно пришло. Нужны только для пометки.
_NON_CONTENT = {"message_id", "message_thread_id", "from", "sender_chat", "chat", "date",
                "is_topic_message", "reply_to_message", "quote", "edit_date",
                "forward_origin", "has_protected_content", "author_signature"}


def unsaved_note(m: dict) -> str:
    """Пометка для сообщения без текста, чьё вложение не скачалось.

    Пустая строка — служебное сообщение, записывать нечего. Иначе — строка,
    которая попадёт в dialog/ и разбудит оркестратора. Прежде такие сообщения
    выбрасывались молча: владелец прислал картинку, приёмник её не принял,
    и узнать об этом можно было только по дырке в нумерации.
    """
    keys = set(m) - _NON_CONTENT
    if keys & SERVICE_KEYS:
        return ""
    kind = ", ".join(sorted(keys)) or "неизвестно"
    return (f"[сообщение без текста; вложение НЕ ПОЛУЧЕНО, тип: {kind} — "
            f"попроси владельца прислать иначе]")


def wake(text: str, topic_name: str, sender: str) -> None:
    """Разбудить оркестратора немедленно, не дожидаясь его обхода.

    Файл в dialog/ уже записан к этому моменту, поэтому неудача здесь ничего
    не теряет: сообщение просто дойдёт позже, на ближайшем обходе. Ради этого
    вызов и обёрнут в try — приёмник не должен падать из-за закрытой сессии.

    Но «не падать» и «молчать» — разные вещи. tg-wake.py сообщает о беде кодом
    возврата, а не исключением: устаревший сокет, пустой указатель, закрытая
    сессия оркестратора — всё это обычный выход с единицей. Не глядя на
    returncode, приёмник выглядел бы работающим, пока мгновенная доставка
    мертва, и заметить это можно было бы только по молчанию оркестратора.
    """
    try:
        r = subprocess.run(
            [os.path.join(HERE, "tg-wake.py"), text, "--topic", topic_name, "--from", sender],
            capture_output=True, text=True, timeout=15,
        )
    except Exception as e:
        print(f"мгновенная доставка не удалась ({e}); сообщение осталось в dialog/", flush=True)
        return
    if r.returncode != 0:
        why = (r.stderr or r.stdout or "без объяснения").strip().replace("\n", " ")
        print(f"мгновенная доставка не удалась: {why}; сообщение осталось в dialog/", flush=True)


def append(slug: str, who: str, text: str, when: str, msg_id: int = 0) -> None:
    """Дописать сообщение в стенограмму темы.

    msg_id сохраняется намеренно: без него нельзя ни закрепить сообщение,
    ни ответить на него — Telegram адресует и то и другое по идентификатору,
    а getUpdates отдаёт каждое обновление лишь однажды.
    """
    os.makedirs(DIALOG_DIR, exist_ok=True)
    path = os.path.join(DIALOG_DIR, f"{slug}.md")
    new = not os.path.exists(path)
    with open(path, "a", encoding="utf-8") as f:
        if new:
            f.write(f"# Переписка: {slug}\n\n")
            f.write("Наполняется автоматически. Входящее пишет приёмник,\n")
            f.write("исходящее — `tg-send.sh`. Править руками не нужно.\n")
        tag = f" `#{msg_id}`" if msg_id else ""
        f.write(f"\n### {when} — {who}{tag}\n\n{text}\n")


def main() -> None:
    configure()
    tok = token()
    topics = load_topics()
    offset = read_offset()
    print(f"приёмник запущен, offset={offset}, чат={CHAT_ID}", flush=True)

    fails = 0
    while True:
        try:
            # Длинный опрос 25 с, а не 50: наблюдалась серия обрывов
            # «Remote end closed connection without response» — соединение рвал
            # кто-то по пути, и приёмник глох на минуты. Короткое окно надёжнее.
            d = api("getUpdates", {"offset": offset, "timeout": 25}, tok, timeout=40)
            fails = 0
        except Exception as e:                      # сеть моргнула — не падаем
            fails += 1
            # Первые попытки повторяем почти сразу: обрыв соединения обычно
            # разовый, и десятисекундная пауза здесь стоила бы задержки ответа.
            pause = 2 if fails <= 3 else min(30, 5 * fails)
            print(f"ошибка опроса ({fails}): {e} — повтор через {pause} с", flush=True)
            time.sleep(pause)
            continue

        if not d.get("ok"):
            print(f"API вернул ошибку: {d.get('description')}", flush=True)
            time.sleep(15)
            continue

        for u in d.get("result", []):
            offset = u["update_id"] + 1
            edited = "edited_message" in u
            m = u.get("message") or u.get("edited_message")
            if not m or m.get("chat", {}).get("id") != CHAT_ID:
                continue

            # Сообщения самого бота пропускаем. Иначе получается петля: закрепление
            # или другое действие порождает служебное сообщение, приёмник считает его
            # входящим и будит оркестратора впустую.
            if (m.get("from") or {}).get("is_bot"):
                continue

            tid = m.get("message_thread_id", 0)

            # Название темы приходит только в служебном сообщении о её создании.
            created = m.get("forum_topic_created")
            if created:
                topics[tid] = created.get("name", f"тема {tid}")
                save_topics(topics)
                continue
            if tid not in topics:
                topics[tid] = "General" if tid == 0 else f"тема {tid}"
                save_topics(topics)

            # Вложения скачиваем на диск: оркестратор умеет читать картинки
            # и файлы, но только локальные. Ссылка Telegram ему бесполезна.
            saved = save_attachment(m, tok)

            # Служебные сообщения (закрепление, вход участника, смена названия)
            # не несут ни текста, ни вложений — записывать и будить нечего.
            text = m.get("text") or m.get("caption") or ""
            if not text and not saved:
                text = unsaved_note(m)
                if not text:
                    continue
            elif not saved and set(m) & MEDIA_KEYS:
                # Подпись дошла, а файл нет — без пометки оркестратор решит,
                # что владелец прислал только текст.
                text += "\n\n[вложение НЕ ПОЛУЧЕНО]"
            if saved:
                text = (text + "\n\n" if text else "") + f"Вложение: `{saved}`"

            quoted = quoted_ref(m, tid)
            if quoted:
                text = f"{quoted}\n\n{text}"

            # Правка — не новое сообщение. Помечаем явно, чтобы оркестратор
            # исправил прежний ответ, а не отвечал заново на то же самое.
            if edited:
                text = (f"[ПРАВКА сообщения #{m.get('message_id', 0)} — "
                        f"владелец изменил текст, отвечать заново не нужно]\n\n{text}")

            who = (m.get("from") or {}).get("first_name", "?")
            when = datetime.fromtimestamp(m.get("date", time.time())).strftime("%Y-%m-%d %H:%M")
            slug = "general" if tid == 0 else f"topic-{tid}"
            msg_id = m.get("message_id", 0)
            if msg_id:
                seen(msg_id, tok)
            append(slug, who, text, when, msg_id)
            print(f"[{when}] {who} → {topics[tid]}: {text[:60]}", flush=True)
            wake(text, topics[tid], who)

        write_offset(offset)


if __name__ == "__main__":
    main()
