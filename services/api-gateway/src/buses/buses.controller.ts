import { Controller, Get, NotFoundException, Param } from '@nestjs/common';
import { BusesService } from './buses.service';

@Controller('buses')
export class BusesController {
  constructor(private readonly busesService: BusesService) {}

  @Get()
  findAll() {
    return this.busesService.findAll();
  }

  @Get(':id')
  async findOne(@Param('id') id: string) {
    const bus = await this.busesService.findOne(id);
    if (!bus) throw new NotFoundException(`no live state for bus '${id}' (no ping on record)`);
    return bus;
  }

  @Get(':id/eta')
  eta(@Param('id') id: string) {
    return this.busesService.eta(id);
  }
}
