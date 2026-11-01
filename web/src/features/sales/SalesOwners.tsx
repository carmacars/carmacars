import Link from 'next/link';
import { $ } from '@/features/admin/ui';
import { AskCommission, CopyLink, InviteOwner } from './SalesOwnersClient';

// Owners you bring in (migration 0340), on My sales for Sales staff: invite an owner (their own link, or the form that sends
// it) or start the application for them; the pipeline (invited, applied, approved, car live, first paid rental); and for
// each owner the commission they ask for, which an Admin approves. Only their own owners, by name and car: no contact
// details, terms or revenue of the owner.
export type OwnerStage = 'invited' | 'lead' | 'lost' | 'applied' | 'declined' | 'approved' | 'car_live' | 'first_paid_rental';
export interface OwnerRequest {
  id: string; status: 'pending' | 'approved' | 'declined'; kind: 'flat' | 'percent'; amount_cents: number | null; rate_bps: number | null; base: 'company_share' | 'car_revenue' | null;
  months: number | null; while_enrolled: boolean; note: string | null; asked: string; approved: string | null; changed: boolean; admin_note: string | null; decided_at: string | null;
}
export interface SalesOwnerRow { owner_id: string; name: string; since: string; stage: OwnerStage; blocked: string | null; cars: Array<{ name: string | null; live: boolean }>;
  request: OwnerRequest | null; earned_cents: number; paid_cents: number }
export interface SalesOwnersData {
  counts: Record<'invited' | 'applied' | 'approved' | 'car_live' | 'first_paid_rental', number>;
  owners: SalesOwnerRow[]; invites: Array<{ lead_id: string; name: string; email: string; since: string; stage: 'invited' | 'lead' | 'lost' }>;
}

export const STAGE_LABEL: Record<OwnerStage, string> = { invited: 'Invited', lead: 'Lead', lost: 'Closed', applied: 'Applied', declined: 'Application declined', approved: 'Approved', car_live: 'Car live', first_paid_rental: 'First paid rental' };
const STEPS: Array<[keyof SalesOwnersData['counts'], string]> = [['invited', 'Invited'], ['applied', 'Applied'], ['approved', 'Approved'], ['car_live', 'Car live'], ['first_paid_rental', 'First paid rental']];

const day = (iso: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', month: 'short', day: 'numeric' }).format(new Date(iso));

function requestLine(r: OwnerRequest | null): { text: string; tone: 'ok' | 'red' | '' } {
  if (!r) return { text: 'No commission asked yet', tone: '' };
  if (r.status === 'pending') return { text: `Asked: ${r.asked}. Waiting for an Admin.`, tone: '' };
  if (r.status === 'declined') return { text: `Declined${r.admin_note ? `: ${r.admin_note}` : ''}`, tone: 'red' };
  return { text: `Approved: ${r.approved}${r.changed ? ` (you asked ${r.asked})` : ''}${r.admin_note ? `. ${r.admin_note}` : ''}`, tone: 'ok' };
}

export function SalesOwners({ data, link }: { data: SalesOwnersData; link: string }) {
  const rows = [...data.invites.map((i) => ({ key: `l-${i.lead_id}`, invite: i, owner: null as SalesOwnerRow | null, since: i.since })),
    ...data.owners.map((o) => ({ key: `o-${o.owner_id}`, invite: null, owner: o, since: o.since }))].sort((a, b) => b.since.localeCompare(a.since));
  return (
    <section className="pt-card ad-card so" id="owners" aria-labelledby="so-title" data-testid="sales-owners">
      <div className="pt-card__head"><h2 className="d4" id="so-title">Owners you bring in</h2></div>
      <p className="small muted so__lead">Invite a car owner or start their application. Each owner is credited to you; ask for your commission on each one and an Admin approves it.</p>
      <ol className="so-funnel" aria-label="Your owners by stage" data-testid="so-funnel">
        {STEPS.map(([k, l]) => <li key={k} data-testid={`so-count-${k}`}><b>{data.counts[k] ?? 0}</b><span>{l}</span></li>)}
      </ol>
      <div className="so-actions">
        <InviteOwner />
        <Link prefetch={false} className="btn btn--sm btn--ghost" href="/staff/owners/add-car" data-testid="so-start">Start an application</Link>
        <CopyLink url={link} />
      </div>
      {rows.length ? (
        <ul className="so-list" data-testid="so-list">
          {rows.map((r) => {
            if (r.invite) return (
              <li key={r.key} className="so-row" data-testid="so-invite">
                <div className="so-row__main"><b>{r.invite.name}</b><span className="small muted">{r.invite.email}</span></div>
                <span className={`ad-pill${r.invite.stage === 'lost' ? ' ad-pill--red' : ''}`}>{STAGE_LABEL[r.invite.stage]}</span>
                <div className="so-row__pay"><span className="small muted">{r.invite.stage === 'lead' ? `Your lead since ${day(r.invite.since)}. Not applied yet.` : `Invitation sent ${day(r.invite.since)}. Waiting for them to apply.`}</span></div>
              </li>);
            const o = r.owner!;
            const line = requestLine(o.request);
            const cars = o.cars.map((c) => c.name).filter(Boolean).join(', ');
            return (
              <li key={r.key} className="so-row" data-testid={`so-owner-${o.owner_id}`}>
                <div className="so-row__main"><b>{o.name}</b><span className="small muted">{cars || 'No car yet'}</span></div>
                <span className={`ad-pill${o.stage === 'first_paid_rental' || o.stage === 'car_live' ? ' ad-pill--ok' : o.stage === 'declined' ? ' ad-pill--red' : ''}`} data-testid="so-stage">{STAGE_LABEL[o.stage]}</span>
                <div className="so-row__pay">
                  {o.blocked ? <span className="small muted">{o.blocked}</span> : <>
                    <span className={`small${line.tone === 'red' ? ' so-red' : ''}`} data-testid="so-request">{line.text}{o.earned_cents ? <> · <b>{$(o.earned_cents)}</b> earned</> : null}</span>
                    {(!o.request || o.request.status === 'pending') && <AskCommission ownerId={o.owner_id} ownerName={o.name} current={o.request} />}
                  </>}
                </div>
              </li>);
          })}
        </ul>
      ) : <p className="small muted" data-testid="so-empty">No owners yet. Invite one, or start an application for an owner you met.</p>}
    </section>
  );
}
