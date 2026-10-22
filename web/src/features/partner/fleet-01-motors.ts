// The 01 Motors partner fleet and chauffeur price guide (the owner's request of October 22, 2026; migration 0093).
//
// The source is the partner's price sheet (a one-page PDF in two columns; its text is the fixture
// fixtures/01-motors-price-sheet.txt). parseSheet() reads every row of both columns; SHEET is the parsed result, checked
// against the fixture by the unit test, and CARS turns each sheet row into a car: make, model, trim and colour from the
// row's name, in proper case, with the body, seats, doors, drive, gearbox and class of that model. The sheet has no
// years, VINs or plates: the year is the latest plausible model year, flagged as approximate (the public pages leave it
// out and say "Year confirmed when you book"), and no VIN or plate is invented. supabase/seed/0093_gen.mjs writes the
// migration's data block from this file.
//
// Money: whole cents. The sheet's rates are the partner's ("sheet rates"); the renter pays the sheet rate marked up
// (10% by default) rounded to the nearest dollar, the site's whole-dollar prices; CarmaCars keeps the markup plus its
// cut (20% of the sheet rate by default) and the partner is owed the rest of the sheet rate.

export interface SheetRental { name: string; base: number; multi: number; long: number }
export type ChauffeurKind = 'chauffeur_only' | 'chauffeur_rental';
export interface SheetChauffeur { name: string; kind: ChauffeurKind; twoHour: number; threePlus: number }

const RENTAL_ROW = /([A-Za-z0-9][A-Za-z0-9.-]*(?: [A-Za-z0-9.-]+)*)\s{2,}\$(\d+)\s+\$(\d+)\s+\$(\d+)(?!\/)/g;
const CHAUFFEUR_ROW = /([A-Za-z0-9][A-Za-z0-9.-]*(?: [A-Za-z0-9.-]+)*) \((chauffeur only|chauffeur \/ rental)\)\s+\$(\d+)\/hr\s+\$(\d+)\/hr/g;

/** Every rental row (both columns, top to bottom, left column first) and every chauffeur row of the sheet's text. */
export function parseSheet(text: string): { rentals: SheetRental[]; chauffeur: SheetChauffeur[] } {
  const left: SheetRental[] = [];
  const right: SheetRental[] = [];
  const chauffeur: SheetChauffeur[] = [];
  for (const line of text.split(/\r?\n/)) {
    // the two columns of the rental guide split at the page's middle (about column 80 of the text); the chauffeur
    // guide is only ever in the right column
    for (const m of line.matchAll(RENTAL_ROW)) {
      const row = { name: m[1]!, base: Number(m[2]) * 100, multi: Number(m[3]) * 100, long: Number(m[4]) * 100 };
      (m.index! < 70 ? left : right).push(row);
    }
    for (const m of line.matchAll(CHAUFFEUR_ROW)) {
      chauffeur.push({ name: m[1]!, kind: m[2] === 'chauffeur only' ? 'chauffeur_only' : 'chauffeur_rental', twoHour: Number(m[3]) * 100, threePlus: Number(m[4]) * 100 });
    }
  }
  return { rentals: [...left, ...right], chauffeur };
}

