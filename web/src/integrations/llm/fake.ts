import type { GenerateResult, TextGenerator } from './types';

// For local work and tests: writes a plain draft from the facts in the prompt, so the whole pipeline
// runs without a model. It invents nothing: every sentence is built from the facts given.
interface Facts { year?: number; make?: string; model?: string; trim?: string; colour?: string; fuel?: string; body_style?: string; seats?: number; transmission?: string; drivetrain?: string; doors?: number; home_area?: string }

const words = (n: number, from: string[]) => { const out: string[] = []; let i = 0; while (out.length < n) out.push(...from[i++ % from.length]!.split(' ')); return out.slice(0, n).join(' '); };

// staff notes guide a person's review; the fake never copies them into public text
export function fakeDraft(f: Facts) {
  const name = [f.year, f.make, f.model].filter(Boolean).join(' ');
  const trim = f.trim ? ` ${f.trim}` : '';
  const headline = `${name}${trim} in ${(f.colour ?? 'a classic colour').toLowerCase()}, ready to book`.slice(0, 69).padEnd(41, '.');
  const sentences = [
    `This ${name}${trim} is a ${f.body_style ? f.body_style.toLowerCase() : 'car'} with ${f.seats ?? 5} seats.`,
    `It has ${f.transmission ? `an ${f.transmission.toLowerCase()} transmission` : 'a simple layout'} and runs on ${f.fuel ? f.fuel.replace(/_/g, ' ') : 'fuel'}.`,
    `You pick it up in ${f.home_area ?? 'Toronto'} or ask for delivery.`,
    'Every rental includes the agreement, the photos at handover and a clear statement at the end.',
    'Ask us anything before you book.'
  ];
  const description = `${words(70, sentences)}.\n\n${words(60, sentences.slice().reverse())}.`;
  const features = [`${f.seats ?? 5} seats`, f.transmission ? `${f.transmission} transmission` : 'Easy controls', f.fuel ? `${f.fuel.replace(/_/g, ' ')} engine` : 'Efficient engine',
    f.drivetrain ? `${f.drivetrain} drive` : 'Front seats', `${f.doors ?? 4} doors`, f.body_style ?? 'Comfortable cabin', 'Rear seats', 'Trunk space']
    .map((x) => x.charAt(0).toUpperCase() + x.slice(1));
  return {
    headline, description, features,
    faq: [
      { question: `How many people fit in the ${f.model ?? 'car'}?`, answer: `It has ${f.seats ?? 5} seats.`, check: false },
      { question: 'Which fuel does it take?', answer: f.fuel ? `It runs on ${f.fuel.replace(/_/g, ' ')}.` : 'Ask us before you book.', check: false },
      { question: 'Is it automatic?', answer: f.transmission ? `It has an ${f.transmission} transmission.` : 'Ask us before you book.', check: false },
      { question: 'Where do I pick it up?', answer: `In ${f.home_area ?? 'Toronto'}, or we deliver it.`, check: false }
    ],
    seo_title: `Rent a ${name} in ${f.home_area ?? 'Toronto'}`.slice(0, 60),
    seo_description: `Rent this ${name}${trim} in ${f.home_area ?? 'Toronto'} from CarmaCars. Request to book online.`.slice(0, 155),
    classes: [f.body_style?.toLowerCase().includes('suv') ? 'suv' : 'standard']
  };
}

/** The fake assistant's next step, read from the prompt the agent wrote: a quote when the visitor names a car and two
 *  dates, a search for two dates alone, a request when they give a name, email and phone, otherwise a plain answer.
 *  Its replies repeat the tool results' amounts word for word, as the real model is told to. */
