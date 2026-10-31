// R23: the delivery figures the public pages show (pure: the unit test and lib/site.ts use it).

/** What one delivery costs at least, each way: the car's own fee, never below the delivery minimum of Program settings
 *  (a car with no fee of its own was shown as "from $0"); app.delivery_fee prices it the same way. */
export function deliveryFrom(carFeeCents: number | null | undefined, minCents: number | null | undefined): number {
  return Math.max(carFeeCents ?? 0, minCents ?? 0);
}
/** Where delivery goes, in the words of Site settings (Delivery area text), else the service area. */
export function deliveryArea(s: { delivery_area_text?: string | null; service_area?: string | null }): string {
  return (s.delivery_area_text ?? '').trim() || (s.service_area ?? '');
}
