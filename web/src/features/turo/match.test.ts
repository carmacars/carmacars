// Unit tests for the automatic car matching of Turo emails (migration 0088): no setup per car, scored signals, learned
// identities, the model's short list, and the guest's details. The fleet below is shaped like CarmaCars' real one
// (three Volkswagen Jettas, two of them black 2021s) plus a few cars for the aliases. The emails in samples/ and below
// are written for these tests in the shapes Turo sends hosts.
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { parseMime, parseTuroEmail, mergeAi, type MatchCar, type MatchTrip } from './email.ts';
import { acceptAiCar, aiCarPrompt, aiCarSchema, carNamesOf, coloursIn, guestOf, modelFamily, modelHit, scoreCars, signalsOf, turoCarIdsOf } from './match.ts';

const raw = (f: string) => readFileSync(join(import.meta.dirname, 'samples', `${f}.eml`), 'utf8');
const car = (id: string, year: number, make: string, model: string, trim: string | null, colour: string | null, plate: string, extra: Partial<MatchCar> = {}): MatchCar =>
  ({ vehicle_id: id, name: `${year} ${make} ${model}`, plate, vin: null, make, model, year, trim, colour, identities: [], busy: [], ...extra });
const FLEET: MatchCar[] = [
  car('cts', 2015, 'Cadillac', 'CTS', 'Luxury', 'SILVER', 'CTSA 715'),
  car('malibu', 2022, 'Chevrolet', 'Malibu', 'LS', 'Black', 'MLBU 043'),
  car('forte', 2021, 'KIA', 'Forte', 'FE, LXS', 'BLACK', 'FRTE 705'),
  car('macan', 2016, 'Porsche', 'Macan', null, 'BLUE', 'MCAN 713'),
  car('beetle', 2019, 'Volkswagen', 'Beetle', 'S, Final Edition SE, Final Edition SEL, SE', 'Black', 'BTLE 616'),
  car('jetta17', 2017, 'Volkswagen', 'Jetta', 'S', 'Grey', 'JTTA 714'),
  car('jettaSEL', 2021, 'Volkswagen', 'Jetta', 'SEL', 'BLACK', 'JTTA 704'),
  car('jettaS', 2021, 'Volkswagen', 'Jetta', 'S / SE / R-Line', 'BLACK', 'JTTA 702'),
  car('jetta24', 2024, 'VOLKSWAGEN', 'JETTA', 'COMFORTLINE SPORT', 'GREY', 'JTTA 176'),
  car('c300', 2024, 'Mercedes-Benz', 'C300', '4MATIC Sedan', 'Iridium Silver', 'CKRT 482'),
  car('glc', 2021, 'Mercedes-Benz', 'GLC 300', '4MATIC SUV', 'Obsidian Black', 'GLCC 100'),
  car('model3', 2023, 'Tesla', 'Model 3', 'Rear-Wheel Drive', 'Pearl White', 'TSLA 010'),
  car('bmw', 2022, 'BMW', '330i', 'xDrive Sedan', 'Mineral Grey', 'BMWW 018'),
  car('camryB', 2023, 'Toyota', 'Camry', 'SE', 'Midnight Black', 'CMRY 014'),
  car('camryW', 2023, 'Toyota', 'Camry', 'SE', 'Pearl White', 'CMRY 015')
];
const learn = (cars: MatchCar[], id: string, ids: Array<{ kind: 'turo_car_id' | 'name'; value: string }>) =>
  cars.map((c) => (c.vehicle_id === id ? { ...c, identities: [...(c.identities ?? []), ...ids.map((x) => ({ ...x, source: 'staff' as const }))] } : c));
const mail = (subject: string, body: string, html = '') => parseMime(`From: Turo <noreply@mail.turo.com>\nTo: rent@carmacars.ca\nSubject: ${subject}\nDate: Mon, 02 Nov 2026 10:00:00 -0500\nMessage-ID: <t@mail.turo.com>\nMIME-Version: 1.0\n` +
  (html ? `Content-Type: multipart/alternative; boundary="B"\n\n--B\nContent-Type: text/plain\n\n${body}\n--B\nContent-Type: text/html\n\n${html}\n--B--\n` : `Content-Type: text/plain\n\n${body}\n`));
