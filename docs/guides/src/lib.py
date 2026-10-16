"""Builds the CarmaCars portal guides: screenshot crops, HTML pages, and the data the printer needs.

Each guide lives in guides/<key>.py and calls the helpers below. `python3 build.py` writes img/*.jpg,
<key>.html and <key>-cover.html; `node print.mjs` prints them to ../pdf/.
"""
import hashlib
import html
import json
import os
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
SCREENS = os.path.normpath(os.path.join(HERE, '..', 'screens'))
MANIFEST = {s['file'][:-4]: s for s in json.load(open(os.path.join(SCREENS, 'manifest.json')))['screens']}

PHONE_SCALE = 3
DESK_SCALE = 2
PHONE_HDR = 60       # the site header on a phone shot (CSS px)
PHONE_GAP_END = 595  # phone shots have an empty band from the header to here
DESK_HDR = 72        # the site header on a desktop shot
PHONE_OUT_W = 640    # output width of a phone image (px)
DESK_OUT_MAX = 1600  # output width cap of a desktop image (px)

SITE_PHONE = '647-575-3377'
SITE_EMAIL = 'contact@carmacars.ca'

USED_IMAGES = set()


def esc(s):
    return html.escape(s, quote=True)


# ---------- inline text helpers ----------

def B(label):
    """An exact button or link label from the screen."""
    cls = 'ui' if len(label) <= 26 else 'ui wrap'
    return f'<b class="{cls}">{esc(label)}</b>'


def P(*parts):
    """A path through the menus: P('Banking', 'Where we pay you')."""
    inner = '<i class="sep">&rsaquo;</i>'.join(f'<span>{esc(p)}</span>' for p in parts)
    return f'<span class="path">{inner}</span>'


def U(url):
    return f'<span class="url">{esc(url)}</span>'


# ---------- screenshots ----------

class Shot:
    """A screenshot, cropped in CSS pixels of the original page.

    crop: (x0, y0, x1, y1). On phone shots y counts on the original page (the content starts near 600);
    the site header is put back on top when hdr is true. pins: [(n, x, y)], boxes: [(x, y, w, h)],
    both in original CSS pixels.
    """

    def __init__(self, key, crop=None, pins=(), boxes=(), hdr=True, url=None, width=None, caption=None):
        if key not in MANIFEST:
            raise KeyError(key)
        self.key = key
        self.m = MANIFEST[key]
        self.phone = self.m['viewport'] == 'phone'
        w, h = self.m['width'], self.m['height']
        self.crop = crop or (0, PHONE_GAP_END if self.phone else 0, w, h)
        self.pins = list(pins)
        self.boxes = list(boxes)
        self.hdr = hdr
        self.url = url or ('carmacars.ca' + self.m['path'])
        self.width = width  # display width in inches (optional)
        self.caption = caption

    def _hdr_h(self):
        x0, y0, x1, y1 = self.crop
        if not self.hdr:
            return 0
        if self.phone:
            return PHONE_HDR if y0 >= PHONE_HDR + 20 else 0
        return DESK_HDR if (y0 >= DESK_HDR + 10 and x0 == 0) else 0

    def size(self):
        x0, y0, x1, y1 = self.crop
        return x1 - x0, (y1 - y0) + self._hdr_h()

    def prepare(self):
        x0, y0, x1, y1 = self.crop
        hh = self._hdr_h()
        sc = PHONE_SCALE if self.phone else DESK_SCALE
        tag = hashlib.sha1(json.dumps([self.key, self.crop, hh]).encode()).hexdigest()[:8]
        name = f"{self.key.replace('/', '-')}-{tag}.jpg"
        out = os.path.join(HERE, 'img', name)
        USED_IMAGES.add(name)
        if not os.path.exists(out):
            im = Image.open(os.path.join(SCREENS, self.key + '.png')).convert('RGB')
            body = im.crop((x0 * sc, y0 * sc, x1 * sc, y1 * sc))
            if hh:
                head = im.crop((x0 * sc, 0, x1 * sc, hh * sc))
                canvas = Image.new('RGB', (body.width, body.height + head.height), 'white')
                canvas.paste(head, (0, 0))
                canvas.paste(body, (0, head.height))
                body = canvas
            tw = PHONE_OUT_W if self.phone else min(DESK_OUT_MAX, body.width)
            if body.width != tw:
                body = body.resize((tw, round(body.height * tw / body.width)), Image.LANCZOS)
            body.save(out, 'JPEG', quality=84, optimize=True, progressive=True)
        return 'img/' + name

    def _xy(self, x, y):
        x0, y0, x1, y1 = self.crop
        W, H = self.size()
        return (x - x0) / W * 100, (y - y0 + self._hdr_h()) / H * 100

    def html(self, width_in):
        src = self.prepare()
        W, H = self.size()
        overlays = []
        for (bx, by, bw, bh) in self.boxes:
            l, t = self._xy(bx, by)
            overlays.append(f'<span class="hl" style="left:{l:.2f}%;top:{t:.2f}%;width:{bw / W * 100:.2f}%;height:{bh / H * 100:.2f}%"></span>')
        edge = (10.5 / 72) / width_in * 100  # keep the pin's circle inside the figure
        for (n, px, py) in self.pins:
            l, t = self._xy(px, py)
            l = min(max(l, edge), 100 - edge)
            overlays.append(f'<span class="pin" style="left:{l:.2f}%;top:{t:.2f}%">{n}</span>')
        img = f'<img src="{src}" alt="" style="aspect-ratio:{W}/{H}">'
        inner = f'<div class="imgwrap">{img}{"".join(overlays)}</div>'
        if self.phone:
            frame = f'<div class="phone">{inner}</div>'
            cls = 'shot is-phone'
        else:
            frame = (f'<div class="browser"><div class="bar"><i></i><i></i><i></i>'
                     f'<span class="addr">{esc(self.url)}</span></div>{inner}</div>')
            cls = 'shot is-desk'
        cap = f'<figcaption>{self.caption}</figcaption>' if self.caption else ''
        return f'<figure class="{cls}" style="width:{width_in:.2f}in">{frame}{cap}</figure>'

    def height_in(self, width_in):
        W, H = self.size()
        extra = 0.32 if not self.phone else 0.2
        return width_in * H / W + extra


