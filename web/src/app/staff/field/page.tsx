import Link from '@/components/Link';
import { requestNow } from '@/features/va/lanes';
import { pageMeta } from '@/features/seo/meta';
import { door, requireStaff } from '@/server/door';
import { FieldButton } from '@/features/field/FieldButton';
import { Plate } from '@/features/field/Plate';
import { FdIcon } from '@/features/field/icons';
import { LicenceReview } from '@/features/field/LicenceReview';
import { KIND, clock, dayLabel, tel } from '@/features/field/format';
import type { FieldList, LicenceCard } from '@/features/field/types';
import { when } from '@/features/agreement/model';
import { getTokens } from '@/lib/site';
import { signCount } from '@/features/manual/SignPages';
import { ShiftStrip } from '@/features/field-portal/ShiftStrip';
import { WorkCard } from '@/features/field-portal/WorkCard';
import { AddButton } from '@/features/field-portal/AddButton';
import type { OpenMust, Today } from '@/features/field-portal/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Today', path: '/staff/field', noindex: true, description: 'Your shift and your work list for the day.' });

const dateText = (d: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'UTC', weekday: 'long', month: 'long', day: 'numeric' }).format(new Date(`${d}T12:00:00Z`));
const TODO_HREF: Record<string, string> = { field_receipt_missing: '/staff/field/shifts#spending', field_pay_details: '/staff/field/pay#pay-details', first_day: '/staff/welcome' };
const tomorrowIso = () => { const d = new Date(new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto' }).format(new Date()) + 'T12:00:00Z'); d.setUTCDate(d.getUTCDate() + 1); return d.toISOString().slice(0, 10); };

// Today (r35 part X; 06-field.md section 2): the shift and Clock in at the top, then one ordered list of the day's work built from
// the data (0930): each pickup and return of the person with its add-ons and clean check as one card, onboarding prep, then the
// cars to clean, the cars needing service and listing photos when there is time. One Add button for money spent, a service
// record, photos and a problem. Tomorrow shows what is planned so far.
export default async function FieldToday({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ user }, sp] = await Promise.all([requireStaff('field', '/staff/field'), searchParams]);
  const tomorrow = sp.day === 'tomorrow';
  const [t, open, list, tk, toSign, licences, report] = await Promise.all([
    door<Today>(user.id, 'field_read', 'today', tomorrow ? { day: tomorrowIso() } : {}),
    tomorrow ? Promise.resolve([] as OpenMust[]) : door<OpenMust[]>(user.id, 'field_read', 'open_musts').catch(() => [] as OpenMust[]),
    door<FieldList>(user.id, 'field_read', 'jobs').catch(() => null), getTokens(), signCount(user.id),
    door<LicenceCard[]>(user.id, 'field_read', 'licences').catch(() => [] as LicenceCard[]),
    door<{ vehicles: Array<{ id: string; name: string; job: string }> }>(user.id, 'field_read', 'report_form').catch(() => ({ vehicles: [] }))]);
  const musts = t.cards.filter((c) => c.must);
  const spare = t.cards.filter((c) => !c.must);
  const now = requestNow();
  const cars = [...new Map(t.cards.map((c) => [c.vehicle.id, { id: c.vehicle.id, name: `${c.vehicle.name}${c.vehicle.plate ? `, ${c.vehicle.plate}` : ''}` }])).values()];
  const bookings = t.cards.filter((c) => c.booking).map((c) => ({ id: c.booking!.id, number: c.booking!.number, vehicle: c.vehicle.id }));
  const preps = Object.fromEntries(t.cards.filter((c) => c.type === 'prep' && !c.done && c.id).map((c) => [c.vehicle.id, c.id!]));
  const first = list?.name?.split(' ')[0];
  return (
    <>
      <header className="fp-hello">
        <h1>{tomorrow ? 'Tomorrow' : `Today${first ? `, ${first}` : ''}`}</h1>
        <p>{dateText(t.day)}</p>
      </header>
      <nav className="fd-days" aria-label="Day">
        <Link prefetch={false} href="/staff/field" aria-current={!tomorrow ? 'page' : undefined}>Today</Link>
        <Link prefetch={false} href="/staff/field?day=tomorrow" aria-current={tomorrow ? 'page' : undefined}>Tomorrow</Link>
      </nav>
      {!tomorrow && <ShiftStrip t={t} open={open} />}
      {(t.todo.length > 0 || toSign > 0) && <ul className="fp-todo" aria-label="To do" data-testid="field-todo">
        {toSign > 0 && <li data-testid="field-to-sign"><Link prefetch={false} href="/staff/field/sign"><FdIcon name="alert" />{toSign === 1 ? 'A document' : `${toSign} documents`} to read and sign</Link></li>}
        {t.todo.map((x) => <li key={x.id}><Link prefetch={false} href={TODO_HREF[x.type] ?? '/staff/field'}><FdIcon name="alert" />{x.title}</Link></li>)}
      </ul>}
      {licences.length > 0 && <section aria-labelledby="lic-t" data-testid="field-licences" className="fp-stack">
        <h2 className="fp-group-h" id="lic-t">Licences to check <span className="fd-days__n">{licences.length}</span></h2>
        <ul className="fd-lic-list">{licences.map((l) => <li key={l.field_job_id} className="fd-lic-card" data-testid="licence-card">
          <p className="fd-lic-card__when">{dayLabel(l.scheduled_at)}, {clock(l.scheduled_at).time} {clock(l.scheduled_at).half}<span className="small"> · {KIND[l.kind] ?? l.kind}</span></p>
          <p className="fd-lic-card__car">{l.vehicle_label}</p>
          <div className="fd-lic-card__id">{l.plate && <Plate plate={l.plate} small />}<span className="small">{[l.renter_first_name, l.booking_number].filter(Boolean).join(', ')}, {l.waiting} image{l.waiting === 1 ? '' : 's'} waiting</span></div>
          <LicenceReview job={l.field_job_id} waiting={l.waiting} />
        </li>)}</ul>
      </section>}
      <h2 className="fp-group-h">{tomorrow ? 'Planned so far' : 'Your work'}<span className="small">{musts.length ? `${musts.length} ${musts.length === 1 ? 'card' : 'cards'}` : ''}</span></h2>
      {musts.length ? <ol className="fp-list" data-testid="work-list">{musts.map((c) => <WorkCard key={c.key} c={c} now={now} />)}</ol>
        : <div className="fd-empty" data-testid="no-jobs"><FdIcon name="car" className="fd-empty__ico" /><p className="fd-empty__h">No pickups or returns {tomorrow ? 'tomorrow yet' : 'today'}.</p>
          <p className="small">{t.on_shift || tomorrow ? 'New work shows up here as bookings come in.' : 'Jobs go to people on a shift: claim one on My shifts.'}</p></div>}
      {spare.length > 0 && <>
        <h2 className="fp-group-h">When you have time<span className="small">{spare.length}</span></h2>
        <ol className="fp-list" data-testid="spare-list">{spare.map((c) => <WorkCard key={c.key} c={c} now={now} />)}</ol>
      </>}
      {!tomorrow && <p><Link prefetch={false} className="btn btn--ghost fd-wide" href="/staff/field/help" data-testid="help-find"><FdIcon name="search" />Help a renter: find a booking</Link></p>}
      {list && (list.vehicles.length > 0 || list.moves.length > 0) && <section className="fd-card fd-moves" aria-labelledby="moves-t">
        <h2 className="fd-section-h" id="moves-t">Moving a car</h2>
        {list.moves.map((m) => <div key={m.id} className="fd-move">
          <p className="fd-move__what"><FdIcon name="car" /><span><b>{m.vehicle_name}</b><span className="small"> on the move since {when(m.started_at)}{m.from_place ? `, from ${m.from_place}` : ''}</span></span></p>
          <FieldButton action="move_end" payload={{ move: m.id }} label="End the move" sheet={{ confirm: 'End the move now', title: `End the move: ${m.vehicle_name}` }} primary testId="move-end" fields={[{ name: 'to_place', label: 'Now at', address: true }, { name: 'odometer', label: 'Odometer (km)', numeric: true }]} /></div>)}
        {list.vehicles.length > 0 && <FieldButton action="move_start" payload={{}} label="Start a move" sheet={{ confirm: 'Start the move now', title: 'Start a move' }} testId="move-start" fields={[{ name: 'vehicle', label: 'Car', options: list.vehicles.map((v) => [v.id, v.name] as [string, string]) },
          { name: 'purpose', label: 'Why', options: [['repositioning', 'Reposition'], ['service', 'Service or repair'], ['detail', 'To the detailer'], ['other', 'Other']] }, { name: 'from_place', label: 'From', address: true }, { name: 'odometer', label: 'Odometer (km)', numeric: true }]} />}
      </section>}
      <p className="small fp-links"><Link prefetch={false} className="link" href="/staff/field/now">Cars now</Link> · <Link prefetch={false} className="link" href="/staff/field/map">Map of your cars</Link>
        {tk.phone ? <> · <a className="link" href={tel(tk.phone)}>Call CarmaCars, {tk.phone}</a></> : null}</p>
      {!tomorrow && <AddButton cars={cars} bookings={bookings} reportCars={report.vehicles} preps={preps} startOpen={sp.add === 'problem' ? 'problem' : sp.add === 'money' ? 'money' : null} />}
    </>
  );
}
