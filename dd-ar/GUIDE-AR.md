# دليل تعريب Double Dealers (Demo) للعربي

> اللعبة: **Double Dealers** — Miklagard Studios — مبنية على **Unity**، نسخة ويندوز.
> Demo (Steam App ID `4750320`) — Full Game (App ID `4218620`).
> آخر تحديث للدليل: سبتمبر 2026.

---

## 1) الخلاصة في 30 ثانية

سؤالك "فين ملف التعريب؟" — الجواب المختصر:

**مفيش ملف واحد اسمه "التعريب" في أغلب ألعاب Unity.** النصوص بتتخزّن في واحد (أو أكتر) من 4 أماكن، ولازم تحدد أي واحد عندك قبل ما تعدّل:

| # | المكان | شكله | صعوبة التعريب |
|---|--------|------|---------------|
| 1 | `StreamingAssets` | ملفات `.csv` / `.json` / `.txt` / `.po` | 🟢 سهل جدًا — تعديل مباشر |
| 2 | `StreamingAssets/aa/...` | ملفات `.bundle` (Unity Localization + Addressables) | 🟡 متوسط — تحتاج UABEA/AssetRipper |
| 3 | `*_Data/resources.assets` | MonoBehaviour اسمه `i2languages` (I2 Localization) | 🟡 متوسط — تحتاج UABEA + pyI2L |
| 4 | `Assembly-CSharp.dll` أو `global-metadata.dat` | نصوص مكتوبة جوّه الكود | 🔴 صعب — تعديل DLL أو مود وقت التشغيل |

⚠️ **الأهم:** أي تعديل مباشر على ملفات اللعبة = **للاستخدام الشخصي بس**، وممكن يتهدم مع أي تحديث. لما تحب توزّع، استخدم **مود** (زي XUnity.AutoTranslator) أو الأفضل: كلّم المطورين على الديسكورد يضيفوا عربي رسمي — اللعبة أصلاً بتدعم 10 لغات، فالأساس موجود.

---

## 2) خطوة بخطوة: حدّد الملف بتاعك في 3 دقايق

### أ) وصّل على فولدر اللعبة
في Steam: كليك يمين على اللعبة ← **Manage** ← **Browse local files**
المسار الافتراضي:
```
C:\Program Files (x86)\Steam\steamapps\common\Double Dealers Demo\
```

### ب) شغّل السكريبت الجاهز (موجود معاك في الفولدر ده)

**ويندوز (PowerShell):**
```powershell
powershell -ExecutionPolicy Bypass -File .\find-localization.ps1
# أو بمسار صريح:
powershell -ExecutionPolicy Bypass -File .\find-localization.ps1 -GameDir "C:\Program Files (x86)\Steam\steamapps\common\Double Dealers Demo"
```

**لينكس / WSL / Git Bash / macOS:**
```bash
bash find-localization.sh "/mnt/c/Program Files (x86)/Steam/steamapps/common/Double Dealers Demo"
```

السكريبت بيعمل إيه؟
1. يلاقي فولدر اللعبة لوحده (من `libraryfolders.vdf` بتاع Steam).
2. يقولك البِلد Mono ولا IL2CPP.
3. يلِست كل ملفات النصوص الظاهرة (CSV/JSON/...) — دي أول حاجة تبص عليها.
4. **يفتّش على كلمات اللعبة نفسها** (`Clause`, `Auction`, `Bid`, `Market`, `Seller`...) جوّه الملفات الثنائية، ويديك **اسم الملف + مكان الكلمة جواه بالبايت** ← ده بالظبط "فين ملف التعريب".
5. يقولك نظام التعريب المستخدم (I2 Localization / Unity Localization / مكتوب في الكود).
6. يحفظ التقرير في `localization-report.txt` جنبه.

