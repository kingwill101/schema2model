import 'package:schema2model/src/generator.dart';

void main() {
  const schema = <String, dynamic>{
    'title': 'Settings',
    'type': 'object',
    'properties': {
      'enabled': {'type': 'boolean'},
    },
    'unevaluatedProperties': false,
  };

  final generator = SchemaGenerator(options: const SchemaGeneratorOptions());

  final dartSource = generator.generate(schema);
  print('--- Generated Dart ---');
  print(dartSource);
}
