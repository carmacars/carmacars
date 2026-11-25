'use client';
// Black toast with the red bar (prototype CC.toast), 4.5 seconds. r50: with Undo where the server can take the action
// back (opts.undo runs it; the toast closes).
export function toast(msg: string, ms = 4500, opts: { undo?: () => void; undoLabel?: string } = {}) {
  let box = document.querySelector<HTMLDivElement>('.toasts');
  if (!box) { box = document.createElement('div'); box.className = 'toasts'; box.setAttribute('role', 'status'); box.setAttribute('aria-live', 'polite'); document.body.appendChild(box); }
  const t = document.createElement('div'); t.className = 'toast'; t.style.setProperty('--toast-ms', `${ms}ms`);
  const span = document.createElement('span'); span.textContent = msg;
  const b = document.createElement('button'); b.type = 'button'; b.setAttribute('aria-label', 'Dismiss'); b.textContent = '×';
  t.append(span);
  if (opts.undo) { const u = document.createElement('button'); u.type = 'button'; u.className = 'toast__undo'; u.textContent = opts.undoLabel ?? 'Undo'; u.onclick = () => { kill(); opts.undo!(); }; t.append(u); }
  t.append(b);
  const kill = () => { t.classList.add('is-out'); setTimeout(() => t.remove(), 250); };
  b.onclick = kill; box.appendChild(t); setTimeout(kill, ms);
}