// ---------------------------------------------------------------- the sheet, parsed (checked against the fixture)
// [name, base (1-2 days), multiple day (3+ days), long term (7+ days)], dollars per day, as printed.
const R: Array<[string, number, number, number]> = [
  ['Mercedes A220', 140, 120, 100], ['Mercedes A35 AMG', 200, 175, 150], ['Mercedes C300 Conv', 200, 175, 140],
  ['Mercedes C300 Sedan Black', 200, 175, 150], ['Mercedes C300 Sedan Grey', 175, 150, 150], ['Mercedes C43 AMG Blue', 250, 225, 200],
  ['Mercedes C43 AMG White', 250, 225, 200], ['Mercedes C43 AMG Grey', 240, 200, 180], ['Mercedes C63s AMG', 400, 375, 325],
  ['Mercedes E43 AMG', 250, 225, 200], ['Mercedes E53 AMG Coupe', 350, 300, 275], ['Mercedes GT53 AMG', 420, 375, 350],
  ['Mercedes S500', 450, 400, 325], ['Mercedes S580', 600, 575, 550], ['Mercedes S580 Maybach', 450, 400, 325],
  ['Mercedes S63 AMG', 700, 650, 600], ['Mercedes GLB250', 150, 120, 100], ['Mercedes GLB35 AMG', 200, 175, 150],
  ['Mercedes GLC43 AMG SUV', 225, 200, 180], ['Mercedes GLC43 AMG Coupe', 250, 225, 200], ['Mercedes GLE53 AMG', 350, 325, 300],
  ['Mercedes GLE53 AMG Coupe', 400, 400, 400], ['Mercedes G63 AMG', 1000, 1000, 900], ['Mercedes GLS600 Maybach', 1500, 1200, 1000],
  ['BMW 330i MSport', 200, 175, 120], ['BMW M340i', 250, 225, 200], ['BMW M3 Comp', 500, 475, 400], ['BMW 430i MSport', 225, 200, 175],
  ['BMW M440i', 250, 225, 200], ['BMW M440i Gran Coupe', 300, 275, 250], ['BMW M4 Comp White', 475, 450, 375],
  ['BMW M4 Comp Black', 750, 725, 700], ['BMW 530i MSport', 200, 175, 150], ['BMW X3M Comp', 350, 325, 300],
  ['BMW X4M40i', 250, 220, 200], ['BMW X5 MSport', 225, 200, 175], ['BMW X6M', 375, 350, 325],
  ['Audi A5 Conv', 200, 175, 150], ['Audi S5', 230, 200, 200], ['Audi R8 Spyder', 1000, 900, 900],
  ['Porsche 718 Boxster', 400, 375, 325], ['Porsche 911 Turbo S', 2000, 2000, 1900], ['Porsche Macan S', 250, 225, 200],
  ['Porsche Cayenne', 275, 250, 225], ['Range Rover Velar White', 220, 200, 175], ['Range Rover Velar Blue', 250, 220, 200],
  ['Range Rover Sport V6', 250, 220, 200], ['Range Rover Sport V8', 300, 275, 250], ['Range Rover Autobiography', 600, 600, 600],
  ['Ferrari California T', 1500, 1450, 1400], ['Ferrari 488 Spider', 2000, 1800, 1600], ['Mclaren 570s', 1500, 1450, 1400],
  ['Lamborghini Urus', 2000, 1800, 1600], ['Corvette C8 Stingray', 700, 600, 500], ['Chevrolet Suburban', 400, 375, 325],
  ['Cadillac Escalade', 600, 550, 500], ['Cadillac Escalade ESV', 600, 550, 500], ['Rolls Royce Ghost', 1000, 900, 800],
  ['Bentley Bentayga', 1200, 1100, 1000], ['Ford Mustang Conv', 150, 120, 100], ['Infiniti Q60', 200, 175, 150], ['Maserati Levante', 250, 220, 200]
];
export const SHEET_RENTALS: SheetRental[] = R.map(([name, b, m, l]) => ({ name, base: b * 100, multi: m * 100, long: l * 100 }));

export const SHEET_CHAUFFEUR: SheetChauffeur[] = ([
  ['Mercedes GLS Maybach', 'chauffeur_only', 350, 300], ['Mercedes S580', 'chauffeur_rental', 200, 175], ['Mercedes S680', 'chauffeur_rental', 225, 200],
  ['Chevrolet Suburban', 'chauffeur_rental', 175, 150], ['Cadillac Escalade', 'chauffeur_rental', 200, 175], ['Range Rovers', 'chauffeur_rental', 200, 150],
  ['Rolls Royce Ghost', 'chauffeur_rental', 350, 350], ['Rolls Royce Phantom', 'chauffeur_only', 600, 500], ['Rolls Royce Cullinan', 'chauffeur_only', 600, 500],
  ['Sprinter Van Blue', 'chauffeur_only', 400, 350], ['Sprinter Van Orange', 'chauffeur_only', 400, 350]
] as const).map(([name, kind, a, b]) => ({ name, kind, twoHour: a * 100, threePlus: b * 100 }));

