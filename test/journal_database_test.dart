import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_test_logger/data/journal_database.dart';
import 'package:flutter_test_logger/models/note.dart';

void main() {
  late JournalDatabase database;

  setUp(() {
    database = JournalDatabase(executor: NativeDatabase.memory());
  });

  tearDown(() async {
    await database.close();
  });

  test('create uses UUID and preserves createdAt independently from entryAt', () async {
    final createdAt = DateTime.utc(2026, 1, 1, 12);
    final entryAt = DateTime.utc(2026, 2, 3, 9);

    final note = await database.createActiveNote(
      text: 'New entry',
      createdAt: createdAt,
      entryAt: entryAt,
      entryTimezone: 'UTC',
    );

    expect(note.id, isNotNull);
    expect(RegExp(r'^\d{4}').hasMatch(note.id!), isFalse);
    expect(note.id!.length, 36);
    expect(note.createdAt, createdAt);
    expect(note.entryAt, entryAt);
  });

  test('loads only active notes for selected UTC month', () async {
    await database.createActiveNote(
      text: 'January',
      createdAt: DateTime.utc(2026, 1, 1),
      entryAt: DateTime.utc(2026, 1, 20),
    );
    await database.createActiveNote(
      text: 'February',
      createdAt: DateTime.utc(2026, 1, 2),
      entryAt: DateTime.utc(2026, 2, 1),
    );

    final january = await database.getActiveNotesForMonth(DateTime.utc(2026, 1));
    expect(january.map((note) => note.text), ['January']);
  });

  test('edit text and move entry preserve immutable createdAt', () async {
    final createdAt = DateTime.utc(2026, 1, 1, 10);
    final note = await database.createActiveNote(
      text: 'Before',
      createdAt: createdAt,
      entryAt: DateTime.utc(2026, 1, 2),
    );

    await database.updateActiveNoteText(note.id!, 'After');
    await database.moveActiveNote(
      note.id!,
      DateTime.utc(2026, 3, 4, 8),
      entryTimezone: 'UTC',
    );

    final moved = (await database.getActiveNotesForMonth(DateTime.utc(2026, 3))).single;
    expect(moved.text, 'After');
    expect(moved.createdAt, createdAt);
    expect(moved.entryAt, DateTime.utc(2026, 3, 4, 8));
  });

  test('deleted notes disappear from monthly reads', () async {
    final note = await database.createActiveNote(
      text: 'Delete me',
      createdAt: DateTime.utc(2026, 4, 1),
      entryAt: DateTime.utc(2026, 4, 1),
    );

    await database.deleteActiveNote(note.id!);

    expect(await database.getActiveNotesForMonth(DateTime.utc(2026, 4)), isEmpty);
  });

  test('legacy migration copies old createdAt to both fields exactly once', () async {
    const legacyJson =
        '[{"text":"Legacy","createdAt":"2026-01-02T03:04:05.000Z"}]';

    expect(await database.migrateLegacyNotes(legacyJson), 1);
    expect(await database.migrateLegacyNotes(legacyJson), 0);

    final migrated = (await database.getActiveNotesForMonth(DateTime.utc(2026, 1))).single;
    expect(migrated.createdAt, DateTime.utc(2026, 1, 2, 3, 4, 5));
    expect(migrated.entryAt, migrated.createdAt);
  });

  test('legacy JSON remains unmarked when migration data is malformed', () async {
    const malformed = '[{"text":"Missing date"}]';

    await expectLater(
      database.migrateLegacyNotes(malformed),
      throwsA(isA<JournalStorageException>()),
    );
    expect(await database.migrateLegacyNotes(malformed), throwsA(isA<JournalStorageException>()));
  });
}
