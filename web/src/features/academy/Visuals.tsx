import { useId, type CSSProperties } from 'react';
import { P24 } from '@/components/portal-ui/icons';
import { wrapLabel, type ComparePhoto, type Visual } from './model';

// Release 50 (migration 4200): the academy's pictures. A flow is an inline SVG (two layouts: across on a wide screen, down on a
// phone, so it reads at 320 px); a screen or photo is a lazy webp with numbered pins and a legend; Do and Don't pairs and the
// icon lists use the portal icon set. All of them carry alt text (the SVG and the figures have an accessible name; the
// pictures inside are decorative where the text beside them says the same).
type Kind<K extends Visual['kind']> = Extract<Visual, { kind: K }>;
const icon = (name: string) => (P24 as Record<string, unknown>)[name] ?? P24.check;

/** An icon of the portal set inside an SVG (a nested svg on the 24 px grid). */
function Glyph({ name, x, y, size }: { name: string; x: number; y: number; size: number }) {
  return <svg x={x} y={y} width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">{icon(name) as React.ReactNode}</svg>;
}

export function FlowSvg({ v }: { v: Kind<'flow'> }) {
  const n = v.steps.length;
  const id = useId().replace(/:/g, '');
  // across: each step 150 wide; down: each step 78 high
  const cw = 150, ch = 128, rh = 78;
  const across = (
    <svg className="ac-flow ac-flow--across" viewBox={`0 0 ${n * cw} ${ch}`} role="img" aria-label={v.alt} focusable="false">
      {v.steps.map((s, i) => {
        const cx = i * cw + cw / 2;
        const lines = wrapLabel(s.label, 17).slice(0, 4);
        return (
          <g key={i}>
            {i > 0 && <path d={`M${cx - cw + 36} 40H${cx - 36}`} className="ac-flow__line" markerEnd={`url(#${id}a)`} />}
            <circle cx={cx} cy={40} r={26} className="ac-flow__node" />
            <Glyph name={s.icon} x={cx - 13} y={27} size={26} />
            <text x={cx} y={88} textAnchor="middle" className="ac-flow__label">{lines.map((l, k) => <tspan key={k} x={cx} dy={k === 0 ? 0 : 15}>{l}</tspan>)}</text>
            <text x={cx - 22} y={20} className="ac-flow__num" textAnchor="middle">{i + 1}</text>
          </g>
        );
      })}
      <defs><marker id={`${id}a`} viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M1 1L9 5L1 9" className="ac-flow__head" /></marker></defs>
    </svg>
  );
  const down = (
    <svg className="ac-flow ac-flow--down" viewBox={`0 0 300 ${n * rh}`} role="img" aria-label={v.alt} focusable="false">
      {v.steps.map((s, i) => {
        const cy = i * rh + 36;
        const lines = wrapLabel(s.label, 27).slice(0, 3);
        return (
          <g key={i}>
            {i > 0 && <path d={`M34 ${cy - rh + 24}V${cy - 24}`} className="ac-flow__line" markerEnd={`url(#${id}d)`} />}
            <circle cx={34} cy={cy} r={22} className="ac-flow__node" />
            <Glyph name={s.icon} x={22} y={cy - 12} size={24} />
            <text x={72} y={cy - (lines.length - 1) * 7 + 5} className="ac-flow__label">{lines.map((l, k) => <tspan key={k} x={72} dy={k === 0 ? 0 : 15}>{l}</tspan>)}</text>
          </g>
        );
      })}
      <defs><marker id={`${id}d`} viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M1 1L9 5L1 9" className="ac-flow__head" /></marker></defs>
    </svg>
  );
  return <figure className="ac-vis ac-vis--flow" data-wide={n <= 5}><figcaption className="ac-scene__head">{v.heading}</figcaption>{across}{down}</figure>;
}

function Tick({ ok }: { ok: boolean }) {
  return <svg className={`ac-mark ${ok ? 'ac-mark--ok' : 'ac-mark--no'}`} viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">{ok ? (P24.check as React.ReactNode) : (P24.x as React.ReactNode)}</svg>;
}

