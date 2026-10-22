// The text generation module (docs/blueprint/09-listing-pipeline.md section 5.3): a hosted model with
// JSON output behind one interface. Launch adapter: Cloudflare Workers AI through the Worker's AI binding
// (the free daily allowance of neurons); a fake for local work and tests.
export type JsonSchema = Record<string, unknown>;

export interface GenerateRequest {
  task: 'listing_draft' | 'guide_rewrite' | 'chat' | 'car_copy' | 'seo_page' | 'article' | 'turo_email' | 'phone_draft' | 'phone_summary';
  system: string;
  /** The user message: the facts and the instructions for this one item. */
  prompt: string;
  schema: JsonSchema;
  maxOutputTokens: number;
  /** 0.4 unless given (a guide rewrite uses 0.1: it should change as little as it can). */
  temperature?: number;
}

export interface Usage { inputTokens: number; outputTokens: number; neurons: number }

export type GenerateResult<T> =
  | { ok: true; data: T; model: string; usage: Usage }
  | { ok: false; reason: 'timeout' | 'invalid_output' | 'quota' | 'unavailable'; message: string; usage?: Usage };

export interface TextGenerator {
  readonly name: 'workers-ai' | 'fake';
  readonly model: string;
  generate<T>(req: GenerateRequest): Promise<GenerateResult<T>>;
}
