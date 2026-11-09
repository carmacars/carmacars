// r35 S2: short moments of motion at the key steps of the flow (owner: "so the flow feels alive"). Each plays once, about
// a second, over the page and never blocks it (pointer-events: none, aria-hidden), and nothing plays under
// prefers-reduced-motion: reduce (the CSS in styles/motion.css draws nothing then, and playMoment returns early).
//   sent       the renter sent a request: a paper plane whooshes away with its trail
//   confirmed  the renter confirmed or paid: a check draws, confetti falls, the car keys drop in
//   offer      an offer is sent or accepted: a ring bursts around a check and an envelope flies off
//   pulse      staff or Admin receive a new request: a toast with a pulsing dot (the words say what came in)
// Pure DOM (no library), so a server page plays one with <Moment kind="..."/> and an action handler calls playMoment().
export type MomentKind = 'sent' | 'confirmed' | 'offer';
export const MOMENT_MS = 1150;

/** The confetti: deterministic pieces (no randomness: the same every time), spread across the top of the screen. */
export function confettiPieces(n = 22): Array<{ x: number; delay: number; rot: number; hue: 'red' | 'white' | 'grey'; drift: number }> {
  const hues = ['red', 'white', 'grey'] as const;
  return Array.from({ length: n }, (_, i) => ({ x: Math.round(((i * 37) % 100) * 10) / 10, delay: (i % 7) * 40, rot: (i * 53) % 360, hue: hues[i % 3]!, drift: ((i * 29) % 40) - 20 }));
}

const reduced = () => typeof window === 'undefined' || !window.matchMedia || window.matchMedia('(prefers-reduced-motion: reduce)').matches;

const SVG = {
  plane: '<svg viewBox="0 0 48 48" width="56" height="56"><path d="M4 22 44 4 34 44 22 30z" fill="#fff"/><path d="M22 30 44 4 16 26z" fill="#d9d9de"/><path d="M22 30v10l5-7z" fill="#b8b8bf"/></svg>',
  check: '<svg viewBox="0 0 64 64" width="72" height="72"><circle cx="32" cy="32" r="29" fill="#D0111B"/><path class="mo-check__tick" d="M19 33l9 9 18-20" fill="none" stroke="#fff" stroke-width="6" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  keys: '<svg viewBox="0 0 64 64" width="52" height="52"><circle cx="20" cy="20" r="11" fill="none" stroke="#fff" stroke-width="5"/><path d="M28 28l24 24M44 44l5-5M50 50l5-5" stroke="#fff" stroke-width="5" stroke-linecap="round"/><rect x="34" y="6" width="22" height="14" rx="5" fill="#D0111B"/></svg>',
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
    el.innerHTML = `<span class="mo-check">${SVG.check}</span><span class="mo-keys">${SVG.keys}</span>` +
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
