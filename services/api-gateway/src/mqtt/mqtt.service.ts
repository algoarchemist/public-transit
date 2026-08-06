import { Injectable, Logger, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import mqtt, { type MqttClient } from 'mqtt';

/**
 * Publishes the `bus/{busId}/status` trip-lifecycle messages of docs §7.2 — the
 * topic that table has always listed but nothing published until now.
 *
 * Why the gateway and not the driver app: the trip row lives in Postgres, and its
 * id is minted here on `POST /api/trips`. The stream-processor needs that id to
 * attach live pings to the right trip (see stream-processor/src/pgPersist.ts,
 * which until now had to *infer* trip boundaries from the first ping it saw and
 * could never mark a trip 'completed'). Publishing from the same place that mints
 * the id means the two can never disagree.
 *
 * Delivery is QoS 1 with retain: a stream-processor that restarts mid-trip
 * re-receives the last status per bus and re-adopts the running trip instead of
 * silently falling back to inferring one.
 *
 * Failure policy: publishing is best-effort and never fails the HTTP request. A
 * trip that exists in Postgres but whose status message didn't reach the broker
 * degrades to exactly the old inferred-lifecycle behaviour, which still works.
 */

export type TripStatusEvent = 'trip_start' | 'trip_end';

export interface TripStatusMessage {
  event: TripStatusEvent;
  tripId: number;
  busId: string;
  routeId: string | null;
  directionId: string;
  timestamp: number;
}

@Injectable()
export class MqttService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(MqttService.name);
  private client: MqttClient | null = null;

  onModuleInit(): void {
    const url = process.env.MQTT_BROKER_URL ?? 'mqtt://localhost:1883';
    const client = mqtt.connect(url, { clientId: `api-gateway-${process.pid}`, reconnectPeriod: 5000 });
    client.on('connect', () => this.logger.log(`connected to ${url}`));
    client.on('error', (err) => this.logger.error(`mqtt error: ${err.message}`));
    this.client = client;
  }

  async onModuleDestroy(): Promise<void> {
    await this.client?.endAsync();
  }

  publishTripStatus(message: TripStatusMessage): void {
    const client = this.client;
    if (!client?.connected) {
      this.logger.warn(
        `broker unavailable — ${message.event} for trip ${message.tripId} not published; ` +
          'stream-processor will fall back to inferring the trip lifecycle',
      );
      return;
    }
    client.publish(
      `bus/${message.busId}/status`,
      JSON.stringify(message),
      { qos: 1, retain: true },
      (err) => {
        if (err) this.logger.error(`failed to publish ${message.event}: ${err.message}`);
      },
    );
  }
}
