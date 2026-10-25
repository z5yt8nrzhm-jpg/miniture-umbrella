"""Render the Gilbert Flex Studio mat pilates reel: 1080x1920, 30fps, frames piped to ffmpeg."""
import subprocess, sys, math
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageFilter

D = Path(__file__).parent
W, H, FPS = 1080, 1920, 30
XF = 0.6  # crossfade seconds

CREAM = (246, 241, 232)
CHAR = (63, 69, 64)
TERRA = (176, 113, 79)
SAGE = (122, 140, 118)


def font(name, size, wght=None):
    f = ImageFont.truetype(str(D / "fonts" / name), size)
    if wght:
        try:
            f.set_variation_by_axes([wght])
        except Exception:
            pass
    return f


def ease(t):
    t = max(0.0, min(1.0, t))
    return t * t * (3 - 2 * t)


def cover(img, w, h):
    s = max(w / img.width, h / img.height)
    return img.resize((round(img.width * s), round(img.height * s)), Image.LANCZOS)


# --- scene definitions -------------------------------------------------------
# kb: (zoom_start, zoom_end, pan_x_start, pan_x_end, pan_y_start, pan_y_end), pans in [-1,1]
# texts: list of (t_in, kind, payload)
SCENES = [
    dict(img="s1.png", dur=4.4, kb=(1.12, 1.0, 0, 0, -0.3, 0.2), texts=[
        (0.3, "kicker", "TUESDAY · OCTOBER 27"),
        (0.7, "script", "grab the girls."),
    ]),
    dict(img="s2.png", dur=3.8, kb=(1.0, 1.14, -0.2, 0.2, 0, 0), texts=[
        (0.2, "script", "bring the fizzy tea"),
        (0.6, "caps", "+ YOUR FAVORITE CUP"),
    ]),
    dict(img="s3.png", dur=4.2, kb=(1.14, 1.02, 0.2, -0.1, 0.2, -0.1), texts=[
        (0.2, "title", None),
    ]),
    dict(img="s4.png", dur=4.2, kb=(1.0, 1.12, 0, 0, 0.3, -0.2), texts=[
        (0.2, "pillars", None),
    ]),
    dict(img="flyer", dur=5.6, kb=None, texts=[]),
]


if "--flyer-only" in sys.argv:
    SCENES = [s for s in SCENES if s["img"] == "flyer"]