const body = (car: string, trip = '55500011') => `Sam booked your ${car}.\nTrip start: Sat, Nov 14, 2026 11:00 AM\nTrip end: Mon, Nov 16, 2026 11:00 AM\nReservation ID: ${trip}\n`;
const pick = (subject: string, b: string, cars = FLEET, trips: MatchTrip[] = [], html = '') => parseTuroEmail(mail(subject, b, html), cars, new Date('2026-11-02T15:00:00Z'), trips);

test('no setup per car: a unique make and model is found with no name on Turo, whatever the case or spacing', () => {
  for (const [name, want] of [['Chevrolet Malibu 2022', 'malibu'], ['CHEVROLET MALIBU 2022', 'malibu'], ['Porsche Macan 2016', 'macan'], ['Cadillac CTS 2015', 'cts'],
    ['Kia Forte 2021', 'forte'], ['Volkswagen Beetle 2019', 'beetle'], ['Volkswagen Jetta 2024', 'jetta24'], ['VW Jetta 2017', 'jetta17']] as const) {
    const p = pick(`Sam booked your ${name}`, body(name));
    assert.equal(p.vehicleId, want, name);
    assert.deepEqual(p.missing, [], name);
    assert.equal(p.matchHow, 'score');
  }
});

test('model aliases: C-Class for a C300, Model3 for Model 3, 3 Series for a 330i, GLC for a GLC 300, Mercedes for Mercedes-Benz', () => {
  assert.equal(pick('Sam booked your Mercedes-Benz C-Class 2024', body('Mercedes-Benz C-Class 2024')).vehicleId, 'c300');
  assert.equal(pick('Sam booked your Mercedes C 300 2024', body('Mercedes C 300 2024')).vehicleId, 'c300');
  assert.equal(pick('Sam booked your Tesla Model3 2023', body('Tesla Model3 2023')).vehicleId, 'model3');
  assert.equal(pick('Sam booked your Tesla Model 3 2023', body('Tesla Model 3 2023')).vehicleId, 'model3');
  assert.equal(pick('Sam booked your BMW 3 Series 2022', body('BMW 3 Series 2022')).vehicleId, 'bmw');
  assert.equal(pick('Sam booked your Mercedes-Benz GLC 2021', body('Mercedes-Benz GLC 2021')).vehicleId, 'glc');
  assert.equal(modelFamily('C300', 'Mercedes-Benz'), 'c');
  assert.equal(modelFamily('C-Class', 'Mercedes-Benz'), 'c');
  assert.equal(modelFamily('GLC 300', 'Mercedes'), 'glc');
  assert.equal(modelFamily('330i', 'BMW'), '3series');
  assert.equal(modelHit(['Tesla Model3'], 'Model 3', 'Tesla'), 30);
  assert.equal(modelHit(['Mercedes-Benz C-Class 2024'], 'C300', 'Mercedes-Benz'), 22);
  assert.equal(modelHit(['Mercedes-Benz A 2021'], 'A220', 'Mercedes-Benz'), 0); // one letter alone is not a model
});

test('another year or make never wins: a 2022 Jetta is none of ours, a Honda Jetta-like name is not a Volkswagen', () => {
  const p = pick('Sam booked your Volkswagen Jetta 2022', body('Volkswagen Jetta 2022'));
  assert.equal(p.vehicleId, null);
  assert.deepEqual(p.missing, ['car']);
  const q = pick('Sam booked your Honda Civic 2022', body('Honda Civic 2022'));
  assert.equal(q.vehicleId, null);
  assert.equal(q.candidates.length, 0);
});

