import { Test, TestingModule } from '@nestjs/testing';
import { BadRequestException } from '@nestjs/common';
import { SearchController } from './search.controller';
import { SearchService } from './search.service';
import { SnapshotService } from '../snapshot/snapshot.service';
import { BusesService } from '../buses/buses.service';

// Real data from data/snapshots/mohali-tricity — route "1" ("Bus 1: New Maloya
// Colony => Mani Majra") serving "Chandigarh Railway Station".
describe('SearchController', () => {
  let controller: SearchController;

  beforeEach(async () => {
    const module: TestingModule = await Test.createTestingModule({
      controllers: [SearchController],
      providers: [SearchService, SnapshotService, BusesService],
    }).compile();

    controller = module.get<SearchController>(SearchController);
  });

  it('resolves an exact route number and exact stop name', () => {
    const result = controller.search('1', 'Chandigarh Railway Station');
    expect(result.matched).toBe(true);
    expect(result.bus?.ref).toBe('1');
    expect(result.stop?.name).toBe('Chandigarh Railway Station');
  });

  it('resolves a case-insensitive, partial stop name', () => {
    const result = controller.search('1', 'railway station');
    expect(result.matched).toBe(true);
    expect(result.stop?.name).toBe('Chandigarh Railway Station');
  });

  it('reports bus_not_found for an unknown route', () => {
    const result = controller.search('not-a-real-route', 'Chandigarh Railway Station');
    expect(result.matched).toBe(false);
    expect(result.reason).toBe('bus_not_found');
  });

  it('reports location_not_found but still identifies the bus', () => {
    const result = controller.search('1', 'not a real stop anywhere');
    expect(result.matched).toBe(false);
    expect(result.reason).toBe('location_not_found');
    expect(result.bus?.ref).toBe('1');
  });

  it('rejects requests missing either query param', () => {
    expect(() => controller.search(undefined, 'Chandigarh Railway Station')).toThrow(BadRequestException);
    expect(() => controller.search('1', undefined)).toThrow(BadRequestException);
    expect(() => controller.search('  ', 'Chandigarh Railway Station')).toThrow(BadRequestException);
  });
});
