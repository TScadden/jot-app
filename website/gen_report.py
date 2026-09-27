#!/usr/bin/env python3
"""Generate the fictional Tabs clinical summary sample report (SAMPLE watermarked).
All data is fictional and labeled as such — no real patient data (founder directive).
"""
import os, textwrap
from PIL import Image, ImageDraw, ImageFont

PUB = "/home/hatch/workspace/repos/jot-app/website/public"
DJ = "/usr/share/fonts/truetype/dejavu/"

def font(name, size):
    return ImageFont.truetype(os.path.join(DJ, name), size)

ACCENT = (124, 110, 255)
INK = (18, 18, 24)
MUTED = (110, 110, 128)
CARD = (246, 246, 250)
LINE = (224, 224, 236)

W, H = 1080, 1960
img = Image.new("RGB", (W, H), "white")
d = ImageDraw.Draw(img)
F  = lambda s: font("DejaVuSans.ttf", s)
FB = lambda s: font("DejaVuSans-Bold.ttf", s)

# header band
d.rectangle([0, 0, W, 190], fill=(12, 12, 18))
d.text((64, 44), "Tabs", font=FB(64), fill="white")
d.text((64, 122), "Clinical Summary Report", font=F(34), fill=(200, 200, 215))
d.text((W - 350, 66), "SAMPLE", font=FB(72), fill=ACCENT)

# patient banner
d.rectangle([0, 190, W, 300], fill=CARD)
d.line([0, 300, W, 300], fill=LINE, width=2)
d.text((64, 216), "Patient:  Jane Doe  (fictional sample patient)", font=FB(28), fill=INK)
d.text((64, 258), "Report period: Aug 24 - Sep 24, 2026  ·  All data on this page is fictional, for illustration only",
       font=F(21), fill=MUTED)

y = 344
def section(title):
    global y
    y += 28
    d.text((64, y), title.upper(), font=FB(24), fill=ACCENT)
    y += 46

def card_open(pad=28):
    """Draw card later; return (top, content_x, content_y, content_w). Caller must call card_close()."""
    global y
    return (y, 64 + 28, y + pad, W - 64 - 28)

CARD_STACK = []
def card_close(bottom_pad=28):
    global y
    top, _, _, _ = CARD_STACK.pop()
    d.rounded_rectangle([56, top, W - 56, y + bottom_pad], radius=18, fill=CARD, outline=LINE, width=2)
    # redraw border on top of nothing - card drawn after content would cover it; instead draw first next time.
    y += bottom_pad

# NOTE: cards are drawn first, then content. Redo: helper that draws card bg behind given content height.
def card_block(content_fn, inner=28):
    """content_fn(x, y0, w) -> height used. Draws card behind it."""
    global y
    h = content_fn(96, y + inner, W - 192)
    d.rounded_rectangle([56, y, W - 56, y + inner + h + inner], radius=18, fill=CARD, outline=LINE, width=2)
    content_fn(96, y + inner, W - 192)  # draw again on top of card
    y += inner + h + inner + 0

def wrapped(text, fnt, max_w):
    out = []
    for para in text.split("\n"):
        w = 0; line = ""
        for word in para.split(" "):
            ww = d.textlength(word + " ", font=fnt)
            if w + ww > max_w and line:
                out.append(line.rstrip()); line = ""; w = 0
            line += word + " "; w += ww
        out.append(line.rstrip())
    return out

# 1. key patterns
section("Key patterns")
def patterns(x, y0, w):
    items = [
        ("Headache (avg 4/10) logged on 11 of 14 days with under 6 hours of sleep the night before.", None),
        ("Fatigue severity trended down across the period.", "Average 6/10 in week 1, 4/10 in week 4."),
        ("6 of 9 migraine entries followed a weather shift.", "Barometric pressure drop within 24 hours."),
    ]
    yy = y0
    for main, sub in items:
        lines = wrapped(main, F(25), w - 40)
        d.ellipse([x, yy + 8, x + 16, yy + 24], fill=ACCENT)
        for i, ln in enumerate(lines):
            d.text((x + 32 if i == 0 else x + 32, yy), ln, font=F(25), fill=INK)
            yy += 36
        if sub:
            for ln in wrapped(sub, F(21), w - 40):
                d.text((x + 32, yy), ln, font=F(21), fill=MUTED)
                yy += 30
        yy += 22
    return yy - y0 - 22
