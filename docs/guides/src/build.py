"""Build the six CarmaCars portal guides.

python3 build.py            all guides
python3 build.py owner      one guide (renter, owner, admin, va, field, investor)
python3 build.py --html     HTML only, no PDF
"""
import importlib
import os
import subprocess
import sys
import tempfile

from pypdf import PdfReader, PdfWriter

import lib

HERE = lib.HERE
PDF_DIR = os.path.normpath(os.path.join(HERE, '..', 'pdf'))
KEYS = ['renter', 'owner', 'admin', 'va', 'field', 'investor']
NAMES = {'renter': 'Renter', 'owner': 'Owner', 'admin': 'Admin', 'va': 'VA', 'field': 'Field', 'investor': 'Investor'}
ENV = dict(os.environ, PLAYWRIGHT_BROWSERS_PATH='/opt/pw-browsers', NODE_PATH='/opt/node-tools/node_modules')


def load(key):
    mod = importlib.import_module(f'guides.{key}')
    return mod.build()


def write(path, text):
    with open(path, 'w') as f:
        f.write(text)


def node_print(page, out, mode, label=''):
    # ESM ignores NODE_PATH, so link node_modules beside the script once
    nm = os.path.join(HERE, 'node_modules')
    if not os.path.exists(nm):
        os.symlink('/opt/node-tools/node_modules', nm)
    subprocess.run(['node', os.path.join(HERE, 'print.mjs'), page, out, mode, label], check=True, env=ENV, cwd=HERE)


def outline_pages(pdf):
    r = PdfReader(pdf)
    found = {}

    def walk(items):
        for it in items:
            if isinstance(it, list):
                walk(it)
            else:
                t = ''.join(str(it.title).split())
                found.setdefault(t, r.get_destination_page_number(it) + 1)
    walk(r.outline)
    return found, len(r.pages)


def merge(cover, body, out, title):
    # the body's first page is a placeholder for the cover, so page numbers match the PDF's own
    w = PdfWriter()
    w.append(cover)
    w.append(body, pages=(1, len(PdfReader(body).pages)), import_outline=False)
    r = PdfReader(body)

    def walk(items, parent=None):
        last = None
        for it in items:
            if isinstance(it, list):
                walk(it, last)
            else:
                last = w.add_outline_item(' '.join(str(it.title).split()), r.get_destination_page_number(it), parent=parent)
    walk(r.outline)
    w.add_metadata({'/Title': f'CarmaCars {title}', '/Author': 'CarmaCars', '/Subject': f'CarmaCars {title}'})
    w.page_mode = '/UseOutlines'
    tmp = out + '.tmp'
    with open(tmp, 'wb') as f:
        w.write(f)
    # linearize and compress object streams
    subprocess.run(['qpdf', '--object-streams=generate', '--compress-streams=y', tmp, out], check=True)
    os.remove(tmp)


def build(key, pdf=True):
    g = load(key)
    html_path = os.path.join(HERE, f'{key}.html')
    cover_path = os.path.join(HERE, f'{key}-cover.html')
    write(cover_path, g.cover_doc())
    write(html_path, g.html_doc())
    for w in g.warnings:
        print('WARN', w)
    if not pdf:
        return
    label = g.title
    with tempfile.TemporaryDirectory() as tmp:
        body = os.path.join(tmp, 'body.pdf')
        node_print(html_path, body, 'body', label)
        pages, n = outline_pages(body)
        want = ['Start here', 'Quick reference'] + [t for _, t, _ in g.chapters]
        nk = lambda t: ''.join(t.split())
        pm = {t: pages.get(nk(t), '?') for t in want}
        missing = [t for t in want if nk(t) not in pages]
        if missing:
            print('WARN missing in outline', missing, list(pages)[:20])
        write(html_path, g.html_doc(pm))
        node_print(html_path, body, 'body', label)
        pages2, n2 = outline_pages(body)
        if any(pages2.get(nk(t)) != pm[t] for t in want if nk(t) in pages2):
            print('WARN page numbers moved on the second pass')
        cover = os.path.join(tmp, 'cover.pdf')
        node_print(cover_path, cover, 'cover')
        out = os.path.join(PDF_DIR, f'CarmaCars-{NAMES[key]}-Guide.pdf')
        merge(cover, body, out, g.title)
        print(f'{out}: {n2} pages, {os.path.getsize(out) / 1e6:.1f} MB')


if __name__ == '__main__':
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    pdf = '--html' not in sys.argv
    for k in (args or KEYS):
        build(k, pdf)