test('two black 2021 Jettas: the same Turo name cannot tell them apart, so the short list has both, best first', () => {
  const p = parseTuroEmail(parseMime(raw('booked-jetta-link')), FLEET);
  assert.equal(p.kind, 'booked');
  assert.equal(p.tripId, '54100777');
  assert.deepEqual(p.turoCarIds, ['3355101']);
  assert.equal(p.carName, 'Volkswagen Jetta 2021');
  assert.equal(p.vehicleId, null);
  assert.deepEqual(p.missing, ['car']);
  assert.deepEqual(p.candidates.map((c) => c.vehicle_id).sort(), ['jettaS', 'jettaSEL']);
  assert.match(p.vehicleWhy ?? '', /matches 2 cars/);
});

test('learning: a Turo car id confirmed once matches that car instantly, and the other Jetta gets any other id', () => {
  const taught = learn(FLEET, 'jettaSEL', [{ kind: 'turo_car_id', value: '3355101' }, { kind: 'name', value: 'Volkswagen Jetta 2021' }]);
  const p = parseTuroEmail(parseMime(raw('booked-jetta-link')), taught);
  assert.equal(p.vehicleId, 'jettaSEL');
  assert.equal(p.matchHow, 'turo_id');
  assert.match(p.vehicleWhy ?? '', /Turo car 3355101/);
  // the second Jetta's first email: a Turo id we have not seen goes to the Jetta without one (the first has its own)
  const other = parseTuroEmail(parseMime(raw('booked-jetta-link').replaceAll('3355101', '3355999')), taught);
  assert.equal(other.vehicleId, 'jettaS');
  assert.ok(other.candidates.find((c) => c.vehicle_id === 'jettaSEL')!.why.some((w) => /another Turo car/.test(w)));
  // a learned name alone never decides between identical cars (no Turo id in a plain email)
  const plain = pick('Omar booked your Volkswagen Jetta 2021', body('Volkswagen Jetta 2021'), taught);
  assert.equal(plain.vehicleId, null);
});

test('a learned name decides when the cars differ only by what our records call them', () => {
  const odd = [...FLEET, car('corolla', 2022, 'Toyota', 'Corolla Test', null, null, 'TEST 001')];
  const before = pick('Sam booked your Toyota Corolla 2022', body('Toyota Corolla 2022'), odd);
  assert.equal(before.vehicleId, null); // "Corolla Test" is not "Corolla"
  const after = pick('Sam booked your Toyota Corolla 2022', body('Toyota Corolla 2022'), learn(odd, 'corolla', [{ kind: 'name', value: 'Toyota Corolla 2022' }]));
  assert.equal(after.vehicleId, 'corolla');
  assert.equal(after.matchHow, 'learned');
});

test('plate, VIN and the optional typed name on Turo still decide at once', () => {
  assert.equal(pick('Sam booked your Volkswagen Jetta 2021', body('Volkswagen Jetta 2021 (plate JTTA-702)')).vehicleId, 'jettaS');
  assert.equal(pick('Sam booked your Volkswagen Jetta 2021', body('Volkswagen Jetta 2021 (plate jtta704)')).vehicleId, 'jettaSEL');
  const vin = FLEET.map((c) => (c.vehicle_id === 'jettaS' ? { ...c, vin: '3VWC57BU1MM000702' } : c));
  const v = pick('Sam booked your Volkswagen Jetta 2021', body('Volkswagen Jetta 2021') + 'VIN: 3VWC57BU1MM000702\n', vin);
  assert.equal(v.vehicleId, 'jettaS');
  assert.equal(v.matchHow, 'vin');
  const typed = FLEET.map((c) => (c.vehicle_id === 'jettaSEL' ? { ...c, listing_name: 'Jetta SEL Black' } : c));
  const t = pick('Sam booked your Jetta SEL Black', body('Jetta SEL Black'), typed);
  assert.equal(t.vehicleId, 'jettaSEL');
  assert.equal(t.matchHow, 'override');
});

