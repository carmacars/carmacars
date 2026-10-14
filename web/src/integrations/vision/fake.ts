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
      if (req.purpose === 'plate_detect') return { ok: true, model: FAKE_MODEL, usage, tried: [FAKE_MODEL], data: { plates: [{ x: 0.42, y: 0.66, w: 0.16, h: 0.06, confidence: 72 }] } };
      return { ok: true, model: FAKE_MODEL, usage, tried: [FAKE_MODEL], data: {
        issuer: 'City of Toronto', kind: 'parking', notice_number: 'PN 7710-0042', due_date: '2026-11-01', total: 50,
        lines: [{ notice_number: 'PN 7710-0042', plate: 'FAKE123', date: '2026-10-02', time: '14:32', location: '100 Queen St W', amount: 50, fees: null, confidence: 74 }]
      } };
    }
  };
}
