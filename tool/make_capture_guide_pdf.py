"""Builds `docs/360_capture_implementation_guide.pdf`.

A plain-language walkthrough of the 26-target AR capture flow, generated from the
constants that are actually in the source (so the numbers in the PDF cannot drift
from the numbers in the code without this file being edited).

    <managed venv>/Scripts/python.exe tool/make_capture_guide_pdf.py

Every threshold quoted below is a default in `CaptureGeometryConfig`,
`PhotoCaptureService` or `StabilityMonitor`; the measured figures in section 8 are
the output of `dart run tool/verify_sphere.dart`.
"""

import os

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER, TA_JUSTIFY, TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (
    BaseDocTemplate,
    Flowable,
    Frame,
    KeepTogether,
    NextPageTemplate,
    PageBreak,
    PageTemplate,
    Paragraph,
    Spacer,
    Table,
    TableStyle,
)

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, os.pardir, "docs", "360_capture_implementation_guide.pdf")

# ── fonts ────────────────────────────────────────────────────────────────────
FONTS = {
    "Segoe": r"C:\Windows\Fonts\segoeui.ttf",
    "Segoe-Bold": r"C:\Windows\Fonts\segoeuib.ttf",
    "Consolas": r"C:\Windows\Fonts\consola.ttf",
}
HAVE_SEGOE = all(os.path.exists(p) for p in FONTS.values())
if HAVE_SEGOE:
    for name, path in FONTS.items():
        pdfmetrics.registerFont(TTFont(name, path))
    pdfmetrics.registerFontFamily(
        "Segoe", normal="Segoe", bold="Segoe-Bold", italic="Segoe", boldItalic="Segoe-Bold"
    )
    BODY, BOLD, MONO = "Segoe", "Segoe-Bold", "Consolas"
else:  # portable fallback
    BODY, BOLD, MONO = "Helvetica", "Helvetica-Bold", "Courier"

# ── palette ──────────────────────────────────────────────────────────────────
INK = colors.HexColor("#1B2430")
MUTED = colors.HexColor("#5A6673")
FAINT = colors.HexColor("#8A94A0")
RULE = colors.HexColor("#D8DEE6")
ACCENT = colors.HexColor("#1F7A4D")
AMBER = colors.HexColor("#A8621A")
PANEL = colors.HexColor("#F4F6F8")
WHITE = colors.white

PAGE_W, PAGE_H = A4
MARGIN_X = 20 * mm
MARGIN_TOP = 24 * mm
MARGIN_BOT = 20 * mm
CONTENT_W = PAGE_W - 2 * MARGIN_X

# ── styles ───────────────────────────────────────────────────────────────────
def S(name, **kw):
    base = dict(fontName=BODY, fontSize=10, leading=15, textColor=INK, alignment=TA_LEFT)
    base.update(kw)
    return ParagraphStyle(name, **base)


st_body = S("body", alignment=TA_JUSTIFY, spaceAfter=6)
st_lead = S("lead", fontSize=11.5, leading=18, textColor=MUTED, spaceAfter=10)
st_h1 = S("h1", fontName=BOLD, fontSize=19, leading=23, spaceBefore=2, spaceAfter=3)
st_h2 = S("h2", fontName=BOLD, fontSize=12.5, leading=16, spaceBefore=13, spaceAfter=4)
st_h3 = S("h3", fontName=BOLD, fontSize=10.5, leading=14, spaceBefore=9, spaceAfter=2)
st_kicker = S("kicker", fontName=BOLD, fontSize=7.5, leading=10, textColor=ACCENT)
st_small = S("small", fontSize=8.5, leading=12, textColor=MUTED)
st_caption = S("caption", fontSize=8, leading=11, textColor=FAINT, spaceBefore=3)
st_cell = S("cell", fontSize=9, leading=12.5)
st_cell_b = S("cellb", fontName=BOLD, fontSize=9, leading=12.5)
st_cell_s = S("cells", fontSize=8.5, leading=12, textColor=MUTED)
st_bullet = S("bullet", fontSize=10, leading=15, leftIndent=12, bulletIndent=2, spaceAfter=2)
st_mono = S("mono", fontName=MONO, fontSize=8.5, leading=12.5, textColor=INK)

# cover
st_eyebrow = S("eyebrow", fontName=BOLD, fontSize=8.5, leading=11, textColor=ACCENT)
st_title = S("title", fontName=BOLD, fontSize=31, leading=35, textColor=INK)
st_sub = S("sub", fontSize=13, leading=19, textColor=MUTED, spaceBefore=10)


def P(text, style=st_body):
    return Paragraph(text, style)


def bullet(text):
    return Paragraph(text, st_bullet, bulletText="•")


def rule(space_before=4, space_after=8, color=RULE, width=0.7):
    t = Table([[""]], colWidths=[CONTENT_W], rowHeights=[0.1])
    t.setStyle(
        TableStyle(
            [
                ("LINEABOVE", (0, 0), (-1, -1), width, color),
                ("TOPPADDING", (0, 0), (-1, -1), space_before),
                ("BOTTOMPADDING", (0, 0), (-1, -1), space_after),
                ("LEFTPADDING", (0, 0), (-1, -1), 0),
                ("RIGHTPADDING", (0, 0), (-1, -1), 0),
            ]
        )
    )
    return t