card_block(patterns)

# 2. symptom log summary
section("Symptom log summary")
def table(x, y0, w):
    rows = [("Symptom", "Entries", "Avg severity"),
            ("Headache", "18", "4/10"), ("Fatigue", "22", "5/10"),
            ("Migraine", "9", "7/10"), ("Brain fog", "12", "5/10")]
    yy = y0
    for i, (a, b, c) in enumerate(rows):
        fnt = FB(24) if i == 0 else F(24)
        col = MUTED if i == 0 else INK
        d.text((x, yy), a, font=fnt, fill=col)
        d.text((x + 440, yy), b, font=fnt, fill=col)
        d.text((x + 640, yy), c, font=fnt, fill=col)
        yy += 50
    return yy - y0 - 50
card_block(table)

# 3. biometrics
section("Biometrics  (Health Connect)")
def biometrics(x, y0, w):
    stats = [("Resting HR", "68 bpm"), ("HRV (RMSSD)", "42 ms"), ("Sleep", "6.4 h avg")]
    for i, (label, val) in enumerate(stats):
        sx = x + i * 280
        d.text((sx, y0), val, font=FB(38), fill=INK)
        d.text((sx, y0 + 54), label, font=F(22), fill=MUTED)
    return 92
card_block(biometrics)

# 4. medications
section("Medications  (sample only)")
def meds(x, y0, w):
    yy = y0
    for ln in ["ExampleMed 10 mg — once daily", "Sample Supplement 1000 IU — once daily"]:
        d.text((x, yy), ln, font=F(25), fill=INK); yy += 42
    d.text((x, yy + 6), "Fictional medications shown as examples only.", font=F(21), fill=MUTED)
    return yy + 6 + 30 - y0
card_block(meds)

# 5. protocol adherence
section("Protocol adherence")
def protos(x, y0, w):
    yy = y0
    for label, frac in [("Morning protocol", 0.86), ("Evening protocol", 0.74)]:
        d.text((x, yy), label, font=F(25), fill=INK)
        pct = f"{int(frac * 100)}%"
        d.text((x + w - d.textlength(pct, font=FB(25)), yy), pct, font=FB(25), fill=INK)
        d.rounded_rectangle([x, yy + 44, x + w, yy + 62], radius=9, fill=LINE)
        d.rounded_rectangle([x, yy + 44, x + int(w * frac), yy + 62], radius=9, fill=ACCENT)
        yy += 100
    return yy - y0 - 38
card_block(protos)

# footer
d.line([64, y + 40, W - 64, y + 40], fill=LINE, width=2)
d.text((64, y + 62), "Generated by Tabs  ·  Fictional sample for illustration only.", font=F(22), fill=MUTED)
d.text((64, y + 98), "Not a real patient. Not medical advice.", font=F(22), fill=MUTED)
bottom = y + 170
img = img.crop((0, 0, W, bottom))
W2, H2 = img.size

# diagonal SAMPLE watermark (baked into the image itself)
wm = Image.new("RGBA", (W2, H2), (0, 0, 0, 0))
wd = ImageDraw.Draw(wm)
wf = FB(150)
for cyy in [H2 // 4, H2 // 2, 3 * H2 // 4]:
    bbox = wd.textbbox((0, 0), "SAMPLE", font=wf)
    tile = Image.new("RGBA", (bbox[2] + 60, bbox[3] + 60), (0, 0, 0, 0))
    ImageDraw.Draw(tile).text((30, 30), "SAMPLE", font=wf, fill=(124, 110, 255, 52))
    tile = tile.rotate(28, expand=True, resample=Image.BICUBIC)
    wm.alpha_composite(tile, (W2 // 2 - tile.width // 2, cyy - tile.height // 2))
img = Image.alpha_composite(img.convert("RGBA"), wm).convert("RGB")

out = os.path.join(PUB, "sample_report.png")
img.save(out)
img.save(os.path.join(PUB, "sample_report.webp"), "WEBP", quality=82, method=6)
print("saved", out, img.size)
