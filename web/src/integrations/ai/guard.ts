import type { GenerateRequest, GenerateResult, TextGenerator } from '../llm/types.ts';
import type { VisionModel, VisionRequest, VisionResult } from '../vision/types.ts';

// The usage guard (migration 0080) in front of every Workers AI call (0104), by feature since 0133. The audit of October 22
// found the guide rewrite still calling the model for hours after Workers AI was paused for the day; the car copy, the
// chat, the phone line, the Turo email reader, the toll and plate reader and the assistant all use the same two
// adapters, so each call goes through here. Since 0133 the day's free neurons are split in tiers (app.ai_budget): the
// staff assistant keeps 70% for itself, live features (chat, phone, readers) share what is not reserved, background work
// (search copy, listing copy, guide rewrites, Turo emails) gets a small share and what is left late in the evening. A
// call that does not fit its tier's room is not made and answers "quota", which every caller treats as "try later".
// Pure: the budget is read through the function passed in (web/src/integrations/ai/paused.ts reads it from the database).

/** Asked before a call: true when it must not run. With no argument (0104's form): is all of Workers AI stopped? */
export type PausedCheck = (ask?: { purpose: string; estimate: number }) => Promise<boolean>;

export const PAUSED_MESSAGE = 'Workers AI is paused for today: the included usage is used up (Admin > Settings > Usage). It resumes tomorrow.';
export const SHARE_MESSAGE = 'Workers AI waits: this feature\'s share of today\'s free allowance is used (the staff assistant keeps its reserve). It continues later or tomorrow.';

export type Tier = 'assistant' | 'live' | 'background';
/** The tier of a purpose, as app.ai_tier (migration 0133) has it. */
export function tierOf(purpose: string): Tier {
  if (purpose === 'staff_assistant') return 'assistant';
  if (['chat', 'phone_draft', 'phone_summary', 'toll_read', 'plate_detect', 'guide_review'].includes(purpose)) return 'live';
  return 'background';
}
/** The purpose each text task is recorded with in provider_calls. */
export const TASK_PURPOSE: Record<GenerateRequest['task'], string> = {
  listing_draft: 'draft_copy', guide_rewrite: 'guide_rewrite', chat: 'chat', car_copy: 'seo_car', seo_page: 'seo_page', article: 'seo_article',
  turo_email: 'turo_email', phone_draft: 'phone_draft', phone_summary: 'phone_summary'
};

/** About what a call costs before it is made: the prompt (4 characters a token) and half the output it may write, at
 *  Llama 3.3 70B's neurons per million tokens (the default model; a cheaper one only makes the estimate safer). */
export function estimateNeurons(promptChars: number, maxOutputTokens: number, perM = { input: 26668, output: 204805 }): number {
  return Math.ceil((Math.ceil(promptChars / 4) * perM.input + Math.ceil(maxOutputTokens / 2) * perM.output) / 1_000_000);
}

export function guardText(gen: TextGenerator, paused: PausedCheck, spent?: (purpose: string, neurons: number) => void): TextGenerator {
  return {
    name: gen.name,
    model: gen.model,
    async generate<T>(req: GenerateRequest): Promise<GenerateResult<T>> {
      const purpose = TASK_PURPOSE[req.task] ?? req.task;
      const estimate = estimateNeurons(req.system.length + req.prompt.length, req.maxOutputTokens);
      if (await paused({ purpose, estimate })) return { ok: false, reason: 'quota', message: (await paused()) ? PAUSED_MESSAGE : SHARE_MESSAGE };
      const r = await gen.generate<T>(req);
      if (r.usage?.neurons) spent?.(purpose, r.usage.neurons);
      return r;
    }
  };
}

export function guardVision(model: VisionModel, paused: PausedCheck, spent?: (purpose: string, neurons: number) => void): VisionModel {
  return {
    name: model.name,
    async read(req: VisionRequest, models: string[]): Promise<VisionResult> {
      // an image is about 1,600 input tokens on top of the prompt
      const estimate = estimateNeurons(req.system.length + req.prompt.length + 6400, req.maxOutputTokens, { input: 24545, output: 77273 });
      if (await paused({ purpose: req.purpose, estimate })) return { ok: false, reason: 'quota', message: (await paused()) ? PAUSED_MESSAGE : SHARE_MESSAGE, tried: [] };
      const r = await model.read(req, models);
      if (r.usage?.neurons) spent?.(req.purpose, r.usage.neurons);
      return r;
    }
  };
}

/** The guard's answer kept for a short time (one isolate runs many calls in a row: a guide run, a copy batch). */
export function cachedCheck(read: () => Promise<boolean>, ttlMs = 30_000, now: () => number = Date.now): () => Promise<boolean> {
  let at = -Infinity;
  let value = false;
  return async () => {
    if (now() - at < ttlMs) return value;
    value = await read();
    at = now();
    return value;
  };
}

/** The day's room per tier, as app.ai_budget returns it. */
export interface AiRoom { included: number; used: number; room: Record<Tier, number> }

/** The budget read once per ttl and kept up to date in between by what each call spent: a run of calls in one isolate
 *  (a search batch, a guide run) stops as soon as its tier's room is used, without asking the database every time. A
 *  budget that cannot be read does not stop the features (as the phone line, 0085). */
export function roomCheck(read: () => Promise<AiRoom | null>, ttlMs = 20_000, now: () => number = Date.now): { paused: PausedCheck; spent: (purpose: string, neurons: number) => void } {
  let at = -Infinity;
  let value: AiRoom | null = null;
  const fresh = async () => {
    if (now() - at >= ttlMs) { value = await read().catch(() => null); at = now(); }
    return value;
  };
  return {
    async paused(ask) {
      const b = await fresh();
      if (!b) return false;
      if (!ask) return b.used >= b.included;
      const room = b.room[tierOf(ask.purpose)] ?? 0;
      return room <= 0 || ask.estimate > room;
    },
    spent(purpose, neurons) {
      if (!value || !(neurons > 0)) return;
      const t = tierOf(purpose);
      value = { ...value, used: value.used + neurons, room: { ...value.room } };
      value.room.assistant = Math.max(0, value.room.assistant - neurons);
      if (t !== 'assistant') {
        value.room.live = Math.max(0, value.room.live - neurons);
        value.room.background = Math.max(0, value.room.background - neurons);
      }
    }
  };
}
