'use client';
import { useCallback, useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { photoUrl } from '@/lib/photo';
import { staffDo, staffRead } from '@/server/actions/staff-tools';
import { normalizePlateBoxes } from '@/features/tolls/vision-schema';
import { clampBox, exportCovered, forSave, fromCorners, inside, nearCorner, paint, type NBox, type PlateStyle } from './plate-cover';

// Cover the licence plate on one listing photo (migration 0042): the vision model suggests the box when it can;
// staff drag a box (or several) over each plate with a mouse or a finger, choose a CarmaCars plate, pixelation or
// blur, and save. The covered photo replaces the public one; the photo as it was is kept privately. Keyboard: Tab
// to the photo, N adds a box in the middle, the arrows move the chosen box, Shift and the arrows resize it,
// Delete removes it.
type Photo = { id: string; vehicle_id: string; shot_label: string | null; shot_type: string; processed_path: string | null; plate_status: string; plate_boxes: NBox[] | null; variants: Array<{ width: number }> | null };
type Ctx = { cover_text: string; default_style: PlateStyle; detect: boolean };

export function PlateEditor({ photo, onClose }: { photo: Photo; onClose: () => void }) {
  const router = useRouter();
  const canvas = useRef<HTMLCanvasElement>(null);
  const img = useRef<HTMLImageElement | null>(null);
  const drag = useRef<{ mode: 'new' | 'move' | 'size'; i: number; start: { x: number; y: number }; orig?: NBox } | null>(null);
  const [ctx, setCtx] = useState<Ctx | null>(null);
  const [boxes, setBoxes] = useState<NBox[]>(photo.plate_boxes ?? []);
  const [sel, setSel] = useState<number>(-1);
  const [style, setStyle] = useState<PlateStyle>('cover');
  const [ready, setReady] = useState(false);
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const font = typeof window !== 'undefined' ? getComputedStyle(document.body).fontFamily || 'Arial, sans-serif' : 'Arial, sans-serif';

  const draw = useCallback(() => {
    const c = canvas.current, i = img.current;
    if (!c || !i || !ctx) return;
    const g = c.getContext('2d')!;
    paint(g, i, c.width, c.height, boxes, style, ctx.cover_text, font);
    boxes.forEach((b, n) => {
      g.save(); g.lineWidth = 2; g.setLineDash(b.suggested ? [6, 4] : []); g.strokeStyle = n === sel ? '#d7141a' : '#ffffff';
      g.strokeRect(b.x * c.width, b.y * c.height, b.w * c.width, b.h * c.height);
      g.fillStyle = n === sel ? '#d7141a' : '#ffffff'; g.fillRect((b.x + b.w) * c.width - 6, (b.y + b.h) * c.height - 6, 12, 12);
      g.restore();
    });
  }, [boxes, style, sel, ctx, font]);

  useEffect(() => {
    let gone = false;
    void staffRead<Ctx>('photo_plate_context', { photo: photo.id }).then((r) => { if (gone) return; if (r.ok) { setCtx(r.data); setStyle(r.data.default_style); } else setErr(r.message); });
    if (!photo.processed_path) return () => { gone = true; };
    const i = new Image();
    i.onload = () => {
      if (gone || !canvas.current) return;
      img.current = i;
      const w = Math.min(960, canvas.current.parentElement?.clientWidth ?? 640);
      const ratio = (i.naturalHeight || 2) / (i.naturalWidth || 3);
      canvas.current.width = Math.round(w); canvas.current.height = Math.round(w * ratio);
      setReady(true);
    };
    i.onerror = () => setErr('The photo could not be opened.');
    i.src = photoUrl(photo.processed_path);
    return () => { gone = true; };
  }, [photo.id, photo.processed_path]);
  useEffect(() => { draw(); }, [draw, ready]);

  const suggest = useCallback(async () => {
    if (!img.current) return;
    setNote('Looking for the plate'); setErr(null);
    const c = document.createElement('canvas');
    const k = Math.min(1, 1024 / Math.max(img.current.naturalWidth || 1024, img.current.naturalHeight || 683));
    c.width = Math.round((img.current.naturalWidth || 1024) * k); c.height = Math.round((img.current.naturalHeight || 683) * k);
    c.getContext('2d')!.drawImage(img.current, 0, 0, c.width, c.height);
    const { askVision } = await import('@/features/tolls/pdf');
    const r = await askVision('plate_detect', c.toDataURL('image/jpeg', 0.85), { photo: photo.id, vehicle: photo.vehicle_id, width: c.width, height: c.height });
    if (!r.ok) { setNote(`No suggestion: ${r.message} Draw the box yourself.`); return; }
    const found = normalizePlateBoxes(r.data, { width: c.width, height: c.height });
    if (!found.length) { setNote('No plate was found. Draw a box over the plate, or mark the photo "no plate visible" if there is none.'); return; }
    setBoxes((b) => [...b, ...found.map((f) => ({ x: f.x, y: f.y, w: f.w, h: f.h, suggested: true }))]);
    setNote(`Suggested ${found.length} box${found.length > 1 ? 'es' : ''}. Check each covers the whole plate; move or resize it if not.`);
  }, [photo.id, photo.vehicle_id]);
  const asked = useRef(false);
  useEffect(() => { if (ready && ctx?.detect && !asked.current && !boxes.length && photo.plate_status === 'unchecked') { asked.current = true; void suggest(); } }, [ready, ctx, boxes.length, photo.plate_status, suggest]);

  const at = (e: React.PointerEvent<HTMLCanvasElement>) => { const r = e.currentTarget.getBoundingClientRect(); return { x: (e.clientX - r.left) / r.width, y: (e.clientY - r.top) / r.height }; };
  const down = (e: React.PointerEvent<HTMLCanvasElement>) => {
    e.preventDefault(); e.currentTarget.setPointerCapture(e.pointerId);
    const p = at(e);
    const hit = boxes.findIndex((b) => nearCorner(b, p)) >= 0 ? boxes.findIndex((b) => nearCorner(b, p)) : boxes.findIndex((b) => inside(b, p));
    if (hit >= 0) { setSel(hit); drag.current = { mode: nearCorner(boxes[hit]!, p) ? 'size' : 'move', i: hit, start: p, orig: boxes[hit] }; return; }
    setBoxes((b) => [...b, { x: p.x, y: p.y, w: 0.01, h: 0.01 }]); setSel(boxes.length);
    drag.current = { mode: 'new', i: boxes.length, start: p };
  };
  const move = (e: React.PointerEvent<HTMLCanvasElement>) => {
    const d = drag.current; if (!d) return;
    e.preventDefault();
    const p = at(e);
    setBoxes((bs) => bs.map((b, n) => {
      if (n !== d.i) return b;
      if (d.mode === 'new') return fromCorners(d.start, p);
      if (d.mode === 'move') return clampBox({ ...d.orig!, x: d.orig!.x + p.x - d.start.x, y: d.orig!.y + p.y - d.start.y });
      return clampBox({ ...d.orig!, w: d.orig!.w + p.x - d.start.x, h: d.orig!.h + p.y - d.start.y });
    }));
  };
  const up = () => {
    const d = drag.current; drag.current = null;
    // a tap without a drag is not a box
    if (d?.mode === 'new') setBoxes((bs) => bs.filter((b, n) => n !== d.i || (b.w > 0.015 && b.h > 0.01)));
    if (d) setBoxes((bs) => bs.map((b, n) => (n === d.i ? { x: b.x, y: b.y, w: b.w, h: b.h } : b)));
  };
  const key = (e: React.KeyboardEvent) => {
    const step = 0.01;
    if (e.key === 'n' || e.key === 'N') { e.preventDefault(); setBoxes((b) => [...b, { x: 0.42, y: 0.6, w: 0.16, h: 0.07 }]); setSel(boxes.length); return; }
    if (sel < 0 || !boxes[sel]) return;
    const b = boxes[sel]!;
    const map: Record<string, [number, number]> = { ArrowLeft: [-step, 0], ArrowRight: [step, 0], ArrowUp: [0, -step], ArrowDown: [0, step] };
    if (map[e.key]) { e.preventDefault(); const [dx, dy] = map[e.key]!; setBoxes((bs) => bs.map((x, n) => (n === sel ? clampBox(e.shiftKey ? { ...b, w: b.w + dx, h: b.h + dy } : { ...b, x: b.x + dx, y: b.y + dy }) : x))); }
    if (e.key === 'Delete' || e.key === 'Backspace') { e.preventDefault(); setBoxes((bs) => bs.filter((_, n) => n !== sel)); setSel(-1); }
  };

  const save = async () => {
    if (!img.current || !ctx || !boxes.length) return;
    setBusy(true); setErr(null);
    try {
      const out = await exportCovered(img.current, boxes, style, ctx.cover_text, (photo.variants ?? []).map((v) => v.width), font);
      const fd = new FormData();
      fd.set('photo', photo.id); fd.set('style', style); fd.set('boxes', JSON.stringify(forSave(boxes)));
      fd.set('width', String(out.width)); fd.set('height', String(out.height));
      fd.set('file', new File([out.main], 'covered.jpg', { type: 'image/jpeg' }));
      for (const v of out.variants) fd.set(`variant:${v.width}`, new File([v.blob], `covered-${v.width}.jpg`, { type: 'image/jpeg' }));
      const r = await fetch('/api/listing/plate', { method: 'POST', body: fd });
      const j = (await r.json().catch(() => ({ ok: false, message: 'The server did not answer.' }))) as { ok: boolean; message?: string };
      if (!j.ok) throw new Error(j.message ?? 'The photo could not be saved.');
      router.refresh(); onClose();
    } catch (e) { setErr(e instanceof Error ? e.message : 'The photo could not be saved.'); } finally { setBusy(false); }
  };
  const noPlate = async () => {
    setBusy(true); setErr(null);
    const r = await staffDo('photo_plate_record', { photo: photo.id, status: 'not_visible' });
    setBusy(false);
    if (!r.ok) { setErr(r.message); return; }
    router.refresh(); onClose();
  };

  return (
    <section className="pt-card ad-card pe" aria-labelledby={`pe-${photo.id}`} data-testid="plate-editor">
      <div className="pt-card__head"><h3 className="d4" id={`pe-${photo.id}`}>Plate on the {photo.shot_label ?? photo.shot_type.replace(/_/g, ' ')} photo</h3>
        <button type="button" className="btn btn--ghost btn--sm" onClick={onClose}>Close</button></div>
      {!photo.processed_path ? <p className="small muted">This photo is still being processed. Come back when it is ready.</p> : <>
        <p className="small muted" id={`pe-help-${photo.id}`}>Drag over each plate to put a box on it; drag a box to move it, or its corner to resize it. Keyboard: N adds a box, the arrows move it, Shift and the arrows resize it, Delete removes it.</p>
        <div className="pe__frame">
          <canvas ref={canvas} className="pe__canvas" tabIndex={0} role="img" aria-label={`The photo with ${boxes.length} box${boxes.length === 1 ? '' : 'es'} over the plate`} aria-describedby={`pe-help-${photo.id}`}
            onPointerDown={down} onPointerMove={move} onPointerUp={up} onPointerCancel={up} onKeyDown={key} data-testid="plate-canvas" />
        </div>
        <fieldset className="pe__styles"><legend className="label">Cover the plate with</legend>
          {([['cover', `A ${ctx?.cover_text ?? 'CarmaCars'} plate`], ['pixelate', 'Pixelation'], ['blur', 'Blur']] as Array<[PlateStyle, string]>).map(([k, t]) => (
            <label key={k} className="check"><input type="radio" name={`pe-style-${photo.id}`} value={k} checked={style === k} onChange={() => setStyle(k)} data-testid={`plate-style-${k}`} /> <span>{t}</span></label>))}
        </fieldset>
        {note && <p className="small" role="status" data-testid="plate-note">{note}</p>}
        <div className="row">
          <button type="button" className="btn btn--primary btn--sm" disabled={busy || !boxes.length || !ready} onClick={save} data-testid="plate-save">{busy ? 'Saving' : 'Save the covered photo'}</button>
          {ctx?.detect && <button type="button" className="btn btn--ghost btn--sm" disabled={busy || !ready} onClick={() => void suggest()} data-testid="plate-suggest">Suggest the plate</button>}
          <button type="button" className="btn btn--ghost btn--sm" disabled={busy || !boxes.length} onClick={() => { setBoxes([]); setSel(-1); }}>Clear the boxes</button>
          <button type="button" className="btn btn--ghost btn--sm" disabled={busy} onClick={noPlate} data-testid="plate-none">No plate visible on this photo</button>
        </div>
      </>}
      {err && <p className="alert alert--error" role="alert"><span>{err}</span></p>}
    </section>
  );
}
