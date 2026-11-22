class Note {
  final String? id;
  String text;
  final DateTime createdAt;
  DateTime entryAt;
  String? entryTimezone;
  final DateTime? updatedAt;
  final DateTime? deletedAt;

  Note({
    this.id,
    required this.text,
    required this.createdAt,
    DateTime? entryAt,
    this.entryTimezone,
    this.updatedAt,
    this.deletedAt,
  }) : entryAt = (entryAt ?? createdAt).toUtc();

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'text': text,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'entryAt': entryAt.toUtc().toIso8601String(),
        if (entryTimezone != null) 'entryTimezone': entryTimezone,
        if (updatedAt != null)
          'updatedAt': updatedAt!.toUtc().toIso8601String(),
        if (deletedAt != null)
          'deletedAt': deletedAt!.toUtc().toIso8601String(),
      };

  factory Note.fromJson(Map<String, dynamic> json) => Note(
        id: json['id'] as String?,
        text: json['text'] as String,
        createdAt: DateTime.parse(json['createdAt']).toUtc(),
        entryAt: json['entryAt'] == null
            ? DateTime.parse(json['createdAt']).toUtc()
            : DateTime.parse(json['entryAt'] as String).toUtc(),
        entryTimezone: json['entryTimezone'] as String?,
        updatedAt: json['updatedAt'] == null
            ? null
            : DateTime.parse(json['updatedAt'] as String).toUtc(),
        deletedAt: json['deletedAt'] == null
            ? null
            : DateTime.parse(json['deletedAt'] as String).toUtc(),
      );
}
