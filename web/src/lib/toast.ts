'use client';
// Black toast with the red bar (prototype CC.toast), 4.5 seconds.
export function toast(msg: string, ms = 4500) {
  let box = document.querySelector<HTMLDivElement>('.toasts');
  if (!box) { box = document.createElement('div'); box.className = 'toasts'; box.setAttribute('role', 'status'); box.setAttribute('aria-live', 'polite'); document.body.appendChild(box); }
  const t = document.createElement('div'); t.className = 'toast'; t.style.setProperty('--toast-ms', `${ms}ms`);
  const span = document.createElement('span'); span.textContent = msg;
  const b = document.createElement('button'); b.type = 'button'; b.setAttribute('aria-label', 'Dismiss'); b.textContent = '×';
  t.append(span, b);
  const kill = () => { t.classList.add('is-out'); setTimeout(() => t.remove(), 250); };
  b.onclick = kill; box.appendChild(t); setTimeout(kill, ms);
}
