#!/usr/bin/env bash
# =============================================================================
#  find-localization.sh  —  أداة للبحث عن ملفات النصوص/التعريب في ألعاب Unity
#  مخصّصة لـ Double Dealers (Demo = app 4750320 | Full = app 4218620)
#
#  الاستخدام:
#     bash find-localization.sh                 # يدوّر لوحده على فولدر اللعبة
#     bash find-localization.sh "/path/to/Double Dealers Demo"
#
#  بيطبع تقرير على الشاشة + يحفظه في localization-report.txt جانبه
# =============================================================================
set -uo pipefail

GAME_DIR="${1:-}"
OUT_REPORT="localization-report.txt"

# كلمات إنجليزية معروفة من اللعبة — بنستخدمها كـ "طُعم" نلاقي بيه ملفات النصوص
KEYWORDS=(Clause Auction Bid Market Seller Buyer Bluff Profit Item Card Deal Victim Offer Value Bankrupt)

C_R=$'\033[0m'; C_B=$'\033[1m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_C=$'\033[36m'

say()  { printf '%s\n' "$*"; }
head1(){ printf '\n%s\n' "${C_B}${C_C}== $* ==${C_R}"; }
ok()   { printf '%s\n' "${C_G}[+]${C_R} $*"; }
warn() { printf '%s\n' "${C_Y}[!]${C_R} $*"; }

TMP_TXT="$(mktemp)"; trap 'rm -f "$TMP_TXT"' EXIT
tee_log(){ tee -a "$TMP_TXT"; }

# ---------------------------------------------------------------------------
# 1) نلاقي فولدر اللعبة لو المستخدم مبعتش مسار
# ---------------------------------------------------------------------------
guess_steam_roots() {
  local roots=(
    "$HOME/.steam/steam"
    "$HOME/.local/share/Steam"
    "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"
    "/mnt/c/Program Files (x86)/Steam"
    "/mnt/c/Program Files/Steam"
    "$HOME/Library/Application Support/Steam"
  )
  printf '%s\n' "${roots[@]}"
}

steam_libraries() {
  local root vdf
  while IFS= read -r root; do
    vdf="$root/steamapps/libraryfolders.vdf"
    [ -f "$vdf" ] || continue
    printf '%s\n' "$root"
    # "path"  "D:\\SteamLibrary"  → نحوّلها لصيغة لينكس
    grep -oP '"path"\s+"\K[^"]+' "$vdf" 2>/dev/null | while IFS= read -r p; do
      if [[ "$p" == *"\\\\"* ]]; then
        # ويندوز: D:\Games → /mnt/d/Games
        drive=$(printf '%s' "$p" | cut -c1 | tr 'A-Z' 'a-z')
        rest=$(printf '%s' "$p" | cut -c3- | tr '\\' '/' )
        printf '/mnt/%s%s\n' "$drive" "$rest"
      else
        printf '%s\n' "$p"
      fi
    done
  done < <(guess_steam_roots)
}

autodetect_game() {
  local lib cand
  while IFS= read -r lib; do
    [ -d "$lib/steamapps/common" ] || continue
    for cand in "$lib/steamapps/common"/*Double*Dealer*; do
      [ -d "$cand" ] && { printf '%s\n' "$cand"; return 0; }
    done
  done < <(steam_libraries)
  return 1
}

if [ -z "$GAME_DIR" ]; then
  if GAME_DIR="$(autodetect_game)"; then
    ok "لقيت اللعبة لوحدي: $GAME_DIR"
  else
    warn "مش لاقي فولدر اللعبة تلقائيًا."
    say  "    • لو ويندوز: افتح Steam ← كليك يمين على اللعبة ← Manage ← Browse local files"
    say  "      والمسار الافتراضي: C:\\Program Files (x86)\\Steam\\steamapps\\common\\Double Dealers Demo"
    say  "    • لو لينكس/WSL: شغّل السكريبت وانت مدي المسار، مثال:"
    say  "      bash find-localization.sh \"/mnt/c/Program Files (x86)/Steam/steamapps/common/Double Dealers Demo\""
    exit 1
  fi
fi

if [ ! -d "$GAME_DIR" ]; then
  warn "المسار ده مش موجود: $GAME_DIR"
  exit 1
fi

{
head1 "0) نظرة سريعة على الفولدر"
say "المسار: $GAME_DIR"
say "الحجم الكلي: $(du -sh "$GAME_DIR" 2>/dev/null | cut -f1)"
say ""
say "الملفات/الفولدرات في الجذر:"
ls -1 "$GAME_DIR" | head -40 | sed 's/^/   /'
} 2>&1 | tee_log

# ---------------------------------------------------------------------------
# 2) نحدّد نوع البِلد (Mono ولا IL2CPP) وفولدر الـ_Data
# ---------------------------------------------------------------------------
DATA_DIR="$(find "$GAME_DIR" -maxdepth 1 -type d -name '*_Data' | head -1)"
{
head1 "1) نوع المحرك والبنية"
if [ -n "$DATA_DIR" ]; then
  ok "فولدر الداتا: $DATA_DIR"
  say "   محتواه:"
  ls -1 "$DATA_DIR" | head -20 | sed 's/^/     /'
else
  warn "ملقيتش فولدر *_Data — يمكن اللعبة مش Unity أو البِلد غريب."
fi

if [ -f "$GAME_DIR/GameAssembly.dll" ] || [ -f "$GAME_DIR/GameAssembly.so" ]; then
  ok "النوع: IL2CPP  → النصوص الجوّانية في global-metadata.dat + GameAssembly"
elif [ -n "$DATA_DIR" ] && [ -f "$DATA_DIR/Managed/Assembly-CSharp.dll" ]; then
  ok "النوع: Mono  → النصوص الجوّانية في Assembly-CSharp.dll (أسهل في التعديل)"
else
  warn "مش عارف أحدد النوع (مفيش GameAssembly ولا Assembly-CSharp)."
fi

if [ -d "$DATA_DIR/StreamingAssets" ]; then
  ok "فيه StreamingAssets — دي أهم فولدر للتعريب:"
  find "$DATA_DIR/StreamingAssets" -maxdepth 3 -type f | head -30 | sed 's/^/     /'
  if [ -d "$DATA_DIR/StreamingAssets/aa" ]; then
    warn "لقيت فولدر 'aa' → اللعبة مستخدمة Unity Localization + Addressables"
    say  "     يعني جداول الترجمة جوّه ملفات .bundle/.json هنا، وتحتاج UABE أو AssetRipper."
  fi
else
  warn "مفيش StreamingAssets — النصوص يبقى جوّه resources.assets أو الكود."
fi
} 2>&1 | tee_log

# ---------------------------------------------------------------------------
# 3) أي ملفات نصية صريحة (CSV/JSON/PO/XML...) = أفضل سيناريو
# ---------------------------------------------------------------------------
{
head1 "2) ملفات النصوص الصريحة (لو موجودة = تعريبك سهل جدًا)"
FOUND_TEXT=$(find "$GAME_DIR" -type f \
  \( -iname '*.csv' -o -iname '*.tsv' -o -iname '*.po' -o -iname '*.pot' \
     -o -iname '*.json' -o -iname '*.xml' -o -iname '*.resx' -o -iname '*.lang' \
     -o -iname '*.loc' -o -iname '*.txt' \) \
  -not -path '*/Managed/*' -not -iname '*.pdb' 2>/dev/null | head -60)

if [ -n "$FOUND_TEXT" ]; then
  printf '%s\n' "$FOUND_TEXT" | while IFS= read -r f; do
    printf '   %8s  %s\n' "$(du -h "$f" | cut -f1)" "${f#$GAME_DIR/}"
  done
  say ""
  warn "افتح أي ملف من دول وشوف فيه لغات (en/tr/de...) — لو لقيت، ده ملف التعريب نفسه."
else
  say "   مفيش ملفات نصية ظاهرة."
fi
} 2>&1 | tee_log

# ---------------------------------------------------------------------------
# 3.5) كشف نظام التعريب المستخدم (I2 Localization ولا Unity Localization؟)
# ---------------------------------------------------------------------------
{
head1 "3.5) إيه نظام التعريب المستخدم؟"
SYS_NAME=""

# الملفات اللي بيتخزّن فيها النصوص عادةً
ASSET_FILES=$(find "$GAME_DIR" -type f \
  \( -iname '*.assets' -o -iname '*.bundle' -o -iname '*.dll' -o -iname '*.dat' -o -iname '*.so' \) \
  2>/dev/null | head -60)

# ملاحظة: المسارات فيها مسافات، فممنوع استخدام xargs — بنلفّ بwhile
grep_asset_files() {  # $1 = النمط
  local pat="$1" f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -l -a -i -- "$pat" "$f" 2>/dev/null
  done <<< "$ASSET_FILES"
}

if [ -n "$(grep_asset_files 'i2languages' | head -1)" ]; then
  ok "🎯 النظام: I2 Localization (أشهر نظام في ألعاب Unity)"
  grep_asset_files 'i2languages' | head -5 | while IFS= read -r f; do
    printf '     الملف: %s\n' "${f#$GAME_DIR/}"
  done
  say  "     الخطوة: صدّر الـMonoBehaviour باسم 'i2languages' من resources.assets بـ UABE"
  say  "     وبعدين استخدم أداة pyI2L (تقدر تزوّد لغة جديدة زي العربية)."
  SYS_NAME="i2"
elif [ -d "$DATA_DIR/StreamingAssets/aa" ]; then
  ok "🎯 النظام: Unity Localization package + Addressables"
  say  "     جداول الترجمة جوّه ملفات .bundle في StreamingAssets/aa"
  say  "     الخطوة: AssetRipper أو UABE لفك الملفات، تلاقي JSON/CSV فيه الـlocales."
  SYS_NAME="unityloc"
elif [ -n "$(grep_asset_files 'LocalizationTable\|LocalizationData\|localization.json\|LanguageCode' | head -1)" ]; then
  warn "في إشارات لنظام تعريب مخصّص (مش I2 ومش Unity Localization الرسمي)."
  SYS_NAME="custom"
elif [ -n "$(grep_asset_files 'TextMeshPro\|TMPro' | head -1)" ]; then
  warn "مفيش نظام تعريب ظاهر، بس في TextMeshPro → النصوص مكتوبة في الكود مباشرة."
  say  "     الحل الأنسب هنا: مود XUnity.AutoTranslator (تعريب وقت التشغيل) بدل تعديل الملفات."
  SYS_NAME="hardcoded"
else
  warn "مفيش ماركرز واضحة — غالبًا مفيش نظام تعريب أصلي."
  SYS_NAME="unknown"
fi
} 2>&1 | tee_log

# ---------------------------------------------------------------------------
# 4) بحث عميق بالكلمات المفتاحية جوّه الملفات الثنائية
# ---------------------------------------------------------------------------
build_utf16_pattern() {  # Clause → C\x00l\x00a\x00u\x00s\x00e
  local kw="$1" out="" i ch
  for (( i=0; i<${#kw}; i++ )); do
    ch="${kw:$i:1}"
    out+="${ch}"$'\\x00'
  done
  printf '%s' "$out"
}

scan_file() {
  local f="$1" k hits
  for k in "${KEYWORDS[@]}"; do
    # UTF-8 (السلاسل العادية في Unity)
    hits=$(grep -a -o -b -i -- "$k" "$f" 2>/dev/null | head -2 | cut -d: -f1)
    for off in $hits; do
      ctx=$(tail -c +"$(( off>60 ? off-60 : 1 ))" "$f" 2>/dev/null | head -c 150 | tr -c '[:print:]' ' ')
      printf '   %s | %s @%s : ...%s...\n' "${f#$GAME_DIR/}" "$k" "$off" "$ctx"
    done
    # UTF-16LE (نادر لكن بيحصل)
    if [ ${#k} -gt 3 ]; then
      pat="$(build_utf16_pattern "$k")"
      grep -a -o -b -P "$pat" "$f" 2>/dev/null | head -1 | cut -d: -f1 | while read -r off; do
        [ -n "$off" ] || continue
        ctx=$(tail -c +"$(( off>60 ? off-60 : 1 ))" "$f" 2>/dev/null | head -c 150 | tr -c '[:print:]' ' ')
        printf '   %s | %s(UTF16) @%s : ...%s...\n' "${f#$GAME_DIR/}" "$k" "$off" "$ctx"
      done
    fi
  done
}

{
head1 "3) بحث عن نصوص اللعبة جوّه الملفات الثنائية (ده اللي يقولك الملف فين بالظبط)"
SCANNED=0
while IFS= read -r f; do
  size=$(stat -c%s "$f" 2>/dev/null || echo 0)
  if [ "$size" -gt 314572800 ]; then
    warn "تخطّيت ملف أكبر من 300MB: ${f#$GAME_DIR/}"
    continue
  fi
  res="$(scan_file "$f")"
  if [ -n "$res" ]; then
    printf '%s\n' "${C_B}>>> ${f#$GAME_DIR/}${C_R}"
    printf '%s\n' "$res"
    SCANNED=$((SCANNED+1))
  fi
done < <(find "$GAME_DIR" -type f \
          \( -iname '*.assets' -o -iname '*.bundle' -o -iname '*.unity3d' \
             -o -iname '*.dat' -o -iname '*.bin' -o -iname '*.dll' \
             -o -iname '*.so' -o -iname '*.bytes' \) 2>/dev/null | head -80)

if [ "$SCANNED" -eq 0 ]; then
  say "   مفيش نتايج — جرّب تضيف كلمة إنجليزية انت شايفها جوّه اللعبة في مصفوفة KEYWORDS فوق."
else
  ok "الملفات اللي فيها نصوص اللعبة: $SCANNED (شوف السطور فوق)"
  say "   ملحوظة: عنوان الملف + اسم الكلمة = ده اللي بتدوّر عليه."
  say "   • resources.assets / sharedassets*.assets + كلمة i2languages → I2 Localization (استخدم pyI2L)"
  say "   • الملفات دي + Unity Localization → جداول جوّه .bundle (استخدم UABE / AssetRipper)"
  say "   • global-metadata.dat أو Assembly-CSharp.dll → النصوص مكتوبة في الكود نفسه"
fi
} 2>&1 | tee_log

# ---------------------------------------------------------------------------
# 5) الخلاصة والتوصية
# ---------------------------------------------------------------------------
{
head1 "4) الخلاصة"
if [ -n "${FOUND_TEXT:-}" ]; then
  ok "عندك ملفات نصية صريحة → ابدأ بيها فورًا، النسخ واللزق يكفي."
elif [ -d "$DATA_DIR/StreamingAssets/aa" ]; then
  warn "الأغلب: Unity Localization + Addressables → تحتاج UABE/AssetRipper لفك الـ.bundle"
elif [ -f "$GAME_DIR/GameAssembly.dll" ]; then
  warn "الأغلب: النصوص جوّه global-metadata.dat (IL2CPP) → استخدم AssetRipper أو XUnity.AutoTranslator"
else
  warn "الأغلب: Mono DLL → افتح Assembly-CSharp.dll بـ dnSpy وشوف"
fi
say ""
say "التقرير اتحفظ في: $(pwd)/$OUT_REPORT"
} 2>&1 | tee_log

cp "$TMP_TXT" "$OUT_REPORT" 2>/dev/null
# شيل أكواد الألوان من التقرير
sed -i 's/\x1b\[[0-9;]*m//g' "$OUT_REPORT" 2>/dev/null || true
printf '\n%s\n' "${C_B}تم. ابعتلي ملف $OUT_REPORT أو أي ملف نصوص لقيته، وأنا أترجمه عربي.${C_R}"