// ---------------------------------------------------------------- each row as a car
export type CarClass = 'premium' | 'luxury' | 'exotic';
export interface PartnerCar {
  sheet: string; make: string; model: string; trim: string | null; colour: string | null;
  body: 'Sedan' | 'Coupe' | 'Convertible' | 'SUV'; seats: number; doors: number;
  drive: 'All-wheel drive' | 'Four-wheel drive' | 'Rear-wheel drive'; transmission: 'Automatic' | 'Automatic (dual-clutch)';
  cls: CarClass; year: number;
  /** "Insurance included: no personal auto policy needed" and "No credit card needed: debit accepted" (the owner's 12 cars) */
  included: boolean;
  rates: SheetRental;
}

const AWD = 'All-wheel drive', FWD4 = 'Four-wheel drive', RWD = 'Rear-wheel drive';
const AUTO = 'Automatic', DCT = 'Automatic (dual-clutch)';
type Spec = [make: string, model: string, trim: string | null, colour: string | null, body: PartnerCar['body'], seats: number, doors: number,
  drive: PartnerCar['drive'], transmission: PartnerCar['transmission'], cls: CarClass, year: number, included?: true];
const MB = 'Mercedes-Benz', LR = 'Land Rover';
// The model year is the latest year the model plausibly is (approximate; confirmed when the renter books).
export const SPECS: Record<string, Spec> = {
  'Mercedes A220': [MB, 'A-Class', 'A220', null, 'Sedan', 5, 4, AWD, DCT, 'premium', 2025],
  'Mercedes A35 AMG': [MB, 'A-Class', 'A35 AMG', null, 'Sedan', 5, 4, AWD, DCT, 'luxury', 2025],
  'Mercedes C300 Conv': [MB, 'C-Class', 'C300 Cabriolet', null, 'Convertible', 4, 2, AWD, AUTO, 'premium', 2023],
  'Mercedes C300 Sedan Black': [MB, 'C-Class', 'C300', 'Black', 'Sedan', 5, 4, AWD, AUTO, 'premium', 2025],
  'Mercedes C300 Sedan Grey': [MB, 'C-Class', 'C300', 'Grey', 'Sedan', 5, 4, AWD, AUTO, 'premium', 2025],
  'Mercedes C43 AMG Blue': [MB, 'C-Class', 'C43 AMG', 'Blue', 'Sedan', 5, 4, AWD, AUTO, 'luxury', 2025],
  'Mercedes C43 AMG White': [MB, 'C-Class', 'C43 AMG', 'White', 'Sedan', 5, 4, AWD, AUTO, 'luxury', 2025],
  'Mercedes C43 AMG Grey': [MB, 'C-Class', 'C43 AMG', 'Grey', 'Sedan', 5, 4, AWD, AUTO, 'luxury', 2025],
  'Mercedes C63s AMG': [MB, 'C-Class', 'C63 S AMG', null, 'Sedan', 5, 4, AWD, AUTO, 'luxury', 2025],
  'Mercedes E43 AMG': [MB, 'E-Class', 'E43 AMG', null, 'Sedan', 5, 4, AWD, AUTO, 'luxury', 2020],
  'Mercedes E53 AMG Coupe': [MB, 'E-Class', 'E53 AMG Coupe', null, 'Coupe', 4, 2, AWD, AUTO, 'luxury', 2023],
  'Mercedes GT53 AMG': [MB, 'AMG GT', 'GT53 4-Door Coupe', null, 'Sedan', 4, 4, AWD, AUTO, 'luxury', 2024],
  'Mercedes S500': [MB, 'S-Class', 'S500', null, 'Sedan', 5, 4, AWD, AUTO, 'luxury', 2024],
  'Mercedes S580': [MB, 'S-Class', 'S580', null, 'Sedan', 5, 4, AWD, AUTO, 'luxury', 2025, true],
  'Mercedes S580 Maybach': [MB, 'S-Class', 'Maybach S580', null, 'Sedan', 4, 4, AWD, AUTO, 'luxury', 2025],
  'Mercedes S63 AMG': [MB, 'S-Class', 'S63 AMG', null, 'Sedan', 5, 4, AWD, AUTO, 'luxury', 2025, true],
  'Mercedes GLB250': [MB, 'GLB', 'GLB250', null, 'SUV', 5, 4, AWD, DCT, 'premium', 2025],
  'Mercedes GLB35 AMG': [MB, 'GLB', 'GLB35 AMG', null, 'SUV', 5, 4, AWD, DCT, 'luxury', 2025],
  'Mercedes GLC43 AMG SUV': [MB, 'GLC', 'GLC43 AMG', null, 'SUV', 5, 4, AWD, AUTO, 'luxury', 2025],
  'Mercedes GLC43 AMG Coupe': [MB, 'GLC', 'GLC43 AMG Coupe', null, 'SUV', 5, 4, AWD, AUTO, 'luxury', 2025],
  'Mercedes GLE53 AMG': [MB, 'GLE', 'GLE53 AMG', null, 'SUV', 5, 4, AWD, AUTO, 'luxury', 2025],
  'Mercedes GLE53 AMG Coupe': [MB, 'GLE', 'GLE53 AMG Coupe', null, 'SUV', 5, 4, AWD, AUTO, 'luxury', 2025],
  'Mercedes G63 AMG': [MB, 'G-Class', 'G63 AMG', null, 'SUV', 5, 4, FWD4, AUTO, 'exotic', 2025, true],
  'Mercedes GLS600 Maybach': [MB, 'GLS', 'Maybach GLS600', null, 'SUV', 4, 4, AWD, AUTO, 'exotic', 2025, true],
  'BMW 330i MSport': ['BMW', '3 Series', '330i M Sport', null, 'Sedan', 5, 4, AWD, AUTO, 'premium', 2025],
  'BMW M340i': ['BMW', '3 Series', 'M340i', null, 'Sedan', 5, 4, AWD, AUTO, 'luxury', 2025],
  'BMW M3 Comp': ['BMW', 'M3', 'Competition', null, 'Sedan', 5, 4, AWD, AUTO, 'luxury', 2025],
  'BMW 430i MSport': ['BMW', '4 Series', '430i M Sport', null, 'Coupe', 4, 2, AWD, AUTO, 'premium', 2025],
  'BMW M440i': ['BMW', '4 Series', 'M440i', null, 'Coupe', 4, 2, AWD, AUTO, 'luxury', 2025],
  'BMW M440i Gran Coupe': ['BMW', '4 Series', 'M440i Gran Coupe', null, 'Sedan', 5, 4, AWD, AUTO, 'luxury', 2025, true],
  'BMW M4 Comp White': ['BMW', 'M4', 'Competition', 'White', 'Coupe', 4, 2, AWD, AUTO, 'luxury', 2025],
  'BMW M4 Comp Black': ['BMW', 'M4', 'Competition', 'Black', 'Coupe', 4, 2, AWD, AUTO, 'luxury', 2025, true],
  'BMW 530i MSport': ['BMW', '5 Series', '530i M Sport', null, 'Sedan', 5, 4, AWD, AUTO, 'premium', 2025],
  'BMW X3M Comp': ['BMW', 'X3 M', 'Competition', null, 'SUV', 5, 4, AWD, AUTO, 'luxury', 2024],
  'BMW X4M40i': ['BMW', 'X4', 'M40i', null, 'SUV', 5, 4, AWD, AUTO, 'luxury', 2025],
  'BMW X5 MSport': ['BMW', 'X5', 'M Sport', null, 'SUV', 5, 4, AWD, AUTO, 'premium', 2025],
  'BMW X6M': ['BMW', 'X6 M', null, null, 'SUV', 5, 4, AWD, AUTO, 'luxury', 2025],
  'Audi A5 Conv': ['Audi', 'A5', 'Cabriolet', null, 'Convertible', 4, 2, AWD, AUTO, 'premium', 2024],
  'Audi S5': ['Audi', 'S5', null, null, 'Sedan', 5, 4, AWD, AUTO, 'luxury', 2024],
  'Audi R8 Spyder': ['Audi', 'R8', 'Spyder', null, 'Convertible', 2, 2, AWD, DCT, 'exotic', 2023],
  'Porsche 718 Boxster': ['Porsche', '718 Boxster', null, null, 'Convertible', 2, 2, RWD, DCT, 'luxury', 2025],
  'Porsche 911 Turbo S': ['Porsche', '911', 'Turbo S', null, 'Coupe', 4, 2, AWD, DCT, 'exotic', 2025],
  'Porsche Macan S': ['Porsche', 'Macan', 'S', null, 'SUV', 5, 4, AWD, DCT, 'luxury', 2024],
  'Porsche Cayenne': ['Porsche', 'Cayenne', null, null, 'SUV', 5, 4, AWD, AUTO, 'luxury', 2025],
  'Range Rover Velar White': [LR, 'Range Rover Velar', null, 'White', 'SUV', 5, 4, AWD, AUTO, 'luxury', 2025],
  'Range Rover Velar Blue': [LR, 'Range Rover Velar', null, 'Blue', 'SUV', 5, 4, AWD, AUTO, 'luxury', 2025],
  'Range Rover Sport V6': [LR, 'Range Rover Sport', 'V6', null, 'SUV', 5, 4, AWD, AUTO, 'luxury', 2025],
  'Range Rover Sport V8': [LR, 'Range Rover Sport', 'V8', null, 'SUV', 5, 4, AWD, AUTO, 'luxury', 2025],
  'Range Rover Autobiography': [LR, 'Range Rover', 'Autobiography', null, 'SUV', 5, 4, AWD, AUTO, 'luxury', 2025, true],
  'Ferrari California T': ['Ferrari', 'California', 'T', null, 'Convertible', 4, 2, RWD, DCT, 'exotic', 2017, true],
  'Ferrari 488 Spider': ['Ferrari', '488', 'Spider', null, 'Convertible', 2, 2, RWD, DCT, 'exotic', 2019],
  'Mclaren 570s': ['McLaren', '570S', null, null, 'Coupe', 2, 2, RWD, DCT, 'exotic', 2021, true],
  'Lamborghini Urus': ['Lamborghini', 'Urus', null, null, 'SUV', 5, 4, AWD, AUTO, 'exotic', 2024, true],
  'Corvette C8 Stingray': ['Chevrolet', 'Corvette', 'Stingray', null, 'Coupe', 2, 2, RWD, DCT, 'exotic', 2025],
  'Chevrolet Suburban': ['Chevrolet', 'Suburban', null, null, 'SUV', 7, 4, FWD4, AUTO, 'luxury', 2025],
  'Cadillac Escalade': ['Cadillac', 'Escalade', null, null, 'SUV', 7, 4, FWD4, AUTO, 'luxury', 2025],
  'Cadillac Escalade ESV': ['Cadillac', 'Escalade', 'ESV', null, 'SUV', 7, 4, FWD4, AUTO, 'luxury', 2025, true],
  'Rolls Royce Ghost': ['Rolls-Royce', 'Ghost', null, null, 'Sedan', 5, 4, AWD, AUTO, 'exotic', 2024],
  'Bentley Bentayga': ['Bentley', 'Bentayga', null, null, 'SUV', 5, 4, AWD, AUTO, 'exotic', 2024, true],
  'Ford Mustang Conv': ['Ford', 'Mustang', 'Convertible', null, 'Convertible', 4, 2, RWD, AUTO, 'premium', 2024],
  'Infiniti Q60': ['Infiniti', 'Q60', null, null, 'Coupe', 4, 2, AWD, AUTO, 'premium', 2022],
  'Maserati Levante': ['Maserati', 'Levante', null, null, 'SUV', 5, 4, AWD, AUTO, 'luxury', 2024]
};

