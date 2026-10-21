# python3 web/scripts/gen-addon-photos.py  (writes web/public/addon-photos; migration 0079 points the add-ons at them)
# Generates the add-on studio illustrations (web/public/addon-photos/<code>.svg), in the sample car images' style:
# a light studio backdrop, a floor, a soft shadow, the CarmaCars red line, the product in charcoal, white and red.
import os, sys
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "public", "addon-photos")
W = H = 800
RED = '#D0111B'; INK = '#26272a'; INK2 = '#4a4b4f'; GREY = '#a9b4bd'; LIGHT = '#e9e9ea'; WHITE = '#f7f7f7'

def frame(code, label, body, shadow_rx=230):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" role="img" aria-label="{label}">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#f7f7f7"/><stop offset="0.72" stop-color="#ececec"/><stop offset="1" stop-color="#dedede"/></linearGradient>
    <linearGradient id="paint" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{INK2}"/><stop offset="1" stop-color="{INK}"/></linearGradient>
    <linearGradient id="red" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#e2343d"/><stop offset="1" stop-color="#a80d16"/></linearGradient>
    <radialGradient id="shadow" cx="0.5" cy="0.5" r="0.5"><stop offset="0" stop-color="#000" stop-opacity="0.28"/><stop offset="1" stop-color="#000" stop-opacity="0"/></radialGradient>
  </defs>
  <rect width="{W}" height="{H}" fill="url(#bg)"/>
  <rect x="0" y="610" width="{W}" height="190" fill="#e2e2e3"/>
  <ellipse cx="400" cy="616" rx="{shadow_rx}" ry="22" fill="url(#shadow)"/>
  <rect x="60" y="640" width="680" height="5" fill="{RED}"/>
{body}
  <text x="740" y="740" font-family="Arial, Helvetica, sans-serif" font-size="30" font-weight="700" fill="#6b6c70" text-anchor="end">{label}</text>
