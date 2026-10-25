// Owner recruitment under Canada's anti-spam law, CASL (migration 0167). Owners and co-hosts are found in classified ads;
// a live phone call is not covered by the law, an email or a text is: it needs consent (express, or implied in the cases
// the law names), it identifies the sender and it offers an unsubscribe. The database decides whether a message may go
// (app.recruit_consent_state) and adds the identification and the unsubscribe; this file holds the words: the templates,
// the kinds of consent and how long each lasts. Pure (no I/O).
import { withUtm } from './channels.ts';

export type Basis = 'express' | 'implied_inquiry' | 'implied_business' | 'implied_published' | 'referral' | 'withdrawn' | 'do_not_contact';
export interface ConsentState { allowed: boolean; basis?: Basis; consent_id?: string; expires_on?: string | null; reason?: string; referrer_name?: string | null }

export const BASIS: Array<[Basis, string, string]> = [
  ['express', 'Express consent', 'They said yes to emails or texts about the owner program: on a call, in a form or in a reply. No end date until they withdraw it. Keep the proof: their words and the time, or the recording or message.'],
  ['implied_inquiry', 'Implied: they asked us', 'They asked about the owner program (a form, an email, a message). Lasts 6 months from the inquiry.'],
  ['implied_business', 'Implied: business relationship', 'They bought from or signed with CarmaCars (a rental, a contract). Lasts 2 years from it.'],
  ['implied_published', 'Implied: published business address', 'A dealer or rental business published the address with no "no solicitation" note, and the message is about their business. Never a private seller.'],
  ['referral', 'Referral (one message)', 'Someone who knows them and us gave us the address. One message, naming the referrer.'],
  ['withdrawn', 'Withdrawn', 'They asked to stop emails or texts. The unsubscribe link and a STOP reply add this by themselves.'],
  ['do_not_contact', 'Do not contact', 'Never contact them again, by any means.']
];
export const basisWords = (b: string | null | undefined) => BASIS.find((x) => x[0] === b)?.[1] ?? (b ?? '');

export const CONTACT_KINDS: Array<[string, string]> = [['private_seller', 'Private seller'], ['dealer', 'Dealer'], ['rental_business', 'Rental business'], ['other_business', 'Other business']];
export const LISTING_SITES: Array<[string, string]> = [['kijiji', 'Kijiji'], ['fb_marketplace', 'Facebook Marketplace'], ['autotrader', 'AutoTrader'], ['craigslist', 'Craigslist'], ['turo', 'Turo'], ['other', 'Other']];
export const CALL_OUTCOMES: Array<[string, string]> = [['yes_text', 'Yes: text me the details'], ['yes_email', 'Yes: email me the details'], ['yes_both', 'Yes: email or text'],
  ['call_back', 'Call back later'], ['no_answer', 'No answer'], ['no', 'No: do not contact me']];
export const LEAD_STATUS: Record<string, string> = { new: 'New', contacted: 'Contacted', qualified: 'Interested', converted: 'Signed up', closed: 'Closed', spam: 'Spam' };

export interface TemplateVars { first_name: string; vehicle: string; sender: string; phone: string; link: string; referrer: string }
export interface Template { key: string; channel: 'email' | 'text'; label: string; when: string; subject?: string; body: string }

// The call script (the spec's section 5): what to say before any message goes.
export const CALL_SCRIPT = [
  'Hi, this is [your name] from CarmaCars, a Toronto car rental company. I\'m calling about the [car] you advertised. Is now a good time?',
  'We run an owner program: your car goes on our fleet insurance policy, we rent it out and pay you monthly. Fees apply. May I text or email you the details?',
  'Yes: log the call with their words ("Yes, text me the details"). No: log "No" and they are never contacted again.'
];

export const TEMPLATES: Template[] = [
  { key: 'after_call', channel: 'email', label: 'After a call (they said yes)', when: 'Express consent from the call',
    subject: 'Your {vehicle} and the CarmaCars owner program',
    body: 'As agreed on our call, here are the details of the CarmaCars owner program. Your car goes on our fleet insurance policy, we rent it out in Toronto and we pay you every month. Fees apply; the page below explains them.\n\n{link}\n\nReply to this email or call {phone} with any question.\n\n{sender}, CarmaCars' },
  { key: 'reply_inquiry', channel: 'email', label: 'Reply to their inquiry', when: 'They asked us (implied, 6 months) or said yes',
    subject: 'The CarmaCars owner program',
    body: 'Thank you for asking about the CarmaCars owner program. In short: your car goes on our fleet insurance policy, we rent it out in Toronto and pay you every month. Fees apply. Everything is on this page:\n\n{link}\n\nReply to this email or call {phone} with any question.\n\n{sender}, CarmaCars' },
  { key: 'dealer_intro', channel: 'email', label: 'A dealer or rental business', when: 'Their business address was published with no "no solicitation" note',
    subject: 'Cars between sales, earning with CarmaCars',
    body: 'CarmaCars rents cars in Toronto for their owners. If {business} has cars that wait between sales, our owner program may put them to work: they go on our fleet insurance policy, we rent them out and pay you every month. Fees apply. How it works:\n\n{link}\n\nReply if you would like to talk, or call {phone}.\n\n{sender}, CarmaCars' },
  { key: 'referral_intro', channel: 'email', label: 'After a referral (one message)', when: 'A referral, naming the referrer',
    subject: '{referrer} suggested we write to you',
    body: '{referrer} suggested we write to you about the CarmaCars owner program. Your car goes on our fleet insurance policy, we rent it out in Toronto and pay you every month. Fees apply. How it works:\n\n{link}\n\nThis is our only message unless you reply.\n\n{sender}, CarmaCars' },
  { key: 'text_after_call', channel: 'text', label: 'Text after a call (they said yes)', when: 'Express consent for texts',
    body: '{first_name}, as agreed on our call, here is the CarmaCars owner program: {link} Questions: {phone}.' },
  { key: 'text_reply', channel: 'text', label: 'Text reply to their inquiry', when: 'They asked us, or said yes',
    body: 'Hi {first_name}, thanks for asking about the CarmaCars owner program. The details: {link} Questions: {phone}.' }
];

/** The owner program page, tracked as recruitment by email or text. */
export const recruitLink = (site: string, channel: 'email' | 'text') => withUtm(`${site.replace(/\/$/, '')}/list-your-car`, 'recruit', channel, 'owner_recruit');

/** A template filled for one lead (a missing value leaves a plain word, never a placeholder). */
export function fillTemplate(t: Template, v: Partial<TemplateVars> & { business?: string }): { subject: string; body: string } {
  const vals: Record<string, string> = { first_name: v.first_name || 'there', vehicle: v.vehicle || 'car', sender: v.sender || 'The CarmaCars team', phone: v.phone || 'the number on carmacars.ca',
    link: v.link || 'https://carmacars.ca/list-your-car', referrer: v.referrer || 'Someone you know', business: v.business || 'your business' };
  const fill = (s: string) => s.replace(/\{(\w+)\}/g, (_m, k: string) => vals[k] ?? '');
  return { subject: t.subject ? fill(t.subject) : '', body: fill(t.body) };
}

/** What the text will look like once the database adds the opt-out line (the anti-spam law's unsubscribe for a text). */
export const withStop = (body: string) => (/reply stop/i.test(body) ? body : `${body} Reply STOP to opt out.`);
