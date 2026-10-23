// Kept apart from fill.ts so the owner's form page knows whether it offers "Sign on screen" without loading pdf-lib.
// Relative imports with their extension: the unit tests run this file in Node directly.
import type { Spec } from './fill.ts';

/** Whether the owner signs this form on screen: a signature field the database kept for this car (a signature with a
 *  condition is kept only when the condition held, for example the second registrant's line under Co-Registrant). */
export function ownerSigns(values: Record<string, string | null>, map: Record<string, Spec | string>): boolean {
  return Object.entries(map).some(([name, s]) => typeof s !== 'string' && s.type === 'signature' && (!s.when || name in values));
}
