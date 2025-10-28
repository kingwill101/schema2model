import 'package:schemamodeschema/src/generator.dart';
import 'package:test/test.dart';

void main() {
  const schema = <String, dynamic>{
    'type': 'object',
    'properties': {
      'name': {'type': 'string', 'minLength': 3},
      'age': {'type': 'integer', 'minimum': 18},
      'status': {'type': 'string', 'const': 'active'},
      'address': {
        'type': 'object',
        'properties': {
          'city': {'type': 'string', 'pattern': r'^[A-Z].*'},
        },
        'required': ['city'],
      },
      'aliases': {
        'type': 'array',
        'items': {'type': 'string', 'maxLength': 5},
      },
      'tags': {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {
            'label': {'type': 'string', 'const': 'x'},
          },
          'required': ['label'],
        },
      },
    },
    'required': ['name', 'age', 'address'],
  };

  group('validation helpers', () {
    test('not emitted when disabled', () {
      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(),
      );
      final generated = generator.generate(schema);

      expect(generated, isNot(contains('void validate(')));
      expect(generator.buildIr(schema).helpers, isEmpty);
    });

    test('emits validate methods with pointer-aware checks', () {
      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(emitValidationHelpers: true),
      );
      final generated = generator.generate(schema);

      expect(generated, contains("void validate({String pointer = ''})"));
      expect(
        generated,
        contains("    final _ptr0 = _appendJsonPointer(pointer, 'address');"),
      );
      expect(generated, contains("_throwValidationError(_ptr0"));
      expect(generated, contains("_appendJsonPointer(pointer, 'city')"));
      expect(generated, contains('class ValidationError implements Exception'));
      expect(generated, contains("_appendJsonPointer(_ptr5, i_p5.toString())"));
      expect(generated, contains("_actualp4 != 'active'"));
    });

    test(
      'multi-file plan exports validation helper and imports it where needed',
      () {
        final generator = SchemaGenerator(
          options: const SchemaGeneratorOptions(emitValidationHelpers: true),
        );
        final ir = generator.buildIr(schema);
        final plan = generator.planMultiFile(ir, baseName: 'validation_sample');

        expect(plan.files.containsKey('validation_error.dart'), isTrue);
        final rootFile = plan.files['root_schema.dart'];
        expect(rootFile, isNotNull);
        expect(rootFile!, contains("import 'validation_error.dart';"));
        expect(
          plan.barrel,
          contains("export '${plan.partsDirectory}/validation_error.dart';"),
        );
      },
    );
  });
}
