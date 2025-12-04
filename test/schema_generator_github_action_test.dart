import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:schema2model/src/generator.dart';
import 'package:test/test.dart';

void main() {
  group('GitHub Actions schema', () {
    late Map<String, dynamic> schema;
    late SchemaIr ir;
    late String schemaPath;

    setUpAll(() {
      final root = Directory.current.path;
      final schemaFile = File(
        p.join(root, 'example', 'schemas', 'github_action/schema.json'),
      );
      expect(
        schemaFile.existsSync(),
        isTrue,
        reason: 'Expected example/schemas/github_action/schema.json to exist',
      );
      schemaPath = schemaFile.path;
      final decoded = jsonDecode(schemaFile.readAsStringSync());
      expect(decoded, isA<Map<String, dynamic>>());
      schema = decoded as Map<String, dynamic>;

      final generator = SchemaGenerator(
        options: SchemaGeneratorOptions(sourcePath: schemaPath),
      );
      ir = generator.buildIr(schema);
    });

    test('reuses definition classes without duplicates', () {
      final classNames = ir.classes.map((klass) => klass.name).toSet();

      expect(
        classNames,
        containsAll(<String>[
          'RootSchemaRuns',
          'RunsJavascript',
          'RunsComposite',
          'RunsDocker',
          'Outputs',
          'OutputsComposite',
          'RootSchemaInputs',
        ]),
      );
      expect(classNames, isNot(contains('RunsJavascript2')));
      expect(classNames, isNot(contains('RunsComposite2')));
      expect(classNames, isNot(contains('RunsDocker2')));

      final union = ir.unions.singleWhere(
        (union) => union.name == 'RootSchemaRuns',
      );
      expect(
        union.variants.map((variant) => variant.classSpec.name).toList(),
        unorderedEquals(<String>[
          'RunsJavascript',
          'RunsComposite',
          'RunsDocker',
        ]),
      );

      final enumNames = ir.enums.map((enumeration) => enumeration.name).toSet();
      expect(
        enumNames,
        containsAll(<String>['RunsJavascriptUsing', 'RootSchemaBrandingIcon']),
      );
      expect(enumNames, isNot(contains('RunsJavascript2Using')));
    });

    test(
      'preserves stringContainingExpressionSyntax definition through field typing',
      () {
        final runsJavascript = ir.classes.firstWhere(
          (klass) => klass.name == 'RunsJavascript',
        );
        final preIfProperty = runsJavascript.properties.singleWhere(
          (property) => property.jsonName == 'pre-if',
        );
        expect(preIfProperty.typeRef, isA<PrimitiveTypeRef>());
        expect(
          (preIfProperty.typeRef as PrimitiveTypeRef).typeName,
          'String',
          reason:
              'pre-if should map to a String, matching stringContainingExpressionSyntax',
        );
      },
    );

    test(
      'multi-file generation emits union variants as parts of the base library',
      () {
        final generator = SchemaGenerator(
          options: SchemaGeneratorOptions(sourcePath: schemaPath),
        );
        final plan = generator.planMultiFile(
          ir,
          baseName: 'github-action.schema',
        );

        final rootRuns = plan.files['root_schema_runs.dart'];
        expect(rootRuns, isNotNull);
        expect(rootRuns, contains("part 'runs_javascript.dart';"));
        expect(rootRuns, contains("part 'runs_composite.dart';"));
        expect(rootRuns, contains("part 'runs_docker.dart';"));

        final javascriptPart = plan.files['runs_javascript.dart'];
        expect(javascriptPart, isNotNull);
        expect(javascriptPart, contains("part of 'root_schema_runs.dart';"));

        final barrel = plan.barrel;
        expect(
          barrel,
          contains("export '${plan.partsDirectory}/root_schema_runs.dart';"),
        );
        expect(barrel, isNot(contains("runs_javascript.dart")));
      },
    );

    test('composite steps remain strongly typed', () {
      final runsComposite = ir.classes.firstWhere(
        (klass) => klass.name == 'RunsComposite',
      );
      final stepsProperty = runsComposite.properties.singleWhere(
        (property) => property.jsonName == 'steps',
      );
      expect(stepsProperty.typeRef, isA<ListTypeRef>());
      final listType = stepsProperty.typeRef as ListTypeRef;
      expect(listType.itemType, isA<ObjectTypeRef>());
      final itemRef = listType.itemType as ObjectTypeRef;
      expect(itemRef.spec.name, equals('RunsCompositeStep'));
    });

    test('composite steps capture required combinations as metadata', () {
      final stepsItem = ir.classes.firstWhere(
        (klass) => klass.name == 'RunsCompositeStep',
      );
      expect(stepsItem.conditionalConstraints, isNotEmpty);
      final constraint = stepsItem.conditionalConstraints.singleWhere(
        (entry) => entry.keyword == 'oneOf',
      );
      expect(
        constraint.schemaPointer,
        equals('#/definitions/runs-composite/properties/steps/items/oneOf'),
      );
      final combinationKeys = constraint.branches
          .map((branch) => branch.requiredProperties.toList()..sort())
          .map((sorted) => sorted.join(','))
          .toSet();
      expect(combinationKeys, containsAll(<String>{'run,shell', 'uses'}));
    });

    test('validation enforces composite step combinations', () {
      final generator = SchemaGenerator(
        options: SchemaGeneratorOptions(
          sourcePath: schemaPath,
          emitValidationHelpers: true,
        ),
      );
      final output = generator.generate(schema);
      expect(
        output,
        contains(
          "throwValidationError(pointer, 'oneOf', 'Expected exactly one of the combinations defined at #/definitions/runs-composite/properties/steps/items/oneOf to be satisfied ([\"run\", \"shell\"], [\"uses\"]).');",
        ),
      );
    });
  });
}
