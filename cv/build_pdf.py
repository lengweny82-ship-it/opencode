# -*- coding: utf-8 -*-
"""Build the Arabic and English CV PDFs (selectable, correctly-ordered text)."""

import os
import pymupdf
from content import CONTENT

HERE = os.path.dirname(os.path.abspath(__file__))
FONTS = os.path.join(HERE, "fonts")
OUT = os.path.join(HERE, "..", "CV")

NAVY = "#102440"
NAVY_SOFT = "#1E3452"
GOLD = "#A28040"
GOLD_LIGHT = "#C6AA70"
INK = "#262C34"
MUTED = "#6E7682"
RULE = "#D6D8DC"
CHIP_BG = "#F6F8FB"
CHIP_BORDER = "#DFE3E9"
BAND_TEXT = "#CED5DF"

# A4 in points
PW, PH = 595.28, 841.89
MARGIN = 54.0          # 19 mm
BAND_H = 88.0

CSS = """
@font-face { font-family: Cairo;   src: url(fonts/Cairo_400Regular.ttf); }
@font-face { font-family: CairoB;  src: url(fonts/Cairo_700Bold.ttf); }
@font-face { font-family: CairoSB; src: url(fonts/Cairo_600SemiBold.ttf); }
@font-face { font-family: AmiriB;  src: url(fonts/Amiri_700Bold.ttf); }
@font-face { font-family: PlayfairB; src: url(fonts/PlayfairDisplay_700Bold.ttf); }
@font-face { font-family: PlayfairSB; src: url(fonts/PlayfairDisplay_600SemiBold.ttf); }
* { margin: 0; padding: 0; }
body { color: %(ink)s; font-size: 10.5pt; }
table { border-collapse: collapse; }
td { vertical-align: top; }
""" % {"ink": INK}


def section(ar, title, font):
    """Section heading: gold rail at the reading-start side + gold hairline."""
    title = title if ar else title.upper()
    size = "13.2" if ar else "12.2"
    spacing = "" if ar else "letter-spacing:0.9pt;"
    side = "right" if ar else "left"
    direction = "rtl" if ar else "ltr"
    return f"""
    <div dir="{direction}" style="direction:{direction}; margin-top:15px;
         border-{side}:3.4pt solid {GOLD}; padding-{side}:8px; padding-bottom:3px;
         border-bottom:1.1pt solid {GOLD}; font-family:{font}; font-size:{size}pt;
         color:{NAVY}; {spacing}">{title}</div>"""


def summary_block(ar, text, font):
    return (f'<div style="font-family:{font}; font-size:10.6pt; line-height:1.52; '
            f'text-align:justify; padding-top:8px;">{text}</div>')


def practice_block(ar, items, font):
    half = (len(items) + 1) // 2
    left, right = items[:half], items[half:]
    rows = []
    for i in range(half):
        cells = []
        for col in (left, right):
            txt = col[i] if i < len(col) else ""
            cells.append(
                f'<td style="width:50%; padding:2.2px 0; font-family:{font}; font-size:10.4pt;">'
                f'<span style="color:{GOLD}; font-family:CairoB; font-size:9pt;">▪</span>'
                f'&nbsp;&nbsp;{txt}</td>')
        rows.append("<tr>" + "".join(cells) + "</tr>")
    direction = "rtl" if ar else "ltr"
    return ('<table style="width:100%; margin-top:7px;" dir="' + direction + '">'
            + "".join(rows) + '</table>')


def experience_block(ar, role, period, bullets, font):
    side = "right" if ar else "left"
    opposite = "left" if ar else "right"
    head = f"""
    <table style="width:100%; margin-top:9px;" dir="{'rtl' if ar else 'ltr'}">
      <tr>
        <td style="text-align:start; font-family:{font}; font-size:11.6pt; color:{NAVY};">{role}</td>
        <td style="text-align:{'left' if ar else 'right'}; font-family:CairoSB; font-size:9.8pt; color:{GOLD};">{period}</td>
      </tr>
    </table>
    <div style="border-top:0.6pt solid {RULE}; margin-top:4px;"></div>"""
    items = "".join(
        f'<div style="padding:2.6px 0; font-family:{font}; font-size:10.4pt; line-height:1.45;">{b}</div>'
        for b in bullets)
    rail = f"""
    <div style="border-{side}:2.6pt solid {GOLD}; padding-{side}:9px; margin-top:9px;">
      {items}
    </div>"""
    return head + rail


