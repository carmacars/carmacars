import type { GenerateRequest, GenerateResult, TextGenerator } from '../llm/types.ts';
import type { VisionModel, VisionRequest, VisionResult } from '../vision/types.ts';

// The usage guard (migration 0080) in front of every Workers AI call (0104). The audit of October 22 found the guide
// rewrite still calling the model for hours after Workers AI was paused for the day; the car copy, the chat, the phone
// line, the Turo email reader, the toll and plate reader and the assistant all use the same two adapters, so each call
// goes through here: while the service is paused (its included allowance used, or all AI use of the day at its cap)
// the call is not made and answers "quota", which every caller already treats as "try again tomorrow".
// Pure: the pause check is passed in (web/src/integrations/ai/paused.ts reads it from the database).

export type PausedCheck = () => Promise<boolean>;

export const PAUSED_MESSAGE = 'Workers AI is paused for today: the included usage is used up (Admin > Settings > Usage). It resumes tomorrow.';

export function guardText(gen: TextGenerator, paused: PausedCheck): TextGenerator {
  return {
    name: gen.name,
    model: gen.model,
    async generate<T>(req: GenerateRequest): Promise<GenerateResult<T>> {
      if (await paused()) return { ok: false, reason: 'quota', message: PAUSED_MESSAGE };
      return gen.generate<T>(req);
    }
  };
}

export function guardVision(model: VisionModel, paused: PausedCheck): VisionModel {
  return {
    name: model.name,
    async read(req: VisionRequest, models: string[]): Promise<VisionResult> {
      if (await paused()) return { ok: false, reason: 'quota', message: PAUSED_MESSAGE, tried: [] };
      return model.read(req, models);
    }
  };
}

/** The guard's answer kept for a short time (one isolate runs many calls in a row: a guide run, a copy batch). */
export function cachedCheck(read: PausedCheck, ttlMs = 30_000, now: () => number = Date.now): PausedCheck {
  let at = -Infinity;
  let value = false;
  return async () => {
    if (now() - at < ttlMs) return value;
    value = await read();
    at = now();
    return value;
  };
}
