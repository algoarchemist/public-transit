import { Module } from '@nestjs/common';
import { StopsController } from './stops.controller';

@Module({
  controllers: [StopsController],
})
export class StopsModule {}