def education_block(ar, degree, font):
    bullet = f'<span style="color:{GOLD}; font-family:CairoB; font-size:9pt;">▪</span>&nbsp;&nbsp;'
    return (f'<div style="font-family:{font}; font-size:10.5pt; padding-top:7px;">'
            f'{bullet}{degree}</div>')


def skills_block(ar, items, font):
    per_row = 3
    rows = []
    for i in range(0, len(items), per_row):
        cells = []
        for item in items[i:i + per_row]:
            cells.append(
                f'<td style="width:33.33%; padding:2.6px; border:none;">'
                f'<div style="background-color:{CHIP_BG}; border:0.7pt solid {CHIP_BORDER}; '
                f'padding:5.5px 3px; text-align:center; font-family:{font}; font-size:9.3pt; '
                f'color:{NAVY_SOFT};">{item}</div></td>')
        rows.append("<tr>" + "".join(cells) + "</tr>")
    direction = "rtl" if ar else "ltr"
    return ('<table dir="' + direction + '" style="width:100%; table-layout:fixed; '
            'border-collapse:collapse; margin-top:8px;">' + "".join(rows) + '</table>')


def courses_block(ar, items, font):
    bullet = f'<span style="color:{GOLD}; font-family:CairoB; font-size:9pt;">▪</span>&nbsp;&nbsp;'
    rows = "".join(
        f'<div style="padding:2.4px 0; font-family:{font}; font-size:10.4pt;">{bullet}{c}</div>'
        for c in items)
    return f'<div style="padding-top:7px;">{rows}</div>'


def header_band(ar, c):
    """Navy band: photo on one side, name/title/phone on the reading-start side."""
    name_font = "CairoB" if ar else "PlayfairB"
    title_font = "CairoB" if ar else "CairoSB"
    contact = f'{c["phone_label"]}: {c["phone"]}'
    title_style = "" if ar else "letter-spacing:1.6pt;"
    align = "right" if ar else "left"
    pad_side = "padding-right" if ar else "padding-left"

    photo_size = 68
    text_cell = f'''
      <td style="background-color:{NAVY}; vertical-align:middle;">
        <div style="text-align:{align}; {pad_side}:30px;">
          <div style="font-family:{name_font}; font-size:{'22' if ar else '24'}pt;
                      color:#FFFFFF; line-height:1.3;">{c['name']}</div>
          <div style="font-family:{title_font}; font-size:{'10.6' if ar else '9.2'}pt;
                      color:{GOLD_LIGHT}; margin-top:2px; {title_style}">{c["title"]}</div>
          <div style="font-family:Cairo; font-size:9.2pt; color:{BAND_TEXT};
                      margin-top:6px;">{contact}</div>
        </div>
      </td>'''
    photo_cell = f'''
      <td style="background-color:{NAVY}; width:{photo_size + 46}px; text-align:center;">
        <div style="text-align:center; padding-top:10px;">
          <img src="assets/photo_circle_pdf.jpg" style="width:{photo_size}px; height:{photo_size}px;">
        </div>
      </td>'''

    cells = photo_cell + text_cell if ar else text_cell + photo_cell
    return f"""
    <div style="background-color:{NAVY}; height:{BAND_H - 3.6}px;">
      <table style="width:100%; border-collapse:collapse;">
        <tr>{cells}</tr>
      </table>
    </div>
    <div style="height:2.4px; background-color:{GOLD};"></div>
    <div style="height:1.2px; background-color:{NAVY}; margin-top:1.2px;"></div>
    <div style="height:1.1px; background-color:{GOLD}; margin-top:1.2px;"></div>
    """


