import { IsInt, IsOptional, IsString, Matches, Max, MaxLength, Min } from 'class-validator';

export class StartTripDto {
  /** The bus's registration number — the same string the driver app publishes as
   * `busId` on `gps/{busId}/ping`, so the live pipeline and the trip row agree on
   * identity without a lookup table. */
  @IsString()
  @MaxLength(32)
  busId!: string;

  /** `direction_id` from `GET /api/routes` ("r" + OSM relation id). */
  @IsString()
  @Matches(/^r\d+$/, { message: 'directionId must look like "r16450017" (see GET /api/routes)' })
  directionId!: string;

  /** Depot-issued driver id. Optional: OTP login is still a stub (§8's
   * /api/auth/otp/* returns placeholders), so there is no authenticated identity
   * to take this from yet — recording whatever the app supplies beats dropping it. */
  @IsOptional()
  @IsString()
  @MaxLength(64)
  driverId?: string;

  /** Occupancy at departure, if the conductor already counted. */
  @IsOptional()
  @IsInt()
  @Min(0)
  @Max(999)
  initialOccupancy?: number;
}
