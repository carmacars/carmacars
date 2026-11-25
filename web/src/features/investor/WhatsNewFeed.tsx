import Link from '@/components/Link';
import { feedFor, prettyDate } from '@/lib/whats-new';
import { WN_DATA } from '@/server/whats-new';
import { investorFeed } from './updates';

// What's new for investors (r50): built from the release notes (docs/releases/rNN.md, "## For investors") by
// scripts/whats-new.mjs into src/generated/whats-new.json, at build time; nothing is read from the database. A release
// without an investor section shows its plain-language summary; nothing on the investor deny list is shown (updates.ts). The dashboard shows the latest few; Updates shows all.
export function WhatsNewFeed({ limit, compact = false }: { limit?: number; compact?: boolean }) {
  const feed = investorFeed(feedFor(WN_DATA, 'investor')).slice(0, limit);
  if (!feed.length) return null;
  return (
    <section className={compact ? 'pu-panel' : 'pt-card stack'} aria-labelledby="iv-wn-h" data-testid="investor-whats-new" data-guide="investor-whats-new">
      <div className={compact ? 'pu-panel__head' : undefined}><h2 className={compact ? 'pu-title' : 'd4'} id="iv-wn-h">What&apos;s new at CarmaCars</h2></div>
      {!compact && <p className="small muted">What each release of the CarmaCars platform added, in plain words, newest first.</p>}
      <ol className="iv-wn">
        {feed.map((f) => (
          <li key={f.release} data-testid={`whats-new-${f.release}`}>
            <p className="small"><span className="strong">Release {f.release.replace(/^r/, '')}</span> <time className="muted" dateTime={f.date}>{prettyDate(f.date)}</time></p>
            {f.items.length ? <ul className="small">{f.items.slice(0, compact ? 3 : undefined).map((i) => <li key={i}>{i}</li>)}</ul> : <p className="small">{f.summary}</p>}
          </li>
        ))}
      </ol>
      {compact && <p className="small"><Link className="link" href="/investor/updates" data-testid="whats-new-all">Every update</Link></p>}
    </section>
  );
}
