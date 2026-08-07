import { BadRequestException, Controller, Get, Query } from '@nestjs/common';
import { SearchService } from './search.service';

/** `GET /search?bus=&location=` — resolves a spoken/typed bus number and
 * destination name into a route+stop match. Built for the mobile app's voice
 * search flow (apps/mobile-app/lib/passenger/voice/), but plain text works too. */
@Controller('search')
export class SearchController {
  constructor(private readonly searchService: SearchService) {}

  @Get()
  search(@Query('bus') bus?: string, @Query('location') location?: string) {
    if (!bus?.trim() || !location?.trim()) {
      throw new BadRequestException('bus and location query params are both required');
    }
    return this.searchService.search(bus.trim(), location.trim());
  }
}
