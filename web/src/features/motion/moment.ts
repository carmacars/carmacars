// r35 S2: short moments of motion at the key steps of the flow (owner: "so the flow feels alive"). Each plays once, about
// a second, over the page and never blocks it (pointer-events: none, aria-hidden), and nothing plays under
// prefers-reduced-motion: reduce (the CSS in styles/motion.css draws nothing then, and playMoment returns early).
//   sent       the renter sent a request: a paper plane whooshes away with its trail
//   confirmed  the renter confirmed or paid: a check draws, confetti falls, the car keys drop in
//   offer      an offer is sent or accepted: a ring bursts around a check and an envelope flies off
//   pulse      staff or Admin receive a new request: a toast with a pulsing dot (the words say what came in)
// r40 (the renter portal): the confirmed moment's car drives in under the check; signed (the agreement): a pen draws the
// signature line and the check pops; review (a review sent): a ring and stars burst out from the check; tier (a new
// Rewards tier): the ring and the check with the confetti.
// Pure DOM (no library), so a server page plays one with <Moment kind="..."/> and an action handler calls playMoment().
export type MomentKind = 'sent' | 'confirmed' | 'offer' | 'signed' | 'review' | 'tier';
export const MOMENT_MS = 1150;

/** The confetti: deterministic pieces (no randomness: the same every time), spread across the top of the screen. */
export function confettiPieces(n = 22): Array<{ x: number; delay: number; rot: number; hue: 'red' | 'white' | 'grey'; drift: number }> {
  const hues = ['red', 'white', 'grey'] as const;
  return Array.from({ length: n }, (_, i) => ({ x: Math.round(((i * 37) % 100) * 10) / 10, delay: (i % 7) * 40, rot: (i * 53) % 360, hue: hues[i % 3]!, drift: ((i * 29) % 40) - 20 }));
}

/** The review's stars: evenly round the check, deterministic like the confetti. */
export function burstPieces(n = 8): Array<{ angle: number; delay: number }> {
  return Array.from({ length: n }, (_, i) => ({ angle: Math.round((360 / n) * i), delay: (i % 4) * 30 }));
}

const reduced = () => typeof window === 'undefined' || !window.matchMedia || window.matchMedia('(prefers-reduced-motion: reduce)').matches;

const SVG = {
  plane: '<svg viewBox="0 0 48 48" width="56" height="56"><path d="M4 22 44 4 34 44 22 30z" fill="#fff"/><path d="M22 30 44 4 16 26z" fill="#d9d9de"/><path d="M22 30v10l5-7z" fill="#b8b8bf"/></svg>',
  check: '<svg viewBox="0 0 64 64" width="72" height="72"><circle cx="32" cy="32" r="29" fill="#D0111B"/><path class="mo-check__tick" d="M19 33l9 9 18-20" fill="none" stroke="#fff" stroke-width="6" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  keys: '<svg viewBox="0 0 64 64" width="52" height="52"><circle cx="20" cy="20" r="11" fill="none" stroke="#fff" stroke-width="5"/><path d="M28 28l24 24M44 44l5-5M50 50l5-5" stroke="#fff" stroke-width="5" stroke-linecap="round"/><rect x="34" y="6" width="22" height="14" rx="5" fill="#D0111B"/></svg>',
  car: '<svg viewBox="0 0 96 40" width="112" height="47"><path d="M8 28c0-5 3-8 9-9l12-9c3-2 6-3 10-3h18c4 0 7 1 10 4l9 8c8 1 12 4 12 9v4H8z" fill="#fff"/><path d="M33 12l-8 7h22V10H39c-2 0-4 1-6 2zm18-2v9h20l-7-6c-2-2-4-3-7-3z" fill="#c9cad0"/><circle cx="26" cy="32" r="7" fill="#111114" stroke="#fff" stroke-width="3"/><circle cx="72" cy="32" r="7" fill="#111114" stroke="#fff" stroke-width="3"/><rect x="84" y="22" width="6" height="3" rx="1.5" fill="#D0111B"/></svg>',
  pen: '<svg viewBox="0 0 160 48" width="180" height="54"><path class="mo-sign__line" d="M6 34c12-18 20-22 24-12s-6 14 2 10 14-22 20-14-4 16 6 10 12-14 20-10 4 12 14 8 16-8 24-6 12 4 30 0" fill="none" stroke="#fff" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  star: '<svg viewBox="0 0 24 24" width="22" height="22"><path d="M12 2l2.9 6.6 7.1.6-5.4 4.7 1.6 7-6.2-3.7-6.2 3.7 1.6-7L2 9.2l7.1-.6z" fill="#D0111B"/></svg>',
  mail: '<svg viewBox="0 0 48 48" width="40" height="40"><rect x="4" y="10" width="40" height="28" rx="4" fill="#fff"/><path d="M6 13l18 14 18-14" fill="none" stroke="#D0111B" stroke-width="3"/></svg>'
};

