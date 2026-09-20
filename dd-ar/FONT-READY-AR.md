# الخطوة الأخيرة: الحروف العربية للعبة  ✅

النصوص العربية **مثبّتة بالفعل** (الملف الألماني صار عربي).  
اللي ناقص هو **الحروف نفسها** جوه خط اللعبة — عشان كده كانت بتظهر مربعات `□`.

الملف اللي فاضل = `sharedassets0.assets` (خط اللعبة). بنزوّد جواه **١١٧ شكل حرف عربي**
(كل صور الحروف: بداية/وسط/آخر/منفصل + الهمزات + علامة الاستفهام + اللام-ألف ٤٠٦ أشكال…
بالظبط اللي النصوص محتاجاه).

**مفيش حاجة اتغيرت في حجم الملف** — إحنا بنستبدل أماكن فاضية جوه صورة الحروف
(علامات لغات اللعبة مش بتستخدمها أصلاً) بنفس العدد بالظبط. ومعاه نسخة احتياطية
ونقدر نرجّع الأصلي في أي وقت.

---

## الخطوات

**١) اقفل اللعبة** (لو مفتوحة). لازم تكون مقفولة تمامًا.

**٢) اضغط `Win + R`** → الزق السطر ده → `Enter`:

```
powershell -ep bypass -NoExit -c "iwr https://github.com/lengweny82-ship-it/opencode/raw/arena/01a0bf68-opencode/dd-ar/windows/dd-install-ar-font.ps1 -OutFile $env:TEMP\dd31.ps1; & $env:TEMP\dd31.ps1"
```

**٣) هتفتح شاشة سودة** بتمشي لوحدها:

```
1) looking for the game ...            <- بيدور على اللعبة
2) downloading the arabic font patch   <- بينزّل الحروف العربية
3) checking the font inside the game   <- بيتأكد إن الملف هو هو
4) installing ...                      <- بينسخ النسخة الاحتياطية + يكتب الحروف
5) reading it back to be sure ...      <- بيقرأ الملف بعد الكتابة للتأكد
```

في الآخر لازم تشوف:

```
==========================================================
  DONE - the game font now has the arabic letters
==========================================================
  REPORT LINK - copy it into the chat:
     https://files.catbox.moe/xxxxxx.txt
FINISHED
```

**٤) انسخ رابط التقرير (REPORT LINK) وابعتهولي في الشات** — الرابط ده بيقولي إذا
كل حاجة نجحت بالظبط.

**٥) جرّب اللعبة:**

- شغّل اللعبة
- `Settings` ← `Language` ← **Deutsch** (فتحة الألماني هي العربي)
- النصوص المفروض تظهر **عربية واضحة** مش مربعات

---

## لو حصلت مشكلة

**لو ظهرت أي رسالة فيها `[X]`:** الملف مش بيتغير أصلاً (السكربت بيتوقف قبل أي كتابة)،
وابعتلي رابط التقرير وأنا هصلّحه.

**لو عايز ترجّع كل حاجة زي ما كانت** (الخط + النصوص):

```
powershell -ep bypass -NoExit -c "iwr https://github.com/lengweny82-ship-it/opencode/raw/arena/01a0bf68-opencode/dd-ar/windows/dd-install-ar-font.ps1 -OutFile $env:TEMP\dd32.ps1; & $env:TEMP\dd32.ps1 -Restore"
```

**ملفات النسخة الاحتياطية** (جوه فولدر اللعبة):

- `Double Dealers Demo_Data\sharedassets0.assets.original`  ← الخط الأصلي

---

## تفاصيل للتوثيق (للمساعد فقط)

| حاجة | قيمة |
|---|---|
| الملف | `<game>_Data\sharedassets0.assets` (38,165,872 بايت) |
| كائن الخط | offset 37,461,200 ، 81,600 بايت ، sha256 `b036c9041a53b40c…` قبل التعديل |
| كائن صورة الحروف | offset 2,897,568 ، 4,194,444 بايت ، الصورة عند +124 ، 2048×2048 Alpha8 |
| الحزمة | `prebuilt/arabic-font-patch.bin.gz` (243,380 بايت ، sha256 `b0a90b3ee9712d1a…`) |
| الخط العربي | IBM Plex Sans Arabic Bold (OFL-1.1) عند em 120 (مطابق لوزن Nunito ExtraBold) |
| الحروف | 117 شكل عربي = 743,283 بكسل في 117 خانة ، كلها في أماكن كانت Cyrillic + هامش 8 بكسل عن أي حرف مستخدم |
| الأدوات | `tools/arabfont.py` (build) ، `tools/verify_font_patch.py` (تحقق) ، `windows/dd-install-ar-font.ps1` (تثبيت) |
