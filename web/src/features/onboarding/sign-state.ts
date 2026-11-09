// The signature of a government form (r35, 1000): the state the database gives each form (unsigned, signed, changed since
// it was signed, or signed in ink) in the owner's and staff's words. Pure: unit-tested in sign-state.test.ts.

export type SignState = 'unsigned' | 'signed' | 'changed' | 'ink';
export type Audience = 'owner' | 'staff';

export interface SignBadge { text: string; tone: 'ok' | 'todo' | 'warn' | 'muted' }

/** The badge a form shows in the Documents list and on the staff page. */
export function signBadge(state: SignState | null | undefined, signable = true): SignBadge | null {
  if (!state) return null;
  if (state === 'signed') return { text: 'Signed', tone: 'ok' };
  if (state === 'ink') return { text: 'Signed in ink', tone: 'ok' };
  if (state === 'changed') return signable ? { text: 'Changed since signed', tone: 'warn' } : { text: 'Changed since signed, a value is missing', tone: 'warn' };
  return signable ? { text: 'Not signed', tone: 'todo' } : { text: 'Waiting for a value', tone: 'muted' };
}

/** Does the owner have something to sign for this form? */
export const needsSignature = (state: SignState | null | undefined, signable: boolean): boolean => (state === 'unsigned' || state === 'changed') && signable;

/** One line for the owner (their Documents list) or staff about all the forms of a car. */
export function signSummary(forms: Array<{ sign_state?: SignState | null; signable?: boolean }>, who: Audience): string {
  const todo = forms.filter((f) => needsSignature(f.sign_state, f.signable ?? true));
  const changed = todo.filter((f) => f.sign_state === 'changed').length;
  const signed = forms.filter((f) => f.sign_state === 'signed' || f.sign_state === 'ink').length;
  if (forms.length === 0) return '';
  if (todo.length === 0) return signed === forms.length ? (who === 'owner' ? 'You signed every form.' : 'The owner signed every form.') : '';
  const n = `${todo.length} of ${forms.length} form${forms.length === 1 ? '' : 's'}`;
  if (who === 'owner') return changed ? `${n} to sign: ${changed === 1 ? 'a form changed' : `${changed} forms changed`} after you signed, so ${changed === 1 ? 'it needs' : 'they need'} your signature again.` : `${n} to sign.`;
  return changed ? `${n} waiting for the owner's signature, ${changed} changed since signed: the owner is asked to sign again.` : `${n} waiting for the owner's signature.`;
}

export interface SignatureFacts { signer_name: string; method: 'drawn' | 'typed'; typed_name: string | null; signed_at: string; form_version: number | null; current_version: number; same_values: boolean; changed: string[] }

/** What the staff page says beside the form about the signature. */
export function signatureLine(s: SignatureFacts, when: (iso: string) => string): string {
  const how = s.method === 'typed' ? 'typed name' : 'drawn signature';
  const base = `${s.signer_name} signed with a ${how} on ${when(s.signed_at)}${s.form_version ? `, version ${s.form_version}` : ''}.`;
  if (s.same_values) return base;
  return `${base} The form has changed since: this is version ${s.current_version}. The owner is asked to sign again.`;
}
