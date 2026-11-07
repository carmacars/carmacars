import Link from '@/components/Link';
import type { QuickLink } from './quick-links';

// r32: the renter home's quick links for a booking that needs them (quick-links.ts decides which)
export function QuickLinks({ number, links }: { number: string; links: QuickLink[] }) {
  if (!links.length) return null;
  return (
    <section className="pu-panel stack" aria-labelledby="pt-quick" data-testid="renter-quick-links">
      <h2 className="pu-section-title" id="pt-quick">Still needed for {number}</h2>
      <div className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-2)' }}>
        {links.map((l, i) => <Link key={l.key} prefetch={false} className={`btn ${i === 0 ? 'btn--primary' : 'btn--ghost'} btn--sm`} href={l.href} data-testid={`quick-${l.key}`}>{l.label}</Link>)}
      </div>
    </section>
  );
}
