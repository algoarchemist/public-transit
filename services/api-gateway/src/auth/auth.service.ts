import { Injectable, Logger, UnauthorizedException } from '@nestjs/common';
import { randomBytes } from 'node:crypto';

/**
 * Driver phone-OTP login.
 *
 * **This is a demo stub and says so out loud.** There is no SMS gateway wired up
 * (production would be MSG91/Twilio-India), so no code is ever delivered anywhere.
 * `requestOtp` therefore *returns* the code it generated and flags `demoMode: true`,
 * and the driver app renders it on screen. A hidden fake that silently accepts
 * anything would be worse: it looks like real auth to anyone reading the code, and
 * nobody at a demo can tell whether it is working.
 *
 * What IS real: the code is randomly generated per request, stored server-side with
 * a short expiry, single-use, and rate-limited per identifier. So the *flow* — request,
 * deliver, verify, consume, expire — is the real one, and swapping in an SMS provider
 * is a change to one function rather than a change to the login model.
 */

interface PendingOtp {
  code: string;
  expiresAt: number;
  attempts: number;
}

const OTP_TTL_MS = 5 * 60 * 1000;
const MAX_ATTEMPTS = 5;

@Injectable()
export class AuthService {
  private readonly logger = new Logger(AuthService.name);
  private readonly pending = new Map<string, PendingOtp>();

  /** Any non-empty identifier: a phone number or a depot-issued driver id. */
  requestOtp(identifier: string) {
    const id = (identifier ?? '').trim();
    if (!id) throw new UnauthorizedException('A driver ID or phone number is required');

    // 6 digits from a CSPRNG rather than Math.random — costs nothing and means the
    // stub does not model "generate a guessable secret" for anyone who copies it.
    const code = (parseInt(randomBytes(4).toString('hex'), 16) % 1_000_000).toString().padStart(6, '0');
    this.pending.set(id, { code, expiresAt: Date.now() + OTP_TTL_MS, attempts: 0 });
    this.sweep();

    this.logger.log(`OTP issued for '${id}' (demo mode — returned in the response, not sent by SMS)`);
    return {
      identifier: id,
      otpSent: true,
      demoMode: true,
      /** Shown in the app because nothing actually delivers it. */
      code,
      expiresInSec: OTP_TTL_MS / 1000,
      message: 'Demo mode: no SMS is sent. Use the code shown here.',
    };
  }

  verifyOtp(identifier: string, code: string) {
    const id = (identifier ?? '').trim();
    const entry = this.pending.get(id);

    if (!entry || entry.expiresAt < Date.now()) {
      this.pending.delete(id);
      throw new UnauthorizedException('That code has expired. Request a new one.');
    }
    if (entry.attempts >= MAX_ATTEMPTS) {
      this.pending.delete(id);
      throw new UnauthorizedException('Too many incorrect attempts. Request a new code.');
    }
    if (entry.code !== (code ?? '').trim()) {
      entry.attempts += 1;
      throw new UnauthorizedException('Incorrect code.');
    }

    this.pending.delete(id); // single use
    return {
      driverId: id,
      verified: true,
      // Not a JWT. Signing real session tokens needs a key and a verification
      // middleware this MVP does not have — returning something JWT-shaped would
      // imply a security property that is not there.
      token: null,
      demoMode: true,
    };
  }

  /** Drops expired entries so the map cannot grow without bound. */
  private sweep() {
    const now = Date.now();
    for (const [id, entry] of this.pending) {
      if (entry.expiresAt < now) this.pending.delete(id);
    }
  }
}
