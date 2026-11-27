// r50 hotfix 2: the white-label rental software page (/rental-software). The owner: "very descriptive about every portal
// and feature, vague about how it is built, no pricing". Pure words, relative imports only (content.test.ts checks that
// no price and no part of the technology is named). The page is indexable and in the pages sitemap and llms.txt, and no
// menu links it.
import type { KitIcon } from '../seo/kit/icons.tsx';

export const SOFTWARE = {
  title: 'Car Rental Software, White-Label, for Rental Companies',
  description: 'White-label car rental software: renter, owner, staff and Admin portals, insurance billing, tolls, AI chat and calls, a staff academy and an SEO engine.',
  h1: 'Car rental software, under your brand',
  lead: 'The platform we run our own rental company on, white-labelled for yours: online booking, renter and owner portals, a portal for every staff role, insurance billing, tolls, AI on chat and calls, a staff academy and an SEO engine that brings renters in.',
  answer: 'A complete car rental management platform for independent rental companies, peer-to-peer hosts with a fleet, dealerships with a rental arm and insurance replacement providers. It covers booking, payments and deposits, agreements, checks of the driver, the fleet, the owners who supply cars, every staff role, insurance-billed rentals, tolls and tickets, calls and chat, hiring and training, and search. Your brand, your domain, your rules.'
} as const;

export interface Portal { id: string; icon: KitIcon; name: string; who: string; points: string[] }
export const PORTALS: Portal[] = [
  { id: 'renter', icon: 'users', name: 'Renter portal and booking site', who: 'For the people who rent your cars', points: [
    'A booking site with every car on its own page: photos, the calendar, the price for the dates, the fees and the deposit shown before anyone pays.',
    'Request to book or instant booking, offers your team sends, and changes the renter asks for (dates, car, extras) approved by your team.',
    'Driver checks: licence upload with expiry and class, identity, age and young driver rules, and coverage proof (their own policy, their card\'s or yours).',
    'Signed rental agreements on the phone, the pay page, the deposit hold and its release, receipts and invoices.',
    'Pickup and return photos, damage and fee evidence, tolls and tickets charged with the proof attached.',
    'Rewards, gift cards, referral credit and discount codes, and the trip history in one account.',
    'Native iPhone and Android apps with push alerts, alongside the website.'] },
  { id: 'owner', icon: 'key', name: 'Owner portal', who: 'For the people who supply cars to your fleet', points: [
    'Owners apply with their car, sign the owner agreement online and upload the ownership, insurance and safety documents.',
    'Each car\'s bookings, calendar, earnings and expenses, live, with the car\'s location where a tracker is fitted.',
    'Monthly statements with the revenue share, the fees and the deductions, invoices and payouts, all on the record.',
    'Owner terms per car or per owner, fleet supplier contracts and lease terms for corporate owners.'] },
  { id: 'staff', icon: 'fleet', name: 'A portal for every staff role', who: 'Sales, customer service, operations, finance and field staff', points: [
    'Sales: leads from every form, chat and call in one list, claimed and followed up, offers sent in a few taps, commissions tracked.',
    'Customer service: the inbox of chats, texts, calls and emails per renter and per booking, with the full history.',
    'Operations and fleet: the live map, the day\'s pickups and returns, field jobs, cleaning and maintenance, licence and coverage reviews.',
    'Finance: payments, refunds prepared for approval, deposits, owner statements, invoices to insurers, expenses and payroll figures.',
    'Field staff: the day\'s handovers with the checklist, guided photos, the car\'s keys and fuel, and expenses with receipts.',
    'Each role sees what it needs and nothing else, and every action is logged.'] },
  { id: 'admin', icon: 'shield', name: 'Admin', who: 'For the owners of the business', points: [
    'Every price, fee, deposit tier, coverage option, policy and message is a setting, changed without a developer.',
    'Today: what needs a decision now, the money waiting, the cars on rent, the risks.',
    'Reports on bookings, utilisation, revenue, owners, leads and sources, staff and search.',
    'Staff access per person and function, the audit log of every change, and an investor portal with statements and updates.',
    'Self-healing: the platform watches its own health and fixes the known problems by itself, and says what it fixed.'] }
];

