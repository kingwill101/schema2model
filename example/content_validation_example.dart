import 'package:schema2model/schema2model.dart';

void main() {
  const schema = <String, dynamic>{
    'type': 'object',
    'properties': {
      'payload': {
        'type': 'string',
        'contentMediaType': 'application/json',
        'contentEncoding': 'base64',
        'contentSchema': {
          'type': 'object',
          'properties': {
            'name': {'type': 'string'},
            'age': {'type': 'integer', 'minimum': 0},
          },
          'required': ['name'],
        },
      },
    },
    'required': ['payload'],
  };

  final generator = SchemaGenerator(
    options: const SchemaGeneratorOptions(
      emitValidationHelpers: true,
      enableContentKeywords: true,
      enableContentValidation: true,
    ),
  );

  final output = generator.generate(schema);
  print(output);
}
