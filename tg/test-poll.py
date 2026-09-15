#!/usr/bin/env python3
"""Проверки приёмника. Запуск: claude-kit/tg/test-poll.py

Проверяется quoted_ref — разбор того, на что владелец ответил или что переслал.
Функция чистая: ни сети, ни токена, ни файлов, поэтому её можно гонять сколько
угодно и на любой машине.

Почему именно она. Ошибки здесь не падают, а тихо портят смысл: приёмник
допишет в dialog/ строку, где вопрос владельца выглядит адресованным всему
сообщению вместо выделенной фразы, и оркестратор ответит не на то. Такое
не заметно ни в логе, ни по коду возврата — только по чтению переписки.

Ни настроек, ни project.conf, ни проекта вокруг не требуется: приёмник читает
настройки в configure(), которую зовёт main(), а не на уровне модуля. Поэтому
проверки гоняются и на голом репозитории кита.
"""

import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)                 # чтобы нашёлся kitconf, который тянет tg-poll

spec = importlib.util.spec_from_file_location("tgpoll", os.path.join(HERE, "tg-poll.py"))
tgpoll = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(tgpoll)
except SystemExit as e:
    sys.exit(f"не удалось загрузить tg-poll.py: {e}")

quoted_ref = tgpoll.quoted_ref

TOPIC = 200                              # идентификатор темы во всех случаях ниже
REPLY = {"message_id": 246, "text": "Не могу — ограничение Telegram", "from": {"first_name": "Оркестратор"}}

# (название, сообщение, тема, чего ждём)
# Ожидание задаётся строкой целиком, а не подстрокой: формат строки попадает
# в dialog/ и читается человеком, поэтому меняться молча он не должен.
CASES = [
    (
        "обычный ответ — виден текст исходного сообщения",
        {"reply_to_message": REPLY}, TOPIC,
        "[в ответ на #246 от Оркестратор: «Не могу — ограничение Telegram»]",
    ),
    (
        "ответ на выделенную фразу — виден фрагмент, а не всё сообщение",
        {"reply_to_message": REPLY, "quote": {"text": "ограничение Telegram", "position": 9}}, TOPIC,
        "[в ответ на #246 от Оркестратор, выделено: «ограничение Telegram»]",
    ),
    (
        "корень темы — не ответ: в форуме reply_to_message есть у каждого сообщения",
        {"reply_to_message": {"message_id": TOPIC, "text": "название темы"}}, TOPIC,
        "",
    ),
    (
        "служебное сообщение о создании темы — тоже не ответ",
        {"reply_to_message": {"message_id": 209, "forum_topic_created": {"name": "новая тема"}}}, TOPIC,
        "",
    ),
    (
        "пересылка — виден автор оригинала",
        {"forward_origin": {"sender_user": {"first_name": "Пётр"}}}, TOPIC,
        "[переслано от Пётр]",
    ),
    (
        "пересылка от скрывшего профиль — есть только имя строкой",
        {"forward_origin": {"sender_user_name": "Аноним"}}, TOPIC,
        "[переслано от Аноним]",
    ),
    (
        "пересылка важнее ответа: переслать можно и ответное сообщение",
        {"forward_origin": {"sender_user": {"first_name": "Пётр"}}, "reply_to_message": REPLY}, TOPIC,
        "[переслано от Пётр]",
    ),
    (
        "длинный фрагмент обрезается, иначе строка dialog/ станет нечитаемой",
        {"reply_to_message": REPLY, "quote": {"text": "я" * 200}}, TOPIC,
        "[в ответ на #246 от Оркестратор, выделено: «" + "я" * 120 + "…»]",
    ),
    (
        "переводы строк схлопываются: в dialog/ пометка занимает одну строку",
        {"reply_to_message": dict(REPLY, text="первая\nвторая")}, TOPIC,
        "[в ответ на #246 от Оркестратор: «первая вторая»]",
    ),
    (
        "ответ на вложение без подписи — сообщение есть, текста нет",
        {"reply_to_message": {"message_id": 225, "from": {"first_name": "Владелец"}}}, TOPIC,
        "[в ответ на #225 от Владелец: «(без текста)»]",
    ),
    (
        "ответ на вложение с подписью — берётся caption",
        {"reply_to_message": {"message_id": 225, "caption": "подпись к вложению", "from": {"first_name": "Владелец"}}}, TOPIC,
        "[в ответ на #225 от Владелец: «подпись к вложению»]",
    ),
    (
        "обычное сообщение вне ответа и пересылки — пометки нет",
        {}, TOPIC,
        "",
    ),
]


# unsaved_note: сообщение без текста и без скачанного файла. Пустая строка —
# «служебное, пропустить»; всё прочее должно дойти до оркестратора пометкой.
# Проверка краснеет, если приёмник снова начнёт выбрасывать такие молча.
BASE = {"message_id": 372, "chat": {"id": 1}, "from": {"first_name": "Леонид"}, "date": 0}
NOTE_CASES = [
    ("служебное: закрепление — пропустить", {**BASE, "pinned_message": {}}, False),
    ("служебное: создание темы — пропустить", {**BASE, "forum_topic_created": {}}, False),
    ("фото без подписи, файл не скачался — пометка", {**BASE, "photo": [{}]}, True),
    ("документ без подписи, файл не скачался — пометка", {**BASE, "document": {}}, True),
    ("анимация, приёмник её не скачивает — пометка", {**BASE, "animation": {}}, True),
    ("неизвестный тип — пометка, а не тишина", {**BASE, "something_new": {}}, True),
]


def main() -> int:
    failed = 0
    for name, message, want_note in NOTE_CASES:
        got = tgpoll.unsaved_note(message)
        if bool(got) == want_note:
            print(f"  ок   {name}")
        else:
            failed += 1
            print(f"  ПЛОХО {name}")
            print(f"        ждали пометку: {want_note}, вышло: {got!r}")

    for name, message, topic, expected in CASES:
        got = quoted_ref(message, topic)
        if got == expected:
            print(f"  ок   {name}")
        else:
            failed += 1
            print(f"  ПЛОХО {name}")
            print(f"        ждали:  {expected!r}")
            print(f"        вышло: {got!r}")

    total = len(CASES) + len(NOTE_CASES)
    if failed:
        print(f"\nпровалено {failed} из {total}")
        return 1
    print(f"\nвсе {total} проверок прошли")
    return 0


if __name__ == "__main__":
    sys.exit(main())
