import { Module } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { TypeOrmModule } from '@nestjs/typeorm';
import { AppController } from './app.controller';
import { AppService } from './app.service';
import { SnapshotModule } from './snapshot/snapshot.module';
import { MqttModule } from './mqtt/mqtt.module';
import { RoutesModule } from './routes/routes.module';
import { BusesModule } from './buses/buses.module';
import { StopsModule } from './stops/stops.module';
import { AlertsModule } from './alerts/alerts.module';
import { TripsModule } from './trips/trips.module';
import { AuthModule } from './auth/auth.module';
import { SearchModule } from './search/search.module';

@Module({
  imports: [
    ConfigModule.forRoot({ isGlobal: true }),
    TypeOrmModule.forRoot({
      type: 'postgres',
      url: process.env.DATABASE_URL ?? 'postgres://setutrack:setutrack@localhost:5432/setutrack',
      autoLoadEntities: true,
      // db/migrations owns the schema (docs §2). `synchronize` cannot express the
      // PostGIS geometry columns, SRID constraints or GiST indexes that schema
      // needs, and letting it near a migration-managed database risks it "fixing"
      // tables it does not understand. Off in every environment, not just prod.
      synchronize: false,
    }),
    SnapshotModule,
    MqttModule,
    RoutesModule,
    BusesModule,
    StopsModule,
    TripsModule,
    AlertsModule,
    AuthModule,
    SearchModule,
  ],
  controllers: [AppController],
  providers: [AppService],
})
export class AppModule {}