</svg>
'''

ART = {}

ART['flowers'] = ('Flowers', f'''  <g>
    <path d="M330 600 L470 600 L540 360 L260 360 Z" fill="url(#paint)" stroke="{INK}" stroke-width="6" stroke-linejoin="round"/>
    <path d="M300 360 L400 600 L500 360" fill="none" stroke="#3a3b3f" stroke-width="5"/>
    <rect x="345" y="470" width="110" height="26" rx="6" fill="{RED}"/>
    <path d="M400 470 l-40 -30 M400 470 l40 -30" stroke="{RED}" stroke-width="10" stroke-linecap="round"/>
    <g stroke="#3a3b3f" stroke-width="6" stroke-linecap="round"><path d="M400 360 L400 250"/><path d="M370 360 L320 250"/><path d="M430 360 L480 250"/><path d="M350 360 L270 300"/><path d="M450 360 L530 300"/></g>
    <g fill="{GREY}"><ellipse cx="300" cy="320" rx="34" ry="14" transform="rotate(-30 300 320)"/><ellipse cx="500" cy="320" rx="34" ry="14" transform="rotate(30 500 320)"/><ellipse cx="370" cy="290" rx="28" ry="11" transform="rotate(-60 370 290)"/></g>
    <g>
      <circle cx="400" cy="230" r="56" fill="url(#red)"/><circle cx="400" cy="230" r="30" fill="#b10f18"/><circle cx="400" cy="230" r="12" fill="#7d0a10"/>
      <circle cx="310" cy="240" r="46" fill="{WHITE}" stroke="#d6d6d8" stroke-width="4"/><circle cx="310" cy="240" r="16" fill="#e2e2e3"/>
      <circle cx="490" cy="240" r="46" fill="{WHITE}" stroke="#d6d6d8" stroke-width="4"/><circle cx="490" cy="240" r="16" fill="#e2e2e3"/>
      <circle cx="262" cy="300" r="38" fill="url(#red)"/><circle cx="262" cy="300" r="14" fill="#7d0a10"/>
      <circle cx="538" cy="300" r="38" fill="url(#red)"/><circle cx="538" cy="300" r="14" fill="#7d0a10"/>
      <circle cx="355" cy="170" r="34" fill="{WHITE}" stroke="#d6d6d8" stroke-width="4"/><circle cx="445" cy="170" r="34" fill="{WHITE}" stroke="#d6d6d8" stroke-width="4"/>
    </g>
  </g>''', 170)

ART['baby_seat'] = ('Baby seat (rear-facing)', f'''  <g>
    <path d="M190 560 Q190 330 330 300 L560 300 Q620 300 620 360 L620 420 Q620 560 470 590 L230 590 Q190 590 190 560 Z" fill="url(#paint)" stroke="{INK}" stroke-width="8" stroke-linejoin="round"/>
    <path d="M250 540 Q250 380 350 360 L540 360 Q570 360 570 390 L570 430 Q570 530 450 545 Z" fill="#3a3b3f"/>
    <path d="M270 520 Q275 410 360 395 L520 395" fill="none" stroke="{GREY}" stroke-width="10" stroke-linecap="round"/>
    <path d="M200 470 Q400 70 610 400" fill="none" stroke="{INK}" stroke-width="30" stroke-linecap="round"/>
    <path d="M200 470 Q400 70 610 400" fill="none" stroke="{INK2}" stroke-width="14" stroke-linecap="round"/>
    <rect x="345" y="210" width="110" height="34" rx="16" fill="{RED}"/>
    <g stroke="{RED}" stroke-width="12" stroke-linecap="round" fill="none"><path d="M400 420 L400 520"/><path d="M350 430 L400 470 L450 430"/></g>
    <rect x="380" y="462" width="40" height="22" rx="5" fill="{LIGHT}"/>
    <path d="M200 595 Q400 625 600 595" fill="none" stroke="{INK}" stroke-width="14" stroke-linecap="round"/>
  </g>''', 240)

ART['child_seat'] = ('Child seat', f'''  <g>
    <path d="M260 600 L260 470 Q230 460 230 420 L240 200 Q245 150 300 140 L500 140 Q555 150 560 200 L570 420 Q570 460 540 470 L540 600 Z" fill="url(#paint)" stroke="{INK}" stroke-width="8" stroke-linejoin="round"/>
    <path d="M290 590 L290 230 Q295 195 330 190 L470 190 Q505 195 510 230 L510 590 Z" fill="#3a3b3f"/>
    <path d="M230 260 L180 280 L185 450 L240 440 Z" fill="{INK2}" stroke="{INK}" stroke-width="6" stroke-linejoin="round"/>
    <path d="M570 260 L620 280 L615 450 L560 440 Z" fill="{INK2}" stroke="{INK}" stroke-width="6" stroke-linejoin="round"/>
    <path d="M220 600 L580 600 L560 520 L240 520 Z" fill="{INK}"/>
    <g stroke="{RED}" stroke-width="16" stroke-linecap="round" fill="none"><path d="M350 250 L360 440 L400 500"/><path d="M450 250 L440 440 L400 500"/><path d="M400 500 L400 560"/></g>
    <rect x="378" y="420" width="44" height="34" rx="6" fill="{LIGHT}"/>
    <rect x="360" y="160" width="80" height="14" rx="7" fill="{GREY}"/>
  </g>''', 220)

ART['booster_seat'] = ('Booster seat', f'''  <g>
    <path d="M280 470 L300 250 Q305 210 345 205 L455 205 Q495 210 500 250 L520 470 Z" fill="url(#paint)" stroke="{INK}" stroke-width="8" stroke-linejoin="round"/>
    <path d="M318 460 L333 270 Q336 245 360 243 L440 243 Q464 245 467 270 L482 460 Z" fill="#3a3b3f"/>
    <rect x="360" y="215" width="80" height="12" rx="6" fill="{GREY}"/>
    <path d="M200 600 L600 600 L590 470 Q590 450 570 450 L230 450 Q210 450 210 470 Z" fill="url(#paint)" stroke="{INK}" stroke-width="8" stroke-linejoin="round"/>
    <rect x="200" y="420" width="90" height="60" rx="20" fill="{INK2}" stroke="{INK}" stroke-width="6"/>
    <rect x="510" y="420" width="90" height="60" rx="20" fill="{INK2}" stroke="{INK}" stroke-width="6"/>
    <rect x="230" y="438" width="40" height="10" rx="5" fill="{RED}"/>
    <rect x="530" y="438" width="40" height="10" rx="5" fill="{RED}"/>
    <rect x="270" y="500" width="260" height="14" rx="7" fill="{RED}"/>
  </g>''', 230)

ART['chauffeur'] = ('Chauffeur', f'''  <g>
    <circle cx="400" cy="440" r="160" fill="none" stroke="url(#paint)" stroke-width="34"/>
    <circle cx="400" cy="440" r="160" fill="none" stroke="{INK}" stroke-width="4"/>
    <circle cx="400" cy="440" r="48" fill="url(#paint)" stroke="{INK}" stroke-width="4"/>
    <circle cx="400" cy="440" r="18" fill="{RED}"/>
    <g stroke="url(#paint)" stroke-width="30" stroke-linecap="round"><path d="M352 452 L250 470"/><path d="M448 452 L550 470"/><path d="M400 488 L400 590"/></g>
    <path d="M250 200 Q400 110 550 200 L540 230 L260 230 Z" fill="url(#paint)" stroke="{INK}" stroke-width="6" stroke-linejoin="round"/>
    <rect x="262" y="226" width="276" height="26" fill="{RED}"/>
    <path d="M262 252 L538 252 Q520 300 400 300 Q280 300 262 252 Z" fill="{INK}"/>
    <circle cx="400" cy="185" r="14" fill="{LIGHT}" stroke="{GREY}" stroke-width="4"/>
  </g>''', 200)

ART['umbrella'] = ('Umbrella', f'''  <g>
    <path d="M150 330 Q400 40 650 330 Q608 300 566 330 Q524 300 483 330 Q441 300 400 330 Q358 300 316 330 Q274 300 233 330 Q191 300 150 330 Z" fill="url(#paint)" stroke="{INK}" stroke-width="6" stroke-linejoin="round"/>
    <path d="M400 110 Q340 200 316 330 Q358 300 400 330 Q441 300 483 330 Q460 200 400 110 Z" fill="url(#red)"/>
    <g stroke="#3a3b3f" stroke-width="4" fill="none"><path d="M400 110 Q250 200 233 330"/><path d="M400 110 Q550 200 566 330"/></g>
    <rect x="394" y="90" width="12" height="26" rx="4" fill="{INK}"/>
    <path d="M400 330 L400 560 Q400 600 440 600 Q480 600 480 560" fill="none" stroke="{INK}" stroke-width="16" stroke-linecap="round"/>
    <path d="M400 520 L400 560 Q400 600 440 600 Q480 600 480 560" fill="none" stroke="{RED}" stroke-width="16" stroke-linecap="round"/>
  </g>''', 200)

ART['phone_charger'] = ('Phone charger', f'''  <g>
    <rect x="470" y="190" width="180" height="350" rx="30" fill="url(#paint)" stroke="{INK}" stroke-width="6"/>
    <rect x="488" y="225" width="144" height="280" rx="10" fill="#3a3b3f"/>
    <rect x="530" y="203" width="60" height="10" rx="5" fill="{GREY}"/>
    <path d="M538 330 L568 330 L556 362 L582 362 L540 420 L552 380 L528 380 Z" fill="{RED}"/>
    <path d="M560 540 L560 580 Q560 610 520 610 L300 610 Q230 610 230 560 Q230 500 300 500 L380 500 Q440 500 440 440 Q440 380 380 380 L250 380 Q190 380 190 320 L190 270" fill="none" stroke="#6b6c70" stroke-width="18" stroke-linecap="round" stroke-linejoin="round"/>
    <path d="M560 540 L560 580 Q560 610 520 610 L300 610 Q230 610 230 560 Q230 500 300 500 L380 500 Q440 500 440 440 Q440 380 380 380 L250 380 Q190 380 190 320 L190 270" fill="none" stroke="#9a9ba0" stroke-width="6" stroke-linecap="round" stroke-linejoin="round"/>
    <rect x="168" y="200" width="44" height="76" rx="8" fill="{LIGHT}" stroke="{GREY}" stroke-width="4"/>
    <rect x="178" y="170" width="24" height="34" rx="10" fill="{INK}"/>
    <rect x="182" y="232" width="16" height="6" rx="3" fill="{RED}"/>
    <rect x="536" y="532" width="48" height="20" rx="6" fill="{LIGHT}" stroke="{GREY}" stroke-width="3"/>
  </g>''', 230)

ART['full_tank'] = ('Full tank of gas (prepaid)', f'''  <g>
    <path d="M150 470 A250 250 0 0 1 650 470" fill="none" stroke="url(#paint)" stroke-width="40" stroke-linecap="round"/>
    <path d="M520 255 A250 250 0 0 1 650 470" fill="none" stroke="{RED}" stroke-width="40" stroke-linecap="round"/>
    <g stroke="{INK}" stroke-width="8" stroke-linecap="round"><path d="M195 470 L225 470"/><path d="M575 470 L605 470"/><path d="M400 265 L400 295"/><path d="M255 325 L276 346"/><path d="M545 325 L524 346"/></g>
    <text x="215" y="545" font-family="Arial, Helvetica, sans-serif" font-size="48" font-weight="700" fill="{INK}">E</text>
    <text x="560" y="545" font-family="Arial, Helvetica, sans-serif" font-size="48" font-weight="700" fill="{RED}">F</text>
    <path d="M400 470 L585 395" stroke="{RED}" stroke-width="14" stroke-linecap="round"/>
    <circle cx="400" cy="470" r="34" fill="url(#paint)" stroke="{INK}" stroke-width="4"/>
    <g transform="translate(345 505)">
      <rect x="0" y="0" width="80" height="96" rx="10" fill="url(#paint)"/>
      <rect x="14" y="14" width="52" height="30" rx="4" fill="{LIGHT}"/>
      <path d="M80 30 L100 30 L100 80 Q100 92 110 92 Q120 92 120 80 L120 40 L108 22" fill="none" stroke="{INK}" stroke-width="8" stroke-linecap="round" stroke-linejoin="round"/>
    </g>
  </g>''', 230)

def tire():
    treads = ''.join(f'<rect x="392" y="146" width="16" height="44" rx="4" fill="#3a3b3f" transform="rotate({a} 400 400)"/>' for a in range(0, 360, 15))
    flake = ''.join(f'<g transform="rotate({a} 400 400)"><path d="M400 400 L400 330" /><path d="M400 352 L386 338 M400 352 L414 338"/></g>' for a in range(0, 360, 60))
    return f'''  <g transform="translate(0 -20)">
    <circle cx="400" cy="400" r="250" fill="url(#paint)" stroke="{INK}" stroke-width="8"/>
    {treads}
    <circle cx="400" cy="400" r="190" fill="{INK}"/>
    <circle cx="400" cy="400" r="150" fill="{LIGHT}"/>
    <circle cx="400" cy="400" r="138" fill="#c9cacc"/>
    <g stroke="{RED}" stroke-width="12" stroke-linecap="round" fill="none">{flake}</g>
    <circle cx="400" cy="400" r="22" fill="#7b7c80"/>
  </g>'''
ART['winter_tire'] = ('Winter tires', tire(), 250)

os.makedirs(OUT, exist_ok=True)
for code, (label, body, rx) in ART.items():
    with open(os.path.join(OUT, code + '.svg'), 'w') as f:
        f.write(frame(code, label, body, rx))
print(len(ART), 'written')
