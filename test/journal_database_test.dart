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

  test('inserts and reads active notes newest first', () async {
    final older = Note(text: 'Older', createdAt: DateTime(2026, 1, 1));
    final newer = Note(text: 'Newer', createdAt: DateTime(2026, 1, 2));

    await database.insertActiveNote(older);
    await database.insertActiveNote(newer);

    final notes = await database.getActiveNotes();
    expect(notes.map((note) => note.text), ['Newer', 'Older']);
    expect(notes.last.createdAt, older.createdAt);
  });

  test('replaces notes atomically', () async {
    await database.insertActiveNote(
      Note(text: 'Old', createdAt: DateTime(2026, 1, 1)),
    );
    final replacement = Note(text: 'Replacement', createdAt: DateTime(2026, 1, 2));

    await database.replaceActiveNotes([replacement]);

    final notes = await database.getActiveNotes();
    expect(notes, hasLength(1));
    expect(notes.single.text, 'Replacement');
  });

  test('imports legacy JSON once and preserves UTC timestamps', () async {
    const legacyJson =
        '[{"text":"Legacy","createdAt":"2026-01-02T03:04:05.000Z"}]';

    expect(await database.importLegacyNotes(legacyJson), 1);
    expect(await database.importLegacyNotes(legacyJson), 0);

    final note = (await database.getActiveNotes()).single;
    expect(note.text, 'Legacy');
    expect(note.createdAt.isUtc, isTrue);
    expect(note.createdAt.toIso8601String(), '2026-01-02T03:04:05.000Z');
  });
}
