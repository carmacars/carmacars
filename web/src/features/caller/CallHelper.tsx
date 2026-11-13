'use client';
import './caller.css';
import Link from '@/components/Link';
import { Fragment, useId, useState } from 'react';
import { faqSearch, greetingFor, helpParts, type CallHelp, type LiveCall, type Portal } from './model';

// The Call helper (r42, migration 2670), inside the caller pop-up, for someone new on the phone: what to say first
// (HelperGreeting: the greeting with their own first name and the caller's), then one big button per situation with its
// steps, and a search over the quick answers (HelperTools). The words are the Admin's (Settings > Call helper); the
// numbers in them come from the settings, filled in by the database. Hidden with one tap, remembered in this browser.

/** Words with their links (to the reader's own portal) and what to say out loud, in quotes, set apart. */
function Rich({ text, portal }: { text: string; portal: Portal }) {
  return <>{helpParts(portal, text).map((p, i) => p.href
    ? (p.outside
      ? <a key={i} className="link" href={p.href} target="_blank" rel="noreferrer noopener">{p.text}</a>
      : <Link key={i} prefetch={false} className="link" href={p.href}>{p.text}</Link>)
    : <Fragment key={i}>{p.text.split(/("[^"]+")/).map((s, j) => (/^"[^"]+"$/.test(s) ? <strong key={j} className="chelp-quote">{s}</strong> : s))}</Fragment>)}</>;
}

export function HelperGreeting({ c, help, hidden, onToggle, portal }: { c: LiveCall; help: CallHelp; hidden: boolean; onToggle: () => void; portal: Portal }) {
  return (
    <div className="chelp-top" data-testid="call-helper">
      <div className="chelp-bar">
        <h3 className="chelp-name">Call helper</h3>
        {help.can_edit && portal === 'admin' && <Link prefetch={false} className="link small" href="/admin/settings/call-helper">Edit</Link>}
        <button type="button" className="chelp-toggle" aria-expanded={!hidden} onClick={onToggle} data-testid="call-helper-toggle">{hidden ? 'Show' : 'Hide'}<span className="cpop-sr"> the call helper</span></button>
      </div>
      {!hidden && <p className="chelp-say" data-testid="call-greeting"><span className="chelp-say-k">Say</span>{greetingFor(c, help)}</p>}
    </div>
  );
}

export function HelperTools({ help, portal }: { help: CallHelp; portal: Portal }) {
  const [code, setCode] = useState<string | null>(null);
  const [q, setQ] = useState('');
  const id = useId();
  const sit = help.situations.find((s) => s.code === code) ?? null;
  const found = faqSearch(help.faq, q);
  const typed = q.trim().length > 1;
  return (
    <div className="chelp" data-testid="call-helper-tools">
      {sit ? (
        <div className="chelp-steps" data-testid="call-steps">
          <p className="chelp-steps-head">
            <button type="button" className="chelp-back" onClick={() => setCode(null)} data-testid="call-steps-back">
              <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><path d="M10 3 5 8l5 5" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" /></svg>All situations</button>
          </p>
          <h4 className="chelp-steps-title">{sit.title}</h4>
          <ol>{sit.steps.map((s, i) => <li key={i}><Rich text={s} portal={portal} /></li>)}</ol>
        </div>
      ) : help.situations.length > 0 ? (<>
        <p className="chelp-label" id={`${id}-sit`}>What is the call about?</p>
        <ul className="chelp-grid" aria-labelledby={`${id}-sit`}>{help.situations.map((s) => (
          <li key={s.code}><button type="button" className="chelp-sit" onClick={() => setCode(s.code)} data-testid={`call-sit-${s.code}`}>{s.title}</button></li>))}</ul>
      </>) : null}
      {help.faq.length > 0 && (
        <div className="chelp-faq">
          <label className="chelp-label" htmlFor={`${id}-q`}>Search the quick answers</label>
          <input id={`${id}-q`} type="search" className="input chelp-q" value={q} onChange={(e) => setQ(e.target.value)} placeholder="For example: deposit, late, cancel" autoComplete="off" enterKeyHint="search" data-testid="call-faq-search" />
          <p className="cpop-sr" role="status">{typed ? `${found.length} quick answer${found.length === 1 ? '' : 's'}` : ''}</p>
          {typed && (found.length ? (
            <ul className="chelp-answers" data-testid="call-faq-results">{found.map((f) => (
              <li key={f.code}><p className="chelp-q-title">{f.q}</p><p className="chelp-a"><Rich text={f.a} portal={portal} /></p></li>))}</ul>
          ) : <p className="small chelp-none" data-testid="call-faq-none">No quick answer for that. Try another word, or ask an Admin.</p>)}
        </div>)}
    </div>
  );
}
