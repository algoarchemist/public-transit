import { Body, Controller, Post } from '@nestjs/common';
import { IsOptional, IsString, MaxLength, MinLength } from 'class-validator';
import { AuthService } from './auth.service';

class RequestOtpDto {
  /** A phone number or a depot-issued driver id — the stub treats both the same. */
  @IsOptional()
  @IsString()
  @MaxLength(32)
  phone?: string;

  @IsOptional()
  @IsString()
  @MaxLength(32)
  driverId?: string;
}

class VerifyOtpDto {
  @IsOptional()
  @IsString()
  @MaxLength(32)
  phone?: string;

  @IsOptional()
  @IsString()
  @MaxLength(32)
  driverId?: string;

  @IsString()
  @MinLength(4)
  @MaxLength(8)
  code!: string;
}

@Controller('auth')
export class AuthController {
  constructor(private readonly authService: AuthService) {}

  @Post('otp/request')
  requestOtp(@Body() body: RequestOtpDto) {
    return this.authService.requestOtp(body.driverId ?? body.phone ?? '');
  }

  @Post('otp/verify')
  verifyOtp(@Body() body: VerifyOtpDto) {
    return this.authService.verifyOtp(body.driverId ?? body.phone ?? '', body.code);
  }
}
