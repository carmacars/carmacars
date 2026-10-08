// SAMPLE DATA. Every car, rate, feature and booking below is a stand-in so the
// layout can be judged until the real cars are uploaded. Replace with the live
// fleet register before launch.
// Rules that are NOT sample (confirmed by the owner, or from docs/source): deposit
// tiers, kilometre choices, fee amounts and how they are worked out, HST, age rules,
// notice and turnaround times, the 30 day maximum. Those live in RULES.

export const PROTO_TODAY = '2026-10-15'; // launch day; the prototype clock is fixed here
export const PROTO_NOW = '09:00';        // time of day on the prototype clock (for the 2 hour notice)

// Classes a car can be in. A car can have several. Matches vehicle_classes (migration 0025).
export const CLASSES = ['Economy', 'Standard', 'Premium', 'Luxury', 'SUV', 'Convertible', 'Coupe', 'Sedan', 'Van', 'Pickup'];

// RULES. Policy numbers, fees and thresholds. The stand-in for Admin > Pricing and
// Admin > Policies. Every page reads these through tokens like {{deductible}}, so a
// change here changes every page, the estimates and the structured data.
export const RULES = {
  hst: 0.13,
  maxDays: 30,
  weeklyFromDays: 7,
  minAge: 18,
  noFeeAge: 26,
  youngBandSplit: 21,                       // the two young driver bands: 18 to 20, 21 to 25
  licence: 'G2 or G',
  depositTiers: [500, 1000, 2500, 5000],    // deposit_tiers; each car has one
  kmChoices: [400, 300, 200, 150],          // km_allowance_choices; each car has one, with its own overage rate
  depositLeadHours: 1,                      // the deposit is taken about 1 hour before pickup
  depositHoldMaxDays: 7,
  depositReleaseBusinessDays: 7,
  depositHoldbackDays: 30,
  refundBusinessDays: 10,
  minNoticeHours: 2,                        // pickup and return any time, with at least 2 hours' notice
  turnaroundHours: 2,                       // at least 2 hours between two bookings of the same car
  handoverSlotMinutes: 30,                  // the time pickers step in 30 minutes, round the clock
  defaultTime: '10:00',
  sampleHandover: '10:00',                  // SAMPLE: time of the pickups and returns of the sample bookings below
  youngDriver: { '18-20': { perDay: 35 }, '21-25': { perDay: 20 } },   // per day, no maximum; a car may override
  additionalDriverPct: 0.25,                // per additional driver, per day: 25% of the car's daily rate, no maximum
  winterTire: { perDay: 15, cap: 150 },
  babySeat: { perDay: 12, cap: 70 },
  nonRefundableDiscount: 0.10,
  deliveryPerKm: null,                      // UNCONFIRMED: rate per km from our location; null = "plus distance, priced in your offer"
  companyLocation: null,                    // UNCONFIRMED: coordinates the distance is measured from
  airports: [                               // airport delivery and pickup; surcharge null = "may apply", priced in the offer
    { code: 'YYZ', name: 'Toronto Pearson', surcharge: null },
    { code: 'YTZ', name: 'Billy Bishop Toronto City Airport', surcharge: null }
  ],
  deductible: 2500,
  adminFee: { claim: 75, other: 50 },
  lateReturn: { graceMinutes: 30, perHour: 25 },
  fuel: { markupPct: 25, serviceFee: 25, per10PctBattery: 10 },
  cleaning: { standard: 75, heavy: 250, pet: 150, smoking: 300 },
  lostKeyFee: 50,
  tollFee: 15,
  ticketFee: 40,
  declinedPaymentFee: 40,
  cancellation: { graceHours: 24, earlyHours: 48, lateHours: 24, gracePct: 95, earlyPct: 75, midPct: 50 },
  offerOpenHours: 24,
  verifyHoursBeforePickup: 24,
  accidentCallHours: 24,
  accidentReportHours: 48,
  hiddenDamageHours: 48,
  owner: { payoutDay: '10th', billingDay: '15th', noticeDays: 30, referralPct: 20, replyBusinessDays: 'one business day', listingBusinessDays: '1 business day' }
};

