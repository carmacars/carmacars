// The booking's facts in the shape of Blind Spot's form (layout.ts): the rental agreement's own facts (0028), what the
// form needs beyond them (0127) and everything else both agreements print (0143). Pure: the server and the tests share it.
// Relative imports with their extension: the unit tests run this file in Node directly.
import type { AgreementFacts } from '../agreement/model.ts';
import type { AgreementExtra } from '../agreement/extra.ts';
import type { BlindSpotFacts } from './layout.ts';

export interface BlindSpotExtraFacts {
  mailing: BlindSpotFacts['extra']['mailing']; hst_number: string | null; fleet_number: string | null; odometer_out_km: number | null; multi_day_rate_cents: number | null;
  insurer: BlindSpotFacts['extra']['insurer'];
}
export function toBlindSpotFacts(f: AgreementFacts, bs: BlindSpotExtraFacts, x: AgreementExtra | null): BlindSpotFacts {
  return {
    booking: { ...f.booking, multi_day_rate_cents: bs.multi_day_rate_cents }, renter: f.renter, drivers: f.drivers, vehicle: f.vehicle, lines: f.lines, card: f.card,
    extra: { mailing: bs.mailing, hst_number: bs.hst_number, fleet_number: bs.fleet_number, odometer_out_km: bs.odometer_out_km, insurer: bs.insurer,
      more: x, coverage: f.coverage, card_expiry: x?.card_expiry ?? null }
  };
}
