"""Export the six guides as Markdown sections, the form the portals store them in (migration 0044).

python3 export.py            writes ../content/<portal>.json for every guide
python3 export.py owner      one guide

Each guide's build() in guides/<key>.py runs with the helpers below in place of lib's HTML ones, so the text, the
steps, the screenshots (with their numbered pins) and the tips come out as Markdown that an Admin can edit in
Admin > Settings > Guides. The screenshots are the cropped JPEGs in img/, served by the site at /guides/img/<name>.
The Markdown dialect is the one web/src/features/guides/markdown.ts renders:

  ## Task title, ### small heading, paragraphs, - bullets, 1. numbered steps (a list may start at any number)
  **Button label**, `carmacars.ca/address`, *italic*
  ![caption](/guides/img/x.jpg "phone; pins: 1 45.2 30.1, 2 50 60; boxes: 10 20 30 5; address: carmacars.ca/owner")
      (an image right after a numbered list sits beside or below its steps)
  > Tip: text        > Watch out: text        > Good to know: text
  | a | b | tables, with a header row
  :::flow / Title | what happens / :::        the row of numbered stages
  :::phones / 1. caption ![](src "phone") / :::   a grid of phone screens with numbered captions
"""
import html
import importlib
import json
import os
import re
import sys

import lib

HERE = lib.HERE
OUT = os.environ.get('GUIDE_CONTENT') or os.path.normpath(os.path.join(HERE, '..', 'content'))
KEYS = ['renter', 'owner', 'admin', 'va', 'field', 'investor']
IMG_BASE = '/guides/img/'


def md_text(s):
    """The guides' inline HTML (from B, P and U, and the odd tag) as Markdown."""
    s = s or ''
    s = re.sub(r'<b class="ui[^"]*">(.*?)</b>', r'**\1**', s)
    s = re.sub(r'<span class="url">(.*?)</span>', r'`\1`', s)
    s = re.sub(r'<span class="path">(.*?)</span>', lambda m: ' > '.join('**' + p + '**' for p in re.findall(r'<span>(.*?)</span>', m.group(1))), s)
    s = re.sub(r'</?(b|strong)>', '**', s)
    s = re.sub(r'</?(i|em)>', '*', s)
    s = re.sub(r'<br\s*/?>', ' ', s)
    s = re.sub(r'<[^>]+>', '', s)
    s = html.unescape(s)
    s = s.replace('\u2013', '-').replace('\u2014', '-')
    return re.sub(r'[ \t]+', ' ', s).strip()


def image(shot, caption=None):
    src = shot.prepare()
    name = os.path.basename(src)
    W, H = shot.size()
    parts = ['phone' if shot.phone else 'desktop', f'size: {W} {H}']
    if not shot.phone:
        parts.append('address: ' + shot.url)
    pins = []
    edge_pct = 3.0
    for (n, px, py) in shot.pins:
        l, t = shot._xy(px, py)
        pins.append(f'{n} {min(max(l, edge_pct), 100 - edge_pct):.1f} {t:.1f}')
    if pins:
        parts.append('pins: ' + ', '.join(pins))
    boxes = []
    for (bx, by, bw, bh) in shot.boxes:
        l, t = shot._xy(bx, by)
        boxes.append(f'{l:.1f} {t:.1f} {bw / W * 100:.1f} {bh / H * 100:.1f}')
    if boxes:
        parts.append('boxes: ' + ', '.join(boxes))
    cap = md_text(caption or shot.caption or '')
    return f'![{cap}]({IMG_BASE}{name} "{"; ".join(parts)}")'


