// The tracker pages (release 48, docs/changes/2026-11-20-r48-seo.md): the product page /trackers, one page per search
// intent (/trackers/<slug>) and the install pages (/trackers/install/<place>). Pure: every price, the product's name, the
// reading interval and whether trackers can be installed come from Program settings (public.tracker_product); a page
// never says a tracker is in stock while trackers_available is off. What the tracker does is the owner's list (Nov 20):
// live GPS for the owner and for us; remote lock, door release, alarm and engine shut-off; tolls and tickets billed to
// the renter who had the car. Relative imports only (the unit test runs it in Node).
import { money } from '../../lib/format.ts';
import type { KitIcon } from '../seo/kit/icons.tsx';

/** The tracker's own price (Program settings): free for our vehicle owners, free for the first pre-orders, then the
 *  pre-order price, and the regular price after launch. `freeFirst` is the number the site says; the count that closes
 *  the offer is kept on the server and never shown. */
export interface Prices { ownerCents: number; preorderCents: number; regularCents: number; freeFirst: number; freeOpen: boolean }
export interface TrackerFacts { name: string; brand: string; city: string; prices: Prices; installCents: number | null; available: boolean; launchNote: string; features: Array<{ title: string; text: string }>; hst: string }
export interface Faq { question: string; answer: string }
export interface TrackerIntent {
  slug: string; title: string; h1: string; kicker: string; icon: KitIcon;
  /** the answer in one or two sentences: what a person or an answer engine takes away */
  answer: string;
  /** the page's own section */
  section: { h: string; p: string; steps?: Array<[string, string]>; points?: Array<{ icon: KitIcon; title: string; text: string }> };
  compare: { caption: string; head: string[]; rows: string[][] };
  faq: Faq[];
  /** which features lead on this page (by the start of the feature's title) */
  lead: string[];
}

type Staged = Pick<TrackerFacts, 'prices' | 'available'>;
/** The prices as public.tracker_product answers them, with the owner's Nov 20 prices where an older answer has none. */
export function toPrices(p?: { owner_cents?: number; preorder_cents?: number; regular_cents?: number; free_first?: number; free_open?: boolean } | null): Prices {
  return { ownerCents: p?.owner_cents ?? 0, preorderCents: p?.preorder_cents ?? 9000, regularCents: p?.regular_cents ?? 17500, freeFirst: p?.free_first ?? 100, freeOpen: Boolean(p?.free_open) };
}
export const priceWord = (c: number) => (c === 0 ? 'free' : money(c));
const cap = (x: string) => x.replace(/^./, (c) => c.toUpperCase());
/** What a person who is not a vehicle owner pays for the tracker today. */
export const deviceNow = (f: Staged) => (f.available ? f.prices.regularCents : f.prices.freeOpen ? 0 : f.prices.preorderCents);
/** Which price applies now: 'regular' after launch, 'free' while the free pre-orders last, 'preorder' after that. */
export const stage = (f: Staged): 'regular' | 'free' | 'preorder' => (f.available ? 'regular' : f.prices.freeOpen ? 'free' : 'preorder');
export const ownerSentence = (f: TrackerFacts) => `${f.brand} vehicle owners get the tracker ${f.prices.ownerCents === 0 ? 'free' : `for ${money(f.prices.ownerCents)}`}`;
/** "the tracker is free for the first 100 pre-orders, $90 on pre-order after that and $175 after launch; CarmaCars vehicle owners get the tracker free" */
export function priceSentence(f: TrackerFacts): string {
  const x = f.prices;
  const main = stage(f) === 'regular' ? `the tracker is ${priceWord(x.regularCents)}`
    : stage(f) === 'free' ? `the tracker is free for the first ${x.freeFirst} pre-orders, ${priceWord(x.preorderCents)} on pre-order after that and ${priceWord(x.regularCents)} after launch`
      : `the tracker is ${priceWord(x.preorderCents)} on pre-order and ${priceWord(x.regularCents)} after launch`;
  return `${main}; ${ownerSentence(f)}`;
}
export const PriceSentence = (f: TrackerFacts) => cap(priceSentence(f));
/** The price in a few words, for a table cell or a card. */
export function priceShort(f: Staged): string {
  const x = f.prices;
  return stage(f) === 'regular' ? money(x.regularCents) : stage(f) === 'free' ? `Free for the first ${x.freeFirst} pre-orders, then ${money(x.preorderCents)}` : `${money(x.preorderCents)} on pre-order`;
}
export const installSentence = (f: TrackerFacts) => (f.installCents ? `${money(f.installCents)} once per car to install` : 'the install is quoted for your car');
/** The offer in one line: "Free for the first 100 pre-orders, plus $150 once per car to install". */
export const offer = (f: TrackerFacts) => `${priceShort(f)}, plus ${installSentence(f)}`;
/** The rows of the price table: who, the tracker, the install. */
export function priceRows(f: TrackerFacts): string[][] {
  const x = f.prices, ins = f.installCents ? money(f.installCents) : 'Quoted';
  const W = (c: number) => (c === 0 ? 'Free' : money(c));
  return [[`${f.brand} vehicle owners`, W(x.ownerCents), ins],
    ...(stage(f) === 'free' ? [[`The first ${x.freeFirst} pre-orders`, 'Free', ins], ['Pre-orders after that', W(x.preorderCents), ins]] : stage(f) === 'preorder' ? [['Pre-orders', W(x.preorderCents), ins]] : []),
    [f.available ? 'Everyone else' : 'After launch', W(x.regularCents), ins]];
}
/** How the page says when a tracker can be had: never "in stock" while trackers cannot be installed. */
export const availability = (f: TrackerFacts) => (f.available ? 'Installs are open now' : `${f.launchNote}: join the waitlist or pre-order`);
export const ctaLabel = (f: TrackerFacts) => (f.available ? 'Order a tracker' : 'Pre-order or join the waitlist');

