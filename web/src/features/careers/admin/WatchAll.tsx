'use client';
import { useRef, useState } from 'react';

// Watch all (release 30, migration 0585): every answer's video one after the other in one player, with the question it
// answers above it. Previous and Next jump between answers.
export function WatchAll({ items }: { items: Array<{ id: string; url: string; label: string; prompt: string }> }) {
  const [open, setOpen] = useState(false);
  const [i, setI] = useState(0);
  const ref = useRef<HTMLVideoElement>(null);
  const cur = items[i];
  const go = (n: number) => { setI(n); requestAnimationFrame(() => ref.current?.play().catch(() => undefined)); };
  if (!open) return <p><button type="button" className="btn btn--primary btn--sm" onClick={() => setOpen(true)} data-testid="cand-ai-watch-all">Watch all</button> <span className="small muted">{items.length} videos, one after the other</span></p>;
  if (!cur) return null;
  return (
    <div className="ai-watch" data-testid="cand-ai-watch">
      <p className="small muted">{cur.label} of {items.length} videos</p>
      <p className="ai-q">{cur.prompt}</p>
      <video key={cur.id} ref={ref} controls autoPlay playsInline src={cur.url} className="ai-video" aria-label={`${cur.label}: video`} data-testid="cand-ai-watch-video"
        onEnded={() => { if (i + 1 < items.length) go(i + 1); }} />
      <p className="row">
        <button type="button" className="btn btn--ghost btn--sm" disabled={i === 0} onClick={() => go(i - 1)}>Previous</button>
        <button type="button" className="btn btn--ghost btn--sm" disabled={i + 1 >= items.length} onClick={() => go(i + 1)} data-testid="cand-ai-watch-next">Next</button>
        <button type="button" className="btn btn--ghost btn--sm" onClick={() => setOpen(false)}>Close</button>
      </p>
    </div>);
}
