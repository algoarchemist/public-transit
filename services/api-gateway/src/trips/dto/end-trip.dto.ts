import { IsIn, IsOptional } from 'class-validator';

export class EndTripDto {
  /** 'completed' when the driver ends the trip normally; 'abandoned' when the run
   * was cut short (breakdown, diversion). Both are real terminal states in the
   * `trips.status` check constraint — see db/migrations/0001_init.sql. */
  @IsOptional()
  @IsIn(['completed', 'abandoned'])
  status?: 'completed' | 'abandoned';
}
