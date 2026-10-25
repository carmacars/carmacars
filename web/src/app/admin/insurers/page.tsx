import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { $, Card, PageHead, Table, d } from '@/features/admin/ui';
import { rateFields, removeFields } from '@/features/insurers/fields';
import { rateLine, type SheetRate } from '@/features/insurers/rates';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Insurer rates', path: '/admin/insurers', noindex: true, description: 'What each insurer pays a day for a replacement car of each class.' });

type Rate = SheetRate & { id: string; effective_from: string };
type Ins = { id: string; name: string; is_active: boolean; rates: Record<string, { now: Rate | null; next: Rate | null }>; open_bookings: number; billed_cents: number; outstanding_cents: number };
type Sheet = { today: string; classes: Array<{ code: string; label: string }>; insurers: Ins[] };

// The insurance-replacement rate sheet (migration 0163): one row per insurer, one column per car class. Each cell is the
// rate today (with the next one already saved); Set or Change adds a rate from a date, the earlier one stays in the
// insurer's history. On a phone each insurer is a card with its classes.
export default async function InsurerRates() {
  const { read } = await page('/admin/insurers');
  const s = await read<Sheet>('insurer_rate_sheet');
  const R = ['/admin/insurers'];
  const cell = (i: Ins, c: { code: string; label: string }) => {
    const x = i.rates[c.code];
    const now = x?.now ?? null; const next = x?.next ?? null;
    return (
      <span className="stack ir-cell" data-testid={`ir-cell-${i.id}-${c.code}`}>
        {now ? <b title={rateLine(now)}>{$(now.daily_rate_cents)}</b> : <span className="muted">none</span>}
        {now && rateLine(now).includes(', ') ? <span className="small muted">{rateLine(now).split(', ').slice(1).join(', ')}</span> : null}
        {next && <span className="small">from {d(next.effective_from)}: {next.daily_rate_cents == null ? 'no rate' : $(next.daily_rate_cents)}</span>}
        <span className="row">
          <Act action="insurer_rate_set" payload={{ insurer_id: i.id, class_code: c.code }} label={now ? 'Change' : 'Set'} variant="quiet" title={`${i.name}: ${c.label}`}
            fields={rateFields(now, s.today)} refresh={R} testId={`ir-set-${i.id}-${c.code}`} done="Rate saved. The earlier rate stays in the history." submitLabel="Save the rate" />
          {now && <Act action="insurer_rate_set" payload={{ insurer_id: i.id, class_code: c.code, remove: true }} label="End" variant="quiet" title={`${i.name}: no ${c.label} rate`}
            fields={removeFields(s.today)} refresh={R} testId={`ir-end-${i.id}-${c.code}`} done="The rate ends on that date." submitLabel="End the rate" />}
        </span>
      </span>
    );
  };
  const active = s.insurers.filter((i) => i.is_active);
  return (<>
    <PageHead title="Insurer rates" kicker="Insurance replacements" purpose="What each insurer pays a day for a replacement car of each class. A booking billed to an insurer takes its rate from here.">
      <Link prefetch={false} className="btn btn--ghost btn--sm" href="/admin/settings/insurers">Insurers&apos; contacts</Link>
      <Link prefetch={false} className="btn btn--ghost btn--sm" href="/admin/insurer-invoices">Insurer invoices</Link>
    </PageHead>
    <Card title="Rate sheet" testId="ir-sheet" aside={<span className="small muted">today {d(s.today)}</span>}>
      <p className="small">A change is saved from a date and never overwrites the rate before it: open an insurer for its history. A car takes the rate of its pricing class, else of its other classes in the list&apos;s order.</p>
      <Table<Ins & Record<string, unknown>> testId="ir-grid" caption="Rates by insurer and class" rows={active as Array<Ins & Record<string, unknown>>}
        empty="No insurer yet. Add one in Settings > Insurers (or from Add a rental, Insurance replacement)."
        cols={[{ key: 'name', label: 'Insurer', render: (i) => <Link prefetch={false} className="link" href={`/admin/insurers/${i.id}`} data-testid={`ir-open-${i.id}`}>{i.name}</Link> },
          ...s.classes.map((c) => ({ key: `c_${c.code}`, label: c.label, render: (i: Ins) => cell(i, c) }))]} />
    </Card>
    <Card title="What each insurer owes" testId="ir-owed">
      <Table<Ins & Record<string, unknown>> rows={s.insurers as Array<Ins & Record<string, unknown>>} empty="No insurer yet."
        cols={[{ key: 'name', label: 'Insurer', render: (i) => <Link prefetch={false} className="link" href={`/admin/insurers/${i.id}`}>{i.name}{i.is_active ? '' : ' (inactive)'}</Link> },
          { key: 'open_bookings', label: 'Open bookings', num: true },
          { key: 'billed_cents', label: 'Billed', num: true, render: (i) => $(i.billed_cents) },
          { key: 'outstanding_cents', label: 'Outstanding', num: true, render: (i) => $(i.outstanding_cents) }]} />
    </Card>
  </>);
}
