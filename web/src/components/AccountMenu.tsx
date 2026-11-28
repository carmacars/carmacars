'use client';
import { useEffect, useId, useRef, useState } from 'react';

// R50 hotfix (docs/changes/2026-11-25-r50-hotfix.md): the portal's top bar keeps only the essentials (the portal name, the
// bell, this menu and the main menu). Everything else that was on the bar (Profile, Academy, the assistant, What's new, the
// guide, Guide me, Report a bug, Sign out) is in this account menu: nothing is removed, only moved.
// The closed panel is hidden with visibility (never display: none), so a dialog one of its items opens (the assistant,
// What's new, Report a bug) still shows, and takes clicks, after the menu closes (core.css).
// Keyboard: the button says it opens a menu; opening moves focus to the first item; Escape closes and returns focus to the
// button, except while an item's dialog is open (Escape is the dialog's); focus leaving the menu closes it.
const ITEMS = 'a[href], button:not([disabled]), [tabindex]:not([tabindex="-1"])';
const dialogOpen = () => !!document.querySelector('dialog[open], [role="dialog"][aria-modal="true"]');

export function AccountMenu({ children, label = 'Account' }: { children: React.ReactNode; label?: string }) {
  const [open, setOpen] = useState(false);
  const box = useRef<HTMLDivElement>(null);
  const btn = useRef<HTMLButtonElement>(null);
  const panel = useRef<HTMLDivElement>(null);
  const id = useId();
  const close = (focusButton: boolean) => { setOpen(false); if (focusButton) btn.current?.focus(); };

  useEffect(() => {
    if (!open) return;
    panel.current?.querySelector<HTMLElement>(ITEMS)?.focus();
    const away = (e: PointerEvent) => { if (box.current && !box.current.contains(e.target as Node)) setOpen(false); };
    const esc = (e: KeyboardEvent) => { if (e.key === 'Escape' && !dialogOpen()) { setOpen(false); btn.current?.focus(); } };
    document.addEventListener('pointerdown', away);
    document.addEventListener('keydown', esc);
    return () => { document.removeEventListener('pointerdown', away); document.removeEventListener('keydown', esc); };
  }, [open]);

  return (
    <div ref={box} className={`hd-more${open ? ' is-open' : ''}`} data-testid="account-menu"
      onBlur={(e) => { if (open && !(e.relatedTarget && box.current?.contains(e.relatedTarget as Node))) setOpen(false); }}>
      <button ref={btn} type="button" className="btn btn--quiet btn--sm hd-act hd-more__btn" aria-haspopup="true" aria-expanded={open} aria-controls={id} title={label}
        onClick={() => setOpen((v) => !v)} data-testid="account-menu-button">
        <svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><circle cx="12" cy="8" r="3.5" /><path d="M5 20c.6-3.6 3.2-5.5 7-5.5s6.4 1.9 7 5.5" /></svg>
        <span className="hd-lbl">{label}</span>
      </button>
      {/* an item's own click runs first (a dialog it opens is modal: the button behind it cannot take focus); then the menu closes */}
      <div ref={panel} id={id} className="hd-more__panel" data-testid="account-menu-panel"
        onClick={(e) => {
          const t = e.target as Element;
          // an item that opens its own list inside the panel (Guide me) keeps the menu open: a closed panel is 0 by 0 and clips it
          if (t.closest('button[aria-haspopup="true"][aria-expanded]')) return;
          if (t.closest('a, button') && !t.closest('dialog')) close(!dialogOpen());
        }}>
        {children}
      </div>
    </div>
  );
}
