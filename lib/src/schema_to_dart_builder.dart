import 'dart:convert';
import 'dart:io';

import 'package:build/build.dart';
import 'package:path/path.dart' as p;

import 'generator.dart';

class SchemaToDartBuilder implements Builder {
  SchemaToDartBuilder(this._options);

  factory SchemaToDartBuilder.fromOptions(BuilderOptions options) {
    final rootClass = options.config['root_class'] as String?;
    final preferCamelCase = _parseBool(
      options.config['prefer_camel_case'],
      true,
    );
    final emitDocs = _parseBool(options.config['emit_docs'], true);
    final header = options.config['header'] as String?;
    final singleFileOutput = _parseBool(
      options.config['single_file_output'],
      false,
    );
    final allowNetworkRefs = _parseBool(
      options.config['allow_network_refs'],
      false,
    );
    final networkCachePath = options.config['network_cache_path'] as String?;

    return SchemaToDartBuilder(
      SchemaGeneratorOptions(
        rootClassName: rootClass,
        preferCamelCase: preferCamelCase,
        emitDocumentation: emitDocs,
        header: header,
        singleFileOutput: singleFileOutput,
        allowNetworkRefs: allowNetworkRefs,
        networkCachePath: networkCachePath,
        onWarning: log.warning,
      ),
    );
  }

  final SchemaGeneratorOptions _options;

  static bool _parseBool(Object? value, bool fallback) {
    if (value is bool) return value;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      if (normalized.isEmpty) return fallback;
      if (normalized == 'true') return true;
      if (normalized == 'false') return false;
    }
    return fallback;
  }

  @override
  Map<String, List<String>> get buildExtensions => const {
    '.schema.json': ['.schema.dart'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final inputId = buildStep.inputId;
    final rawContents = await buildStep.readAsString(inputId);
    final schema = jsonDecode(rawContents);

    if (schema is! Map<String, dynamic>) {
      log.warning('${inputId.path}: Root schema is not an object. Skipping.');
      return;
    }

    final outputId = inputId.changeExtension('.dart');
    final sourceDescription = inputId.path;
    final absoluteInputPath = p.normalize(
      p.join(Directory.current.path, inputId.path),
    );
    final baseUri = Uri.file(absoluteInputPath);
    final cachePath =
        _options.networkCachePath ??
        p.join('.dart_tool', 'schemamodeschema', 'cache');
    final absoluteCachePath = p.isAbsolute(cachePath)
        ? cachePath
        : p.join(Directory.current.path, cachePath);

    final options = _options.copyWith(
      inferredRootClass: _inferRootClassName(schema, inputId),
      sourcePath: sourceDescription,
      baseUri: baseUri,
      networkCachePath: absoluteCachePath,
    );
    final generator = SchemaGenerator(options: options);
    final ir = generator.buildIr(schema);

    if (options.singleFileOutput) {
      final contents = generator.generateFromIr(ir);
      await buildStep.writeAsString(outputId, contents);
      await _cleanupSplitOutputs(inputId);
      return;
    }

    final baseName = _schemaBaseName(inputId);
    final plan = generator.planMultiFile(ir, baseName: baseName);
    await buildStep.writeAsString(outputId, plan.barrel);
    await _writeSplitOutputs(inputId, plan);
  }

  String _inferRootClassName(Map<String, dynamic> schema, AssetId id) {
    final explicit = schema['title'] as String?;
    if (explicit != null && explicit.trim().isNotEmpty) {
      return explicit;
    }

    final basename = p.basenameWithoutExtension(id.path); // removes .json first
    final withoutSchema = basename.endsWith('.schema')
        ? basename.substring(0, basename.length - '.schema'.length)
        : basename;

    return withoutSchema;
  }

  Future<void> _writeSplitOutputs(AssetId inputId, MultiOutputPlan plan) async {
    final root = Directory.current.path;
    final inputDir = p.join(root, p.dirname(inputId.path));
    final partsDirPath = p.join(inputDir, plan.partsDirectory);
    final partsDir = Directory(partsDirPath);
    if (partsDir.existsSync()) {
      await partsDir.delete(recursive: true);
    }
    await partsDir.create(recursive: true);

    for (final entry in plan.files.entries) {
      final filePath = p.join(partsDirPath, entry.key);
      await File(filePath).writeAsString(entry.value);
    }
  }

  Future<void> _cleanupSplitOutputs(AssetId inputId) async {
    final root = Directory.current.path;
    final inputDir = p.join(root, p.dirname(inputId.path));
    final dir = Directory(
      p.join(inputDir, _generatedDirectoryName(_schemaBaseName(inputId))),
    );
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  }

  String _schemaBaseName(AssetId id) {
    final fileName = p.basename(id.path); // e.g. foo.schema.json
    if (fileName.endsWith('.schema.json')) {
      return fileName.substring(0, fileName.length - '.schema.json'.length);
    }
    if (fileName.endsWith('.json')) {
      return fileName.substring(0, fileName.length - '.json'.length);
    }
    return fileName;
  }

  String _generatedDirectoryName(String baseName) {
    final sanitized = baseName
        .replaceAll(RegExp(r'[^a-zA-Z0-9]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '')
        .toLowerCase();
    return '${sanitized}_generated';
  }
}