### ج) بديل يدوي سريع (لو مش عاوز تشغّل سكريبت)
في PowerShell:
```powershell
$g = "C:\Program Files (x86)\Steam\steamapps\common\Double Dealers Demo"
Get-ChildItem $g -Recurse -File | Where-Object { $_.Extension -in ".csv",".json",".txt",".po",".xml" } | Select FullName, Length
# وبعدين دوّر في الملفات الثنائية:
Get-ChildItem $g -Recurse -File -Include *.assets,*.bundle,*.dll,*.dat | Select-String -Pattern "i2languages" -List | Select Path
```

في لينكس/WSL:
```bash
cd "/mnt/c/Program Files (x86)/Steam/steamapps/common/Double Dealers Demo"
ls -R | head -100
grep -rlai 'i2languages' . ; grep -rlai 'Clause' ./DoubleDealers_Data/resources.assets
```

---

## 3) حسب نتيجة السكريبت: اعمل إيه بالظبط

### 🟢 الحالة 1: لقيت ملف `.csv` / `.json` فيه أعمدة لغات
ده أحسن سيناريو (وده اللي أتمناه — معظم الألعاب اللي بتدعم 10 لغات بتعمل كده).

1. خُد نسخة احتياطية من الملف.
2. زوّد عمود/صف جديد اسمه `ar` (أو `Arabic`).
3. ترجم صف واحد لكل قيمة — **لازم تسيب المفاتيح (keys) زي ما هي**، ترجم الجانب اليمين بس:
   ```csv
   key,en,tr,ar
   auction_start,The auction begins!,Muzayede başlıyor,المزاد بدأ!
   ```
4. **الأهم:** لو مفيش لغة عربية أصلاً في قايمة اللغات، اللعبة ممكن متقراهاش — ساعتها لازم تعدّل سكربت اللغة أو تستخدم مود.
5. خُد باك أب وحُط الملف مكانه، وشغّل اللعبة.

### 🟡 الحالة 2: Unity Localization + Addressables (فولدر `aa/`)
1. نزّل **UABEA** (Unity Asset Bundle Extractor Avalonia) أو **AssetRipper**.
2. افتح ملفات `.bundle` اللي في:
   ```
   ...\DoubleDealers_Data\StreamingAssets\aa\StandaloneWindows64\
   ```
3. دوّر على اللي فيه كلمة `localization` أو `StringTable` — هتلاقي جداول اللغات (en/tr/de/...).
4. صدّرها CSV/JSON، ترجم، وارجع ادمجها (Export Dump ← عدّل ← Import Dump).
5. لو الأداة مساعدتش على الاستيراد، استخدمها للقراءة بس، وسيب التعريب على مود وقت التشغيل.

### 🟡 الحالة 3: I2 Localization (MonoBehaviour اسمه `i2languages`)
1. افتح `resources.assets` بـ **UABEA**.
2. لاقط العنصر اللي الـcontainer بتاعه فيه `i2languages` ← **Export Dump / Export Raw**.
3. استخدم أداة **pyI2L** (مكتوبة بالبايثون وبتدعم **إضافة لغة جديدة**):
   ```bash
   python pyI2L.py            # وضع الاستخراج → يطلعلك CSV فيه كل النصوص
   python pyI2L.py -a my_arabic.csv   # يرجع التعريب جوه ملف الـassets
   ```
4. خُد نسخة احتياطية من `resources.assets` قبل الاستيراد (الأداة بتكتب فوقه).
5. ملاحظة: الـI2 بيحفظ "locale code" — اختار `ar` (أو `ar-SA`) وسجّل الاسم زي ما اللعبة متوقعة.

### 🔴 الحالة 4: النصوص جوّه الكود
- لو البِلد **Mono**:
  - افتح `Assembly-CSharp.dll` بـ **dnSpy**، دوّر على الكلمة اللي شايفها في اللعبة، عدّل النص، وبعدين **File → Save Module**.
  - نصيحة: سجّل النصوص اللي بتظهر في اللعبة وأنت بتلعب الأول، وبعدين ابحث بيها بالحرف — أسرع بكتير من التخمين.
