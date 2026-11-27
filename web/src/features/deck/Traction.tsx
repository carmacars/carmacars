import { bars, change, figure, headline, monthWords, type DeckTraction } from './traction';

// The traction card of the investor deck and the investor portal (r50 hotfix 2, migration 5162): each measure's last full
// month, its change and the 12-month trend, with what it counts. The site's own figures only.
export function Traction({ t, today, portal = false }: { t: DeckTraction | null; today: string; /** the investor portal's panel instead of the deck's card */ portal?: boolean }) {
  const rows = (t?.metrics ?? []).map((m) => ({ m, h: headline(m, today) })).filter((x) => x.h);
  if (!rows.length) return null;
  return (
    <section className={portal ? 'pu-panel stack' : 'pt-card stack'} aria-labelledby="dk-traction" data-testid="deck-traction">
      <h2 className={portal ? 'pu-title' : 'd3'} id="dk-traction">{portal ? 'How the business is growing' : 'Traction'}</h2>
      <dl className="th-points">
        {rows.map(({ m, h }) => (
          <div key={m.code} data-metric={m.code}>
            <dt className="small muted">{m.label}, {monthWords(h!.month)}</dt>
            <dd className="d3 num" data-testid={`traction-${m.code}`}>{figure(h!.value, m.unit)} <span className="small muted">{m.unit}</span></dd>
            <dd className="small">{change(h!.changePct)}{h!.current !== null ? `${h!.changePct !== null ? '. ' : ''}So far this month: ${figure(h!.current, m.unit)}` : ''}</dd>
            {m.months.length > 1 && <dd aria-hidden="true" style={{ display: 'flex', alignItems: 'flex-end', gap: 3, height: 40, marginTop: 'var(--s-2)' }}>
              {bars(m).map((b, i) => <span key={m.months[i]!.month} style={{ flex: 1, height: `${Math.max(3, b)}%`, background: 'var(--accent, currentColor)', opacity: 0.8, borderRadius: 2 }} />)}</dd>}
          </div>))}
      </dl>
      <p className="small muted">{rows.map(({ m }) => m.note).filter(Boolean).join(' ')}</p>
    </section>
  );
}
