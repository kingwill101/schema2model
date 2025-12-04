import 'package:schema2model/src/generator.dart';
import 'package:test/test.dart';

void main() {
  test('default values appear in constructors', () {
    const schema = {
      'type': 'object',
      'properties': {
        'flag': {
          'type': 'boolean',
          'default': true,
        },
        'items': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'name': {'type': 'string'},
              'done': {
                'type': 'boolean',
                'default': false,
              },
            },
            'required': ['name'],
          },
        },
      },
    };

    final generator = SchemaGenerator(
      options: const SchemaGeneratorOptions(),
    );
    final output = generator.generate(schema);

    expect(
      output,
      contains('const RootSchema({\n    this.flag = true,\n    this.items,\n  });'),
    );
    expect(
      output,
      contains("final flag = (json['flag'] as bool?) ?? true;"),
    );
    expect(
      output,
      contains('const RootSchemaItem({\n    this.done = false,\n    required this.name,\n  });'),
    );
    expect(
      output,
      contains("final done = (json['done'] as bool?) ?? false;"),
    );
  });
}
