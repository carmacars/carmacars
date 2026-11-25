'use client';
import { useEffect, useId, useRef, useState } from 'react';

// R50 hotfix (docs/changes/2026-11-25-r50-hotfix.md): the portal's top bar keeps only the essentials (the portal name, the
// bell, this menu and the main menu). Everything else that was on the bar (Profile, Academy, the assistant, What's new, the
// guide, Guide me, Report a bug, Sign out) is in this account menu: nothing is removed, only moved.
// The panel is hidden with visibility (never display: none), so a dialog one of its items opens (the assistant, What's new,
// Report a bug) still shows after the menu closes: core.css makes those dialogs visible again.
export function AccountMenu({ children, label = 'Account' }: { children: React.ReactNode; label?: string }) {
  const [open, setOpen] = useState(false);
  const box = useRef<HTMLDivElement>(null);
  const id = useId();
  useEffect(() => {
    if (!open) return;
    const away = (e: PointerEvent) => { if (box.current && !box.current.contains(e.target as Node)) setOpen(false); };
    const esc = (e: KeyboardEvent) => { if (e.key === 'Escape') { setOpen(false); box.current?.querySelector<HTMLButtonElement>('.hd-more__btn')?.focus(); } };
    document.addEventListener('pointerdown', away);
    document.addEventListener('keydown', esc);
    return () => { document.removeEventListener('pointerdown', away); document.removeEventListener('keydown', esc); };
  }, [open]);
  return (
    <div ref={box} className={`hd-more${open ? ' is-open' : ''}`} data-testid="account-menu">
      <button type="button" className="btn btn--quiet btn--sm hd-act hd-more__btn" aria-expanded={open} aria-controls={id} title={label}
        onClick={() => setOpen((v) => !v)} data-testid="account-menu-button">
        <svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><circle cx="12" cy="8" r="3.5" /><path d="M5 20c.6-3.6 3.2-5.5 7-5.5s6.4 1.9 7 5.5" /></svg>
        <span className="hd-lbl">{label}</span>
      </button>
      {/* an item's own click runs first; then the menu closes */}
      <div id={id} className="hd-more__panel" data-testid="account-menu-panel"
        onClick={(e) => { if ((e.target as Element).closest('a, button')) setOpen(false); }}>
        {children}
      </div>
    </div>
  );
}
