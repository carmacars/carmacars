// What staff and renters read when the database refuses something for a reason of its own (a check, a unique key, a
// missing value), instead of the raw Postgres text (the simulation of October 24, 2026, item 15: "raw Postgres errors
// shown to staff"). The messages our functions raise on purpose are already sentences and pass through unchanged.
const CONSTRAINT: Record<string, string> = {
  bookings_bill_to_insurer: 'An insurer is billed only when the insurer is chosen: pick the insurer (Admin > Settings > Insurers adds one), or choose another way of payment.',
  bookings_billable_days_check: 'The rental is too long or too short: check the pickup and return dates.',
  bookings_check: 'The return must be after the pickup.',
  bookings_check1: 'The days do not match the dates: check the pickup and return.',
  bookings_check4: 'The discount is larger than the rental charge.',
  bookings_no_overlap: 'The car is already booked for part of these dates: choose other dates or another car.',
  vehicle_calendar_blocks_no_overlap: 'The car is already blocked for part of these dates.',
  renters_email_key: 'A renter with this email address already exists: find them by email instead of adding a new one.',
  users_email_key: 'An account with this email address already exists.'
};

export function friendlyDbMessage(raw: string): string {
  const m = raw.replace(/^.*?ERROR:\s*/, '');
  const named = m.match(/constraint "([^"]+)"/)?.[1];
  if (named && CONSTRAINT[named]) return CONSTRAINT[named]!;
  if (/violates check constraint/.test(m)) return 'That value is not allowed here: check the amounts and dates you typed. Nothing was saved.';
  if (/duplicate key value violates unique constraint/.test(m)) return 'That is already recorded (the same item exists): reload the page to see it. Nothing was saved.';
  if (/violates foreign key constraint/.test(m)) return /delete/i.test(m) ? 'It is still in use elsewhere, so it cannot be removed.' : 'Something this refers to no longer exists: reload the page and try again.';
  if (/null value in column "([^"]+)"/.test(m)) return `Something required is missing (${m.match(/null value in column "([^"]+)"/)![1]!.replace(/_/g, ' ')}). Fill it in and try again.`;
  if (/invalid input syntax for type (uuid|integer|bigint|numeric|date|timestamp)/.test(m)) return 'A value is not in the expected form (a number, a date or a choice from the list): check what you typed.';
  if (/value too long for type/.test(m)) return 'A value is too long: shorten it and try again.';
  if (/numeric field overflow|out of range for type/.test(m)) return 'A number is too large: check the amount.';
  if (/could not serialize access|deadlock detected/.test(m)) return 'Someone else changed this at the same moment: try again.';
  if (/^permission denied for/.test(m)) return 'Not permitted for your role.';
  return m;
}
