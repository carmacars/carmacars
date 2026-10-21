# Builds src/features/listing/presets/ghost-glyphs.json: the outlines of the capital letters, digits and a few signs
# of Inter Display ExtraBold (src/fonts/inter-display-800.woff2, the weight the sample cars' lettering asks for),
# flattened to polygons in font units, for the model-name lettering drawn behind real cars (lettering.ts).
#   python3 scripts/gen-ghost-glyphs.py   (fontTools; reading WOFF2 needs a brotli module)
import json, os
from fontTools.ttLib import TTFont
from fontTools.pens.recordingPen import RecordingPen

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
font = TTFont(os.path.join(ROOT, 'src', 'fonts', 'inter-display-800.woff2'))
cmap = font.getBestCmap(); gs = font.getGlyphSet(); hmtx = font['hmtx']
CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -&./'

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
            for i in range(1, 9):
                t = i / 8; u = 1 - t
                cur.append(q((u**3*p0[0] + 3*u*u*t*p1[0] + 3*u*t*t*p2[0] + t**3*p3[0], u**3*p0[1] + 3*u*u*t*p1[1] + 3*u*t*t*p2[1] + t**3*p3[1])))
            last = p3
        elif op == 'qCurveTo':
            pts = [last] + list(args)
            for a, b in zip(pts[1:], pts[2:]):
                cur.append(q(b)); last = b
        elif op in ('closePath', 'endPath'):
            if len(cur) > 1: contours.append(cur)
            cur = []
    return contours

out = {'unitsPerEm': font['head'].unitsPerEm, 'glyphs': {}}
for ch in CHARS:
    name = cmap[ord(ch)]
    pen = RecordingPen(); gs[name].draw(pen)
    out['glyphs'][ch] = {'advance': hmtx[name][0], 'contours': flatten(pen)}
with open(os.path.join(ROOT, 'src', 'features', 'listing', 'presets', 'ghost-glyphs.json'), 'w') as f:
    json.dump(out, f, separators=(',', ':'))
print('ghost-glyphs.json:', len(out['glyphs']), 'glyphs')
