import Link from '@/components/Link';
import { Badge, $, d, t } from '@/features/admin/ui';
import { contextLine, DEPOSIT_WORDS, owedWords, signalGroup, type LeadContext, type Signal } from './model';

const GROUP_LABEL: Record<string, string> = { talk: 'Talked', site: 'On the site', money: 'Booked', lead: 'Lead' };
const ROLE_LABEL: Record<string, string> = { renter: 'Renter', owner: 'Owner', partner: 'Partner', investor: 'Investor', staff: 'Staff' };

function Section({ title, n, children, testId, open = false }: { title: string; n?: number; children: React.ReactNode; testId: string; open?: boolean }) {
  return (
    <details className="rc-sec" data-testid={testId} open={open}>
      <summary><b>{title}</b>{n !== undefined && <span className="muted"> ({n})</span>}</summary>
      <div className="rc-sec__body">{children}</div>
    </details>
  );
}
const None = ({ what }: { what: string }) => <p className="small muted">{what}</p>;

/** The signals timeline: everything the person did with us, newest first (app.person_signals). */
export function SignalTimeline({ items }: { items: Signal[] }) {
  if (!items.length) return <None what="No calls, texts, messages, visits or bookings yet." />;
  return (
    <ol className="rc-list" data-testid="rc-signals">
      {items.map((s, i) => (
        <li key={`${s.at}-${i}`} className="small" data-group={signalGroup(s.type)}>
          <span className="muted">{t(s.at)}</span> <span className="badge badge--outline">{GROUP_LABEL[signalGroup(s.type)]}</span> <b>{s.title}</b>{s.detail ? <>: {s.detail}</> : null}
        </li>))}
    </ol>
  );
}

/** The whole person behind a lead (read lead_context, migration 2411), on the lead page and under a lead card's Renter button,
 *  the same for an Admin and staff. `portal` is /admin or /staff, for the booking and renter links. */
