import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:uuid/uuid.dart';

import '../models/note.dart';

/// Drift-backed persistence for active journal entries.
class JournalDatabase extends GeneratedDatabase {
  JournalDatabase({QueryExecutor? executor, Uuid? uuid})
      : _uuid = uuid ?? const Uuid(),
        super(executor ?? driftDatabase(name: 'capitans_journal'));

  final Uuid _uuid;

  static const String legacyNotesKey = 'notes_json';
  static const String legacyMigrationMarker = 'legacy_notes_migration_completed';

  @override
  int get schemaVersion => 2;

  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];

  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => const [];

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (_) async {
          await _createSchema();
        },
        onUpgrade: (Migrator m, int from, int to) async {
          await customStatement('CREATE TABLE IF NOT EXISTS app_metadata ('
              'key TEXT PRIMARY KEY, value TEXT NOT NULL)');

          if (from < 2) {
            await customStatement('DROP TABLE IF EXISTS active_notes_new');
            await customStatement('''
              CREATE TABLE active_notes_new (
                id TEXT PRIMARY KEY,
                created_at_utc INTEGER NOT NULL,
                entry_at_utc INTEGER NOT NULL,
                entry_timezone TEXT,
                text TEXT NOT NULL,
                updated_at_utc INTEGER,
                deleted_at_utc INTEGER
              )
            ''');

            await customStatement('''
              INSERT INTO active_notes_new
                (id, created_at_utc, entry_at_utc, entry_timezone, text)
              SELECT lower(hex(randomblob(16))),
                     created_at,
                     created_at,
                     NULL,
                     text
              FROM active_notes
            ''');

            await customStatement('DROP TABLE active_notes');
            await customStatement('ALTER TABLE active_notes_new RENAME TO active_notes');
          }

          await _createIndexes();
        },
      );

  Future<void> _createSchema() async {
    await customStatement('''
      CREATE TABLE active_notes (
        id TEXT PRIMARY KEY,
        created_at_utc INTEGER NOT NULL,
        entry_at_utc INTEGER NOT NULL,
        entry_timezone TEXT,
        text TEXT NOT NULL,
        updated_at_utc INTEGER,
        deleted_at_utc INTEGER
      )
    ''');
    await customStatement('''
      CREATE TABLE app_metadata (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    await _createIndexes();
  }

  Future<void> _createIndexes() async {
    await customStatement(
      'CREATE INDEX IF NOT EXISTS active_notes_entry_at_idx '
      'ON active_notes(entry_at_utc)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS active_notes_created_at_idx '
      'ON active_notes(created_at_utc)',
    );
  }

  String _newUuidV7() => _uuid.v7();

  int _utcMilliseconds(DateTime value) => value.toUtc().millisecondsSinceEpoch;

  Future<List<Note>> getActiveNotesForMonth(DateTime month) async {
    final start = DateTime.utc(month.year, month.month, 1);
    final end = month.month == 12
        ? DateTime.utc(month.year + 1, 1, 1)
        : DateTime.utc(month.year, month.month + 1, 1);

    try {
      final rows = await customSelect(
        'SELECT id, created_at_utc, entry_at_utc, entry_timezone, text, '
        'updated_at_utc, deleted_at_utc FROM active_notes '
        'WHERE deleted_at_utc IS NULL '
        'AND entry_at_utc >= ? AND entry_at_utc < ? '
        'ORDER BY entry_at_utc DESC, created_at_utc DESC, id ASC',
        variables: [
          Variable<int>(_utcMilliseconds(start)),
          Variable<int>(_utcMilliseconds(end)),
        ],
      ).get();

      return rows.map(_noteFromRow).toList(growable: false);
    } catch (error) {
      throw JournalStorageException('Не удалось загрузить записи за месяц', error);
    }
  }

  Note _noteFromRow(QueryRow row) {
    final updated = row.readNullable<int>('updated_at_utc');
    final deleted = row.readNullable<int>('deleted_at_utc');
    return Note(
      id: row.read<String>('id'),
      text: row.read<String>('text'),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        row.read<int>('created_at_utc'),
        isUtc: true,
      ),
      entryAt: DateTime.fromMillisecondsSinceEpoch(
        row.read<int>('entry_at_utc'),
        isUtc: true,
      ),
      entryTimezone: row.readNullable<String>('entry_timezone'),
      updatedAt: updated == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(updated, isUtc: true),
      deletedAt: deleted == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(deleted, isUtc: true),
    );
  }

  Future<Note> createActiveNote({
    required String text,
    required DateTime entryAt,
    String? entryTimezone,
    DateTime? createdAt,
  }) async {
    final now = DateTime.now().toUtc();
    final factCreatedAt = (createdAt ?? now).toUtc();
    final cleanText = text.trim();
    if (cleanText.isEmpty) {
      throw const JournalStorageException('Текст записи не может быть пустым');
    }

    final note = Note(
      id: _newUuidV7(),
      text: cleanText,
      createdAt: factCreatedAt,
      entryAt: entryAt.toUtc(),
      entryTimezone: entryTimezone,
      updatedAt: null,
      deletedAt: null,
    );

    try {
      await customInsert(
        'INSERT INTO active_notes '
        '(id, created_at_utc, entry_at_utc, entry_timezone, text, updated_at_utc, deleted_at_utc) '
        'VALUES (?, ?, ?, ?, ?, NULL, NULL)',
        variables: [
          Variable<String>(note.id!),
          Variable<int>(_utcMilliseconds(note.createdAt)),
          Variable<int>(_utcMilliseconds(note.entryAt)),
          Variable<String>.withNullable(note.entryTimezone),
          Variable<String>(note.text),
        ],
      );
      return note;
    } catch (error) {
      throw JournalStorageException('Не удалось создать запись', error);
    }
  }

  Future<void> updateActiveNoteText(String id, String text) async {
    final cleanText = text.trim();
    if (cleanText.isEmpty) {
      throw const JournalStorageException('Текст записи не может быть пустым');
    }

    try {
      await customUpdate(
        'UPDATE active_notes SET text = ?, updated_at_utc = ? '
        'WHERE id = ? AND deleted_at_utc IS NULL',
        variables: [
          Variable<String>(cleanText),
          Variable<int>(_utcMilliseconds(DateTime.now().toUtc())),
          Variable<String>(id),
        ],
      );
    } catch (error) {
      throw JournalStorageException('Не удалось изменить текст записи', error);
    }
  }

  Future<void> moveActiveNote(
    String id,
    DateTime newEntryAt, {
    String? entryTimezone,
  }) async {
    try {
      await customUpdate(
        'UPDATE active_notes SET entry_at_utc = ?, entry_timezone = ?, '
        'updated_at_utc = ? WHERE id = ? AND deleted_at_utc IS NULL',
        variables: [
          Variable<int>(_utcMilliseconds(newEntryAt.toUtc())),
          Variable<String>.withNullable(entryTimezone),
          Variable<int>(_utcMilliseconds(DateTime.now().toUtc())),
          Variable<String>(id),
        ],
      );
    } catch (error) {
      throw JournalStorageException('Не удалось перенести запись', error);
    }
  }

  Future<void> deleteActiveNote(String id) async {
    try {
      await customUpdate(
        'UPDATE active_notes SET deleted_at_utc = ? '
        'WHERE id = ? AND deleted_at_utc IS NULL',
        variables: [
          Variable<int>(_utcMilliseconds(DateTime.now().toUtc())),
          Variable<String>(id),
        ],
      );
    } catch (error) {
      throw JournalStorageException('Не удалось удалить запись', error);
    }
  }

  Future<int> migrateLegacyNotes(String? legacyJson) async {
    return transaction(() async {
      final marker = await customSelect(
        'SELECT value FROM app_metadata WHERE key = ?',
        variables: [Variable<String>(legacyMigrationMarker)],
      ).getSingleOrNull();
      if (marker != null) return 0;

      if (legacyJson == null || legacyJson.trim().isEmpty) {
        await _markMigrationCompleted();
        return 0;
      }

      try {
        final decoded = jsonDecode(legacyJson);
        if (decoded is! List) {
          throw const FormatException('Ожидается JSON-массив записей.');
        }

        var importedCount = 0;
        for (final item in decoded) {
          if (item is! Map) {
            throw const FormatException('Элемент записи должен быть объектом.');
          }

          final legacy = Map<String, dynamic>.from(item);
          final text = legacy['text'];
          final oldCreatedAt = legacy['createdAt'];
          if (text is! String || text.trim().isEmpty || oldCreatedAt is! String) {
            throw const FormatException('Устаревшая запись не содержит text/createdAt.');
          }

          final approximateAt = DateTime.parse(oldCreatedAt).toUtc();
          await customInsert(
            'INSERT OR IGNORE INTO active_notes '
            '(id, created_at_utc, entry_at_utc, entry_timezone, text, updated_at_utc, deleted_at_utc) '
            'VALUES (?, ?, ?, NULL, ?, NULL, NULL)',
            variables: [
              Variable<String>(_newUuidV7()),
              Variable<int>(_utcMilliseconds(approximateAt)),
              Variable<int>(_utcMilliseconds(approximateAt)),
              Variable<String>(text.trim()),
            ],
          );
          importedCount++;
        }

        // Marker is written only after every legacy row has been inserted.
        await _markMigrationCompleted();
        return importedCount;
      } catch (error) {
        throw JournalStorageException(
          'Миграция старых данных не завершена; JSON сохранён',
          error,
        );
      }
    });
  }

  Future<void> _markMigrationCompleted() async {
    await customInsert(
      'INSERT OR REPLACE INTO app_metadata (key, value) VALUES (?, ?)',
      variables: [
        Variable<String>(legacyMigrationMarker),
        Variable<String>('true'),
      ],
    );
  }
}

class JournalStorageException implements Exception {
  const JournalStorageException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => 'JournalStorageException: $message${cause == null ? '' : ' ($cause)'}';
}
