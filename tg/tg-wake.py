#!/usr/bin/env python3
"""Мгновенная доставка сообщения из Telegram в сессию оркестратора.

Единственное назначение: взять текст, пришедший от владельца проекта в Telegram,
и положить его в сессию оркестратора немедленно — вместо ожидания обхода.

Как это работает: у каждой живой сессии Claude Code есть unix-сокет
/tmp/cc-socks/<pid>.sock с правами 600. Запись в него JSON-строки
{"type":"user","message":{"role":"user","content":"…"}} доставляет сообщение
в сессию — тем же путём, каким приходят сообщения от соседних сессий.
Механизм описан в самом Claude Code.

Границы, намеренно узкие:
  • пишет ТОЛЬКО в сокет, путь к которому лежит в .kit-state/orchestrator.sock;
  • ничего не выполняет, ничего не читает из проекта, в сеть не ходит;
  • текст всегда помечается источником, чтобы оркестратор видел,
    что сообщение пришло из Telegram, а не набрано в его окне.

Использование:
    tg-wake.py "<текст>" [--topic "<название темы>"] [--from "<имя>"]
    echo "<текст>" | tg-wake.py
"""

import argparse
import json
import os
import socket
import sys

from kitconf import ConfigError, state_dir

HERE = os.path.dirname(os.path.abspath(__file__))


def sock_pointer() -> str:
    try:
        return os.path.join(state_dir(), "orchestrator.sock")
    except ConfigError as e:
        sys.exit(str(e))


def socket_path() -> str:
    """Путь к сокету оркестратора. Записывается им самим при настройке."""
    pointer = sock_pointer()
    if not os.path.exists(pointer):
        sys.exit(
            f"не задан сокет оркестратора: нет файла {pointer}\n"
            "Оркестратор записывает туда значение $CLAUDE_CODE_MESSAGING_SOCKET."
        )
    p = open(pointer, encoding="utf-8").read().strip()
    if not p:
        sys.exit(f"файл {pointer} пуст")
    if not os.path.exists(p):
        sys.exit(
            f"сокет {p} не существует — сессия оркестратора, вероятно, закрыта.\n"
            "Сообщение остаётся в dialog/, оркестратор увидит его на обходе."
        )
    return p


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("text", nargs="?", help="текст сообщения")
    ap.add_argument("--topic", default="", help="название темы, откуда пришло")
    ap.add_argument("--from", dest="sender", default="", help="кто написал")
    a = ap.parse_args()

    text = a.text if a.text is not None else sys.stdin.read()
    text = text.strip()
    if not text:
        sys.exit("пустое сообщение, отправлять нечего")

    # Источник указывается всегда: оркестратор должен отличать сообщение
    # из Telegram от того, что владелец набрал прямо в окне сессии.
    head = "[Telegram"
    if a.topic:
        head += f" · тема «{a.topic}»"
    head += "]"
    if a.sender:
        head += f" {a.sender}:"

    payload = {
        "type": "user",
        "message": {"role": "user", "content": f"{head}\n\n{text}"},
    }

    p = socket_path()
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    try:
        s.connect(p)
        s.sendall((json.dumps(payload, ensure_ascii=False) + "\n").encode("utf-8"))
    finally:
        s.close()
    print(f"доставлено в сессию оркестратора ({os.path.basename(p)})")


if __name__ == "__main__":
    main()
