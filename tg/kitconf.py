#!/usr/bin/env python3
"""Чтение project.conf из корня проекта — тех же настроек, что читает bash.

Зачем отдельный разборщик, а не JSON: файл настроек в первую очередь читает
и правит человек, заводящий новый проект, и ему нужны комментарии — чем
отличается один ключ от другого и где взять значение. JSON комментариев
не держит. Обратный вариант — JSON, который bash разбирает через python3 —
означал бы запуск интерпретатора на каждый вызов каждого tg-*.sh, включая
пути с ошибками. Дешевле один раз написать эти тридцать строк.

Цена решения: формат приходится ограничить до подмножества shell, которое
оба языка понимают одинаково. Подстановки запрещены и вызывают ошибку —
молча разойтись с bash хуже, чем отказаться работать.

Корень проекта ищется тем же способом, что в kit-common.sh: вверх от каталога
кита до каталога с project.conf. Разойдутся два поиска — разойдутся и настройки,
причём молча, поэтому правило одно на оба языка.

Использование:
    from kitconf import require
    CHAT_ID, KEYCHAIN_SERVICE = require("TG_CHAT_ID", "TG_KEYCHAIN_SERVICE")
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
KIT_DIR = os.path.abspath(os.path.join(HERE, ".."))
EXAMPLE_PATH = os.path.join(KIT_DIR, "project.conf.example")

KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
PLACEHOLDER_RE = re.compile(r"<[^>]*>")
FORBIDDEN = ("$", "`", "\\")


class ConfigError(Exception):
    """Файл настроек не читается или написан не в том подмножестве формата."""


def find_root(start: str = None) -> str:
    """Корень проекта: ближайший каталог НАД китом, где лежит project.conf.

    Поиск начинается с родителя кита, а не с самого кита: кит общий для всех
    проектов и подключается подмодулем, поэтому настройки внутри него лежать
    не должны — при обновлении подмодуля они затрутся.

    Переменная KIT_PROJECT_ROOT перебивает поиск: нужна для проверок
    и для раскладок, где project.conf ещё не заведён.
    """
    env = os.environ.get("KIT_PROJECT_ROOT")
    if env:
        return os.path.abspath(env)
    d = start or os.path.dirname(KIT_DIR)
    d = os.path.abspath(d)
    while True:
        if os.path.isfile(os.path.join(d, "project.conf")):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            raise ConfigError(
                f"не найден корень проекта: ни в одном каталоге над {KIT_DIR} "
                f"нет project.conf\n"
                f"создать: cp {EXAMPLE_PATH} "
                f"{os.path.join(os.path.dirname(KIT_DIR), 'project.conf')} и заполнить"
            )
        d = parent


def conf_path() -> str:
    return os.path.join(find_root(), "project.conf")


def state_dir() -> str:
    """Каталог рабочего состояния: offset приёмника, указатели оркестратора.

    Лежит в корне проекта, а не в ките, чтобы переустановка подмодуля
    его не задевала. Создаётся по требованию — читатели должны переживать
    его отсутствие.
    """
    env = os.environ.get("KIT_STATE_DIR")
    return os.path.abspath(env) if env else os.path.join(find_root(), ".kit-state")


def _value(raw: str, path: str, lineno: int) -> str:
    """Значение справа от «=»: в кавычках или голое, с отрезанным комментарием."""
    raw = raw.strip()
    for q in ('"', "'"):
        if raw.startswith(q):
            end = raw.find(q, 1)
            if end < 0:
                raise ConfigError(f"{path}:{lineno}: не закрыта кавычка {q}")
            val, rest = raw[1:end], raw[end + 1:].strip()
            if rest and not rest.startswith("#"):
                raise ConfigError(f"{path}:{lineno}: лишнее после закрывающей кавычки: {rest!r}")
            # В одинарных кавычках bash ничего не подставляет — и мы тоже.
            if q == "'":
                return val
            break
    else:
        # Голое значение: комментарий отделяется пробелом, как в shell.
        val = re.split(r"\s+#", raw, maxsplit=1)[0].strip()

    for ch in FORBIDDEN:
        if ch in val:
            raise ConfigError(
                f"{path}:{lineno}: символ {ch!r} в значении. Подстановки запрещены: "
                "bash их раскроет, Python нет, и настройки разъедутся между скриптами. "
                "Впиши готовое значение или возьми его в одинарные кавычки."
            )
    return val


def load(path: str = None) -> dict:
    """Разобрать файл настроек. Кидает ConfigError на любой непонятной строке."""
    path = path or conf_path()
    if not os.path.exists(path):
        raise ConfigError(
            f"нет файла настроек {path}\n"
            f"создать: cp {EXAMPLE_PATH} {path} и заполнить"
        )
    conf = {}
    with open(path, encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                raise ConfigError(f"{path}:{lineno}: строка без «=»: {line!r}")
            key, raw = line.split("=", 1)
            key = key.strip()
            if not KEY_RE.match(key):
                raise ConfigError(f"{path}:{lineno}: недопустимое имя ключа {key!r}")
            conf[key] = _value(raw, path, lineno)
    return conf


def require(*keys: str, path: str = None):
    """Значения перечисленных ключей. Незаполненные — внятная ошибка и выход.

    Незаполненным считается и пустое значение, и оставшийся <плейсхолдер>.
    Плейсхолдер ищется в любом месте значения, а не только целиком: в шаблоне
    есть ключи вида «telegram-bot-token-<проект>», и заполненными наполовину
    они выглядят правдоподобно ровно до первого обращения к Keychain.

    Выход через sys.exit, а не исключение: вызывающие — скрипты, и трейсбек
    в их логе ничего не объясняет тому, кто просто не заполнил настройки.
    """
    try:
        path = path or conf_path()
        conf = load(path)
    except ConfigError as e:
        sys.exit(str(e))

    missing = [k for k in keys
               if not conf.get(k) or PLACEHOLDER_RE.search(conf[k])]
    if missing:
        sys.exit(
            f"в {path} не заполнены настройки:\n"
            + "".join(f"  {k}\n" for k in missing)
            + f"заполни их и повтори; пояснения — в {EXAMPLE_PATH}"
        )

    values = [conf[k] for k in keys]
    return values[0] if len(values) == 1 else tuple(values)


if __name__ == "__main__":
    # Проверка файла настроек без запуска моста: kitconf.py [ключ …]
    # Без аргументов печатает и найденные пути — это первое, что нужно знать,
    # когда «скрипт читает не те настройки».
    try:
        p = conf_path()
        c = load(p)
    except ConfigError as e:
        sys.exit(str(e))
    args = sys.argv[1:]
    if not args:
        print(f"# корень проекта: {find_root()}")
        print(f"# настройки:      {p}")
        print(f"# состояние:      {state_dir()}")
    for k in (args or sorted(c)):
        print(f"{k}={c.get(k, '')}")
