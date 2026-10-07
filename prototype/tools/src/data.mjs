// SAMPLE DATA. Every car, rate, feature and booking below is a stand-in so the
// layout can be judged. Replace with the live fleet register before launch.
// Rules that are NOT sample (taken from docs/source): deposit by class, fee
// amounts, HST, age rules, 30 day maximum. Those live in RULES.

export const PROTO_TODAY = '2026-10-15'; // launch day; the prototype clock is fixed here

export const RULES = {
  hst: 0.13,
  maxDays: 30,
  depositByClass: { Economy: 500, Standard: 500, Premium: 1000, SUV: 1000, Luxury: 2500 },
  youngDriver: { '18-20': { perDay: 35, cap: 350 }, '21-25': { perDay: 20, cap: 200 } },
  additionalDriver: { perDay: 10, cap: 70 },
  winterTire: { perDay: 15, cap: 150 },
  babySeat: { perDay: 12, cap: 70 },
  nonRefundableDiscount: 0.10,
  deliveryRange: [75, 200],
  deductible: 2500
};

const car = (o) => ({
  transmission: 'Automatic', doors: 4, seats: 5, fuel: 'Gasoline', kmPerDay: 200, overage: 0.35,
  young: false, ...o,
  slug: `${o.make} ${o.model}`.toLowerCase().replace(/[^a-z0-9]+/g, '-'),
  name: `${o.make} ${o.model}`,
  deposit: RULES.depositByClass[o.cls]
});

