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
      const m = /<facts>([\s\S]*?)<\/facts>/.exec(req.prompt);
      let facts: Facts = {};
      try { facts = JSON.parse(m?.[1] ?? '{}') as Facts; } catch { /* empty facts */ }
      if (process.env.FAKE_LLM_FAIL === '1') return { ok: false, reason: 'unavailable', message: 'The fake model is set to fail' };
      return { ok: true, data: fakeDraft(facts) as T, model: 'fake-draft-v1', usage: { inputTokens: req.prompt.length / 4, outputTokens: 600, neurons: 0 } };
    }
  };
}