def S(key, *crop, **kw):
    """Shorthand: S('owner/07-banking-desktop', 0, 72, 1440, 900, pins=[...])."""
    return Shot(key, crop=tuple(crop) if crop else None, **kw)


# ---------- the guide ----------

CONTENT_W = 7.2   # inches between the side margins
PAGE_H = 9.65     # usable height


class Guide:
    def __init__(self, key, title, short, promise, cover_shot, audience, signin_url, lands_on):
        self.key = key
        self.title = title
        self.short = short
        self.promise = promise
        self.cover_shot = cover_shot
        self.audience = audience
        self.signin_url = signin_url
        self.lands_on = lands_on
        self.parts = []
        self.chapters = []   # (number, title, blurb)
        self.step_n = 0
        self.task_open = False
        self.pending_head = None
        self.start_html = ''
        self.ref_html = ''
        self.warnings = []

    # structure
    def chapter(self, title, intro, blurb=None):
        self._close_task()
        n = len(self.chapters) + 1
        self.chapters.append((n, title, blurb or intro))
        self.parts.append(
            f'<section class="chapter"><header class="ch-head"><div class="ch-num">{n:02d}</div>'
            f'<div><div class="ch-kicker">Chapter {n}</div><h1>{esc(title)}</h1>'
            f'<p class="ch-intro">{intro}</p></div></header>')
        self.parts.append('</section>')  # closed placeholder; tasks are appended after it
        return self

    def task(self, title, intro=None):
        self._close_task()
        self.step_n = 0
        head = f'<h2>{esc(title)}</h2>' + (f'<p class="lead">{intro}</p>' if intro else '')
        self.pending_head = head
        self.parts.append('<section class="task">')
        self.task_open = True
        return self

    def _close_task(self):
        if self.pending_head:
            self.parts.append(f'<div class="keep">{self.pending_head}</div>')
            self.pending_head = None
        if self.task_open:
            self.parts.append('</section>')
            self.task_open = False

    def _emit(self, block_html):
        if self.pending_head:
            block_html = f'<div class="keep">{self.pending_head}{block_html}</div>'
            self.pending_head = None
        self.parts.append(block_html)

    # blocks
    def steps(self, items, shot=None, layout=None, fig_w=None):
        """items: list of html strings (one short instruction each). Numbers continue within the task."""
        lis = []
        for it in items:
            self.step_n += 1
            lis.append(f'<li><span class="n">{self.step_n}</span><div class="t">{it}</div></li>')
        ol = f'<ol class="steps" start="{self.step_n - len(items) + 1}">{"".join(lis)}</ol>'
        if not shot:
            self._emit(f'<div class="stepblock only">{ol}</div>')
            return self
        W, H = shot.size()
        if layout is None:
            if shot.phone:
                layout = 'side'
            else:
                layout = 'side' if W <= 1000 else 'below'
        max_h = 5.4 if shot.phone else 5.0
        if layout == 'side':
            fw = fig_w or (shot.width or (2.45 if shot.phone else min(4.3, 0.0046 * W)))
            if not fig_w:
                fw = min(fw, max_h * W / H)
            fig = shot.html(fw)
            h = shot.height_in(fw)
            self._check(h, shot)
            self._emit(f'<div class="stepblock side"><div class="col-t">{ol}</div><div class="col-f">{fig}</div></div>')
        else:
            fw = fig_w or shot.width or min(CONTENT_W, 4.4 * W / H)
            fig = shot.html(fw)
            h = shot.height_in(fw) + 0.45 * len(items)
            self._check(h, shot)
            self._emit(f'<div class="stepblock below">{ol}<div class="col-f">{fig}</div></div>')
        return self

    def figure(self, shot, fig_w=None, note=None):
        fw = fig_w or shot.width or (2.45 if shot.phone else CONTENT_W)
        self._check(shot.height_in(fw), shot)
        n = f'<p class="fignote">{note}</p>' if note else ''
        stack = ' stack' if fw > 4.6 else ''
        self._emit(f'<div class="figblock{stack}">{shot.html(fw)}{n}</div>')
        return self

    def _check(self, h, shot):
        if h > PAGE_H - 0.6:
            self.warnings.append(f'{self.key}: figure {shot.key} {shot.crop} is {h:.1f}in tall')

    def tip(self, text, label='Tip'):
        self._emit(f'<aside class="box tip"><span class="lbl">{esc(label)}</span><div>{text}</div></aside>')
        return self

    def warn(self, text, label='Watch out'):
        self._emit(f'<aside class="box warn"><span class="lbl">{esc(label)}</span><div>{text}</div></aside>')
        return self

    def para(self, text):
        self._emit(f'<p class="para">{text}</p>')
        return self

    def bullets(self, items):
        self._emit('<ul class="bul">' + ''.join(f'<li>{i}</li>' for i in items) + '</ul>')
        return self

    def table(self, rows, head=None, cls=''):
        h = ''
        if head:
            h = '<thead><tr>' + ''.join(f'<th>{c}</th>' for c in head) + '</tr></thead>'
        b = ''.join('<tr>' + ''.join(f'<td>{c}</td>' for c in r) + '</tr>' for r in rows)
        self._emit(f'<table class="tbl {cls}">{h}<tbody>{b}</tbody></table>')
        return self

    def flow(self, items):
        cells = ''.join(f'<div><b>{i + 1}</b><span>{a}</span><em>{b}</em></div>' for i, (a, b) in enumerate(items))
        self._emit(f'<div class="flow">{cells}</div>')
        return self

    def phones(self, items, per_row=3, width=2.05):
        """A grid of phone shots, each with a numbered caption: items = [(shot, html caption)]."""
        cells = []
        for shot, cap in items:
            self.step_n += 1
            cells.append(f'<div class="pcell"><div class="pcap"><span class="n">{self.step_n}</span><div>{cap}</div></div>{shot.html(width)}</div>')
            self._check(shot.height_in(width) + 0.6, shot)
        rows = [cells[i:i + per_row] for i in range(0, len(cells), per_row)]
        for r in rows:
            self._emit(f'<div class="pgrid" style="grid-template-columns:repeat({per_row},1fr)">{"".join(r)}</div>')
        return self

    def raw(self, h):
        self._emit(h)
        return self

    def pagebreak(self):
        self._close_task()
        self.parts.append('<div class="pb"></div>')
        return self

    # special pages
    def start_page(self, who, need, first_steps, shot, note=None):
        steps = ''.join(f'<li><span class="n">{i + 1}</span><div class="t">{s}</div></li>' for i, s in enumerate(first_steps))
        need_html = ''.join(f'<li>{n}</li>' for n in need)
        fig = shot.html(2.15)
        note_html = f'<aside class="box tip"><span class="lbl">Good to know</span><div>{note}</div></aside>' if note else ''
        self.start_html = f'''
<section class="start">
  <div class="kicker-red">Before you begin</div>
  <h1 class="big">Start here</h1>
  <div class="start-grid">
    <div>
      <h3>Who this guide is for</h3>
      <p>{who}</p>
      <h3>What you need</h3>
      <ul class="bul">{need_html}</ul>
    </div>
    <div class="signin-card">
      <div class="lbl">Sign in at</div>
      <div class="big-url">{esc(self.signin_url)}</div>
      <div class="sub">You land on {self.lands_on}.</div>
    </div>
  </div>
  <div class="keep">
  <h2 class="first">Your first sign-in</h2>
  <div class="stepblock side"><div class="col-t"><ol class="steps">{steps}</ol>{note_html}</div><div class="col-f">{fig}</div></div>
  </div>
</section>'''

    def reference(self, nav_rows, top_tasks, extra_problems=()):
        nav = ''.join(f'<tr><td><b>{a}</b></td><td>{b}</td></tr>' for a, b in nav_rows)
        tasks = ''.join(f'<li><b>{a}</b><span>{b}</span></li>' for a, b in top_tasks)
        probs = [
            ('A link says it expired', f'Links in our emails work for 24 hours, once. Press {B("Send me a new link")} on that page.'),
            ('"Error 1102" on a page', 'A short limit on our web host. Reload the page. You are still signed in.'),
            ('"That email and password do not match an account."', f'Check the address, or use {B("Set a new password")} on the sign-in page.'),
        ] + list(extra_problems)
        prob = ''.join(f'<tr><td><b>{a}</b></td><td>{b}</td></tr>' for a, b in probs)
        self.ref_html = f'''
<section class="ref">
  <div class="ref-head"><div><div class="kicker-red">Keep this page handy</div><h1 class="big">Quick reference</h1></div>
  <div class="ref-signin"><div class="lbl">Sign in</div><div class="u">{esc(self.signin_url)}</div></div></div>
  <div class="ref-grid">
    <div class="card"><h3>Where things are</h3><table class="mini">{nav}</table></div>
    <div class="card"><h3>Top tasks</h3><ol class="toptasks">{tasks}</ol></div>
    <div class="card"><h3>If something goes wrong</h3><table class="mini">{prob}</table></div>
    <div class="card dark"><h3>Talk to us</h3>
      <div class="contact"><div><span>Email</span><b>{SITE_EMAIL}</b></div><div><span>Phone</span><b>{SITE_PHONE}</b></div></div>
      <p>Tell us your name, the booking or car, and what you see on the screen.</p></div>
  </div>
</section>'''

    # output
    def html_doc(self, page_map=None):
        self._close_task()
        pm = page_map or {}

        def pg(t):
            return str(pm.get(t, '00'))
        toc_rows = ''.join(
            f'<li><span class="tn">{n:02d}</span><span class="tt"><b>{esc(t)}</b><em>{b}</em></span><span class="tp">{pg(t)}</span></li>'
            for n, t, b in self.chapters)
        toc_rows += f'<li class="qr"><span class="tn">&rarr;</span><span class="tt"><b>Quick reference</b><em>One page with the essentials.</em></span><span class="tp">{pg("Quick reference")}</span></li>'
        dense = ' dense' if len(self.chapters) > 8 else ''
        toc = f'''<section class="toc{dense}"><div class="kicker-red">Inside</div><h1 class="big">Contents</h1>
<ol class="toc-list"><li><span class="tn">&rarr;</span><span class="tt"><b>Start here</b><em>Who this is for and your first sign-in.</em></span><span class="tp">{pg("Start here")}</span></li>{toc_rows}</ol></section>'''
        body = ''.join(self.parts)
        return f'''<!doctype html>
<html lang="en-CA"><head><meta charset="utf-8"><title>CarmaCars {esc(self.title)}</title>
<link rel="stylesheet" href="guide.css"></head>
<body class="g-{self.key}">
<div class="dummy"></div>
{self.start_html}
{toc}
{body}
{self.ref_html}
</body></html>'''

    def cover_doc(self):
        sh = self.cover_shot
        src = sh.prepare()
        W, H = sh.size()
        words = self.title.split(' ')
        t1 = words[0]
        t2 = ' '.join(words[1:])
        return f'''<!doctype html>
<html lang="en-CA"><head><meta charset="utf-8"><title>CarmaCars {esc(self.title)} cover</title>
<link rel="stylesheet" href="guide.css"><style>@page {{ margin: 0; }}</style></head>
<body class="cover-body">
<div class="cover">
  <div class="stripe"></div>
  <div class="cv-top"><div class="wm">Carma<b>Cars</b></div><div class="cv-site">carmacars.ca</div></div>
  <div class="cv-title"><div class="cv-kicker">User guide</div><h1><span>{esc(t1)}</span><span>{esc(t2)}</span></h1>
  <div class="cv-rule"></div><p class="cv-promise">{self.promise}</p></div>
  <div class="cv-phone"><div class="phone big"><div class="imgwrap"><img src="{src}" alt="" style="aspect-ratio:{W}/{H}"></div></div></div>
  <div class="cv-foot"><div class="tag">Drive your carma.</div><div class="ed">October 2026 edition</div></div>
</div>
</body></html>'''
