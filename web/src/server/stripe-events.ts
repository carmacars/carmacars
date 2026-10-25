// The Stripe events the site records beyond its own PaymentIntents (migration 0132): refunds settling or failing, a
// refund made in Stripe's dashboard, disputes (chargebacks) and a charge the bank wants confirmed. Pure: the webhook
// route calls the database function this names, with these arguments; the unit test checks the mapping.
type Obj = Record<string, unknown>;
const str = (v: unknown): string | null => (typeof v === 'string' && v ? v : v && typeof v === 'object' && typeof (v as Obj).id === 'string' ? String((v as Obj).id) : null);
const num = (v: unknown): number | null => (typeof v === 'number' && Number.isFinite(v) ? v : null);
const meta = (o: Obj) => (o.metadata && typeof o.metadata === 'object' ? (o.metadata as Record<string, string>) : {});

export interface StripeCall { fn: 'server_stripe_refund_event' | 'server_stripe_dispute_event' | 'server_stripe_requires_action'; p: Record<string, unknown> }

/** The database calls an event makes (none: not one of these). */
export function stripeEventCalls(type: string, o: Obj): StripeCall[] {
  if ((type === 'refund.updated' || type === 'refund.created' || type === 'charge.refund.updated') && o.object === 'refund') {
    return [{ fn: 'server_stripe_refund_event', p: { refund_id: str(o.id), status: o.status, amount_cents: num(o.amount), intent_id: str(o.payment_intent), charge_id: str(o.charge),
      site_refund_id: meta(o).refund_id ?? null, failure_reason: o.failure_reason ?? null } }];
  }
  if (type === 'charge.refunded' && o.object === 'charge') {
    const list = o.refunds && typeof o.refunds === 'object' && Array.isArray((o.refunds as Obj).data) ? ((o.refunds as Obj).data as Obj[]) : [];
    if (list.length) return list.map((r) => ({ fn: 'server_stripe_refund_event' as const, p: { refund_id: str(r.id), status: r.status, amount_cents: num(r.amount), intent_id: str(o.payment_intent),
      charge_id: str(o.id), site_refund_id: meta(r).refund_id ?? null, failure_reason: r.failure_reason ?? null } }));
    // newer API versions leave the list out: the amount refunded so far stands for it, once per amount
    return [{ fn: 'server_stripe_refund_event', p: { refund_id: `${str(o.id)}:${num(o.amount_refunded) ?? 0}`, status: 'succeeded', amount_cents: num(o.amount_refunded), intent_id: str(o.payment_intent), charge_id: str(o.id) } }];
  }
  if (type.startsWith('charge.dispute.') && o.object === 'dispute') {
    const due = o.evidence_details && typeof o.evidence_details === 'object' ? num((o.evidence_details as Obj).due_by) : null;
    return [{ fn: 'server_stripe_dispute_event', p: { dispute_id: str(o.id), status: o.status, amount_cents: num(o.amount), reason: o.reason ?? null, intent_id: str(o.payment_intent),
      charge_id: str(o.charge), evidence_due_at: due ? new Date(due * 1000).toISOString() : null } }];
  }
  // only a charge the site made off session (a saved card): on the pay page the renter confirms it there and then
  if (type === 'payment_intent.requires_action' && o.object === 'payment_intent' && meta(o).purpose === 'staff_charge') {
    return [{ fn: 'server_stripe_requires_action', p: { intent_id: str(o.id), payment_id: meta(o).payment_id ?? null } }];
  }
  return [];
}

/** The events the webhook endpoint subscribes to (scripts/deploy/supabase.sh keeps the same list). */
export const STRIPE_EVENTS = ['payment_intent.amount_capturable_updated', 'payment_intent.succeeded', 'payment_intent.payment_failed', 'payment_intent.processing',
  'payment_intent.canceled', 'payment_intent.requires_action', 'setup_intent.succeeded', 'setup_intent.setup_failed', 'mandate.updated',
  'charge.refunded', 'refund.created', 'refund.updated', 'charge.dispute.created', 'charge.dispute.updated', 'charge.dispute.closed'] as const;
