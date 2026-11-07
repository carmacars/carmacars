// Release 33 (0700): the extra photos' order (ExtraOrder.tsx). Pure.
/** The list with the item at `from` moved to `to` (both held inside the list). */
export function moveItem<T>(list: readonly T[], from: number, to: number): T[] {
  const out = list.slice();
  if (from < 0 || from >= out.length) return out;
  const t = Math.max(0, Math.min(out.length - 1, to));
  const [x] = out.splice(from, 1);
  out.splice(t, 0, x!);
  return out;
}
/** The shots whose photos are extras: any number, after the standard shots, in the order staff give them. */
export const EXTRA_SHOTS = ['exterior_more', 'other'] as const;
export const isExtra = (shot: string) => (EXTRA_SHOTS as readonly string[]).includes(shot);
