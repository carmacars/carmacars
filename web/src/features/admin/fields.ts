import type { Field } from './Act';

// Form fields from a database row: the type follows the column's name and value, so a new setting
// appears on the settings screen without a developer.
const nice = (k: string) => { const s = k.replace(/_(cents|bps)$/, '').replace(/_/g, ' '); return s.charAt(0).toUpperCase() + s.slice(1); };
// settings whose meaning needs a sentence (0042: one turnaround between trips; the tolls, plates and vision settings)
const LABELS: Record<string, string> = {
  vpage_place_index: 'Index the place pages', vpage_colour_index: 'Index the colour pages', vpage_term_index: 'Index the search term pages', vpage_buy_index: 'Index the /buy pages',
  vpage_detailing_index: 'Index the detailing pages', vpage_bodyshop_index: 'Index the body shop pages', vpage_finance_disclaimer: 'Financing disclaimer',
  vpage_import_db_cap_mb: 'Database size cap for the catalog import (MB)', indexnow_daily_max: 'IndexNow: most addresses a day', indexnow_batch: 'IndexNow: addresses a request (at most 10,000)',
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
  chat_keep_days: 'Chats linked to a renter or booking are kept with the rental records. The privacy policy says 12 months for the others.'
};
// numbers with a range the database also checks
const RANGES: Record<string, [number, number]> = { owner_debit_notice_days: [10, 30], default_km_allowance_per_day: [1, 5000], request_response_target_minutes: [1, 1440] };
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