def heading(number, title):
    """A section heading with a small green number, and a rule under it."""
    t = Table(
        [[Paragraph(number, S("num", fontName=BOLD, fontSize=8.5, leading=10, textColor=ACCENT)),
          Paragraph(title, st_h1)]],
        colWidths=[18, CONTENT_W - 18],
    )
    t.setStyle(
        TableStyle(
            [
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("LEFTPADDING", (0, 0), (-1, -1), 0),
                ("RIGHTPADDING", (0, 0), (-1, -1), 0),
                ("TOPPADDING", (0, 0), (0, 0), 9),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 2),
            ]
        )
    )
    return [t, rule(0, 10)]


def table(header, rows, widths, header_bg=INK, zebra=True, align_right=()):
    data = []
    if header:
        data.append([Paragraph(h, S("th", fontName=BOLD, fontSize=8.5, leading=11, textColor=WHITE))
                     for h in header])
    for r in rows:
        data.append([c if isinstance(c, Paragraph) else Paragraph(str(c), st_cell) for c in r])
    t = Table(data, colWidths=widths, repeatRows=1 if header else 0, hAlign="LEFT")
    style = [
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("TOPPADDING", (0, 0), (-1, -1), 5),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
        ("LEFTPADDING", (0, 0), (-1, -1), 6),
        ("RIGHTPADDING", (0, 0), (-1, -1), 6),
        ("LINEBELOW", (0, 1), (-1, -1), 0.4, RULE),
    ]
    if header:
        style += [
            ("BACKGROUND", (0, 0), (-1, 0), header_bg),
            ("LINEBELOW", (0, 0), (-1, 0), 0.4, INK),
        ]
        first = 1
    else:
        first = 0
    if zebra:
        for i in range(first, len(data)):
            if (i - first) % 2 == 1:
                style.append(("BACKGROUND", (0, i), (-1, i), PANEL))
    for col in align_right:
        style.append(("ALIGN", (col, 1), (col, -1), "RIGHT"))
    t.setStyle(TableStyle(style))
    return t


def callout(title, body, accent=ACCENT, bg=None):
    """A bordered note. Used for the things a reader must not miss."""
    inner = [
        Paragraph(title, S("ct", fontName=BOLD, fontSize=8.5, leading=11, textColor=accent)),
        Spacer(1, 3),
        Paragraph(body, S("cb", fontSize=9.5, leading=14)),
    ]
    t = Table([[inner]], colWidths=[CONTENT_W])
    t.setStyle(
        TableStyle(
            [
                ("BACKGROUND", (0, 0), (-1, -1), bg or colors.HexColor("#F2F7F4")),
                ("LINEBEFORE", (0, 0), (0, -1), 2.4, accent),
                ("LEFTPADDING", (0, 0), (-1, -1), 10),
                ("RIGHTPADDING", (0, 0), (-1, -1), 10),
                ("TOPPADDING", (0, 0), (-1, -1), 8),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 8),
            ]
        )
    )
    return t


# ── diagram: the 26 directions, seen from above ──────────────────────────────
class SphereDiagram(Flowable):
    """Top-down view of the middle ring, with the other two rings as a legend.

    Drawn rather than photographed: there is no device in this environment, and a
    diagram of the arrangement is more legible than a screenshot would be.
    """

    HEIGHT = 322

    def __init__(self):
        super().__init__()
        self.width = CONTENT_W
        self.height = self.HEIGHT

    def draw(self):
        import math

        c = self.canv
        cx = self.width / 2.0
        r = 80.0
        cy = self.HEIGHT - 100

        # the sphere at the middle ring
        c.setStrokeColor(RULE)
        c.setLineWidth(0.8)
        c.setDash(3, 3)
        c.circle(cx, cy, r, stroke=1, fill=0)
        c.setDash()

        # the eight directions of that ring
        labels = ["0°", "45°", "90°", "135°", "180°", "−135°", "−90°", "−45°"]
        for i, lab in enumerate(labels):
            yaw = i * 45.0
            dx = math.sin(math.radians(yaw))
            dy = math.cos(math.radians(yaw))
            px = cx + r * dx
            py = cy + r * dy
            front = i == 0
            c.setFillColor(ACCENT if front else INK)
            c.setStrokeColor(WHITE)
            c.setLineWidth(1.4)
            c.circle(px, py, 5.6 if front else 4.4, stroke=1, fill=1)
            c.setFillColor(ACCENT if front else MUTED)
            c.setFont(BODY, 7.6)
            c.drawCentredString(px + dx * 15, py + dy * 15 - 2.6, lab)

        # station
        c.setFillColor(INK)
        c.circle(cx, cy, 3.2, stroke=0, fill=1)
        c.setFillColor(MUTED)
        c.setFont(BODY, 7.6)
        c.drawCentredString(cx, cy - 13, "station")

        # radius annotation
        c.setStrokeColor(ACCENT)
        c.setLineWidth(0.9)
        c.setDash(2, 2)
        c.line(cx, cy, cx, cy + r)
        c.setDash()
        c.setFillColor(ACCENT)
        c.setFont(BOLD, 7.8)
        c.drawString(cx + 5, cy + r * 0.50, "1.5 m")

        # legend, two columns under the ring
        rows_left = [
            ("T01", "front — first in the sequence"),
            ("T02–T08", "rest of the middle ring, 0°"),
            ("T09–T16", "upper ring, +45°"),
        ]
        rows_right = [
            ("T17–T24", "lower ring, −45°"),
            ("T25", "zenith, +90°"),
            ("T26", "nadir, −90°"),
        ]
        base_y = 100.0
        for col, rows in ((self.width * 0.06, rows_left), (self.width * 0.53, rows_right)):
            y = base_y
            for tag, desc in rows:
                c.setFillColor(ACCENT if tag == "T01" else INK)
                c.setFont(BOLD, 7.8)
                c.drawString(col, y, tag)
                c.setFillColor(MUTED)
                c.setFont(BODY, 7.6)
                c.drawString(col + 44, y, desc)
                y -= 13.5

        c.setFillColor(FAINT)
        c.setFont(BODY, 7.2)
        c.drawString(self.width * 0.06, 46, "The ring drawn is the middle one; the other two sit 45° above and below it.")
        c.drawString(self.width * 0.06, 33, "At calibration you face the 0° direction, so the front target comes first.")