test('two cars of the same model told apart by colour words, trim words or year', () => {
  assert.equal(pick('Sam booked your Toyota Camry 2023', body('Toyota Camry 2023')).vehicleId, null);
  const html = '<p><img src="https://images.turo.com/x.jpg" alt="White Toyota Camry 2023"></p><p>Sam booked your Toyota Camry 2023</p>';
  const w = pick('Sam booked your Toyota Camry 2023', body('Toyota Camry 2023'), FLEET, [], html);
  assert.equal(w.vehicleId, 'camryW');
  assert.deepEqual(w.colours, ['white']);
  assert.equal(pick('Sam booked your Toyota Camry 2023', body('Toyota Camry 2023') + 'Colour: Black\n').vehicleId, 'camryB');
  assert.equal(pick('Sam booked your Volkswagen Jetta SEL 2021', body('Volkswagen Jetta SEL 2021')).vehicleId, 'jettaSEL');
  assert.equal(pick('Sam booked your Volkswagen Jetta R-Line 2021', body('Volkswagen Jetta R-Line 2021')).vehicleId, 'jettaS');
  assert.equal(pick('Sam booked your Volkswagen Jetta 2017', body('Volkswagen Jetta 2017')).vehicleId, 'jetta17');
  assert.deepEqual(coloursIn('Obsidian Black'), ['black']);
  assert.deepEqual(coloursIn('Mineral Grey'), ['grey']);
  assert.deepEqual(coloursIn('Panthera Metal'), []);
});

test('the trip and the guest: a change email without the car finds it by its trip; a guest\'s earlier trip and a busy car tip the balance', () => {
  const trips: MatchTrip[] = [{ trip_id: '54100777', vehicle_id: 'jettaS', guest_first_name: 'Omar', starts_at: '2026-11-14T14:00:00Z', ends_at: '2026-11-16T14:00:00Z' }];
  const p = parseTuroEmail(parseMime(raw('changed-no-car')), FLEET, new Date(), trips);
  assert.equal(p.kind, 'changed');
  assert.equal(p.vehicleId, 'jettaS');
  assert.equal(p.matchHow, 'trip');
  assert.deepEqual(p.missing, []);
  // the other Jetta is busy then: the free one is the better guess, and with nothing else it decides
  const busy = FLEET.map((c) => (c.vehicle_id === 'jettaSEL' ? { ...c, busy: [['2026-11-13T00:00:00Z', '2026-11-18T00:00:00Z', '1'] as [string, string, string]] } : c));
  const b = pick('Sam booked your Volkswagen Jetta 2021', body('Volkswagen Jetta 2021'), busy);
  assert.equal(b.vehicleId, 'jettaS');
});

test('the car named in an image\'s alt text, and Turo car ids in image addresses and links (never the trip number)', () => {
  const m = parseMime(raw('booked-alt-malibu'));
  const p = parseTuroEmail(m, FLEET);
  assert.equal(p.kind, 'booked');
  assert.equal(p.vehicleId, 'malibu');
  assert.equal(p.carName, '2022 Chevrolet Malibu LS');
  assert.deepEqual(p.turoCarIds, ['8822001']);
  assert.deepEqual(turoCarIdsOf('https://turo.com/ca/en/reservation/54200888 https://turo.com/us/en/suv-rental/united-states/x/y/z/2711093?utm=1 https://turo.com/vehicles/123456', '54200888'), ['2711093', '123456']);
  assert.deepEqual(carNamesOf('x', 'Car: Porsche Macan 2016 https://turo.com/a', '', ['Porsche']), ['Porsche Macan 2016']);
});

test('the model picks only from the short list; "unsure" or an id outside it is refused', () => {
  const p = parseTuroEmail(parseMime(raw('booked-jetta-link')), FLEET);
  const ids = p.candidates.map((c) => c.vehicle_id);
  assert.deepEqual((aiCarSchema(ids).properties.vehicle_id as { enum: string[] }).enum, [...ids, 'unsure']);
  const prompt = aiCarPrompt(signalsOf('s', 'Omar booked your Volkswagen Jetta 2021', '', { tripId: null, guest: null, start: null, end: null, makes: ['Volkswagen'] }), 's',
    FLEET.filter((c) => ids.includes(c.vehicle_id)));
  assert.match(prompt, /colour BLACK, plate ending 704/);
  assert.equal(acceptAiCar({ vehicle_id: 'jettaS' }, p.candidates), 'jettaS');
  assert.equal(acceptAiCar({ vehicle_id: 'unsure' }, p.candidates), null);
  assert.equal(acceptAiCar({ vehicle_id: 'macan' }, p.candidates), null);
  assert.equal(acceptAiCar('jettaS', p.candidates), null);
  // the general reading's "car" counts only when it is one of the short list
  const merged = mergeAi(p, { car: 'Porsche Macan 2016' }, parseMime(raw('booked-jetta-link')), FLEET);
  assert.equal(merged.vehicleId, null);
});

