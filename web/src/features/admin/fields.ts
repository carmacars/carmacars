import type { Field } from './Act';

// Form fields from a database row: the type follows the column's name and value, so a new setting
// appears on the settings screen without a developer.
const nice = (k: string) => { const s = k.replace(/_(cents|bps)$/, '').replace(/_/g, ' '); return s.charAt(0).toUpperCase() + s.slice(1); };
// settings whose meaning needs a sentence (0042: one turnaround between trips; the tolls, plates and vision settings)
const LABELS: Record<string, string> = {
  turnaround_buffer_minutes: 'Turnaround between trips (minutes)', turnaround_block_enabled: 'Show the turnaround as a cleaning block on the calendar',
  toll_read_min_confidence: 'Notice reading: confidence needed to import without a check (0 to 100)', toll_read_auto_charge: 'Notice reading: charge renters matched with high confidence when confirmed',
  toll_read_max_pages: 'Notice reading: pages sent to the vision model', listing_plate_check_required: 'Every public listing photo needs its plate covered or marked not visible before publishing',
  plate_cover_style: 'Default way to cover a plate (cover, pixelate or blur)', plate_cover_text: 'Text on the plate cover (empty: the brand name)', plate_detect_enabled: 'Suggest the plate box with the vision model',
  notify_daily_cap: 'Emails a day (the email provider\'s daily limit)', notify_class_limits: 'Daily count under which each kind may still send: customer, owner and investor, staff, digests, marketing',
  notify_cap_warn_bps: 'Warn the Admins in the portal at this share of the daily limit', notify_count_auth_emails: 'Count sign-in emails (sent by Supabase through the same provider) in the daily limit',
  ai_vision_enabled: 'Vision model on', ai_vision_model: 'Vision model', ai_vision_fallback_model: 'Vision model if the first is not available', ai_vision_daily_neurons: 'Vision model: neurons a day'
};
const HINTS: Record<string, string> = {
  turnaround_buffer_minutes: 'One time between trips (default 120). No trip may start within it after another ends, and a trip must end this long before the next starts. After each trip it shows as the cleaning block; removing the block frees the time. It is never added twice. A car can have its own under Vehicles, the car, Calendar.',
  turnaround_block_enabled: 'Off: the same time is still held after each trip, without a block on the calendar.',
  toll_read_min_confidence: 'Lines read below this, or with something missing, wait for a person to check them; the rest are imported when the read is confirmed.',
  notify_class_limits: 'Five numbers, in this order: customer booking emails, owner and investor emails, immediate staff emails, digests and summaries, marketing. Keep the first under the daily limit so sign-in emails always have room (default 97, 95, 90, 80, 60 of 100). What cannot go waits until after midnight; nothing is dropped.',
  ai_vision_daily_neurons: 'Cloudflare gives 10,000 neurons a day free, shared with the listing copy. A scanned page uses about 100 to 300.'
};
export function fieldFor(k: string, v: unknown, options?: Array<[string, string]>): Field {
  const f = fieldForBase(k, v, options);
  return { ...f, ...(LABELS[k] ? { label: LABELS[k] } : {}), ...(HINTS[k] ? { hint: HINTS[k] } : {}) };
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