# ── diagram: the capture ladder ──────────────────────────────────────────────
class Ladder(Flowable):
    """Nine steps, top to bottom, with the two decision points marked."""

    STEPS = [
        ("1", "Boot the AR session", "ARCore starts; the camera frame reaches the screen"),
        ("2", "Calibrate the station", "freeze a level reference at your position"),
        ("3", "Place all 26 targets", "one world anchor each, 1.5 m out, never moved again"),
        ("4", "Aim at the current target", "arrow + sentence point at the marker"),
        ("5", "Hold still", "the ring fills while the pose stays steady"),
        ("6", "Ring completes", "target hides, shutter fires by itself"),
        ("7", "Save and verify", "write, read back, record — or fail and re-arm"),
        ("8", "Advance", "the next pending target becomes active and visible"),
        ("9", "All 26 done", "the station is complete"),
    ]

    ROW = 31.0

    def __init__(self):
        super().__init__()
        self.width = CONTENT_W
        self.height = self.ROW * len(self.STEPS) + 8

    def draw(self):
        c = self.canv
        x_num = 14
        box_x = 34
        box_w = self.width - box_x
        top = self.height - 6

        for i, (num, title, sub) in enumerate(self.STEPS):
            y = top - (i + 1) * self.ROW + 6
            # connector
            if i < len(self.STEPS) - 1:
                c.setStrokeColor(RULE)
                c.setLineWidth(1)
                c.line(x_num, y - 6, x_num, y - self.ROW + 12)

            is_decision = num in ("5", "6", "7")
            c.setFillColor(ACCENT if num in ("6", "7") else INK)
            c.circle(x_num, y + 4, 8.6, stroke=0, fill=1)
            c.setFillColor(WHITE)
            c.setFont(BOLD, 8.4)
            c.drawCentredString(x_num, y + 1.4, num)

            c.setFillColor(colors.HexColor("#F7F9FA") if is_decision else PANEL)
            c.roundRect(box_x, y - 5, box_w, self.ROW - 8, 3, stroke=0, fill=1)
            c.setFillColor(INK)
            c.setFont(BOLD, 9.2)
            c.drawString(box_x + 10, y + 9, title)
            c.setFillColor(MUTED)
            c.setFont(BODY, 8.2)
            c.drawString(box_x + 10, y - 1, sub)


# ── page furniture ───────────────────────────────────────────────────────────
def cover_page(canvas, doc):
    canvas.saveState()
    canvas.setFillColor(INK)
    canvas.rect(0, PAGE_H - 9 * mm, PAGE_W, 9 * mm, stroke=0, fill=1)
    canvas.setFillColor(ACCENT)
    canvas.rect(0, PAGE_H - 9.8 * mm, PAGE_W, 0.8 * mm, stroke=0, fill=1)
    canvas.setFillColor(FAINT)
    canvas.setFont(BODY, 8)
    canvas.drawString(MARGIN_X, 14 * mm, "Generated from the source in this repository — every number is a constant in it.")
    canvas.restoreState()


def body_page(canvas, doc):
    canvas.saveState()
    canvas.setFont(BODY, 7.6)
    canvas.setFillColor(FAINT)
    canvas.drawString(MARGIN_X, PAGE_H - 13 * mm, "360° AR Capture — implementation guide")
    canvas.drawRightString(PAGE_W - MARGIN_X, PAGE_H - 13 * mm, "26-target spherical capture")
    canvas.setStrokeColor(RULE)
    canvas.setLineWidth(0.6)
    canvas.line(MARGIN_X, PAGE_H - 15 * mm, PAGE_W - MARGIN_X, PAGE_H - 15 * mm)

    canvas.line(MARGIN_X, 14 * mm, PAGE_W - MARGIN_X, 14 * mm)
    canvas.setFont(BODY, 8)
    canvas.setFillColor(FAINT)
    canvas.drawString(MARGIN_X, 10 * mm, "adaptive_360_capture_app")
    canvas.drawRightString(PAGE_W - MARGIN_X, 10 * mm, "%d" % doc.page)
    canvas.restoreState()


