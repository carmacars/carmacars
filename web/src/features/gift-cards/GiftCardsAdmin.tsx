import Link from '@/components/Link';
import { Act, type Field } from '@/features/admin/Act';
import { $, Badge, PageHead, Table, t } from '@/features/admin/ui';
import { ListFilters } from '@/features/list-filters/ListFilters';
import { cardState, ledgerText, type GiftCardRow } from './model';
import './gift-cards.css';

// Money > Gift cards (migration 3600), for Admins and Finance: the liability (what CarmaCars owes in rentals on cards
// sold for money), vouchers given, the last 30 days, every card with search, and one card's balance history. Admins also
// issue a voucher (an amount, or a percentage as a promo code), void a card with the reason and resend the email. The
// database checks every read and action (app.gift_cards_admin and the door); Finance sees no Issue, Void or Resend.
export interface GiftAdminData {
  summary: { liability_cents: number; liability_count: number; voucher_cents: number; sold_30d_cents: number; redeemed_30d_cents: number; waiting_to_send: number };
  rows: GiftCardRow[]; can_issue: boolean; voucher_max_cents: number;
}
type R = GiftCardRow & Record<string, unknown>;

const ISSUE: Field[] = [
  { name: 'type', label: 'Kind', type: 'select', required: true, value: 'amount', options: [['amount', 'An amount (a credit that keeps its remainder)'], ['percent', 'A percentage off (a promo code)']] },
  { name: 'amount_cents', label: 'Amount ($), for an amount', type: 'money' },
  { name: 'percent_bps', label: 'Percentage off, for a percentage', type: 'percent' },
  { name: 'max_uses', label: 'Most uses, for a percentage (empty: no limit)', type: 'number', min: 1, max: 10000 },
  { name: 'code', label: 'Code, for a percentage (empty: one is made)' },
  { name: 'recipient_name', label: 'For (name)' },
  { name: 'recipient_email', label: 'Their email (we email it; a percentage is then theirs alone)', type: 'email' },
  { name: 'message', label: 'Message to them', type: 'textarea' },
  { name: 'expires_on', label: 'Ends on (optional: a voucher given free may end)', type: 'date' },
  { name: 'reason', label: 'Why (kept with the voucher)', required: true, type: 'textarea' }
];

export function GiftCardsAdmin({ data, base, history, sp }: { data: GiftAdminData; base: string; history: (GiftCardRow & { history: NonNullable<GiftCardRow['history']> }) | null; sp: Record<string, string | undefined> }) {
  const s = data.summary;
  const refresh = [base.split('?')[0]!];
  const stats: Array<[string, string, string]> = [
    ['liability', $(s.liability_cents), `Owed in rentals on ${s.liability_count} ${s.liability_count === 1 ? 'card' : 'cards'} sold (a liability until used)`],
    ['vouchers', $(s.voucher_cents), 'Voucher credit given free, unused'],
    ['sold', $(s.sold_30d_cents), 'Sold in the last 30 days'],
    ['redeemed', $(s.redeemed_30d_cents), 'Used on bookings in the last 30 days'],
    ['waiting', String(s.waiting_to_send), 'Paid, waiting for their send date']
  ];
  return (
    <>
      <PageHead title="Gift cards" purpose="Gift cards and gifted rentals sold online, and vouchers given. A card sold for money never expires; its balance is a liability until it pays for a rental.">
        {data.can_issue && <Act action="gift_card_issue" label="Issue a voucher" variant="primary" fields={ISSUE} refresh={refresh} done="Voucher issued." testId="gift-issue" />}
      </PageHead>
      <div className="gc-stats" data-testid="gift-stats">
        {stats.map(([k, v, l]) => <div key={k} className="gc-stat" data-key={k}><b>{v}</b><small>{l}</small></div>)}
      </div>
      <ListFilters id="gift-cards" base={base} sp={sp} search={{ placeholder: 'Code, last four, name or email' }}
        chips={{ name: 'status', label: 'Status', value: sp.status ?? '', options: [['', 'All'], ['active', 'Active'], ['voided', 'Voided'], ['pending_payment', 'Not paid']] }} />
      {history && (
        <section className="pt-card stack" aria-labelledby="gift-hist-h" data-testid="gift-history">
          <h2 className="d4" id="gift-hist-h">{history.kind_label} ending {history.code_last4}: {$(history.balance_cents)} of {$(history.initial_cents)}</h2>
          <p className="small muted">{history.code} for {history.recipient_name}{history.recipient_email ? ` (${history.recipient_email})` : ''}. {history.buyer_name ? `From ${history.buyer_name}${history.buyer_email ? ` (${history.buyer_email})` : ''}` : ''}{history.card_text ? `, paid with ${history.card_text}` : ''}{history.issue_reason ? `. Why: ${history.issue_reason}` : ''}{history.void_reason ? `. Voided by ${history.voided_by_name ?? 'an Admin'}: ${history.void_reason}` : ''}</p>
          <Table<R & { at: string }> testId="gift-history-rows" sort={false} rows={history.history as unknown as Array<R & { at: string }>} empty="No balance changes yet."
            cols={[{ key: 'at', label: 'When', render: (r) => t(r.at) }, { key: 'kind', label: 'What', render: (r) => ledgerText(r as never, (c) => $(c)).label },
              { key: 'amount_cents', label: 'Amount', num: true, render: (r) => ledgerText(r as never, (c) => $(c)).amount }, { key: 'balance_after_cents', label: 'Balance', num: true, render: (r) => $(r.balance_after_cents) },
              { key: 'by_name', label: 'By' }, { key: 'reason', label: 'Note', className: 'wrap' }]} />
          <p><Link prefetch={false} className="link" href={base}>Close</Link></p>
        </section>)}
      <Table<R> testId="gift-cards" rows={data.rows as R[]} empty="No gift cards yet. A card sold on /gift-cards, or a voucher you issue, shows here."
        cols={[{ key: 'created_at', label: 'Made', render: (r) => t(r.paid_at ?? r.created_at) },
          { key: 'code_last4', label: 'Card', render: (r) => <Link prefetch={false} className="link" href={`${base}${base.includes('?') ? '&' : '?'}card=${r.id}`} data-testid="gift-open" data-guide="gift-open">{r.kind_label} {r.code_last4}</Link> },
          { key: 'recipient_name', label: 'For', className: 'wrap', render: (r) => <>{r.recipient_name}{r.recipient_email ? <><br /><span className="small muted">{r.recipient_email}</span></> : null}</> },
          { key: 'buyer_name', label: 'From', className: 'wrap' },
          { key: 'initial_cents', label: 'Amount', num: true, render: (r) => $(r.initial_cents) },
          { key: 'balance_cents', label: 'Balance', num: true, render: (r) => $(r.balance_cents) },
          { key: 'status', label: 'Status', render: (r) => <Badge s={r.status === 'active' ? (r.balance_cents > 0 ? 'active' : 'closed') : r.status}>{cardState(r)}</Badge> },
          { key: 'act', label: '', render: (r) => data.can_issue && r.status === 'active' ? (
            <span className="ad-actions">
              {r.recipient_email && <Act action="gift_card_resend" payload={{ id: r.id }} label="Resend" refresh={refresh} done="Sent again." confirm={`Email the gift card to ${r.recipient_email} again.`} />}
              <Act action="gift_card_void" payload={{ id: r.id }} label="Void" fields={[{ name: 'reason', label: 'Why (kept with the card)', required: true, type: 'textarea' }]} refresh={refresh} done="Voided." testId="gift-void" />
            </span>) : null }]} />
    </>
  );
}
