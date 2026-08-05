import { Body, Controller, Get, Param, Post } from '@nestjs/common';
import { TicketsService } from './tickets.service';

@Controller('tickets')
export class TicketsController {
  constructor(private readonly ticketsService: TicketsService) {}

  @Post('fare')
  fare(@Body() body: { routeId: string; fromStopId: string; toStopId: string }) {
    return this.ticketsService.calculateFare(body.routeId, body.fromStopId, body.toStopId);
  }

  @Post()
  create(@Body() body: { routeId: string; fromStopId: string; toStopId: string; passengerId: string }) {
    return this.ticketsService.createTicket(body);
  }

  @Get(':id')
  findOne(@Param('id') id: string) {
    return this.ticketsService.findOne(id);
  }

  @Post(':id/validate')
  validate(@Param('id') id: string) {
    return this.ticketsService.validate(id);
  }
}
