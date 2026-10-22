// Text alerts (migration 0096): how a person is reached (Email, Text or Both), the words each screen shows, and the
// rules of the text templates (the same as the database's app.sms_template_ok and app.sms_render), for the forms, the
// Admin preview and the unit tests. No imports.

export type Channel = 'email' | 'text' | 'both';
export const CHANNELS: Channel[] = ['email', 'text', 'both'];
export const CHANNEL_LABEL: Record<Channel, string> = { email: 'Email', text: 'Text', both: 'Both' };
export const CHANNEL_HINT: Record<Channel, string> = {
  email: 'Everything by email.',
  text: 'Short texts with a link. Signed documents, statements and receipts are still emailed when we have your email.',
  both: 'A text and an email for each update.'
};
export type WhyNot = 'no_verified_phone' | 'opted_out' | 'us_waiting' | 'not_canada' | 'off';

/** What app.notify_reach answers (and app.my_notify_channel adds for the person's own card). */
export interface Reach {
  user_id: string | null; chosen: Channel | null; default: Channel; wanted: Channel; channel: Channel;
  email: string | null; phone: string | null; country: string | null; textable: boolean; why_not: WhyNot | null; opted_out_at: string | null;
  our_number?: string | null; quiet_from?: number; quiet_until?: number; quiet?: boolean; enabled?: boolean;
  log?: Array<{ action: 'stop' | 'start'; source: string | null; at: string; confirmation?: string | null }>; texts_30d?: number;
}

export const isChannel = (v: unknown): v is Channel => v === 'email' || v === 'text' || v === 'both';

/** Why texts are not going to this person now (null: they can). `our` is the CarmaCars number for START. */
export function whyNotWords(why: WhyNot | null | undefined, our?: string | null, who: 'you' | 'they' = 'you'): string | null {
  const you = who === 'you';
  switch (why) {
    case 'no_verified_phone': return you ? 'Verify your mobile number to get texts. Until then we email you.' : 'No verified phone: email only until they verify one.';
    case 'opted_out': return you ? `You replied STOP, so texts are off. Text START to ${our ?? 'our number'} to turn them back on. Until then we email you.` : 'They replied STOP: email only until they text START.';
    case 'us_waiting': return you ? 'Texts to US numbers are not available yet. We email you for now.' : 'US number: texts wait for A2P 10DLC registration, so email only.';
    case 'not_canada': return you ? 'We text Canadian and US mobile numbers only. We email you.' : 'Not a Canadian or US mobile: email only.';
    case 'off': return you ? 'Texts are not available right now. We email you.' : 'Text alerts are off in Settings: email only.';
    default: return null;
  }
}

/** The line under the choice: what happens now. */
export function nowWords(r: Pick<Reach, 'channel' | 'wanted' | 'email'>): string {
  if (r.channel === 'text') return r.wanted === 'email' ? 'You have no email on file, so we text you.' : 'We text you. Documents are still emailed when you add an email.';
  if (r.channel === 'both') return 'We text and email you.';
  return 'We email you.';
}

const hour = (h: number) => (h === 0 ? 'midnight' : h === 12 ? 'noon' : h < 12 ? `${h} am` : `${h - 12} pm`);
export const quietWords = (from = 21, until = 8) => `No texts from ${hour(from)} to ${hour(until)} unless it is urgent; they wait until ${hour(until)}.`;

// ---------------------------------------------------------------- templates
/** Why a template is refused (null: fine). 1 to 320 characters, no long dashes, names CarmaCars, has {{link}}. */
export function smsTemplateProblem(t: string | null | undefined): string | null {
  const s = (t ?? '').trim();
  if (!s) return 'Write the text';
  if (s.length > 320) return 'Keep it under 320 characters (two texts)';
  if (/[–—]/.test(s)) return 'No long dashes: use a comma, a colon or a full stop';
  if (!s.includes('CarmaCars')) return 'Name CarmaCars in the text, so people know who it is from';
  if (!s.includes('{{link}}')) return 'Keep {{link}}: every text links to the page';
  return null;
}

