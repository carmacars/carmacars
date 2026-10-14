import { z } from 'zod';

// Zod compiles a fast validator with `new Function` unless told not to; in the browser our content security
// policy refuses eval, so every page that validated a form logged a CSP violation (Lighthouse: best practices
// 96). Jitless mode validates the same way without eval. Import z from here, not from 'zod'.
z.config({ jitless: true });
export { z };
