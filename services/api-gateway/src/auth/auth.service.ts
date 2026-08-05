import { Injectable } from '@nestjs/common';

// TODO: phone-OTP via SMS gateway (MSG91/Twilio-India); RBAC roles (District Officer / State HQ)
// backed by Keycloak in production, Firebase Auth acceptable for hackathon demo speed.
@Injectable()
export class AuthService {
  requestOtp(phone: string) {
    return { phone, otpSent: true };
  }

  verifyOtp(phone: string, code: string) {
    return { phone, verified: code.length > 0, token: null };
  }
}
