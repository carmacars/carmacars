// The renter's own auto insurer (OPCF 27, coverage option 1), picked from a list wherever staff or renters enter it: the
// renter's coverage upload in the portal, staff's "Upload a document", the agreement's fields (migration 0186's
// change). The plain name is stored as before; "Other (type it)" takes any other name. Relative imports only: the unit
// tests run it directly.

/** Canadian and Ontario auto insurers, in alphabetical order (a leading "The" is ignored). */
export const INSURANCE_COMPANIES: readonly string[] = [
  'Allstate', 'Aviva', 'Belairdirect', 'CAA Insurance', 'Chubb', 'The Co-operators', 'Coachman', 'Definity', 'Desjardins',
  'Echelon', 'Economical', 'Gore Mutual', 'Intact', 'Jevco', 'Northbridge', 'Old Republic', 'Optimum', 'Peel Mutual',
  'Pembridge', 'Primmum', 'RBC Insurance', 'SGI Canada', 'Sonnet', 'Square One', 'TD Insurance', 'Travelers', 'Unica',
  'Wawanesa', 'Western Assurance'
];

/** The choice that shows a text box for any other insurer. */
export const OTHER_INSURER = '__other__';
export const OTHER_INSURER_LABEL = 'Other (type it)';

/** How the list is ordered: the name without a leading "The", ignoring case. */
export const insurerSortKey = (name: string) => name.replace(/^the\s+/i, '').toLowerCase();

const squash = (s: string) => s.toLowerCase().replace(/^the\s+/, '').replace(/[^a-z0-9]/g, '');

/** The list's own spelling of a name typed or saved before ("td insurance", "Co-operators"), or null when it is not on
 *  the list (an "Other" insurer). */
export function matchInsurer(name: string | null | undefined): string | null {
  const k = squash(name ?? '');
  if (!k) return null;
  return INSURANCE_COMPANIES.find((c) => squash(c) === k) ?? null;
}
