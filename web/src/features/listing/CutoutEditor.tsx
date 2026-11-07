'use client';
import { useCallback, useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { alphaOf, compose, masksDiffer, NO_ADJUST, sameAdjust, stroke, studioPlan, type Brush } from './cutout-edit';
import { LETTERING, letterThis, letteringMask } from './lettering';
import { adjustPlace, type Adjust } from './subject-frame';

// The cut-out editor of one outside listing photo (release 33, migration 0700). Two views: "Cut-out", the car over the
// photo as taken (shown faint), where a brush erases what is left of the background or restores what the automatic
// cut-out took off (a mirror, the roof, a wheel); "On the studio", the car on the studio background with the model's
// name behind it (as the worker draws it), dragged to move it, the slider to size it. Reset goes back to the automatic
// cut-out; Save has the photo made again from the edit (the version before is kept; the plate check carries over when the
// car did not move). Mouse, finger or pen (pointer events); keyboard on the studio view: the arrows move, + and - size.
type Ctx = { id: string; vehicle_id: string; shot_type: string; shot_label: string | null; rebackground: boolean; is_cover: boolean; model: string | null;
  auto_mask: string | null; mask: string | null; adjust: Adjust | null; plate_status: string; pending: boolean; mask_pending: boolean; versions: number };
const src = (photo: string, part: string) => `/api/listing/cutout?photo=${encodeURIComponent(photo)}&part=${part}&t=${Date.now()}`;
const FW = 1800, FH = 1200;

function load(url: string): Promise<HTMLImageElement> {
  return new Promise((res, rej) => { const i = new Image(); i.onload = () => res(i); i.onerror = () => rej(new Error('The photo could not be opened.')); i.src = url; });
}
function pixels(img: CanvasImageSource, w: number, h: number): Uint8ClampedArray {
  const c = document.createElement('canvas'); c.width = w; c.height = h;
  const g = c.getContext('2d', { willReadFrequently: true })!; g.drawImage(img, 0, 0, w, h);
  return g.getImageData(0, 0, w, h).data;
}

export function CutoutEditor({ photo, onClose }: { photo: { id: string; shot_label: string | null; shot_type: string }; onClose: () => void }) {
  const router = useRouter();
  const [ctx, setCtx] = useState<Ctx | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const [ready, setReady] = useState(false);
  const [view, setView] = useState<'cut' | 'studio'>('cut');
  const [tool, setTool] = useState<Brush | 'pan'>('erase');
  const [size, setSize] = useState(24);
  const [zoom, setZoom] = useState(1);
  const [adjust, setAdjust] = useState<Adjust>(NO_ADJUST);
  const [busy, setBusy] = useState(false);
  const [dirty, setDirty] = useState(0);
  const [maskChanged, setMaskChanged] = useState(false);
  const [canUndo, setCanUndo] = useState(false);
  const [startAdjust, setStartAdjust] = useState<Adjust>(NO_ADJUST);
  const cutCanvas = useRef<HTMLCanvasElement>(null);
  const studioCanvas = useRef<HTMLCanvasElement>(null);
  // the working state: the mask's size, the original at that size, the mask now, the one loaded, the automatic one
  const work = useRef<{ W: number; H: number; orig: Uint8ClampedArray; mask: Uint8ClampedArray; loaded: Uint8ClampedArray; auto: Uint8ClampedArray | null;
    faint: HTMLCanvasElement; car: HTMLCanvasElement; carData: ImageData; backdrop: HTMLImageElement; band: HTMLCanvasElement | null } | null>(null);
  const undo = useRef<Uint8ClampedArray[]>([]);
  const plan = useRef<ReturnType<typeof studioPlan> | null>(null);
  const planCanvas = useRef<HTMLCanvasElement | null>(null);

  const info = useCallback(async () => {
    const r = await fetch(src(photo.id, 'info')).catch(() => null);
    const j = (r ? await r.json().catch(() => null) : null) as { ok: boolean; data?: Ctx; message?: string } | null;
    if (!j?.ok || !j.data) { setErr(j?.message ?? 'The photo could not be opened.'); return null; }
    setCtx(j.data); return j.data;
  }, [photo.id]);

  const open = useCallback(async (c: Ctx) => {
    try {
      const [orig, maskImg, backdrop, autoImg] = await Promise.all([load(src(c.id, 'original')), load(src(c.id, 'mask')), load(src(c.id, 'backdrop')),
        c.mask ? load(src(c.id, 'automask')).catch(() => null) : Promise.resolve(null)]);
      const W = maskImg.naturalWidth, H = maskImg.naturalHeight;
      const mask = alphaOf({ width: W, height: H, data: pixels(maskImg, W, H) });
      const o = pixels(orig, W, H);
      const auto = autoImg ? alphaOf({ width: W, height: H, data: pixels(autoImg, W, H) }) : null;
      const faint = document.createElement('canvas'); faint.width = W; faint.height = H;
      faint.getContext('2d')!.drawImage(orig, 0, 0, W, H);
      const car = document.createElement('canvas'); car.width = W; car.height = H;
      const g = car.getContext('2d')!;
      const carData = g.createImageData(W, H);
      compose(o, mask, W, H, carData.data);
      g.putImageData(carData, 0, 0);
      let band: HTMLCanvasElement | null = null;
      if (c.model && letterThis({ rebackground: c.rebackground, shot_type: c.shot_type, is_cover: c.is_cover })) {
        const m = letteringMask(c.model);
        band = document.createElement('canvas'); band.width = LETTERING.width; band.height = LETTERING.height;
        const bg = band.getContext('2d')!, bd = bg.createImageData(LETTERING.width, LETTERING.height);
        for (let i = 0; i < m.length; i++) if (m[i]) { const p = i * 4; bd.data[p] = 255; bd.data[p + 1] = 255; bd.data[p + 2] = 255; bd.data[p + 3] = Math.round(255 * 0.13 * m[i]!); }
        bg.putImageData(bd, 0, 0);
      }
      const start = c.adjust ? { dx: Number(c.adjust.dx) || 0, dy: Number(c.adjust.dy) || 0, scale: Number(c.adjust.scale) || 1 } : NO_ADJUST;
      work.current = { W, H, orig: o, mask, loaded: mask.slice(), auto: auto ?? (c.mask ? null : mask.slice()), faint, car, carData, backdrop, band };
      setAdjust(start); setStartAdjust(start); plan.current = null; undo.current = []; setCanUndo(false); setMaskChanged(false);
      setReady(true); setDirty((n) => n + 1);
    } catch (e) { setErr(e instanceof Error ? e.message : 'The photo could not be opened.'); }
  }, []);

  useEffect(() => {
    let gone = false;
    void fetch(src(photo.id, 'info')).then((r) => r.json()).then((j: { ok: boolean; data?: Ctx; message?: string }) => {
      if (gone) return;
      if (!j?.ok || !j.data) { setErr(j?.message ?? 'The photo could not be opened.'); return; }
      setCtx(j.data);
      if (j.data.mask || j.data.auto_mask) void open(j.data);
    }).catch(() => { if (!gone) setErr('The photo could not be opened.'); });
    return () => { gone = true; };
  }, [photo.id, open]);
  // a mask asked for: looked for again every 5 seconds until the worker has made it
  useEffect(() => {
    if (!ctx || ready || ctx.auto_mask || ctx.mask || !ctx.mask_pending) return;
    const t = setInterval(() => { void info().then((c) => { if (c && (c.auto_mask || c.mask)) { clearInterval(t); setNote(null); void open(c); } }); }, 5000);
    return () => clearInterval(t);
  }, [ctx, ready, info, open]);
  const askMask = async () => {
    setBusy(true); setErr(null);
    const fd = new FormData(); fd.set('photo', photo.id); fd.set('action', 'mask');
    const r = await fetch('/api/listing/cutout', { method: 'POST', body: fd }).catch(() => null);
    const j = (r ? await r.json().catch(() => null) : null) as { ok: boolean; message?: string } | null;
    setBusy(false);
    if (!j?.ok) { setErr(j?.message ?? 'The mask could not be asked for.'); return; }
    setNote('Making the cut-out. This takes about a minute; the editor opens by itself.');
    await info();
  };

  // ---------------------------------------------------------------- drawing
  const drawCut = useCallback(() => {
    const c = cutCanvas.current, w = work.current;
    if (!c || !w) return;
    const box = c.parentElement?.clientWidth ?? 640;
    const dw = Math.round(Math.min(1400, box) * zoom), dh = Math.round((dw * w.H) / w.W);
    if (c.width !== dw || c.height !== dh) { c.width = dw; c.height = dh; }
    const g = c.getContext('2d')!;
    // a checker shows what is clear; the photo as taken, faint, shows what Restore brings back
    g.fillStyle = '#3a3a3a'; g.fillRect(0, 0, dw, dh);
    g.fillStyle = '#2a2a2a';
    const k = 16; for (let y = 0; y < dh; y += k) for (let x = ((y / k) % 2) * k; x < dw; x += 2 * k) g.fillRect(x, y, k, k);
    g.globalAlpha = 0.28; g.drawImage(w.faint, 0, 0, dw, dh); g.globalAlpha = 1;
    g.drawImage(w.car, 0, 0, dw, dh);
  }, [zoom]);

  const drawStudio = useCallback(() => {
    const c = studioCanvas.current, w = work.current;
    if (!c || !w) return;
    const dw = Math.round(Math.min(1400, c.parentElement?.clientWidth ?? 640)), dh = Math.round((dw * FH) / FW);
    if (c.width !== dw || c.height !== dh) { c.width = dw; c.height = dh; }
    const g = c.getContext('2d')!, s = dw / FW;
    g.drawImage(w.backdrop, 0, 0, dw, dh);
    if (w.band) g.drawImage(w.band, 0, LETTERING.top * s, LETTERING.width * s, LETTERING.height * s);
    if (!plan.current) {
      const p = studioPlan({ width: w.W, height: w.H, data: w.carData.data }, null);
      plan.current = p;
      if (p) {
        const pc = document.createElement('canvas'); pc.width = p.framed.width; pc.height = p.framed.height;
        pc.getContext('2d')!.putImageData(new ImageData(p.framed.data as Uint8ClampedArray<ArrayBuffer>, p.framed.width, p.framed.height), 0, 0);
        planCanvas.current = pc;
      }
    }
    const p = plan.current;
    if (!p || !planCanvas.current) { g.fillStyle = '#fff'; g.font = `${Math.max(12, 18 * s * 2)}px sans-serif`; g.fillText('No car left in the cut-out', 16, 32); return; }
    const pl = adjustPlace(p.base, adjust, FW, FH);
    g.drawImage(planCanvas.current, pl.left * s, (FH - pl.bottom - pl.height) * s, pl.width * s, pl.height * s);
  }, [adjust]);

  useEffect(() => { if (ready) { if (view === 'cut') drawCut(); else drawStudio(); } }, [ready, view, dirty, drawCut, drawStudio]);
  useEffect(() => {
    const f = () => setDirty((n) => n + 1);
    window.addEventListener('resize', f); return () => window.removeEventListener('resize', f);
  }, []);

  // ---------------------------------------------------------------- the brush
  const last = useRef<{ x: number; y: number } | null>(null);
  const pan = useRef<{ x: number; y: number; sl: number; st: number } | null>(null);
  const toMask = (e: React.PointerEvent<HTMLCanvasElement>) => {
    const r = e.currentTarget.getBoundingClientRect(), w = work.current!;
    return { x: ((e.clientX - r.left) / r.width) * w.W, y: ((e.clientY - r.top) / r.height) * w.H };
  };
  const brushR = () => { const c = cutCanvas.current, w = work.current; return c && w ? (size / 2) * (w.W / c.getBoundingClientRect().width) : size / 2; };
  const paintTo = (p: { x: number; y: number }) => {
    const w = work.current!, a = last.current ?? p;
    const rect = stroke(w.mask, w.W, w.H, a.x, a.y, p.x, p.y, brushR(), tool as Brush);
    last.current = p;
    if (!rect) return;
    compose(w.orig, w.mask, w.W, w.H, w.carData.data, rect);
    w.car.getContext('2d')!.putImageData(w.carData, 0, 0, rect.x, rect.y, rect.w, rect.h);
    drawCut();
  };
  const down = (e: React.PointerEvent<HTMLCanvasElement>) => {
    if (!work.current) return;
    e.preventDefault(); e.currentTarget.setPointerCapture(e.pointerId);
    if (tool === 'pan') { const f = e.currentTarget.parentElement!; pan.current = { x: e.clientX, y: e.clientY, sl: f.scrollLeft, st: f.scrollTop }; return; }
    undo.current.push(work.current.mask.slice()); if (undo.current.length > 12) undo.current.shift();
    setCanUndo(true);
    last.current = null; paintTo(toMask(e));
  };
  const move = (e: React.PointerEvent<HTMLCanvasElement>) => {
    if (pan.current) { const f = e.currentTarget.parentElement!; f.scrollLeft = pan.current.sl - (e.clientX - pan.current.x); f.scrollTop = pan.current.st - (e.clientY - pan.current.y); return; }
    if (last.current === null || !work.current) return;
    e.preventDefault(); paintTo(toMask(e));
  };
  const maskNow = () => { const w = work.current; setMaskChanged(!!w && masksDiffer(w.mask, w.loaded)); setCanUndo(undo.current.length > 0); };
  const up = () => { if (last.current) { plan.current = null; setDirty((n) => n + 1); maskNow(); } last.current = null; pan.current = null; };
  const back = () => {
    const w = work.current, m = undo.current.pop();
    if (!w || !m) return;
    w.mask.set(m); compose(w.orig, w.mask, w.W, w.H, w.carData.data); w.car.getContext('2d')!.putImageData(w.carData, 0, 0);
    plan.current = null; setDirty((n) => n + 1); maskNow();
  };
  const reset = async () => {
    const w = work.current;
    if (!w) return;
    let auto = w.auto;
    if (!auto && ctx?.auto_mask) {
      try { const i = await load(src(photo.id, 'automask')); auto = alphaOf({ width: w.W, height: w.H, data: pixels(i, w.W, w.H) }); w.auto = auto; } catch { /* below */ }
    }
    if (!auto) { setErr('The automatic cut-out could not be opened.'); return; }
    undo.current.push(w.mask.slice());
    w.mask.set(auto); compose(w.orig, w.mask, w.W, w.H, w.carData.data); w.car.getContext('2d')!.putImageData(w.carData, 0, 0);
    setAdjust(NO_ADJUST); plan.current = null; setDirty((n) => n + 1); maskNow();
    setNote('Back to the automatic cut-out. Save to use it.');
  };

  // ---------------------------------------------------------------- moving and sizing on the studio view
  const drag = useRef<{ x: number; y: number; a: Adjust } | null>(null);
  const sdown = (e: React.PointerEvent<HTMLCanvasElement>) => { e.preventDefault(); e.currentTarget.setPointerCapture(e.pointerId); drag.current = { x: e.clientX, y: e.clientY, a: adjust }; };
  const smove = (e: React.PointerEvent<HTMLCanvasElement>) => {
    const d = drag.current; if (!d) return;
    e.preventDefault();
    const r = e.currentTarget.getBoundingClientRect();
    setAdjust({ ...d.a, dx: clampD(d.a.dx + (e.clientX - d.x) / r.width), dy: clampD(d.a.dy + (e.clientY - d.y) / r.height) });
  };
  const skey = (e: React.KeyboardEvent) => {
    const st = 0.01, m: Record<string, [number, number]> = { ArrowLeft: [-st, 0], ArrowRight: [st, 0], ArrowUp: [0, -st], ArrowDown: [0, st] };
    if (m[e.key]) { e.preventDefault(); const [x, y] = m[e.key]!; setAdjust((a) => ({ ...a, dx: clampD(a.dx + x), dy: clampD(a.dy + y) })); }
    if (e.key === '+' || e.key === '=') { e.preventDefault(); setAdjust((a) => ({ ...a, scale: clampS(a.scale + 0.02) })); }
    if (e.key === '-') { e.preventDefault(); setAdjust((a) => ({ ...a, scale: clampS(a.scale - 0.02) })); }
  };

  const changed = ready && (maskChanged || !sameAdjust(adjust, startAdjust));
  const save = async () => {
    const w = work.current;
    if (!w) return;
    if (!studioPlan({ width: w.W, height: w.H, data: w.carData.data }, null)) { setErr('No car is left in the cut-out. Restore it, or Reset.'); return; }
    setBusy(true); setErr(null);
    try {
      const c = document.createElement('canvas'); c.width = w.W; c.height = w.H;
      c.getContext('2d')!.putImageData(new ImageData(compose(w.orig, w.mask, w.W, w.H) as Uint8ClampedArray<ArrayBuffer>, w.W, w.H), 0, 0);
      const blob = await new Promise<Blob | null>((res) => c.toBlob(res, 'image/png'));
      if (!blob) throw new Error('The cut-out could not be made.');
      const fd = new FormData();
      fd.set('photo', photo.id); fd.set('action', 'save'); fd.set('file', new File([blob], 'cutout.png', { type: 'image/png' }));
      fd.set('dx', adjust.dx.toFixed(4)); fd.set('dy', adjust.dy.toFixed(4)); fd.set('scale', adjust.scale.toFixed(4));
      const r = await fetch('/api/listing/cutout', { method: 'POST', body: fd });
      const j = (await r.json().catch(() => ({ ok: false, message: 'The server did not answer.' }))) as { ok: boolean; message?: string };
      if (!j.ok) throw new Error(j.message ?? 'The cut-out could not be saved.');
      setNote('Saved as a new version. The photo is being made again (about a minute); the version before is kept. If the car moved, check its plate again.');
      w.loaded = w.mask.slice(); setStartAdjust(adjust); setMaskChanged(false);
      router.refresh();
    } catch (e) { setErr(e instanceof Error ? e.message : 'The cut-out could not be saved.'); } finally { setBusy(false); }
  };

  const label = photo.shot_label ?? photo.shot_type.replace(/_/g, ' ');
  return (
    <section className="pt-card ad-card ce" aria-labelledby={`ce-${photo.id}`} data-testid="cutout-editor">
      <div className="pt-card__head"><h3 className="d4" id={`ce-${photo.id}`}>Cut-out of the {label} photo</h3>
        <button type="button" className="btn btn--ghost btn--sm" onClick={onClose}>Close</button></div>
      {ctx && !ctx.mask && !ctx.auto_mask && !ready && <div className="stack">
        <p className="small">This photo was made before the cut-out was kept. Make it again from the photo as taken (one image transformation), then edit it.</p>
        <p><button type="button" className="btn btn--primary btn--sm" disabled={busy || ctx.mask_pending} onClick={() => void askMask()} data-testid="cutout-make-mask">{ctx.mask_pending ? 'Making the cut-out' : 'Make the cut-out'}</button></p>
      </div>}
      {ctx?.pending && !ctx.mask_pending && <p className="alert alert--warn small" role="status"><span>The photo is being made now. Edits saved after it is ready start from the newest version.</span></p>}
      {ready && <>
        <div className="row ce__tabs" role="tablist" aria-label="View">
          <button type="button" role="tab" aria-selected={view === 'cut'} className={`btn btn--sm ${view === 'cut' ? 'btn--primary' : 'btn--ghost'}`} onClick={() => setView('cut')} data-testid="cutout-view-cut">Cut-out</button>
          <button type="button" role="tab" aria-selected={view === 'studio'} className={`btn btn--sm ${view === 'studio' ? 'btn--primary' : 'btn--ghost'}`} onClick={() => setView('studio')} data-testid="cutout-view-studio">On the studio</button>
        </div>
        {view === 'cut' ? <>
          <p className="small muted" id={`ce-help-${photo.id}`}>Brush over what should go (Erase) or what the cut-out took off, such as a mirror, the roof or a wheel (Restore). The photo as taken shows faintly behind the car.</p>
          <fieldset className="row ce__tools"><legend className="vh">Brush</legend>
            {([['erase', 'Erase'], ['restore', 'Restore'], ...(zoom > 1 ? [['pan', 'Move the view']] : [])] as Array<[Brush | 'pan', string]>).map(([k, t]) => (
              <label key={k} className="check"><input type="radio" name={`ce-tool-${photo.id}`} checked={tool === k} onChange={() => setTool(k)} data-testid={`cutout-tool-${k}`} /> <span>{t}</span></label>))}
          </fieldset>
          <div className="row ce__sliders">
            <label className="small">Brush size <input type="range" min={6} max={90} value={size} onChange={(e) => setSize(Number(e.target.value))} data-testid="cutout-brush-size" /></label>
            <label className="small">Zoom <input type="range" min={1} max={4} step={0.5} value={zoom} onChange={(e) => { const z = Number(e.target.value); setZoom(z); if (z === 1 && tool === 'pan') setTool('erase'); }} data-testid="cutout-zoom" /></label>
          </div>
          <div className="ce__frame">
            <canvas ref={cutCanvas} className={`ce__canvas ce__canvas--${tool}`} aria-describedby={`ce-help-${photo.id}`} role="img" aria-label="The cut-out of the car"
              onPointerDown={down} onPointerMove={move} onPointerUp={up} onPointerCancel={up} data-testid="cutout-canvas" />
          </div>
        </> : <>
          <p className="small muted" id={`ce-shelp-${photo.id}`}>Drag the car to move it; the slider sizes it. Keyboard: the arrows move it, + and - size it.</p>
          <div className="row ce__sliders">
            <label className="small">Size <input type="range" min={40} max={160} value={Math.round(adjust.scale * 100)} onChange={(e) => setAdjust((a) => ({ ...a, scale: clampS(Number(e.target.value) / 100) }))} data-testid="cutout-scale" /> {Math.round(adjust.scale * 100)}%</label>
            <button type="button" className="btn btn--ghost btn--sm" onClick={() => setAdjust(NO_ADJUST)} disabled={sameAdjust(adjust, NO_ADJUST)}>Centre and full size</button>
          </div>
          <div className="ce__frame ce__frame--studio">
            <canvas ref={studioCanvas} className="ce__canvas ce__canvas--move" tabIndex={0} role="img" aria-label="The car on the studio background" aria-describedby={`ce-shelp-${photo.id}`}
              onPointerDown={sdown} onPointerMove={smove} onPointerUp={() => { drag.current = null; }} onPointerCancel={() => { drag.current = null; }} onKeyDown={skey} data-testid="cutout-studio" />
          </div>
        </>}
        <div className="row">
          <button type="button" className="btn btn--primary btn--sm" disabled={busy || !changed} onClick={() => void save()} data-testid="cutout-save">{busy ? 'Saving' : 'Save as a new version'}</button>
          <button type="button" className="btn btn--ghost btn--sm" disabled={busy || !canUndo} onClick={back} data-testid="cutout-undo">Undo</button>
          <button type="button" className="btn btn--ghost btn--sm" disabled={busy} onClick={() => void reset()} data-testid="cutout-reset">Reset to the automatic cut-out</button>
        </div>
        {ctx && ctx.versions > 0 && <p className="small muted">Versions kept: {ctx.versions} before this one, and the photo as taken.</p>}
      </>}
      {!ctx && !err && <p className="small muted" role="status">Opening the photo</p>}
      {note && <p className="small" role="status" data-testid="cutout-note">{note}</p>}
      {err && <p className="alert alert--error" role="alert"><span>{err}</span></p>}
    </section>
  );
}

const clampD = (v: number) => Math.max(-0.5, Math.min(0.5, v));
const clampS = (v: number) => Math.max(0.4, Math.min(1.6, Math.round(v * 100) / 100));
