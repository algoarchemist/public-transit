import { Global, Module } from '@nestjs/common';
import { SnapshotService } from './snapshot.service';

/** Global because both RoutesModule and TripsModule read the same parsed snapshot
 * and it is a few MB of GeoJSON — one instance, one parse. */
@Global()
@Module({
  providers: [SnapshotService],
  exports: [SnapshotService],
})
export class SnapshotModule {}