const car = (o) => ({
  transmission: 'Automatic', doors: 4, seats: 5, fuel: 'Gasoline', kmPerDay: 200, overage: 0.35, ownerPickup: false,
  youngFees: { '18-20': RULES.youngDriver['18-20'].perDay, '21-25': RULES.youngDriver['21-25'].perDay }, ...o,
  slug: `${o.make} ${o.model}`.toLowerCase().replace(/[^a-z0-9]+/g, '-'),
  name: `${o.make} ${o.model}`,
  cls: o.classes[0] // the first class is the pricing class (vehicles.class)
});

// booked: [start, end] dates of confirmed sample bookings; each starts and ends at RULES.sampleHandover.
// The car is blocked from turnaroundHours before the start to turnaroundHours after the end.
// pending: requests not yet confirmed (shown hatched in the portal sample)
// ownerPickup: the car's owner offers handover at their own location (self-managed sample cars)
export const CARS = [
  car({ code: 'CC 01', make: 'Mercedes-Benz', model: 'A220', year: 2021, trim: '4MATIC Sedan', classes: ['Premium', 'Sedan'], body: 'Sedan', shape: 'compact', paint: 'white', colour: 'Polar White', drive: 'All-wheel drive', bags: 2, l100: '8.4 L/100 km combined',
    rates: { daily: 95, weekend: 115, weekly: 560, monthly: 1850 }, delivery: 100, deposit: 1000, kmPerDay: 300, overage: 0.35,
    features: ['Apple CarPlay and Android Auto', 'Heated front seats', 'Backup camera', 'Blind spot assist', 'Panoramic roof', 'All-season tires'],
    blurb: 'The small Mercedes. Easy to park downtown, all-wheel drive for the 401 in November.',
    booked: [['2026-10-17', '2026-10-19'], ['2026-10-27', '2026-11-02'], ['2026-11-13', '2026-11-15']], pending: [['2026-10-22', '2026-10-24']] }),
  car({ code: 'CC 02', make: 'Mercedes-Benz', model: 'CLA250', year: 2022, trim: '4MATIC Coupe', classes: ['Premium', 'Coupe', 'Sedan'], body: 'Four-door coupe', shape: 'fastback', paint: 'black', colour: 'Night Black', drive: 'All-wheel drive', bags: 2, l100: '8.7 L/100 km combined',
    rates: { daily: 105, weekend: 125, weekly: 620, monthly: 2050 }, delivery: 100, deposit: 1000, kmPerDay: 300, overage: 0.40,
    features: ['Apple CarPlay and Android Auto', 'Heated front seats', 'Ambient lighting', 'Backup camera', 'Frameless doors', 'All-season tires'],
    blurb: 'Lower roofline than the A220 and a louder look. Same footprint, same easy drive.',
    booked: [['2026-10-21', '2026-10-23'], ['2026-10-30', '2026-11-01'], ['2026-11-20', '2026-11-27']], pending: [] }),
  car({ code: 'CC 03', make: 'Mercedes-Benz', model: 'C300', year: 2022, trim: '4MATIC Sedan', classes: ['Premium', 'Sedan'], body: 'Sedan', shape: 'sedan', paint: 'silver', colour: 'Iridium Silver', drive: 'All-wheel drive', bags: 3, l100: '8.1 L/100 km combined',
    rates: { daily: 119, weekend: 142, weekly: 700, monthly: 2300 }, delivery: 100, deposit: 1000, kmPerDay: 200, overage: 0.45,
    features: ['Apple CarPlay and Android Auto', 'Heated front seats', '360 degree camera', 'Adaptive cruise control', 'Leather seats', 'All-season tires'],
    blurb: 'The one people ask for by name. Quiet on the highway, room for three bags.',
    booked: [['2026-10-15', '2026-10-21'], ['2026-11-06', '2026-11-08']], pending: [['2026-10-24', '2026-10-26']] }),
  car({ code: 'CC 04', make: 'Mercedes-Benz', model: 'GLC300', year: 2022, trim: '4MATIC SUV', classes: ['Premium', 'SUV'], body: 'Compact SUV', shape: 'suv', paint: 'black', colour: 'Obsidian Black', drive: 'All-wheel drive', bags: 4, l100: '9.6 L/100 km combined',
    rates: { daily: 135, weekend: 160, weekly: 800, monthly: 2650 }, delivery: 125, deposit: 2500, kmPerDay: 200, overage: 0.50,
    features: ['Apple CarPlay and Android Auto', 'Heated front seats', 'Power tailgate', 'Backup camera', 'Roof rails', 'All-season tires'],
    blurb: 'Higher seat, bigger trunk, the same Mercedes cabin. Good for Blue Mountain weekends.',
    booked: [['2026-10-23', '2026-10-26'], ['2026-11-10', '2026-11-19']], pending: [] }),
  car({ code: 'CC 05', make: 'Mercedes-Benz', model: 'GLE350', year: 2023, trim: '4MATIC SUV', classes: ['Luxury', 'SUV'], body: 'Mid-size SUV', shape: 'suvlg', paint: 'white', colour: 'Diamond White', drive: 'All-wheel drive', bags: 5, l100: '10.4 L/100 km combined', kmPerDay: 150, overage: 0.75,
    rates: { daily: 189, weekend: 225, weekly: 1120, monthly: 3700 }, delivery: 175, deposit: 2500,
    features: ['Apple CarPlay and Android Auto', 'Heated and ventilated seats', 'Air suspension', '360 degree camera', 'Burmester sound', 'Power tailgate'],
    blurb: 'The big one. Five adults and their luggage, in real comfort, to Muskoka and back.',
    booked: [['2026-10-20', '2026-10-22'], ['2026-11-01', '2026-11-04']], pending: [['2026-10-29', '2026-10-31']] }),
  car({ code: 'CC 06', make: 'Toyota', model: 'Corolla', year: 2023, trim: 'LE', classes: ['Economy', 'Sedan'], body: 'Sedan', shape: 'compact', paint: 'silver', colour: 'Classic Silver', drive: 'Front-wheel drive', bags: 2, l100: '6.7 L/100 km combined',
    rates: { daily: 59, weekend: 69, weekly: 350, monthly: 1150 }, delivery: 75, deposit: 500, kmPerDay: 400, overage: 0.25,
    features: ['Apple CarPlay and Android Auto', 'Backup camera', 'Lane keeping assist', 'Adaptive cruise control', 'Heated front seats', 'All-season tires'],
    blurb: 'Cheap to rent, cheap to fuel, and it starts every morning.',
    booked: [['2026-10-15', '2026-10-16'], ['2026-10-20', '2026-10-30']], pending: [] }),
  car({ code: 'CC 07', make: 'Hyundai', model: 'Elantra', year: 2023, trim: 'Preferred', classes: ['Economy', 'Sedan'], body: 'Sedan', shape: 'fastback', paint: 'grey', colour: 'Cyber Grey', drive: 'Front-wheel drive', bags: 2, l100: '6.4 L/100 km combined',
    rates: { daily: 62, weekend: 72, weekly: 365, monthly: 1200 }, delivery: 75, deposit: 500, kmPerDay: 400, overage: 0.25,
    features: ['Apple CarPlay and Android Auto', 'Heated front seats', 'Heated steering wheel', 'Backup camera', 'Blind spot assist', 'All-season tires'],
    blurb: 'More legroom than you expect at this price.',
    booked: [['2026-10-24', '2026-10-25'], ['2026-11-03', '2026-11-12']], pending: [['2026-10-17', '2026-10-19']] }),
  car({ code: 'CC 08', make: 'Honda', model: 'Civic', year: 2022, trim: 'Sport', classes: ['Standard', 'Sedan'], body: 'Sedan', shape: 'compact', paint: 'red', colour: 'Rallye Red', drive: 'Front-wheel drive', bags: 2, l100: '7.1 L/100 km combined',
    rates: { daily: 69, weekend: 82, weekly: 410, monthly: 1350 }, delivery: 75, deposit: 500, kmPerDay: 300, overage: 0.30,
    features: ['Apple CarPlay and Android Auto', 'Heated front seats', 'Backup camera', 'Adaptive cruise control', 'Remote start', 'All-season tires'],
    blurb: 'A proper daily driver with a bit of life in the steering.',
    booked: [['2026-10-19', '2026-10-22'], ['2026-11-14', '2026-11-16']], pending: [] }),
  car({ code: 'CC 09', make: 'Toyota', model: 'RAV4', year: 2023, trim: 'XLE AWD', classes: ['Standard', 'SUV'], body: 'Compact SUV', shape: 'suv', paint: 'grey', colour: 'Magnetic Grey', drive: 'All-wheel drive', bags: 4, l100: '8.0 L/100 km combined',
    rates: { daily: 89, weekend: 105, weekly: 525, monthly: 1750 }, delivery: 125, deposit: 1000, kmPerDay: 300, overage: 0.30,
    features: ['Apple CarPlay and Android Auto', 'Heated front seats', 'Power tailgate', 'Roof rails', 'Adaptive cruise control', 'All-season tires'],
    blurb: 'The sensible SUV. All-wheel drive, a flat load floor and fuel bills that stay small.',
    booked: [['2026-10-26', '2026-10-29'], ['2026-10-31', '2026-11-07']], pending: [] }),
  car({ code: 'CC 10', make: 'Tesla', model: 'Model 3', year: 2023, trim: 'Rear-Wheel Drive', classes: ['Premium', 'Sedan'], body: 'Sedan', shape: 'fastback', paint: 'white', colour: 'Pearl White', drive: 'Rear-wheel drive', bags: 3, fuel: 'Electric', l100: 'About 430 km of range',
    rates: { daily: 109, weekend: 129, weekly: 645, monthly: 2150 }, delivery: 100, deposit: 1000, kmPerDay: 300, overage: 0.35,
    features: ['15 inch touchscreen', 'Autopilot', 'Glass roof', 'Heated seats, front and rear', 'Mobile charging cable', 'All-season tires'],
    blurb: 'No gas stations. Return it with the charge you left with and that is the whole fuel policy.',
    booked: [['2026-10-22', '2026-10-25'], ['2026-11-07', '2026-11-09']], pending: [['2026-10-16', '2026-10-17']] }),
  car({ code: 'CC 11', make: 'Chrysler', model: 'Pacifica', year: 2022, trim: 'Touring L', classes: ['Van', 'Premium'], body: 'Minivan', shape: 'van', paint: 'silver', colour: 'Billet Silver', drive: 'Front-wheel drive', seats: 7, bags: 6, l100: '10.6 L/100 km combined', ownerPickup: true,
    rates: { daily: 99, weekend: 119, weekly: 590, monthly: 1950 }, delivery: 125, deposit: 1000, kmPerDay: 300, overage: 0.35,
    features: ['Seven seats', 'Power sliding doors', 'Stow and go seating', 'Apple CarPlay and Android Auto', 'Tri-zone climate', 'Backup camera'],
    blurb: 'Seven seats and doors that open themselves. The airport run with everybody in one car.',
    booked: [['2026-10-21', '2026-10-28'], ['2026-11-21', '2026-11-23']], pending: [] }),
  car({ code: 'CC 12', make: 'Mazda', model: 'MX-5', year: 2021, trim: 'GS-P Soft Top', classes: ['Convertible', 'Premium'], body: 'Convertible', shape: 'roadster', paint: 'red', colour: 'Soul Red', drive: 'Rear-wheel drive', seats: 2, doors: 2, bags: 1, transmission: 'Manual', l100: '7.8 L/100 km combined',
    rates: { daily: 99, weekend: 135, weekly: 620, monthly: 2050 }, delivery: 100, deposit: 1000, kmPerDay: 200, overage: 0.40,
    features: ['Six-speed manual', 'Soft top', 'Apple CarPlay and Android Auto', 'Heated seats', 'Bose sound', 'Limited-slip differential'],
    blurb: 'Two seats, a manual gearbox and a roof you fold with one hand. Not practical. That is the point.',
    booked: [['2026-10-23', '2026-10-25'], ['2026-10-30', '2026-11-01']], pending: [] }),
  car({ code: 'CC 13', make: 'Kia', model: 'Forte', year: 2023, trim: 'EX', classes: ['Economy', 'Sedan'], body: 'Sedan', shape: 'sedan', paint: 'white', colour: 'Snow White Pearl', drive: 'Front-wheel drive', bags: 2, l100: '6.9 L/100 km combined',
    rates: { daily: 64, weekend: 74, weekly: 380, monthly: 1250 }, delivery: 75, deposit: 500, kmPerDay: 400, overage: 0.25,
    features: ['Apple CarPlay and Android Auto', 'Heated front seats', 'Heated steering wheel', 'Backup camera', 'Lane keeping assist', 'All-season tires'],
    blurb: 'A roomy trunk and a soft ride. The commuter that does not mind a road trip.',
    booked: [['2026-10-18', '2026-10-21'], ['2026-11-05', '2026-11-09']], pending: [] }),
  car({ code: 'CC 14', make: 'Toyota', model: 'Camry', year: 2023, trim: 'SE', classes: ['Standard', 'Sedan'], body: 'Mid-size sedan', shape: 'sedan', paint: 'black', colour: 'Midnight Black', drive: 'Front-wheel drive', bags: 3, l100: '7.6 L/100 km combined', ownerPickup: true,
    rates: { daily: 79, weekend: 92, weekly: 470, monthly: 1550 }, delivery: 75, deposit: 500, kmPerDay: 300, overage: 0.30,
    features: ['Apple CarPlay and Android Auto', 'Heated front seats', 'Adaptive cruise control', 'Blind spot assist', 'Backup camera', 'All-season tires'],
    blurb: 'Room for four adults and their bags, and the quiet cabin Toyota is known for.',
    booked: [['2026-10-16', '2026-10-18'], ['2026-10-29', '2026-11-03']], pending: [] }),
  car({ code: 'CC 15', make: 'Honda', model: 'CR-V', year: 2023, trim: 'EX-L AWD', classes: ['Standard', 'SUV'], body: 'Compact SUV', shape: 'suv', paint: 'silver', colour: 'Lunar Silver', drive: 'All-wheel drive', bags: 4, l100: '8.4 L/100 km combined',
    rates: { daily: 92, weekend: 108, weekly: 540, monthly: 1800 }, delivery: 125, deposit: 1000, kmPerDay: 300, overage: 0.30,
    features: ['Apple CarPlay and Android Auto', 'Heated leather seats', 'Power tailgate', 'Adaptive cruise control', 'Blind spot assist', 'All-season tires'],
    blurb: 'A big boot, a high seat and all-wheel drive for whatever February brings.',
    booked: [['2026-10-22', '2026-10-24'], ['2026-11-11', '2026-11-14']], pending: [] }),
  car({ code: 'CC 16', make: 'Kia', model: 'Carnival', year: 2023, trim: 'EX', classes: ['Van', 'Standard'], body: 'Minivan', shape: 'van', paint: 'grey', colour: 'Panthera Metal', drive: 'Front-wheel drive', seats: 8, bags: 6, l100: '11.0 L/100 km combined',
    rates: { daily: 109, weekend: 129, weekly: 650, monthly: 2150 }, delivery: 125, deposit: 1000, kmPerDay: 300, overage: 0.35,
    features: ['Eight seats', 'Power sliding doors', 'Rear climate controls', 'Apple CarPlay and Android Auto', 'Backup camera', 'All-season tires'],
    blurb: 'Eight seats. Cottage weekends, team trips and family visits, in one car.',
    booked: [['2026-10-16', '2026-10-19'], ['2026-11-13', '2026-11-16']], pending: [] }),
  car({ code: 'CC 17', make: 'Ford', model: 'F-150', year: 2022, trim: 'XLT SuperCrew 4x4', classes: ['Pickup', 'Standard'], body: 'Pickup truck', shape: 'suvlg', paint: 'black', colour: 'Agate Black', drive: 'Four-wheel drive', bags: 4, l100: '12.8 L/100 km combined', ownerPickup: true,
    rates: { daily: 129, weekend: 149, weekly: 770, monthly: 2550 }, delivery: 150, deposit: 2500, kmPerDay: 200, overage: 0.45,
    features: ['5.5 foot box', 'Tow hitch', 'Apple CarPlay and Android Auto', 'Heated front seats', 'Backup camera', 'All-season tires'],
    blurb: 'A full-size truck with a short box. Moving day, a hardware run, a load of firewood.',
    booked: [['2026-10-24', '2026-10-26'], ['2026-11-07', '2026-11-08']], pending: [] }),
  car({ code: 'CC 18', make: 'BMW', model: '330i', year: 2022, trim: 'xDrive Sedan', classes: ['Premium', 'Sedan'], body: 'Sedan', shape: 'sedan', paint: 'grey', colour: 'Mineral Grey', drive: 'All-wheel drive', bags: 3, l100: '8.5 L/100 km combined',
    rates: { daily: 125, weekend: 149, weekly: 745, monthly: 2450 }, delivery: 100, deposit: 2500, kmPerDay: 200, overage: 0.50,
    features: ['Apple CarPlay and Android Auto', 'Heated front seats', 'Heated steering wheel', 'Parking assistant', 'Live Cockpit display', 'All-season tires'],
    blurb: 'The driver’s sedan. Balanced, quick and happy on a back road.',
    booked: [['2026-10-19', '2026-10-21'], ['2026-11-02', '2026-11-06']], pending: [] }),
  car({ code: 'CC 19', make: 'Ford', model: 'Mustang', year: 2022, trim: 'EcoBoost Premium Convertible', classes: ['Convertible', 'Coupe', 'Premium'], body: 'Convertible', shape: 'roadster', paint: 'red', colour: 'Race Red', drive: 'Rear-wheel drive', seats: 4, doors: 2, bags: 2, l100: '10.1 L/100 km combined',
    rates: { daily: 139, weekend: 169, weekly: 830, monthly: 2750 }, delivery: 125, deposit: 2500, kmPerDay: 200, overage: 0.50,
    features: ['Power soft top', 'Apple CarPlay and Android Auto', 'Heated and cooled front seats', 'B&O sound', 'Backup camera', 'All-season tires'],
    blurb: 'Roof down along the lakeshore. Four seats, so friends can come too.',
    booked: [['2026-10-17', '2026-10-18'], ['2026-10-31', '2026-11-01']], pending: [] }),
  car({ code: 'CC 20', make: 'Porsche', model: '911', year: 2021, trim: 'Carrera', classes: ['Luxury', 'Coupe'], body: 'Coupe', shape: 'fastback', paint: 'silver', colour: 'GT Silver', drive: 'Rear-wheel drive', seats: 4, doors: 2, bags: 1, l100: '10.9 L/100 km combined',
    rates: { daily: 449, weekend: 529, weekly: 2650, monthly: 8900 }, delivery: 200, deposit: 5000, kmPerDay: 150, overage: 1.50,
    youngFees: { '18-20': 75, '21-25': 50 },
    features: ['Eight-speed PDK', 'Sport Chrono package', 'Apple CarPlay', 'Heated seats', 'Bose sound', 'Front axle lift'],
    blurb: 'The one for the occasion. A deposit to match, and a day you will talk about.',
    booked: [['2026-10-24', '2026-10-25'], ['2026-11-14', '2026-11-15']], pending: [] })
];

