// Phone numbers for sign-in (migration 0091). No imports: used by the browser forms, the server actions, the SMS hook
// and the unit tests (phone.test.ts). The database checks the same rules again (app.phone_e164, app.phone_country,
// app.signin_phone_check); phone.test.ts reads the migration so the area code lists cannot drift apart.

/** Canadian geographic area codes (CNA, 2026). Texts to them need no A2P 10DLC registration in Quo. */
export const CA_AREA_CODES: readonly string[] = [
  '204', '226', '236', '249', '250', '257', '263', '289', '306', '343', '354', '365', '367', '368', '382', '387', '403', '416', '418', '428',
  '431', '437', '438', '450', '460', '468', '474', '506', '514', '519', '548', '579', '581', '584', '587', '604', '613', '639', '647', '672',
  '683', '705', '709', '742', '753', '778', '780', '782', '807', '819', '825', '867', '873', '879', '902', '905', '942'
];

/** +1 area codes that are neither the United States nor Canada (Caribbean and Atlantic NANP countries), toll-free
 *  and special numbers. */
export const NANP_NOT_US: readonly string[] = [
  '242', '246', '264', '268', '284', '345', '441', '473', '649', '658', '664', '721', '758', '767', '784', '809', '829', '849', '868', '869', '876',
  '500', '521', '522', '523', '524', '525', '526', '527', '528', '529', '533', '544', '566', '577', '588', '600', '622', '633', '644', '655', '677', '688',
  '700', '710', '800', '822', '833', '844', '855', '866', '877', '880', '881', '882', '883', '884', '885', '886', '887', '888', '889', '900'
];

/** "+16475551234" from what a person typed, or null when it is not a phone number (the rule of app.phone_e164). */
export function toE164(input: string | null | undefined): string | null {
  const raw = String(input ?? '').trim();
  const d = raw.replace(/\D/g, '');
  if (/^[2-9]\d{9}$/.test(d)) return `+1${d}`;
  if (/^1[2-9]\d{9}$/.test(d)) return `+${d}`;
  if (raw.startsWith('+') && d.length >= 8 && d.length <= 15 && d[0] !== '0') return `+${d}`;
  return null;
}

export type PhoneCountry = 'CA' | 'US' | 'other';
/** Canada, the United States or anywhere else, for a number in any form (null when it is not a number). */
export function phoneCountry(input: string | null | undefined): PhoneCountry | null {
  const n = toE164(input);
  if (!n) return null;
  if (!/^\+1[2-9]\d{2}[2-9]\d{6}$/.test(n)) return 'other';
  const area = n.slice(2, 5);
  if (CA_AREA_CODES.includes(area)) return 'CA';
  if (NANP_NOT_US.includes(area) || area.slice(1) === '11') return 'other';
  return 'US';
}

export const isCanadianAreaCode = (area: string) => CA_AREA_CODES.includes(area);

export type SignInPhoneCheck = { ok: true; phone: string; country: PhoneCountry } | { ok: false; reason: 'invalid' | 'country'; phone: string | null; message: string };
/** May this number sign in? Canadian numbers always; US numbers only when an Admin allowed them (A2P 10DLC). */
export function checkSignInPhone(input: string | null | undefined, usAllowed: boolean): SignInPhoneCheck {
  const phone = toE164(input);
  const country = phoneCountry(input);
  if (!phone || !country) return { ok: false, reason: 'invalid', phone: null, message: 'Enter a mobile number with its area code, for example 647 555 1234.' };
  if (country === 'CA' || (country === 'US' && usAllowed)) return { ok: true, phone, country };
  return { ok: false, reason: 'country', phone, message: usAllowed
    ? 'Sign-in codes are texted to Canadian and US mobile numbers only. Sign in with your email instead.'
    : 'Sign-in codes are texted to Canadian mobile numbers only for now. Sign in with your email instead.' };
}

/** (647) 555-1234 for a +1 number; the E.164 form otherwise. */
export function formatPhone(input: string | null | undefined): string {
  const n = toE164(input);
  if (!n) return String(input ?? '');
  const m = /^\+1(\d{3})(\d{3})(\d{4})$/.exec(n);
  return m ? `(${m[1]}) ${m[2]}-${m[3]}` : n;
}

/** A 6-digit code from what was typed or pasted ("123 456", "123-456"); null otherwise. */
export function cleanCode(input: string | null | undefined): string | null {
  const d = String(input ?? '').replace(/[\s-]/g, '');
  return /^\d{6}$/.test(d) ? d : null;
}
