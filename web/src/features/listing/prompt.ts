// The listing copy draft (docs/blueprint/09-listing-pipeline.md section 5.3): the prompt, the JSON schema
// the model must follow, and the checks every draft passes before it is stored. The database checks the
// copy again (app.listing_copy_problems) and a person approves it before anything is published.
// Pure functions: no server imports, so the unit tests run them directly.
export const PROMPT_VERSION = 'listing-draft-v1';

export interface CopyRules {
  headline_chars: [number, number];
  description_words: [number, number];
  features: [number, number];
  faq: [number, number];
  banned_phrases: string[];
}
export const DEFAULT_RULES: CopyRules = { headline_chars: [40, 70], description_words: [120, 220], features: [6, 14], faq: [3, 8], banned_phrases: [] };

export interface Draft {
  headline: string;
  description: string;
  features: string[];
  faq: { question: string; answer: string; check?: boolean }[];
  seo_title: string;
  seo_description: string;
  classes: string[];
}

export const DRAFT_SCHEMA = {
  type: 'object',
  properties: {
    headline: { type: 'string', description: 'Year, make, model and one true differentiator' },
    description: { type: 'string', description: 'Two or three short paragraphs separated by a blank line' },
    features: { type: 'array', items: { type: 'string' } },
    faq: { type: 'array', items: { type: 'object', properties: { question: { type: 'string' }, answer: { type: 'string' }, check: { type: 'boolean' } }, required: ['question', 'answer', 'check'] } },
    seo_title: { type: 'string' },
    seo_description: { type: 'string' },
    classes: { type: 'array', items: { type: 'string' } }
  },
  required: ['headline', 'description', 'features', 'faq', 'seo_title', 'seo_description', 'classes']
} as const;

const DASHES = /[‒–—―−]/;
// Claims the facts must support before the copy may make them.
const CLAIMS: Array<{ re: RegExp; needs: RegExp; label: string }> = [
  { re: /\b(mpg|l\/100 ?km|fuel economy|fuel efficien\w*|miles per gallon)\b/i, needs: /economy|l\/100|mpg/i, label: 'fuel economy' },
  { re: /\b(safety rating|five-star|5-star|iihs|nhtsa|top safety pick)\b/i, needs: /safety_rating/i, label: 'a safety rating' },
  { re: /\b(\d{2,4} ?km (of )?range|range of \d+)\b/i, needs: /range/i, label: 'an electric range' },
  { re: /\b(\d{2,4} ?(hp|horsepower))\b/i, needs: /hp|horsepower/i, label: 'horsepower' }
];
const COMPANY = /18122211|canada inc|numbered company/i;

const wordCount = (s: string) => (s.trim() ? s.trim().split(/\s+/).length : 0);
const within = (n: number, [lo, hi]: [number, number]) => n >= lo && n < hi;

export function systemPrompt(): string {
  return [
    'You write car rental listings for CarmaCars, a car rental company in Ontario, Canada.',
    'Write in plain Canadian English: short sentences, everyday words, no filler, no superlatives, no exclamation marks.',
    'Never use an em dash or an en dash. Use commas, colons or full stops instead.',
    'Call the company CarmaCars only. Never write a numbered company name or a legal company name.',
    'Use only the facts given and the staff notes. Do not invent features, options, fuel economy, range, horsepower, safety ratings, awards, prices or history.',
    'If a detail is not in the facts, leave it out. If an FAQ answer depends on something not in the facts, give the safest general answer and set "check" to true.',
    'Never mention the VIN, the plate, the owner, the odometer reading or damage.',
    'Answer with one JSON object that follows the schema exactly, and nothing else.'
  ].join('\n');
}

