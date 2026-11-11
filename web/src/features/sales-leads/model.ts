// The Sales lead list (migration 0950): what the database gives (sales_leads, sales_lead, sales_dashboard) and what a
// screen makes of it. Pure, so the unit tests cover it; the screens are LeadList.tsx, LeadPage.tsx and SalesDashboard.tsx.

export type LeadType = 'renter' | 'owner' | 'partner';
export type Outcome = 'contacted' | 'call_booked' | 'applied' | 'won' | 'lost';
export interface LeadClaim { by: string; name: string; since: string; until: string; cap: string; mine: boolean }
/** 2320: a customer service or fleet person handling the lead on a call, for a while; `locked` is true for the person who may not work it meanwhile (Sales) */
export interface LeadHold { by: string; name: string; first_name: string; role: 'cs' | 'fleet'; role_label: string; since: string; until: string; mine: boolean; locked: boolean }
export interface LeadRow {
  id: string; type: LeadType; source: string; source_key: string; kind: string; name: string | null; phone: string | null; email: string | null;
  excerpt: string; vehicle: string | null; created_at: string; status: string; outcome: Outcome | null; outcome_reason: string | null;
  assigned_to: string | null; assigned_name: string | null; claim: LeadClaim | null; /** 2320 */ hold?: LeadHold | null; priority: number; hot: boolean; value_cents: number | null;
  first_contact_at: string | null; handled_at: string | null; new: boolean;
}
export interface Person { id: string; name: string }
export interface LeadList { rows: LeadRow[]; count: number; sources: Array<{ source: string; n: number }>; mine_active: number; max_active: number; admin: boolean; people: Person[];
  /** 1152: the pacing and the person's cap */ next_claim_at?: string | null; claim_cooldown_minutes?: number; paced?: boolean; cap?: LeadCap }
export interface LeadDetail extends LeadRow {
  message: string | null; source_url: string | null; owner_id: string | null; pipeline_stage: string | null; form: Record<string, string>; chat_id: string | null;
  transcript: Array<{ at: string; from: string; text: string }>; calls: Array<{ at: string; kind: string; direction: string; missed: boolean; text: string | null }>;
  contacts: Array<{ at: string; channel: string; note: string | null; by: string }>;
  history: Array<{ at: string; action: string; who: string; by: string | null; note: string | null }>;
  outcome_by: string | null; outcome_at: string | null; won_booking: string | null; admin: boolean; people: Person[];
}
export interface Figures { claimed: number; won: number; close_rate: number; contacted_pct: number; first_contact_minutes: number | null; expired: number }
/** 1152: a person's cap of open leads: the base, plus one for every per_wins won in 30 days, up to max */
export interface LeadCap { cap: number; wins: number; base: number; per_wins: number; max: number; wins_to_next: number | null }
export interface TeamRow extends Figures { id: string; name: string; active: number; rank: number; /** 1152 */ cap?: LeadCap }
/** my_call_minutes for an Admin: each person who called with the site's Call button in the last 40 days, with this month's connected minutes */
export type CallTeam = Array<{ user_id: string; name: string | null; month: number }>;
export interface Dashboard { today: Figures; week: Figures; month: Figures; period: 'today' | 'week' | 'month'; team: TeamRow[] | null; active: number; max_active: number; open_pool: number }
export interface LeadSettings { claim_minutes: Record<LeadType, number>; extend_max_minutes: number; max_active: number; hot_hours: number; updated_at: string; updated_by: string | null; /** 1152 */ claim_cooldown_minutes?: number; /** 2320: empty is the Sales claim window */ lead_cs_hold_minutes?: number | null; lead_cap_base?: number; lead_cap_per_wins?: number; lead_cap_max?: number }

export const TYPE_LABEL: Record<LeadType, string> = { renter: 'Renter', owner: 'Owner', partner: 'Partner' };
export const OUTCOME_LABEL: Record<Outcome, string> = { contacted: 'Contacted', call_booked: 'Call booked', applied: 'Applied', won: 'Won', lost: 'Lost' };
export const OUTCOMES = Object.keys(OUTCOME_LABEL) as Outcome[];
export const STATUS_CHIPS: Array<[string, string]> = [['', 'Open'], ['new', 'New'], ['unclaimed', 'Not claimed'], ['claimed', 'Claimed'], ['contacted', 'Contacted'], ['won', 'Won'], ['lost', 'Lost'], ['handled', 'Handled'], ['all', 'All']];
export const HISTORY_LABEL: Record<string, string> = { claim: 'Claimed', extend: 'Claim extended', unclaim: 'Unclaimed', expire: 'Claim ran out', reassign: 'Reassigned to', release: 'Claim released', return: 'Returned to', hold: 'Handling a call:', hold_extend: 'Another call handled by', hold_end: 'Hold ended for' };
export const CHANNEL_LABEL: Record<string, string> = { call: 'Call', text: 'Text', email: 'Email', note: 'Note' };

