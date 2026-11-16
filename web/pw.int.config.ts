import base from './playwright.config';
const use = { ...(base.use as object), launchOptions: { ...((base.use as { launchOptions?: object }).launchOptions ?? {}), executablePath: '/opt/pw-browsers/chromium_headless_shell-1254/chrome-headless-shell-linux64/chrome-headless-shell' } };
export default { ...base, use, expect: { timeout: 20_000 }, workers: 1, reporter: [['list']] };
