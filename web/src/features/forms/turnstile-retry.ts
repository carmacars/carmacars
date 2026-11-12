/** r40: whether a Turnstile error is worth another try. Without an error-callback Turnstile throws "[Cloudflare Turnstile]
 *  Error" into the page (crash reports on the careers form). A setup error (an unknown site key or domain, 110xxx, 4xxxxx)
 *  never passes on a retry; the rest (network, a challenge that timed out, 300xxx and 600xxx) get up to 3 tries. */
export function turnstileRetry(code: unknown, tries: number): boolean {
  const c = String(code ?? '');
  if (/^(110|4\d\d)\d{3}$/.test(c)) return false;
  return tries < 3;
}
