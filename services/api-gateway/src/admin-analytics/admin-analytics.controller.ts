import { Controller, Get } from '@nestjs/common';
import { AdminAnalyticsService } from './admin-analytics.service';

@Controller('admin/analytics')
export class AdminAnalyticsController {
  constructor(private readonly analytics: AdminAnalyticsService) {}

  @Get('ridership')
  ridership() {
    return this.analytics.ridership();
  }

  @Get('demand-supply')
  demandSupply() {
    return this.analytics.demandSupply();
  }

  @Get('model-health')
  modelHealth() {
    return this.analytics.modelHealth();
  }
}