test('scores in words: the reasons say why each car was chosen or not', () => {
  const sig = signalsOf('Sam booked your Volkswagen Jetta 2021', body('Volkswagen Jetta 2021'), '', { tripId: null, guest: 'Sam', start: null, end: null, makes: ['Volkswagen'] });
  const s = scoreCars(sig, 'Sam booked your Volkswagen Jetta 2021', body('Volkswagen Jetta 2021'), FLEET);
  const j17 = s.find((x) => x.vehicle_id === 'jetta17')!;
  assert.ok(j17.why.includes('-25 another year (2021)'));
  assert.ok(s.find((x) => x.vehicle_id === 'macan')!.why.includes('-40 the email names another make'));
});

test('the guest: the full name as shown, a phone and an email next to the guest; masked or Turo\'s own numbers are not taken', () => {
  const a = parseTuroEmail(parseMime(raw('booked')), FLEET);
  assert.equal(a.guestName, 'Ayesha K.');
  assert.equal(a.guestPhone, '+14165550199');
  assert.equal(a.guestEmail, null);
  const b = parseTuroEmail(parseMime(raw('booked-alt-malibu')), FLEET);
  assert.equal(b.guestName, 'Priya Shah');
  assert.equal(b.guestPhone, '+16475550142');
  assert.equal(b.guestEmail, 'priya.shah@example.test');
  const c = parseTuroEmail(parseMime(raw('booked-masked')), FLEET);
  assert.equal(c.guestName, 'Liam T.');
  assert.equal(c.guestPhone, null);
  assert.equal(c.guestPhoneMasked, true);
  assert.equal(c.vehicleId, 'model3');
  const d = parseTuroEmail(parseMime(raw('booked-jetta-link')), FLEET);
  assert.equal(d.guestName, 'Omar R.');
  assert.equal(d.guestPhone, null); // Turo support's toll-free number is not the guest's
  const e = parseTuroEmail(parseMime(raw('unclear')), FLEET);
  assert.equal(e.guestPhone, '+16475550123');
  for (const [line, want] of [['Call Noor at 416.555.0101', '+14165550101'], ['Text Noor: +1 416 555 0101', '+14165550101'], ['Noor: 1-416-555-0101', '+14165550101'],
    ['Noor: (416) 555-01XX', null], ['Noor: +1 ••• ••• 0101', null], ['Reach Turo support at 416-555-0101', null], ['Call us at 647-555-0000', null]] as const) {
    assert.equal(guestOf('Noor booked your car', line, 'Noor').phone, want, line);
  }
  assert.equal(guestOf('Noor booked your car', 'Noor: noor@guest.turo.com', 'Noor').email, null);
  assert.equal(guestOf('Noor A. Haddad booked your car', '', 'Noor').name, 'Noor A. Haddad');
});

test('the sample emails of 0063 still read the same with the new matcher (no names typed, cars from the records)', () => {
  const cars: MatchCar[] = [car('glc21', 2021, 'Mercedes-Benz', 'GLC 300', null, null, 'CMRA 100'), car('c24', 2024, 'Mercedes-Benz', 'C 300', null, null, 'CKRT 482')];
  for (const f of ['booked', 'changed', 'extended']) assert.equal(parseTuroEmail(parseMime(raw(f)), cars).vehicleId, 'glc21', f);
  assert.equal(parseTuroEmail(parseMime(raw('booked-range')), cars).vehicleId, 'c24');
  assert.equal(parseTuroEmail(parseMime(raw('forwarded-by-hand')), cars).vehicleId, 'c24');
});
