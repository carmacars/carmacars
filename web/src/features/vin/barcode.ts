'use client';

// The barcode reader of the VIN scanner (release 28), in the browser only: the browser's own BarcodeDetector where it
// reads Code 39 (Chrome and Edge on Android, ChromeOS, macOS), otherwise zxing-wasm (MIT), self-hosted under
// /vendor/zxing-wasm-3.1.6 and loaded only when a scan starts (Safari on the iPhone has no BarcodeDetector). The VIN
// barcode on the door jamb and under the windshield is Code 39 or Code 128; newer labels carry a Data Matrix.

export type Source = HTMLVideoElement | HTMLCanvasElement | ImageBitmap;
export interface Reader { name: 'native' | 'zxing'; read(src: Source): Promise<string[]> }

const NATIVE_FORMATS = ['code_39', 'code_128', 'data_matrix', 'qr_code', 'pdf417'];
const ZXING_FORMATS = ['Code39', 'Code128', 'DataMatrix', 'QRCode', 'PDF417'];
const VENDOR = '/vendor/zxing-wasm-3.1.6';

interface NativeDetector { detect(src: Source): Promise<Array<{ rawValue: string }>> }
interface NativeCtor { new (o: { formats: string[] }): NativeDetector; getSupportedFormats(): Promise<string[]> }
interface ZXing {
  prepareZXingModule(o: { overrides: { locateFile: (path: string, prefix: string) => string }; fireImmediately?: boolean }): unknown;
  readBarcodes(input: ImageData, o: Record<string, unknown>): Promise<Array<{ text: string; isValid: boolean }>>;
}

let zx: Promise<ZXing> | null = null;
function loadZXing(): Promise<ZXing> {
  zx ??= new Promise<ZXing>((ok, no) => {
    const w = window as unknown as { ZXingWASM?: ZXing };
    if (w.ZXingWASM) { ok(w.ZXingWASM); return; }
    const s = document.createElement('script');
    s.src = `${VENDOR}/reader.js`;
    s.async = true;
    s.onload = () => {
      const z = (window as unknown as { ZXingWASM?: ZXing }).ZXingWASM;
      if (!z) { no(new Error('The barcode reader did not load.')); return; }
      // the wasm file from this site, never the package's default CDN
      z.prepareZXingModule({ overrides: { locateFile: (path, prefix) => (path.endsWith('.wasm') ? `${VENDOR}/${path}` : prefix + path) }, fireImmediately: true });
      ok(z);
    };
    s.onerror = () => no(new Error('The barcode reader did not load.'));
    document.head.appendChild(s);
  }).catch((e) => { zx = null; throw e; });
  return zx;
}

/** Pixels of a frame, at most 1600 wide (enough for a door-jamb barcode filling a third of the frame). */
function pixels(src: Source): ImageData | null {
  const w0 = src instanceof HTMLVideoElement ? src.videoWidth : src.width;
  const h0 = src instanceof HTMLVideoElement ? src.videoHeight : src.height;
  if (!w0 || !h0) return null;
  const k = Math.min(1, 1600 / w0);
  const c = document.createElement('canvas');
  c.width = Math.round(w0 * k); c.height = Math.round(h0 * k);
  const g = c.getContext('2d', { willReadFrequently: true });
  if (!g) return null;
  g.drawImage(src, 0, 0, c.width, c.height);
  return g.getImageData(0, 0, c.width, c.height);
}

let chosen: Promise<Reader> | null = null;
/** The reader this browser uses (decided once). */
export function barcodeReader(): Promise<Reader> {
  chosen ??= (async (): Promise<Reader> => {
    const Native = (window as unknown as { BarcodeDetector?: NativeCtor }).BarcodeDetector;
    if (Native) {
      try {
        const have = await Native.getSupportedFormats();
        const formats = NATIVE_FORMATS.filter((f) => have.includes(f));
        if (formats.includes('code_39')) {
          const d = new Native({ formats });
          return { name: 'native', read: async (src) => (await d.detect(src)).map((b) => b.rawValue).filter(Boolean) };
        }
      } catch { /* not usable here: zxing */ }
    }
    const z = await loadZXing();
    return {
      name: 'zxing',
      read: async (src) => {
        const img = pixels(src);
        if (!img) return [];
        const out = await z.readBarcodes(img, { formats: ZXING_FORMATS, tryHarder: true, tryRotate: true, maxNumberOfSymbols: 4 });
        return out.filter((r) => r.isValid && r.text).map((r) => r.text);
      }
    };
  })().catch((e) => { chosen = null; throw e; });
  return chosen;
}

/** The back camera, as large as the phone gives (a barcode needs detail). */
export async function backCamera(): Promise<MediaStream> {
  if (!navigator.mediaDevices?.getUserMedia) throw new Error('This browser cannot open the camera here. Take a photo instead.');
  return navigator.mediaDevices.getUserMedia({ audio: false, video: { facingMode: { ideal: 'environment' }, width: { ideal: 1920 }, height: { ideal: 1080 } } });
}
