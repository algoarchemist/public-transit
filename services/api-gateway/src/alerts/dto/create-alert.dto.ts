import { IsIn, IsInt, IsLatitude, IsLongitude, IsOptional, IsString, MaxLength } from 'class-validator';

/** Driver-raised incident types. System-inferred ones ('route_deviation',
 * 'signal_lost') are written by the stream-processor, never posted here. */
export const DRIVER_ALERT_TYPES = ['sos', 'breakdown', 'traffic', 'road_diversion', 'accident'] as const;
export type DriverAlertType = (typeof DRIVER_ALERT_TYPES)[number];

export class CreateAlertDto {
  // Optional here, not required: /alerts/sos and /alerts/breakdown (docs §8) fill
  // this in server-side after validation, so the client never sends it on those
  // routes. AlertsService.create still always receives a real, valid type — either
  // this field (validated below when present) or the controller's literal.
  @IsOptional()
  @IsIn(DRIVER_ALERT_TYPES as unknown as string[])
  type?: DriverAlertType;

  /** Optional so a driver can raise an SOS before, or after, a trip exists. */
  @IsOptional()
  @IsInt()
  tripId?: number;

  /** Bus registration / fleet code. Resolved to `buses.id` if we know it. */
  @IsOptional()
  @IsString()
  @MaxLength(32)
  busId?: string;

  @IsOptional()
  @IsLatitude()
  lat?: number;

  @IsOptional()
  @IsLongitude()
  lon?: number;

  @IsOptional()
  @IsString()
  @MaxLength(500)
  notes?: string;
}
