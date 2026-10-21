// The vision module (migration 0042): a model that reads an image and answers in JSON. It reads scanned toll
// notices and suggests where the plate is on a listing photo. Launch adapter: Cloudflare Workers AI through the
// Worker's AI binding (the same free daily neurons as the listing copy); a fake for local work and tests.
export interface VisionUsage { inputTokens: number; outputTokens: number; neurons: number }

export interface VisionRequest {
  system: string;
  prompt: string;
  /** The image as a data URL (image/jpeg or image/png, base64), already made small in the browser. */
  imageDataUrl: string;
  schema?: Record<string, unknown>;
  maxOutputTokens: number;
  purpose: 'toll_read' | 'plate_detect' | 'guide_review' | 'colour_read';
}

export type VisionResult =
  | { ok: true; data: unknown; model: string; usage: VisionUsage; tried: string[] }
  | { ok: false; reason: 'quota' | 'unavailable' | 'timeout' | 'invalid_output'; message: string; model?: string; usage?: VisionUsage; tried: string[] };

export interface VisionModel {
  readonly name: 'workers-ai' | 'fake';
  /** Tries each model in order until one answers (a model that is not on the account, or refuses the input, is skipped). */
  read(req: VisionRequest, models: string[]): Promise<VisionResult>;
}
