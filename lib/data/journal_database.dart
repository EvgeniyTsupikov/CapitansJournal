import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../models/note.dart';

/// Drift-backed persistence for active journal notes.
///
/// The SQL schema is intentionally declared here instead of generated so that
/// this storage layer can be introduced without generated source files.
class JournalDatabase extends GeneratedDatabase {
  JournalDatabase({QueryExecutor? executor})
      : super(executor ?? driftDatabase(name: 'capitans_journal'));

  @override
  int get schemaVersion => 1;

  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];

  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => const [];

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (_) async {
          await customStatement('''
            CREATE TABLE active_notes (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              text TEXT NOT NULL,
              created_at INTEGER NOT NULL,
              is_utc INTEGER NOT NULL DEFAULT 0
            )
          ''');
          await customStatement('''
            CREATE TABLE app_metadata (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
            )
          ''');
          await customStatement(
            'CREATE INDEX active_notes_created_at_idx '
            'ON active_notes(created_at DESC)',
          );
        },
      );

  /// Returns active notes in newest-first order, matching the notes screen.
  Future<List<Note>> getActiveNotes() async {
    final rows = await customSelect(
      'SELECT text, created_at, is_utc FROM active_notes '
      'ORDER BY created_at DESC, id DESC',
    ).get();

    return rows
        .map(
          (row) => Note(
            text: row.read<String>('text'),
            createdAt: DateTime.fromMillisecondsSinceEpoch(
              row.read<int>('created_at'),
              isUtc: row.read<int>('is_utc') == 1,
            ),
          ),
        )
        .toList(growable: false);
  }

  /// Inserts a note and returns its SQLite row id.
  Future<int> insertActiveNote(Note note) {
    return customInsert(
      'INSERT INTO active_notes (text, created_at, is_utc) VALUES (?, ?, ?)',
      variables: [
        Variable<String>(note.text),
        Variable<int>(note.createdAt.millisecondsSinceEpoch),
        Variable<int>(note.createdAt.isUtc ? 1 : 0),
      ],
    );
  }

  /// Replaces all active notes atomically, useful for bulk edits and migration.
  Future<void> replaceActiveNotes(Iterable<Note> notes) async {
    await transaction(() async {
      await customStatement('DELETE FROM active_notes');
      for (final note in notes) {
        await insertActiveNote(note);
      }
    });
  }

  /// Imports the former `notes_json` SharedPreferences value exactly once.
  ///
  /// The import marker and note inserts share a transaction, so malformed data
  /// or an insert error leaves the database unchanged and safe to retry.
  Future<int> importLegacyNotes(String? legacyJson) {
    return transaction(() async {
      final marker = await customSelect(
        'SELECT value FROM app_metadata WHERE key = ?',
        variables: [Variable<String>('legacy_notes_imported')],
      ).getSingleOrNull();
      if (marker != null) return 0;

      var importedCount = 0;
      if (legacyJson != null && legacyJson.trim().isNotEmpty) {
        final decoded = jsonDecode(legacyJson);
        if (decoded is! List) {
          throw const FormatException('Legacy notes data must be a JSON list.');
        }
        for (final item in decoded) {
          if (item is! Map) {
            throw const FormatException('Legacy note entry must be a JSON object.');
          }
          final note = Note.fromJson(Map<String, dynamic>.from(item));
          await insertActiveNote(note);
          importedCount++;
        }
      }

      await customInsert(
        'INSERT INTO app_metadata (key, value) VALUES (?, ?)',
        variables: [
          Variable<String>('legacy_notes_imported'),
          Variable<String>('true'),
        ],
      );
      return importedCount;
    });
  }
}
