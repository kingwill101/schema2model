import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:schemamodeschema/src/generator.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty || arguments.length > 2) {
    stderr.writeln(
      'Usage: dart run tool/generate_schema.dart <schema.json> [output.dart]',
    );
    exitCode = 64;
    return;
  }

  final schemaPath = arguments[0];
  final schemaFile = File(schemaPath);
  if (!schemaFile.existsSync()) {
    stderr.writeln('Schema file not found: $schemaPath');
    exitCode = 66;
    return;
  }

  final outputPath = arguments.length == 2 ? arguments[1] : null;
  final outputFile = outputPath != null ? File(outputPath) : null;

  final raw = schemaFile.readAsStringSync();
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) {
    stderr.writeln('Schema root must be a JSON object.');
    exitCode = 65;
    return;
  }

  final absolutePath = schemaFile.absolute.path;
  final baseUri = Uri.file(absolutePath);
  final cacheDir = p.join(
    Directory.current.path,
    '.dart_tool',
    'schemamodeschema',
    'cache',
  );

  final generator = SchemaGenerator(
    options: SchemaGeneratorOptions(
      sourcePath: schemaFile.path,
      baseUri: baseUri,
      allowNetworkRefs: true,
      networkCachePath: cacheDir,
      onWarning: stderr.writeln,
    ),
  );

  final schemaName = p.basenameWithoutExtension(schemaFile.path);
  final ir = generator.buildIr(decoded);
  final output = generator.generateFromIr(ir);

  if (outputFile != null) {
    outputFile
      ..createSync(recursive: true)
      ..writeAsStringSync(output);
    stdout.writeln('Wrote ${outputFile.path}');
  } else {
    stdout.writeln(output);
  }

  // Optionally emit split files into a directory for inspection.
  final plan = generator.planMultiFile(ir, baseName: schemaName);
  final generatedDir = Directory(plan.partsDirectory);
  if (generatedDir.existsSync()) {
    generatedDir.deleteSync(recursive: true);
  }
  generatedDir.createSync(recursive: true);
  for (final entry in plan.files.entries) {
    final file = File(p.join(generatedDir.path, entry.key))
      ..createSync(recursive: true)
      ..writeAsStringSync(entry.value);
    stdout.writeln('Wrote ${file.path}');
  }
  final rewrittenBarrel = plan.barrel.replaceAll('${plan.partsDirectory}/', '');
  final barrel = File(p.join(generatedDir.path, 'index.dart'))
    ..writeAsStringSync(rewrittenBarrel);
  stdout.writeln('Wrote ${barrel.path}');

  if (plan.readmeFileName != null && plan.readmeContents != null) {
    final readmeFile = File(p.join(generatedDir.path, plan.readmeFileName!))
      ..writeAsStringSync(plan.readmeContents!);
    stdout.writeln('Wrote ${readmeFile.path}');
  }
}
