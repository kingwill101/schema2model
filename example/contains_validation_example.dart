import 'package:schemamodeschema/src/generator.dart';

void main() {
  const schema = <String, dynamic>{
    'title': 'GroceryList',
    'type': 'object',
    'properties': {
      'items': {
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

  final dartSource = generator.generate(schema);
  print('--- Generated Dart ---');
  print(dartSource);
}
