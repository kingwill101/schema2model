import 'package:schema2model/schema2model.dart';

void main() {
  const schema = <String, dynamic>{
    'type': 'object',
    'properties': {
      'email': {'type': 'string', 'format': 'email'},
      'website': {'type': 'string', 'format': 'uri'},
    },
    'required': ['email'],
  };

  final generator = SchemaGenerator(
    options: const SchemaGeneratorOptions(
      emitValidationHelpers: true,
      enableFormatAssertions: true,
    ),
  );

  final output = generator.generate(schema);
  print(output);
}
