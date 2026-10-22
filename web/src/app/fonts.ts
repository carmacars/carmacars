import localFont from 'next/font/local';

// Inter Display (headings, prices, wordmark) and Inter (text), self-hosted Latin subsets converted
// to WOFF2 from prototype/assets/fonts. SIL Open Font License. No third-party font request.
export const interDisplay = localFont({
  src: [
    { path: '../fonts/inter-display-600.woff2', weight: '600', style: 'normal' },
    { path: '../fonts/inter-display-700.woff2', weight: '700', style: 'normal' },
    { path: '../fonts/inter-display-800.woff2', weight: '800', style: 'normal' }
  ],
  variable: '--ff-display', display: 'swap', preload: true,
  fallback: ['Helvetica Neue', 'Helvetica', 'Arial', 'sans-serif']
});

export const inter = localFont({
  src: [
    { path: '../fonts/inter-400.woff2', weight: '400', style: 'normal' },
    { path: '../fonts/inter-500.woff2', weight: '500', style: 'normal' },
    { path: '../fonts/inter-600.woff2', weight: '600 700', style: 'normal' }
  ],
  variable: '--ff-text', display: 'swap', preload: false,  // text swaps in; the hero image and the display face load first (0095 speed)
  fallback: ['Helvetica Neue', 'Helvetica', 'Arial', 'sans-serif']
});