export const CARS: PartnerCar[] = SHEET_RENTALS.map((rates) => {
  const s = SPECS[rates.name];
  if (!s) throw new Error(`No car for sheet row ${rates.name}`);
  const [make, model, trim, colour, body, seats, doors, drive, transmission, cls, year, included] = s;
  return { sheet: rates.name, make, model, trim, colour, body, seats, doors, drive, transmission, cls, year, included: included === true, rates };
});

// ---------------------------------------------------------------- chauffeur vehicles
export interface ChauffeurVehicle { sheet: string; name: string; kind: ChauffeurKind; passengers: number; sort: number;
  /** the sheet names of the rental cars this vehicle also rents as ("/ rental"); none found for the S680 */
  rentals: string[]; twoHour: number; threePlus: number }
const CH: Record<string, [name: string, passengers: number, rentals: string[]]> = {
  'Mercedes GLS Maybach': ['Mercedes-Maybach GLS', 4, []],
  'Mercedes S580': ['Mercedes-Benz S580', 3, ['Mercedes S580']],
  // the sheet marks the S680 "chauffeur / rental", but the rental guide has no S680 row (its Maybach row is an S580)
  'Mercedes S680': ['Mercedes-Maybach S680', 3, []],
  'Chevrolet Suburban': ['Chevrolet Suburban', 6, ['Chevrolet Suburban']],
  'Cadillac Escalade': ['Cadillac Escalade', 6, ['Cadillac Escalade']],
  'Range Rovers': ['Range Rover', 4, ['Range Rover Autobiography', 'Range Rover Sport V8', 'Range Rover Sport V6', 'Range Rover Velar White', 'Range Rover Velar Blue']],
  'Rolls Royce Ghost': ['Rolls-Royce Ghost', 3, ['Rolls Royce Ghost']],
  'Rolls Royce Phantom': ['Rolls-Royce Phantom', 3, []],
  'Rolls Royce Cullinan': ['Rolls-Royce Cullinan', 4, []],
  'Sprinter Van Blue': ['Mercedes-Benz Sprinter (blue)', 12, []],
  'Sprinter Van Orange': ['Mercedes-Benz Sprinter (orange)', 12, []]
};
export const CHAUFFEUR: ChauffeurVehicle[] = SHEET_CHAUFFEUR.map((r, i) => {
  const c = CH[r.name];
  if (!c) throw new Error(`No chauffeur vehicle for sheet row ${r.name}`);
  return { sheet: r.name, name: c[0], kind: r.kind, passengers: c[1], sort: i + 1, rentals: c[2], twoHour: r.twoHour, threePlus: r.threePlus };
});

