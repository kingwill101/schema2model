import 'package:schema2model/schema2model.dart';
import 'package:test/test.dart';

void main() {
  group('Type array unions', () {
    test('emits sealed class for simple primitive unions', () {
      final schema = {
        '\$schema': 'https://json-schema.org/draft/2020-12/schema',
        'type': 'object',
        'properties': {
          'value': {
            'type': ['string', 'number'],
          },
        },
      };

      final generator = SchemaGenerator(options: const SchemaGeneratorOptions());
      final code = generator.generate(schema);

      expect(code, contains('sealed class Value'));
    });

    test('treats type arrays with null as nullable fields', () {
      final schema = {
        '\$schema': 'https://json-schema.org/draft/2020-12/schema',
        'type': 'object',
        'properties': {
          'value': {
            'type': ['string', 'null'],
          },
        },
      };

      final generator = SchemaGenerator(options: const SchemaGeneratorOptions());
      final code = generator.generate(schema);

      expect(code, contains('final String? value;'));
    });

    test('adds type validation when constraints prevent union emission', () {
      final schema = {
        '\$schema': 'https://json-schema.org/draft/2020-12/schema',
        'type': 'object',
        'properties': {
          'value': {
            'type': ['string', 'number'],
            'minLength': 2,
          },
        },
      };

      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(emitValidationHelpers: true),
      );
      final code = generator.generate(schema);

      expect(
        code,
        contains('Expected value to match one of the allowed types [string, number].'),
      );
    });
  });
}
