// Phone and browser alerts (migration 0300): the nine topics, their words for each portal, and the small browser facts
// the alerts card needs (which device this is, whether iOS needs the Home Screen first). No imports: shared by the
// server, the card and the unit tests.

export const TOPICS = ['requests', 'bookings', 'payments', 'handovers', 'messages', 'alerts', 'documents', 'leads', 'visitors'] as const;
export type Topic = (typeof TOPICS)[number];
export type PushRole = 'renter' | 'owner' | 'investor' | 'staff' | 'field' | 'admin';

export interface PushDevice { id: string; device: string; portal: string | null; created_at: string; last_sent_at: string | null; this: boolean }
export interface PushStore { ios: string | null; android: string | null }
export interface PushState { store?: PushStore; enabled: boolean; role: PushRole; topics: Topic[]; defaults: Topic[]; chosen: boolean; this_device: boolean | null; devices: PushDevice[] }

const COMMON: Record<Topic, [string, string]> = {
  requests: ['New requests and offers', 'A booking request comes in or an offer is ready.'],
  bookings: ['Booking changes', 'Confirmed, changed, extended or cancelled.'],
  payments: ['Payments', 'Money in or out, and a payment that failed.'],
  handovers: ['Pickups and returns', 'A handover is due, with the time and place.'],
  messages: ['Messages', 'A reply from us or a new message to answer.'],
  alerts: ['Urgent alerts', 'Late returns, incidents and anything that cannot wait.'],
  documents: ['Documents and statements', 'Something to sign, upload or read.'],
  leads: ['New leads', 'A new lead, a request left unfinished or a new owner lead.'],
  visitors: ['Hot visitors', 'A visitor on the site is ready to book.']
};
const BY_ROLE: Partial<Record<PushRole, Partial<Record<Topic, [string, string]>>>> = {
  renter: {
    requests: ['Offers and request updates', 'Your offer is ready, or we need something to confirm.'],
    payments: ['Payments and deposits', 'Receipts, refunds and a payment that did not go through.'],
    messages: ['Messages from CarmaCars', 'When our team writes to you.'],
    alerts: ['Urgent trip alerts', 'Late return notices and roadside help.']
  },
  owner: {
    requests: ['New bookings of your cars', 'A renter booked one of your cars.'],
    payments: ['Payments and payouts', 'Payouts sent, invoices and debits.'],
    alerts: ['Incidents', 'Damage, accidents and anything urgent about your cars.']
  },
  investor: { payments: ['Returns paid', 'When a return is paid to you.'] },
  field: { handovers: ['My jobs', 'A job is assigned or changed, and the day\'s list.'], payments: ['My pay', 'When your pay or commission is paid.'] },
  admin: { alerts: ['Urgent alerts', 'Incidents, disputes, failed jobs, approvals and site alerts.'] }
};

export function topicLabel(role: PushRole, t: Topic): { label: string; hint: string } {
  const [label, hint] = BY_ROLE[role]?.[t] ?? COMMON[t];
  return { label, hint };
}

/** The topics a portal shows: every topic that can reach someone in it (an investor has no handovers or requests). */
const SHOWN: Record<PushRole, Topic[]> = {
  renter: ['requests', 'bookings', 'payments', 'handovers', 'messages', 'alerts', 'documents'],
  owner: ['requests', 'bookings', 'payments', 'alerts', 'documents'],
  investor: ['payments', 'documents', 'messages'],
  staff: ['requests', 'bookings', 'payments', 'messages', 'alerts', 'leads', 'visitors'],
  field: ['handovers', 'payments'],
  admin: ['requests', 'bookings', 'payments', 'messages', 'alerts', 'leads', 'visitors']
};
export function topicsFor(role: PushRole): Topic[] {
  return SHOWN[role] ?? SHOWN.renter;
}

/** A short name for this device, so a person can tell their devices apart ("iPhone, Safari"). */
export function deviceLabel(ua: string): string {
  const os = /iPhone/.test(ua) ? 'iPhone' : /iPad/.test(ua) || (/Macintosh/.test(ua) && /Mobile\//.test(ua)) ? 'iPad'
    : /Android/.test(ua) ? (/Mobile/.test(ua) ? 'Android phone' : 'Android tablet') : /Windows/.test(ua) ? 'Windows'
    : /Macintosh|Mac OS X/.test(ua) ? 'Mac' : /CrOS/.test(ua) ? 'Chromebook' : /Linux/.test(ua) ? 'Linux' : 'Device';
  const br = /Edg\//.test(ua) ? 'Edge' : /SamsungBrowser/.test(ua) ? 'Samsung Internet' : /Firefox\/|FxiOS/.test(ua) ? 'Firefox'
    : /OPR\//.test(ua) ? 'Opera' : /Chrome\/|CriOS/.test(ua) ? 'Chrome' : /Safari\//.test(ua) ? 'Safari' : '';
  return br ? `${os}, ${br}` : os;
}

/** iPhone and iPad: web alerts only from the app added to the Home Screen (iOS 16.4 and later). */
export function isIos(ua: string, maxTouchPoints = 0): boolean {
  return /iPhone|iPad|iPod/.test(ua) || (/Macintosh/.test(ua) && maxTouchPoints > 1);
}

/** What the card can offer on this browser right now. */
export type Support = 'ready' | 'ios_install' | 'unsupported' | 'blocked';
export function supportOf(b: { ua: string; maxTouchPoints?: number; standalone: boolean; hasPush: boolean; permission: 'default' | 'granted' | 'denied' | 'none' }): Support {
  if (isIos(b.ua, b.maxTouchPoints) && !b.standalone) return 'ios_install';
  if (!b.hasPush || b.permission === 'none') return 'unsupported';
  if (b.permission === 'denied') return 'blocked';
  return 'ready';
}

/** The native app is in the stores (0463): a phone is asked to download it instead of turning on browser alerts. Inside the app (its user agent says so) the native prompt is used instead. */
export function storeLink(ua: string, store: PushStore | undefined, maxTouchPoints = 0): { platform: 'ios' | 'android'; url: string } | null {
  if (!store || /CarmaCarsApp/.test(ua)) return null;
  if (isIos(ua, maxTouchPoints) && store.ios) return { platform: 'ios', url: store.ios };
  if (/Android/.test(ua) && store.android) return { platform: 'android', url: store.android };
  return null;
}