/** Fills {{name}} like app.render_text, then tidies like app.sms_render. */
export function renderSms(tpl: string, vars: Record<string, string | null | undefined>): string {
  let s = (tpl ?? '').replace(/\{\{\s*([a-z0-9_]+)\s*\}\}/g, (_, k: string) => String(vars[k] ?? '')).replace(/—/g, ',').replace(/–/g, '-');
  s = s.replace(/\(\s*\)/g, '').replace(/\s+/g, ' ').replace(/\s+([,.!?:)])/g, '$1').replace(/,\s*([,.])/g, '$1');
  return s.trim().slice(0, 1600);
}

export const STOP_LINE = 'Reply STOP to opt out.';

/** Is a text all GSM-7 (160 characters a text) rather than Unicode (70)? */
export const isGsm = (s: string) => /^[\n\r -_a-zA-Z0-9@£$¥èéùìòÇØøÅåΔΦΓΛΩΠΨΣΘΞÆæßÉ!"#¤%&'()*+,\-./:;<=>?¡ÄÖÑÜ§¿äöñüà^{}\\[~\]|€]*$/.test(s);

/** Sample values for previews and tests: a long car name and real-looking links. */
export const SMS_SAMPLE: Record<string, string> = {
  first_name: 'Maya', booking_number: 'CC-10482', vehicle_name: '2024 Mercedes-Benz C 300 4MATIC Sedan', pickup_date: 'Fri, Oct 23, 2026', pickup_time: '10:00 am',
  return_date: 'Mon, Oct 26, 2026', return_time: '10:00 am', pickup_place: '1570 Midland Ave, Toronto', return_place: '1570 Midland Ave, Toronto',
  total_amount: '$1,468.95', amount: '$468.95', amount_due: '$212.40', deposit_amount: '$1,000.00', release_amount: '$1,000.00', refund_amount: '$468.95',
  offer_expires_at: 'Thu, Oct 22 at 6:00 pm', extension_amount: '$212.40', new_return_date: 'Tue, Oct 27, 2026', new_return_time: '10:00 am',
  final_deadline: 'Tue, Oct 27 at 2:00 pm', verify_by: 'Thu, Oct 22 at 6:00 pm', hours_left: '6 hours', statement_month: 'October 2026',
  payout_amount: '$2,140.55', invoice_number: 'INV-2026-0142', invoice_total: '$545.00', due_date: 'Nov 1, 2026', debit_total: '$545.00',
  debit_date: 'Nov 1, 2026', return_amount: '$812.50', eta_minutes: '40', subject: 'Your CarmaCars owner account is ready',
  accept_by: 'Thu, Oct 22 at 6:00 pm', charge_type: 'Toll', charge_total: '$18.40', renter_name: 'Maya Patel', notice_type: 'Parking ticket',
  notice_type_lower: 'parking ticket', notice_number: 'PT-55120', notice_amount: '$75.00', notice_date: 'Oct 20, 2026', discount_percent: '10',
  discount_code: 'BACK10', discount_expires: 'Nov 30, 2026', prize_label: '10% off', chat_number: 'CH-2041', application_number: 'APP-0311',
  visit_date: 'Mon, Oct 26', visit_time: '11:00 am', owner_name: 'Omar Haddad', balance: '$545.00', arrears_amount: '$545.00', payee_name: 'CarmaCars',
  support_phone: '(647) 555-0100', effective_date: 'Dec 1, 2026', document_type: 'Insurance slip', form_title: 'Form D, limited power of attorney',
  incident_date: 'Oct 20, 2026', incident_number: 'INC-0042', incident_status: 'with the body shop', exit_date: 'Dec 31, 2026',
  link: 'https://carmacars.ca/account/bookings/CC-10482/offer'
};
