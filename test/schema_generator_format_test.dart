import 'package:schemamodeschema/src/generator.dart';
import 'package:test/test.dart';

void main() {
  const schema = <String, dynamic>{
    'type': 'object',
    'properties': {
      'timestamp': {'type': 'string', 'format': 'date-time'},
      'website': {'type': 'string', 'format': 'uri'},
      'contactEmail': {'type': 'string', 'format': 'email'},
      'identifier': {'type': 'string', 'format': 'uuid'},
      'customFormatted': {
        'type': 'string',
        'format': 'custom-format',
        'description': 'String with vendor-specific format',
      },
    },
    'required': ['timestamp', 'website', 'contactEmail', 'identifier'],
  };

  group('format hints', () {
    test('disabled retains strings and documents formats', () {
      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(),
      );
      final ir = generator.buildIr(schema);

      expect(ir.helpers, isEmpty);

      final root = ir.rootClass;
      final properties = {
        for (final prop in root.properties) prop.jsonName: prop,
      };

      expect(properties['timestamp']!.typeRef, isA<PrimitiveTypeRef>());
      expect(
        properties['timestamp']!.description,
        contains('Format: date-time (format hints disabled).'),
      );
      expect(
        properties['customFormatted']!.description,
        contains(
          'Format: custom-format (unsupported format, emitted as String).',
        ),
      );
    });

    test('enabled maps recognised formats to rich types', () {
      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(enableFormatHints: true),
      );
      final ir = generator.buildIr(schema);

      expect(
        ir.helpers.map((helper) => helper.name),
        containsAll(<String>['EmailAddress', 'UuidValue']),
      );

      final root = ir.rootClass;
      final properties = {
        for (final prop in root.properties) prop.jsonName: prop,
      };

      final timestamp = properties['timestamp']!;
      final website = properties['website']!;
      final contactEmail = properties['contactEmail']!;
      final identifier = properties['identifier']!;

      expect(timestamp.typeRef, isA<FormatTypeRef>());
      expect(timestamp.typeRef.dartType(), 'DateTime');
      expect(website.typeRef.dartType(), 'Uri');
      expect(contactEmail.typeRef.dartType(), 'EmailAddress');
      expect(identifier.typeRef.dartType(), 'UuidValue');
      expect(contactEmail.description, contains('Format: email.'));
      expect(
        properties['customFormatted']!.description,
        contains('unsupported format'),
      );

      final generated = generator.generate(schema);

      expect(generated, contains('DateTime.parse('));
      expect(generated, contains('Uri.parse('));
      expect(generated, contains('EmailAddress('));
      expect(generated, contains('UuidValue('));
      expect(generated, contains('class EmailAddress'));
      expect(generated, contains('class UuidValue'));
      expect(generated, contains('/// Format: date-time.'));
    });

    test('multi-file plan emits helper files and imports', () {
      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(enableFormatHints: true),
      );
      final ir = generator.buildIr(schema);
      final plan = generator.planMultiFile(ir, baseName: 'format_sample');

      expect(plan.files.containsKey('root_schema.dart'), isTrue);
      expect(plan.files.containsKey('email_address.dart'), isTrue);
      expect(plan.files.containsKey('uuid_value.dart'), isTrue);

      final rootFile = plan.files['root_schema.dart']!;
      expect(rootFile, contains("import 'email_address.dart';"));
      expect(rootFile, contains("import 'uuid_value.dart';"));
      expect(rootFile, contains('DateTime.parse('));
      expect(rootFile, contains('EmailAddress('));

      final helper = plan.files['email_address.dart']!;
      expect(helper, contains('class EmailAddress'));

      expect(
        plan.barrel,
        contains("export '${plan.partsDirectory}/email_address.dart';"),
      );
    });
  });
}