export interface Feature { id: string; icon: KitIcon; title: string; text: string; points: string[] }
export const FEATURES: Feature[] = [
  { id: 'insurance', icon: 'card', title: 'Insurance replacement billing', text: 'Rent to drivers whose car is in the shop and bill their insurer directly.', points: [
    'The claim number, the adjuster and the approved days on the booking.', 'Invoices to the insurance company at the daily rate it approved, and the balance to the renter when the approved days run out.',
    'Body shop and tow truck referral partners, with their commissions.'] },
  { id: 'tolls', icon: 'route', title: 'Tolls and tickets', text: 'Toll charges and tickets matched to the booking that had the car.', points: [
    'Toll statements read and each charge matched to the renter by the car and the time.', 'The renter charged with the proof attached, with the admin fee your policy sets.',
    'Parking and traffic tickets transferred or charged the same way.'] },
  { id: 'ai', icon: 'sparkle', title: 'AI that does the work', text: 'AI on the website chat, in the staff tools and behind the scenes.', points: [
    'Website chat that answers renters from your own policies and cars, and hands over to a person.', 'A staff assistant that finds bookings, drafts replies and explains a charge.',
    'Car photos made uniform: every car shown in the same angles on the same background.', 'Recorded AI interviews that screen job applicants and score them against the role.',
    'Page copy written and rewritten from what people search.'] },
  { id: 'calls', icon: 'phone', title: 'Calls and texts', text: 'A business phone line built in, for every staff member.', points: [
    'Calls ring the right people, with the renter and their booking on screen.', 'Recordings, transcripts and summaries on the renter\'s history.',
    'Texts and reminders by SMS, and missed calls followed up.'] },
  { id: 'academy', icon: 'star', title: 'Staff academy', text: 'Training for every role, with tests, before a new hire works alone.', points: [
    'Courses per role with short lessons, quizzes and a pass mark.', 'New hires onboarded in one step: the agreement, the pay details, the academy and the first tasks.',
    'Hiring built in: job posts, scored applications, AI interviews and interview calls.'] },
  { id: 'seo', icon: 'pin', title: 'The SEO engine', text: 'Pages that bring renters in from search and from AI answers.', points: [
    'A page for every place you serve and every way people search for a rental, written from real data.', 'Every car, make and model with its own page, in every language you turn on.',
    'Search Console read every day: pages that rank close to the top are rewritten, new pages are sent to the search engines.', 'Structured data and an answer file so AI assistants describe your business correctly.'] },
  { id: 'fleet', icon: 'lock', title: 'Trackers and kill switch', text: 'Live GPS, remote locking and a kill switch on the cars that need it.', points: [
    'The live map of the fleet and each car\'s trip history.', 'Remote immobilisation when a car is overdue or stolen, with the steps logged.'] },
  { id: 'money', icon: 'dollar', title: 'Payments and deposits', text: 'Cards, e-Transfer and pay links, with the deposit held and released on rules.', points: [
    'Pay links and saved cards, deposits held and released after the return checks.', 'Every refund or payout prepared for a person to approve: money never moves by itself.'] }
];

export const FAQ: Array<{ question: string; answer: string }> = [
  { question: 'Who is this car rental software for?', answer: 'Independent car rental companies, peer-to-peer hosts who run a fleet, dealerships with a rental arm, insurance replacement providers and chauffeur companies that want one platform for booking, fleet, owners, staff and marketing.' },
  { question: 'Can it carry our own brand?', answer: 'Yes. It runs under your name, logo, colours and domain, with your policies, prices and emails. Renters never see ours.' },
  { question: 'How much does it cost?', answer: 'Pricing depends on your fleet size and the parts you use. Send the form on this page and we reply with pricing for your fleet and a time for a walkthrough.' },
  { question: 'Does it handle insurance replacement rentals?', answer: 'Yes. Bookings carry the claim, the adjuster and the approved days, and the insurer is invoiced directly, with the balance to the renter after the approved days.' },
  { question: 'Can owners list their cars with us through it?', answer: 'Yes. Owners apply, sign and upload their documents online, then see their bookings, statements and payouts in the owner portal.' },
  { question: 'Is there a mobile app?', answer: 'Yes. Renters and staff get native iPhone and Android apps with push alerts, alongside the website.' },
  { question: 'How long does it take to start?', answer: 'We set up your brand, your cars, your prices and your policies with you, train your team in the academy and agree the start date with you.' }
];

/** The llms.txt lines of the software page. */
export const llmsLines = (base: string) => ['## Car rental software for rental companies', '',
  `${SOFTWARE.answer} Pricing on request: ${base}/rental-software#pricing`, '', `- Page: ${base}/rental-software`, ''];
