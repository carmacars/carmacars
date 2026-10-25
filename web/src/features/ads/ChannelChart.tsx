// Bookings by channel (migration 0167): a bar per channel, requests in grey with the bookings inside them, and the
// figures in a table for screen readers and anyone who wants them. No library: CSS widths.
export interface ChannelRow { channel: string; label: string; requests: number; bookings: number; revenue_cents: number; conversion_bps: number }

export function ChannelChart({ rows, money }: { rows: ChannelRow[]; money: (c: number) => string }) {
  const max = Math.max(1, ...rows.map((r) => r.requests));
  if (!rows.length) return <p className="small muted" data-testid="ads-chart-empty">No requests in these dates yet.</p>;
  return (
    <figure className="ads-chart" data-testid="ads-chart" style={{ margin: 0 }}>
      <ul aria-hidden="true" style={{ listStyle: 'none', margin: 0, padding: 0, display: 'grid', gap: '0.5rem' }}>
        {rows.map((r) => (
          <li key={r.channel} style={{ display: 'grid', gridTemplateColumns: 'minmax(7rem, 11rem) 1fr', gap: '0.75rem', alignItems: 'center' }}>
            <span className="small" style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{r.label}</span>
            <span style={{ position: 'relative', display: 'block', height: '1.4rem', background: 'var(--grey-100, #f2f2f2)', borderRadius: '4px' }}>
              <span style={{ position: 'absolute', inset: '0 auto 0 0', width: `${(r.requests / max) * 100}%`, background: 'var(--grey-300, #c8c8c8)', borderRadius: '4px' }} />
              <span style={{ position: 'absolute', inset: '0 auto 0 0', width: `${(r.bookings / max) * 100}%`, background: 'var(--black, #111)', borderRadius: '4px' }} />
              <span className="small" style={{ position: 'absolute', right: '0.4rem', top: '0.1rem' }}>{r.bookings} of {r.requests}</span>
            </span>
          </li>))}
      </ul>
      <figcaption className="small muted" style={{ display: 'flex', flexWrap: 'wrap', gap: '0.5rem 1.25rem', marginTop: '0.5rem' }}>
        <span><i aria-hidden="true" style={{ display: 'inline-block', width: '0.8rem', height: '0.8rem', marginRight: '0.35rem', background: 'var(--grey-300, #c8c8c8)' }} />Requests</span>
        <span><i aria-hidden="true" style={{ display: 'inline-block', width: '0.8rem', height: '0.8rem', marginRight: '0.35rem', background: 'var(--black, #111)' }} />Bookings</span>
      </figcaption>
      <table className="ad-table small vh" data-testid="ads-chart-table"><caption>Requests and bookings by channel</caption>
        <thead><tr><th scope="col">Channel</th><th scope="col">Requests</th><th scope="col">Bookings</th><th scope="col">Revenue</th></tr></thead>
        <tbody>{rows.map((r) => <tr key={r.channel}><td>{r.label}</td><td>{r.requests}</td><td>{r.bookings}</td><td>{money(r.revenue_cents)}</td></tr>)}</tbody></table>
    </figure>
  );
}
