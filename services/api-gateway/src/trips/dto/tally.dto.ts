import { IsIn, IsInt, IsOptional, Max, Min } from 'class-validator';

/** Conductor's +/- passenger tally (docs §8 `POST /api/trips/:id/tally`).
 *
 * The app sends the resulting absolute count, not the delta: the buttons mutate
 * local state that is also folded into the next GPS ping, so an absolute value
 * keeps the durable `occupancy_snapshots` row and the live ping in agreement even
 * if a tap's request is lost or retried. */
export class TallyDto {
  @IsInt()
  @Min(0)
  @Max(999)
  occupancy!: number;

  /** Defaults to 'conductor_tally' — the only source that exists today. Present so
   * ticket-derived or sensor counts can post here unchanged if they ever land. */
  @IsOptional()
  @IsIn(['conductor_tally', 'ticket_derived', 'sensor'])
  source?: 'conductor_tally' | 'ticket_derived' | 'sensor';
}