// booked: [start, end] inclusive dates that block the calendar (sample)
// pending: requests not yet confirmed (shown hatched in the portal sample)
export const CARS = [
  car({ code: 'CC 01', make: 'Mercedes-Benz', model: 'A220', year: 2021, trim: '4MATIC Sedan', cls: 'Premium', body: 'Sedan', shape: 'compact', paint: 'white', colour: 'Polar White', drive: 'All-wheel drive', bags: 2, l100: '8.4 L/100 km combined',
    rates: { daily: 95, weekend: 115, weekly: 560, monthly: 1850 }, delivery: 100,
    features: ['Apple CarPlay and Android Auto', 'Heated front seats', 'Backup camera', 'Blind spot assist', 'Panoramic roof', 'All-season tires'],
    blurb: 'The small Mercedes. Easy to park downtown, all-wheel drive for the 401 in November.',
    booked: [['2026-10-17', '2026-10-19'], ['2026-10-27', '2026-11-02'], ['2026-11-13', '2026-11-15']], pending: [['2026-10-22', '2026-10-24']] }),
  car({ code: 'CC 02', make: 'Mercedes-Benz', model: 'CLA250', year: 2022, trim: '4MATIC Coupe', cls: 'Premium', body: 'Four-door coupe', shape: 'fastback', paint: 'black', colour: 'Night Black', drive: 'All-wheel drive', bags: 2, l100: '8.7 L/100 km combined',
    rates: { daily: 105, weekend: 125, weekly: 620, monthly: 2050 }, delivery: 100,
    features: ['Apple CarPlay and Android Auto', 'Heated front seats', 'Ambient lighting', 'Backup camera', 'Frameless doors', 'All-season tires'],
    blurb: 'Lower roofline than the A220 and a louder look. Same footprint, same easy drive.',
    booked: [['2026-10-21', '2026-10-23'], ['2026-10-30', '2026-11-01'], ['2026-11-20', '2026-11-27']], pending: [] }),
  car({ code: 'CC 03', make: 'Mercedes-Benz', model: 'C300', year: 2022, trim: '4MATIC Sedan', cls: 'Premium', body: 'Sedan', shape: 'sedan', paint: 'silver', colour: 'Iridium Silver', drive: 'All-wheel drive', bags: 3, l100: '8.1 L/100 km combined',
    rates: { daily: 119, weekend: 142, weekly: 700, monthly: 2300 }, delivery: 100,
    features: ['Apple CarPlay and Android Auto', 'Heated front seats', '360 degree camera', 'Adaptive cruise control', 'Leather seats', 'All-season tires'],
    blurb: 'The one people ask for by name. Quiet on the highway, room for three bags.',
    booked: [['2026-10-15', '2026-10-21'], ['2026-11-06', '2026-11-08']], pending: [['2026-10-24', '2026-10-26']] }),
  car({ code: 'CC 04', make: 'Mercedes-Benz', model: 'GLC300', year: 2022, trim: '4MATIC SUV', cls: 'SUV', body: 'Compact SUV', shape: 'suv', paint: 'black', colour: 'Obsidian Black', drive: 'All-wheel drive', bags: 4, l100: '9.6 L/100 km combined',
    rates: { daily: 135, weekend: 160, weekly: 800, monthly: 2650 }, delivery: 125,
    features: ['Apple CarPlay and Android Auto', 'Heated front seats', 'Power tailgate', 'Backup camera', 'Roof rails', 'All-season tires'],
    blurb: 'Higher seat, bigger trunk, the same Mercedes cabin. Good for Blue Mountain weekends.',
    booked: [['2026-10-23', '2026-10-26'], ['2026-11-10', '2026-11-19']], pending: [] }),
  car({ code: 'CC 05', make: 'Mercedes-Benz', model: 'GLE350', year: 2023, trim: '4MATIC SUV', cls: 'Luxury', body: 'Mid-size SUV', shape: 'suvlg', paint: 'white', colour: 'Diamond White', drive: 'All-wheel drive', bags: 5, l100: '10.4 L/100 km combined', kmPerDay: 150, overage: 0.75,
    rates: { daily: 189, weekend: 225, weekly: 1120, monthly: 3700 }, delivery: 175,
    features: ['Apple CarPlay and Android Auto', 'Heated and ventilated seats', 'Air suspension', '360 degree camera', 'Burmester sound', 'Power tailgate'],
    blurb: 'The big one. Five adults and their luggage, in real comfort, to Muskoka and back.',
    booked: [['2026-10-20', '2026-10-22'], ['2026-11-01', '2026-11-04']], pending: [['2026-10-29', '2026-10-31']] }),
  car({ code: 'CC 06', make: 'Toyota', model: 'Corolla', year: 2023, trim: 'LE', cls: 'Economy', body: 'Sedan', shape: 'compact', paint: 'silver', colour: 'Classic Silver', drive: 'Front-wheel drive', bags: 2, l100: '6.7 L/100 km combined', young: true,
    rates: { daily: 59, weekend: 69, weekly: 350, monthly: 1150 }, delivery: 75,
    features: ['Apple CarPlay and Android Auto', 'Backup camera', 'Lane keeping assist', 'Adaptive cruise control', 'Heated front seats', 'All-season tires'],
    blurb: 'Cheap to rent, cheap to fuel, and it starts every morning. Open to drivers aged 18 to 20.',
    booked: [['2026-10-15', '2026-10-16'], ['2026-10-20', '2026-10-30']], pending: [] }),
  car({ code: 'CC 07', make: 'Hyundai', model: 'Elantra', year: 2023, trim: 'Preferred', cls: 'Economy', body: 'Sedan', shape: 'fastback', paint: 'grey', colour: 'Cyber Grey', drive: 'Front-wheel drive', bags: 2, l100: '6.4 L/100 km combined', young: true,
    rates: { daily: 62, weekend: 72, weekly: 365, monthly: 1200 }, delivery: 75,
    features: ['Apple CarPlay and Android Auto', 'Heated front seats', 'Heated steering wheel', 'Backup camera', 'Blind spot assist', 'All-season tires'],
    blurb: 'More legroom than you expect at this price. Open to drivers aged 18 to 20.',
    booked: [['2026-10-24', '2026-10-25'], ['2026-11-03', '2026-11-12']], pending: [['2026-10-17', '2026-10-19']] }),
  car({ code: 'CC 08', make: 'Honda', model: 'Civic', year: 2022, trim: 'Sport', cls: 'Standard', body: 'Sedan', shape: 'compact', paint: 'red', colour: 'Rallye Red', drive: 'Front-wheel drive', bags: 2, l100: '7.1 L/100 km combined', young: true,
    rates: { daily: 69, weekend: 82, weekly: 410, monthly: 1350 }, delivery: 75,
    features: ['Apple CarPlay and Android Auto', 'Heated front seats', 'Backup camera', 'Adaptive cruise control', 'Remote start', 'All-season tires'],
    blurb: 'A proper daily driver with a bit of life in the steering. Open to drivers aged 18 to 20.',
    booked: [['2026-10-19', '2026-10-22'], ['2026-11-14', '2026-11-16']], pending: [] }),
  car({ code: 'CC 09', make: 'Toyota', model: 'RAV4', year: 2023, trim: 'XLE AWD', cls: 'SUV', body: 'Compact SUV', shape: 'suv', paint: 'grey', colour: 'Magnetic Grey', drive: 'All-wheel drive', bags: 4, l100: '8.0 L/100 km combined',
    rates: { daily: 89, weekend: 105, weekly: 525, monthly: 1750 }, delivery: 125,
    features: ['Apple CarPlay and Android Auto', 'Heated front seats', 'Power tailgate', 'Roof rails', 'Adaptive cruise control', 'All-season tires'],
    blurb: 'The sensible SUV. All-wheel drive, a flat load floor and fuel bills that stay small.',
    booked: [['2026-10-26', '2026-10-29'], ['2026-10-31', '2026-11-07']], pending: [] }),
  car({ code: 'CC 10', make: 'Tesla', model: 'Model 3', year: 2023, trim: 'Rear-Wheel Drive', cls: 'Premium', body: 'Sedan', shape: 'fastback', paint: 'white', colour: 'Pearl White', drive: 'Rear-wheel drive', bags: 3, fuel: 'Electric', l100: 'About 430 km of range',
    rates: { daily: 109, weekend: 129, weekly: 645, monthly: 2150 }, delivery: 100,
    features: ['15 inch touchscreen', 'Autopilot', 'Glass roof', 'Heated seats, front and rear', 'Mobile charging cable', 'All-season tires'],
    blurb: 'No gas stations. Return it with the charge you left with and that is the whole fuel policy.',
    booked: [['2026-10-22', '2026-10-25'], ['2026-11-07', '2026-11-09']], pending: [['2026-10-16', '2026-10-17']] }),
  car({ code: 'CC 11', make: 'Chrysler', model: 'Pacifica', year: 2022, trim: 'Touring L', cls: 'Premium', body: 'Minivan', shape: 'van', paint: 'silver', colour: 'Billet Silver', drive: 'Front-wheel drive', seats: 7, bags: 6, l100: '10.6 L/100 km combined',
    rates: { daily: 99, weekend: 119, weekly: 590, monthly: 1950 }, delivery: 125,
    features: ['Seven seats', 'Power sliding doors', 'Stow and go seating', 'Apple CarPlay and Android Auto', 'Tri-zone climate', 'Backup camera'],
    blurb: 'Seven seats and doors that open themselves. The airport run with everybody in one car.',
    booked: [['2026-10-21', '2026-10-28'], ['2026-11-21', '2026-11-23']], pending: [] }),
  car({ code: 'CC 12', make: 'Mazda', model: 'MX-5', year: 2021, trim: 'GS-P Soft Top', cls: 'Premium', body: 'Convertible', shape: 'roadster', paint: 'red', colour: 'Soul Red', drive: 'Rear-wheel drive', seats: 2, doors: 2, bags: 1, transmission: 'Manual', l100: '7.8 L/100 km combined',
    rates: { daily: 99, weekend: 135, weekly: 620, monthly: 2050 }, delivery: 100,
    features: ['Six-speed manual', 'Soft top', 'Apple CarPlay and Android Auto', 'Heated seats', 'Bose sound', 'Limited-slip differential'],
    blurb: 'Two seats, a manual gearbox and a roof you fold with one hand. Not practical. That is the point.',
    booked: [['2026-10-23', '2026-10-25'], ['2026-10-30', '2026-11-01']], pending: [] })
];

export const FEATURED = ['mercedes-benz-c300', 'mercedes-benz-a220', 'mercedes-benz-cla250', 'mercedes-benz-glc300', 'toyota-corolla', 'tesla-model-3', 'mazda-mx-5'];

export const bySlug = (s) => CARS.find((c) => c.slug === s);
export const money = (n) => '$' + Number(n).toLocaleString('en-CA', { minimumFractionDigits: Number.isInteger(n) ? 0 : 2, maximumFractionDigits: 2 });
