import Link from '@/components/Link';
import { Badge, Card, Table, t } from '@/features/admin/ui';
import { ContactButtons } from '@/features/phone/QuoButtons';
import { LeadPhoneAccess } from '@/features/sales-leads/LeadPhone';
import type { LeadRow } from '@/features/sales-leads/model';

// r33 (migration 0741): offers that expired a week ago or more left Requests and offers and are renter leads here: the contact, the car and the dates
// they wanted, who has the lead (Sales, the one with the fewest open leads) and its follow-up To do. Once per booking.
export type ExpiredLead = { id: string; created_at: string; name: string | null; email: string | null; phone: string | null; vehicle_text: string | null; status: string; assigned_to: string | null;
  payload: { booking_number?: string; pickup_at?: string; return_at?: string } | null };

/** 2870: each lead's owner, claim and phone facts (lead_phone_state), for Show the phone and Hide it again */
export type LeadPhoneState = Record<string, Pick<LeadRow, 'id' | 'phone' | 'assigned_to' | 'assigned_name' | 'claim' | 'phone_unlocks' | 'phone_unlocked' | 'phone_ask_open'>>;

export function ExpiredOfferLeads({ rows, count, phones = {} }: { rows: ExpiredLead[]; count: number; phones?: LeadPhoneState }) {
  return (
    <Card title={`Expired offers (${count})`} testId="expired-offer-leads">
      <p className="small muted">An offer that expired a week ago or more leaves Requests and offers and comes here, once, with the car and the dates the renter wanted. Sales has a To do to win them back.</p>
      <Table rows={rows} rowKey={(r) => r.id} empty="No expired offers yet." cols={[
        { key: 'created_at', label: 'Became a lead', render: (r) => t(r.created_at) },
        { key: 'name', label: 'Renter', render: (r) => r.name ?? 'No name' },
        { key: 'email', label: 'Email', render: (r) => (r.email ? <a className="link" href={`mailto:${r.email}`}>{r.email}</a> : '') },
        { key: 'phone', label: 'Phone', render: (r) => (r.phone ? <>
          <ContactButtons phone={r.phone} name={r.name} look="link" testId="eol-num">{r.phone}</ContactButtons>
          {(() => { const st = phones[r.id]; return st ? <LeadPhoneAccess lead={st} admin compact /> : null; })()}</> : '') },
        { key: 'vehicle_text', label: 'Car wanted' },
        { key: 'dates', label: 'Dates', render: (r) => `${(r.payload?.pickup_at ?? '').slice(0, 10)} to ${(r.payload?.return_at ?? '').slice(0, 10)}` },
        { key: 'status', label: 'Lead', render: (r) => <Badge s={r.status} /> },
        { key: 'booking', label: '', render: (r) => (r.payload?.booking_number ? <Link prefetch={false} className="link small" href={`/admin/bookings/${encodeURIComponent(r.payload.booking_number)}`}>{r.payload.booking_number}</Link> : '') }
      ]} />
    </Card>
  );
}
