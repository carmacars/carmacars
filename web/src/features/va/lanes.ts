// The assistant's "My queue" home (October 25, 2026; the owner: each staff portal "extremely easy to use"): the open tasks
// sorted into a few lanes per function, each lane with its count, its oldest item and how long that has waited, ordered
// by urgency. Reply lanes (requests, renter messages, texts and calls, live chat) are timed against the first reply
// target (Program settings, 5 minutes by default). Pure functions: the page reads, this sorts.
import type { Task } from './tasks';

export type Fn = 'finance' | 'fleet' | 'cs' | 'sales';
export type LaneIcon = 'doc' | 'clock' | 'alert' | 'car' | 'pay' | 'bank' | 'sign' | 'check' | 'chart' | 'arrow';

export interface LaneDef {
  key: string; label: string; /** what doing the lane means, in a few words */ verb: string; href: string; icon: LaneIcon;
  /** timed against the first reply target */ reply?: boolean; types: string[];
}

const REQUESTS: LaneDef = { key: 'requests', label: 'Booking requests', verb: 'Review and send an offer', href: '/va/requests?state=new', icon: 'doc', reply: true,
  types: ['booking_request', 'reoffer_booking', 'offer_change_requested', 'calendar_offer_clash', 'confirm_offline_booking', 'chauffeur_request', 'place_request'] };
const MESSAGES: LaneDef = { key: 'messages', label: 'Renter messages', verb: 'Reply to the renter', href: '/va/messages', icon: 'arrow', reply: true, types: ['renter_message'] };
const PHONE: LaneDef = { key: 'phone', label: 'Texts and calls', verb: 'Call back or text', href: '/va?lane=phone', icon: 'alert', reply: true, types: ['phone_missed_call', 'account_phone_review'] };
const CHAT: LaneDef = { key: 'chat', label: 'Live chat', verb: 'Answer the visitor', href: '/va/chat', icon: 'arrow', reply: true, types: ['live_chat_waiting', 'chat_request', 'chat_contact'] };
const OFFERS: LaneDef = { key: 'offers', label: 'Offers out', verb: 'Chase or re-send the offer', href: '/va/requests?state=offer_out', icon: 'clock', types: ['chase_offer', 'offer_expired', 'offer_approved_paid'] };
const SIGNING: LaneDef = { key: 'signing', label: 'Signing and payment', verb: 'Help the renter finish', href: '/va?lane=signing', icon: 'sign',
  types: ['verify_renter', 'chase_verification', 'protection_plan_request', 'coverage_review', 'paper_agreement_scan', 'insurer_provisional', 'review_extension', 'booking_change_approval'] };
const FOLLOW: LaneDef = { key: 'follow', label: 'Follow-ups', verb: 'Follow up', href: '/va?lane=follow', icon: 'chart',
  types: ['visitor_follow_up', 'game_lead_follow_up', 'owner_lead', 'buyer_lead', 'finance_lead', 'detailing_lead', 'bodyshop_lead', 'enquiry', 'sample_car_enquiry', 'owner_intake',
    'auto_service_request', 'detailing_request', 'bodyshop_request'] };
// Finance
const PAYMENTS: LaneDef = { key: 'payments', label: 'Payments to fix', verb: 'Collect or match the payment', href: '/va/money#failed', icon: 'pay',
  types: ['debit_failed', 'arrears', 'collect_upfront', 'stripe_requires_action', 'stripe_dispute_finance', 'unmatched_payment', 'reconcile', 'addon_payment', 'field_cash_handin', 'charge_question'] };
const DEPOSITS: LaneDef = { key: 'deposits', label: 'Deposits to settle', verb: 'Take or release the deposit', href: '/va/money#deposits', icon: 'bank',
  types: ['take_deposit', 'release_deposit', 'return_deposit_offline', 'settle_holdback', 'review_damage_match', 'price_findings'] };
const REFUNDS: LaneDef = { key: 'refunds', label: 'Refunds waiting', verb: 'Request or issue the refund', href: '/va/money#refunds', icon: 'clock',
  types: ['refund_cancellation', 'stripe_refund_failed', 'stripe_refund_outside'] };
const STATEMENTS: LaneDef = { key: 'statements', label: 'Owner statements', verb: 'Prepare the statement', href: '/va/money#statements', icon: 'doc',
  types: ['review_statements', 'statement_correction', 'fleet_report'] };
const TOLLS: LaneDef = { key: 'tolls', label: 'Tolls and tickets', verb: 'Match the toll', href: '/va/tolls', icon: 'car', types: ['match_toll', 'review_toll_match', 'toll_read_exceptions', 'toll_read_review'] };
// Fleet
const HANDOVERS: LaneDef = { key: 'handovers', label: 'Handovers and returns', verb: 'Schedule or assign the job', href: '/va/fleet', icon: 'car',
  types: ['schedule_handover', 'schedule_detail', 'job_unacknowledged', 'field_job_problem', 'field_report', 'late_return', 'vehicle_swap', 'addon_prep'] };