export function RenterContext({ c, portal, renterLink = true }: { c: LeadContext; portal: '/admin' | '/staff'; /** the viewer may open Find a renter (Admin, CS, Finance, Fleet; not Sales) */ renterLink?: boolean }) {
  const owed = owedWords(c.balance ?? null, $);
  const name = c.contact.preferred_name && c.contact.preferred_name !== c.contact.name ? `${c.contact.name ?? ''} (goes by ${c.contact.preferred_name})` : c.contact.name;
  const renterHref = c.renter_id && renterLink ? (portal === '/admin' ? `/admin/renters/${c.renter_id}` : `/staff/renters?id=${c.renter_id}`) : null;
  return (
    <section className="rc stack" aria-label="The person behind this lead" data-testid="renter-context" data-full={c.full ? 'true' : 'false'}>
      <div className="rc-head">
        <p className="small"><b data-testid="rc-name">{name || 'No name'}</b>{renterHref && <> · <Link prefetch={false} className="link" href={renterHref}>Renter record</Link></>}</p>
        <p className="small muted" data-testid="rc-line">{contextLine(c)}{c.roles.length ? ` · ${c.roles.map((r) => ROLE_LABEL[r] ?? r).join(', ')}` : ''}</p>
        <p className="small" style={{ overflowWrap: 'anywhere' }}>{[c.contact.phone, c.contact.email, c.contact.city].filter(Boolean).join(' · ') || <span className="muted">No phone or email</span>}</p>
        <p className="small" data-testid="rc-account">
          Account: {c.account.has_sign_in ? (c.account.email_confirmed ? 'signed up, email confirmed' : 'signed up, email not confirmed') : 'none'}
          {c.account.renter && <> · Licence verified: <b data-testid="rc-licence">{c.account.licence_verified ? 'yes' : 'no'}</b></>}
          {c.account.since && <> · since {d(c.account.since)}</>}
          {c.account.blocked && <> · <span className="badge badge--red">Blocked</span></>}
        </p>
        {c.intent && c.intent.label !== 'unknown' && <p className="small" data-testid="rc-intent">Intent: <b>{c.intent.label} ({c.intent.score})</b>{c.intent.reasons?.length ? <span className="muted"> · {c.intent.reasons.slice(0, 4).map((r) => r.label).join(', ')}</span> : null}</p>}
      </div>
      {!c.full ? <p className="small muted" data-testid="rc-limited">{c.why_limited}</p> : <>
        {(owed || c.deposit) && <p className="small" data-testid="rc-money">{owed ? <b className="rc-red">{owed}</b> : 'Nothing owed'}{c.deposit && <> · Deposit: {DEPOSIT_WORDS[c.deposit.state] ?? c.deposit.state}{c.deposit.held_cents ? ` (${$(c.deposit.held_cents)})` : ''}</>}</p>}
        <Section title="Bookings" n={c.bookings?.length ?? 0} testId="rc-bookings" open={!!c.bookings?.length}>
          {c.bookings?.length ? <ul className="rc-list">{c.bookings.map((b) => (
            <li key={b.number} className="small"><Link prefetch={false} className="link" href={`${portal}/bookings/${encodeURIComponent(b.number)}`}>{b.number}</Link> {b.upcoming && <span className="badge badge--outline">Upcoming</span>} <Badge s={b.status} /> {b.car ?? ''} · {d(b.pickup_at)} to {d(b.return_at)}{b.total_cents ? ` · ${$(b.total_cents)}` : ''}{b.open_cents ? <b className="rc-red"> · {$(b.open_cents)} open</b> : null}</li>))}</ul>
            : <None what="No bookings." />}
        </Section>
        <Section title="Signals" n={c.signals?.length ?? 0} testId="rc-signals-sec" open>
          <SignalTimeline items={c.signals ?? []} />
        </Section>
        <Section title="Earlier leads and requests" n={(c.leads?.filter((l) => !l.this).length ?? 0) + (c.requests?.length ?? 0) + (c.offers?.length ?? 0)} testId="rc-leads">
          {!!c.requests?.length && <ul className="rc-list">{c.requests.map((r, i) => <li key={i} className="small"><b>{r.label}</b>{r.booking_number ? ` · ${r.booking_number}` : ''} · {t(r.at)}</li>)}</ul>}
          {!!c.offers?.length && <ul className="rc-list" data-testid="rc-offers">{c.offers.map((o) => <li key={`${o.booking}-${o.version}`} className="small">Offer {o.booking} v{o.version}: <Badge s={o.status} /> {o.car ?? ''}{o.total_cents ? ` · ${$(o.total_cents)}` : ''}{o.sent_at ? ` · sent ${t(o.sent_at)}` : ''}{o.by ? ` by ${o.by}` : ''}</li>)}</ul>}
          {c.leads?.filter((l) => !l.this).length ? <ul className="rc-list">{c.leads.filter((l) => !l.this).map((l) => (
            <li key={l.id} className="small"><Link prefetch={false} className="link" href={`${portal}/sales-leads/${l.id}`}>{l.source}</Link> · {t(l.at)} · {l.outcome ?? (l.handled ? 'handled' : l.status)}{l.excerpt ? <span className="muted">: {l.excerpt}</span> : null}</li>))}</ul>
            : !c.requests?.length && !c.offers?.length && <None what="This is their first lead." />}
        </Section>
        <Section title="Messages, calls and texts" n={c.activity?.length ?? 0} testId="rc-activity">
          {c.activity?.length ? <ul className="rc-list">{c.activity.map((a, i) => <li key={i} className="small"><span className="muted">{t(a.at)}</span> <b>{a.title}</b>{a.by ? ` (${a.by})` : ''}{a.body ? <>: {a.body.slice(0, 240)}</> : null}</li>)}</ul>
            : <None what="Nothing on their renter record yet; the lead's own calls and chat are above." />}
          {renterHref && <p className="small"><Link prefetch={false} className="link" href={renterHref}>Their full activity log</Link></p>}
        </Section>
        <Section title="Notes, reviews, incidents" n={(c.notes?.length ?? 0) + (c.reviews?.length ?? 0) + (c.incidents?.length ?? 0) + (c.staff_note ? 1 : 0)} testId="rc-notes">
          {c.staff_note && <p className="small"><b>Staff note:</b> {c.staff_note}</p>}
          {c.notes?.length ? <ul className="rc-list">{c.notes.map((n) => <li key={n.id} className="small"><span className="muted">{t(n.at)} · {n.author}</span>: {n.body}</li>)}</ul> : <None what="No notes." />}
          {!!c.reviews?.length && <ul className="rc-list" data-testid="rc-reviews">{c.reviews.map((r, i) => <li key={i} className="small">{'★'.repeat(r.rating)}<span className="vh">{r.rating} stars</span> {r.title ?? ''}{r.booking ? ` · ${r.booking}` : ''} · {d(r.at)}{r.body ? <span className="muted">: {r.body}</span> : null}</li>)}</ul>}
          {!!c.incidents?.length && <ul className="rc-list" data-testid="rc-incidents">{c.incidents.map((x) => <li key={x.number} className="small">Incident {x.number} ({x.kind}) on {x.booking}: <Badge s={x.status} />{x.claims.length ? ` · claims ${x.claims.map((k) => `${k.number} ${k.status}`).join(', ')}` : ''}</li>)}</ul>}
        </Section>
        <Section title="Who has handled them" n={c.handled_by?.length ?? 0} testId="rc-handled">
          {c.handled_by?.length ? <ul className="rc-list" data-testid="rc-helped-by">{c.handled_by.map((h) => <li key={h.id} className="small"><b>{h.name}</b>: {h.what.join(', ')}</li>)}</ul> : <None what="Nobody yet." />}
        </Section>
      </>}
    </section>
  );
}
