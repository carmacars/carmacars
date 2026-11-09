import Link from '@/components/Link';
import { Act, type Field } from '@/features/admin/Act';
import { $, Card, Kv, Table, d, t } from '@/features/admin/ui';
import { storage, type Bucket } from '@/integrations/storage';
import { angleLabel } from '@/features/handover/angles';
import type { HandoverReportData, ReportPhoto } from '@/features/handover/types';
import { addonFacts, pairPhotos, stageWords, type Place, type ReviewItem, type ReviewView, type Sign } from './model';

// One returned booking's deposit review (release 35 part RR, migration 1010): the pickup and return photos side by side,
// angle by angle; then the seven items, each with what the site already knows (readings, return report, late time, the
// tolls and tickets on the car). Fleet signs each first, then Finance double-checks; Finance also checks the toll operator
// and every ticket place (its official lookup link; none found, or the ticket, logged in Tolls and tickets). Then Finance
// bills what is owed (the charge after the return on Money) or releases the deposit; the database keeps the deposit held
// until both signed every item, unless an Admin releases with the reason.
const RESULT: Array<[string, string]> = [['ok', 'OK, nothing to bill'], ['issue', 'Issue']];
const TICKET_KINDS: Array<[string, string]> = [['parking', 'Parking ticket'], ['camera_offence', 'Camera (speed or red light)'], ['ticket', 'Other ticket'], ['fine', 'Fine'], ['tow', 'Tow'], ['impound', 'Impound']];

function factLines(it: ReviewItem): string[] {
  const f = it.facts as Record<string, unknown>;
  const n = (k: string) => (f[k] === null || f[k] === undefined ? null : Number(f[k]));
  const charged = n('charged_cents') ? `already charged ${$(n('charged_cents'))}` : null;
  switch (it.item) {
    case 'fuel': return [f.out_pct !== null && f.out_pct !== undefined ? `Fuel ${n('out_pct')}% out, ${f.in_pct ?? 'not read'}% in${n('eighths_short') ? `: ${n('eighths_short')}/8 short` : ''}` : 'No fuel reading', charged].filter(Boolean) as string[];
    case 'km': return [f.driven !== null && f.driven !== undefined ? `${n('driven')} km driven, ${n('allowance') ?? 0} included${n('over') ? `: ${n('over')} km over` : ''}` : 'No odometer reading', charged].filter(Boolean) as string[];
    case 'damage': { const nw = (f.new as string[] | undefined) ?? []; return [nw.length ? `New at the return: ${nw.join('; ')}` : 'No new damage marked at the return', charged].filter(Boolean) as string[]; }
    case 'late': return [n('minutes') ? `Back ${Math.floor(n('minutes')! / 60)} h ${n('minutes')! % 60} min after the return time` : 'Back on time', charged].filter(Boolean) as string[];
    case 'cleaning': return [f.at_return ? `At the return: ${String(f.at_return).replace(/_/g, ' ')}` : 'Cleanliness not recorded at the return', charged].filter(Boolean) as string[];
    case 'tickets': case 'tolls': {
      const xs = (f.on_car as Array<{ authority: string | null; amount_cents: number; at: string; status: string }> | undefined) ?? [];
      return xs.length ? xs.map((x) => `${x.authority ?? 'Notice'}: ${$(x.amount_cents)} on ${t(x.at)} (${x.status.replace(/_/g, ' ')})`) : [it.item === 'tolls' ? 'No toll notice on the car for these dates yet' : 'No ticket on the car for these dates yet'];
    }    // r35 UX (1108): each add-on that went in the car, with what to charge if it is not back (a suggestion; nothing is charged by itself)
    case 'addons': return addonFacts(f);
  }
}

function signWords(s: Sign | null): string {
  if (!s) return 'Not checked yet';
  return `${s.result === 'ok' ? 'OK' : `Issue${s.amount_cents ? ` ${$(s.amount_cents)}` : ''}`}${s.note ? `: ${s.note}` : ''}${s.photos?.length ? ` (photos ${s.photos.join(', ')})` : ''} · ${s.by ?? 'staff'}, ${t(s.at)}`;
}