def html_page(lang):
    c = CONTENT[lang]
    ar = lang == "ar"
    body_font = "Cairo"
    section_font = "CairoB" if ar else "PlayfairB"
    s = c["sections"]

    parts = [f'<html><body dir="{"rtl" if ar else "ltr"}" style="font-family:{body_font}; color:{INK};">']
    parts.append(header_band(ar, c))
    parts.append(f'<div style="padding:14px {MARGIN}px 0 {MARGIN}px;">')

    parts.append(section(ar, s["summary"], section_font))
    parts.append(summary_block(ar, c["summary"], body_font))

    parts.append(section(ar, s["practice"], section_font))
    parts.append(practice_block(ar, c["practice"], body_font))

    parts.append(section(ar, s["experience"], section_font))
    parts.append(experience_block(ar, c["role"], c["period"], c["experience"], body_font))

    parts.append(section(ar, s["education"], section_font))
    parts.append(education_block(ar, c["education_degree"], body_font))

    parts.append(section(ar, s["skills"], section_font))
    parts.append(skills_block(ar, c["skills"], body_font))

    parts.append(section(ar, s["courses"], section_font))
    parts.append(courses_block(ar, c["courses"], body_font))

    parts.append("</div></body></html>")
    return "\n".join(parts)


def footer_story(lang):
    c = CONTENT[lang]
    ar = lang == "ar"
    return f"""
    <html><body dir="{'rtl' if ar else 'ltr'}">
      <div style="border-top:0.6pt solid {RULE}; padding-top:6px; text-align:center;
                  font-family:Cairo; font-size:8.2pt; color:{MUTED};">
        {c['phone_label']}: {c['phone']} &nbsp;·&nbsp; {c['name']}
      </div>
    </body></html>"""


def build(lang, path):
    c = CONTENT[lang]
    archive = pymupdf.Archive(HERE)
    story = pymupdf.Story(html=html_page(lang), user_css=CSS, archive=archive)
    foot = pymupdf.Story(html=footer_story(lang), user_css=CSS, archive=archive)

    writer = pymupdf.DocumentWriter(path)
    page_rect = pymupdf.paper_rect("a4")

    # content area runs edge to edge (the band spans the full width)
    more, filled = story.place(page_rect)
    bottom = filled[3] if isinstance(filled, (tuple, list)) else filled.y1
    if more:
        raise RuntimeError(f"content overflows one page ({lang}); bottom={bottom}")
    if bottom > PH - 60:
        raise RuntimeError(f"content too tall: {bottom:.1f} > {PH - 60:.1f}")

    dev = writer.begin_page(page_rect)
    story.draw(dev)

    # footer pinned to the bottom margin
    foot_rect = pymupdf.Rect(MARGIN, PH - 56, PW - MARGIN, PH - 18)
    foot_more, ffilled = foot.place(foot_rect)
    if foot_more:
        raise RuntimeError("footer overflowed")
    foot.draw(dev)
    writer.end_page()
    writer.close()

    doc = pymupdf.open(path)
    doc.set_metadata({
        "title": f"{c['name']} — CV",
        "author": c["name"],
        "subject": "Curriculum Vitae",
        "keywords": "CV, résumé, lawyer, attorney",
        "creator": "CV Builder",
        "producer": "PyMuPDF",
    })
    tmp = path + ".tmp"
    doc.save(tmp, garbage=4, deflate=True)
    doc.close()
    os.replace(tmp, path)

    # report
    doc = pymupdf.open(path)
    text = doc[0].get_text()
    print(f"wrote {path} | pages={doc.page_count} | content_bottom={bottom:.0f}pt | "
          f"chars={len(text)}")
    doc.close()


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    build("ar", os.path.join(OUT, "Ahmed_AbdelNaby_CV_AR.pdf"))
    build("en", os.path.join(OUT, "Ahmed_AbdelNaby_CV_EN.pdf"))
