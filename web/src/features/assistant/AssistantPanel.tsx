'use client';
import './assistant.css';
import Link from 'next/link';
import { useCallback, useEffect, useId, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import type { Out, Turn } from './agent';
import type { Portal } from './tools';

// The staff assistant's panel (migration 0080): opened from the portal header's "Assistant" button or Ctrl+/ (Cmd+/ on
// a Mac); Esc closes it. Answers come as cards: results with links, a question with choices, a draft to copy, and a
// change as a card with Confirm and Cancel. Nothing changes until Confirm.
type Item = { id: string; from: 'me' | 'assistant'; text?: string; out?: Out; decided?: { ok: boolean; text: string } };
let seq = 0;
const nid = () => `a${++seq}`;

const HINTS: Record<Portal, string[]> = {
  admin: ['What needs doing today?', 'Is the Corolla free from 2026-11-02 to 2026-11-04?', 'Record a $900 e-Transfer on INV-1053 dated 2026-10-15 ref CA12345'],
  va: ['What needs doing today?', 'Find booking R-000123', 'Create a task: call the renter back about the deposit'],
  field: ['What needs doing today?', 'Who has the Tesla?', 'Is the Corolla free from 2026-11-02 to 2026-11-04?']
};

export function AssistantPanel({ portal }: { portal: Portal }) {
  const router = useRouter();
  const dlg = useRef<HTMLDialogElement>(null);
  const input = useRef<HTMLTextAreaElement>(null);
  const end = useRef<HTMLDivElement>(null);
  const idp = useId().replace(/:/g, '');
  const [items, setItems] = useState<Item[]>([]);
  const [text, setText] = useState('');
  const [busy, setBusy] = useState(false);

  const open = useCallback(() => { const d = dlg.current; if (d && !d.open) { d.showModal(); setTimeout(() => input.current?.focus(), 0); } }, []);
  useEffect(() => {
    const k = (e: KeyboardEvent) => {
      if ((e.ctrlKey || e.metaKey) && !e.altKey && e.key === '/') { e.preventDefault(); const d = dlg.current; if (d?.open) d.close(); else open(); }
    };
    window.addEventListener('keydown', k);
    return () => window.removeEventListener('keydown', k);
  }, [open]);
  useEffect(() => { end.current?.scrollIntoView({ block: 'end' }); }, [items, busy]);

  const history = (): Turn[] => items.slice(-6).map((i) => ({ role: i.from === 'me' ? 'user' : 'assistant', text: i.text ?? describe(i.out) }));
  const post = async (body: Record<string, unknown>) => {
    const r = await fetch('/api/staff/assistant', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ portal, ...body }) });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(j.error ?? 'The assistant could not answer.');
    return j;
  };
  const send = async (q: string) => {
    const t = q.trim();
    if (!t || busy) return;
    const h = history();
    setItems((s) => [...s, { id: nid(), from: 'me', text: t }]);
    setText('');
    setBusy(true);
    try {
      const j = (await post({ text: t, history: h })) as { out?: Out[] };
      setItems((s) => [...s, ...(j.out ?? []).map((o) => ({ id: nid(), from: 'assistant' as const, out: o }))]);
    } catch (e) {
      setItems((s) => [...s, { id: nid(), from: 'assistant', out: { type: 'text', text: e instanceof Error ? e.message : 'The assistant could not answer.' } }]);
    } finally { setBusy(false); }
  };
  const decideCard = async (item: Item, confirm: boolean) => {
    if (item.out?.type !== 'proposal' || busy) return;
    setBusy(true);
    try {
      const j = (await post(confirm ? { confirm: item.out.id } : { cancel: item.out.id })) as { ok: boolean; text: string };
      setItems((s) => s.map((x) => (x.id === item.id ? { ...x, decided: { ok: j.ok, text: j.text } } : x)));
      if (j.ok && confirm) router.refresh();
    } catch (e) {
      setItems((s) => s.map((x) => (x.id === item.id ? { ...x, decided: { ok: false, text: e instanceof Error ? e.message : 'Not done.' } } : x)));
    } finally { setBusy(false); }
  };

  return (
    <>
      <button type="button" className="btn btn--quiet btn--sm as-open" onClick={open} aria-haspopup="dialog" aria-keyshortcuts="Control+/ Meta+/" data-testid="assistant-open"
        title="Assistant (Ctrl+/)">Assistant</button>
      <dialog ref={dlg} className="as-panel" aria-labelledby={`${idp}-t`} data-testid="assistant-panel">
        <header className="as-panel__head">
          <h2 className="d4" id={`${idp}-t`}>Assistant</h2>
          <span className="small muted as-panel__keys">Ctrl+/ opens and closes</span>
          <button type="button" className="btn btn--quiet btn--sm" onClick={() => dlg.current?.close()} data-testid="assistant-close">Close</button>
        </header>
        <div className="as-panel__log" role="log" aria-live="polite" aria-busy={busy} data-testid="assistant-log">
          {!items.length && (
            <div className="as-empty small">
              <p>Ask about today&apos;s work, bookings, cars, renters, owners and invoices. Changes come as a card for you to confirm; nothing runs until you do.</p>
              <ul className="as-hints">{HINTS[portal].map((h) => <li key={h}><button type="button" className="link" onClick={() => send(h)}>{h}</button></li>)}</ul>
            </div>)}
          {items.map((i) => (i.from === 'me'
            ? <p key={i.id} className="as-me" data-testid="assistant-me">{i.text}</p>
            : <Card key={i.id} item={i} onDecide={decideCard} onPick={send} busy={busy} />))}
          {busy && <p className="small muted as-wait" data-testid="assistant-busy">Working</p>}
          <div ref={end} />
        </div>
        <form className="as-panel__ask" onSubmit={(e) => { e.preventDefault(); void send(text); }}>
          <label className="vh" htmlFor={`${idp}-q`}>Ask the assistant</label>
          <textarea ref={input} id={`${idp}-q`} className="input as-input" rows={2} maxLength={1000} value={text} placeholder="Ask, or tell it what to do"
            onChange={(e) => setText(e.target.value)} onKeyDown={(e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); void send(text); } }} data-testid="assistant-input" />
          <button type="submit" className="btn btn--primary btn--sm" disabled={busy || !text.trim()} data-testid="assistant-send">Send</button>
        </form>
      </dialog>
    </>
  );
}