const time = (iso: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', hour: 'numeric', minute: '2-digit', hour12: true }).format(new Date(iso)).replace(/\s?([ap])\.?m\.?/i, ' $1m').toLowerCase();

/** "12 min ago", "3 h ago", "2 days ago": how old a lead is, in words. */
export function age(iso: string, now: number = Date.now()): string {
  const m = Math.max(0, Math.floor((now - new Date(iso).getTime()) / 60000));
  if (m < 1) return 'just now';
  if (m < 60) return `${m} min ago`;
  const h = Math.round(m / 60);
  if (h < 48) return `${h} h ago`;
  return `${Math.round(h / 24)} days ago`;
}

/** What the claim line says to this person, and whether they may act on the lead now. */
export function claimWords(c: LeadClaim | null, now: number = Date.now()): { text: string | null; mine: boolean; locked: boolean } {
  if (!c || new Date(c.until).getTime() <= now) return { text: null, mine: false, locked: false };
  const left = Math.max(1, Math.ceil((new Date(c.until).getTime() - now) / 60000));
  if (c.mine) return { text: `Yours until ${time(c.until)} (${left} min). Each call, text, email or note adds time, up to ${time(c.cap)}.`, mine: true, locked: false };
  return { text: `${c.name} is on it until ${time(c.until)}`, mine: false, locked: true };
}

/** 2320: what the hold line says to this person, and whether they may work the lead meanwhile. Sales read
 *  "Being handled by Sam (Customer service) until 10:10 am"; the holder reads that the lead is theirs. */
export function holdWords(h: LeadHold | null | undefined, now: number = Date.now()): { text: string | null; mine: boolean; locked: boolean } {
  if (!h || new Date(h.until).getTime() <= now) return { text: null, mine: false, locked: false };
  if (h.mine) return { text: `You are handling this lead until ${time(h.until)}. Each call you handle adds time.`, mine: true, locked: false };
  return { text: `Being handled by ${h.first_name} (${h.role_label}) until ${time(h.until)}`, mine: false, locked: h.locked };
}

/** The lead's state in a word for its badge. */
export function stateOf(r: Pick<LeadRow, 'outcome' | 'handled_at' | 'status' | 'new'>): string {
  if (r.outcome === 'won') return 'Won';
  if (r.outcome === 'lost' || r.status === 'closed') return 'Lost';
  if (r.handled_at) return 'Handled';
  if (r.outcome) return OUTCOME_LABEL[r.outcome];
  return r.new ? 'New' : 'Open';
}

/** tel:, sms: and mailto: links, or null when the lead has no such contact. */
export function contactLinks(r: Pick<LeadRow, 'phone' | 'email'>): { call: string | null; text: string | null; email: string | null } {
  const digits = (r.phone ?? '').replace(/[^\d+]/g, '');
  return { call: digits ? `tel:${digits}` : null, text: digits ? `sms:${digits}` : null, email: r.email ? `mailto:${r.email}` : null };
}

/** The list's query for the database from the page's search parameters (only known values pass). */
export function listQuery(sp: Record<string, string | undefined>, fixedType?: LeadType): Record<string, unknown> {
  const q: Record<string, unknown> = {};
  const type = fixedType ?? sp.type;
  if (type && ['renter', 'owner', 'partner'].includes(type)) q.type = type;
  if (sp.source) q.source = sp.source.slice(0, 80);
  if (sp.status && STATUS_CHIPS.some(([v]) => v === sp.status)) q.status = sp.status;
  if (sp.age && /^\d{1,3}$/.test(sp.age)) q.age = Number(sp.age);
  if (sp.assigned && /^(none|[0-9a-f-]{36})$/.test(sp.assigned)) q.assigned = sp.assigned;
  if (sp.mine === '1') q.mine = true;
  if (sp.q) q.q = sp.q.slice(0, 100);
  if (sp.sort && ['priority', 'newest', 'oldest'].includes(sp.sort)) q.sort = sp.sort;
  if (sp.page && /^\d{1,3}$/.test(sp.page)) q.offset = (Number(sp.page) - 1) * 50;
  q.limit = 50;
  return q;
}

/** "33%" or a dash when nothing was claimed. */
export const pct = (n: number, claimed: number) => (claimed ? `${n}%` : '-');
/** "4 min" for the time to first contact, or a dash. */
export const minutes = (m: number | null) => (m === null || m === undefined ? '-' : m < 60 ? `${m} min` : `${Math.floor(m / 60)} h ${m % 60} min`);

/** The lead's own page on this portal. */
export const leadHref = (base: string, id: string) => `${base}/${id}`;

/** The two limits on claiming in words (1152): "you hold 1 of 3 (2 more wins for a 4th) · next claim in 4:05" (an Admin is not
 *  paced or capped). */
export function claimPaceWords(p: { held: number; max: number; nextAt: string | null; cooldown: number; paced: boolean; winsToNext?: number | null }, nowMs: number): string {
  if (!p.paced) return `you hold ${p.held}`;
  const left = p.nextAt ? Math.max(0, Math.ceil((Date.parse(p.nextAt) - nowMs) / 1000)) : 0;
  const pace = left > 0 ? `next claim in ${Math.floor(left / 60)}:${String(left % 60).padStart(2, '0')}` : p.cooldown > 0 ? `one claim every ${p.cooldown} min` : '';
  const cap = p.held >= p.max ? ' (the most: close or unclaim one to take another)' : '';
  const grow = p.winsToNext ? ` · ${p.winsToNext} more win${p.winsToNext === 1 ? '' : 's'} for one more` : '';
  return [`you hold ${p.held} of ${p.max}${cap}${grow}`, pace].filter(Boolean).join(' · ');
}
