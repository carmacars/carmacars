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
      const m = /<facts>([\s\S]*?)<\/facts>/.exec(req.prompt);
      let facts: Facts = {};
      try { facts = JSON.parse(m?.[1] ?? '{}') as Facts; } catch { /* empty facts */ }
      if (process.env.FAKE_LLM_FAIL === '1') return { ok: false, reason: 'unavailable', message: 'The fake model is set to fail' };
      return { ok: true, data: fakeDraft(facts) as T, model: 'fake-draft-v1', usage: { inputTokens: req.prompt.length / 4, outputTokens: 600, neurons: 0 } };
    }
  };
}
