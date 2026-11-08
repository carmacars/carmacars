import { redirect } from 'next/navigation';

// r35 part X: a problem with a car is reported from the one Add button on Today.
export default function Report() { redirect('/staff/field?add=problem'); }
