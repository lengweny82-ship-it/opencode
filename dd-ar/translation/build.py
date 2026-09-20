#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build.py — يبني ملفات الترجمة النهائية لـ XUnity.AutoTranslator من pairs.txt
  pairs.txt : سطور بالشكل   English ||| العربية
المخرجات:
  _AutoTranslations.ar.txt               عربي عادي (لو المحرك بيدعم RTL)
  _AutoTranslations.display-ready.ar.txt  عربي موصول ومعكوس (لمحركات LTR زي TextMeshPro)
"""
from pathlib import Path
try:
    import arabic_reshaper
    from bidi.algorithm import get_display
except ImportError:
    raise SystemExit("pip install arabic-reshaper python-bidi")

AR = range(0x0600, 0x06FF + 1)
def has_ar(s): return any(ord(c) in AR for c in s)
def display(s):
    if not has_ar(s): return s
    return get_display(arabic_reshaper.reshape(s))

src = Path(__file__).with_name("pairs.txt")
rows, seen = [], set()
bad = 0
for ln, line in enumerate(src.read_text(encoding="utf-8").splitlines(), 1):
    if not line.strip() or line.lstrip().startswith("#"): continue
    if " ||| " not in line:
        bad += 1; print(f"⚠️  سطر {ln} بدون فاصل: {line[:60]}"); continue
    en, ar = line.split(" ||| ", 1)
    en, ar = en.rstrip("\n"), ar.strip()
    if not en or not ar: bad += 1; continue
    if en in seen: continue          # المفاتيح المتكررة تُهمَل
    seen.add(en)
    rows.append((en, ar))

plain = ["# ملف تعريب Double Dealers — عربي (نسخة عادية)", "# الصيغة: النص الإنجليزي=الترجمة العربية", ""]
disp  = ["# ملف تعريب Double Dealers — عربي (نسخة جاهزة للعرض: حروف موصولة + ترتيب صحيح لمحركات LTR)", ""]
for en, ar in rows:
    plain.append(f"{en}={ar}")
    disp.append(f"{en}={display(ar)}")

(Path(__file__).with_name("_AutoTranslations.ar.txt")).write_text("\n".join(plain) + "\n", encoding="utf-8")
(Path(__file__).with_name("_AutoTranslations.display-ready.ar.txt")).write_text("\n".join(disp) + "\n", encoding="utf-8")

n_ar = sum(1 for _, a in rows if has_ar(a))
print(f"✅ عدد النصوص المترجمة : {len(rows)}")
print(f"   منها فيها حروف عربية : {n_ar}")
print(f"   أسطر فيها مشاكل      : {bad}")
print("📄 _AutoTranslations.ar.txt")
print("📄 _AutoTranslations.display-ready.ar.txt")
