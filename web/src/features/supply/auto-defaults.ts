// What was set automatically on a car and its rate card (migration 0087): {field: {value, source}}. A value is marked
// only while it is still the one set automatically, so a value a person changed loses its mark.
export type AutoDefaults = Record<string, { value?: unknown; source?: string } | undefined>;

const CARD_FIELDS: Record<string, string> = {
  daily: 'daily_rate_cents', weekend: 'weekend_rate_cents', weekly: 'weekly_rate_cents', monthly: 'monthly_rate_cents',
  km_per_day: 'km_allowance_per_day', overage: 'overage_cents_per_km', deposit: 'deposit_cents', delivery: 'delivery_fee_cents', pickup: 'pickup_fee_cents'
};
export const CARD_LABELS: Record<string, string> = {
  daily: 'Daily rate', weekend: 'Weekend rate', weekly: 'Weekly rate', monthly: 'Monthly rate', km_per_day: 'Kilometres a day',
  overage: 'Extra kilometre rate', deposit: 'Deposit', delivery: 'Delivery fee', pickup: 'Pickup fee'
};

/** The source of a car field's automatic value, or null when it is not (or no longer) the automatic one. */
export function autoSource(auto: unknown, field: string, current: unknown): string | null {
  const a = (auto && typeof auto === 'object' ? (auto as AutoDefaults)[field] : undefined);
  if (!a) return null;
  if (a.value !== undefined && String(a.value) !== String(current)) return null;
  return a.source ?? 'Set automatically';
}

/** The rate card's values still at their automatic value, in the form's order. */
export function autoCardFields(card: Record<string, unknown> | null | undefined): Array<{ key: string; label: string; source: string }> {
  if (!card) return [];
  const auto = card.auto_defaults;
  return Object.keys(CARD_FIELDS).flatMap((k) => {
    const s = autoSource(auto, k, card[CARD_FIELDS[k]!]);
    return s ? [{ key: k, label: CARD_LABELS[k]!, source: s }] : [];
  });
}
