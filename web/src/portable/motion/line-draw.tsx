// A mark whose strokes draw along their lines (SVG stroke-dashoffset), then fill in (release 48 AN). Plays once a session
// (sessionStorage), never under reduced motion or the pause control: then the mark shows at once. An inline script before
// the mark decides before the first paint (no flash, no layout shift: the box is the SVG's own size).
// Portable: React only, no client code (works in a server component). Styles: motion.css (.mo-draw).

const script = (key: string) =>
  `try{var h=document.documentElement;if(!h.dataset.moDraw&&!matchMedia('(prefers-reduced-motion: reduce)').matches&&h.dataset.motion!=='reduced'&&!sessionStorage.getItem(${JSON.stringify(key)})){h.dataset.moDraw='play';sessionStorage.setItem(${JSON.stringify(key)},'1')}}catch(e){}`;

export function LineDraw({ d, viewBox, width, height, title, sessionKey = 'mo-draw', className = '', fill = 'currentColor', strokeWidth = 1.4, ms = 1400, fillRule = 'evenodd' }: {
  /** the mark's path data (its outline: the strokes follow it), or paths with their own fill */
  d: string | Array<string | { d: string; fill?: string }>; viewBox: string; width: number; height: number; title: string; sessionKey?: string; className?: string;
  fill?: string; strokeWidth?: number; ms?: number; fillRule?: 'evenodd' | 'nonzero';
}) {
  const paths = (Array.isArray(d) ? d : [d]).map((p) => (typeof p === 'string' ? { d: p, fill } : { d: p.d, fill: p.fill ?? fill }));
  return (
    <>
      <script dangerouslySetInnerHTML={{ __html: script(sessionKey) }} />
      <svg className={`mo-draw ${className}`.trim()} viewBox={viewBox} width={width} height={height} role="img" aria-label={title}
        style={{ ['--mo-draw-ms' as string]: `${ms}ms`, ['--mo-draw-width' as string]: String(strokeWidth) }}>
        {paths.map((p, i) => <path key={`f${i}`} className="mo-draw__fill" d={p.d} fill={p.fill} fillRule={fillRule} />)}
        {paths.map((p, i) => <path key={`s${i}`} className="mo-draw__stroke" d={p.d} stroke={p.fill} pathLength={1} />)}
      </svg>
    </>
  );
}
