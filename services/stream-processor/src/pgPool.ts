/** Shared Postgres pool — statsStore.ts (read-only, derived stats) and
 * pgPersist.ts (writes raw gps_pings/stop_events) both use the same pool rather
 * than each opening its own connection set to the same database. */
import { Pool } from 'pg';
import { config } from './config';

let pool: Pool | null = null;

export function getPgPool(): Pool {
  if (!pool) {
    pool = new Pool({ connectionString: config.databaseUrl });
  }
  return pool;
}
