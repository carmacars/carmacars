// r48 FE (3197): the data checks of a person's own record, as the pop-up shows them. Pure, for the modal and the tests.
export type Severity = 'blocking' | 'warning';
export interface DataIssue {
  key: string; audience: 'staff' | 'owner' | 'renter'; severity: Severity; label: string; message: string; allow_confirm: boolean;
  fix: { kind?: 'agreement' | 'address' | 'licence' | 'phone' | 'whatsapp_tag' | 'link'; fields?: string[]; address?: string; postal?: string; value?: string | null; tag?: string; href?: string; label?: string };
}

/** Blocking first; the pop-up cannot be closed while one is open. */
export function order(issues: DataIssue[]): DataIssue[] {
  return [...issues].sort((a, b) => (a.severity === b.severity ? 0 : a.severity === 'blocking' ? -1 : 1));
}
export const closable = (issues: DataIssue[]) => issues.every((i) => i.severity !== 'blocking');

/** The inputs a fix asks for. */
export function inputsOf(i: DataIssue): Array<{ name: string; label: string; type: 'text' | 'address' | 'date' | 'tel' | 'check'; value?: string }> {
  const k = i.fix.kind;
  if (k === 'agreement') return [
    ...(i.fix.fields?.includes('licence') ? [{ name: 'licence_number', label: 'Driver\'s licence number', type: 'text' as const }, { name: 'licence_expiry', label: 'Licence expiry date', type: 'date' as const }] : []),
    ...(i.fix.fields?.includes('address') ? [{ name: 'home_address', label: 'Home address (number, street, city, province)', type: 'address' as const }, { name: 'home_postal_code', label: 'Postal code', type: 'text' as const }] : [])];
  if (k === 'address') return [{ name: 'home_address', label: 'Home address', type: 'address', value: i.fix.address ?? '' }, { name: 'home_postal_code', label: 'Postal code', type: 'text', value: i.fix.postal ?? '' }];
  if (k === 'licence') return [{ name: 'licence_number', label: 'Driver\'s licence number (if it changed)', type: 'text' }, { name: 'licence_expiry', label: 'Licence expiry date', type: 'date' }];
  if (k === 'phone') return [{ name: 'phone', label: 'Mobile number', type: 'tel', value: i.fix.value ?? '' }];
  if (k === 'whatsapp_tag') return [{ name: 'tag_set', label: `I set my member tag "${i.fix.tag ?? ''}" in each group`, type: 'check' }];
  return [];
}