const INCIDENTS: LaneDef = { key: 'incidents', label: 'Incidents and breakdowns', verb: 'Handle it now', href: '/va?lane=incidents', icon: 'alert', types: ['incident', 'breakdown', 'recovery_done'] };
const CHECKS: LaneDef = { key: 'checks', label: 'Checks and photos', verb: 'Do the check', href: '/va/checks', icon: 'check', types: ['opening_checks', 'closing_checks', 'review_photos'] };
const CARS: LaneDef = { key: 'cars', label: 'Car paperwork and service', verb: 'Renew, book or list', href: '/va/fleet#expiry', icon: 'doc',
  types: ['plate_renewal', 'safety_certificate_window', 'book_registry', 'turo_expiry', 'record_registration', 'maintenance_due', 'maintenance_backfill', 'maintenance_bill', 'list_vehicle',
    'listing_failed', 'listing_similarity', 'calendar_conflict', 'calendar_feed_failing', 'turo_email_review', 'owner_exit', 'addon_stock'] };

export const LANES: Record<Fn, LaneDef[]> = {
  cs: [REQUESTS, MESSAGES, PHONE, CHAT, OFFERS, SIGNING, FOLLOW],
  sales: [CHAT, REQUESTS, OFFERS, FOLLOW, PHONE, SIGNING],
  finance: [PAYMENTS, DEPOSITS, REFUNDS, STATEMENTS, TOLLS],
  fleet: [INCIDENTS, HANDOVERS, CHECKS, CARS]
};
export const OTHER: LaneDef = { key: 'other', label: 'Other tasks', verb: 'Open the task', href: '/va?lane=other', icon: 'arrow', types: [] };

/** The lane a task belongs to, for this function ('other' when none of its lanes takes it). */
export function laneOf(fn: Fn, taskType: string): string {
  return LANES[fn].find((l) => l.types.includes(taskType))?.key ?? 'other';
}

export interface Lane extends LaneDef {
  count: number; overdue: number; urgent: number;
  /** when the oldest item started waiting (ISO), for the timer */ since: string | null;
  /** minutes the oldest item has waited */ waited: number | null;
  /** the oldest item, to open in one click */ first: Task | null;
  /** 0 calm, 1 due, 2 past the reply target or overdue, 3 urgent and late */ heat: number;
}

const PRI: Record<string, number> = { urgent: 3, high: 2, normal: 1, low: 0 };

/** How urgent a task is: higher first. Overdue and escalated tasks lead, then priority, then the longest waiting. */
export function taskScore(t: Task, now: number, targetMin: number, reply: boolean): number {
  const waited = Math.max(0, (now - Date.parse(t.created_at)) / 60_000);
  const late = t.overdue || (t.due_at !== null && Date.parse(t.due_at) < now);
  return (t.escalated ? 4000 : 0) + (late ? 2000 : 0) + (reply && waited > targetMin ? 1500 : 0) + (PRI[t.priority] ?? 1) * 300 + Math.min(waited, 299);
}

/** The most urgent task first. */
export function sortTasks(fn: Fn, tasks: Task[], now: number, targetMin: number): Task[] {
  const reply = new Set(LANES[fn].filter((l) => l.reply).flatMap((l) => l.types));
  return [...tasks].sort((a, b) => taskScore(b, now, targetMin, reply.has(b.task_type)) - taskScore(a, now, targetMin, reply.has(a.task_type)));
}

/**
 * The lanes of a function with their counts, most urgent first; empty lanes last, in their usual order. `extra` adds
 * items the queue does not hold as tasks (chats waiting, requests waiting) to a lane's count, with their oldest time.
 */
export function buildLanes(fn: Fn, tasks: Task[], now: number, targetMin: number, extra: Record<string, { count: number; since?: string | null }> = {}): Lane[] {
  const defs = [...LANES[fn], OTHER];
  const lanes = defs.map((def, order) => {
    const mine = sortTasks(fn, tasks.filter((t) => laneOf(fn, t.task_type) === def.key), now, targetMin);
    const ex = extra[def.key];
    const times = [...mine.map((t) => t.created_at), ...(ex?.since ? [ex.since] : [])].sort();
    const since = times[0] ?? null;
    const count = Math.max(mine.length, ex?.count ?? 0);
    const waited = since ? Math.max(0, Math.floor((now - Date.parse(since)) / 60_000)) : null;
    const overdue = mine.filter((t) => t.overdue || (t.due_at !== null && Date.parse(t.due_at) < now)).length;
    const urgent = mine.filter((t) => t.priority === 'urgent' || t.escalated).length;
    const pastTarget = !!def.reply && waited !== null && waited > targetMin;
    const heat = !count ? 0 : (urgent && (overdue || pastTarget)) ? 3 : (overdue || pastTarget) ? 2 : 1;
    return { lane: { ...def, count, overdue, urgent, since: count ? since : null, waited: count ? waited : null, first: mine[0] ?? null, heat } as Lane, order };
  });
  return lanes
    .filter(({ lane }) => lane.key !== 'other' || lane.count > 0)
    .sort((a, b) => (b.lane.heat - a.lane.heat) || ((b.lane.count ? 1 : 0) - (a.lane.count ? 1 : 0)) || (b.lane.count && a.lane.count ? (b.lane.waited ?? 0) - (a.lane.waited ?? 0) : 0) || a.order - b.order)
    .map(({ lane }) => lane);
}

/** Minutes as a short wait: "4 min", "1 h 12 min", "2 d 3 h". */
export function waitWords(min: number): string {
  if (min < 1) return 'just now';
  if (min < 60) return `${min} min`;
  if (min < 1440) return `${Math.floor(min / 60)} h${min % 60 ? ` ${min % 60} min` : ''}`;
  return `${Math.floor(min / 1440)} d${Math.floor((min % 1440) / 60) ? ` ${Math.floor((min % 1440) / 60)} h` : ''}`;
}


/** The clock of this request (server pages read it once and pass it down). */
export const requestNow = (): number => Date.now();