// ---------------------------------------------------------------- the money
export const DEFAULT_MARKUP_BPS = 1000;
export const DEFAULT_CUT_BPS = 2000;

/** The renter's price for a partner's sheet amount: marked up, rounded to the nearest dollar (half a dollar up), the
 *  same rule as app.partner_renter_cents. */
export function renterCents(sheetCents: number, markupBps = DEFAULT_MARKUP_BPS): number {
  return Math.round((sheetCents * (10000 + markupBps)) / 1_000_000) * 100;
}
/** A basis-point share of an amount, half a cent up (public.calc_bps). */
export function bps(amountCents: number, b: number): number { return Math.round((amountCents * b) / 10000); }

/** The renter's rate card for a sheet row: the 1-2 day rate is the daily and weekend rate, the 3+ day rate the
 *  multi-day rate, and the 7+ day rate the per-day rate of the weekly (7 days) and monthly (30 days) rates. */
export function rateCard(r: Pick<SheetRental, 'base' | 'multi' | 'long'>, markupBps = DEFAULT_MARKUP_BPS) {
  const daily = renterCents(r.base, markupBps), multi = renterCents(r.multi, markupBps), long = renterCents(r.long, markupBps);
  return { daily, weekend: daily, multi, weekly: long * 7, monthly: long * 30 };
}
/** The partner's own rates in the same shape (the sheet amounts the partner is paid on). */
export const sheetCard = (r: Pick<SheetRental, 'base' | 'multi' | 'long'>) => ({ daily: r.base, weekend: r.base, multi: r.multi, weekly: r.long * 7, monthly: r.long * 30 });

