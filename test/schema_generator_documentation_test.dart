import 'package:schema2model/src/generator.dart';
import 'package:test/test.dart';

void main() {
  group('documentation enhancements', () {
    const docSchema = <String, dynamic>{
      'type': 'object',
      'description': 'A sample entity used to test documentation output.',
      'properties': {
        'alpha': {
          'type': 'string',
          'description': 'Primary identifier.',
          'default': 'guest',
          'examples': ['guest', 'admin'],
        },
        'beta': {
          'type': 'integer',
          'deprecated': true,
          'description': 'Legacy numeric field.',
        },
        'gamma': {'type': 'number', 'propertyOrder': 1},
        'delta': {'type': 'string'},
      },
      'required': ['alpha', 'gamma'],
    };

    test('includes extended metadata in property doc comments', () {
      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(),
      );
      final generated = generator.generate(docSchema);

      expect(
        generated,
        contains(
          '  /// Primary identifier.\n  /// \n  /// Default: \'guest\'.\n  /// \n  /// Examples: \'guest\', \'admin\'.',
        ),
      );
      expect(
        generated,
        contains('  /// Legacy numeric field.\n  /// \n  /// Deprecated.'),
      );
    });

    test('stabilises property ordering by propertyOrder then name', () {
      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(),
      );
      final ir = generator.buildIr(docSchema);
      final rootProperties = ir.rootClass.properties
          .map((p) => p.jsonName)
          .toList();

      expect(rootProperties, equals(['gamma', 'alpha', 'beta', 'delta']));
    });

    test('emits README snippet when enabled', () {
      final generator = SchemaGenerator(
        options: const SchemaGeneratorOptions(emitReadmeSnippets: true),
      );
      final ir = generator.buildIr(docSchema);
      final snippet = generator.buildReadmeSnippet(ir);

      expect(snippet, isNotNull);
      expect(snippet, contains('# Schema Summary'));
      expect(snippet, contains('Root type:'));
      expect(snippet, contains('## Root Properties'));

      final plan = generator.planMultiFile(ir, baseName: 'doc_sample');
      expect(plan.readmeFileName, equals('README.schema.md'));
      expect(plan.readmeContents, equals(snippet));
    });
  });
}