export function fakeChatStep(prompt: string): Record<string, unknown> {
  const conv = prompt.split('CONVERSATION:')[1]?.split('TOOL RESULTS:')[0] ?? '';
  const tools = prompt.split('TOOL RESULTS:')[1] ?? '';
  const last = [...conv.matchAll(/^Visitor: (.*)$/gm)].pop()?.[1] ?? '';
  const slugs = [...prompt.matchAll(/^([a-z0-9-]+) \| ([^|]+) \|/gm)].map((m) => ({ slug: m[1]!, name: m[2]!.trim() }));
  const q = /quote ([a-z0-9-]+) (\d{4}-\d{2}-\d{2}) \S+ to (\d{4}-\d{2}-\d{2}) \S+: available, (\d+) days\..*?Total (\$[\d,.]+)\. Deposit (\$[\d,.]+)\./.exec(tools);
  if (q) {
    const name = slugs.find((x) => x.slug === q[1])?.name ?? q[1];
    return { action: 'reply', reply: `Good news: the ${name} is free from ${q[2]} to ${q[3]}. It is ${q[5]} in total with HST, Deposit ${q[6]}. Want me to start a booking request?` };
  }
  if (/NOT available/.test(tools)) return { action: 'reply', reply: 'That car is not free on those dates. Want me to check which cars are?' };
  const s = /search_cars (\S+) to (\S+): (.*)$/m.exec(tools);
  if (s) return { action: 'reply', reply: /no car is free/.test(s[3]!) ? 'No car is free on those dates. Try other dates?' : `These cars are free from ${s[1]} to ${s[2]}: ${s[3]!.split('; ').slice(0, 3).map((x) => x.split(' (')[0]).join(', ')}. Want a quote for one of them?` };
  if (/start_request: missing (\w+)/.test(tools)) return { action: 'reply', reply: `What is your ${/start_request: missing (\w+)/.exec(tools)![1]}?` };
  const dates = [...last.matchAll(/(\d{4}-\d{2}-\d{2})/g)].map((m) => m[1]);
  const email = /[\w.+-]+@[\w-]+\.[\w.]+/.exec(last)?.[0];
  const phone = /(\+?1?[\s-]?\(?\d{3}\)?[\s-]?\d{3}[\s-]?\d{4})/.exec(last)?.[1];
  const name = /(?:my name is|i am|i'm|this is)\s+([A-Z][a-z]+(?: [A-Z][a-z]+)+)/i.exec(last)?.[1];
  const known = /\(car ([a-z0-9-]+)\)/.exec(prompt)?.[1];
  const car = slugs.find((x) => last.toLowerCase().includes(x.slug.replace(/-/g, ' ')) || last.toLowerCase().includes(x.name.toLowerCase().replace(/^\d{4} /, '').split(' ').slice(0, 2).join(' ')))?.slug;
  if (email && phone && name) return { action: 'start_request', name, email, phone, car: car ?? known, pickup_date: dates[0], return_date: dates[1] };
  if (dates.length >= 2 && (car || known)) return { action: 'quote', car: car ?? known, pickup_date: dates[0], return_date: dates[1] };
  if (dates.length >= 2) return { action: 'search_cars', pickup_date: dates[0], return_date: dates[1] };
  return { action: 'reply', reply: 'I can check dates and prices for any of our cars. Tell me the car and your dates (for example 2026-11-02 to 2026-11-04), or ask how booking works.' };
}

/** A car page from the facts of the search job's prompt (features/seo/copy.ts), plain and true. */
export function fakeCarCopy(prompt: string): Record<string, unknown> {
  let f: Record<string, Record<string, unknown> | unknown[] | string> = {};
  try { f = JSON.parse(/<facts>([\s\S]*?)<\/facts>/.exec(prompt)?.[1] ?? '{}'); } catch { /* empty */ }
  const c = (f.car ?? {}) as Record<string, string | number | undefined>;
  const pr = (f.prices ?? {}) as Record<string, string | number | undefined>;
  const pl = (f.place ?? {}) as Record<string, string | undefined>;
  const ru = (f.rules ?? {}) as Record<string, string | number | boolean | undefined>;
  const inc = Array.isArray(f.included) ? (f.included as string[]) : [];
  const photos = Array.isArray(f.photos) ? (f.photos as string[]) : [];
  const name = [c.year, c.make, c.model].filter(Boolean).join(' ');
  const city = pl.city ?? 'Toronto';
  const area = pl.area ?? city;
  const colour = String(c.colour ?? '').toLowerCase();
  const body = String(c.body_style ?? 'car').toLowerCase();
  const h1 = `${name}${c.trim ? ' ' + c.trim : ''} rental in ${city}`.length <= 70 ? `${name}${c.trim ? ' ' + c.trim : ''} rental in ${city}` : `${name} rental in ${city}`;
  const title = `${name} Rental in ${city} | CarmaCars`.length <= 60 ? `${name} Rental in ${city} | CarmaCars` : `${name} Rental in ${city}`.slice(0, 60);
  const meta = `Rent the ${colour ? colour + ' ' : ''}${name} in ${area}${pr.daily ? ` from ${pr.daily} a day` : ''}. Collect it from us or have it delivered, and request with no payment up front.`;
  // a stand-in for a writer: the sentences vary with the car, so two cars never read the same
  // (the whole prompt counts, so a retry after "repeats another car" picks other sentences, as a writer would)
  const seed = [...`${name}|${colour}|${area}|${c.trim ?? ''}|${prompt}`].reduce((a, ch) => Math.imul(a ^ ch.charCodeAt(0), 2654435761) >>> 0, 2166136261);
  const pick = <T,>(xs: T[], k: number) => xs[Math.floor(seed / 5 ** k) % xs.length]!;
  const open = pick([`The ${name}${c.trim ? ' ' + c.trim : ''} on this page is a ${colour ? colour + ' ' : ''}${body}${c.seats ? ` that seats ${c.seats}` : ''}.`,
    `Meet our ${colour ? colour + ' ' : ''}${c.model}, a ${body}${c.seats ? ` with room for ${c.seats}` : ''} from ${c.year}.`,
    `This ${colour ? colour + ' ' : ''}${c.make} ${c.model} is a practical ${body}${c.seats ? ` for up to ${c.seats} people` : ''}.`,
    `Looking for a ${body} in ${city}? This ${c.year} ${c.make} ${c.model}${colour ? ' in ' + colour : ''} is ready to book.`,
    `Here is a ${c.year} ${c.model} from ${c.make}${colour ? ', finished in ' + colour : ''}${c.seats ? `, with ${c.seats} seats` : ''}.`], 0);
  const where = pick([`It lives in ${area}, close at hand for trips across ${city}, and it suits errands, commutes and weekends away alike.`,
    `We keep it in ${area}. From there it is an easy start for a work week, a family visit or a run out of ${city}.`,
    `Its home base is ${area}, which makes it handy for daily driving in ${city} as well as longer drives out of town.`,
    `You will find it in ${area}, and it is just as good for a quick errand as for a long weekend.`,
    `Based in ${area}, it covers school runs, airport trips and day trips without fuss.`], 1);
  const tr = c.transmission ? String(c.transmission).toLowerCase() : '', fu = c.fuel ? String(c.fuel).toLowerCase() : '', an = /^[aeiou]/.test(tr) ? 'an' : 'a';
  const drive = pick([`${tr ? `The gearbox is ${tr}` : 'It is simple to drive'}${fu ? ` and it runs on ${fu}` : ''}.`,
    `${tr ? `Driving it is easy with the ${tr} gearbox` : 'Driving it is easy'}${fu ? `, and it takes ${fu}` : ''}.`,
    `${fu ? `It runs on ${fu}` : 'It is easy to live with'}${tr ? ` and shifts with ${an} ${tr} gearbox` : ''}.`,
    `${tr ? `With ${an} ${tr} gearbox` : 'With simple controls'}, it feels at home in city traffic${fu ? ` and fills up with ${fu}` : ''}.`], 4);
  const how = pick([`Pick your dates and send a request. We check the car is free, confirm the price, and only then ask you to sign and pay. You can collect it from our location or have it brought to your address.`,
    `Send a request with your dates and we reply with the full price. Nothing is charged until you approve, sign and pay, and we can bring the car to your door.`,
    `Choose your dates below. Your request is free; we confirm the car and the total first, then you sign and pay online, and we meet you with the keys.`,
    `Booking takes a few minutes: tell us your dates, wait for our offer, then sign and pay when you are happy with it.`,
    `Requests cost nothing. Once we confirm the dates and the total, you sign the agreement and pay, and the keys are yours.`], 2);
  const close = pick(['We walk around the car with you at the handover and note its condition together.', 'At the handover we check the car together and write down anything we see.',
    'Before you drive off, we go over the car with you and agree on its condition.', 'You get a short walk-around at pickup so we both know the state of the car.',
    'We meet you in person, show you the car and record its condition with you.'], 3);
  void open; void where; void drive; void how; void close; void area;
  // car-copy-v2 (0073): a short blurb in the sample cars' voice, and six features from the offered equipment
  const intro = pick([`Easy to park downtown and quiet on the highway, with room for ${c.seats ?? 'five'} and a proper trunk.`,
    `A comfortable ${body} for the week: errands in the city, a long drive on Friday, and space for the bags.`,
    `Simple to drive, simple to park, and roomy enough for the airport run with luggage.`,
    `The everyday ${c.make} ${c.model}. Room for the family, and a trunk that takes the weekend.`,
    `A calm, easy ${body} that suits a commute as well as a road trip out of the city.`], 0);
  const eq = [...(Array.isArray(c.equipment_known) ? (c.equipment_known as unknown as string[]) : []), ...(Array.isArray(c.equipment) ? (c.equipment as unknown as string[]) : [])];
  const hl = [...new Set(eq)].slice(0, 6);
  return {
    seo_title: title, meta_description: meta.length <= 155 ? meta : `Rent the ${name} in ${city}. Collect it or have it delivered, and request with no payment up front.`, h1, intro,
    highlights: hl, good_for: [`Trips around ${city}`, body.includes('suv') || Number(c.seats ?? 0) > 5 ? 'Families and groups with bags' : 'Commutes and errands', 'Weekly and monthly rentals'],
    included: inc.slice(0, 5).length >= 3 ? inc.slice(0, 5) : [...inc, 'Third-party liability coverage', 'Roadside assistance, 24 hours a day'].slice(0, 3),
    pickup_delivery: `Collect it from our location at no charge, or we bring it to your address${pr.delivery_fee ? ` for ${pr.delivery_fee}` : ''}. We hand it over in person.`,
    requirements: [ru.min_age ? `Drivers ${ru.min_age} or older` : 'Drivers of the minimum age', String(ru.licence ?? 'A valid Ontario licence'), String(ru.card ?? 'A credit card in your name'), String(ru.identity ?? 'An identity check before pickup')],
    faq: [
      { question: `How many people fit in the ${c.model}?`, answer: c.seats ? `The ${c.model} has ${c.seats} seats.` : 'Ask us before you book and we will tell you.' },
      { question: `Can you deliver the ${c.model}?`, answer: `Yes. We bring it to your address${pr.delivery_fee ? ` for ${pr.delivery_fee}` : ''}, or you collect it from our location at no charge.` },
      { question: 'How many kilometres are included?', answer: pr.km_per_day ? `${pr.km_per_day} km for each day of the rental, added together over the trip.` : 'The allowance is shown with the rates on this page.' },
      { question: 'Do I pay when I send a request?', answer: 'No. We confirm the car and the price first, and you pay only when you approve the offer.' }
    ],
    alt_texts: Object.fromEntries(photos.map((k) => [k, `${name}${colour ? ' in ' + colour : ''}, ${k.replace(/_/g, ' ')} view`]))
  };
}
export function fakePageCopy(prompt: string): Record<string, unknown> {
  let p: { name?: string; kind?: string; city?: string } = {};
  try { p = JSON.parse(/<page>([\s\S]*?)<\/page>/.exec(prompt)?.[1] ?? '{}'); } catch { /* empty */ }
  const cur = /The current text, for reference \(rewrite it, keep the facts\): (\{[\s\S]*\})\s*$/m.exec(prompt)?.[1];
  if (cur) { try { return JSON.parse(cur) as Record<string, unknown>; } catch { /* fall through */ } }
  const n = p.name ?? 'Toronto';
  const para = (h: string) => `${h} We hand every car over in person, with a walk-around and a check of your licence and card. Send a request with your dates and the address, and we confirm the car and the price before you pay. You can also collect the car from our location if that is easier for you.`;
  return { seo_title: `Car Rental in ${n} | CarmaCars`, meta_description: `Rent a car in ${n} with CarmaCars. Delivery to your address or pickup from us, and a request with no payment up front.`,
    h1: `Car rental in ${n}`, intro: para(`CarmaCars rents cars to people in ${n}.`), sections: [{ heading: `Delivery in ${n}`, body: para('We deliver to homes, offices and hotels.') }, { heading: 'How it works', body: para('Pick a car on this page.') }],
    faq: [{ question: `Do you deliver in ${n}?`, answer: 'Yes, to any address.' }, { question: 'Do I pay to send a request?', answer: 'No. You pay after we confirm.' }, { question: 'Who can rent?', answer: 'Drivers with a valid licence and a credit card.' }] };
}
export function fakeArticle(prompt: string): Record<string, unknown> {
  try { return JSON.parse(/<current>([\s\S]*?)<\/current>/.exec(prompt)?.[1] ?? '{}') as Record<string, unknown>; } catch { return {}; }
}

export function fakeText(): TextGenerator {
  return {
    name: 'fake',
    model: 'fake-draft-v1',
    async generate<T>(req: { prompt: string; task?: string }): Promise<GenerateResult<T>> {
      // a guide section to rewrite (0055): each missing button renamed to its closest label, nothing invented
      if (req.task === 'guide_rewrite') {
        if (process.env.FAKE_LLM_FAIL === '1') return { ok: false, reason: 'unavailable', message: 'The fake model is set to fail' };
        // imported only here: the unit tests load this file without the app's path aliases
        const { fakeRewrite } = await import('../../features/guides/upkeep');
        return { ok: true, data: fakeRewrite(req.prompt) as T, model: 'fake-draft-v1', usage: { inputTokens: req.prompt.length / 4, outputTokens: 400, neurons: 0 } };
      }
      // the live chat assistant (0060): a deterministic stand-in that follows the same protocol (agent.ts)
      if (req.task === 'chat') {
        if (process.env.FAKE_LLM_FAIL === '1') return { ok: false, reason: 'unavailable', message: 'The fake model is set to fail' };
        return { ok: true, data: fakeChatStep(req.prompt) as T, model: 'fake-chat-v1', usage: { inputTokens: Math.round(req.prompt.length / 4), outputTokens: 60, neurons: 0 } };
      }
      // the search copy (0061): built from the facts in the prompt, so it passes the same checks as a real answer
      if (req.task === 'car_copy' || req.task === 'seo_page' || req.task === 'article') {
        if (process.env.FAKE_LLM_FAIL === '1') return { ok: false, reason: 'unavailable', message: 'The fake model is set to fail' };
        const data = req.task === 'car_copy' ? fakeCarCopy(req.prompt) : req.task === 'seo_page' ? fakePageCopy(req.prompt) : fakeArticle(req.prompt);
        return { ok: true, data: data as T, model: 'fake-seo-v1', usage: { inputTokens: Math.round(req.prompt.length / 4), outputTokens: 700, neurons: 0 } };
      }
      const m = /<facts>([\s\S]*?)<\/facts>/.exec(req.prompt);
      let facts: Facts = {};
      try { facts = JSON.parse(m?.[1] ?? '{}') as Facts; } catch { /* empty facts */ }
      if (process.env.FAKE_LLM_FAIL === '1') return { ok: false, reason: 'unavailable', message: 'The fake model is set to fail' };
      return { ok: true, data: fakeDraft(facts) as T, model: 'fake-draft-v1', usage: { inputTokens: req.prompt.length / 4, outputTokens: 600, neurons: 0 } };
    }
  };
}
