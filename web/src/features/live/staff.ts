'use client';
// Live visitors and Live chat for staff (migration 0060): the reads and actions of /api/staff/live, and their shapes.
export type SignalAction = 'chat' | 'discount' | 'assign' | 'similar' | 'none';
/** A signal (0060, and since 0086 with why, strength 0 to 3, its group, the suggested action and message). */
export interface Signal { kind: string; label: string; at: string; booking_number?: string | null; task_id?: string | null; who?: string; session_id?: string | null; renter_id?: string | null;
  why?: string; strength?: number; grp?: string; action?: SignalAction; message?: string; weight?: number; source?: string }
export interface Reason { kind: string; label: string; why: string; weight: number }
/** A name staff gave a visitor (0179). source: staff (typed), match (from a chat with the same email or phone), renter (they booked). */
export interface VisitorLabel { name: string; phone: string | null; email: string | null; note: string | null; source: 'staff' | 'match' | 'renter'; by: string | null; at: string }
export interface Visitor {
  id: string; visitor_id: string; who: string; known: boolean; renter_id: string | null; email: string | null; identified_by: string | null; consent: string;
  city: string | null; region: string | null; device: string | null; referrer: string | null; utm_source: string | null; utm_campaign: string | null;
  started_at: string; last_seen_at: string; page_views: number; visit_number: number; current_path: string | null; current_page: string | null;
  car: string | null; vehicle_id: string | null; booking_number: string | null; cars_viewed: number; signals: Signal[]; chat: { id: string; number: string; status: string } | null;
  // 0086
  score?: number | null; band?: 'hot' | 'warm' | 'cold' | null; reasons?: Reason[]; hot_at?: string | null; audience?: 'renter' | 'owner'; suggested?: Signal | null;
  others_on_car?: number | null; assigned?: { id: string; name: string; at: string } | null; last_action?: { action: string; at: string; by: string } | null;
  from_ad?: boolean; landing?: string | null; utm_medium?: string | null;
  /** What the visitor typed into a form (contact capture, 0090), sent or not. */
  captured?: { name: string | null; email: string | null; phone: string | null; form: string; at: string; done: boolean; renter_id: string | null; email_confirmed: boolean | null } | null;
  /** 0179: the name staff gave this browser (shown to staff only), with the phone, email and note they added */
  label?: VisitorLabel | null;
}
export interface VisitEvent { at: string; kind: string; path: string | null; page: string | null; car: string | null; booking_number: string | null; ms: number | null; pickup?: string | null; return?: string | null; detail?: string | null }
export interface SessionDetail extends Visitor { events: VisitEvent[]; visits: number; visits_7d: number }
export interface CarRow { vehicle_id: string; car: string; views_today: number; views_7d: number; viewers_7d: number; requests_7d: number; looking_now: number; quotes_7d?: number; compared?: { vehicle_id: string; car: string; sessions: number } | null }
export interface LiveCfg { hot: number; warm: number; notify_hot: boolean; discount: { enabled: boolean; percent: number; days: number; can: boolean }; is_admin: boolean; quiet: boolean; me: string | null; alerts: boolean }
export interface HotRow { id: string; who: string; score: number; hot_at: string; reasons: Reason[]; online: boolean; renter_id: string | null; acted: boolean }
export interface LiveData { live_minutes: number; tracking: boolean; at: string; now: Visitor[]; signals: Signal[]; most_viewed: CarRow[];
  /** 0103: visitors (browsers) besides visits (sessions), and the browsers that chose necessary cookies only today */
  today: { sessions: number; known: number; chats: number; hot?: number; visitors?: number; untracked?: number };
  cfg?: LiveCfg; hot?: HotRow[]; beat_seconds?: number }
export interface SignalRule { code: string; grp: string; label: string; explain: string; enabled: boolean; weight: number; t1: number | null; t2: number | null; t1_label: string | null; t2_label: string | null;
  param: string | null; param_label: string | null; action: SignalAction; message: string; scope: string; legacy: boolean; sort: number; updated_at: string }
export interface SignalConfig { hot_score: number; warm_score: number; strong_weight: number; medium_weight: number; notify_hot: boolean; discount_enabled: boolean; discount_percent: number;
  discount_max_cents: number | null; discount_valid_days: number; discount_daily_cap: number; discount_cs: boolean; discount_message: string; updated_at: string }