/** The product in one quotable sentence. */
export function productAnswer(f: TrackerFacts): string {
  return `The ${f.name} is a GPS tracker with a remote kill switch for cars in Ontario: live location, a starter interrupt that keeps a parked car from being started, remote door locking and an alarm, from your phone. `
    + `${PriceSentence(f)}. Everyone pays ${installSentence(f)}. Prices are before ${f.hst} HST. ${availability(f)}.`;
}

const US = (f: TrackerFacts) => f.name;
const price = priceShort;

export function trackerIntents(f: TrackerFacts): TrackerIntent[] {
  const install = f.installCents ? money(f.installCents) : 'a quoted price';
  return [
    {
      slug: 'kill-switch-for-car', title: `Kill switch for a car: remote engine shut-off | ${f.brand}`, h1: 'Kill switch for a car, worked from your phone', kicker: 'Remote kill switch', icon: 'power',
      answer: `A kill switch keeps a car from being started. The ${f.name} adds one you work from your phone: a starter interrupt wired in by us, with live GPS so you also know where the car is. ${offer(f)}. ${availability(f)}.`,
      section: { h: 'How a remote kill switch works', p: 'A classic kill switch is a hidden toggle: you have to be at the car to flip it. Ours is wired to the starter and answers to your phone.',
        steps: [['The car is parked', 'A late rental, a missed payment, a car that is not where it should be: you open the car on your phone.'],
          ['You switch the starter off', 'The starter interrupt keeps the engine from being started again. It acts on a parked car, when the car is next started.'],
          ['You know where it is', 'The live location shows the car on the map, so you or the police go straight to it.'],
          ['You switch it back on', 'One tap gives the starter back when the car is home or the bill is paid.']] },
      compare: { caption: 'A remote kill switch compared with a hidden toggle and a steering wheel lock', head: ['', US(f), 'Hidden toggle switch', 'Steering wheel lock'],
        rows: [['Works when you are away from the car', 'Yes, from your phone', 'No, you flip it by hand', 'No, you fit it by hand'], ['Shows where the car is', 'Yes, live GPS', 'No', 'No'],
          ['Someone with the key can drive away', 'Not once the starter is off', 'Yes, if they find the toggle', 'Yes, once the lock is removed'], ['Good for a rented or shared car', 'Yes: nothing for the driver to do', 'The driver must know the toggle', 'The driver must carry the key'],
          ['Cost', `${price(f)} plus ${install} install`, 'Parts and an installer', 'One purchase']] },
      faq: [
        { question: 'What is a kill switch on a car?', answer: 'A switch that breaks a circuit the engine needs to start, usually the starter, the fuel pump or the ignition. With it off, turning the key or pressing Start does nothing. Ours interrupts the starter and is switched from your phone.' },
        { question: 'Is a kill switch the same as a starter interrupt?', answer: 'A starter interrupt is one kind of kill switch: it stops the starter from cranking the engine. It is the kind used on rental and financed cars because it acts on a parked car.' },
        { question: 'Can it stop a car that is being driven?', answer: 'It is a starter interrupt: it keeps a parked car from being started. It is used once the car has stopped, together with the live location.' },
        { question: `How much does a kill switch cost in ${f.city}?`, answer: `${PriceSentence(f)}. Everyone pays ${installSentence(f)}. Prices are before ${f.hst} HST. The GPS tracking, the door locking and the alarm are part of the same tracker.` },
        { question: 'Who installs it?', answer: `${f.brand} installs the tracker out of sight and checks that it works before the car goes out.` }],
      lead: ['Kill switch', 'Live GPS', 'Alarm']
    },
    {
      slug: 'starter-interrupt-device', title: `Starter interrupt device with GPS, installed in ${f.city} | ${f.brand}`, h1: 'Starter interrupt device with live GPS', kicker: 'Starter interrupt', icon: 'key',
      answer: `A starter interrupt device stops a parked car from being started until you allow it. The ${f.name} pairs one with live GPS, so a car that is overdue or unpaid stays where it is and you can see where that is. ${offer(f)}. ${availability(f)}.`,
      section: { h: 'Who uses a starter interrupt', p: 'Anyone who hands their car to someone else and needs a calm way to get it back.',
        points: [{ icon: 'car', title: 'Rental car owners', text: 'A renter keeps the car past the return time and stops answering. The starter goes off at the next stop and the map shows the car.' },
          { icon: 'users', title: 'Turo and peer-to-peer hosts', text: 'One host, several cars, guests you have never met: every car answers to your phone.' },
          { icon: 'fleet', title: 'Small fleets and dealers', text: 'Cars out on weekly or monthly terms, each one visible and each one recoverable.' }] },
      compare: { caption: 'A starter interrupt with GPS compared with a GPS tracker alone', head: ['', US(f), 'A GPS tracker alone', 'A Bluetooth tag'],
        rows: [['Live location', 'Yes', 'Yes', 'Only near a phone on its network'], ['Keeps the car from being started', 'Yes, starter interrupt', 'No', 'No'], ['Lock the doors remotely', 'Yes', 'Rarely', 'No'],
          ['Sound the horn and lights', 'Yes', 'Rarely', 'A beep at the tag'], ['Installed out of sight', `Yes, by ${f.brand}`, 'Often plugged into the OBD port', 'Hidden by you']] },
      faq: [
        { question: 'What does a starter interrupt device do?', answer: 'It opens the starter circuit on command, so the engine will not crank. The car is unharmed and starts normally again as soon as the starter is switched back on.' },
        { question: 'Does it drain the battery or change how the car drives?', answer: `Ask us about your car when you join the waitlist: ${f.brand} installs each tracker and checks the car starts, locks and reports its location before it goes back out.` },
        { question: 'Can the driver switch it off?', answer: 'The tracker is installed out of sight and is switched only from the owner\'s account.' },
        { question: 'What does it cost?', answer: `${PriceSentence(f)}. Everyone pays ${installSentence(f)}. Prices are before ${f.hst} HST.` }],
      lead: ['Kill switch', 'Remote lock', 'Installed']
    },
    {
      slug: 'gps-tracker-for-rental-car', title: `GPS tracker for rental cars: location, kill switch | ${f.brand}`, h1: 'GPS tracker for rental cars', kicker: 'For rental car owners', icon: 'pin',
      answer: `For a car you rent out, the ${f.name} shows the car live, keeps a trip history, shuts the starter off when a renter will not bring it back, and ties every 407 ETR toll and ticket to the renter who had the car. ${offer(f)}. ${availability(f)}.`,
      section: { h: 'What it settles on a rental', p: 'The four arguments every rental car owner has, each one answered by a record.',
        points: [{ icon: 'clock', title: 'Late returns', text: 'You see the car is still across town at the return time, before the next renter arrives.' },
          { icon: 'receipt', title: 'Tolls and tickets', text: 'The trip history shows who had the car at that minute. On cars rented through us, the toll or ticket is billed to that renter with the proof.' },
          { icon: 'route', title: 'Kilometres and where it went', text: 'Each trip with its route, times and distance, kept with the car.' },
          { icon: 'power', title: 'A car that does not come back', text: 'The starter interrupt and the live location bring it home without a chase.' }] },
      compare: { caption: 'Renting a car out with and without a tracker', head: ['', `With the ${f.name}`, 'Without a tracker'],
        rows: [['Where is the car right now?', 'On the map, live', 'You ask the renter'], ['A 407 toll arrives weeks later', 'Matched to the renter who had the car', 'You work it out from messages'], ['The renter is three hours late', 'You see where the car is', 'You wait'],
          ['The car is not returned', 'Starter off at the next stop, location known', 'A police report and a wait'], ['Handover without meeting', 'Doors locked and released from your phone', 'A key exchange']] },
      faq: [
        { question: 'Do rental cars have GPS trackers?', answer: `Most rental companies track their cars. The ${f.brand} rental agreement tells every renter the car is tracked by GPS and can be disabled remotely, and what the tracker records: location, speed, distance, ignition and tampering, never sound or video.` },
        { question: 'Who pays the 407 ETR toll on a rental car?', answer: 'The renter who drove it. The 407 bills the plate, so the bill reaches the owner first; the trip history shows who had the car at that minute, and the toll is billed on to that renter.' },
        { question: 'Do I have to tell renters the car is tracked?', answer: 'Yes. Say so in your rental agreement and your listing, and have the renter agree to it. Our rental agreement asks every renter to consent to GPS tracking and remote disabling for the whole rental.' },
        { question: 'How much is a GPS tracker for a rental car?', answer: `${PriceSentence(f)}. Everyone pays ${installSentence(f)}. Prices are before ${f.hst} HST.` }],
      lead: ['Live GPS', 'Tolls', 'Trip history']
    },
    {
      slug: 'anti-theft-tracker-toronto', title: `Anti-theft GPS tracker in ${f.city} with a kill switch | ${f.brand}`, h1: `Anti-theft GPS tracker in ${f.city}`, kicker: 'Anti-theft', icon: 'shield',
      answer: `An anti-theft tracker has two jobs: make the car hard to take and easy to find. The ${f.name} does both: a starter interrupt and an alarm you set off from your phone, and a live GPS location for you and the police. Installed in ${f.city} by ${f.brand}. ${offer(f)}. ${availability(f)}.`,
      section: { h: 'If the car goes missing', p: 'What you do, in order. Keep it calm and let the police do the recovering.',
        steps: [['Open the map', 'The live location shows where the car is, with a new reading every few minutes while it moves.'], ['Call the police', 'Give them the location and the plate. Do not go to the car yourself.'],
          ['Switch the starter off', 'Once the car is parked, the starter interrupt keeps it from being started again.'], ['Sound the alarm if it helps', 'The horn and lights draw attention to the car and help an officer find it in a lot.']] },
      compare: { caption: 'Anti-theft options for a car compared', head: ['', US(f), 'Bluetooth tag', 'Steering wheel lock', 'Factory alarm'],
        rows: [['Finds the car after it is taken', 'Yes, live GPS', 'Only near a phone on its network', 'No', 'No'], ['Keeps the car from being started', 'Yes', 'No', 'Slows a thief down', 'On some models'],
          ['Works from your phone', 'Yes', 'Location only', 'No', 'On some models'], ['Installed out of sight', 'Yes', 'Hidden by you', 'In plain sight', 'Built in'], ['Price', price(f), 'One purchase', 'One purchase', 'Comes with the car']] },
      faq: [
        { question: 'What is the best anti-theft device for a car?', answer: 'Layers. Something that slows a thief (a steering wheel lock), something that stops the car being started (a starter interrupt) and something that finds it (a GPS tracker). The tracker with a kill switch covers the last two in one install.' },
        { question: 'Will a GPS tracker stop my car being stolen?', answer: 'A tracker alone finds the car; it does not stop it leaving. That is why ours includes a starter interrupt and an alarm as well as the location.' },
        { question: 'Should I go and get the car myself?', answer: 'No. Share the live location with the police and let them recover it.' },
        { question: `Where is it installed in ${f.city}?`, answer: `${f.brand} installs it. Tell us where the car is when you join the waitlist and we agree the day and place with you.` }],
      lead: ['Kill switch', 'Alarm', 'Live GPS']
    },
    {
      slug: 'fleet-tracking', title: `Fleet GPS tracking in Ontario for small fleets | ${f.brand}`, h1: 'Fleet tracking for small fleets', kicker: 'Fleet tracking', icon: 'fleet',
      answer: `Fleet tracking from ${f.brand} shows every car live on one map with its trips, and each car has its own kill switch, door locking and alarm. ${PriceSentence(f)}. Everyone pays ${installSentence(f)}. ${availability(f)}.`,
      section: { h: 'Built for 3 to 50 cars', p: 'Big telematics suites are sold by the hundred seats. This is for the owner who knows every car by its plate.',
        points: [{ icon: 'pin', title: 'One map, every car', text: 'See the whole fleet at once, and open any car for its trips.' }, { icon: 'dollar', title: 'One price per tracker', text: `${offer(f)}. ${ownerSentence(f)}.` },
          { icon: 'receipt', title: 'Tolls and tickets to the driver', text: 'The trip history ties each one to whoever had the car at that minute.' }, { icon: 'power', title: 'Every car recoverable', text: 'A starter interrupt in each car, switched from your phone.' }] },
      compare: { caption: 'What a tracker costs, per car', head: ['Who', 'The tracker', 'Install, once per car'], rows: priceRows(f) },
      faq: [
        { question: 'How much does fleet tracking cost per vehicle?', answer: `${PriceSentence(f)}. The install is ${f.installCents ? `${money(f.installCents)} once per car` : 'quoted per car'}. Prices are before ${f.hst} HST.` },
        { question: `Do I have to install with ${f.brand}?`, answer: `A pre-ordered tracker is installed by ${f.brand}: ${installSentence(f)}. We fit it out of sight and check that it works before the car goes back out.` },
        { question: 'Is there a contract?', answer: 'Ask us when you join the waitlist: we confirm the terms and your price in writing before anything is billed.' },
        { question: 'Can my cars also be rented out through CarmaCars?', answer: 'Yes. Owners list cars with us and we handle the renters, the bookings and the payments; the tracker is how we and you see the car. See List your car.' }],
      lead: ['Live GPS', 'Trip history', 'Tolls']
    },
    {
      slug: 'turo-host-gps-tracker', title: `GPS tracker for Turo hosts in Ontario, with kill switch | ${f.brand}`, h1: 'GPS tracker for Turo hosts', kicker: 'For peer-to-peer hosts', icon: 'users',
      answer: `Hosts who rent their cars on Turo or any other platform use the ${f.name} to see each car live, lock and release the doors for a contactless handover, prove who had the car when a toll or ticket arrives, and switch the starter off when a guest will not return it. ${offer(f)}. ${availability(f)}. ${f.brand} is not affiliated with Turo.`,
      section: { h: 'A host\'s week, with a tracker', p: 'The moments it earns its keep.',
        points: [{ icon: 'lock', title: 'Contactless handover', text: 'Release the doors when the guest arrives and lock them again when the trip ends, from wherever you are.' },
          { icon: 'clock', title: 'The guest is late', text: 'You see where the car is and can tell the next guest the truth.' },
          { icon: 'receipt', title: 'A toll or ticket weeks later', text: 'The trip history shows which trip it belongs to, with the time and the route.' },
          { icon: 'power', title: 'A trip that does not end', text: 'The starter interrupt and the live location, and your platform\'s own process.' }] },
      compare: { caption: 'What a host can do with and without a tracker', head: ['', `With the ${f.name}`, 'With the platform app alone'],
        rows: [['See the car during a trip', 'Yes, live', 'What the platform shows'], ['Lock and release the doors remotely', 'Yes', 'On some cars with the maker\'s app'], ['Proof for a toll or ticket', 'Trip history with times and route', 'Trip dates'],
          ['Keep an unreturned car from being started', 'Yes, starter interrupt', 'No'], ['Price of the tracker', price(f), '']].map((r) => r.map((c) => c || 'Not part of it')) },
      faq: [
        { question: 'Are hosts allowed to track their cars?', answer: 'Check your platform\'s current policy and tell guests in your listing that the car has a tracker. Most platforms allow a disclosed tracker; the rules are theirs to set.' },
        { question: 'Is this a Turo product?', answer: `No. ${f.brand} is an Ontario car rental company and is not affiliated with or endorsed by Turo. Turo is named here only because hosts search for a tracker by that name.` },
        { question: 'What does it cost for 5 cars?', answer: `${PriceSentence(f)}. The install is ${f.installCents ? `${money(f.installCents)} once per car, ${money(f.installCents * 5)} for the five` : 'quoted per car'}. Prices are before ${f.hst} HST.` },
        { question: 'Can CarmaCars rent my cars out as well?', answer: 'Yes. With the owner program we find the renters, check them, take the payments and send you a monthly statement. See List your car.' }],
      lead: ['Remote lock', 'Tolls', 'Kill switch']
    },
    {
      slug: 'toll-and-ticket-billing', title: `407 ETR tolls and tickets on a rented car: who pays | ${f.brand}`, h1: 'Tolls and tickets, billed to the renter who had the car', kicker: 'Tolls and tickets', icon: 'receipt',
      answer: `The 407 ETR and the ticket cameras bill the plate, so the bill reaches the car's owner weeks after the trip. The ${f.name} keeps each trip with its times and route: on cars rented through ${f.brand}, every toll and ticket is matched to the renter who had the car at that minute and billed to that renter, with the proof.`,
      section: { h: 'From the bill to the right person', p: 'What happens when a toll or a ticket arrives.',
        steps: [['The bill arrives', 'A 407 ETR invoice or a ticket, in the owner\'s name, for a day weeks ago.'], ['It is matched', 'The date and time are checked against the bookings and the car\'s trips: one renter had the car at that minute.'],
          ['The renter is billed', 'The toll or ticket goes on that renter\'s account with the invoice as proof.'], ['The owner sees it on the statement', 'What was billed and what was collected, with the booking it belongs to.']] },
      compare: { caption: 'A toll on a rented car, with and without trip records', head: ['', 'With trip records', 'Without'],
        rows: [['Who had the car at 3:42 pm on the 14th?', 'One renter, by name', 'A guess from the calendar'], ['Proof to show the renter', 'The invoice and the trip', 'Your word'], ['Time it takes', 'Minutes', 'An evening of messages'], ['Who ends up paying', 'The renter who drove', 'Often the owner']] },
      faq: [
        { question: 'Who is responsible for a 407 toll on a rental car?', answer: 'The driver. The 407 ETR bills the plate holder, who passes the charge to the renter who had the car at that time, as the rental agreement says.' },
        { question: 'What about a red light or speed camera ticket?', answer: 'Camera tickets are sent to the plate holder too. The trip history shows who had the car, and the ticket is billed to that renter.' },
        { question: 'Does the renter know?', answer: 'Yes. Our rental agreement says tolls and tickets during the rental are the renter\'s, and the charge arrives with the invoice attached.' }],
      lead: ['Tolls', 'Trip history', 'Live GPS']
    }
  ];
}

