import 'package:schema2model/src/generator.dart';
import 'package:test/test.dart';

void main() {
  group('unevaluatedProperties', () {
    test('collects typed map when schema provided', () {
      const schema = <String, dynamic>{
        'type': 'object',
        'properties': {
          'known': {'type': 'string'},
        },
        'unevaluatedProperties': {'type': 'integer'},
      };

      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(emitValidationHelpers: true),
      );
      final ir = generator.buildIr(schema);
      final root = ir.rootClass;

      final field = root.unevaluatedPropertiesField;
      expect(field, isNotNull);
      expect(field!.valueType, isA<PrimitiveTypeRef>());
      expect(
        field.valueType.dartType(),
        equals(const PrimitiveTypeRef('int').dartType()),
      );

      final generated = generator.generate(schema);
      expect(
        generated,
        contains('final Map<String, int>? ${field.fieldName};'),
      );
      expect(generated, contains('Map<String, int>? ${field.fieldName}Value;'));
    });

    test('sets disallow flag when keyword is false', () {
      const schema = <String, dynamic>{
        'type': 'object',
        'properties': {
          'known': {'type': 'string'},
        },
        'unevaluatedProperties': false,
      };

      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(emitValidationHelpers: true),
      );
      final ir = generator.buildIr(schema);
      final root = ir.rootClass;

      expect(root.unevaluatedPropertiesField, isNull);
      expect(root.disallowUnevaluatedProperties, isTrue);

      final generated = generator.generate(schema);
      expect(generated, contains('Unexpected unevaluated properties'));
    });
  });

  group('unevaluatedItems', () {
    test('captures array metadata for downstream validation', () {
      const schema = <String, dynamic>{
        'type': 'object',
        'properties': {
          'values': {
            'type': 'array',
            'prefixItems': [
              {'type': 'string'},
            ],
            'unevaluatedItems': {'type': 'integer'},
          },
        },
      };

      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(emitValidationHelpers: true),
      );
      final ir = generator.buildIr(schema);
      final root = ir.rootClass;
      final values = root.properties.singleWhere(
        (prop) => prop.jsonName == 'values',
      );

      final typeRef = values.typeRef;
      expect(typeRef, isA<ListTypeRef>());
      final list = typeRef as ListTypeRef;
      expect(list.prefixItemTypes, hasLength(1));
      expect(list.prefixItemTypes.first, isA<PrimitiveTypeRef>());
      expect(list.allowAdditionalItems, isTrue);
      expect(list.itemsEvaluatesAdditionalItems, isFalse);
      expect(list.unevaluatedItemsType, isA<PrimitiveTypeRef>());
      expect(list.disallowUnevaluatedItems, isFalse);

      generator.generate(schema);
    });
  });

  group('contains', () {
    test('enforces min and max matches', () {
      const schema = <String, dynamic>{
        'type': 'object',
        'properties': {
          'values': {
            'type': 'array',
            'contains': {'type': 'string'},
            'minContains': 2,
            'maxContains': 3,
          },
        },
      };

      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(emitValidationHelpers: true),
      );
      final generated = generator.generate(schema);

      expect(
        generated,
        contains('Expected at least 2 item(s) matching "contains"'),
      );
      expect(
        generated,
        contains('Expected at most 3 item(s) matching "contains"'),
      );
    });

    test('promotes element type when contains schema is provided', () {
      const schema = <String, dynamic>{
        'type': 'object',
        'properties': {
          'values': {
            'type': 'array',
            'contains': {'type': 'string'},
          },
        },
      };

      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(emitValidationHelpers: true),
      );
      final ir = generator.buildIr(schema);
      final property = ir.rootClass.properties.singleWhere(
        (prop) => prop.jsonName == 'values',
      );
      expect(property.dartType, equals('List<String>?'));
    });

    test('reuses strongly typed models for object contains schemas', () {
      const schema = <String, dynamic>{
        'type': 'object',
        'properties': {
          'values': {
            'type': 'array',
            'contains': {
              'type': 'object',
              'properties': {
                'title': {'type': 'string'},
              },
              'required': ['title'],
            },
          },
        },
      };

      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(emitValidationHelpers: true),
      );
      final ir = generator.buildIr(schema);
      final property = ir.rootClass.properties.singleWhere(
        (prop) => prop.jsonName == 'values',
      );
      final listRef = property.typeRef as ListTypeRef;
      final itemRef = listRef.itemType as ObjectTypeRef;
      expect(property.dartType, equals('List<RootSchemaValue>?'));
      expect(itemRef.spec.name, equals('RootSchemaValue'));
      expect(itemRef.spec.name, isNot(contains('Contains')));

      final generated = generator.generate(schema);
      expect(generated, contains('class ${itemRef.spec.name}'));
    });
  });

  group('dependent constraints', () {
    test('dependentRequired enforces secondary presence metadata', () {
      const schema = <String, dynamic>{
        'type': 'object',
        'properties': {
          'primary': {'type': 'string'},
          'secondary': {'type': 'string'},
        },
        'dependentRequired': {
          'primary': ['secondary'],
        },
      };

      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(emitValidationHelpers: true),
      );
      final ir = generator.buildIr(schema);
      expect(ir.rootClass.dependentRequired, contains('primary'));
      expect(ir.rootClass.dependentRequired['primary'], contains('secondary'));

      final output = generator.generate(schema);
      expect(
        output,
        contains(
          'Property "secondary" must be present when "primary" is defined.',
        ),
      );
    });

    test('dependentSchemas apply additional validation and disallow', () {
      const schema = <String, dynamic>{
        'type': 'object',
        'properties': {
          'config': {
            'type': 'object',
            'properties': {
              'channel': {'type': 'string'},
            },
            'additionalProperties': false,
          },
          'mode': {'type': 'string'},
        },
        'dependentSchemas': {
          'config': {
            'properties': {
              'channel': {
                'type': 'string',
                'enum': ['alpha', 'beta'],
              },
            },
          },
          'mode': false,
        },
      };

      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(emitValidationHelpers: true),
      );
      final ir = generator.buildIr(schema);
      expect(ir.rootClass.dependentSchemas, contains('config'));
      expect(ir.rootClass.dependentSchemas, contains('mode'));
      expect(ir.rootClass.dependentSchemas['mode']!.disallow, isTrue);

      final output = generator.generate(schema);
      expect(output, contains('RootSchemaConfigDependency.fromJson'));
      expect(
        output,
        contains('Property "mode" is not allowed in this context.'),
      );
    });
  });

  group('propertyNames', () {
    test('boolean false schema forbids all property names', () {
      const schema = <String, dynamic>{
        'type': 'object',
        'properties': {
          'disallowed': {'type': 'string'},
        },
        'propertyNames': false,
      };

      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(emitValidationHelpers: true),
      );
      final output = generator.generate(schema);

      expect(output, contains('throwValidationError(_ptr0, \'propertyNames\''));
    });

    test('pattern applies to additional properties', () {
      const schema = <String, dynamic>{
        'type': 'object',
        'additionalProperties': {'type': 'integer'},
        'propertyNames': {'pattern': '^[a-z]+\$'},
      };

      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(emitValidationHelpers: true),
      );
      final output = generator.generate(schema);

      expect(output, contains(r"RegExp('^[a-z]+\$')"));
      expect(
        output,
        contains('throwValidationError(itemPointer, \'propertyNames\''),
      );
    });
  });

  group('annotation capture', () {
    test('collects unevaluatedProperties values when schema provided', () {
      const schema = <String, dynamic>{
        'type': 'object',
        'properties': {
          'known': {'type': 'string'},
        },
        'patternProperties': {
          '^foo': {'type': 'integer'},
        },
        'unevaluatedProperties': {'type': 'boolean'},
      };

      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(emitValidationHelpers: true),
      );
      final output = generator.generate(schema);

      expect(
        output,
        contains('final Map<String, bool>? unevaluatedProperties;'),
      );
      expect(
        output,
        contains('Map<String, bool>? unevaluatedPropertiesValue;'),
      );
      expect(
        output,
        contains("unevaluatedProperties: unevaluatedPropertiesValue"),
      );
    });

    test('collects unevaluatedItems into typed list entries', () {
      const schema = <String, dynamic>{
        'type': 'object',
        'properties': {
          'values': {
            'type': 'array',
            'prefixItems': [
              {'type': 'string'},
            ],
            'items': {'type': 'integer'},
            'contains': {'minimum': 0},
            'unevaluatedItems': {'type': 'boolean'},
          },
        },
      };

      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(emitValidationHelpers: true),
      );
      final output = generator.generate(schema);

      expect(output, contains('final _evaluatedp0 = List<bool>.filled'));
      expect(output, contains('throwValidationError(_ptr0, \'contains\''));
    });
  });

  group('boolean schemas', () {
    test('true schema short-circuits validation generation', () {
      const schema = <String, dynamic>{'type': 'array', 'items': true};
      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(emitValidationHelpers: true),
      );
      final output = generator.generate(schema);
      expect(
        output,
        contains(
          "  void validate({String pointer = '', ValidationContext? context}) {}\n",
        ),
      );
    });

    test('false schema emits validation failure', () {
      const schema = <String, dynamic>{
        'type': 'object',
        'properties': {'impossible': false},
      };

      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(emitValidationHelpers: true),
      );
      final output = generator.generate(schema);

      expect(
        output,
        contains(
          'Schema at #/properties/impossible forbids property "impossible".',
        ),
      );
    });
  });
}
