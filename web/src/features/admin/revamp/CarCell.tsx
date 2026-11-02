// A car in a row (r27, the Now view's car line): its photo when the row has one, else a black tile with the make's first
// letter, then the name and a quiet second line (plate, code or booking). Shared by admin and staff rows.
export function CarCell({ name, sub, photo }: { name: unknown; sub?: unknown; photo?: string | null }) {
  const n = typeof name === 'string' ? name : '';
  if (!n) return <span className="muted">none</span>;
  const letter = (n.replace(/^\d{4}\s+/, '').trim().charAt(0) || '?').toUpperCase();
  return (
    <span className="rv-car">
      {/* eslint-disable-next-line @next/next/no-img-element -- a 48 by 32 thumbnail already sized by the photo service */}
      {photo ? <img className="rv-car__photo" src={photo} alt="" width={48} height={32} loading="lazy" /> : <span className="rv-car__photo rv-car__photo--none" aria-hidden="true">{letter}</span>}
      <span className="rv-car__text"><span className="rv-car__name">{n}</span>{sub ? <span className="rv-car__sub">{String(sub)}</span> : null}</span>
    </span>
  );
}