// Featured cars on the home page: chosen at random on each visit (featured_mode random).
export const FEATURED = { mode: 'random', count: 7 };

// Reviews. Our own reviews, approved by staff, and Google reviews read with googlePlaceId
// (site.mjs). Both are empty until real reviews exist; the page shows an honest empty state.
export const REVIEWS = {
  own: [],
  google: { rating: null, total: null, items: [] }
};
// SAMPLE review content for the prototype switch only. Not real customers.
export const SAMPLE_REVIEWS = {
  own: [
    { name: 'Sample renter A', car: 'Mercedes-Benz C300', when: 'Sample month', stars: 5, text: 'Sample review text. A renter’s own words about the booking, the handover and the car will appear here once real rentals are complete.' },
    { name: 'Sample renter B', car: 'Toyota Corolla', when: 'Sample month', stars: 5, text: 'Sample review text. Two or three sentences, shown exactly as the renter wrote them, with the car they rented and the month of the rental.' }
  ],
  google: { rating: 4.9, total: 'Sample', items: [
    { name: 'Sample Google reviewer', when: 'Sample time', stars: 5, text: 'Sample text. A Google review appears here as the reviewer wrote it, with their name and when they posted it.' }
  ] }
};

// SAMPLE address suggestions for the prototype's address lookup. Production asks a maps
// service as the person types. Public Toronto landmarks only; no private addresses.
export const ADDRESS_SAMPLES = [
  'Union Station, 65 Front Street West, Toronto, ON',
  'Toronto Pearson Airport, Terminal 1, Mississauga, ON',
  'Toronto Pearson Airport, Terminal 3, Mississauga, ON',
  'Billy Bishop Toronto City Airport, 1 Eireann Quay, Toronto, ON',
  'CN Tower, 290 Bremner Boulevard, Toronto, ON',
  'Royal Ontario Museum, 100 Queens Park, Toronto, ON',
  'Scotiabank Arena, 40 Bay Street, Toronto, ON',
  'Yorkdale Shopping Centre, 3401 Dufferin Street, Toronto, ON',
  'Square One, 100 City Centre Drive, Mississauga, ON',
  'Vaughan Mills, 1 Bass Pro Mills Drive, Vaughan, ON',
  'Markville Mall, 5000 Highway 7 East, Markham, ON',
  'Scarborough Town Centre, 300 Borough Drive, Toronto, ON',
  'Toronto City Hall, 100 Queen Street West, Toronto, ON',
  'St. Lawrence Market, 93 Front Street East, Toronto, ON'
];

