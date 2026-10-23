"""The script hand of the Blind Spot rental agreement's box 21 (web/src/features/blindspot/script-glyphs.generated.ts).

Letter outlines derived from Dancing Script (SIL Open Font License 1.1, by The Dancing Script Project Authors), instanced
at weight 600, as SVG paths in font units (1000 to the em, y down, baseline at 0) with each letter's advance width. Only
the outlines are kept: no font file ships with the site, and the derived copy is not called by the Reserved Font Name.

  curl -sSLO https://raw.githubusercontent.com/google/fonts/main/ofl/dancingscript/DancingScript%5Bwght%5D.ttf
  python3 docs/forms/blindspot-script-glyphs.py DancingScript%5Bwght%5D.ttf > web/src/features/blindspot/script-glyphs.generated.ts

Needs fontTools (pip install fonttools).
"""
import json
import sys

from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz .'-"

f = instancer.instantiateVariableFont(TTFont(sys.argv[1]), {'wght': 600})
gs = f.getGlyphSet()
cmap = f.getBestCmap()
hmtx = f['hmtx']
out = {}
for ch in CHARS:
    g = cmap[ord(ch)]
    pen = SVGPathPen(gs, ntos=lambda v: str(int(round(v))))
    gs[g].draw(TransformPen(pen, (1, 0, 0, -1, 0, 0)))
    out[ch] = [hmtx[g][0], pen.getCommands()]
print('\n'.join([
    '// Generated from Dancing Script (SIL Open Font License 1.1; script-glyphs.LICENSE.txt), weight 600, by',
    '// docs/forms/blindspot-script-glyphs.py. The outline of each letter as an SVG path in font units (1000 to the em, y down,',
    '// baseline at 0) and its advance width. A derived copy: not the font itself, and not called by its Reserved Font Name.',
    'export const SCRIPT_GLYPHS: Record<string, [number, string]> = ' + json.dumps(out, separators=(',', ':')) + ';',
]))
