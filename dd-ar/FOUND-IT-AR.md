# 🎯 لقيناه! — ملفات التعريب بتاعة Double Dealers

> اللي ظهر في فولدر `aa\StandaloneWindows64`:
> ```
> localization-string-tables-english(en)_assets_all.bundle     ← ملف التعريب الرئيسي ✅
> localization-string-tables-turkish(tr)_assets_all.bundle
> localization-string-tables-russian(ru)_assets_all.bundle
> localization-string-tables-japanese(ja)_assets_all.bundle
> localization-string-tables-chinese(simplified)(zh-Hans)_assets_all.bundle
> localization-string-tables-french(fr)_assets_all.bundle
> localization-string-tables-german(de)_assets_all.bundle
> localization-string-tables-korean(ko)_assets_all.bundle
> localization-string-tables-portuguese(pt)_assets_all.bundle
> localization-string-tables-spanish(es)_assets_all.bundle
> localization-locales_assets_all.bundle                        ← قائمة اللغات المتاحة
> localization-assets-shared_assets_all.bundle
> ```

اللعبة بتستخدم **Unity Localization + Addressables**، وكل لغة في ملف لوحدها. اللعبة بتدعم 9 لغات غير الإنجليزي = **مفيش عربي**، ومفيش مكان فاضي للعربي — لازم إحنا نضيفه.

كل ملف **21 كيلوبايت** بس (الروسية 24 ك.ب لأن الكيريلي أطول، والصيني 20). يعني الرفع سهل جدًا 👌

---

## الخطوة الجاية فورًا: ابعتلي الملفات دي (3 ملفات صغيرة)

من الفولدر:
```
E:\SteamLibrary\steamapps\common\Double Dealers Demo\Double Dealers - Demo_Data\StreamingAssets\aa\StandaloneWindows64\
```

| الملف | الحجم | ليه محتاجينه |
|-------|-------|--------------|
| `localization-string-tables-english(en)_assets_all.bundle` | 21 KB | ⭐ **أهم ملف** — فيه كل نصوص اللعبة بالإنجليزي |
| `localization-locales_assets_all.bundle` | 3 KB | قائمة اللغات — عشان نعرف نضيف العربي صح |
| `localization-assets-shared_assets_all.bundle` | 10 KB | الجداول المشتركة |

واختياري (برضه صغير): `catalog.bin` (12 KB) و `settings.json` (1 KB) من فولدر `aa` نفسه.

### طريقة الإرسال (اتنين، اختار الأسهل عليك)

**الطريقة 1 — زيب بإيدك:**
1. اعمل فولدر جديد على **سطح المكتب** اسمه `dd-files`.
2. كوبي فيه الـ3 ملفات اللي فوق (كوبي، مش قص).
3. كليك يمين على الفولدر → **Send to** → **Compressed (zipped) folder**.
4. في الشات ده، اضغط على أيقونة **المشبك 📎** جنب مربع الكتابة، واختار ملف الزيب.

**الطريقة 2 — سكريبت جاهز (لو الرفع وقّف معاك أو الكوبي تعبك):**
1. نزّل الملف: `dd-ar/windows/collect-localization-files.bat`
2. حُطّه على **سطح المكتب** ودوس عليه **دبل كليك**.
3. هو هيلاقي اللعبة لوحده، ينسخ الـ6 ملفات على سطح المكتب في فولدر `dd-files`، يزيّبهم في ملف واحد **`dd-localization.zip`**، ويفتحلك الفولدر.
4. اسحب ملف `dd-localization.zip` وارميه في الشات. ✋ خلاص.

> لو اللعبة عندك في مسار تاني غير `E:\SteamLibrary\...`، افتح الـ.bat بالنوت باد وغيّر السطر `set "GAME=..."` للمسار بتاعك، واحفظ.

---

## بعد ما تبعتهم، أنا هعمل إيه بالظبط

1. **هفك الملف** وأطلّع كل نصوص اللعبة (IDs + النصوص الإنجليزية) — كل جملة، كل بند (Clause)، كل كارت، كل زر في الواجهة.
2. **هترجمها كلها للعربي** بترجمة متّسقة (نفس المصطلح في كل مكان، من غير ترجمة آلية ركيكة) + نسخة "جاهزة للعرض" للحروف المتوصّلة.
3. **هجهّزلك الناتج في صورة واحدة من دول** (حسب اللي يشتغل أحسن على جهازك):
   - **ملف ترجمة عربي** تحطّه جوه فولدر اللعبة → العربي يظهر من غير تعديل أي ملف أصلي (الأأمن).
   - **أو ملف bundle جديد بالعربي** يستبدل ملف الإنجليزي بعد أخد نسخة احتياطية (بيعرّب كل حاجة حتى الكلام اللي بيتكتب من السيرفر).
4. **هجهّزلك الخط**: أكتبلك بالظبط إعداد الخط العربي عشان الحروف ما تطلعش مربعات ▯▯▯.
5. وأقولك خطوة بخطوة إزاي ترجّع كل حاجة زي ما كانت لو حبيت.

**خُد نسخة احتياطية من فولدر `aa` كله قبل أي تعديل** (حجمه صغير جدًا، دقيقة شغل).

---

## ملاحظة عن الترجمة الرسمية

الملفات دي بتورّيك حاجة مهمة: إضافة لغة جديدة عندهم = **إضافة ملف واحد**. يعني لو كلّمتهم على الديسكورد في طلب عربي، الموضوع عندهم **مش مستحيل** — المهم إن حد يبعتلهم الترجمة جاهزة. وهو ده اللي إحنا بنعمله دلوقتي. لو عايز بعد كده تبعتلهم ملف عربي جاهز، قوللي **"اكتب الرسالة"**.