export async function ReviewPage({ d: v, report, base, tollsHref, refresh }: { d: ReviewView; report: HandoverReportData | null; base: string; tollsHref: string; refresh: string[] }) {
  const s = await storage();
  const sign = async (p: ReportPhoto | null) => (p ? { ...p, src: await s.signedDownloadUrl(p.bucket as Bucket, p.path, 900).catch(() => null) } : null);
  const out = report?.reports.find((x) => x.kind === 'pickup');
  const back = report?.reports.find((x) => x.kind === 'return');
  const pairs = await Promise.all(pairPhotos(out?.photos ?? [], back?.photos ?? []).map(async (r) => ({ key: r.key, out: await sign(r.out), in: await sign(r.in) })));
  const st = v.state;
  const P = { booking: v.booking_id };
  const fleetFields = (it: ReviewItem): Field[] => [
    { name: 'result', label: 'Result', type: 'select', required: true, options: RESULT, value: it.fleet?.result ?? it.facts.suggest ?? 'ok' },
    { name: 'amount_cents', label: 'Amount to bill (if an issue)', type: 'money', value: it.fleet?.amount_cents ?? undefined, ...(it.item === 'addons' ? { hint: 'Not back? The suggested charge is in What the site knows: type the amount for the add-ons missing.' } : {}) },
    { name: 'note', label: 'What you found (required for an issue)', type: 'textarea', value: it.fleet?.note ?? '' },
    { name: 'photos', label: 'Return photo numbers that show it (for example 3, 7)', type: 'text', value: it.fleet?.photos?.join(', ') ?? '' }];
  const financeFields = (it: ReviewItem): Field[] => [
    { name: 'result', label: it.item === 'tolls' ? 'Toll operator checked' : 'Result', type: 'select', required: true, options: RESULT, value: it.finance?.result ?? it.fleet?.result ?? 'ok' },
    { name: 'amount_cents', label: 'Amount to bill (if an issue)', type: 'money', value: it.finance?.amount_cents ?? it.fleet?.amount_cents ?? undefined },
    { name: 'note', label: it.item === 'tolls' ? 'What the toll operator shows (required for an issue)' : 'Your note (required for an issue)', type: 'textarea', value: it.finance?.note ?? '' }];
  const done = st?.stage === 'done';
  return (
    <div className="stack-lg" data-testid="deposit-review">
      <Card title="Where it stands" testId="dr-state" aside={<span className={`ad-b ${done ? '' : 'ad-b--amber'}`}>{stageWords(st)}</span>}>
        <Kv rows={[['Car', `${v.vehicle}${v.plate ? ` · ${v.plate}` : ''}`], ['Renter', v.renter ?? ''], ['Out', t(v.pickup_at)], ['Due back', t(v.return_at)], ['Back', v.checked_in_at ? t(v.checked_in_at) : 'not yet'],
          ['Deposit', v.deposit ? `${$(v.deposit.amount_cents)} ${v.deposit.status}${v.deposit.released_cents ? `, ${$(v.deposit.released_cents)} released` : ''}${v.deposit.held_back_cents ? `, ${$(v.deposit.held_back_cents)} held back` : ''}` : 'none'],
          ['Promised back by', v.deposit?.release_due_on ? d(v.deposit.release_due_on) : ''], ['Tolls and tickets window ends', v.toll_window_ends_on ? d(v.toll_window_ends_on) : '']]} />
        {!v.exists && <p className="small muted">This booking has no deposit review (no deposit, an Owner Booking, or returned before the review started).</p>}
        {v.blockers.length > 0 && <div className="alert alert--warn" role="status" data-testid="dr-blockers"><span>The deposit stays held: {v.blockers.map((b) => b.label).join('; ')}.{v.may.admin ? ' As an Admin you can release it on Money with the reason.' : ''}</span></div>}
        <p className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-2)' }}>
          <Link prefetch={false} className="btn btn--ghost btn--sm" href={`${base}/report`}>Photo report</Link>
          {v.may.finance && <Link prefetch={false} className="btn btn--primary btn--sm" href={`${base}?tab=money`} data-testid="dr-money">{done ? 'Bill or release on Money' : 'Money'}</Link>}
          {v.may.finance && <Link prefetch={false} className="btn btn--ghost btn--sm" href={tollsHref}>Tolls and tickets</Link>}
        </p>
      </Card>

      {v.exists && <Card title="The checklist" testId="dr-items">
        <p className="small muted">Fleet checks each item first, then Finance double-checks it. An issue needs a note; put the amount to bill when you know it.</p>
        <Table<ReviewItem & Record<string, unknown>> rows={v.items as Array<ReviewItem & Record<string, unknown>>} rowKey={(r) => r.item} cols={[
          { key: 'label', label: 'Item', render: (r) => <b>{r.label}</b> },
          { key: 'facts', label: 'What the site knows', className: 'wrap', render: (r) => <span className="small">{factLines(r).join('. ')}{r.facts.suggest === 'issue' ? <> <span className="ad-b ad-b--amber">check</span></> : null}</span> },
          { key: 'fleet', label: 'Fleet', className: 'wrap', render: (r) => <span className="stack-xs"><span className="small" data-testid={`dr-fleet-${r.item}`}>{signWords(r.fleet)}</span>
            {v.may.fleet && !r.finance && <Act ops action="deposit_review_sign" payload={{ ...P, side: 'fleet', item: r.item }} label={r.fleet ? 'Change' : 'Sign'} variant={r.fleet ? 'quiet' : 'primary'}
              testId={`dr-sign-fleet-${r.item}`} fields={fleetFields(r)} refresh={refresh} done="Signed." />}</span> },
          { key: 'finance', label: 'Finance', className: 'wrap', render: (r) => <span className="stack-xs"><span className="small" data-testid={`dr-finance-${r.item}`}>{signWords(r.finance)}</span>
            {v.may.finance && r.fleet && (v.may.admin || !r.fleet_by_me) && <Act ops action="deposit_review_sign" payload={{ ...P, side: 'finance', item: r.item }} label={r.finance ? 'Change' : 'Double-check'} variant={r.finance ? 'quiet' : 'primary'}
              testId={`dr-sign-finance-${r.item}`} fields={financeFields(r)} refresh={refresh} done="Checked." />}</span> }]} />
      </Card>}

      {v.exists && v.may.finance && <Card title="Tolls and tickets: Finance checks each place" testId="dr-places">
        <p className="small">1. Highway tolls: <a className="link" href={v.toll_url} target="_blank" rel="noreferrer" data-testid="dr-toll-link">open the toll operator&apos;s site</a>, search plate <b>{v.plate ?? 'unknown'}</b> for {d(v.pickup_at)} to {d(v.checked_in_at ?? v.return_at)}, then double-check the Highway tolls item above.</p>
        <p className="small">2. Tickets: open each place, search the plate for the same dates, and record what you found. A ticket is logged in Tolls and tickets and matched to this booking there.</p>
        <Table<Place & Record<string, unknown>> rows={v.places as Array<Place & Record<string, unknown>>} rowKey={(r) => r.key} cols={[
          { key: 'name', label: 'Place', render: (r) => <a className="link" href={r.url} target="_blank" rel="noreferrer">{r.name}</a> },
          { key: 'check', label: 'Found', className: 'wrap', render: (r) => r.check ? <span className="small" data-testid={`dr-place-${r.key}`}>{r.check.result === 'ticket' ? 'A ticket (logged)' : 'None found'}{r.check.note ? `: ${r.check.note}` : ''} · {r.check.by ?? ''}, {t(r.check.at)}</span> : <span className="small muted">not checked</span> },
          { key: 'act', label: '', render: (r) => r.check?.result === 'ticket' ? <Link prefetch={false} className="link small" href={tollsHref}>Open in Tolls and tickets</Link> : <span className="ad-actions">
            <Act ops action="deposit_review_ticket" payload={{ ...P, place: r.key, result: 'none_found' }} label="None found" testId={`dr-none-${r.key}`} refresh={refresh} done="Recorded." />
            <Act ops action="deposit_review_ticket" payload={{ ...P, place: r.key, result: 'ticket' }} label="A ticket" testId={`dr-ticket-${r.key}`} refresh={refresh} done="Logged."
              fields={[{ name: 'kind', label: 'Kind', type: 'select', required: true, options: TICKET_KINDS, value: 'parking' }, { name: 'amount_cents', label: 'Amount', type: 'money', required: true },
                { name: 'occurred_at', label: 'When it happened', type: 'datetime', required: true }, { name: 'notice_number', label: 'Notice number', type: 'text' }, { name: 'note', label: 'Note', type: 'textarea' }]} /></span> }]} />
      </Card>}

      <Card title="Pickup and return, angle by angle" testId="dr-photos">
        {pairs.length === 0 ? <p className="pt-empty">No photos yet.</p> : <ul className="stack" style={{ listStyle: 'none', padding: 0 }}>
          {pairs.map((r) => (
            <li key={r.key}>
              <p className="small"><b>{r.key.startsWith('damage:') ? `Damage ${r.key.slice(7)}` : angleLabel((r.in ?? r.out)?.angle ?? (r.in ?? r.out)?.shot)}</b></p>
              <div className="hr-dashes">
                {[['Pickup', r.out], ['Return', r.in]].map(([lbl, p]) => {
                  const ph = p as (ReportPhoto & { src: string | null }) | null;
                  return (<figure className="hr-dash" key={lbl as string}>
                    {/* eslint-disable-next-line @next/next/no-img-element -- signed private photo */}
                    {ph?.src ? <a href={ph.src} target="_blank" rel="noreferrer"><img src={ph.src} alt={`${lbl as string}: ${angleLabel(ph.angle ?? ph.shot)}`} loading="lazy" decoding="async" width={320} height={213} /></a> : <span className="small muted">No {String(lbl).toLowerCase()} photo</span>}
                    <figcaption className="xs">{lbl as string}{ph ? ` · photo ${ph.seq}${ph.taken_at ? ` · ${t(ph.taken_at)}` : ''}` : ''}</figcaption>
                  </figure>);
                })}
              </div>
            </li>))}
        </ul>}
      </Card>
    </div>
  );
}
