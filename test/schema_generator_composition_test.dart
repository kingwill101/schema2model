import 'package:schema2model/src/generator.dart';
import 'package:test/test.dart';

void main() {
  group('allOf composition', () {
    test('merges allOf compositions into single class', () {
      const schema = <String, dynamic>{
        'title': 'Composite',
        'allOf': [
          {
            'type': 'object',
            'properties': {
              'base': {'type': 'string'},
              'shared': {'type': 'string'},
            },
            'required': ['base'],
          },
          {
            'type': 'object',
            'properties': {
              'shared': {
                'type': 'string',
                'description': 'Shared description.',
              },
              'extra': {'type': 'integer'},
            },
            'required': ['shared'],
          },
        ],
      };

      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(),
      );
      final ir = generator.buildIr(schema);

      expect(ir.classes, hasLength(1));
      final klass = ir.rootClass;
      final properties = {
        for (final prop in klass.properties) prop.jsonName: prop,
      };
      expect(properties.keys, containsAll(<String>['base', 'shared', 'extra']));
      expect(properties['base']!.isRequired, isTrue);
      expect(properties['shared']!.isRequired, isTrue);
      expect(properties['shared']!.description, 'Shared description.');
      expect(properties['extra']!.typeRef, isA<PrimitiveTypeRef>());
    });

    test('throws when allOf members conflict on property type', () {
      const schema = <String, dynamic>{
        'title': 'Conflicting',
        'allOf': [
          {
            'type': 'object',
            'properties': {
              'value': {'type': 'string'},
            },
          },
          {
            'type': 'object',
            'properties': {
              'value': {'type': 'integer'},
            },
          },
        ],
      };

      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(),
      );

      expect(
        () => generator.buildIr(schema),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('Conflicting types for property "value"'),
          ),
        ),
      );
    });
  });
}
