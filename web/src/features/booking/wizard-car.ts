// The request form's car (0102): built from public.booking_car on the server and in the browser alike. No imports, so
// the unit test runs it in Node.
export interface BookingCarRow {
  vehicle_id: string; slug: string; make: string; model: string; year: number | null; trim: string | null; name: string; from_cents: number;
  daily_rate_cents: number; weekend_rate_cents: number; weekly_rate_cents: number; monthly_rate_cents: number; multi_day_rate_cents?: number | null;
  insurance_included?: boolean | null; no_credit_card?: boolean | null; delivery_fee_cents: number; pickup_fee_cents: number; owner_location: boolean;
  allows_18_to_20: boolean; is_sample?: boolean | null; cover: { path: string; alt: string | null } | null;
}

export interface WizardCarShape {
  slug: string; vehicleId: string; name: string; year: number | null; trim: string | null; daily: number; weekend: number; weekly: number; monthly: number;
  multi?: number | null; insuranceIncluded?: boolean; noCreditCard?: boolean; delivery: number; pickup: number; ownerLocation: boolean; allowsYoung: boolean;
  cover: { path: string; alt: string } | null; from: number; isSample: boolean;
}

export function toWizardCar(x: BookingCarRow): WizardCarShape {
  return {
    slug: x.slug, vehicleId: x.vehicle_id, name: `${x.make} ${x.model}`, year: x.year, trim: x.trim, daily: x.daily_rate_cents, weekend: x.weekend_rate_cents,
    weekly: x.weekly_rate_cents, monthly: x.monthly_rate_cents, multi: x.multi_day_rate_cents ?? null, insuranceIncluded: !!x.insurance_included,
    noCreditCard: !!x.no_credit_card, delivery: x.delivery_fee_cents, pickup: x.pickup_fee_cents, ownerLocation: !!x.owner_location,
    allowsYoung: x.allows_18_to_20, cover: x.cover ? { path: x.cover.path, alt: x.cover.alt ?? '' } : null, from: x.from_cents, isSample: !!x.is_sample
  };
}
