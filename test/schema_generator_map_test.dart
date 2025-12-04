import 'package:schema2model/src/generator.dart';
import 'package:test/test.dart';

void main() {
  group('map support', () {
    test('emits typed map for additionalProperties schema', () {
      const schema = <String, dynamic>{
        'title': 'Extras',
        'type': 'object',
        'properties': {
          'known': {'type': 'string'},
        },
        'additionalProperties': {'type': 'integer'},
      };

      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(),
      );
      final generated = generator.generate(schema);

      expect(
        generated,
        contains('final Map<String, int>? additionalProperties;'),
      );
      expect(
        generated,
        contains('final additionalPropertiesMap = <String, int>{};'),
      );
      expect(
        generated,
        contains('additionalProperties!.forEach((key, value) {'),
      );
      expect(
        generated,
        contains('additionalProperties: additionalPropertiesValue,'),
      );
    });

    test('throws when additionalProperties is false and extras exist', () {
      const schema = <String, dynamic>{
        'title': 'Strict',
        'type': 'object',
        'additionalProperties': false,
      };

      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(),
      );
      final generated = generator.generate(schema);

      expect(
        generated,
        contains(
          "final unexpected = unmatched.keys.join(', ');",
        ),
      );
      expect(
        generated,
        contains(
          "throw ArgumentError('Unexpected additional properties: \$unexpected');",
        ),
      );
    });

    test('patternProperties picks uniform value type', () {
      const schema = <String, dynamic>{
        'title': 'Patterned',
        'type': 'object',
        'patternProperties': {
          '^s_': {'type': 'string'},
          '^t_': {'type': 'string'},
        },
      };

      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(),
      );
      final generated = generator.generate(schema);

      expect(
        generated,
        contains('final Map<String, String>? patternProperties;'),
      );
      expect(
        generated,
        contains('final patternPropertiesMap = <String, String>{};'),
      );
      expect(generated, contains('RegExp(\'^s_\').hasMatch(key)'));
    });

    test('mixed patternProperties fall back to dynamic map', () {
      const schema = <String, dynamic>{
        'title': 'MixedPattern',
        'type': 'object',
        'patternProperties': {
          '^s_': {'type': 'string'},
          '^o_': {
            'type': 'object',
            'properties': {
              'value': {'type': 'number'},
            },
          },
        },
      };

      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(),
      );
      final generated = generator.generate(schema);

      expect(
        generated,
        contains('final Map<String, dynamic>? patternProperties;'),
      );
      expect(generated, contains('patternProperties: patternPropertiesValue,'));
    });
  });
}
