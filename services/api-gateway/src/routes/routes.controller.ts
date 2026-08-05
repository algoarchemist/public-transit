import { Controller, Get, Param } from '@nestjs/common';
import { RoutesService } from './routes.service';

@Controller('routes')
export class RoutesController {
  constructor(private readonly routesService: RoutesService) {}

  @Get()
  findAll() {
    return this.routesService.findAll();
  }

  @Get(':id')
  findOne(@Param('id') id: string) {
    return this.routesService.findOne(id);
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
