part of 'package:schema2model/src/generator.dart';

class SchemaDialect {
  const SchemaDialect._(
    this.uri, {
    required this.defaultVocabularies,
    required this.supportedVocabularies,
    this.aliases = const <String>[],
  });

  final String uri;
  final Map<String, bool> defaultVocabularies;
  final Set<String> supportedVocabularies;
  final List<String> aliases;

  bool supportsVocabulary(String vocabularyUri) {
    return supportedVocabularies.contains(vocabularyUri);
  }

  static const SchemaDialect draft2020_12 = SchemaDialect._(
    'https://json-schema.org/draft/2020-12/schema',
    defaultVocabularies: <String, bool>{
      'https://json-schema.org/draft/2020-12/vocab/core': true,
      'https://json-schema.org/draft/2020-12/vocab/applicator': true,
      'https://json-schema.org/draft/2020-12/vocab/validation': true,
      'https://json-schema.org/draft/2020-12/vocab/unevaluated': true,
      'https://json-schema.org/draft/2020-12/vocab/meta-data': false,
      'https://json-schema.org/draft/2020-12/vocab/format-annotation': false,
      'https://json-schema.org/draft/2020-12/vocab/format-assertion': false,
      'https://json-schema.org/draft/2020-12/vocab/content': false,
    },
    supportedVocabularies: <String>{
      'https://json-schema.org/draft/2020-12/vocab/core',
      'https://json-schema.org/draft/2020-12/vocab/applicator',
      'https://json-schema.org/draft/2020-12/vocab/validation',
      'https://json-schema.org/draft/2020-12/vocab/unevaluated',
      'https://json-schema.org/draft/2020-12/vocab/meta-data',
      'https://json-schema.org/draft/2020-12/vocab/format-annotation',
      'https://json-schema.org/draft/2020-12/vocab/format-assertion',
      'https://json-schema.org/draft/2020-12/vocab/content',
    },
    aliases: <String>[
      'https://json-schema.org/draft/2020-12/meta/core',
      'https://json-schema.org/draft/2020-12',
      'https://json-schema.org/v1/2026',
      'http://json-schema.org/draft-07/schema#',
      'http://json-schema.org/draft-07/schema',
      'http://json-schema.org/draft-07',
    ],
  );

  static const Map<String, SchemaDialect> defaultDialectRegistry =
      <String, SchemaDialect>{
        draft2020_12Uri: draft2020_12,
        'https://json-schema.org/draft/2020-12/meta/core': draft2020_12,
        'https://json-schema.org/draft/2020-12': draft2020_12,
        'https://json-schema.org/v1/2026': draft2020_12,
        'http://json-schema.org/draft-07/schema#': draft2020_12,
        'http://json-schema.org/draft-07/schema': draft2020_12,
        'http://json-schema.org/draft-07': draft2020_12,
      };

  static const String draft2020_12Uri =
      'https://json-schema.org/draft/2020-12/schema';

  static const SchemaDialect latest = draft2020_12;

  static SchemaDialect? lookup(
    String uri,
    Map<String, SchemaDialect> registry,
  ) {
    final trimmed = uri.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    final direct = registry[trimmed];
    if (direct != null) {
      return direct;
    }
    for (final dialect in registry.values) {
      if (dialect.aliases.contains(trimmed)) {
        return dialect;
      }
    }
    return null;
  }
}
