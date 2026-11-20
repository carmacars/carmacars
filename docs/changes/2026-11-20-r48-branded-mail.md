# Branded mail: BIMI logo and Apple Branded Mail (Release 48)

The owner (Nov 20) wants the logo shown cleanly on every device, for every business. CarmaCars' name or logo is trademarked (which one is unconfirmed).

- `web/public/brand/carma-bimi.svg`: the BIMI logo, made from the red icon. It is SVG Tiny PS (baseProfile tiny-ps, version 1.2), square, with a solid #E30613 background, a title and desc, no scripts or links, and about 3 KB. It is served at https://carmacars.ca/brand/carma-bimi.svg.
- Still to do, by the owner with Claude in Chrome:
  1. DMARC to p=quarantine, pct=100, then p=reject, after every sender (Google Workspace, Resend, SES, Cloudflare Email) passes DKIM with alignment.
  2. A VMC if the logo is the registered mark, otherwise a CMC. The issuer gives a PEM; host it at /brand/carma-bimi.pem.
  3. A DNS TXT record `default._bimi.carmacars.ca` with `v=BIMI1; l=https://carmacars.ca/brand/carma-bimi.svg; a=https://carmacars.ca/brand/carma-bimi.pem`.
  4. Apple Business Connect: verify the organisation, add Branded Mail for carmacars.ca (DKIM on all mail), upload the logo, and wait for review (up to 7 business days).

## Guides

No guide change: a logo file for mail programs, nothing a person does.
