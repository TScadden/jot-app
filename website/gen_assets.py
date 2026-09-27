#!/usr/bin/env python3
"""Generate static assets for the jottracker.com redesign:
   - public/og-image.png       : 1200x630 social card
   - WebP conversions of hero screenshots (PNG kept as fallback)

The sample clinical report is generated separately by gen_report.py
(fictional data, diagonal SAMPLE watermark baked into the image).
"""
import os
from PIL import Image, ImageDraw, ImageFont

PUB = "/home/hatch/workspace/repos/jot-app/website/public"
DJ = "/usr/share/fonts/truetype/dejavu/"

def font(name, size):
    return ImageFont.truetype(os.path.join(DJ, name), size)

ACCENT = (124, 110, 255)
INK = (18, 18, 24)
MUTED = (110, 110, 128)
CARD = (245, 245, 250)
LINE = (225, 225, 235)

# ---------------------------------------------------------------- og image
OW, OH = 1200, 630
og = Image.new("RGB", (OW, OH), (10, 10, 14))
od = ImageDraw.Draw(og)
logo = Image.open(os.path.join(PUB, "tabs_logo.png")).convert("RGBA").resize((120, 120), Image.LANCZOS)
og.paste(logo, (80, 80), logo)
od.text((220, 88), "Tabs", font=font("DejaVuSans-Bold.ttf", 72), fill="white")
od.text((84, 260), "The notes app that", font=font("DejaVuSans.ttf", 64), fill=(245, 245, 245))
od.text((84, 340), "builds with you.", font=font("DejaVuSans-Bold.ttf", 64), fill=ACCENT)
od.text((84, 470), "Log symptoms, spot patterns, share clinical reports with your doctor.",
        font=font("DejaVuSans.ttf", 30), fill=(168, 168, 188))
od.rectangle([80, 540, 220, 548], fill=ACCENT)
og.save(os.path.join(PUB, "og-image.png"))
print("og-image.png", og.size)

# ---------------------------------------------------------------- webp conversions
for name in ["new_home", "new_voice", "new_heart", "new_history"]:
    src = os.path.join(PUB, name + ".png")
    dst = os.path.join(PUB, name + ".webp")
    Image.open(src).save(dst, "WEBP", quality=82, method=6)
    print(dst, os.path.getsize(dst), "bytes (png was", os.path.getsize(src), ")")

# sample report webp too
Image.open(os.path.join(PUB, "sample_report.png")).save(
    os.path.join(PUB, "sample_report.webp"), "WEBP", quality=82, method=6)
print("sample_report.webp done")
