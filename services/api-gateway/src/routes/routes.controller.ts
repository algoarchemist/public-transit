import { Controller, Get, Param, Query } from '@nestjs/common';
import { RoutesService } from './routes.service';

@Controller('routes')
export class RoutesController {
  constructor(private readonly routesService: RoutesService) {}

  @Get()
  findAll() {
    return this.routesService.findAll();
  }

  @Get('geometry')
  geometry() {
    return this.routesService.geometry();
  }

  // Registered ahead of ':id' — Nest/Express matches static segments in
  // registration order, so 'journeys' must not fall through to findOne(id='journeys').
  @Get('journeys')
  journeys(@Query('from') from: string, @Query('to') to: string) {
    return this.routesService.journeys(from, to);
  }

  @Get(':id')
  findOne(@Param('id') id: string) {
    return this.routesService.findOne(id);
  }

  /** One route's polyline. The passenger app draws a single route at a time and must
   * not pull the whole multi-MB collection to do it — see RoutesService.routeGeometry. */
  @Get(':id/geometry')
  routeGeometry(@Param('id') id: string) {
    return this.routesService.routeGeometry(id);
  }

  @Get(':id/stops')
  stops(@Param('id') id: string) {
    return this.routesService.stops(id);
  }

  @Get(':id/performance')
  performance(@Param('id') id: string) {
    return this.routesService.performance(id);
  }
}
