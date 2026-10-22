// The business phone line (migration 0085): sending a text from the CarmaCars number. Real adapter: Quo's public API
// (src/features/phone/quo-api.ts); fake: records the text and answers like Quo, for local work and tests.
export interface SendResult { ok: boolean; id: string | null; error?: string; permanent?: boolean }
export interface PhoneLine {
  readonly name: 'quo' | 'fake';
  /** false when the line cannot send (no key): texts then wait in the outbox. */
  readonly ready: boolean;
  sendText(p: { from: string; to: string; body: string }): Promise<SendResult>;
}
