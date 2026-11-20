// The line icons of the search page kit (release 48): one weight (1.7, the weight of the text beside them), 24 px box,
// drawn here so no icon library loads. Decorative: the label beside each icon says what it is.
const P = {
  pin: <><path d="M12 21s7-6.2 7-11.5A7 7 0 0 0 5 9.5C5 14.800 12 21 12 21z" /><circle cx="12" cy="9.5" r="2.5" /></>,
  power: <><path d="M12 3v8" /><path d="M6.3 6.8a8 8 0 1 0 11.4 0" /></>,
  lock: <><rect x="5" y="10.500" width="14" height="9.500" rx="2" /><path d="M8 10.500V7.500a4 4 0 0 1 8 0v3" /></>,
  bell: <><path d="M6 16.500V11a6 6 0 0 1 12 0v5.500l1.500 2h-15z" /><path d="M10 20.500a2 2 0 0 0 4 0" /></>,
  route: <><circle cx="6" cy="18" r="2" /><circle cx="18" cy="6" r="2" /><path d="M8 18h6.500a3.500 3.500 0 0 0 0-7h-5a3.500 3.500 0 0 1 0-7H16" /></>,
  receipt: <><path d="M6 3h12v18l-3-2-3 2-3-2-3 2z" /><path d="M9 8h6M9 12h6" /></>,
  wrench: <path d="M14.500 6.500a4 4 0 0 0 5 5L10 21a2.100 2.100 0 0 1-3-3l9.500-9.500a4 4 0 0 0-2-2z" />,
  key: <><circle cx="8" cy="15" r="4" /><path d="M11 12l8.500-8.500M16 6.500l2.500 2.500" /></>,
  wheel: <><circle cx="12" cy="12" r="8.500" /><circle cx="12" cy="12" r="2" /><path d="M12 14v6.500M10.200 11.200L4 9.200M13.800 11.200L20 9.200" /></>,
  sparkle: <><path d="M12 3l1.800 5.200L19 10l-5.200 1.800L12 17l-1.800-5.200L5 10l5.200-1.800z" /><path d="M18.500 16l.700 2 2 .700-2 .700-.700 2-.700-2-2-.700 2-.700z" /></>,
  truck: <><path d="M3 7h10.500v9.500H3zM13.500 10.500h4l3 3v3h-7z" /><circle cx="7.500" cy="17.500" r="1.800" /><circle cx="16.500" cy="17.500" r="1.800" /></>,
  plane: <path d="M10 13.500L3.500 15v-2l6.500-4V5a2 2 0 0 1 4 0v4l6.500 4v2L14 13.500V18l2 1.500V21l-4-1-4 1v-1.500L10 18z" />,
  shield: <><path d="M12 3l7.500 3v5.500c0 4.700-3.200 8-7.500 9.500-4.300-1.500-7.500-4.800-7.500-9.500V6z" /><path d="M9 12l2.200 2.200L15.200 10" /></>,
  users: <><circle cx="9" cy="8.500" r="3" /><path d="M3.500 19.500a5.500 5.500 0 0 1 11 0" /><circle cx="17" cy="9.500" r="2.300" /><path d="M16 14.200a4.500 4.500 0 0 1 5 4.800" /></>,
  calendar: <><rect x="4" y="5.500" width="16" height="14.500" rx="2" /><path d="M4 10h16M8.500 3.500v4M15.500 3.500v4" /></>,
  plug: <><path d="M9 3.500v5M15 3.500v5" /><path d="M6.500 8.500h11V12a5.500 5.500 0 0 1-11 0z" /><path d="M12 17.500v3.500" /></>,
  flower: <><circle cx="12" cy="9" r="2.200" /><path d="M12 6.800V4.500a2.300 2.300 0 0 1 4 1.600L14.200 8M14.200 10l1.800 1.900a2.300 2.300 0 0 1-4 1.600V11.200M12 13.500a2.300 2.300 0 0 1-4-1.600L9.800 10M9.800 8L8 6.100a2.300 2.300 0 0 1 4-1.600" /><path d="M12 13.500V21M12 18c-1.500 0-3-.800-3.500-2.500M12 16.500c1.500 0 3-.800 3.500-2.500" /></>,
  seat: <><path d="M8 4.500h6a2 2 0 0 1 2 2v6.500H8z" /><path d="M6 13h12v3.500a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2z" /><path d="M9 18.500V21M15 18.500V21" /></>,
  check: <path d="M5 12.500l4.500 4.500L19 7.500" />,
  star: <path d="M12 3.500l2.600 5.300 5.900.900-4.300 4.100 1 5.800-5.200-2.700-5.200 2.700 1-5.800-4.300-4.100 5.900-.900z" />,
  clock: <><circle cx="12" cy="12" r="8.500" /><path d="M12 7.500V12l3 2" /></>,
  phone: <path d="M6.500 3.500h3l1.500 4-2 1.500a11 11 0 0 0 6 6l1.500-2 4 1.500v3a2 2 0 0 1-2 2A15.500 15.500 0 0 1 4.500 5.500a2 2 0 0 1 2-2z" />,
  car: <><path d="M4 16.500v-3l2-5.500a2 2 0 0 1 1.900-1.400h8.200A2 2 0 0 1 18 8l2 5.500v3" /><path d="M3.500 13.500h17v4h-17z" /><circle cx="7.500" cy="17.500" r="1.500" /><circle cx="16.500" cy="17.500" r="1.500" /></>,
  card: <><rect x="3" y="6" width="18" height="12.500" rx="2" /><path d="M3 10.500h18M7 15h3.500" /></>,
  fleet: <><rect x="3" y="4" width="7.500" height="6.500" rx="1.500" /><rect x="13.500" y="4" width="7.500" height="6.500" rx="1.500" /><rect x="3" y="13.500" width="7.500" height="6.500" rx="1.500" /><rect x="13.500" y="13.500" width="7.500" height="6.500" rx="1.500" /></>,
  dollar: <><circle cx="12" cy="12" r="8.500" /><path d="M14.500 9.200c-.500-.900-1.400-1.400-2.500-1.400-1.500 0-2.600.800-2.600 2 0 2.900 5.300 1.400 5.300 4.300 0 1.200-1.200 2.100-2.700 2.100-1.200 0-2.200-.600-2.700-1.600M12 6v1.800M12 16.200V18" /></>,
  arrow: <path d="M4 12h15M13.500 6.500L19 12l-5.500 5.500" />
} as const;
export type KitIcon = keyof typeof P;
export function Ico({ name, lg }: { name: KitIcon; lg?: boolean }) {
  return <svg className={lg ? 'sk-ico sk-ico--lg' : 'sk-ico'} viewBox="0 0 24 24" aria-hidden="true" focusable="false">{P[name]}</svg>;
}
