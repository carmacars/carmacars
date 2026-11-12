// The caller's own mobile (r40 hotfix, migration 2460). The site's Call button rings the staff member's own phone first,
// then connects the customer; a staff member with no mobile on file is asked for it in a pop-up, it is saved to their
// profile (no texted code: the call itself rings it) and the call is placed. No imports, so the unit tests run it as it is
// (my-number.test.ts); the database checks the number again (app.staff_set_call_phone).

export type MyNumberCheck = { ok: true; e164: string; display: string } | { ok: false; message: string };

export const MY_NUMBER_HELP = 'Enter your Canadian or US mobile number, 10 digits, for example (647) 555-0123';

/** A North American mobile typed any way ("647 555 0123", "+1 (647) 555-0123", "1-647-555-0123"), or why not. */
export function checkMyNumber(raw: string | null | undefined): MyNumberCheck {
  const s = (raw ?? '').trim();
  if (!s) return { ok: false, message: 'Enter your mobile number.' };
  if (/[^\d\s()+.\-]/.test(s)) return { ok: false, message: `${MY_NUMBER_HELP}.` };
  let d = s.replace(/\D/g, '');
  if (d.length === 11 && d.startsWith('1')) d = d.slice(1);
  else if (s.startsWith('+') && !s.startsWith('+1')) return { ok: false, message: `Only Canadian and US mobiles can be called first. ${MY_NUMBER_HELP}.` };
  if (d.length !== 10) return { ok: false, message: `${MY_NUMBER_HELP}.` };
  // North American numbering: the area code and the exchange start with 2 to 9; N11 codes (411, 911) are not numbers
  if (!/^[2-9]\d{2}[2-9]\d{6}$/.test(d) || /^\d11/.test(d)) return { ok: false, message: `That is not a valid number. ${MY_NUMBER_HELP}.` };
  return { ok: true, e164: `+1${d}`, display: `(${d.slice(0, 3)}) ${d.slice(3, 6)}-${d.slice(6)}` };
}

/** What the Call pop-up shows for the server's answer to a call: ringing, the number box, or the message to act on. */
export type CallAnswer = { ok?: boolean; need_phone?: boolean; message?: string; calling?: string; fallback?: string | null; error?: string };
export type CallView = { kind: 'ringing'; calling?: string } | { kind: 'ask_number'; message: string } | { kind: 'problem'; message: string };

export function callView(a: CallAnswer | null | undefined, masked: boolean): CallView {
  if (a?.ok) return { kind: 'ringing', calling: a.calling };
  if (a?.need_phone) return { kind: 'ask_number', message: a.message || 'Add your mobile number first: the call rings your phone, then connects the customer.' };
  const m = (a?.message || a?.error || '').trim() || 'The call did not start. Try again in a moment.';
  // calling from the site is not set up (Quo fallback): Sales has no number to dial, so say who can call
  if (masked && a?.fallback === 'quo') return { kind: 'problem', message: `${m} The number is hidden for Sales: ask customer service or an Admin to call, and tell an Admin that calling from the site needs fixing.` };
  return { kind: 'problem', message: m };
}
