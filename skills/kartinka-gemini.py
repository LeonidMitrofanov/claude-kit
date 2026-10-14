#!/usr/bin/env python3
"""Генерация картинок через Gemini: Nano Banana Pro и Flash Image.

Только стандартная библиотека: ставить пакеты на сервер не нужно, а скрипт
должен работать и внутри клиентского контейнера, где кроме питона ничего нет.

Ключ лежит файлом с правами 600:
  ~/.config/claude-kit/gemini-key

Модели и цена за картинку (с ai.google.dev/pricing, 15.10.2026):
  pro    gemini-3-pro-image     $0,134 (1-2K), $0,24 (4K)   — Nano Banana Pro
  flash  gemini-2.5-flash-image $0,039                      — вчетверо дешевле

Flash хватает для схем, плашек и фонов. Pro берут там, где виден почерк:
сложная сцена, люди, текст внутри картинки.

Запуск:
  kartinka-gemini.py "промт" --kuda kadr.png
  kartinka-gemini.py "промт" --model pro --kuda kadr.png
  kartinka-gemini.py "промт" --iskhodnik lico.png --kuda novoe.png
"""
import argparse
import base64
import json
import mimetypes
import pathlib
import sys
import urllib.error
import urllib.request

MODELI = {
    "pro": "gemini-3-pro-image",
    "flash": "gemini-2.5-flash-image",
}
KLYUCH = pathlib.Path.home() / ".config" / "claude-kit" / "gemini-key"


def klyuch() -> str:
    if not KLYUCH.exists():
        sys.exit(f"нет ключа: {KLYUCH}\n"
                 f"положить: umask 077 && printf '%s' '<ключ>' > {KLYUCH}")
    return KLYUCH.read_text(encoding="utf-8").strip()


def zapros(model: str, chasti: list, api: str) -> dict:
    url = (f"https://generativelanguage.googleapis.com/v1beta/models/"
           f"{model}:generateContent?key={api}")
    telo = json.dumps({"contents": [{"parts": chasti}]}).encode("utf-8")
    req = urllib.request.Request(url, data=telo,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            return json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        # Текст ошибки у Google содержит причину — без него видно только «400».
        sys.exit(f"Gemini ответил {e.code}: {e.read().decode('utf-8')[:400]}")


def vytashchit(otvet: dict, kuda: pathlib.Path) -> None:
    kandidaty = otvet.get("candidates") or []
    if not kandidaty:
        sys.exit(f"ответ без картинки: {json.dumps(otvet)[:300]}")
    for chast in kandidaty[0].get("content", {}).get("parts", []):
        dannye = chast.get("inlineData") or chast.get("inline_data")
        if dannye:
            kuda.write_bytes(base64.b64decode(dannye["data"]))
            print(f"готово: {kuda} ({kuda.stat().st_size // 1024} КБ)")
            return
    # Модель иногда отвечает текстом вместо картинки — например когда промт
    # она сочла недопустимым. Печатаем этот текст, а не молчим.
    teksty = [c.get("text", "") for c in
              kandidaty[0].get("content", {}).get("parts", [])]
    sys.exit("картинки в ответе нет. Модель сказала: " + " ".join(teksty)[:400])


razbor = argparse.ArgumentParser(description=__doc__)
razbor.add_argument("promt", help="что нарисовать")
razbor.add_argument("--kuda", required=True, help="куда положить файл")
razbor.add_argument("--model", default="flash", choices=sorted(MODELI),
                    help="flash — дёшево, pro — качественнее (по умолчанию flash)")
razbor.add_argument("--iskhodnik", help="картинка-основа: правка вместо рисования с нуля")
args = razbor.parse_args()

chasti = [{"text": args.promt}]
if args.iskhodnik:
    f = pathlib.Path(args.iskhodnik)
    if not f.exists():
        sys.exit(f"нет файла: {f}")
    tip = mimetypes.guess_type(str(f))[0] or "image/png"
    chasti.append({"inlineData": {
        "mimeType": tip,
        "data": base64.b64encode(f.read_bytes()).decode("ascii"),
    }})

vytashchit(zapros(MODELI[args.model], chasti, klyuch()), pathlib.Path(args.kuda))
