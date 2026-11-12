// What the crash listener leaves out (0433; r40). Pure, unit-tested (noise.test.ts).
// Noise that is not a crash: the stale build guard handles chunk errors, and ResizeObserver loop notices and cancelled
// requests are harmless.
export const NOISE = /ResizeObserver loop|skipTransition\(\) was called|^Script error\.?$|ChunkLoadError|Loading chunk|Failed to load chunk|MetaMask|chrome-extension:|moz-extension:|safari-web-extension:|Loading CSS chunk|AbortError|The user aborted|cancelled|Load failed/i;

/** r40: an error thrown by a script that is not ours (a browser extension, a password manager or autofill, a translator):
 *  the file it came from is another origin, or its stack has frames and none of them is on this site. */
export function foreignError(origin: string, filename: string | null | undefined, stack: string | null | undefined): boolean {
  if (filename && /^[a-z-]+:\/\//i.test(filename) && !filename.startsWith(origin)) return true;
  const frames = (stack ?? '').split('\n').filter((l) => /:\d+:\d+\)?\s*$/.test(l));
  return frames.length > 0 && !frames.some((l) => l.includes(origin) || l.includes('/_next/'));
}
