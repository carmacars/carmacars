// The car's plate as it looks on the car (2026-10-25): the fastest way to find the right car in a lot, at night or in
// the sun. Read out as "Plate ABCD 123".
export function Plate({ plate, small, big }: { plate: string; small?: boolean; big?: boolean }) {
  return <span className={`fd-plate${small ? ' fd-plate--sm' : ''}${big ? ' fd-plate--lg' : ''}`}><span className="vh">Plate </span>{plate.toUpperCase()}</span>;
}