export function DoDont({ v }: { v: Kind<'dodont'> }) {
  return (
    <figure className="ac-vis ac-vis--dodont" aria-label={v.alt}>
      <figcaption className="ac-scene__head">{v.heading}</figcaption>
      <div className="ac-dd">
        {v.pairs.map((p, i) => (
          <div className="ac-dd__pair" key={i} style={{ ['--i' as string]: i } as CSSProperties}>
            <p className="ac-dd__do"><Tick ok /><span><b>Do</b> {p.do}</span></p>
            <p className="ac-dd__dont"><Tick ok={false} /><span><b>Do not</b> {p.dont}</span></p>
          </div>
        ))}
      </div>
    </figure>
  );
}

export function IconList({ v }: { v: Kind<'icons'> }) {
  return (
    <figure className="ac-vis ac-vis--icons" aria-label={v.alt}>
      <figcaption className="ac-scene__head">{v.heading}</figcaption>
      <ul className="ac-ic">
        {v.items.map((it, i) => (
          <li key={i} style={{ ['--i' as string]: i } as CSSProperties}>
            <svg viewBox="0 0 24 24" width="26" height="26" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" focusable="false">{icon(it.icon) as React.ReactNode}</svg>
            <span>{it.text}</span>
          </li>
        ))}
      </ul>
    </figure>
  );
}

/** A screen or photo with its pins numbered over it and the legend under it. The image is lazy and sized (no layout jump). */
export function Pic({ v }: { v: Kind<'pic'> }) {
  return (
    <figure className="ac-vis ac-vis--pic">
      <figcaption className="ac-scene__head">{v.heading}</figcaption>
      <div className="ac-pic" style={{ ['--ar' as string]: v.w && v.h ? v.w / v.h : 1.6 } as CSSProperties}>
        {/* eslint-disable-next-line @next/next/no-img-element -- a static webp from /academy, lazy and sized */}
        <img src={v.src} alt={v.alt} width={v.w || undefined} height={v.h || undefined} loading="lazy" decoding="async" className="ac-pic__img" />
        {v.pins?.map((p) => <span key={p.n} className="ac-pin" style={{ left: `${p.x}%`, top: `${p.y}%` }} aria-hidden="true">{p.n}</span>)}
      </div>
      {(v.pins?.length || v.text) ? (
        <ol className="ac-legend">{v.pins?.map((p) => <li key={p.n}><span className="ac-legend__n" aria-hidden="true">{p.n}</span>{p.label}</li>)}{v.text && <li className="ac-legend__text">{v.text}</li>}</ol>
      ) : null}
    </figure>
  );
}

function Photo({ p, ok, alt }: { p: ComparePhoto; ok: boolean; alt: string }) {
  return (
    <div className={`ac-cmp__side ac-cmp__side--${ok ? 'good' : 'bad'}`}>
      <div className="ac-pic">
        {/* eslint-disable-next-line @next/next/no-img-element -- a static webp from /academy, lazy and sized */}
        <img src={p.src} alt={alt} width={p.w || undefined} height={p.h || undefined} loading="lazy" decoding="async" className="ac-pic__img" />
        <span className={`ac-badge-mark ac-badge-mark--${ok ? 'ok' : 'no'}`}><Tick ok={ok} /> {ok ? 'Good' : 'Not good'}</span>
      </div>
      <p>{p.text}</p>
    </div>
  );
}

export function Compare({ v }: { v: Kind<'compare'> }) {
  return (
    <figure className="ac-vis ac-vis--compare">
      <figcaption className="ac-scene__head">{v.heading}</figcaption>
      <div className="ac-cmp">
        <Photo p={v.good} ok alt={`Good example: ${v.good.text}`} />
        <Photo p={v.bad} ok={false} alt={`Bad example: ${v.bad.text}`} />
      </div>
      <p className="ac-cmp__note">Example pictures from the sample cars.</p>
    </figure>
  );
}

/** The scene body of a picture kind (null for the others). */
export function PictureScene({ v }: { v: Visual }) {
  switch (v.kind) {
    case 'flow': return <FlowSvg v={v} />;
    case 'dodont': return <DoDont v={v} />;
    case 'icons': return <IconList v={v} />;
    case 'pic': return <Pic v={v} />;
    case 'compare': return <Compare v={v} />;
    default: return null;
  }
}
