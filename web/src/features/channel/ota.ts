// Release 37 (2304): the OTA-style XML variant of the Channel API (OpenTravel 2003B+ vehicle messages, the subset the
// brokers send): OTA_VehAvailRateRQ in, OTA_VehAvailRateRS out, built from the same JSON the /availability call returns.
// Pure (tested); no XML library: the request is read for its few attributes, the answer escaped field by field.

export interface AvailRq { pickupAt: string; returnAt: string; echoToken: string | null }
export interface QuoteCar { ref: string; available: boolean; currency: string; total_cents: number; rental_cents: number; billable_days: number | null; km_per_day: number | null; deposit_cents: number | null }
export interface VehicleInfo { ref: string; class: string; make: string; model: string; year: number; seats: number | null; transmission: string | null; photos: string[] }

const attr = (xml: string, el: string, name: string): string | null => {
  const m = new RegExp(`<(?:\\w+:)?${el}\\b[^>]*\\b${name}\\s*=\\s*"([^"]*)"`, 'i').exec(xml);
  return m ? m[1]! : null;
};
/** The pickup and return times of an OTA_VehAvailRateRQ (VehRentalCore PickUpDateTime / ReturnDateTime), or null. */
export function parseAvailRq(xml: string): AvailRq | null {
  if (!/<(?:\w+:)?OTA_VehAvailRateRQ\b/i.test(xml) || /<!DOCTYPE|<!ENTITY/i.test(xml)) return null;
  const pickupAt = attr(xml, 'VehRentalCore', 'PickUpDateTime'), returnAt = attr(xml, 'VehRentalCore', 'ReturnDateTime');
  if (!pickupAt || !returnAt || Number.isNaN(Date.parse(pickupAt)) || Number.isNaN(Date.parse(returnAt))) return null;
  return { pickupAt, returnAt, echoToken: attr(xml, 'OTA_VehAvailRateRQ', 'EchoToken') };
}

export const esc = (s: unknown) => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&apos;');
const amt = (cents: number) => (cents / 100).toFixed(2);

/** OTA_VehAvailRateRS: one VehAvail per car that can be booked for the times, with its total and rate per day. */
export function availRs(rq: AvailRq, cars: QuoteCar[], info: Map<string, VehicleInfo>, now = new Date()): string {
  const avail = cars.filter((c) => c.available).map((c) => {
    const v = info.get(c.ref);
    const days = c.billable_days || 1;
    return `<VehAvail><VehAvailCore Status="Available"><Vehicle TransmissionType="${esc(v?.transmission === 'Manual' ? 'Manual' : 'Automatic')}" PassengerQuantity="${esc(v?.seats ?? '')}" Code="${esc(c.ref)}">`
      + `<VehMakeModel Name="${esc(v ? `${v.year} ${v.make} ${v.model}` : c.ref)}" Code="${esc(v?.class ?? '')}"/>${v?.photos[0] ? `<PictureURL>${esc(v.photos[0])}</PictureURL>` : ''}</Vehicle>`
      + `<RentalRate><RateDistance Unlimited="false" Quantity="${esc(c.km_per_day ?? '')}" DistUnitName="Km" VehiclePeriodUnitName="Day"/>`
      + `<VehicleCharges><VehicleCharge Purpose="1" CurrencyCode="${esc(c.currency)}" Amount="${amt(c.rental_cents)}" TaxInclusive="false"><Calculation UnitCharge="${amt(Math.round(c.rental_cents / days))}" UnitName="Day" Quantity="${days}"/></VehicleCharge></VehicleCharges></RentalRate>`
      + `<TotalCharge RateTotalAmount="${amt(c.rental_cents)}" EstimatedTotalAmount="${amt(c.total_cents)}" CurrencyCode="${esc(c.currency)}"/>`
      + (c.deposit_cents ? `<Fees><Fee Purpose="Deposit" Amount="${amt(c.deposit_cents)}" CurrencyCode="${esc(c.currency)}"/></Fees>` : '')
      + '</VehAvailCore></VehAvail>';
  }).join('');
  return `<?xml version="1.0" encoding="UTF-8"?><OTA_VehAvailRateRS xmlns="http://www.opentravel.org/OTA/2003/05" Version="1.0" TimeStamp="${now.toISOString()}"${rq.echoToken ? ` EchoToken="${esc(rq.echoToken)}"` : ''}>`
    + `<Success/><VehAvailRSCore><VehRentalCore PickUpDateTime="${esc(rq.pickupAt)}" ReturnDateTime="${esc(rq.returnAt)}"/><VehVendorAvails><VehVendorAvail><Vendor>CarmaCars</Vendor><VehAvails>${avail}</VehAvails></VehVendorAvail></VehVendorAvails></VehAvailRSCore></OTA_VehAvailRateRS>`;
}

/** An OTA error answer. */
export const errorRs = (message: string, code = '450') =>
  `<?xml version="1.0" encoding="UTF-8"?><OTA_VehAvailRateRS xmlns="http://www.opentravel.org/OTA/2003/05" Version="1.0"><Errors><Error Type="3" Code="${esc(code)}">${esc(message)}</Error></Errors></OTA_VehAvailRateRS>`;
