import { Controller, Get, Param } from '@nestjs/common';
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
