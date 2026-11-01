import type { Transcriber, TranscribeRequest, TranscribeResult } from './types';

// For local work and tests: no model. A recording that carries the text "FAKE-TRANSCRIPT:" (the end-to-end tests make
// one) is "heard" as the words after it; any other audio as one plain sentence. FAKE_TRANSCRIBE_FAIL=1 fails, as a model
// that is down. Never used on the live site.
export const FAKE_TRANSCRIBE_MODEL = 'fake-whisper-v1';
export const FAKE_SENTENCE = 'I worked two years in customer support for a company in the United States, answering calls and chats every day with Zendesk.';
export function fakeTranscriber(): Transcriber {
  return {
    name: 'fake',
    async transcribe(req: TranscribeRequest): Promise<TranscribeResult> {
      if (process.env.FAKE_TRANSCRIBE_FAIL === '1') return { ok: false, reason: 'unavailable', message: 'The fake transcriber is set to fail', model: FAKE_TRANSCRIBE_MODEL };
      const s = new TextDecoder('utf-8', { fatal: false }).decode(req.audio.slice(0, 64 * 1024));
      const m = /FAKE-TRANSCRIPT:([^\u0000]{1,2000})/.exec(s);
      return { ok: true, text: (m?.[1] ?? FAKE_SENTENCE).trim(), model: FAKE_TRANSCRIBE_MODEL, neurons: 0 };
    }
  };
}
