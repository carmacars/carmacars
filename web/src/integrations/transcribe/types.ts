// Speech to text for the recorded interviews (migration 0380): the audio of one answer in, its text out. Launch adapter:
// Cloudflare Workers AI Whisper through the Worker's AI binding (the free daily allowance of neurons); a fake for local
// work and tests.
export interface TranscribeRequest {
  audio: Uint8Array;
  /** the recording's type, for example audio/webm;codecs=opus */
  type: string;
  /** its length, for the cost estimate */
  seconds: number;
  /** the model, from Program settings (hiring_ai_transcribe_model) */
  model?: string;
}
export type TranscribeResult =
  | { ok: true; text: string; model: string; neurons: number }
  | { ok: false; reason: 'timeout' | 'quota' | 'unavailable' | 'invalid_output'; message: string; model?: string; neurons?: number };
export interface Transcriber {
  readonly name: 'workers-ai' | 'fake';
  transcribe(req: TranscribeRequest): Promise<TranscribeResult>;
}
