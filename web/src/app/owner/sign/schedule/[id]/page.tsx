import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { money } from '@/lib/format';
import { rpc } from '@/lib/db/repo';
import { Back } from '@/features/portal/Blocks';
import { requireOwner } from '@/server/owner/data';
import { ScheduleSign } from '@/features/owner-billing/OwnerReview';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Updated Vehicle Schedule', path: '/owner/sign/schedule', noindex: true, description: 'Read and sign an updated Vehicle Schedule.' });

type T = { insurance_fee_cents: number; tracker_fee_cents: number; revenue_share_bps: number; install_fee_cents?: number | null; first_last_cents?: number | null };
interface Change { change_id: string; status: string; vehicle_name: string; effective_from: string; text: string; sha256: string; owner_name: string; previous: T; new: T; signed_at: string | null }
const day = (iso: string) => new Date(`${iso.slice(0, 10)}T12:00:00Z`).toLocaleDateString('en-CA', { timeZone: 'UTC', weekday: 'short', month: 'short', day: 'numeric', year: 'numeric' });

// An updated Vehicle Schedule (migration 0067): what changes, the exact text, and the owner's signature, bound to the
// SHA-256 of the text on screen, given with the signing steps of every signature (0182).
export default async function ScheduleChangePage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const { user } = await requireOwner(`/owner/sign/schedule/${id}`);
  const c = (await rpc('server_owner_schedule_change', { p_by: user.id, p_change: id }, { role: 'service_role' })) as unknown as Change | null;
  if (!c) notFound();
  const rows: Array<[string, string, string]> = [['Insurance Fee a month', money(c.previous.insurance_fee_cents, { cents: true }), money(c.new.insurance_fee_cents, { cents: true })],
    ['Tracker Fee a month', money(c.previous.tracker_fee_cents, { cents: true }), money(c.new.tracker_fee_cents, { cents: true })],
    ['Revenue Share', `${+(c.previous.revenue_share_bps / 100).toFixed(2)}%`, `${+(c.new.revenue_share_bps / 100).toFixed(2)}%`]];
  return (
    <>
      <Back href="/owner">Owner portal</Back>
      <header className="stack"><p className="pt-kicker">Updated Vehicle Schedule</p><h1 className="d2">{c.vehicle_name}</h1>
        <p className="muted">From {day(c.effective_from)}, once you sign. Your current terms stay in place until then.</p></header>
      <div className="pt-split">
        <div className="stack-lg">
          <section className="pt-card stack" aria-labelledby="sc-what"><h2 className="d4" id="sc-what">What changes</h2>
            <div className="table-scroll"><table className="ad-table" data-testid="schedule-compare"><thead><tr><th scope="col">Term</th><th scope="col">Now</th><th scope="col">Updated</th></tr></thead>
              <tbody>{rows.map(([l, b, n]) => <tr key={l}><td>{l}</td><td>{b}</td><td><b>{n}</b></td></tr>)}</tbody></table></div>
          </section>
          <section className="pt-card stack" aria-labelledby="sc-text"><h2 className="d4" id="sc-text">The text you sign</h2>
            <pre className="ob-text" data-testid="schedule-text">{c.text}</pre>
            <ScheduleSign changeId={c.change_id} sha256={c.sha256} owner={c.owner_name} title={`Updated Vehicle Schedule, ${c.vehicle_name}`} signed={c.status === 'applied'} />
          </section>
        </div>
      </div>
    </>
  );
}