function describe(o?: Out): string {
  if (!o) return '';
  switch (o.type) {
    case 'text': case 'paused': return o.text;
    case 'results': return `${o.title}: ${o.rows.slice(0, 4).map((r) => r.title).join('; ')}`;
    case 'proposal': return `Proposed: ${o.summary}`;
    case 'question': return o.text;
    case 'draft': return `Draft to ${o.name}: ${o.text}`;
  }
}

function Card({ item, onDecide, onPick, busy }: { item: Item; onDecide: (i: Item, c: boolean) => void; onPick: (t: string) => void; busy: boolean }) {
  const o = item.out!;
  const [copied, setCopied] = useState(false);
  switch (o.type) {
    case 'text': return <p className="as-said" data-testid="assistant-text">{o.text}</p>;
    case 'paused': return <p className="alert alert--warn as-paused" role="status" data-testid="assistant-paused"><span>{o.text}</span></p>;
    case 'question': return (
      <div className="as-said" data-testid="assistant-question"><p>{o.text}</p>
        {o.options.length > 0 && <ul className="as-options">{o.options.map((x) => <li key={x}><button type="button" className="btn btn--ghost btn--sm" disabled={busy} onClick={() => onPick(x)}>{x}</button></li>)}</ul>}</div>);
    case 'results': return (
      <section className="as-card" data-testid="assistant-results"><h3 className="as-card__t">{o.title}</h3>
        {o.rows.length ? <ul className="as-rows">{o.rows.map((r, n) => <li key={n}>{r.href ? <Link prefetch={false} className="link" href={r.href}>{r.title}</Link> : <b>{r.title}</b>}{r.sub && <span className="small muted">{r.sub}</span>}</li>)}</ul>
          : <p className="small muted">{o.empty ?? 'Nothing found.'}</p>}</section>);
    case 'draft': return (
      <section className="as-card" data-testid="assistant-draft"><h3 className="as-card__t">Draft for {o.name} ({o.to})</h3>
        <p className="as-draft">{o.text}</p>
        <div className="row"><button type="button" className="btn btn--ghost btn--sm" onClick={() => { void navigator.clipboard?.writeText(o.text).then(() => setCopied(true)).catch(() => setCopied(false)); }}>{copied ? 'Copied' : 'Copy'}</button>
          <Link prefetch={false} className="link small" href={o.href}>Open to send it yourself</Link></div></section>);
    case 'proposal': return (
      <section className="as-card as-card--change" data-testid="assistant-proposal"><h3 className="as-card__t">Confirm this change</h3>
        <p data-testid="assistant-summary">{o.summary}</p>
        {item.decided
          ? <p className={`small ${item.decided.ok ? '' : 'ad-late'}`} role="status" data-testid="assistant-decided">{item.decided.text}</p>
          : <div className="row"><button type="button" className="btn btn--primary btn--sm" disabled={busy} onClick={() => onDecide(item, true)} data-testid="assistant-confirm">Confirm</button>
              <button type="button" className="btn btn--ghost btn--sm" disabled={busy} onClick={() => onDecide(item, false)} data-testid="assistant-cancel">Cancel</button></div>}
      </section>);
  }
}
