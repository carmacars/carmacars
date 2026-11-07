'use client';
import { useRef, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { staffDo } from '@/server/actions/staff-tools';
import { photoUrl } from '@/lib/photo';
import { moveItem } from './extra-order';

// Release 33 (0700): the extra photos ("More outside photos" and "Other detail") come after the standard shots on the
// car's page, in the order set here: drag a photo by its handle (mouse, finger or pen), or use Earlier and Later, then
// Save the order (app.listing_photos_order).
type P = { id: string; processed_path: string | null; original_path: string | null; original_url?: string | null; shot_label: string | null; shot_type: string; alt_text: string | null };

export function ExtraOrder({ vehicle, photos }: { vehicle: string; photos: P[] }) {
  const router = useRouter();
  const [order, setOrder] = useState(photos.map((p) => p.id));
  const [pending, start] = useTransition();
  const [res, setRes] = useState<{ ok: boolean; text: string } | null>(null);
  const list = useRef<HTMLOListElement>(null);
  const dragging = useRef<string | null>(null);
  const [held, setHeld] = useState<string | null>(null);
  const byId = new Map(photos.map((p) => [p.id, p]));
  const ids = order.filter((id) => byId.has(id)).concat(photos.map((p) => p.id).filter((id) => !order.includes(id)));
  const changed = ids.join() !== photos.map((p) => p.id).join();
  const at = (y: number) => {
    const items = Array.from(list.current?.querySelectorAll<HTMLElement>('[data-extra]') ?? []);
    const i = items.findIndex((el) => { const r = el.getBoundingClientRect(); return y < r.top + r.height / 2; });
    return i < 0 ? items.length - 1 : i;
  };
  const down = (id: string) => (e: React.PointerEvent) => { e.preventDefault(); (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId); dragging.current = id; setHeld(id); };
  const move = (e: React.PointerEvent) => {
    const id = dragging.current; if (!id) return;
    e.preventDefault();
    const to = at(e.clientY);
    setOrder((o) => { const cur = o.filter((x) => byId.has(x)); const from = cur.indexOf(id); return from === to ? o : moveItem(cur, from, to); });
  };
  const up = () => { dragging.current = null; setHeld(null); };
  const step = (id: string, by: number) => setOrder(() => { const from = ids.indexOf(id); return moveItem(ids, from, from + by); });
  const save = () => start(async () => {
    const r = await staffDo('listing_photos_order', { vehicle, order: ids });
    setRes(r.ok ? { ok: true, text: 'Order saved. The car page shows the extra photos in this order after the standard shots.' } : { ok: false, text: r.message });
    if (r.ok) router.refresh();
  });
  if (photos.length < 2) return null;
  return (
    <div className="lr-extras" data-testid="extra-order">
      <h3 className="d5">Extra photos, in their order on the car page</h3>
      <p className="small muted">They come after the standard shots. Drag a photo by its handle, or use Earlier and Later.</p>
      <ol className="lr-extras__list" ref={list} onPointerMove={move} onPointerUp={up} onPointerCancel={up}>
        {ids.map((id, n) => { const p = byId.get(id)!; const src = p.processed_path && p.processed_path !== p.original_path ? photoUrl(p.processed_path) : p.original_url ?? null; return (
          <li key={id} data-extra={id} className={`lr-extras__item${held === id ? ' is-held' : ''}`}>
            <span className="lr-extras__grip" role="button" tabIndex={-1} aria-hidden="true" onPointerDown={down(id)} title="Drag to move" data-testid={`extra-grip-${n}`}>⋮⋮</span>
            {/* eslint-disable-next-line @next/next/no-img-element -- pre-sized by the pipeline */}
            {src ? <img src={src} alt={p.alt_text ?? p.shot_label ?? p.shot_type} width={96} height={64} loading="lazy" draggable={false} /> : <span className="muted small">no file</span>}
            <span className="small">{n + 1}. {p.shot_label ?? p.shot_type}</span>
            <span className="row">
              <button type="button" className="btn btn--quiet btn--sm" disabled={n === 0} onClick={() => step(id, -1)}>Earlier<span className="vh"> (photo {n + 1})</span></button>
              <button type="button" className="btn btn--quiet btn--sm" disabled={n === ids.length - 1} onClick={() => step(id, 1)}>Later<span className="vh"> (photo {n + 1})</span></button>
            </span>
          </li>); })}
      </ol>
      <p className="row"><button type="button" className="btn btn--primary btn--sm" disabled={pending || !changed} onClick={save} data-testid="extra-order-save">{pending ? 'Saving' : 'Save the order'}</button></p>
      {res && <p className={`alert ${res.ok ? 'alert--ok' : 'alert--error'} small`} role={res.ok ? 'status' : 'alert'}><span>{res.text}</span></p>}
    </div>
  );
}
