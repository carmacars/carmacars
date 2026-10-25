'use client';
import { useEffect, useRef, useState } from 'react';

// SignaturePad (08-forms.md section 8): a canvas the width of the screen, pointer events (finger, pen
// or mouse) with pressure where available, smooth strokes, Clear. Too few points is not a signature.
export const MIN_POINTS = 12;

export function SignaturePad({ id, onChange, invalid, describedBy, minPoints = MIN_POINTS, small = false, label, testId = 'signature-pad' }: { id: string; onChange: (png: string | null) => void; invalid?: boolean; describedBy?: string; minPoints?: number; small?: boolean; label?: string; testId?: string }) {
  const ref = useRef<HTMLCanvasElement>(null);
  const pts = useRef(0);
  const last = useRef<{ x: number; y: number } | null>(null);
  const [signed, setSigned] = useState(false);

  useEffect(() => {
    const c = ref.current!;
    const fit = () => {
      const r = c.getBoundingClientRect();
      const dpr = Math.max(1, window.devicePixelRatio || 1);
      c.width = Math.round(r.width * dpr); c.height = Math.round(r.height * dpr);
      const g = c.getContext('2d')!;
      g.setTransform(dpr, 0, 0, dpr, 0, 0);
      g.lineCap = 'round'; g.lineJoin = 'round'; g.strokeStyle = '#000';
      pts.current = 0; setSigned(false); onChange(null);
    };
    fit();
    const ro = new ResizeObserver(() => { if (pts.current === 0) fit(); });
    ro.observe(c);
    return () => ro.disconnect();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const pos = (e: React.PointerEvent<HTMLCanvasElement>) => { const r = e.currentTarget.getBoundingClientRect(); return { x: e.clientX - r.left, y: e.clientY - r.top }; };
  const down = (e: React.PointerEvent<HTMLCanvasElement>) => { e.preventDefault(); e.currentTarget.setPointerCapture(e.pointerId); last.current = pos(e); };
  const move = (e: React.PointerEvent<HTMLCanvasElement>) => {
    if (!last.current) return;
    e.preventDefault();
    const g = e.currentTarget.getContext('2d')!;
    const p = pos(e);
    const pressure = e.pressure && e.pointerType === 'pen' ? e.pressure : 0.5;
    g.lineWidth = 1.4 + pressure * 2.2;
    const mid = { x: (last.current.x + p.x) / 2, y: (last.current.y + p.y) / 2 };
    g.beginPath(); g.moveTo(last.current.x, last.current.y); g.quadraticCurveTo(last.current.x, last.current.y, mid.x, mid.y); g.lineTo(p.x, p.y); g.stroke();
    last.current = p;
    pts.current++;
  };
  const up = () => {
    if (!last.current) return;
    last.current = null;
    const ok = pts.current >= minPoints;
    setSigned(ok);
    onChange(ok ? ref.current!.toDataURL('image/png') : null);
  };
  const clear = () => {
    const c = ref.current!; const g = c.getContext('2d')!;
    g.save(); g.setTransform(1, 0, 0, 1, 0, 0); g.clearRect(0, 0, c.width, c.height); g.restore();
    pts.current = 0; setSigned(false); onChange(null);
  };
  return (
    <div className={`sigpad${small ? ' sigpad--small' : ''}`}>
      <div className={`sigpad__box${signed ? ' is-signed' : ''}${invalid ? ' is-invalid' : ''}`}>
        <canvas ref={ref} id={id} role="img" aria-label={label ?? (signed ? 'Your drawn signature' : 'Signature box: draw your signature with your finger or mouse')} aria-describedby={describedBy}
          data-testid={testId} onPointerDown={down} onPointerMove={move} onPointerUp={up} onPointerCancel={up} onPointerLeave={up} />
        <span className="sigpad__line" aria-hidden="true" />
        <span className="sigpad__hint" aria-hidden="true">{signed ? (small ? 'Initialled' : 'Signed') : small ? 'Initial here' : 'Sign here'}</span>
      </div>
      <div className="sigpad__tools">
        {!small && <span className="small muted">{signed ? 'Looks good.' : 'Use your finger, a stylus or the mouse.'}</span>}
        <button type="button" className="btn btn--quiet btn--sm" onClick={clear}>Clear</button>
      </div>
    </div>
  );
}