/** Play a moment over the page (once; removed after it ends). */
export function playMoment(kind: MomentKind): void {
  if (typeof document === 'undefined' || reduced()) return;
  const el = document.createElement('div');
  el.className = `mo mo--${kind}`;
  el.setAttribute('aria-hidden', 'true');
  if (kind === 'sent') el.innerHTML = `<span class="mo-trail"></span><span class="mo-plane">${SVG.plane}</span>`;
  if (kind === 'confirmed') {
    el.innerHTML = `<span class="mo-check">${SVG.check}</span><span class="mo-keys">${SVG.keys}</span><span class="mo-car">${SVG.car}</span>` +
      confettiPieces().map((p) => `<i class="mo-bit mo-bit--${p.hue}" style="--x:${p.x}%;--d:${p.delay}ms;--r:${p.rot}deg;--dx:${p.drift}vw"></i>`).join('');
  }
  if (kind === 'signed') el.innerHTML = `<span class="mo-sign">${SVG.pen}</span><span class="mo-check">${SVG.check}</span>`;
  if (kind === 'review') {
    el.innerHTML = `<span class="mo-ring"></span><span class="mo-check">${SVG.check}</span>` +
      burstPieces().map((p) => `<span class="mo-star" style="--a:${p.angle}deg;--d:${p.delay}ms">${SVG.star}</span>`).join('');
  }
  // r40 (2421): a new Rewards tier: the ring bursts round the check and the confetti falls
  if (kind === 'tier') {
    el.innerHTML = `<span class="mo-ring"></span><span class="mo-check">${SVG.check}</span>` +
      confettiPieces().map((p) => `<i class="mo-bit mo-bit--${p.hue}" style="--x:${p.x}%;--d:${p.delay}ms;--r:${p.rot}deg;--dx:${p.drift}vw"></i>`).join('');
  }
  if (kind === 'offer') el.innerHTML = `<span class="mo-ring"></span><span class="mo-check">${SVG.check}</span><span class="mo-mail">${SVG.mail}</span>`;
  document.body.appendChild(el);
  setTimeout(() => el.remove(), MOMENT_MS + 150);
}

/** Staff and Admin: a new request came in. A toast with a pulsing dot, its words and a link; gone after a few seconds. */
export function pulseToast(title: string, href: string | null): void {
  if (typeof document === 'undefined' || !title) return;
  let box = document.querySelector<HTMLDivElement>('.mo-toasts');
  if (!box) {
    box = document.createElement('div');
    box.className = 'mo-toasts';
    box.setAttribute('aria-live', 'polite');
    document.body.appendChild(box);
  }
  const t = document.createElement(href ? 'a' : 'div');
  t.className = 'mo-toast';
  if (href) (t as HTMLAnchorElement).href = href;
  const dot = document.createElement('span');
  dot.className = 'mo-toast__dot';
  dot.setAttribute('aria-hidden', 'true');
  const span = document.createElement('span');
  span.textContent = title;
  t.append(dot, span);
  box.appendChild(t);
  setTimeout(() => { t.classList.add('is-out'); setTimeout(() => t.remove(), 250); }, 6000);
}
