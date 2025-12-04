import 'dart:io';

import 'schemas/github_workflow/schema.dart';

void main(List<String> arguments) {
  final workflow = GithubWorkflow(
    name: 'Dart CI',
    on: const ['push', 'pull_request'],
    jobs: GithubWorkflowJobs(
      patternProperties: {
        'build': NormalJob(
          runsOn: 'ubuntu-latest',
          timeoutMinutes: null,
          steps: [
            Step(
              name: 'Checkout repository',
              uses: 'actions/checkout@v4',
              continueOnError: null,
            ),
            Step(
              name: 'Install Dart SDK',
              uses: 'dart-lang/setup-dart@v1',
              with_: const {'sdk': 'stable'},
              continueOnError: null,
            ),
            Step(
              name: 'Install dependencies',
              run: 'dart pub get',
              continueOnError: null,
            ),
            Step(
              name: 'Analyze',
              run: 'dart analyze',
              continueOnError: null,
            ),
            Step(
              name: 'Tests',
              run: 'dart test',
              continueOnError: null,
            ),
          ],
        ),
      },
    ),
  );

  final workflowMap = _orderedWorkflowMap(workflow);
  final yaml = _toYaml(workflowMap).trimRight();
  final outputPath =
      arguments.isNotEmpty ? arguments.first : 'example/workflows/dart_ci.yml';

  File(outputPath)
    ..createSync(recursive: true)
    ..writeAsStringSync('$yaml\n');

  stdout.writeln('Wrote $outputPath');
  stdout.writeln('\n$yaml');
}

Map<String, dynamic> _orderedWorkflowMap(GithubWorkflow workflow) {
  final jobsJson = workflow.jobs.toJson();

  final ordered = <String, dynamic>{
    if (workflow.name != null) 'name': workflow.name,
    if (workflow.runName != null) 'run-name': workflow.runName,
    'on': workflow.on,
    if (workflow.permissions != null) 'permissions': workflow.permissions,
    if (workflow.env != null) 'env': workflow.env,
    if (workflow.defaults != null) 'defaults': workflow.defaults!.toJson(),
    if (workflow.concurrency != null) 'concurrency': workflow.concurrency,
    'jobs': jobsJson,
  };

  for (final entry in workflow.toJson().entries) {
    ordered.putIfAbsent(entry.key, () => entry.value);
  }
  return ordered;
}

String _toYaml(Object? value) {
  final buffer = StringBuffer();
  _writeYaml(value, buffer, 0);
  return buffer.toString();
}

void _writeYaml(Object? value, StringBuffer buffer, int indent) {
  final indentation = '  ' * indent;
  if (value is Map) {
    final entries = value.entries.where((entry) => entry.value != null);
    for (final entry in entries) {
      final key = _formatKey(entry.key);
      final val = entry.value;
      if (_isScalar(val)) {
        buffer.write('$indentation$key: ${_formatScalar(val)}\n');
      } else {
        buffer.write('$indentation$key:\n');
        _writeYaml(val, buffer, indent + 1);
      }
    }
  } else if (value is Iterable) {
    for (final item in value) {
      if (_isScalar(item)) {
        buffer.write('$indentation- ${_formatScalar(item)}\n');
      } else {
        buffer.write('$indentation-\n');
        _writeYaml(item, buffer, indent + 1);
      }
    }
  } else {
    buffer.write('$indentation${_formatScalar(value)}\n');
  }
}

bool _isScalar(Object? value) =>
    value == null || value is num || value is bool || value is String;

String _formatScalar(Object? value) {
  if (value == null) {
    return 'null';
  }
  if (value is bool || value is num) {
    return value.toString();
  }
  final escaped = value.toString().replaceAll("'", "''").replaceAll('\n', r'\n');
  return "'$escaped'";
}

String _formatKey(Object key) {
  final keyStr = key.toString();
  final safeKey = RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(keyStr);
  if (safeKey) {
    return keyStr;
  }
  final escaped = keyStr.replaceAll("'", "''");
  return "'$escaped'";
}
