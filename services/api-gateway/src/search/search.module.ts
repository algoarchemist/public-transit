import { Module } from '@nestjs/common';
import { SearchController } from './search.controller';
import { SearchService } from './search.service';
import { BusesModule } from '../buses/buses.module';

@Module({
  imports: [BusesModule],
  controllers: [SearchController],
  providers: [SearchService],
})
export class SearchModule {}
