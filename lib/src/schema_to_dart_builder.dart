import 'dart:convert';
import 'dart:io';

import 'package:build/build.dart';
import 'package:glob/glob.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'generator.dart';

class SchemaToDartBuilder implements Builder {
  SchemaToDartBuilder(
    this._options, {
    List<Glob>? includeGlobs,
  }) : _includeGlobs = includeGlobs ?? _defaultIncludeGlobs;

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
    final defaultDialectUri = options.config['default_dialect'] as String?;
    SchemaDialect? defaultDialect;
    if (defaultDialectUri == null) {
      defaultDialect = SchemaDialect.latest;
    } else if (defaultDialectUri.trim().toLowerCase() == 'none') {
      defaultDialect = null;
    } else {
      final dialect = SchemaDialect.lookup(
        defaultDialectUri,
        SchemaDialect.defaultDialectRegistry,
      );
      if (dialect == null) {
        final supported = SchemaDialect.defaultDialectRegistry.keys.join(', ');
        throw ArgumentError(
          'Unsupported default_dialect "$defaultDialectUri". '
          'Supported dialects: $supported, or "none" to require explicit declarations.',
        );
      }
      defaultDialect = dialect;
    }

    final includeGlobs = _parseIncludeGlobs(options.config['include_globs']);
    final emitValidationHelpers = _parseBool(
      options.config['emit_validation_helpers'],
      true,
    );
    final enableFormatHints =
        _parseBool(options.config['enable_format_hints'], false);
    final enableFormatAssertions =
        _parseBool(options.config['enable_format_assertions'], false);
    final enableContentKeywords =
        _parseBool(options.config['enable_content_keywords'], false);
    final enableContentValidation =
        _parseBool(options.config['enable_content_validation'], false);
    final emitUsageDocs = _parseBool(options.config['emit_usage_docs'], false);
    final generateHelpers =
        _parseBool(options.config['generate_helpers'], false);
    final emitReadmeSnippets =
        _parseBool(options.config['emit_readme_snippets'], false);

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
        defaultDialect: defaultDialect,
        emitValidationHelpers: emitValidationHelpers,
        enableFormatHints: enableFormatHints,
        enableFormatAssertions: enableFormatAssertions,
        enableContentKeywords: enableContentKeywords,
        enableContentValidation: enableContentValidation,
        emitUsageDocs: emitUsageDocs,
        generateHelpers: generateHelpers,
        emitReadmeSnippets: emitReadmeSnippets,
      ),
      includeGlobs: includeGlobs,
    );
  }

  final SchemaGeneratorOptions _options;
  final List<Glob> _includeGlobs;

  static final List<Glob> _defaultIncludeGlobs = List.unmodifiable(
    [
      Glob('**/*.schema.json'),
      Glob('**/*.json'),
    ],
  );

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

  static List<Glob> _parseIncludeGlobs(Object? raw) {
    if (raw == null) {
      return _defaultIncludeGlobs;
    }

    final patterns = <String>[];
    if (raw is String) {
      if (raw.trim().isNotEmpty) {
        patterns.add(raw.trim());
      }
    } else if (raw is Iterable) {
      for (final entry in raw) {
        if (entry is String && entry.trim().isNotEmpty) {
          patterns.add(entry.trim());
        }
      }
    } else {
      throw ArgumentError(
        'include_globs must be a String or List<String>, got ${raw.runtimeType}.',
      );
    }

    if (patterns.isEmpty) {
      return _defaultIncludeGlobs;
    }

    return List.unmodifiable(patterns.map(Glob.new));
  }

  @override
  Map<String, List<String>> get buildExtensions => const {
        '.json': ['.dart'],
      };

  @override
  Future<void> build(BuildStep buildStep) async {
    final inputId = buildStep.inputId;
    if (!_matchesInclude(inputId.path)) {
      log.fine(
        '${inputId.path}: Skipping because it does not match configured include_globs.',
      );
      return;
    }
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
        p.join('.dart_tool', 'schema2model', 'cache');
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

  @visibleForTesting
  bool matchesInclude(String path) => _matchesInclude(path);

  bool _matchesInclude(String path) {
    for (final glob in _includeGlobs) {
      if (glob.matches(path)) {
        return true;
      }
    }
    return false;
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
