import { Card } from '@/features/admin/ui';
import { intentPhrases, type Intent } from './model';

// Lead intent (migration 1506): a renter's or a lead's intent score, label and signals, read from what they said and did
// (rules; an AI reading fills what the rules left empty). On the lead page, the renter page and the staff renter view.
export function IntentCard({ intent }: { intent: Intent | null }) {
  if (!intent) return null;
  const phrases = intentPhrases(intent.signals);
  return (
    <Card title={intent.label === 'unknown' ? 'Intent: nothing to read yet' : `Intent: ${intent.label} (${intent.score})`} testId="intent-card" tone={intent.label === 'hot' ? 'next' : undefined}>
      {phrases.length ? <ul className="lm-chips" aria-label="Intent signals" data-testid="intent-signals">{phrases.map((p) => <li key={p}>{p}</li>)}</ul>
        : <p className="small muted">No budget, car, dates or coverage said yet.</p>}
      {!!intent.reasons?.length && <p className="small muted" data-testid="intent-reasons">{intent.reasons.map((r) => `${r.label} (${r.points >= 0 ? '+' : ''}${r.points})`).join(' · ')}</p>}
      <p className="small muted">From everything this person did with us, on every lead and booking: calls, texts, WhatsApp, emails, the site chat, visits, offers, bookings and reviews{intent.sources ? ` (${intent.sources} messages read)` : ''}{intent.ai_at ? '; an AI reading filled the gaps' : ''}.</p>
    </Card>
  );
}
