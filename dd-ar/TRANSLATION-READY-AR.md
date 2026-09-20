# 🎉 الترجمة العربية جاهزة! — Double Dealers

**اللي حصل:** فكّينا ملف اللعبة واستخرجنا **541 نص** (كل الكلام اللي في اللعبة)، وترجمنا **533 نص** منهم للعربي ترجمة يدوية متّسقة، وجهّزنا ملف تعريب جاهز للتركيب.

---

## ✅ خطوة 1: تأكد إن مود الترجمة مركّب

لو **لسه** مركّبتش المود، اتبع `START-HERE-AR.md` (تركيب MelonLoader + XUnity.AutoTranslator-IL2CPP).
**ولو مركّبته خلاص، اتفضل للخطوة 2.**

---

## ✅ خطوة 2: ثبّت الترجمة العربية (أمر واحد)

اضغط **Win + R** والصق الأمر ده ثم **Enter**:

```
powershell -ep bypass -c "iwr https://github.com/lengweny82-ship-it/opencode/raw/arena/01a0bf68-opencode/dd-ar/windows/install-translation.ps1 -OutFile $env:TEMP\dd-ar.ps1; & $env:TEMP\dd-ar.ps1"
```

السكريبت ده بيعمل أوتوماتيك:
1. يلاقي فولدر اللعبة (من مسارات ستيم)
2. ينزّل ملف الترجمة العربية (533 نص) من مشروعنا
3. يحطه في المكان الصح: `...\Double Dealers Demo\AutoTranslator\Translation\ar\Text\`
4. **يغيّر اللغة في الإعدادات لـ `Language=ar`** لوحده (مع نسخة احتياطية `.bak`)

---

## ✅ خطوة 3: شغّل اللعبة

- شغّل اللعبة عادي من ستيم.
- جوه اللعبة اضغط **ALT + R** (يعيد تحميل ملف الترجمة).
- المفروض الكلام يظهر عربي 🎉

**مفاتيح المود مفيدة:**
| المفتاح | بيعمل إيه |
|---------|-----------|
| **ALT + R** | إعادة تحميل ملف الترجمة (اضغطه بعد أي تعديل) |
| **ALT + T** | تبديل بين العربي والأصلي |
| **ALT + 0** | فتح واجهة المود (زيرو مش O) |

---

## 🔧 لو لقيت مشاكل

### 1) العربي طالع مقطّع (م ر ح ل ة) أو مقلوب (ةيبرحلا)
ده لأن اللعبة مش بتدعم الاتجاه العربي. شغّل نفس الأمر بالنسخة الجاهزة للعرض:
```
powershell -ep bypass -c "iwr https://github.com/lengweny82-ship-it/opencode/raw/arena/01a0bf68-opencode/dd-ar/windows/install-translation.ps1 -OutFile $env:TEMP\dd-ar.ps1; & $env:TEMP\dd-ar.ps1 -DisplayReady"
```
النسخة دي فيها الحروف **موصولة** والكلام **بترتيب عرض مضبوط** لمحركات Unity.
بعد ما تشغّلها، اضغط **ALT + R** جوه اللعبة.

### 2) بتبان مربعات فاضية ▯▯▯ بدل الحروف
الخط المستخدم في اللعبة مفيش فيه حروف عربي. الحل: ملف الخطوط الاحتياطية:
1. نزّل: https://github.com/bbepis/XUnity.AutoTranslator/releases/tag/v5.4.4 ← `TMP_Font_AssetBundles.zip`
2. فكّه جوه فولدر اللعبة (بـ 7-Zip أو ويندوز نفسه)
3. افتح `AutoTranslator\Config.ini` واضبط:
   ```ini
   [Behaviour]
   FallbackFontTextMeshPro=arialuni_sdf_u2018
   ```
4. شغّل اللعبة و **ALT + R**

### 3) النص طويل وبيخرج بره الأزرار
افتح `Config.ini` وخلي:
```ini
[Behaviour]
EnableUIResizing=True
```

---

## 📊 إحصائيات الترجمة

| البند | العدد |
|-------|-------|
| نصوص اللعبة المستخرجة | 541 |
| نصوص مترجمة | **533** |
| أسماء العناصر (Antique Vase, Katana...) | ✅ كلها |
| أسماء الكروت (Robin Hood, Loan Shark...) | ✅ كلها |
| البنود (Clauses) كاملة | ✅ |
| الإعدادات والقوائم | ✅ |
| رسائل الأخطاء والشبكة | ✅ |

**التعريب مش بيغيّر أي ملف من ملفات اللعبة** — الترجمة بتتحمّل وقت التشغيل عن طريق المود، ولو حبيت ترجّع اللعبة زي ما كانت: امسح فولدر `AutoTranslator` (أو شيل ملف الترجمة بس).

---

## ✏️ عايز تعدّل أي ترجمة؟

1. افتح الملف: `...\Double Dealers Demo\AutoTranslator\Translation\ar\Text\_AutoTranslations.ar.txt`
2. عدّل أي سطر بالشكل ده:
   ```
   Market Phase=مرحلة السوق
   ```
   (سيب النص الإنجليزي زي ما هو بالظبط، وغيّر العربي بس)
3. جوه اللعبة اضغط **ALT + R**

أو عدّل الأصل في المشروع: `translation/pairs.txt` وبعدين شغّل `python3 translation/build.py` وهيتولّد الملف الجديد.

---

## 🎁 إضافة: لو حبيت العربي يبقى رسمي في اللعبة

عندك دلوقتي **ملف تعريب كامل**. تقدر تبعت لفريق التطوير (Miklagard Studios) على ديسكورد اللعبة:
> "I've prepared a complete Arabic localization for the game (533 strings, matching your string table). At least 420 million people speak Arabic and the game currently supports 10 languages but not Arabic. I'm happy to hand it over for free so you can add `ar` as an official language."

وبكده تبقى إنت **صاحب أول تعريب عربي رسمي للعبة** 👑 (قوللي لو عايز الرسالة بالإنجليزي كاملة وأنا أجهّزها).
