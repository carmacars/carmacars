# Builds src/features/listing/presets/plate-glyphs.json: the outlines of the letters of the CARMA plate (r35 S2): the
# plate characters in Inter Display Bold (src/fonts/inter-display-700.woff2), and "ONTARIO" and "Yours to discover" in
# Inter SemiBold (src/fonts/inter-600.woff2), flattened to polygons in font units, so the plate is drawn without a font
# (plate-art.ts: as SVG paths for the sample cars, rasterized for the photos).
#   python3 scripts/gen-plate-glyphs.py   (fontTools; reading WOFF2 needs a brotli module)
import json, os
from fontTools.ttLib import TTFont
from fontTools.pens.recordingPen import RecordingPen

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')

def flatten(rec):
    contours, cur, last = [], [], None
    def q(p): return [round(p[0]), round(p[1])]
    for op, args in rec.value:
        if op == 'moveTo':
            cur = [q(args[0])]; last = args[0]
        elif op == 'lineTo':
            cur.append(q(args[0])); last = args[0]
        elif op == 'curveTo':
            p0 = last; p1, p2, p3 = args
            for i in range(1, 7):
                t = i / 6; u = 1 - t
                cur.append(q((u**3*p0[0] + 3*u*u*t*p1[0] + 3*u*t*t*p2[0] + t**3*p3[0], u**3*p0[1] + 3*u*u*t*p1[1] + 3*u*t*t*p2[1] + t**3*p3[1])))
            last = p3
        elif op == 'qCurveTo':
            pts = [last] + list(args)
            ons = [pts[0]]
            for a, b in zip(pts[1:-1], pts[2:]):
                pass
            # implied on-curve points between consecutive off-curve points
            offs = list(args[:-1]); end = args[-1]; start = last
            segs = []
            for i, c in enumerate(offs):
                nxt = end if i == len(offs) - 1 else ((c[0] + offs[i + 1][0]) / 2, (c[1] + offs[i + 1][1]) / 2)
                segs.append((start, c, nxt)); start = nxt
            for a, c, b in segs:
                for i in range(1, 5):
                    t = i / 4; u = 1 - t
                    cur.append(q((u*u*a[0] + 2*u*t*c[0] + t*t*b[0], u*u*a[1] + 2*u*t*c[1] + t*t*b[1])))
            last = end
        elif op in ('closePath', 'endPath'):
            if len(cur) > 2: contours.append(cur)
            cur = []
    return contours

def glyphs(file, chars):
    font = TTFont(os.path.join(ROOT, 'src', 'fonts', file))
    cmap = font.getBestCmap(); gs = font.getGlyphSet(); hmtx = font['hmtx']
    out = {}
    for ch in chars:
        name = cmap[ord(ch)]; rec = RecordingPen(); gs[name].draw(rec)
        out[ch] = {'advance': hmtx[name][0], 'contours': flatten(rec)}
    return {'unitsPerEm': font['head'].unitsPerEm, 'capHeight': getattr(font['OS/2'], 'sCapHeight', 1490), 'glyphs': out}

data = {'plate': glyphs('inter-display-700.woff2', 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 '),
        'small': glyphs('inter-600.woff2', ''.join(sorted(set('ONTARIO Yours to discover'))))}
with open(os.path.join(ROOT, 'src', 'features', 'listing', 'presets', 'plate-glyphs.json'), 'w') as f:
    json.dump(data, f, separators=(',', ':'))
print('plate glyphs written')
