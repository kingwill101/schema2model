import 'package:build/build.dart';
import 'package:schema2model/src/schema_to_dart_builder.dart';
import 'package:test/test.dart';

void main() {
  group('SchemaToDartBuilder include_globs', () {
    test('defaults include *.schema.json and *.json', () {
      final builder = SchemaToDartBuilder.fromOptions(BuilderOptions({}));

      expect(builder.matchesInclude('lib/foo.schema.json'), isTrue);
      expect(builder.matchesInclude('lib/foo.json'), isTrue);
      expect(builder.matchesInclude('lib/foo.yaml'), isFalse);
    });

    test('respects custom include_globs overrides', () {
      final builder = SchemaToDartBuilder.fromOptions(
        BuilderOptions({
          'include_globs': ['example/schemas/**.json'],
        }),
      );

      expect(builder.matchesInclude('example/schemas/workflow.json'), isTrue);
      expect(builder.matchesInclude('lib/foo.json'), isFalse);
    });
  });
}
