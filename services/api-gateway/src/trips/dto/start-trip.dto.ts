import { IsInt, IsISO8601, IsOptional, IsString, Matches, Max, MaxLength, Min } from 'class-validator';

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

  /** The driver's stated/expected start time — populates the `trips.scheduled_start`
   * column, which existed in the schema (0001_init.sql) but nothing ever wrote to
   * it until now. Distinct from `startedAt` below: this is what the trip was
   * *supposed* to start at, for later schedule-adherence comparison (driver app's
   * History screen shows both). */
  @IsOptional()
  @IsISO8601()
  scheduledStart?: string;

  /** Client-supplied actual start instant, for the GPS-unavailable manual-entry
   * flow — a driver recording a trip that already started before connectivity/GPS
   * came back must be able to say when it really began rather than have the server
   * stamp `now()` and silently misrecord it. Omitted on the normal path, where the
   * server's `now()` is the honest value. */
  @IsOptional()
  @IsISO8601()
  startedAt?: string;
}