- لو البِلد **IL2CPP** (`GameAssembly.dll` + `global-metadata.dat`):
  - أسهل حل عملي = **مود تعريب وقت التشغيل** (القسم 5) لأن تعديل `global-metadata.dat` شغل معقّد وهيتكسر مع أي تحديث.

---

## 4) مشكلة العربي (RTL) — الجزء اللي بيفشّل معظم التعريبات

حتى لو ترجمت النصوص بنجاح، في 3 عقبات:

| العقبة | الحل |
|--------|------|
| **الحروف مش متوصلة + الاتجاه شمال-يمين غلط** (بيطلع "ةيبرعلا") | محتاج منطق RTL. لو بتعدّل الداتا لوحدها، اكتب العربي بصيغة **Arabic Presentation Forms (sub) + معكوس** — أداة زي [RTLTMPro](https://github.com/pnarimani/RTLTMPro) أو مكتبات Unity Arabic Support بتعمل ده بالكود. لو باستخدام مود، اختار plug-in بيدعم RTL. |
| **الخط مفيهوش حروف عربي** (بتطلع مربعات ▯▯▯) | لازم تستبدل الخط بـ font فيه glyphs عربية، أو تضيف **Fallback Font**. في XUnity.AutoTranslator فيه إعداد `FallbackFontTextMeshPro` مخصوص لكده. |
| **النص طويل وبيخرج بره الأزرار** | فعّل `EnableUIResizing` في المود، أو قصّر الترجمة (مثال: "Market Phase" → "السوق" أو "السوق!" مش جملة طويلة). |

**قاعدة ذهبية لتعريب الواجهات:** العربي عادة أطول 20–30% من الإنجليزي، فخلّي ترجمتك مختصرة قدر الإمكان في الأزرار والقوايم.

---

## 5) الطريق الأذكى: مود تعريب في وقت التشغيل (XUnity.AutoTranslator)

مميزاته: **مش بيلمس ملفات اللعبة**، بيشتغل مع Mono و IL2CPP، وبيعمل **كاش ترجمة في ملف نصي** تقدر تعدّله بإيدك (وده أقرب حاجة لـ"ملف التعريب" اللي بتدوّر عليه لو مفيش ملف أصلي).

1. نزّل **BepInEx** (نسخة mono أو il2cpp حسب البِلد).
2. نزّل **XUnity.AutoTranslator** (نسخة BepInEx) وفكّه في فولدر اللعبة جنب الـexe.
3. شغّل اللعبة مرة، هيطلعلك الفولدر:
   ```
   Double Dealers Demo\Translation\ar\
   ```
   وجواه الملف:
   ```
   _AutoGeneratedTranslations.ar.txt
   ```
   **ده هو "ملف التعريب" بتاعك** — تقدر تكتب فيه يدوي:
   ```
   Clause=بند
   A secret Clause=بند سرّي
   Market Phase=مرحلة السوق
   ```
   واللعبة هتستخدم ترجمتك دي من غير ما تروح لأي خدمة ترجمة.
4. في الإعدادات (`BepInEx\config\gravydevsupreme.xunity.autotranslator.ini`):
   ```ini
   [AutoTranslator]
   Language=ar
   FromLanguage=en
   EnableUIResizing=True
   FallbackFontTextMeshPro=arial-arabic-sdf     ; أو اسم أي TMP font asset عندك فيه عربي
   ```
5. ملاحظة مهمة: المود مش بيعمل RTL لوحده بشكل موثوق لكل الألعاب — جرّب الأول على نص صغير، ولو الحروف مقلوبة هتحتاج إضافة RTL أو تكتب العربي جاهز بشكل معكوس.

---

## 6) الطريق الرسمي (الأفضل على المدى الطويل)

اللعبة بتدعم 10 لغات ومطوّرينها بيتفاعلوا مع المجتمع على **Discord** (مكتوب ده صريح في صفحة الـEarly Access): إنهم "بيجمعوا الفيدباك من الديسكورد كل فترة".
1. على صفحة ستيم: **Community Hub → Discussions** أو لينك الديسكورد في الـsidebar.
2. اطلب رسميًا **اللغة العربية (Arabic)** في قسم الاقتراحات، واعرض إنك **مستعد تتولّى الترجمة مجانًا** (كتير من المطورين بيقبلوا ده وبيحطوا اسمك في الشكر).
3. ابعتلهم **الـCSV مترجم** كعينة — ده بيخلي الرد إيجابي 90% أكتر من مجرد طلب.

---

## 7) الأخلاقيات والقانون

- تعديل ملفات اللعبة **لنفسك** عادي في معظم الحالات، لكن **ممنوع توزّع ملفات اللعبة الأصلية** مع التعريب.
- وزّع **ملف الترجمة فقط** (CSV/JSON) أو سوّيه **مود** منفصل — ده أنضف قانونيًا وأسهل في التحديث.
- متبيعش التعريب ولا تحطه ورا إعلانات.
- أي تعديل ممكن يخرّب اللعبة أو يمنعها من الأونلاين؛ خُد **باك أب** دايماً قبل أي تعديل.

---

## 8) ابعتلي إيه وأنا أعمل إيه

أنا مش قادر أوصل لملفات اللعبة على جهازك (الفولدر اللي عندي فيه كود بس، مش اللعبة)، فلو بعتلي أي حاجة من دول في الشات هترجعلك **جاهزة**:

| تبعتلي إيه | أنا أرجعلك إيه |
|------------|----------------|
| `localization-report.txt` من السكريبت | تحليل نهائي: الملف فين بالظبط + خطة تعديل مرقّمة |
| ملف CSV/JSON/TXT فيه نصوص اللعبة | **نسخة مترجمة كاملة للعربي** بنفس المفاتيح جاهزة للاستيراد |
| محتوى ملف `i2languages` المصدّر | CSV عربي كامل + خطوات إرجاعه بـ pyI2L |
| سكرين شوت من واجهة اللعبة | ترجمة الواجهة بشكل مضبوط (مع مراعاة طول النصوص العربي) |
| اقتراح الديسكورد | **رسالة رسمية بالإنجليزي** جاهزة ترجّعها للمطورين |

---

## 9) الأدوات — روابط مباشرة

| الأداة | بتعمل إيه | لينك |
|--------|-----------|------|
| **UABEA** | فك وتعديل ملفات Unity `.assets` و `.bundle` | https://github.com/nesrak1/UABEA |
| **AssetRipper** | استخراج مشروع Unity كامل من اللعبة | https://github.com/AssetRipper/AssetRipper |
| **UnityPy** | مكتبة بايثون للتعامل مع ملفات Unity برمجيًا | https://github.com/K0lb3/UnityPy |
| **pyI2L** | استخراج وإرجاع ترجمات I2 Localization | https://github.com/KovacsGG/pyI2L |
| **dnSpy / dnSpyEx** | فتح وتعديل `Assembly-CSharp.dll` (Mono) | https://github.com/dnSpyEx/dnSpy |
| **BepInEx** | أساس المودات لـUnity | https://github.com/BepInEx/BepInEx |
| **XUnity.AutoTranslator** | تعريب وقت التشغيل + كاش نصي تعدّله | https://github.com/bbepis/XUnity.AutoTranslator |
| **RTLTMPro** | دعم العربي والعبرية في TextMeshPro (للمطوّرين) | https://github.com/pnarimani/RTLTMPro |

---

## 10) المصطلحات اللي هتقابلها (مترجمة)

في ملف `glossary-ar.csv` جنب الدليل ده هتلاقي ~60 مصطلح من اللعبة مترجم للعربي بشكل متسّق (Auction, Clause, Market Phase, Bluff...)، جاهز تستخدمه كأساس للتعريب عشان الترجمات تطلع متّسقة ومايبقاش كل مكان بكلمة مختلفة.
