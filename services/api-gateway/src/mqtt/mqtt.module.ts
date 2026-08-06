import { Global, Module } from '@nestjs/common';
import { MqttService } from './mqtt.service';

/** Global so any module can publish without each opening its own broker connection. */
@Global()
@Module({
  providers: [MqttService],
  exports: [MqttService],
})
export class MqttModule {}
