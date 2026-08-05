import 'dart:convert';

import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

/// A pending GPS ping, queued locally when MQTT publish fails or the device is
/// offline. `lateArrival` is computed at flush time (how old the ping actually was
/// when it finally went out), not at enqueue time — see docs/IMPLEMENTATION_ARCHITECTURE.md
/// §7.4: the server must never let a replayed backlog rewind a bus's live position,
/// so every buffered ping needs to self-report that it's a late arrival.
class BufferedPing {
  final int? id;
  final Map<String, dynamic> payload;
  final int originalTimestampMs;

  BufferedPing({this.id, required this.payload, required this.originalTimestampMs});
}

/// Bounded (oldest-first eviction) local queue so a long outage can't fill a
/// budget Android phone's storage — see solution doc section 1.3.
class PingBuffer {
  static const _maxBufferedPings = 2000;

  Database? _db;

  Future<void> open() async {
    final path = join(await getDatabasesPath(), 'setutrack_ping_buffer.db');
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE pending_pings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            payload_json TEXT NOT NULL,
            original_timestamp_ms INTEGER NOT NULL
          )
        ''');
      },
    );
  }

  Future<void> enqueue(Map<String, dynamic> payload, int originalTimestampMs) async {
    final db = _db;
    if (db == null) return;

    await db.insert('pending_pings', {
      'payload_json': jsonEncode(payload),
      'original_timestamp_ms': originalTimestampMs,
    });

    final count = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM pending_pings')) ?? 0;
    if (count > _maxBufferedPings) {
      final overflow = count - _maxBufferedPings;
      await db.rawDelete(
        'DELETE FROM pending_pings WHERE id IN (SELECT id FROM pending_pings ORDER BY id ASC LIMIT ?)',
        [overflow],
      );
    }
  }

  Future<List<BufferedPing>> peekAll() async {
    final db = _db;
    if (db == null) return [];
    final rows = await db.query('pending_pings', orderBy: 'id ASC');
    return rows
        .map((r) => BufferedPing(
              id: r['id'] as int,
              payload: jsonDecode(r['payload_json'] as String) as Map<String, dynamic>,
              originalTimestampMs: r['original_timestamp_ms'] as int,
            ))
        .toList();
  }

  /// Removes one flushed ping. Deleting per-row (not the whole table at once)
  /// means a connection drop mid-flush leaves the remaining backlog intact.
  Future<void> remove(int id) async {
    await _db?.delete('pending_pings', where: 'id = ?', whereArgs: [id]);
  }
}
