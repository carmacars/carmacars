import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { BookingLink, Card, Kv, PageHead, t } from '@/features/admin/ui';
import '@/features/visitors/history.css';
import { CONVERSION_WORDS, DEVICE_WORDS, EVENT_WORDS, clockS, duration, place, sourceWords, type VisitDetail } from '@/features/visitors/history';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'A visit', path: '/admin/live/history', noindex: true, description: 'One visit to the site in full.' });

const ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const SENDER: Record<string, string> = { visitor: 'Visitor', ai: 'Assistant', staff: 'Staff', system: 'Note' };

// Today > Visitor history > a visit (migration 0118): the pages in order with the time on each, the other actions,
// the games, chats and forms of the visit, and the renter, leads and bookings it is linked to.
export default async function Visit({ params }: { params: Promise<{ id: string }> }) {
  const [{ read }, { id }] = await Promise.all([page('/admin/live/history'), params]);
  if (!ID.test(id)) notFound();
  let v: VisitDetail;
  try { v = await read<VisitDetail>('visitor_visit', { id }); } catch (e) {
    if (e instanceof Error && /no longer kept/.test(e.message)) {
      return (<><PageHead title="Visit not kept" kicker={<Link prefetch={false} className="link" href="/admin/live/history">Visitor history</Link>} />
        <p className="ad-empty" data-testid="vh-gone">That visit is no longer kept. Visits are deleted after the days set in Settings &gt; Program.</p></>);
    }
    throw e;
  }
  const pages = v.timeline.filter((x) => x.is_page);
  return (
    <>
      <PageHead title={v.who} kicker={<Link prefetch={false} className="link" href="/admin/live/history">Visitor history</Link>}>
        {v.renter && <Link prefetch={false} className="btn btn--ghost btn--sm" href={`/admin/renters/${v.renter.id}`}>Renter page</Link>}
      </PageHead>
      <Card title="The visit" testId="vh-visit">
        <Kv rows={[
          ['When', `${t(v.started_at)} to ${clockS(v.last_seen_at)}`],
          ['Length', `${duration(v.duration_s)}, ${v.page_views} ${v.page_views === 1 ? 'page' : 'pages'}${v.cars_viewed ? `, ${v.cars_viewed} ${v.cars_viewed === 1 ? 'car' : 'cars'}` : ''}`],
          ['Came from', <span key="s" data-testid="vh-source">{sourceWords(v)}{v.referrer && v.utm_source ? ` (via ${v.referrer})` : ''}</span>],
          ['Entry page', v.landing_path ? `${v.landing ?? ''} (${v.landing_path})` : 'Not recorded'],
          ['Exit page', v.exit_path ? `${v.exit ?? ''} (${v.exit_path})` : 'Not recorded'],
          ['Device', v.device ? DEVICE_WORDS[v.device] : 'Not known'],
          ['Approximate location', place(v) || 'Not known'],
          ['Visitor', `${v.returning ? `Returning, visit ${v.visit_number}` : 'First visit'}${v.other_visits.count > 1 ? ` (${v.other_visits.count} visits kept from this browser)` : ''}`],
          ['Cookies', v.consent === 'analytics' ? 'Analytics accepted' : 'Necessary only (only their own booking pages and the chat are recorded)'],
          ['Led to', v.conversions.length ? v.conversions.map((c) => CONVERSION_WORDS[c]).join(', ') : v.summarized ? 'Nothing recorded' : 'Worked out 30 minutes after the visit'],
          ['Contact', v.has_contact ? (v.email ?? 'On file') : 'None'],
          ['Left out of the totals', v.exclude_reason === 'bot' ? 'Yes: looks automated' : v.exclude_reason === 'staff' ? 'Yes: a staff account' : ''],
          ['Booking likelihood', v.score !== null ? String(v.score) : ''],
          ['Assigned to', v.assigned ?? '']
        ]} />
      </Card>

      {(v.renter || v.bookings.length > 0 || v.forms.some((x) => x.lead_id) || v.chats.length > 0) && (
        <Card title="Linked records" testId="vh-linked">
          <ul className="small">
            {v.renter && <li>Renter: <Link prefetch={false} className="link" href={`/admin/renters/${v.renter.id}`}>{v.renter.name}</Link>{v.signed_in ? ' (signed in)' : ''}</li>}
            {v.bookings.map((b) => <li key={b.number}>Booking <BookingLink n={b.number} />: {b.status.replace(/_/g, ' ')}{b.booked_at ? `, confirmed ${t(b.booked_at)}` : `, requested ${t(b.requested_at)}`}</li>)}
            {v.forms.some((x) => x.lead_id) && <li>Lead: <Link prefetch={false} className="link" href="/admin/leads">Bookings &gt; Leads</Link></li>}
            {v.chats.map((c) => <li key={c.id}>Chat <Link prefetch={false} className="link" href={`/admin/chat?id=${c.id}`}>{c.number}</Link></li>)}
          </ul>
        </Card>
      )}

      <Card title={`Pages and actions${pages.length ? ` (${pages.length} pages)` : ''}`} testId="vh-timeline">
        {!v.pages_kept && <p className="small muted" data-testid="vh-pages-gone">Pages viewed are kept {v.pages_keep_days} days; this visit is older, so only its summary is left.</p>}
        {v.timeline.length > 0 ? (
          <ol className="vh-timeline">
            {v.timeline.map((x, i) => (
              <li key={i} className={x.is_page ? 'is-page' : undefined} data-testid={x.is_page ? 'vh-page' : 'vh-event'}>
                <time dateTime={x.at}>{clockS(x.at)}</time>
                <span>{EVENT_WORDS[x.kind] ?? x.kind}{x.is_page && x.page ? ` ${x.page}` : ''}{x.car ? `: ${x.car}` : ''}{x.detail ? `: ${x.detail}` : ''}
                  {x.pickup ? `, ${x.pickup.replace('T', ' ')}${x.return ? ` to ${x.return.replace('T', ' ')}` : ''}` : ''}{x.booking_number ? `, ${x.booking_number}` : ''}
                  {x.path && x.is_page ? <> <span className="vh-path">{x.path}</span></> : null}</span>
                <span className="num">{x.seconds !== null ? duration(x.seconds) : ''}</span>
              </li>))}
          </ol>) : v.pages_kept && <p className="small muted">No pages recorded for this visit.</p>}
        {capNote(v)}
      </Card>

      {v.games.length > 0 && (
        <Card title="Discount games" testId="vh-games">
          <ul className="small">{v.games.map((g, i) => <li key={i}>{t(g.at)}: {g.game.replace(/_/g, ' ')}{g.prize ? `, ${g.prize}` : ''}{g.revealed_at ? `, revealed ${clockS(g.revealed_at)}` : ', not played to the end'}{g.claimed_at ? `, claimed${g.code ? ` (code ${g.code})` : ''}` : ''}</li>)}</ul>
        </Card>)}

      {v.chats.length > 0 && (
        <Card title="Chats" testId="vh-chats">
          {v.chats.map((c) => (
            <div key={c.id}>
              <p className="small"><Link prefetch={false} className="link" href={`/admin/chat?id=${c.id}`}>{c.number}</Link>, {t(c.at)}, {c.messages} {c.messages === 1 ? 'message' : 'messages'}</p>
              {c.first.map((m, i) => <p key={i} className="vh-chatmsg"><b>{SENDER[m.sender] ?? m.sender}</b> <span className="muted">{clockS(m.at)}</span>: {m.body}</p>)}
            </div>))}
        </Card>)}

      {v.forms.length > 0 && (
        <Card title="Forms" testId="vh-forms">
          <ul className="small">{v.forms.map((x, i) => <li key={i}>{x.form}: started {clockS(x.first_at)}, {x.sent ? 'sent' : 'not sent'}{[x.name, x.email, x.phone].some(Boolean) ? ` (${[x.name, x.email, x.phone].filter(Boolean).join(', ')})` : ''}</li>)}</ul>
        </Card>)}

      {v.other_visits.recent.length > 0 && (
        <Card title="Other visits from this browser" testId="vh-others">
          <ul className="small">{v.other_visits.recent.map((o) => <li key={o.id}><Link prefetch={false} className="link" href={`/admin/live/history/${o.id}`}>{t(o.started_at)}</Link>, {o.page_views} {o.page_views === 1 ? 'page' : 'pages'}{o.conversions.length ? `: ${o.conversions.map((c) => CONVERSION_WORDS[c]).join(', ')}` : ''}</li>)}</ul>
        </Card>)}
    </>
  );
}

function capNote(v: VisitDetail) {
  return v.timeline.length >= 300 ? <p className="small muted">The first 300 pages and actions are shown.</p> : null;
}
