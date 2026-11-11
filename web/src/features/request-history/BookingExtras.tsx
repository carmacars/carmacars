import Link from '@/components/Link';
import { when } from '@/features/agreement/model';
import { Card } from '@/features/admin/ui';
import { Act } from '@/features/admin/Act';
import { Chip } from '@/features/bookings-now/parts';
import { ContactButtons } from '@/features/phone/QuoButtons';

// r35a: the booking page's small cards for staff: the renter's secondary contact (1302), the rideshare documents the renter
// made (1303) and the renter's instant booking (1304, an Admin takes it away or gives it back).
export interface SecondaryContact { name: string; relationship: string; phone: string | null; email: string | null; updated_at: string; source: 'booking' | 'profile' }
export interface RideshareFacts { open: boolean; requests: Array<{ id: string; labels: string[]; created_at: string }> }
export interface InstantState { eligible: boolean; reason: string | null; completed: number; needed: number; revoked_at: string | null; revoked_reason: string | null; renter_id: string; may_change: boolean }

export function SecondaryContactCard({ c, booking }: { c: SecondaryContact | null; booking: string }) {
  return (
    <Card title="Secondary contact" testId="secondary-contact">
      {!c ? <p className="small muted">None given. The renter can add one in their profile or on this booking.</p> : (
        <div className="stack" style={{ gap: 'var(--s-2)' }}>
          <p><b>{c.name}</b> <span className="small muted">({c.relationship})</span></p>
          <p className="small">{c.phone && <ContactButtons phone={c.phone} name={c.name} booking={booking} look="link" testId="secondary-contact-phone">{c.phone}</ContactButtons>}
            {c.phone && c.email ? ' · ' : ''}{c.email && <a className="link" href={`mailto:${c.email}`} data-testid="secondary-contact-email">{c.email}</a>}</p>
          <p className="small muted">Use it when the renter cannot be reached. {c.source === 'booking' ? 'Given for this booking' : 'From the renter\'s profile'}, {when(c.updated_at, false)}.</p>
        </div>)}
    </Card>
  );
}

export function RideshareStaffCard({ f, lettersHref }: { f: RideshareFacts | null; lettersHref: string }) {
  if (!f || f.requests.length === 0) return null;
  return (
    <Card title="Rideshare documents" testId="rideshare-staff">
      <ul className="small">{f.requests.map((r) => <li key={r.id}>{r.labels.join(', ')} · {when(r.created_at)}</li>)}</ul>
      <p className="small muted">The renter made the rental agreement copy, the coverage letter and the vehicle letter from their booking. The letters name only the company.</p>
      <p><Link prefetch={false} className="btn btn--ghost btn--sm" href={lettersHref} data-testid="rideshare-staff-open">See the letters</Link></p>
    </Card>
  );
}

export function InstantBookCard({ s, refresh }: { s: InstantState | null; refresh: string[] }) {
  if (!s) return null;
  return (
    <Card title="Instant booking" testId="instant-book-state">
      <p className="small"><Chip tone={s.eligible ? 'ok' : 'quiet'}>{s.eligible ? 'This renter books instantly' : 'Request to book'}</Chip> {s.eligible ? `${s.completed} completed rental${s.completed === 1 ? '' : 's'}, licence verified, nothing owing.` : s.reason}</p>
      {s.may_change && (s.revoked_at
        ? <Act ops action="instant_book_set" payload={{ renter: s.renter_id, revoke: false }} label="Give instant booking back" confirm="The renter books instantly again when they qualify." refresh={refresh} testId="instant-book-restore" />
        : <Act ops action="instant_book_set" payload={{ renter: s.renter_id, revoke: true }} label="Take instant booking away" title="Take instant booking away"
            fields={[{ name: 'reason', label: 'Why', type: 'textarea', required: true }]} refresh={refresh} testId="instant-book-revoke" />)}
    </Card>
  );
}
