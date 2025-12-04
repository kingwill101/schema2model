import 'package:schema2model/src/generator.dart';

void log(String message) {
  // ignore: avoid_print
  print('[debug] $message');
}

void main() {
  final schema = <String, dynamic>{
    r'$id': 'https://example.com/root.json',
    'type': 'object',
    'properties': <String, dynamic>{
      'step': <String, dynamic>{
        r'$anchor': 'step',
        'type': 'string',
      },
      'child': <String, dynamic>{
        r'$dynamicAnchor': 'node',
        'type': 'object',
        'properties': <String, dynamic>{
          'value': <String, dynamic>{'type': 'integer'},
        },
      },
      'useAnchor': <String, dynamic>{r'$ref': '#step'},
      'useDynamic': <String, dynamic>{r'$dynamicRef': '#node'},
    },
  };

  final generator = SchemaGenerator(
    options: SchemaGeneratorOptions(
      sourcePath: 'memory://debug',
      onWarning: (message) => log('warning: $message'),
    ),
  );

  log('Building IR');
  final ir = generator.buildIr(schema);
  log('Root class: ${ir.rootClass.name}');
  for (final property in ir.rootClass.properties) {
    log(' - ${property.fieldName}: ${property.typeRef}');
  }
}
