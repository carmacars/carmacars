// What the signer does next, from the signing session the server gives (the same session as the site's Sign and pay
// page, migration 0154). The server decides what is required; this only orders it for one screen at a time.
import type { EsignView } from '../shared.ts';

export type SignStage = 'code' | 'read' | 'initials' | 'consents' | 'signature' | 'ready' | 'done';
export function stageOf(v: EsignView): SignStage {
  if (v.signed) return 'done';
  if (v.code_required && !v.verified) return 'code';
  if (!v.viewed) return 'read';
  if (v.required_initials.some((c) => !v.initials.includes(c))) return 'initials';
  if (v.required_consents.some((c) => !v.consents.includes(c))) return 'consents';
  if (!v.signature) return 'signature';
  return 'ready';
}
export const initialsLeft = (v: EsignView) => v.required_initials.filter((c) => !v.initials.includes(c));
export const consentsLeft = (v: EsignView) => v.required_consents.filter((c) => !v.consents.includes(c));
/** Progress for the bar: the steps done out of the steps this session asks for. */
export function progress(v: EsignView): { done: number; total: number } {
  const total = (v.code_required ? 1 : 0) + 1 + v.required_initials.length + v.required_consents.length + 1;
  const done = (v.code_required && v.verified ? 1 : 0) + (v.viewed ? 1 : 0) + v.required_initials.filter((c) => v.initials.includes(c)).length
    + v.required_consents.filter((c) => v.consents.includes(c)).length + (v.signature ? 1 : 0);
  return { done, total };
}
/** Initials from a legal name: "Rita Marie Renter" -> "RMR" (the signer can change them). */
export const initialsOf = (name: string) => name.trim().split(/\s+/).filter(Boolean).map((w) => w[0]!.toUpperCase()).join('').slice(0, 4);
