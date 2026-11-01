import type { VisionModel, VisionRequest, VisionResult } from './types';

// For local work and tests: a fixed answer that looks like the model's, so the whole review runs without a
// model. The toll answer is a parking notice for a plate that is not in the fleet (staff correct it on the
// review screen); the plate answer is a box in the lower middle of the photo. Never used on the live site.
export const FAKE_MODEL = 'fake-vision-v1';
export function fakeVision(): VisionModel {
  return {
    name: 'fake',
    async read(req: VisionRequest): Promise<VisionResult> {
      if (process.env.FAKE_VISION_FAIL === '1') return { ok: false, reason: 'unavailable', message: 'The fake vision model is set to fail', tried: [FAKE_MODEL] };
      const usage = { inputTokens: 1200, outputTokens: 180, neurons: 0 };
      if (req.purpose === 'guide_review') {
        // the text between the markers of the prompt, with one sentence added: enough to check the review flow
        const m = /<<<GUIDE\n([\s\S]*?)\nGUIDE>>>/.exec(req.prompt);
        return { ok: true, model: FAKE_MODEL, usage, tried: [FAKE_MODEL], data: { body_md: `${m?.[1] ?? ''}\n\n> Good to know: the screen now matches the steps above.`, summary: 'Added a note that the screen matches the steps.' } };
      }
      if (req.purpose === 'colour_read') return { ok: true, model: FAKE_MODEL, usage, tried: [FAKE_MODEL], data: { colour: process.env.FAKE_VISION_COLOUR || 'Silver', confidence: 88 } };
      // an ownership permit (0290): a synthetic car, its VIN with a valid check digit; no real plate or permit
      if (req.purpose === 'permit_read') return { ok: true, model: FAKE_MODEL, usage, tried: [FAKE_MODEL], data: {
        plate: 'ZZZZ 123', vin: '3FAKEPRM5RT000042', year: 2024, make: 'TOYOT', model: 'CRL', body: '4DR', colour: 'GRY', permit_number: 'X0000001', sticker_expiry: '271130', confidence: 86 } };
      if (req.purpose === 'plate_detect') return { ok: true, model: FAKE_MODEL, usage, tried: [FAKE_MODEL], data: { plates: [{ x: 0.42, y: 0.66, w: 0.16, h: 0.06, confidence: 72 }] } };
      return { ok: true, model: FAKE_MODEL, usage, tried: [FAKE_MODEL], data: {
        issuer: 'City of Toronto', kind: 'parking', notice_number: 'PN 7710-0042', due_date: '2026-11-01', total: 50,
        lines: [{ notice_number: 'PN 7710-0042', plate: 'FAKE123', date: '2026-10-02', time: '14:32', location: '100 Queen St W', amount: 50, fees: null, confidence: 74 }]
      } };
    }
  };
}
