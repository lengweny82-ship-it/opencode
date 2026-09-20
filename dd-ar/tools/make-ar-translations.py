#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make-ar-translations.py — يحوّل ملف ترجمة عربي عادي إلى نسخة "جاهزة للعرض"
في الألعاب اللي مفيهاش دعم RTL.

الفكرة: معظم محركات ألعاب Unity (TextMeshPro) بترسم النص من الشمال لليمين
وبتوصلش الحروف العربية. فبنحوّل العربي لـ "Arabic Presentation Forms" (الحروف
المتوصّلة) وبنعكس ترتيب السطر — فالنتيجة تطلع مضبوطة على الشاشة.

الاستخدام:
   python3 make-ar-translations.py input.txt              # input.txt فيه سطور  English=العربي
   python3 make-ar-translations.py input.txt -o out.txt
   python3 make-ar-translations.py --test                 # تجربة سريعة

بيطلّع ملفين:
   <name>-plain.txt          العربي عادي (لو اللعبة بتدعم RTL بنفسها)
   <name>-display-ready.txt  العربي مُشكَّل ومعكوس (لو الحروف بتطلع مقطّعة/مقلوبة)
"""
import argparse
import sys
from pathlib import Path

try:
    import arabic_reshaper
    from bidi.algorithm import get_display
except ImportError:
    sys.exit("لازم تشغّل الأول:  pip install arabic-reshaper python-bidi")

AR_RANGE = range(0x0600, 0x06FF + 1)


def has_arabic(s: str) -> bool:
    return any(ord(c) in AR_RANGE for c in s)


def to_display(s: str) -> str:
    """يحوّل العربي لحروف متوصّلة + ترتيب عرض صحيح لمحرّك LTR"""
    if not has_arabic(s):
        return s
    # نحافظ على الجمل الإنجليزية/الأرقام اللي جوه النص
    reshaped = arabic_reshaper.reshape(s)
    return get_display(reshaped)


def convert(text: str, mode: str) -> str:
    return text if mode == "plain" else to_display(text)


def process(infile: Path, outbase: Path) -> None:
    lines = infile.read_text(encoding="utf-8").splitlines()
    plain, ready = [], []
    for line in lines:
        if not line.strip() or line.lstrip().startswith(("#", "//", ";")):
            plain.append(line)
            ready.append(line)
            continue
        if "=" in line:
            key, _, val = line.partition("=")
            plain.append(f"{key}={val}")
            ready.append(f"{key}={to_display(val)}")
        else:
            plain.append(line)
            ready.append(to_display(line))

    p1 = outbase.with_name(outbase.name + "-plain.txt")
    p2 = outbase.with_name(outbase.name + "-display-ready.txt")
    p1.write_text("\n".join(plain) + "\n", encoding="utf-8")
    p2.write_text("\n".join(ready) + "\n", encoding="utf-8")
    print(f"✅ اتعمل: {p1}")
    print(f"✅ اتعمل: {p2}")


def selftest() -> None:
    samples = ["Market Phase", "The auction begins!", "السوق", "Sold! 25 coins", "Ready", "12"]
    for s in samples:
        print(f"{s:22} -> {to_display(s)}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("input", nargs="?", help="ملف الترجمة (سطور English=العربي)")
    ap.add_argument("-o", "--output", help="اسم ملف الخروج بدون الامتداد")
    ap.add_argument("--test", action="store_true", help="تجربة سريعة")
    a = ap.parse_args()

    if a.test or not a.input:
        selftest()
    else:
        inp = Path(a.input)
        outbase = Path(a.output) if a.output else inp.with_suffix("")
        process(inp, outbase)