def text_layer(scene, t):
    """Transparent RGBA overlay with the scene's animated text at local time t."""
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    for t_in, kind, payload in scene["texts"]:
        a = ease((t - t_in) / 0.6)
        if a <= 0:
            continue
        dy = round((1 - a) * 40)
        alpha = round(255 * a)
        if kind == "kicker":
            f = font("Montserrat.ttf", 38, 600)
            draw_spaced(d, payload, f, W // 2, 250 + dy, CREAM + (alpha,), 9)
        elif kind == "script":
            y = 310 if scene["img"] == "s1.png" else 230
            f = font("Cormorant-Italic.ttf", 118, 500)
            draw_center(d, payload, f, W // 2, y + dy, CREAM + (alpha,))
        elif kind == "caps":
            f = font("Montserrat.ttf", 36, 600)
            draw_spaced(d, payload, f, W // 2, 395 + dy, CREAM + (alpha,), 8)
        elif kind == "title":
            f1 = font("Cormorant-Italic.ttf", 190, 500)
            f2 = font("Montserrat.ttf", 120, 300)
            f3 = font("Montserrat.ttf", 32, 600)
            draw_center(d, "mat", f1, W // 2, 1290 + dy, CREAM + (alpha,))
            draw_spaced(d, "PILATES", f2, W // 2, 1470 + dy, CREAM + (alpha,), 34)
            a2 = ease((t - 1.0) / 0.6)
            if a2 > 0:
                draw_spaced(d, "A VIBE COMMUNITY EXPERIENCE", f3, W // 2, 1640,
                            CREAM + (round(255 * a2),), 8)
        elif kind == "pillars":
            f = font("Montserrat.ttf", 64, 500)
            for i, word in enumerate(["MOVE", "BREATHE", "CONNECT", "FEEL GOOD"]):
                ai = ease((t - 0.2 - i * 0.55) / 0.5)
                if ai <= 0:
                    continue
                draw_spaced(d, word, f, W // 2, 1180 + i * 125 + round((1 - ai) * 30),
                            CREAM + (round(255 * ai),), 16)
    return layer


def draw_center(d, s, f, cx, y, fill):
    w = d.textlength(s, font=f)
    d.text((cx - w / 2, y), s, font=f, fill=fill)


def draw_spaced(d, s, f, cx, y, fill, track):
    widths = [d.textlength(c, font=f) for c in s]
    total = sum(widths) + track * (len(s) - 1)
    x = cx - total / 2
    for c, w in zip(s, widths):
        d.text((x, y), c, font=f, fill=fill)
        x += w + track


def shadowed(layer):
    """Soft dark glow under text so cream type reads over photos."""
    a = layer.split()[3]
    sh = Image.new("RGBA", layer.size, (30, 28, 24, 0))
    sh.putalpha(a.filter(ImageFilter.GaussianBlur(14)).point(lambda v: int(v * 0.55)))
    return Image.alpha_composite(sh, layer)


def scrim(top, bottom):
    """Vertical gradient to darken the top and/or bottom of a photo."""
    g = Image.new("L", (1, H))
    for y in range(H):
        v = 0
        if top:
            v = max(v, int(top * max(0, 1 - y / (H * 0.32)) ** 1.6))
        if bottom:
            v = max(v, int(bottom * max(0, (y - H * 0.5) / (H * 0.5)) ** 1.4))
        g.putpixel((0, y), v)
    m = g.resize((W, H))
    s = Image.new("RGBA", (W, H), (25, 22, 18, 0))
    s.putalpha(m)
    return s


def photo_frame(scene, t, base, sc):
    z0, z1, px0, px1, py0, py1 = scene["kb"]
    p = ease(t / scene["dur"])
    z = z0 + (z1 - z0) * p
    px = px0 + (px1 - px0) * p
    py = py0 + (py1 - py0) * p
    cw, ch = W / z, H / z
    bx = (base.width - cw) / 2 * (1 + px)
    by = (base.height - ch) / 2 * (1 + py)
    bx = max(0, min(base.width - cw, bx))
    by = max(0, min(base.height - ch, by))
    fr = base.resize((W, H), Image.LANCZOS, box=(bx, by, bx + cw, by + ch)).convert("RGBA")
    fr = Image.alpha_composite(fr, sc)
    return Image.alpha_composite(fr, shadowed(text_layer(scene, t))).convert("RGB")


FLYER = Image.open(D / "flyer.png").convert("RGB")


def flyer_frame(t):
    bg = Image.new("RGB", (W, H), CREAM)
    d = ImageDraw.Draw(bg)
    # flyer card, slow settle-in
    a = ease(t / 0.8)
    scale = (W - 80) / FLYER.width * (0.96 + 0.04 * a + 0.03 * ease(t / 5.6))
    fw, fh = round(FLYER.width * scale), round(FLYER.height * scale)
    card = FLYER.resize((fw, fh), Image.LANCZOS)
    cy = 300 + round((1 - a) * 60)
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        ((W - fw) // 2, cy + 14, (W + fw) // 2, cy + fh + 14), 28, fill=(80, 64, 48, 60))
    bg = Image.alpha_composite(bg.convert("RGBA"), shadow.filter(ImageFilter.GaussianBlur(22)))
    mask = Image.new("L", (fw, fh), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, fw - 1, fh - 1), 26, fill=round(255 * a))
    bg.paste(card, ((W - fw) // 2, cy), mask)
    d = ImageDraw.Draw(bg)
    # header
    ah = ease((t - 0.3) / 0.6)
    f = font("Cormorant-Italic.ttf", 84, 500)
    draw_center(d, "see you on the mat", f, W // 2, 120 + round((1 - ah) * 20), CHAR + (round(255 * ah),))
    # pulsing CTA pill
    ac = ease((t - 1.0) / 0.6)
    if ac > 0:
        pulse = 1 + 0.035 * math.sin(max(0, t - 1.6) * 2 * math.pi / 1.4) * ease((t - 1.6) / 0.4)
        pw, ph = 720 * pulse, 118 * pulse
        y0 = 1600 + round((1 - ac) * 30)
        d.rounded_rectangle((W / 2 - pw / 2, y0, W / 2 + pw / 2, y0 + ph), ph / 2,
                            fill=(84, 89, 84, round(255 * ac)))
        fc = font("Montserrat.ttf", round(44 * pulse), 500)
        tw = d.textlength("save your spot · link in bio", font=fc)
        d.text((W / 2 - tw / 2, y0 + ph / 2), "save your spot · link in bio", font=fc,
               fill=CREAM + (round(255 * ac),), anchor="lm")
        fs = font("Montserrat.ttf", 34, 600)
        draw_spaced(d, "5:00 – 5:45 PM  ·  $15  ·  ALL LEVELS", fs, W // 2, 1765,
                    TERRA + (round(255 * ac),), 4)
    return bg.convert("RGB")


def render_scene(i, t):
    s = SCENES[i]
    if s["img"] == "flyer":
        return flyer_frame(t)
    return photo_frame(s, t, BASES[i], SCRIMS[i])


BASES, SCRIMS = [], []
for s in SCENES:
    if s["img"] == "flyer":
        BASES.append(None); SCRIMS.append(None); continue
    BASES.append(cover(Image.open(D / s["img"]).convert("RGB"), W, H))
    kinds = {k for _, k, _ in s["texts"]}
    top = 150 if kinds & {"kicker", "script", "caps"} else 0
    bottom = 170 if kinds & {"title", "pillars"} else 0
    SCRIMS.append(scrim(top, bottom))

# timeline with crossfades
starts, t = [], 0.0
for s in SCENES:
    starts.append(t)
    t += s["dur"] - XF
total = t + XF
n = round(total * FPS)

out = sys.argv[1] if len(sys.argv) > 1 else str(D / "reel.mp4")
ff = subprocess.Popen([
    "ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24",
    "-s", f"{W}x{H}", "-r", str(FPS), "-i", "-",
    "-f", "lavfi", "-t", f"{total:.3f}", "-i", "anullsrc=r=48000:cl=stereo",
    "-c:v", "libx264", "-preset", "slow", "-crf", "18", "-pix_fmt", "yuv420p",
    "-c:a", "aac", "-shortest", "-movflags", "+faststart", out,
], stdin=subprocess.PIPE)

for k in range(n):
    tt = k / FPS
    active = [i for i, st in enumerate(starts) if st <= tt < st + SCENES[i]["dur"]]
    frame = render_scene(active[0], tt - starts[active[0]])
    if len(active) > 1:
        j = active[1]
        b = render_scene(j, tt - starts[j])
        frame = Image.blend(frame, b, ease((tt - starts[j]) / XF))
    if "--still" in sys.argv and k % FPS:
        pass
    ff.stdin.write(frame.tobytes())
ff.stdin.close()
ff.wait()
print(f"wrote {out} ({total:.1f}s, {n} frames)")