/** public.calc_rental_charge with the 3+ day tier (0093) for a car whose weekend rate is its daily rate: 1 or 2 days
 *  at the daily rate, 3 to 6 at the multi-day rate (never more than the daily rate would cost or the weekly rate), 7 to
 *  29 at the weekly rate by the day (never more than the monthly rate), 30 at the monthly rate. */
export function rentalCharge(days: number, c: { daily: number; multi?: number | null; weekly: number; monthly: number }): { tier: 'daily' | 'multi_day' | 'weekly' | 'monthly'; cents: number } {
  if (!Number.isInteger(days) || days < 1 || days > 30) throw new Error('A rental is 1 to 30 days');
  if (days <= 6) {
    const byDay = Math.min(days * c.daily, c.weekly);
    if (days >= 3 && c.multi != null) return { tier: 'multi_day', cents: Math.min(days * c.multi, byDay) };
    return { tier: 'daily', cents: byDay };
  }
  if (days <= 29) return { tier: 'weekly', cents: Math.min(Math.round((c.weekly * days) / 7), c.monthly) };
  return { tier: 'monthly', cents: c.monthly };
}

/** What a rental of a partner car comes to on the partner-rate basis: the renter's rental charge, the sheet amount, the
 *  CarmaCars cut of the sheet, the partner's payout, and what CarmaCars keeps (the markup plus the cut). */