export function userPrompt(facts: Record<string, unknown>, notes: string | null, classes: string[], rules: CopyRules = DEFAULT_RULES, problems: string[] = []): string {
  const r = rules;
  return [
    `<facts>${JSON.stringify(facts)}</facts>`,
    `<staff_notes>${notes?.trim() || 'none'}</staff_notes>`,
    `<classes>${classes.join(', ')}</classes>`,
    'Write:',
    `- headline: ${r.headline_chars[0]} to ${r.headline_chars[1] - 1} characters; the year, make and model and one true differentiator from the facts.`,
    `- description: ${r.description_words[0] + 10} to ${r.description_words[1] - 20} words in two or three short paragraphs separated by a blank line: what the car is like to drive and live with, who it suits, and that pickup or delivery is arranged when booking. Facts only.`,
    `- features: ${Math.max(r.features[0], 8)} to ${Math.min(r.features[1] - 1, 12)} items of 2 to 5 words each, only what the facts or staff notes support.`,
    `- faq: exactly 4 questions and answers specific to this model (luggage, child seats, winter driving, charging for an electric car), "check": true where you are not sure.`,
    '- seo_title: at most 60 characters, like "Rent a 2022 Toyota Corolla in Toronto".',
    '- seo_description: at most 155 characters, one sentence.',
    '- classes: one to three codes from the classes list that fit this car.',
    r.banned_phrases.length ? `Never use these phrases: ${r.banned_phrases.map((p) => `"${p}"`).join(', ')}.` : '',
    'Example of the house style (another car): headline "2021 Honda Civic EX sedan with a sunroof and heated seats"; feature "Heated front seats"; ' +
      'a description sentence "It is easy to park and light on fuel, so it suits city trips and weekend drives."',
    problems.length ? `Your last answer had these problems; fix every one: ${problems.join('; ')}.` : ''
  ].filter(Boolean).join('\n');
}

/** Cleans a model answer into a Draft (or null when it is not one). */
export function normalizeDraft(x: unknown): Draft | null {
  if (!x || typeof x !== 'object') return null;
  const o = x as Record<string, unknown>;
  const s = (v: unknown) => (typeof v === 'string' ? v.replace(/\s+\n/g, '\n').replace(/[ \t]+/g, ' ').trim() : '');
  const faq = Array.isArray(o.faq) ? o.faq.flatMap((q) => {
    const e = (q ?? {}) as Record<string, unknown>;
    return s(e.question) && s(e.answer) ? [{ question: s(e.question), answer: s(e.answer), check: e.check === true }] : [];
  }) : [];
  const d: Draft = {
    headline: s(o.headline), description: typeof o.description === 'string' ? o.description.trim().replace(/\n{3,}/g, '\n\n') : '',
    features: Array.isArray(o.features) ? o.features.map(s).filter(Boolean) : [],
    faq, seo_title: s(o.seo_title), seo_description: s(o.seo_description),
    classes: Array.isArray(o.classes) ? o.classes.map((c) => s(c).toLowerCase()).filter(Boolean).slice(0, 3) : []
  };
  return d.headline || d.description ? d : null;
}

/** What is wrong with a draft, in words the model (or a reviewer) can act on. */
export function draftProblems(d: Draft, facts: Record<string, unknown>, rules: CopyRules = DEFAULT_RULES): string[] {
  const p: string[] = [];
  if (!within(d.headline.length, rules.headline_chars)) p.push(`the headline must be ${rules.headline_chars[0]} to ${rules.headline_chars[1] - 1} characters (it is ${d.headline.length})`);
  const w = wordCount(d.description);
  if (!within(w, rules.description_words)) p.push(`the description must be ${rules.description_words[0]} to ${rules.description_words[1] - 1} words (it is ${w})`);
  if (!within(d.features.length, rules.features)) p.push(`give ${rules.features[0]} to ${rules.features[1] - 1} features (there are ${d.features.length})`);
  if (!within(d.faq.length, rules.faq)) p.push(`give ${rules.faq[0]} to ${rules.faq[1] - 1} questions (there are ${d.faq.length})`);
  if (d.seo_title.length > 60 || !d.seo_title) p.push('the seo_title must be 1 to 60 characters');
  if (d.seo_description.length > 155 || !d.seo_description) p.push('the seo_description must be 1 to 155 characters');
  const all = [d.headline, d.description, ...d.features, ...d.faq.flatMap((q) => [q.question, q.answer]), d.seo_title, d.seo_description].join('\n');
  if (DASHES.test(all)) p.push('remove every em dash and en dash');
  if (COMPANY.test(all)) p.push('never name a numbered or legal company: say CarmaCars');
  for (const b of rules.banned_phrases) if (b && all.toLowerCase().includes(b.toLowerCase())) p.push(`remove the phrase "${b}"`);
  const factText = JSON.stringify(facts).toLowerCase();
  for (const c of CLAIMS) if (c.re.test(all) && !c.needs.test(factText)) p.push(`do not claim ${c.label}: it is not in the facts`);
  const vin = typeof facts.vin === 'string' ? facts.vin : null;
  if (vin && all.includes(vin)) p.push('never include the VIN');
  return p;
}
