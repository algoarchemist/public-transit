import { Body, Controller, Get, Param, ParseIntPipe, Patch, Post, Query } from '@nestjs/common';
import { TripsService } from './trips.service';
import { StartTripDto } from './dto/start-trip.dto';
import { EndTripDto } from './dto/end-trip.dto';
import { TallyDto } from './dto/tally.dto';

@Controller('trips')
export class TripsController {
  constructor(private readonly trips: TripsService) {}

  @Post()
  start(@Body() dto: StartTripDto) {
    return this.trips.start(dto);
  }

  /** "View all trips" (driver app's post-trip summary screen) — most recent first,
   * optionally scoped to one bus. `/trips` and `/trips/:id` below never collide:
   * Nest/Express match by path shape, and `:id` requires a segment `/trips` alone
   * doesn't have. */
  @Get()
  findAll(@Query('busId') busId?: string, @Query('limit') limit?: string) {
    return this.trips.findAll(busId, limit ? Number(limit) : undefined);
  }

  @Get(':id')
  findOne(@Param('id', ParseIntPipe) id: number) {
    return this.trips.findOne(id);
  }

  @Patch(':id/end')
  end(@Param('id', ParseIntPipe) id: number, @Body() dto: EndTripDto) {
    return this.trips.end(id, dto);
  }

  @Post(':id/tally')
  tally(@Param('id', ParseIntPipe) id: number, @Body() dto: TallyDto) {
    return this.trips.tally(id, dto);
  }
}