class MdGuide(lib.Guide):
    """The same calls as lib.Guide, writing Markdown sections."""

    def __init__(self, *a, **kw):
        super().__init__(*a, **kw)
        self.sections = []
        self.cur = None
        self.step_n = 0

    def _sec(self, kind, title, blurb=None):
        self.cur = {'kind': kind, 'title': title, 'blurb': blurb, 'lines': []}
        self.sections.append(self.cur)
        return self.cur

    def _add(self, block):
        self.cur['lines'].append(block.strip('\n'))

    # structure
    def chapter(self, title, intro, blurb=None):
        self.chapters.append((len(self.chapters) + 1, title, blurb or intro))
        self._sec('chapter', title, md_text(blurb or intro))
        self._add(md_text(intro))
        return self

    def task(self, title, intro=None):
        self.step_n = 0
        self._add('## ' + md_text(title))
        if intro:
            self._add(md_text(intro))
        return self

    def steps(self, items, shot=None, layout=None, fig_w=None):
        lines = []
        for it in items:
            self.step_n += 1
            lines.append(f'{self.step_n}. {md_text(it)}')
        block = '\n'.join(lines)
        if shot:
            block += '\n\n' + image(shot)
        self._add(block)
        return self

    def figure(self, shot, fig_w=None, note=None):
        self._add(image(shot, note))
        return self

    def tip(self, text, label='Tip'):
        self._add(f'> {label}: {md_text(text)}')
        return self

    def warn(self, text, label='Watch out'):
        self._add(f'> {label}: {md_text(text)}')
        return self

    def para(self, text):
        self._add(md_text(text))
        return self

    def bullets(self, items):
        self._add('\n'.join('- ' + md_text(i) for i in items))
        return self

    def table(self, rows, head=None, cls=''):
        cell = lambda c: md_text(str(c)).replace('|', '/')
        head = head or [''] * len(rows[0])
        out = ['| ' + ' | '.join(cell(c) for c in head) + ' |', '|' + '|'.join(' --- ' for _ in head) + '|']
        out += ['| ' + ' | '.join(cell(c) for c in r) + ' |' for r in rows]
        self._add('\n'.join(out))
        return self

    def flow(self, items):
        self._add(':::flow\n' + '\n'.join(f'{md_text(a)} | {md_text(b)}' for a, b in items) + '\n:::')
        return self

    def phones(self, items, per_row=3, width=2.05):
        out = []
        for shot, cap in items:
            self.step_n += 1
            out.append(f'{self.step_n}. {md_text(cap)} {image(shot)}')
        self._add(':::phones\n' + '\n'.join(out) + '\n:::')
        return self

    def raw(self, h):
        self._add(md_text(h))
        return self

    def pagebreak(self):
        return self

    # special pages
    def start_page(self, who, need, first_steps, shot, note=None):
        cur = self.cur
        sec = {'kind': 'start', 'title': 'Start here', 'blurb': 'Who this is for and your first sign-in.', 'lines': []}
        self.sections.insert(0, sec)
        self.cur = sec
        self._add('### Who this guide is for\n\n' + md_text(who))
        self._add('### What you need\n\n' + '\n'.join('- ' + md_text(n) for n in need))
        self._add('## Your first sign-in')
        self._add('\n'.join(f'{i + 1}. {md_text(s)}' for i, s in enumerate(first_steps)) + '\n\n' + image(shot))
        if note:
            self._add(f'> Good to know: {md_text(note)}')
        self.cur = cur

    def reference(self, nav_rows, top_tasks, extra_problems=()):
        sec = {'kind': 'reference', 'title': 'Quick reference', 'blurb': 'One page with the essentials.', 'lines': []}
        cur = self.cur
        self.cur = sec
        self._add('### Where things are\n\n| Item | What it is for |\n| --- | --- |\n' +
                  '\n'.join(f'| **{md_text(a)}** | {md_text(b)} |' for a, b in nav_rows))
        self._add('### Top tasks\n\n' + '\n'.join(f'{i + 1}. **{md_text(a)}** {md_text(b)}' for i, (a, b) in enumerate(top_tasks)))
        probs = [
            ('A link says it expired', f'Links in our emails work for 24 hours, once. Press {lib.B("Send me a new link")} on that page.'),
            ('"Error 1102" on a page', 'A short limit on our web host. Reload the page. You are still signed in.'),
            ('"That email and password do not match an account."', f'Check the address, or use {lib.B("Set a new password")} on the sign-in page.'),
        ] + list(extra_problems)
        self._add('### If something goes wrong\n\n| What you see | What to do |\n| --- | --- |\n' +
                  '\n'.join(f'| **{md_text(a)}** | {md_text(b)} |' for a, b in probs))
        self.sections.append(sec)
        self.cur = cur

    def export(self):
        out = []
        seen = set()
        for s in self.sections:
            slug = {'start': 'start-here', 'reference': 'quick-reference'}.get(s['kind']) or \
                re.sub(r'[^a-z0-9]+', '-', s['title'].lower()).strip('-')[:50]
            base, n = slug, 2
            while slug in seen:
                slug = f'{base}-{n}'
                n += 1
            seen.add(slug)
            out.append({'kind': s['kind'], 'slug': slug, 'title': s['title'], 'blurb': s['blurb'],
                        'body_md': '\n\n'.join(x for x in s['lines'] if x.strip()) + '\n'})
        return out


def export(key):
    lib.Guide = MdGuide
    mod = importlib.import_module(f'guides.{key}')
    importlib.reload(mod)
    mod.Guide = MdGuide
    g = mod.build()
    data = {'portal': key, 'title': g.title, 'promise': md_text(g.promise), 'signin_url': g.signin_url, 'lands_on': md_text(g.lands_on),
            'sections': g.export()}
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, f'{key}.json'), 'w') as f:
        json.dump(data, f, indent=1, ensure_ascii=False)
        f.write('\n')
    chars = sum(len(s['body_md']) for s in data['sections'])
    print(f'{key}: {len(data["sections"])} sections, {chars} characters')
    return data


if __name__ == '__main__':
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    used = set()
    for k in (args or KEYS):
        export(k)
    with open(os.path.join(OUT, 'images.json'), 'w') as f:
        json.dump(sorted(lib.USED_IMAGES), f, indent=1)
        f.write('\n')
    print(f'{len(lib.USED_IMAGES)} images used')
