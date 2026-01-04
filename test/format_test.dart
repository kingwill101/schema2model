import 'package:schema2model/src/generator.dart';
import 'package:test/test.dart';

void main() {
  const schema = <String, dynamic>{
    'type': 'object',
    'properties': {
      'timestamp': {'type': 'string', 'format': 'date-time'},
      'birthday': {'type': 'string', 'format': 'date'},
      'website': {'type': 'string', 'format': 'uri'},
      'contactEmail': {'type': 'string', 'format': 'email'},
      'identifier': {'type': 'string', 'format': 'uuid'},
      'host': {'type': 'string', 'format': 'hostname'},
      'ipv4Addr': {'type': 'string', 'format': 'ipv4'},
      'relativeLink': {'type': 'string', 'format': 'uri-reference'},
      'customFormatted': {
        'type': 'string',
        'format': 'custom-format',
        'description': 'String with vendor-specific format',
      },
    },
    'required': [
      'timestamp',
      'birthday',
      'website',
      'contactEmail',
      'identifier',
    ],
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
        properties['timestamp']!.description,
        contains('Date and time as defined'),
      );
      expect(
        properties['birthday']!.description,
        contains('Format: date (format hints disabled).'),
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
        containsAll(<String>[
          'EmailAddress',
          'UuidValue',
          'Hostname',
          'Ipv4Address',
          'UriReference',
        ]),
      );

      final root = ir.rootClass;
      final properties = {
        for (final prop in root.properties) prop.jsonName: prop,
      };

      final timestamp = properties['timestamp']!;
      final birthday = properties['birthday']!;
      final website = properties['website']!;
      final contactEmail = properties['contactEmail']!;
      final identifier = properties['identifier']!;
      final host = properties['host']!;
      final ipv4 = properties['ipv4Addr']!;
      final relative = properties['relativeLink']!;

      expect(timestamp.typeRef, isA<FormatTypeRef>());
      expect(timestamp.typeRef.dartType(), 'DateTime');
      expect(birthday.typeRef, isA<FormatTypeRef>());
      expect(birthday.typeRef.dartType(), 'DateTime');
      expect(website.typeRef.dartType(), 'Uri');
      expect(contactEmail.typeRef.dartType(), 'EmailAddress');
      expect(identifier.typeRef.dartType(), 'UuidValue');
      expect(contactEmail.description, contains('Format: email.'));
      expect(contactEmail.description, contains('Email address as defined'));
      expect(
        properties['customFormatted']!.description,
        contains('unsupported format'),
      );
      expect(host.typeRef, isA<FormatTypeRef>());
      expect(host.description, contains('Format: hostname.'));
      expect(host.description, contains('Hostname as defined by RFC 1123.'));
      expect(ipv4.typeRef.dartType(), 'Ipv4Address');
      expect(ipv4.description, contains('IPv4 address as defined'));
      expect(relative.typeRef.dartType(), 'UriReference');
      expect(relative.description, contains('URI Reference as defined'));

      final generated = generator.generate(schema);

      expect(generated, contains('DateTime.parse('));
      expect(generated, contains('toIso8601String().split(\'T\').first'));
      expect(generated, contains('Uri.parse('));
      expect(generated, contains('EmailAddress('));
      expect(generated, contains('UuidValue('));
      expect(generated, contains('class Hostname'));
      expect(generated, contains('class Ipv4Address'));
      expect(generated, contains('class UriReference'));
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
      expect(plan.files.containsKey('hostname.dart'), isTrue);
      expect(plan.files.containsKey('ipv4_address.dart'), isTrue);
      expect(plan.files.containsKey('uri_reference.dart'), isTrue);

      final rootFile = plan.files['root_schema.dart']!;
      expect(rootFile, contains("import 'email_address.dart';"));
      expect(rootFile, contains("import 'uuid_value.dart';"));
      expect(rootFile, contains("import 'hostname.dart';"));
      expect(rootFile, contains("import 'ipv4_address.dart';"));
      expect(rootFile, contains("import 'uri_reference.dart';"));
      expect(rootFile, contains('DateTime.parse('));
      expect(rootFile, contains('EmailAddress('));

      final helper = plan.files['email_address.dart']!;
      expect(helper, contains('class EmailAddress'));
      expect(
        plan.barrel,
        contains("export '${plan.partsDirectory}/hostname.dart';"),
      );
      expect(
        plan.barrel,
        contains("export '${plan.partsDirectory}/ipv4_address.dart';"),
      );
      expect(
        plan.barrel,
        contains("export '${plan.partsDirectory}/uri_reference.dart';"),
      );

      expect(
        plan.barrel,
        contains("export '${plan.partsDirectory}/email_address.dart';"),
      );
    });
  });

  group('format assertions', () {
    test('emits validation when enabled', () {
      const schema = <String, dynamic>{
        'type': 'object',
        'properties': {
          'email': {'type': 'string', 'format': 'email'},
        },
        'required': ['email'],
      };

      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(
          emitValidationHelpers: true,
          enableFormatAssertions: true,
        ),
      );

      final code = generator.generate(schema);

      expect(code, contains("isValidFormat('email'"));
      expect(code, contains("throwValidationError(_ptr0, 'format'"));
    });

    test('does not emit validation when disabled', () {
      const schema = <String, dynamic>{
        'type': 'object',
        'properties': {
          'email': {'type': 'string', 'format': 'email'},
        },
      };

      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(
          emitValidationHelpers: true,
        ),
      );

      final code = generator.generate(schema);

      expect(code, isNot(contains("isValidFormat('email'")));
    });
  });
}
