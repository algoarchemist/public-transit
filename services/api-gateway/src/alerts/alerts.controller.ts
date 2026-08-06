import { BadRequestException, Body, Controller, Get, Param, ParseIntPipe, Patch, Post, Query } from '@nestjs/common';
import { AlertsService } from './alerts.service';
import { CreateAlertDto, DRIVER_ALERT_TYPES } from './dto/create-alert.dto';

@Controller('alerts')
export class AlertsController {
  constructor(private readonly alerts: AlertsService) {}

  /** The general form the driver app posts to, with `type` in the body. */
  @Post()
  create(@Body() dto: CreateAlertDto) {
    if (!dto.type) {
      throw new BadRequestException(`type must be one of the following values: ${DRIVER_ALERT_TYPES.join(', ')}`);
    }
    return this.alerts.create({ ...dto, type: dto.type });
  }

  /** Docs §8 names `/alerts/sos` and `/alerts/breakdown` explicitly. Kept as
   * aliases so the documented surface is real, rather than quietly replaced. */
  @Post('sos')
  sos(@Body() dto: CreateAlertDto) {
    return this.alerts.create({ ...dto, type: 'sos' });
  }

  @Post('breakdown')
  breakdown(@Body() dto: CreateAlertDto) {
    return this.alerts.create({ ...dto, type: 'breakdown' });
  }

  @Get()
  listOpen(@Query('limit') limit?: string) {
    const parsed = Number(limit ?? 50);
    return this.alerts.listOpen(Number.isFinite(parsed) ? parsed : 50);
  }

  @Patch(':id/resolve')
  resolve(@Param('id', ParseIntPipe) id: number) {
    return this.alerts.resolve(id);
  }
}
