import 'package:schema2model/src/generator.dart';
import 'package:test/test.dart';

void main() {
  SchemaGenerator createGenerator({
    SchemaGeneratorOptions? options,
  }) {
    return SchemaGenerator(
      options: options ??
          const SchemaGeneratorOptions(
            sourcePath: 'memory://schema.json',
          ),
    );
  }

  group('dialect detection', () {
    test('accepts draft-07 alias as supported dialect', () {
      final schema = <String, dynamic>{
        r'$schema': 'http://json-schema.org/draft-07/schema#',
        'type': 'object',
        'properties': <String, dynamic>{
          'name': <String, dynamic>{'type': 'string'},
        },
      };

      final generator = createGenerator();
      expect(() => generator.buildIr(schema), returnsNormally);
    });

    test('throws when schema declares unsupported dialect', () {
      final schema = <String, dynamic>{
        r'$schema': 'https://example.com/custom-dialect',
        'type': 'object',
      };
      final generator = createGenerator();

      expect(
        () => generator.buildIr(schema),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('Unsupported JSON Schema dialect'),
          ),
        ),
      );
    });

    test('throws when required vocabulary is not supported', () {
      final schema = <String, dynamic>{
        r'$schema': SchemaDialect.draft2020_12Uri,
        r'$vocabulary': <String, bool>{
          'https://example.com/custom-vocab': true,
        },
        'type': 'string',
      };
      final generator = createGenerator();

      expect(
        () => generator.buildIr(schema),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('Vocabulary https://example.com/custom-vocab is required'),
          ),
        ),
      );
    });

    test('requires explicit dialect when default is disabled', () {
      final schema = <String, dynamic>{
        'type': 'object',
      };
      final generator = createGenerator(
        options: const SchemaGeneratorOptions(
          sourcePath: 'memory://schema.json',
          defaultDialect: null,
        ),
      );

      expect(
        () => generator.buildIr(schema),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('No JSON Schema dialect declared'),
          ),
        ),
      );
    });
  });
}