/** The addresses of every tracker page except the install pages (the sitemap and the internal links read this). */
export const TRACKER_PATHS = ['/trackers', '/trackers/install', ...['kill-switch-for-car', 'starter-interrupt-device', 'gps-tracker-for-rental-car', 'anti-theft-tracker-toronto', 'fleet-tracking', 'turo-host-gps-tracker', 'toll-and-ticket-billing'].map((s) => `/trackers/${s}`)];

/** The icon of a feature, by its title. */
export function featureIcon(title: string): KitIcon {
  const t = title.toLowerCase();
  if (/kill|shut|starter/.test(t)) return 'power';
  if (/lock|door/.test(t)) return 'lock';
  if (/alarm|horn/.test(t)) return 'bell';
  if (/trip|history|route/.test(t)) return 'route';
  if (/toll|ticket/.test(t)) return 'receipt';
  if (/install/.test(t)) return 'wrench';
  if (/reading|every/.test(t)) return 'clock';
  return 'pin';
}

/** The questions of the product page. */
export function productFaq(f: TrackerFacts): Faq[] {
  return [
    { question: `How much is the ${f.name}?`, answer: `${PriceSentence(f)}. Everyone pays ${installSentence(f)}. Prices are before ${f.hst} HST.` },
    { question: 'Who gets the tracker free?', answer: `${ownerSentence(f)}: owners whose cars are listed with us pay only the install.${stage(f) === 'free' ? ` For everyone else, the tracker is free for the first ${f.prices.freeFirst} pre-orders, and a pre-ordered tracker is installed by ${f.brand}.` : ''}` },
    { question: 'Can I get one today?', answer: f.available ? `Yes. Order online and we agree the install day with you.` : `${f.launchNote}. Join the waitlist or pre-order and you hear first, in the order people joined. Nothing is charged until we confirm your install.` },
    { question: 'What is the difference between a GPS tracker and a kill switch?', answer: 'A GPS tracker shows where the car is. A kill switch (a starter interrupt) keeps a parked car from being started. This product is both, with remote door locking and an alarm.' },
    { question: 'Who can see where my car is?', answer: `You, and ${f.brand}. The location is not shared with anyone else unless you ask us to help recover the car.` },
    { question: 'Who installs it, and where?', answer: `${f.brand} installs it out of sight and checks that it works. We serve ${f.city} and the cities around it; tell us where the car is and we agree the day and place.` },
    { question: 'Does it work on any car?', answer: 'Tell us the year, make and model when you join the waitlist and we confirm it for your car before anything is billed.' },
    { question: 'Do tolls and tickets really go to the renter?', answer: `On cars rented through ${f.brand}, yes: each 407 ETR toll and ticket is matched to the renter who had the car at that minute and billed to them. On cars you rent out yourself, the trip history gives you the same proof.` }
  ];
}
