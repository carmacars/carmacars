// Guide me (r51, migration 3950): the workflows, one declarative step file each (flows/*.json). A new workflow is a new
// file listed here: the steps name data-guide="..." elements, an instruction and the condition that completes them.
import type { Flow } from './engine';
import createOffer from './flows/create-offer.json';
import recordPayment from './flows/record-payment.json';
import pickupHandover from './flows/pickup-handover.json';
import returnDeposit from './flows/return-deposit.json';
import approveOwnerCar from './flows/approve-owner-car.json';
import fieldExpense from './flows/field-expense.json';
import bookingRequest from './flows/booking-request.json';
import checkinVisit from './flows/checkin-visit.json';

export const FLOWS: Flow[] = [createOffer, bookingRequest, recordPayment, pickupHandover, returnDeposit, approveOwnerCar, fieldExpense, checkinVisit] as Flow[];
export const flowById = (id: string): Flow | undefined => FLOWS.find((f) => f.id === id);
