'use client';
// The admin portal's confirmation toast (admin portal design, October 25, 2026): after an action that closes its dialog,
// a short line in plain words says what happened ("Refund sent."), bottom centre, for about four seconds. It is a polite
// live region without the status role, so a page's own status lines stay the only ones a test or reader finds by role.
export function adminToast(msg: string, tone: 'ok' | 'error' = 'ok', ms = 4200) {
  // only inside the admin frame: the assistant portal shares the action button (Act) but not these styles
  if (typeof document === 'undefined' || !msg || !document.querySelector('[data-testid="admin-nav"]')) return;
  let box = document.querySelector<HTMLDivElement>('.ad-toasts');
  if (!box) {
    box = document.createElement('div');
    box.className = 'ad-toasts';
    box.setAttribute('aria-live', 'polite');
    box.setAttribute('aria-atomic', 'false');
    document.body.appendChild(box);
  }
  const t = document.createElement('div');
  t.className = `ad-toast ad-toast--${tone}`;
  const icon = document.createElement('span');
  icon.className = 'ad-toast__icon';
  icon.setAttribute('aria-hidden', 'true');
  const span = document.createElement('span');
  span.textContent = msg;
  const b = document.createElement('button');
  b.type = 'button';
  b.setAttribute('aria-label', 'Dismiss');
  b.textContent = '×';
  t.append(icon, span, b);
  const kill = () => { t.classList.add('is-out'); setTimeout(() => t.remove(), 220); };
  b.onclick = kill;
  box.appendChild(t);
  setTimeout(kill, ms);
}
