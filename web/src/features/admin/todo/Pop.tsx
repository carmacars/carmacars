'use client';
import { useId, useRef, useState, type ReactNode } from 'react';

// A button and the small pop-up it opens (the same <dialog> as Act): for a pop-up whose content is a form of its own
// (record a payment, a paper signature, the document review). Esc or Close shuts it; the page refreshes behind it when
// the work is done, and the prompt that opened it is gone.
export function Pop({ label, title, children, variant = 'primary', testId, onOpen, wide }: {
  label: string; title: string; children: ReactNode; variant?: 'primary' | 'ghost'; testId?: string; onOpen?: () => void; wide?: boolean;
}) {
  const dlg = useRef<HTMLDialogElement>(null);
  const idp = useId().replace(/[^\w-]/g, '');
  const [open, setOpen] = useState(false);
  return (
    <>
      <button className={`btn btn--sm ${variant === 'primary' ? 'btn--primary' : 'btn--ghost'}`} type="button" aria-haspopup="dialog" data-testid={testId}
        onClick={() => { setOpen(true); dlg.current?.showModal(); onOpen?.(); }}>{label}</button>
      <dialog ref={dlg} className={`ad-dialog${wide ? ' gd-dialog--wide' : ''}`} aria-labelledby={`${idp}-t`} onClose={() => setOpen(false)} data-testid={testId ? `${testId}-dialog` : undefined}>
        <div className="gd-dialog__head">
          <h2 className="d4" id={`${idp}-t`}>{title}</h2>
          <button className="btn btn--quiet btn--sm" type="button" onClick={() => dlg.current?.close()} aria-label="Close">Close</button>
        </div>
        {open ? children : null}
      </dialog>
    </>
  );
}
