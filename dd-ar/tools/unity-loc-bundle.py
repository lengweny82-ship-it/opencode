#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
unity-loc-bundle.py — يقرأ ملفات ترجمة ألعاب Unity (.bundle)
المخصّص لـ Double Dealers (Unity Localization + Addressables)

الاستخدام:
    python3 unity-loc-bundle.py extract  <bundle-file>  [-o strings.csv]
    python3 unity-loc-bundle.py rebuild  <bundle-file>  <translations.txt>  [-o new.bundle]
    python3 unity-loc-bundle.py info     <bundle-file>

الملفات المستهدفة:
    localization-string-tables-english(en)_assets_all.bundle   ← نترجمه
    localization-locales_assets_all.bundle

الصيغ المدعومة للترجمة (translations.txt):  English=العربي  (سطر لكل نص)
"""
import argparse
import csv
import io
import sys
from pathlib import Path

try:
    import UnityPy
except ImportError:
    sys.exit("لازم تشغّل الأول:  pip install UnityPy")


def load_bundle(path: Path):
    return UnityPy.load(str(path))


def iter_objects(env):
    for obj in env.objects:
        yield obj


def object_type_name(obj) -> str:
    try:
        return obj.type.name
    except Exception:
        return str(obj.type)


def try_read_text_table(obj):
    """بيحاول يقرأ جدول نصوص Unity Localization من الـMonoBehaviour"""
    try:
        tree = obj.read_typetree()
    except Exception:
        return None
    if not isinstance(tree, dict):
        return None
    # Unity Localization StringTable → m_TableData : List<LocalizationTableEntry>
    data = tree.get("m_TableData")
    if not isinstance(data, list):
        return None
    rows = []
    for entry in data:
        if not isinstance(entry, dict):
            continue
        key_id = entry.get("m_Id") or entry.get("m_KeyId") or ""
        value = entry.get("m_Localized")
        if value is None:
            loc = entry.get("m_LocalizedString") or {}
            value = loc.get("m_Localized") if isinstance(loc, dict) else None
        if value is None:
            continue
        rows.append({"id": str(key_id), "en": str(value)})
    return (tree, rows) if rows else None


def raw_strings_from_bytes(raw: bytes):
    """استخراج احتياطي: كل النصوص المقروءة جوّه الملف (UTF-8)"""
    out = []
    cur = bytearray()
    for b in raw:
        if 32 <= b < 127 or b >= 0x80:
            cur.append(b)
        else:
            if len(cur) >= 4:
                try:
                    s = cur.decode("utf-8")
                    out.append(s)
                except UnicodeDecodeError:
                    pass
            cur = bytearray()
    if len(cur) >= 4:
        try:
            out.append(cur.decode("utf-8"))
        except UnicodeDecodeError:
            pass
    return out


def cmd_info(path: Path, _args, _opts):
    env = load_bundle(path)
    print(f"📦 {path.name}  ({path.stat().st_size/1024:.1f} KB)")
    from collections import Counter
    kinds = Counter()
    names = []
    for obj in env.objects:
        t = object_type_name(obj)
        kinds[t] += 1
        if t == "MonoBehaviour":
            try:
                d = obj.read()
                names.append(getattr(d, "m_Name", "") or "(بلا اسم)")
            except Exception:
                names.append("(تعذّر القراءة)")
    for t, c in kinds.items():
        print(f"   {t}: {c}")
    if names:
        print("   عناصر MonoBehaviour:", ", ".join(n for n in names[:10]))


def cmd_extract(path: Path, args, opts):
    env = load_bundle(path)
    rows = []
    for obj in env.objects:
        if object_type_name(obj) != "MonoBehaviour":
            continue
        res = try_read_text_table(obj)
        if res:
            _tree, rows = res
            break

    if not rows:
        print("⚠️  مقدرتش أقرأ الجدول بالطريقة الرسمية — هجرّب استخراج النصوص الخام.")
        raw = path.read_bytes()
        strings = raw_strings_from_bytes(raw)
        rows = [{"id": f"raw{i}", "en": s} for i, s in enumerate(strings)]

    out = Path(args.output) if args.output else path.with_suffix(".csv")
    with out.open("w", encoding="utf-8-sig", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["id", "en", "ar"])
        w.writeheader()
        for r in rows:
            w.writerow({"id": r.get("id", ""), "en": r.get("en", ""), "ar": ""})
    print(f"✅ استخرجت {len(rows)} نص → {out}")
    print("   عدّل عمود 'ar' وبعدين:  python3 unity-loc-bundle.py rebuild ...")


def cmd_rebuild(path: Path, args, opts):
    mapping = {}
    for line in Path(args.translations).read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if "=" in line:
            k, _, v = line.partition("=")
            mapping[k.strip()] = v.strip()

    env = load_bundle(path)
    changed = 0
    for obj in env.objects:
        if object_type_name(obj) != "MonoBehaviour":
            continue
        res = try_read_text_table(obj)
        if not res:
            continue
        tree, rows = res
        for entry in tree.get("m_TableData", []):
            if not isinstance(entry, dict):
                continue
            cur = entry.get("m_Localized")
            if isinstance(cur, str) and cur in mapping:
                entry["m_Localized"] = mapping[cur]
                changed += 1
        obj.save_typetree(tree)

    if changed == 0:
        sys.exit("❌ مفيش أي نص اتغيّر — تأكد إن مفاتيح ملف الترجمة مطابقة للنصوص الإنجليزية.")

    out = Path(args.output) if args.output else path.with_name(path.stem + "_AR" + path.suffix)
    with out.open("wb") as fh:
        fh.write(env.file.save(packer="original"))
    print(f"✅ اتغيّر {changed} نص → {out}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("command", choices=["info", "extract", "rebuild"])
    ap.add_argument("bundle")
    ap.add_argument("translations", nargs="?")
    ap.add_argument("-o", "--output")
    args = ap.parse_args()
    path = Path(args.bundle)
    if not path.exists():
        sys.exit(f"مفيش ملف بالاسم ده: {path}")
    {"info": cmd_info, "extract": cmd_extract, "rebuild": cmd_rebuild}[args.command](path, args, None)


if __name__ == "__main__":
    main()