export const bySlug = (s) => CARS.find((c) => c.slug === s);
export const money = (n) => '$' + Number(n).toLocaleString('en-CA', { minimumFractionDigits: Number.isInteger(n) ? 0 : 2, maximumFractionDigits: 2 });
const list = (a, join = 'or') => a.length < 2 ? a.join('') : a.slice(0, -1).join(', ') + ' ' + join + ' ' + a[a.length - 1];

// TOKENS. Formatted strings for the page templates: write {{name}} in any template text.
const $ = (n) => money(n);
const R = RULES;
const overs = CARS.map((c) => c.overage); const dels = CARS.map((c) => c.delivery);
export const TOKENS = {
  hst: Math.round(R.hst * 100) + '%', maxDays: String(R.maxDays), maxDaysLess1: String(R.maxDays - 1), weekFrom: String(R.weeklyFromDays), weekFromLess1: String(R.weeklyFromDays - 1),
  minAge: String(R.minAge), fullAge: String(R.noFeeAge), youngA: `${R.minAge} to ${R.youngBandSplit - 1}`, youngB: `${R.youngBandSplit} to ${R.noFeeAge - 1}`, licence: R.licence,
  depTiers: list(R.depositTiers.map($)), depMin: $(Math.min(...R.depositTiers)), depMax: $(Math.max(...R.depositTiers)), kmChoices: list(R.kmChoices.map(String)),
  depLead: `${R.depositLeadHours} hour`, holdDays: String(R.depositHoldMaxDays), releaseDays: `${R.depositReleaseBusinessDays} business days`, holdbackDays: `${R.depositHoldbackDays} days`, refundDays: `${R.refundBusinessDays} business days`,
  notice: `${R.minNoticeHours} hours`, turnaround: `${R.turnaroundHours} hours`,
  ydA: $(R.youngDriver['18-20'].perDay), ydB: $(R.youngDriver['21-25'].perDay),
  addDrvPct: Math.round(R.additionalDriverPct * 100) + '%', winter: $(R.winterTire.perDay), winterCap: $(R.winterTire.cap), baby: $(R.babySeat.perDay), babyCap: $(R.babySeat.cap),
  nonRef: Math.round(R.nonRefundableDiscount * 100) + '%', delMin: $(Math.min(...dels)), delMax: $(Math.max(...dels)),
  airports: list(R.airports.map((a) => a.name), 'and'),
  deductible: $(R.deductible), adminClaim: $(R.adminFee.claim), adminOther: $(R.adminFee.other),
  overMin: '$' + Math.min(...overs).toFixed(2), overMax: '$' + Math.max(...overs).toFixed(2),
  grace: `${R.lateReturn.graceMinutes} minutes`, graceShort: `${R.lateReturn.graceMinutes} minute`, lateHr: $(R.lateReturn.perHour),
  fuelPct: R.fuel.markupPct + '%', fuelFee: $(R.fuel.serviceFee), evPer: $(R.fuel.per10PctBattery),
  clean: $(R.cleaning.standard), cleanHeavy: $(R.cleaning.heavy), pet: $(R.cleaning.pet), smoke: $(R.cleaning.smoking), keyFee: $(R.lostKeyFee), tollFee: $(R.tollFee), ticketFee: $(R.ticketFee), declined: $(R.declinedPaymentFee),
  c1: R.cancellation.gracePct + '%', c2: R.cancellation.earlyPct + '%', c3: R.cancellation.midPct + '%', cGrace: String(R.cancellation.graceHours), cEarly: String(R.cancellation.earlyHours), cLate: String(R.cancellation.lateHours),
  offerHours: String(R.offerOpenHours), verifyHours: String(R.verifyHoursBeforePickup), callHours: String(R.accidentCallHours), reportHours: String(R.accidentReportHours), hiddenHours: String(R.hiddenDamageHours),
  payoutDay: R.owner.payoutDay, billDay: R.owner.billingDay, noticeDays: String(R.owner.noticeDays), referralPct: R.owner.referralPct + '%', ownerReply: R.owner.replyBusinessDays, listDays: R.owner.listingBusinessDays,
  minDaily: $(Math.min(...CARS.map((c) => c.rates.daily)))
};