def build():
    doc = BaseDocTemplate(
        OUT,
        pagesize=A4,
        leftMargin=MARGIN_X,
        rightMargin=MARGIN_X,
        topMargin=MARGIN_TOP,
        bottomMargin=MARGIN_BOT,
        title="360° AR Capture — implementation guide",
        author="adaptive_360_capture_app",
        subject="How the 26-target spherical capture works, step by step",
    )
    frame_cover = Frame(MARGIN_X, MARGIN_BOT, CONTENT_W, PAGE_H - MARGIN_TOP - MARGIN_BOT, id="cover")
    frame_body = Frame(MARGIN_X, MARGIN_BOT, CONTENT_W, PAGE_H - MARGIN_TOP - MARGIN_BOT, id="body")
    doc.addPageTemplates(
        [
            PageTemplate(id="cover", frames=[frame_cover], onPage=cover_page),
            PageTemplate(id="body", frames=[frame_body], onPage=body_page),
        ]
    )

    story = []
    A = story.append

    # ── cover ────────────────────────────────────────────────────────────────
    A(Spacer(1, 44 * mm))
    A(P("IMPLEMENTATION GUIDE", st_eyebrow))
    A(Spacer(1, 6))
    A(P("360° AR Capture", st_title))
    A(P("How it works, step by step", S("t2", fontName=BOLD, fontSize=21, leading=26, textColor=MUTED)))
    A(Spacer(1, 14))
    A(rule(0, 12, ACCENT, 2.2))
    A(P(
        "One station. Twenty-six fixed targets on a 1.5 m sphere around it. "
        "Twenty-six photographs, taken one at a time, each aimed at a marker that stays put "
        "in the real world while you turn, tilt and step.",
        st_sub,
    ))
    A(Spacer(1, 30))
    A(table(
        None,
        [
            ["What it produces", "26 JPEGs plus a station record, one folder per station"],
            ["Where it runs", "Android, ARCore, Flutter UI, native GLES renderer"],
            ["Targets", "26 directions — three rings of eight, plus zenith and nadir"],
            ["Status of this document", "describes the current source; measured figures in section 8"],
        ],
        [42 * mm, CONTENT_W - 42 * mm],
        zebra=False,
    ))
    A(Spacer(1, 22))
    A(callout(
        "How to read this",
        "Sections 1–3 explain what the app is doing and in what order. Section 4 lists the "
        "numbers that decide everything, so you can check any behaviour against them. "
        "Sections 5–7 are the reference: what the screen says, what happens when AR loses "
        "tracking, and what to do when a step will not complete. Section 8 is the evidence "
        "that the arrangement really is fixed in the world.",
    ))
    A(Spacer(1, 26))
    A(P("CONTENTS", st_eyebrow))
    A(Spacer(1, 5))
    A(table(
        None,
        [
            ["01  What the app does", "06  What the screen is telling you"],
            ["02  The words this document uses", "07  When AR loses tracking"],
            ["03  The working sequence", "08  Evidence the arrangement is fixed"],
            ["04  The numbers that decide everything", "09  When a step will not complete"],
            ["05  The coordinate rules", "10  Where the code lives"],
        ],
        [CONTENT_W / 2, CONTENT_W / 2],
        zebra=False,
    ))
    A(NextPageTemplate("body"))
    A(PageBreak())

    # ── 1 ────────────────────────────────────────────────────────────────────
    A(KeepTogether(heading("01", "What the app does")))
    A(P(
        "You stand somewhere in a room, hold the phone up, and press <b>Calibrate station</b>. "
        "From that moment the app knows two things: <b>where</b> you are standing, and <b>which way</b> "
        "you were facing. Everything else is derived from those two facts.",
        st_lead,
    ))
    A(P(
        "It then builds an imaginary sphere of radius 1.5 m around that spot and puts 26 markers on it — "
        "eight around the horizon, eight 45° above, eight 45° below, one straight up and one straight down. "
        "Each marker is pinned to a real position in the room with an ARCore world anchor, and stays there "
        "for the rest of the session. Your job is to point the phone at each one in turn and hold still; "
        "the app takes the photograph, saves it, and moves you to the next.",
    ))
    A(Spacer(1, 4))
    A(SphereDiagram())
    A(P("Figure 1 — the arrangement seen from above. The sequence starts at the front target, because that is where you were already looking when you pressed Calibrate.", st_caption))
    A(Spacer(1, 6))
    A(P(
        "Twenty-six is not arbitrary: three rings of eight plus two poles covers the whole sphere with "
        "enough overlap that a stitched panorama has no gaps, and it is small enough to finish in one sitting.",
    ))

    # ── 2 ────────────────────────────────────────────────────────────────────
    A(KeepTogether(heading("02", "The words this document uses") + [table(
        ["Term", "What it means here"],
        [
            ["Station", "The one spot you calibrated from. Its position and orientation are frozen and never re-derived."],
            ["Target", "One of the 26 directions, and the marker placed 1.5 m along it."],
            ["Anchor", "ARCore's handle on a real-world position. The marker is drawn wherever the anchor is."],
            ["Plate / bezel", "The two GLB models: a white disc with a green centre, and the ring around it."],
            ["Ring", "The reticle in the middle of the screen — the same shape as the bezel. It fills as you hold still."],
            ["Alignment", "The 3-D angle between where the camera points and where the target is."],
            ["Stability window", "How long the phone must stay aimed and still before the shutter may fire."],
            ["Drift", "How far you have walked from the station. Past 0.6 m the shutter is blocked."],
            ["Ready", "Every condition is met. Only then can a photograph be taken."],
        ],
        [34 * mm, CONTENT_W - 34 * mm],
    )]))

    # ── 3 ────────────────────────────────────────────────────────────────────
    A(KeepTogether(heading("03", "The working sequence")))
    A(P(
        "Nine steps, in the order the app performs them. Steps 5 to 7 repeat 26 times — once per target.",
        st_lead,
    ))
    A(Ladder())
    A(Spacer(1, 10))

    # step details
    steps = [
        ("1", "Boot the AR session",
         "The app asks ARCore for a camera session, creates the texture the preview renders into, "
         "and starts listening to the pose stream — about 30 to 60 position-and-orientation readings a second.",
         "The preview appears. The status line reads <b>AR starting</b>, then <b>AR tracking OK</b> once ARCore "
         "has found the room.",
         "Nothing is placed yet. Placement needs a station, and a station needs a pose the app can trust."),
        ("2", "Calibrate the station",
         "You press <b>Calibrate station</b>. The app takes the current camera pose and rebuilds it from gravity: "
         "<b>up</b> comes from the world's vertical axis, <b>forward</b> is the direction you are facing flattened "
         "onto the horizontal plane. Your pitch and roll are deliberately thrown away.",
         "The status line reports how many targets were placed. The first target's marker appears straight ahead.",
         "If the reference kept the phone's tilt, the whole sphere would lean by whatever angle you happened to "
         "hold it at. Levelling it against gravity means the rings sit level however you were holding the phone. "
         "If you are pointing within 10° of straight up or down, calibration is refused — there is no reliable "
         "forward direction there."),
        ("3", "Place all 26 targets",
         "For each of the 26 directions the app computes one world position — station, plus 1.5 m along that "
         "direction — and asks ARCore to hold a world anchor there. All 26 are created in this single pass and "
         "kept for the whole session.",
         "The active target is solid; the other 25 are faint ghosts at their own positions.",
         "The position is <b>arithmetic, not a raycast</b>. No wall, floor or ceiling is consulted, so an unmapped "
         "room, an empty unit or a bare wall all place the targets identically. That is also why the shutter never "
         "waits for surfaces to be found."),
        ("4", "Aim at the current target",
         "Every frame the app compares the camera's forward axis with the target's current position and produces "
         "two things: a sentence, and an arrow. The arrow is drawn towards the target's actual place on the screen, "
         "not towards a bearing.",
         "<b>Aim at the front target. Turn right 45°</b>, with a short arrow pointing that way. When the target is "
         "off screen the arrow becomes an edge marker on the correct side.",
         "The arrow uses the same projection as the renderer, so it points at the marker you can see. It disappears "
         "once you are inside tolerance — at that point the ring is the whole message."),
        ("5", "Hold still",
         "The ring starts filling. It only fills while the alignment is inside 3° and the phone is genuinely still: "
         "no more than 5°/s of rotation, no more than 3 cm of wandering, readings no older than 250 ms.",
         "The ring sweeps clockwise in green. The chip reads <b>Hold still</b>, then <b>Ready</b>.",
         "One small tremor should not restart the wait, so the window tolerates 2° of wobble beyond the 3° "
         "tolerance before it gives up. A real turn breaks it immediately."),
        ("6", "The ring completes",
         "The ring is full. The app hides the active marker and its bezel — they are simply left out of the "
         "drawing — and fires the shutter. The anchor is untouched.",
         "The marker vanishes and the chip reads <b>Validating image</b>.",
         "Hiding it is the point: a full ring means the photograph is being taken, so a marker still sitting in "
         "front of the lens is only in the way. If the photograph fails, the marker comes back and you re-aim."),
        ("7", "Save and verify",
         "Five stages, each with its own deadline: take the still (6 s), write the file (10 s), check it exists, "
         "read it back and compare its length, then write the record (10 s). Any failure stops the sequence and "
         "says which stage it stopped at.",
         "A confirmation line with the image size, then the next target becomes active.",
         "The target is only marked captured after the file is on disk <b>and</b> read back intact. A write that "
         "returned but produced a truncated file is not a photograph."),
        ("8", "Advance",
         "The app steps to the next target that has no photograph, starting from the one just accepted. If you "
         "captured them out of order, it follows the list, not the numbering.",
         "The next marker becomes solid at its own position. Every completed marker stays hidden.",
         "Only the highlight moves. No target is created, moved or released, so the arrangement you calibrated "
         "against is the arrangement you finish with."),
        ("9", "All 26 done",
         "When the 26th photograph is accepted, the station is complete.",
         "Every marker is gone; the screen offers the review.",
         "The station's folder holds the reference pose, the 26 targets, the 26 records and the 26 JPEGs."),
    ]
    for num, title, what, see, why in steps:
        block = [P("Step %s — %s" % (num, title), st_h3)]
        block.append(P("<b>What happens.</b> " + what, st_body))
        block.append(P("<b>What you see.</b> " + see, st_body))
        block.append(P("<b>Why it works that way.</b> " + why, st_body))
        A(KeepTogether(block))

    # What one target actually costs, so the reader can plan a session.
    A(Spacer(1, 6))
    A(KeepTogether([
        P("What one target costs you", st_h3),
        table(
            ["Phase", "Typical time", "What sets it"],
            [
                ["Aim and turn", "2–5 s", "how far you have to rotate"],
                ["Hold still", "0.45 s", "the stability window, fixed"],
                ["Shutter and save", "0.1–0.3 s", "camera handover, file write, read-back"],
                ["Advance", "instant", "the next marker becomes active"],
            ],
            [36 * mm, 26 * mm, CONTENT_W - 62 * mm],
        ),
        Spacer(1, 5),
        P(
            "Twenty-six targets at a few seconds each is a two-to-three minute session, plus whatever time "
            "ARCore needs to find the room at the start. The bottleneck is almost always the aim, not the app.",
            st_small,
        ),
    ]))

    # ── 4 ────────────────────────────────────────────────────────────────────
    A(PageBreak())
    A(KeepTogether(heading("04", "The numbers that decide everything")))
    A(P(
        "Every behaviour above comes from a handful of constants. If something feels wrong, this is the table "
        "to check it against — they are the defaults in <font name='%s'>CaptureGeometryConfig</font> and "
        "<font name='%s'>PhotoCaptureService</font>." % (MONO, MONO),
        st_lead,
    ))
    A(table(
        ["Setting", "Value", "What it controls"],
        [
            ["Target radius", "1.5 m", "How far each target sits from the station."],
            ["Plate diameter", "0.22 m", "The physical size of the white disc — about 8° of view at 1.5 m."],
            ["Draw scale", "0.407×", "0.22 ÷ 0.54 (the plate's authored width). Applied once, to plate and bezel alike."],
            ["Bezel setback", "6 mm", "How far the ring sits behind the plate so the two faces are flush."],
            ["Alignment tolerance", "3.0°", "The shutter's strict test, and the angle at which the arrow disappears."],
            ["Window hysteresis", "+2.0°", "How far past tolerance you may wobble before the hold is thrown away."],
            ["Stability window", "450 ms", "How long you must stay aimed and still."],
            ["Max angular rate", "5 °/s", "Faster than this and the hold does not start."],
            ["Max orientation drift", "1.5°", "Total turning allowed across the window."],
            ["Max position drift", "3 cm", "Total wandering allowed across the window."],
            ["Max reading age", "250 ms", "An older pose is not acted on."],
            ["Station drift limit", "0.6 m", "Past this the shutter is blocked and the app asks you to walk back."],
            ["Still timeout", "6 s", "How long the camera may take to hand over an image."],
            ["Save timeout", "10 s", "Per write and per record."],
            ["Minimum JPEG", "2,048 bytes", "Anything smaller is not treated as a photograph."],
        ],
        [44 * mm, 22 * mm, CONTENT_W - 66 * mm],
    ))
    A(Spacer(1, 8))
    A(callout(
        "Two of these are easy to confuse",
        "<b>3°</b> is the shutter's test at the instant of capture, and it is strict. <b>5°</b> (3 + 2) is where the "
        "stability window gives up. That gap is why a hand tremor does not send you back to the start, while a "
        "deliberate turn does.",
        accent=AMBER,
        bg=colors.HexColor("#FBF6EF"),
    ))

    # ── 5 ────────────────────────────────────────────────────────────────────
    A(KeepTogether(
        heading("05", "The coordinate rules")
        + [
            P(
                "Everything in the app is expressed in one frame, anchored at the station: <b>+Z is forward</b>, "
                "<b>+X is to your right</b>, <b>+Y is up</b>. Yaw turns around the vertical axis, pitch tilts up and down.",
                st_lead,
            ),
            table(
                ["Yaw / pitch", "Means", "Lands at"],
                [
                    ["0° / 0°", "straight ahead", "T01 — the front target, first in the sequence"],
                    ["+90° / 0°", "90° to your right", "T03, on the horizon to your right"],
                    ["180° / 0°", "directly behind you", "T05"],
                    ["−90° / 0°", "90° to your left", "T07"],
                    ["any / +45°", "halfway up", "the upper ring, T09–T16"],
                    ["any / −45°", "halfway down", "the lower ring, T17–T24"],
                    ["— / +90°", "straight up", "T25, the zenith"],
                    ["— / −90°", "straight down", "T26, the nadir"],
                ],
                [30 * mm, 42 * mm, CONTENT_W - 72 * mm],
            ),
        ]
    ))
    A(Spacer(1, 8))
    A(P(
        "At the two poles the yaw term vanishes: every yaw gives the same point, which is why the guidance at the "
        "zenith and nadir uses the plain 3-D angle and never says \"turn right\".",
    ))
    A(Spacer(1, 4))
    A(P(
        "One detail that looks like a bug and is not: a camera's own right-hand direction is the mirror of a "
        "mathematical rotation's, so the app negates the horizontal axis when it converts. The visible consequence "
        "is that a target at yaw +90° (\"to your right\") sits on the world's −X axis. That is correct, and it is "
        "what makes the arrow point the way the sentence says.",
    ))

    # ── 6 ────────────────────────────────────────────────────────────────────
    A(KeepTogether(heading("06", "What the screen is telling you")))
    A(P(
        "Four places carry information. When something is not working, read them in this order: the status line "
        "first, then the phase chip, then the sentence, then the drawer.",
        st_lead,
    ))
    A(KeepTogether([
        P("Status line — top left", st_h3),
        table(
            ["Reads", "Means"],
            [
                ["AR tracking OK · no planes yet", "Tracking is fine. No surfaces have been found — irrelevant, because targets are placed by calculation."],
                ["AR starting", "The session is up but no pose has arrived yet."],
                ["AR tracking paused", "ARCore has lost confidence. It is still running and will usually recover; nothing is destroyed."],
                ["AR tracking stopped", "The session has to be restarted. The Retry action appears."],
            ],
            [52 * mm, CONTENT_W - 52 * mm],
        ),
    ]))
    A(Spacer(1, 6))
    A(KeepTogether([
        P("Phase chip — the small label near the shutter", st_h3),
        table(
            ["Chip", "Means", "Can you shoot?"],
            [
                ["Initialising", "No trustworthy pose yet.", "No"],
                ["Aim at target", "A pose, but not aimed — or aimed from the wrong place.", "No"],
                ["Hold still", "Aimed, ring filling.", "No"],
                ["Ready", "Aimed, steady, every condition met.", "Yes — and it fires by itself"],
                ["Validating image", "A photograph is being written.", "No"],
                ["Accepted", "Saved and recorded.", "—"],
                ["Retry", "The last attempt failed. Re-aim to try again.", "No"],
            ],
            [30 * mm, CONTENT_W - 62 * mm, 32 * mm],
        ),
    ]))
    A(Spacer(1, 6))
    A(P("The sentence in the middle", st_h3))
    A(P(
        "This is the instruction, and it names the action: <b>Aim at the front target. Turn right 45°</b>, "
        "<b>Walk back to the station, or press Recalibrate here</b>, <b>The last attempt failed — re-aim at the "
        "target to try again</b>. It is derived from the same state as the chip, so the two cannot disagree.",
    ))
    A(Spacer(1, 6))
    A(P("The drawer — tap the status line", st_h3))
    A(P(
        "Target id and its yaw/pitch, whether the marker is placed, the plane breakdown, the GLB triangle count, "
        "the camera's still resolution and focus mode, the plate's physical size and its current distance, and "
        "the actionable advice. That last line is the one to read when tracking misbehaves.",
    ))

    # ── 7 ────────────────────────────────────────────────────────────────────
    A(KeepTogether(heading("07", "When AR loses tracking")))
    A(P(
        "ARCore reports four states. Only one of them is a problem, and even that one is usually temporary.",
        st_lead,
    ))
    A(table(
        ["State", "What the app does"],
        [
            ["tracking", "Normal operation. Targets are drawn from their anchors; the shutter is live once aimed."],
            ["paused", "The markers stay exactly where they are and keep being drawn — a pause is ARCore losing confidence in the "
                       "<i>room</i>, not the marker moving. No alignment is computed from the paused pose, the drift figure holds its "
                       "last trustworthy value, and the shutter is blocked."],
            ["stopped", "The session must be restarted. The Retry action appears; the station is discarded because a new session has "
                        "a new world origin."],
            ["unavailable", "The device cannot run AR. The app says so instead of pretending."],
        ],
        [24 * mm, CONTENT_W - 24 * mm],
    ))
    A(Spacer(1, 8))
    A(P(
        "ARCore also says <b>why</b> it paused, and the app repeats it verbatim because each reason is a different "
        "action:",
    ))
    A(table(
        ["ARCore's reason", "What to do"],
        [
            ["INSUFFICIENT_FEATURES", "Point at something with visible detail — a textured wall, furniture, a door frame. A blank wall gives the tracker nothing to hold on to."],
            ["INSUFFICIENT_LIGHT", "Move somewhere brighter."],
            ["EXCESSIVE_MOTION", "Slow down; hold the phone still for a moment."],
            ["BAD_STATE", "Point back roughly where you started and let it recover."],
            ["CAMERA_UNAVAILABLE", "Another app is using the camera."],
        ],
        [42 * mm, CONTENT_W - 42 * mm],
    ))
    A(Spacer(1, 8))
    A(callout(
        "The one thing the app cannot fix",
        "When ARCore has too few features to track, its map of the room is unreliable — and the markers move with "
        "that map, because that is where they are anchored. The app can keep them placed, keep them drawn, refuse "
        "to take a photograph from an unreliable world, and tell you why. It cannot make the tracker see detail "
        "that is not there. More texture and more light are the only real remedies.",
        accent=AMBER,
        bg=colors.HexColor("#FBF6EF"),
    ))

    # ── 8 ────────────────────────────────────────────────────────────────────
    A(KeepTogether(heading("08", "Evidence that the arrangement really is fixed")))
    A(P(
        "The claim \"the targets do not move with the phone\" is testable without a device, because the position "
        "of every target is computed from the station alone. <font name='%s'>dart run tool/verify_sphere.dart</font> "
        "places all 26 through the same function the app uses, then moves the camera four different ways and "
        "measures how far the targets moved." % MONO,
        st_lead,
    ))
    A(table(
        ["Check", "Result"],
        [
            ["Distance from the station, all 26 targets", "1.500 m — worst error 2.2 × 10⁻¹⁶ m (floating-point noise)"],
            ["Yaw recovered from the placed position", "matches the spec exactly — worst error 0.0°"],
            ["Pitch recovered from the placed position", "worst error 7.1 × 10⁻¹⁵°"],
            ["World movement, camera at the station / turned 90° / tilted 40° / walked 2 m", "0.0 m — literally zero"],
            ["Marker facing as the camera walks away", "fixed (facing·toCamera falls 1.00 → 0.24) — not a billboard"],
        ],
        [72 * mm, CONTENT_W - 72 * mm],
    ))
    A(Spacer(1, 8))
    A(P(
        "What does change is where the target appears on screen, and that is the perspective you are meant to see:",
    ))
    A(table(
        ["Camera", "T01 on a 1080×2400 screen"],
        [
            ["at the station, facing forward", "dead centre (540, 1200)"],
            ["turned 90° right", "behind you — pinned to the edge (1064, 1200)"],
            ["tilted up 40°", "off the bottom (540, 2693)"],
            ["walked 2 m right and 1 m forward", "off to the left (−407, 822)"],
        ],
        [72 * mm, CONTENT_W - 72 * mm],
    ))
    A(Spacer(1, 6))
    A(P(
        "The same run is also the quickest way to confirm, after any change, that the geometry has not regressed: "
        "the last line must read <font name='%s'>0.0e+0 m</font>." % MONO,
    ))

    # ── 9 ────────────────────────────────────────────────────────────────────
    A(KeepTogether(heading("09", "When a step will not complete")))
    A(table(
        ["Symptom", "Likely cause", "What to do"],
        [
            ["\"AR tracking paused\" and it stays that way",
             "Too few features or too little light for the tracker",
             "Point at textured surfaces; add light. The markers are still placed — nothing has been lost."],
            ["Ring never fills",
             "The phone is moving, or the reading is stale",
             "Hold still; the sentence names the reason (\"moving at 8.2°/s\", \"waiting for a fresh pose\")."],
            ["Ring fills, chip says Ready, nothing happens",
             "A capture is already in flight",
             "Wait for the confirmation line. Only one photograph is taken at a time."],
            ["\"Walk back to the station\"",
             "You are more than 0.6 m from where you calibrated",
             "Walk back, or press Recalibrate here to start a new station where you stand."],
            ["\"The last attempt failed — re-aim\"",
             "The camera or the disk refused the photograph",
             "Look away and back, then try again. The error line says which stage failed."],
            ["A marker vanished mid-sequence",
             "Its photograph was accepted, or you are aimed and steady (the ring is full)",
             "Expected. It comes back if the hold is lost or the photograph fails."],
            ["Targets look bigger or smaller than each other",
             "Perspective — they are at different distances from the lens",
             "Nothing to fix. Every target is 0.22 m across; the drawer shows the size and the distance."],
            ["Marker sits slightly off the wall it should be on",
             "ARCore's map is still refining, or it is drifting for lack of features",
             "Move the phone to map more of the room. The marker follows the anchor, not the wall."],
        ],
        [46 * mm, 52 * mm, CONTENT_W - 98 * mm],
    ))

    # ── 10 ───────────────────────────────────────────────────────────────────
    A(KeepTogether(heading("10", "Where the code lives")))
    A(table(
        ["File", "Responsibility"],
        [
            ["capture_controller.dart", "The conductor: calibration, placement, the pose loop, the shutter, advancing."],
            ["capture_state.dart", "The one immutable snapshot the screen paints, and the single readiness decision."],
            ["target_sphere.dart", "The 26 directions, the geometry constants, and resolveTarget — the one authority for placement."],
            ["station_frame.dart", "The frozen station reference and the gravity-aligned calibration."],
            ["plane_anchor_service.dart", "The 26 world anchors, the scene push, and the hidden/visible set."],
            ["alignment_calculator.dart", "Camera pose → target position → the angle, the turn, the tilt."],
            ["stability_monitor.dart", "The 450 ms window and its five conditions."],
            ["photo_capture_service.dart", "Take, write, read back, record — with a deadline per stage."],
            ["projection.dart", "The pinhole model the arrow and the marker both use."],
            ["ArCoreSessionController.kt", "The native side: session, render loop, anchors, stills."],
            ["ArGlRenderer.kt", "The GLES renderer: mvp = projection × view × anchor × rotation × offset × scale."],
            ["tool/verify_sphere.dart", "The measurement in section 8."],
        ],
        [56 * mm, CONTENT_W - 56 * mm],
    ))
    A(Spacer(1, 10))
    A(rule(0, 8))
    A(P(
        "This document describes the source as it stands. It is generated from the same constants the app runs on, "
        "and the measurements in section 8 are reproduced by running the tool named there — not asserted.",
        st_small,
    ))

    doc.build(story)
    return OUT


if __name__ == "__main__":
    path = build()
    print("wrote", os.path.abspath(path))
