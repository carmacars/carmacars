import qrcode from 'qrcode-generator';
import { pageMeta } from '@/features/seo/meta';
import { door, requireStaff } from '@/server/door';
import { env } from '@/lib/env';
import { money } from '@/lib/format';
import { when } from '@/features/agreement/model';
import { CopyLink } from '@/features/portal/CopyLink';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Referrals', path: '/field/referrals', noindex: true, description: 'Your referral link and commissions.' });

type Ref = { code: string; rate_bps: number; kickbacks: Array<{ booking_number: string; month: string; amount_cents: number; status: string; payroll_period: string | null }> };
const pctText = (bps: number) => `${bps % 100 === 0 ? bps / 100 : (bps / 100).toFixed(2)}%`;

// /field/referrals (06-field.md section 10): the staff member's link and QR code. A booking made with the link counts as a
// rental they sourced and earns their commission (0058; the commissions are on My sales). Referral fees of the old rule
// are listed for the record.
export default async function Referrals() {
  const { user } = await requireStaff('field', '/field/referrals');
  const r = await door<Ref>(user.id, 'field_read', 'referrals');
  const url = `${env().NEXT_PUBLIC_APP_URL.replace(/\/$/, '')}/r/${r.code}`;
  const qr = qrcode(0, 'M'); qr.addData(url); qr.make();
  const month = (s: string) => new Intl.DateTimeFormat('en-CA', { month: 'long', year: 'numeric', timeZone: 'UTC' }).format(new Date(`${s}T12:00:00Z`));
  return (
    <div className="stack">
      <h1 className="d3">Referrals</h1>
      <section className="fd-card" aria-labelledby="ref-t"><h2 className="d4" id="ref-t">Your link</h2>
        <p className="fd-big" data-testid="referral-code">{r.code}</p>
        <p className="small" style={{ overflowWrap: 'anywhere' }}>{url}</p>
        <CopyLink url={url} label="Copy the link" />
        <div className="fd-qr" role="img" aria-label="QR code of your referral link" dangerouslySetInnerHTML={{ __html: qr.createSvgTag({ cellSize: 4, margin: 2, scalable: true }) }} />
        <p className="small">A booking made with your link counts as a rental you sourced. You earn {pctText(r.rate_bps)} of the rental charge of each one, once it is completed and paid in full and an Admin approves it. See them on <a className="link" href="/field/sales">My sales</a>.</p>
      </section>
      {r.kickbacks.length > 0 && <section className="fd-card" aria-labelledby="kb-t"><h2 className="d4" id="kb-t">Referral fees before October 18, 2026</h2>
        {r.kickbacks.length ? <ul className="fd-shots" data-testid="kickbacks">{r.kickbacks.map((k) => <li key={k.booking_number}><span>{month(k.month)} · {k.booking_number}</span><span>{money(k.amount_cents, { cents: true })}, {k.status}{k.payroll_period ? ` (${when(`${k.payroll_period}T12:00:00Z`, false)})` : ''}</span></li>)}</ul>
          : null}
      </section>}
    </div>
  );
}
