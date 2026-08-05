import { Injectable } from '@nestjs/common';

// TODO: fare calc from route/stop distance table; QR generation + UPI (Razorpay) integration;
// tickets must be verifiable offline by the driver app (signed payload), syncing validation later.
@Injectable()
export class TicketsService {
  calculateFare(routeId: string, fromStopId: string, toStopId: string) {
    return { routeId, fromStopId, toStopId, fare: null };
  }

  createTicket(input: { routeId: string; fromStopId: string; toStopId: string; passengerId: string }) {
    return { id: null, ...input, qrPayload: null, status: 'pending_payment' };
  }

  findOne(id: string) {
    return { id, status: null };
  }

  validate(id: string) {
    return { id, status: 'validated', validatedAt: new Date().toISOString() };
  }
}
