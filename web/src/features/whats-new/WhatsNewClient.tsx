'use client';
import { useEffect, useId, useRef } from 'react';
import { markReleaseSeen } from '@/server/actions/whats-new';
import { prettyDate } from '@/lib/whats-new';

// The menu link and the pop-up. The pop-up is a native modal dialog: the page behind is inert, Tab stays inside it, Esc closes
// it and focus goes back to where it was. It opens by itself once (autoOpen), and the person is marked as having seen it
// the moment it opens, so it never comes back by itself; the link opens it again at any time.
export function WhatsNewClient({ portal, release, date, summary, items, autoOpen, className }: {
  portal: string; release: string; date: string; summary: string; items: string[]; autoOpen: boolean; className: string;
}) {
  const ref = useRef<HTMLDialogElement>(null);
  const title = useId();
  const open = () => { const d = ref.current; if (d && !d.open) d.showModal(); };
  const close = () => ref.current?.close();

  useEffect(() => {
    if (!autoOpen) return;
    open();
    void markReleaseSeen(portal, release);
  }, [autoOpen, portal, release]);

  return (
    <>
      <button type="button" className={className} title="What's new" onClick={open} data-testid="whats-new-link">
        <svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M12 3l1.9 5.1L19 10l-5.1 1.9L12 17l-1.9-5.1L5 10l5.1-1.9z" /><path d="M19 16l.7 1.8L21.5 18.5l-1.8.7L19 21l-.7-1.8-1.8-.7 1.8-.7z" /></svg>
        <span className="hd-lbl">What&apos;s new</span>
      </button>
      <dialog
        ref={ref}
        className="wn"
        aria-labelledby={title}
        data-testid="whats-new"
        data-release={release}
        onClick={(e) => { if (e.target === ref.current) close(); }}
      >
        <div className="wn__card">
          <p className="wn__kicker small muted">{prettyDate(date)}</p>
          <h2 id={title} className="wn__title">What&apos;s new</h2>
          <p className="wn__summary">{summary}</p>
          <ul className="wn__list">{items.map((t, i) => <li key={i}>{t}</li>)}</ul>
          <div className="wn__actions"><button type="button" className="btn btn--primary" onClick={close} data-testid="whats-new-dismiss" autoFocus>Got it</button></div>
        </div>
      </dialog>
    </>
  );
}
