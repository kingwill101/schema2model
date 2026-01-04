import 'package:schema2model/src/generator.dart';
import 'package:test/test.dart';

void main() {
  group('applicator validation', () {
    test('emits not validation', () {
      const schema = <String, dynamic>{
        'type': 'object',
        'properties': {
          'value': {
            'type': 'string',
            'not': {
              'type': 'string',
              'pattern': '^a',
            },
          },
        },
      };

      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(emitValidationHelpers: true),
      );
      final output = generator.generate(schema);

      expect(output, contains("throwValidationError(_ptr0, 'not'"));
      expect(output, contains('Expected subschema at #/properties/value/not'));
    });

    test('emits allOf validation', () {
      const schema = <String, dynamic>{
        'type': 'object',
        'properties': {
          'value': {
            'type': 'string',
            'allOf': [
              {
                'type': 'string',
                'minLength': 3,
              },
              {
                'type': 'string',
                'pattern': '^a',
              },
            ],
          },
        },
      };

      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(emitValidationHelpers: true),
      );
      final output = generator.generate(schema);

      expect(output, contains("throwValidationError(_ptr0, 'allOf'"));
      expect(output, contains('Expected all subschemas in #/properties/value/allOf'));
    });

    test('emits anyOf validation', () {
      const schema = <String, dynamic>{
        'type': 'object',
        'properties': {
          'value': {
            'type': 'string',
            'anyOf': [
              {
                'type': 'string',
                'minLength': 3,
              },
              {
                'type': 'string',
                'pattern': '^a',
              },
            ],
          },
        },
      };

      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(emitValidationHelpers: true),
      );
      final output = generator.generate(schema);

      expect(output, contains("throwValidationError(_ptr0, 'anyOf'"));
      expect(output, contains('Expected at least one subschema in #/properties/value/anyOf'));
    });

    test('emits oneOf validation', () {
      const schema = <String, dynamic>{
        'type': 'object',
        'properties': {
          'value': {
            'type': 'string',
            'oneOf': [
              {
                'type': 'string',
                'minLength': 3,
              },
              {
                'type': 'string',
                'pattern': '^a',
              },
            ],
          },
        },
      };

      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(emitValidationHelpers: true),
      );
      final output = generator.generate(schema);

      expect(output, contains("throwValidationError(_ptr0, 'oneOf'"));
      expect(output, contains('Expected exactly one subschema in #/properties/value/oneOf'));
    });
  });
}
