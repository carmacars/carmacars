import type { Field } from './Act';

// Form fields from a database row: the type follows the column's name and value, so a new setting
// appears on the settings screen without a developer.
const nice = (k: string) => { const s = k.replace(/_(cents|bps)$/, '').replace(/_/g, ' '); return s.charAt(0).toUpperCase() + s.slice(1); };
// settings whose meaning needs a sentence (0042: one turnaround between trips; the tolls, plates and vision settings)
const LABELS: Record<string, string> = {
  turnaround_buffer_minutes: 'Turnaround between trips (minutes)', turnaround_block_enabled: 'Show the turnaround as a cleaning block on the calendar',
  toll_read_min_confidence: 'Notice reading: confidence needed to import without a check (0 to 100)', toll_read_auto_charge: 'Notice reading: charge renters matched with high confidence when confirmed',
  toll_read_max_pages: 'Notice reading: pages sent to the vision model', listing_plate_check_required: 'Keep each listing photo private until its plate is covered or marked not visible (the car is listed meanwhile)',
  listing_publish_new_cars_automatically: 'Publish new cars automatically (as soon as the year, make, model, plate or VIN and rates are in)',
  listing_default_daily_rate_cents: 'Starting daily rate by class, in cents (used when no similar car has rates)',
  plate_cover_style: 'Default way to cover a plate (cover, pixelate or blur)', plate_cover_text: 'Text on the plate cover (empty: the brand name)', plate_detect_enabled: 'Suggest the plate box with the vision model',
  notify_daily_cap: 'Emails a day (the email provider\'s daily limit)', notify_class_limits: 'Daily count under which each kind may still send: customer, owner and investor, staff, digests, marketing',
  notify_cap_warn_bps: 'Warn the Admins in the portal at this share of the daily limit', notify_count_auth_emails: 'Count sign-in emails (sent by Supabase through the same provider) in the daily limit',
  owner_debit_notice_days: 'Pre-debit notice (days before each debit, 10 to 30)',
  request_response_target_minutes: 'First reply target for customer service and sales (minutes)',
  staff_commission_bps: 'Commission outside Sales: customer service, finance, fleet and field staff (also the field referral fee)',
  sales_tier_low_bps: 'Sales commission under the middle tier\'s days', sales_tier_mid_bps: 'Sales commission from the middle tier\'s days', sales_tier_high_bps: 'Sales commission from the top tier\'s days',
  sales_tier_mid_days: 'Sales: rental days in a month for the middle tier', sales_tier_high_days: 'Sales: rental days in a month for the top tier (the month\'s target)',
  custom_price_floor_daily_cents: 'Price typed by hand: floor a day (empty: no floor)', custom_price_max_discount_bps: 'Price typed by hand: flag a discount from the rate sheet above',
  street_address: 'Street address (pickup and returns)', signing_officer_authorized_on: 'Signing officer: date of the standing authorization',
  visitor_tracking_enabled: 'Live visitors: record visits on the site', visitor_events_keep_days: 'Live visitors: keep page views and events (days)',
  visitor_live_minutes: 'Live visitors: "on the site now" means seen in the last (minutes)', visitor_spree_cars: 'Signal "Viewing spree": cars viewed',
  visitor_spree_minutes: 'Signal "Viewing spree": within (minutes)', visitor_offer_no_answer_hours: 'Follow-up: offer opened, no answer after (hours)',
  visitor_proposal_opens: 'Signal: change proposal opened this many times', visitor_returning_visits: 'Signal "Returning visitor": visits in 7 days',
  visitor_pay_left_minutes: 'Follow-up: pay page left without paying, after (minutes)', visitor_request_stopped_minutes: 'Follow-up: booking request started and stopped, after (minutes)',
  visitor_followup_tasks: 'Raise follow-up tasks from the signals of known visitors', chat_enabled: 'Live chat on the site and portals',
  chat_ai_enabled: 'Live chat: the AI assistant answers first', chat_ai_model: 'Live chat: Workers AI model', chat_ai_daily_neurons: 'Live chat: AI neurons a day',
  chat_ai_total_daily_neurons: 'Live chat: stop the AI when all Workers AI use of the day reaches (neurons)', chat_ai_max_replies: 'Live chat: AI replies in one chat before a person takes it',
  chat_greeting_seconds: 'Live chat: greet visitors on a car page after (seconds, 0 is off)', chat_greeting_text: 'Live chat: the greeting',
  chat_shift_minutes: 'Live chat: staff count as on shift when active within (minutes)', chat_keep_days: 'Live chat: keep chats of visitors who are not customers (days)',
  default_km_allowance_per_day: 'Kilometres included a day on a new rate card (the default)', stale_request_expire: 'Expire a booking request whose pickup time passed without an offer',
  stale_request_email_renter: 'Email the renter when their request expires that way',
  game_enabled: 'Discount games: show the game to visitors who browse (on by default)', game_max_discount_cents: 'Discount games: most a percentage code takes off one booking',
  game_code_valid_days: 'Discount games: a code is good for (days)', game_trigger_car_pages: 'Discount games: show after this many car pages (0 is off)',
  game_trigger_seconds: 'Discount games: or after this many seconds on the site (0 is off)', game_exit_intent: 'Discount games: or when the mouse heads for the tabs (computers)',
  game_dismiss_days: 'Discount games: after a visitor closes it, wait (days)', game_task_min_cars: 'Discount games: Sales task when the visitor viewed this many cars (0: every claim)',
  game_reminder_hours: 'Discount games: reminder email before an unused code expires (hours, 0 is off)',
  game_prizes: 'Discount games: prize table (edit it under Settings, Discount games)', game_weights: 'Discount games: games and their weights (edit it under Settings, Discount games)',
  phone_enabled: 'Phone and texts: record calls and texts on the CarmaCars number (Quo)', phone_record_calls: 'Phone and texts: keep calls', phone_record_texts: 'Phone and texts: keep texts',
  phone_missed_call_text_enabled: 'Missed call: text the caller back from the CarmaCars number', phone_missed_call_text: 'Missed call: the text',
  phone_missed_call_text_hours: 'Missed call: at most one text per number in (hours)', phone_missed_call_task: 'Missed call: a task to call back',
  phone_missed_call_queue: 'Missed call: who calls back (cs, sales, fleet, finance or admin)', phone_ai_drafts: 'Texts: Suggest a reply with AI (never sent by itself)',
  phone_ai_summaries: 'Calls: a one-line AI summary when Quo gives none', phone_ai_daily_neurons: 'Phone and texts: AI neurons a day',
  phone_link_visitors: 'Show the site visit of a caller who gave the same phone in live chat or a game', phone_keep_months: 'Keep calls and texts of people who are not customers (months)',
  phone_sms_booking: 'Booking texts beside the emails', phone_sms_quiet_hours: 'Booking texts: wait for the end of the quiet hours (Site check)',
  phone_sms_stop_line: 'Booking texts: add "Reply STOP to opt out." to the first one', phone_sms_offer_sent: 'Booking text: offer sent', phone_sms_offer_sent_text: 'Booking text: offer sent, the text',
  phone_sms_payment_confirmed: 'Booking text: payment received, booking confirmed', phone_sms_payment_confirmed_text: 'Booking text: booking confirmed, the text',
  phone_sms_payment_received: 'Booking text: other payments received', phone_sms_payment_received_text: 'Booking text: payment received, the text',
  phone_sms_pickup_tomorrow: 'Booking text: pickup tomorrow', phone_sms_pickup_tomorrow_text: 'Booking text: pickup tomorrow, the text',
  phone_sms_return_reminder: 'Booking text: return reminder', phone_sms_return_reminder_text: 'Booking text: return reminder, the text',
  phone_sms_payment_link: 'Booking text: payment link', phone_sms_payment_link_text: 'Booking text: payment link, the text',
  signin_phone_enabled: 'Sign-in by phone: people may sign in and verify a phone with a texted code', signin_phone_us_allowed: 'Sign-in by phone: also US numbers',
  signin_phone_hourly_per_number: 'Sign-in by phone: codes per number an hour', signin_phone_hourly_per_ip: 'Sign-in by phone: codes per connection (IP) an hour',
  signin_confirm_required: 'Accepting an offer, signing and paying need a confirmed account', signin_confirm_by_phone: 'A phone verified with a code confirms the account (like a confirmed email)',
  ai_vision_enabled: 'Vision model on', ai_vision_model: 'Vision model', ai_vision_fallback_model: 'Vision model if the first is not available', ai_vision_daily_neurons: 'Vision model: neurons a day'
};
const HINTS: Record<string, string> = {
  turnaround_buffer_minutes: 'One time between trips (default 120). No trip may start within it after another ends, and a trip must end this long before the next starts. After each trip it shows as the cleaning block; removing the block frees the time. It is never added twice. A car can have its own under Vehicles, the car, Calendar.',
  turnaround_block_enabled: 'Off: the same time is still held after each trip, without a block on the calendar.',
  street_address: 'Where renters pick up and return cars. This address will change: update it here and every page, email and agreement uses the new one. Nothing else holds it.',
  mailing_address: 'The company mailing address. Marketing emails, the PAD agreement and its confirmation print it.',
  signing_officer_name: 'Signs every automatic countersignature for the company and countersigns investment agreements.',
  signing_officer_authorized_on: 'Printed in every automatic countersignature. A new signing officer takes the date the change is saved.',
  request_response_target_minutes: 'Booking requests, enquiries, offer changes and renter messages are due this many minutes after they come in (5 by default, counted in opening hours). The task due times, the countdown, the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) and the late-request alert to staff are separate settings.',
  staff_commission_bps: 'The share of the rental charge (before tax, after discounts, less refunds) a staff member outside Sales earns on each rental they sourced, once it is completed and paid and an Admin approves it. 10% by default. An Admin may set another rate for one person on their Sales page.',
  sales_tier_high_days: 'Days count from the completed, paid rentals a Sales staff member sourced that end in the month. The month\'s tier applies to all that month\'s rentals. My sales and the scorecard show this as the month\'s target.',
  custom_price_floor_daily_cents: 'A price typed by hand under this amount a day is flagged on the booking and in To do. It is never refused.',
  custom_price_max_discount_bps: 'A price typed by hand this far or more under the rate sheet is flagged on the booking and in To do (20% by default). It is never refused.',
  owner_debit_notice_days: 'Payments Canada Rule H1: an owner gets the notice of a variable debit at least 10 days ahead. The owner\'s PAD agreement does not waive it, so 10 is the least allowed.',
  toll_read_min_confidence: 'Lines read below this, or with something missing, wait for a person to check them; the rest are imported when the read is confirmed.',
  notify_class_limits: 'Five numbers, in this order: customer booking emails, owner and investor emails, immediate staff emails, digests and summaries, marketing. Keep the first under the daily limit so sign-in emails always have room (default 97, 95, 90, 80, 60 of 100). What cannot go waits until after midnight; nothing is dropped.',
  ai_vision_daily_neurons: 'Cloudflare gives 10,000 neurons a day free, shared with the listing copy. A scanned page uses about 100 to 300.',
  chat_ai_daily_neurons: 'One assistant reply uses about 100 to 250 neurons (a quote takes two model calls); a typical chat about 600. 6,000 a day is about 10 chats. When it is used up, chats wait for a person ("A person will reply shortly"). Cloudflare gives 10,000 neurons a day free, shared with the listing copy, the guides and the vision model.',
  chat_greeting_seconds: 'Off (0) by default. When set, a small message bubble offers help on car pages; the visitor opens the chat only if they press Reply.',
  visitor_events_keep_days: 'The privacy policy says 90 days. Change it only with the lawyer. The daily counts per car (no personal information) are kept.',
  default_km_allowance_per_day: 'Used when staff keep "Use the defaults" on a car\'s rates (200 by default). The extra kilometre rate comes from Fee defaults, Mileage overage, by class.',
  stale_request_email_renter: 'Off by default: the request expires with a note in the booking history only. On: the renter gets the "request declined" email saying the pickup time passed.',
  game_max_discount_cents: 'Applies to percentage prizes only ($75 by default). A dollar prize is its own amount. Empty: no cap.',
  game_trigger_car_pages: 'Never on the first page of a visit from a search engine on a phone, never on booking, pay, sign or sign-in pages, never for someone signed in.',
  game_task_min_cars: 'A claim from a visitor who viewed this many different cars raises a Sales follow-up task ("Claimed 10% off, viewed 6 cars").',
  phone_missed_call_text_enabled: 'Off by default: Quo\'s own missed-call auto-reply is used. Turn off Quo\'s own missed-call auto-reply first, or callers get two texts. The task to call back is separate (below).',
  phone_missed_call_text: 'Sent once per number in the hours below, never to staff or to a number that texted STOP. Short (160 characters is one text), no long dashes, and name CarmaCars.',
  phone_missed_call_queue: 'The task goes to whoever of that function has Live chat or Texts and calls open (on shift); otherwise to the function\'s queue; with nobody in that function, to the Admins. In the site check\'s quiet hours it is due when they end.',
  phone_sms_booking: 'One text for each of these emails: offer sent, booking confirmed, payment receipt, pickup reminder (24 hours before), return reminder (24 hours before), and the payment link after the renter left the pay page. Only to renters with a mobile number who did not opt out (STOP). Transactional only: never marketing.',
  phone_sms_offer_sent_text: 'Placeholders: {first_name}, {booking}, {car}, {pickup}, {return}, {amount}, {link}. Keep it short (160 characters is one text), no long dashes, and name CarmaCars.', phone_sms_payment_confirmed_text: 'Placeholders: {first_name}, {booking}, {car}, {pickup}, {return}, {amount}, {link}. Keep it short (160 characters is one text), no long dashes, and name CarmaCars.', phone_sms_payment_received_text: 'Placeholders: {first_name}, {booking}, {car}, {pickup}, {return}, {amount}, {link}. Keep it short (160 characters is one text), no long dashes, and name CarmaCars.', phone_sms_pickup_tomorrow_text: 'Placeholders: {first_name}, {booking}, {car}, {pickup}, {return}, {amount}, {link}. Keep it short (160 characters is one text), no long dashes, and name CarmaCars.',
  phone_sms_return_reminder_text: 'Placeholders: {first_name}, {booking}, {car}, {pickup}, {return}, {amount}, {link}. Keep it short (160 characters is one text), no long dashes, and name CarmaCars.', phone_sms_payment_link_text: 'Placeholders: {first_name}, {booking}, {car}, {pickup}, {return}, {amount}, {link}. Keep it short (160 characters is one text), no long dashes, and name CarmaCars.',
  phone_keep_months: 'Calls and texts of renters and owners stay with the rental records. The privacy policy says 12 months for the others.',
  phone_ai_daily_neurons: 'A draft or a summary uses about 50 to 100 neurons. Also stopped when all Workers AI use of the day reaches the Live chat cap.',
  signin_phone_us_allowed: 'Off until the CarmaCars Quo number is registered for US texting (A2P 10DLC, in Quo: Settings, Trust center). Without it US carriers block the codes. Canadian numbers always get codes.',
  signin_phone_enabled: 'Codes come by text from the CarmaCars number (Quo), 6 digits, valid 5 minutes. Off: the phone choice disappears from the sign-in pages; email sign-in is unchanged.',
  signin_confirm_by_phone: 'Off: only a confirmed email counts. An email is still needed before the first payment (for the receipts); the pay page asks for it.',
  chat_keep_days: 'Chats linked to a renter or booking are kept with the rental records. The privacy policy says 12 months for the others.'
};
// numbers with a range the database also checks
const RANGES: Record<string, [number, number]> = { signin_phone_hourly_per_number: [1, 50], signin_phone_hourly_per_ip: [1, 500], phone_missed_call_text_hours: [1, 168], phone_keep_months: [1, 120], owner_debit_notice_days: [10, 30], default_km_allowance_per_day: [1, 5000], request_response_target_minutes: [1, 1440] };
export function fieldFor(k: string, v: unknown, options?: Array<[string, string]>): Field {
  const f = fieldForBase(k, v, options);
  return { ...f, ...(LABELS[k] ? { label: LABELS[k] } : {}), ...(HINTS[k] ? { hint: HINTS[k] } : {}), ...(RANGES[k] ? { min: RANGES[k][0], max: RANGES[k][1] } : {}) };
}
function fieldForBase(k: string, v: unknown, options?: Array<[string, string]>): Field {
  if (options) return { name: k, label: nice(k), type: 'select', options, value: v, required: true };
  if (typeof v === 'boolean') return { name: k, label: nice(k), type: 'bool', value: v };
  if (k.endsWith('_cents') && (typeof v === 'number' || v === null)) return { name: k, label: nice(k), type: 'money', value: v };
  if (k.endsWith('_bps') && (typeof v === 'number' || v === null)) return { name: k, label: nice(k), type: 'percent', value: v };
  if (typeof v === 'number') return { name: k, label: nice(k), type: 'number', value: v };
  if (v !== null && typeof v === 'object') return { name: k, label: nice(k), type: 'json', value: v };
  if (typeof v === 'string' && v.length > 80) return { name: k, label: nice(k), type: 'textarea', value: v };
  return { name: k, label: nice(k), type: 'text', value: v };
}
export const fieldsFrom = (row: Record<string, unknown>, keys: string[], options: Record<string, Array<[string, string]>> = {}) => keys.filter((k) => k in row).map((k) => fieldFor(k, row[k], options[k]));