export function partnerSplit(days: number, r: Pick<SheetRental, 'base' | 'multi' | 'long'>, o: { markupBps?: number; cutBps?: number } = {}) {
  const renter = rentalCharge(days, rateCard(r, o.markupBps ?? DEFAULT_MARKUP_BPS));
  const sheet = rentalCharge(days, sheetCard(r));
  const cut = bps(sheet.cents, o.cutBps ?? DEFAULT_CUT_BPS);
  const payout = sheet.cents - cut;
  return { tier: renter.tier, renter: renter.cents, sheet: sheet.cents, cut, payout, markup: renter.cents - sheet.cents, keep: renter.cents - payout };
}

/** A chauffeur booking: at least 2 hours; exactly 2 at the 2-hour rate, 3 or more at the 3+ hour rate, each per hour. */
export function chauffeurCharge(hours: number, rates: { twoHour: number; threePlus: number }): number {
  if (!Number.isInteger(hours) || hours < 2 || hours > 24) throw new Error('A chauffeur booking is 2 to 24 whole hours');
  return hours * (hours === 2 ? rates.twoHour : rates.threePlus);
}
export function chauffeurSplit(hours: number, sheet: { twoHour: number; threePlus: number }, o: { markupBps?: number; cutBps?: number } = {}) {
  const m = o.markupBps ?? DEFAULT_MARKUP_BPS;
  const renter = chauffeurCharge(hours, { twoHour: renterCents(sheet.twoHour, m), threePlus: renterCents(sheet.threePlus, m) });
  const s = chauffeurCharge(hours, sheet);
  const cut = bps(s, o.cutBps ?? DEFAULT_CUT_BPS);
  return { renter, sheet: s, cut, payout: s - cut, keep: renter - (s - cut) };
}