export interface SignalSettingsData { rules: SignalRule[]; config: SignalConfig; can_edit: boolean; week: { hot: number; acted: number; discounts: number; discounts_used: number } }
export const GROUP_WORDS: Record<string, string> = { intent: 'Intent', urgency: 'Urgency', value: 'Value', hesitation: 'Hesitation', context: 'Context' };
export const ACTION_WORDS: Record<SignalAction, string> = { chat: 'Invite to chat', discount: 'Offer a discount code', assign: 'Assign to Sales', similar: 'Suggest a similar free car', none: 'No action' };
export const STRENGTH_WORDS = ['', 'weak', 'medium', 'strong'];
export interface ChatRow {
  id: string; number: string; status: 'ai' | 'waiting' | 'human' | 'closed'; who: string; email: string | null; phone: string | null; renter_id: string | null; session_id: string | null;
  started_by: string; assigned_to: string | null; assigned_name: string | null; human_requested_at: string | null; human_reason: string | null; first_human_reply_at: string | null;
  offline: boolean; page: string | null; car: string | null; last_message_at: string; created_at: string; closed_at: string | null; unread: number; last: string | null;
  visitor_typing: boolean; online: boolean; waiting_minutes: number | null; target_minutes: number; ai_replies: number; lead_id: string | null;
}
export interface ChatMsg { id: number; at: string; sender: 'visitor' | 'ai' | 'staff' | 'system'; body: string; name?: string | null; staff_name?: string | null; meta?: Record<string, unknown> }
export interface Inbox { at: string; on_shift: number; open: ChatRow[]; closed: ChatRow[]; prefs: { email_when_waiting: boolean; desktop_alerts: boolean };
  budget: { chat_neurons: number; all_neurons: number; chat_cap: number; all_cap: number; ok: boolean; ai_enabled: boolean }; waiting: number; unread: number }
export interface Thread { chat: ChatRow; mine: boolean; messages: ChatMsg[]; session: SessionDetail | null;
  renter: { id: string; name: string; email: string | null; mobile: string | null; bookings: Array<{ number: string; status: string; pickup_at: string }> } | null }

export async function liveRead<T>(what: string, p: Record<string, string | number | undefined> = {}): Promise<T> {
  const q = new URLSearchParams({ what });
  for (const [k, v] of Object.entries(p)) if (v !== undefined && v !== '') q.set(k, String(v));
  const r = await fetch(`/api/staff/live?${q}`, { cache: 'no-store', credentials: 'same-origin' });
  const j = (await r.json()) as T & { error?: string };
  if (!r.ok) throw new Error(j.error ?? 'Could not load');
  return j;
}
export async function liveDo<T = { ok: boolean }>(action: string, p: Record<string, unknown> = {}): Promise<T> {
  const r = await fetch('/api/staff/live', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ action, ...p }), credentials: 'same-origin' });
  const j = (await r.json()) as T & { error?: string };
  if (!r.ok) throw new Error(j.error ?? 'That did not work');
  return j;
}

export const minsAgo = (iso: string) => Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 60000));
export const agoWords = (iso: string) => { const m = minsAgo(iso); return m < 1 ? 'just now' : m < 60 ? `${m} min ago` : m < 1440 ? `${Math.floor(m / 60)} h ago` : `${Math.floor(m / 1440)} d ago`; };
export const clock = (iso: string) => new Date(iso).toLocaleTimeString('en-CA', { hour: 'numeric', minute: '2-digit', timeZone: 'America/Toronto' });
export const dayClock = (iso: string) => new Date(iso).toLocaleString('en-CA', { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit', timeZone: 'America/Toronto' });
export const EVENT_WORDS: Record<string, string> = {
  page_view: 'Viewed', car_view: 'Opened a car', search: 'Searched dates', request_started: 'Started a booking request', request_abandoned: 'Left the request form',
  request_submitted: 'Sent a booking request', email_link_opened: 'Opened an email link', offer_viewed: 'Viewed the offer', change_viewed: 'Viewed the change proposal',
  pay_viewed: 'Viewed the pay page', pay_left: 'Left the pay page', chat_opened: 'Opened the chat', page_leave: 'Left',
  quote_seen: 'Saw the price', request_step: 'Reached a step of the request form', help_open: 'Opened a question', contact_click: 'Tapped to contact us',
  photos: 'Looked through photos', browse: 'Sorted or filtered the cars', friction: 'Had trouble with a form'
};
export const STATUS_WORDS: Record<ChatRow['status'], string> = { ai: 'Assistant', waiting: 'Waiting for a person', human: 'With a person', closed: 'Closed' };
