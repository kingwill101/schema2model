import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:schemamodeschema/src/generator.dart';
import 'package:test/test.dart';

import '../example/schemas/github_workflow/schema.dart' as model;

void main() {
  group('GitHub workflow schema', () {
    late SchemaIr ir;
    late String schemaPath;

    setUpAll(() {
      final root = Directory.current.path;
      final schemaFile = File(
        p.join(root, 'example', 'schemas', 'github_workflow', 'schema.json'),
      );
      expect(
        schemaFile.existsSync(),
        isTrue,
        reason: 'Expected example/schemas/github_workflow/schema.json to exist',
      );
      schemaPath = schemaFile.path;
      final decoded = jsonDecode(schemaFile.readAsStringSync());
      expect(decoded, isA<Map<String, dynamic>>());
      final generator = SchemaGenerator(
        options: SchemaGeneratorOptions(sourcePath: schemaPath),
      );
      ir = generator.buildIr(decoded as Map<String, dynamic>);
    });

    test('exposes job union variants with heuristic discrimination', () {
      final union = ir.unions.firstWhere(
        (entry) =>
            entry.baseClass.name == 'GithubWorkflowJobsPatternProperty1',
      );
      final variantNames = union.variants
          .map((variant) => variant.classSpec.name)
          .toSet();
      expect(
        variantNames,
        containsAll(<String>['NormalJob', 'ReusableWorkflowCallJob']),
      );
      expect(union.keyword, equals('oneOf'));
    });

    test('multi-file generation keeps job variants as parts', () {
      final generator = SchemaGenerator(
        options: SchemaGeneratorOptions(sourcePath: schemaPath),
      );
      final plan = generator.planMultiFile(
        ir,
        baseName: 'github-workflow.schema',
      );

      final unionFileEntry = plan.files.entries.firstWhere(
        (entry) => entry.key.contains('jobs_pattern_property1.dart'),
      );
      final unionFile = unionFileEntry.value;
      expect(
        unionFile,
        contains("part 'normal_job.dart';"),
        reason: 'Normal job variant should be emitted as a part file.',
      );
      expect(unionFile, contains("part 'reusable_workflow_call_job.dart';"));

      final barrel = plan.barrel;
      expect(
        barrel,
        contains(
          "export '${plan.partsDirectory}/github_workflow_jobs_pattern_property1.dart';",
        ),
      );
    });

    test('supports building strongly typed workflow instances', () {
      final workflow = model.GithubWorkflow(
        name: 'CI',
        on: const {
          'workflow_dispatch': null,
          'push': {
            'branches': ['main'],
          },
        },
        jobs: model.GithubWorkflowJobs(
          patternProperties: {
            'build': model.NormalJob(
              runsOn: 'ubuntu-latest',
              steps: const [
                model.Step(name: 'Checkout', uses: 'actions/checkout@v4'),
                model.Step(name: 'Install dependencies', run: 'dart pub get'),
                model.Step(name: 'Analyze', run: 'dart analyze'),
                model.Step(name: 'Test', run: 'dart test'),
              ],
            ),
            'docs': model.ReusableWorkflowCallJob(
              uses: 'owner/workflows/.github/workflows/docs.yml@v1',
            ),
          },
        ),
        defaults: const model.Defaults(),
        env: const {'CI': 'true'},
        permissions: const {'contents': 'read'},
        concurrency: const {
          'group': 'ci-\${{ github.ref }}',
          'cancel-in-progress': true,
        },
        runName: 'CI for \${{ github.ref }}',
      );

      final json = workflow.toJson();
      expect(json['name'], equals('CI'));

      final jobs = json['jobs'] as Map<String, dynamic>;
      expect(jobs.keys, containsAll(<String>['build', 'docs']));
      final buildJob = jobs['build'] as Map<String, dynamic>;
      expect(buildJob['runs-on'], equals('ubuntu-latest'));
      expect(buildJob['steps'], isA<List>());
      expect(
        (buildJob['steps'] as List)
            .map((step) => (step as Map<String, dynamic>)['name'])
            .toList(),
        containsAll(<String>[
          'Checkout',
          'Install dependencies',
          'Analyze',
          'Test',
        ]),
      );

      final docsJob = jobs['docs'] as Map<String, dynamic>;
      expect(
        docsJob['uses'],
        equals('owner/workflows/.github/workflows/docs.yml@v1'),
      );
    });
  });
}
