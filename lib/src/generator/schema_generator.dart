part of 'package:schema2model/src/generator.dart';

/// Entrypoint that turns a JSON schema map into Dart source code.
class SchemaGenerator {
  SchemaGenerator({required this.options});

  final SchemaGeneratorOptions options;

  static const _memoryScheme = 'memory';

  SchemaDocumentLoader get _effectiveLoader {
    final loader = options.documentLoader;
    if (loader != null) {
      return loader;
    }
    final defaultLoader = _DefaultSchemaDocumentLoader(
      allowNetworkRefs: options.allowNetworkRefs,
      allowedNetworkHosts: options.allowedNetworkHosts,
      allowedFilePaths: options.allowedFilePaths,
      cacheDirectoryPath: options.networkCachePath,
      onWarning: options.onWarning,
    );
    return defaultLoader.call;
  }

  String generate(Map<String, dynamic> schema) {
    final ir = buildIr(schema);
    return generateFromIr(ir);
  }

  SchemaIr buildIr(Map<String, dynamic> schema) {
    final baseUri = options.baseUri ?? _inferBaseUri();
    final walker = _SchemaWalker(
      schema,
      options,
      baseUri: baseUri,
      documentLoader: _effectiveLoader,
    );
    return walker.build();
  }

  String generateFromIr(SchemaIr ir) {
    final emitter = _SchemaEmitter(options);
    final buffer = StringBuffer()
      ..write(_buildHeader())
      ..write(emitter.renderLibrary(ir));
    return buffer.toString();
  }

  String? buildReadmeSnippet(SchemaIr ir) => _buildReadmeSnippet(ir);

  MultiOutputPlan planMultiFile(SchemaIr ir, {required String baseName}) {
    final emitter = _SchemaEmitter(options);
    emitter.setUnions(ir.unions);
    final partsDirectory = '${_sanitizeBaseName(baseName)}_generated';
    final files = <String, String>{};
    final readmeSnippet = _buildReadmeSnippet(ir);
    final fileNameByType = <String, String>{
      for (final klass in ir.classes)
        klass.name: '${_Naming.fileNameFromType(klass.name)}.dart',
      for (final enumeration in ir.enums)
        enumeration.name: '${_Naming.fileNameFromType(enumeration.name)}.dart',
      for (final mixedEnum in ir.mixedEnums)
        mixedEnum.name: '${_Naming.fileNameFromType(mixedEnum.name)}.dart',
    };
    for (final helper in ir.helpers) {
      fileNameByType[helper.name] = helper.fileName;
    }
    final unionByBase = {
      for (final union in ir.unions) union.baseClass.name: union,
    };
    final unionVariantLookup = {
      for (final union in ir.unions)
        for (final variant in union.variants) variant.classSpec.name: union,
    };

    for (final union in ir.unions) {
      final baseFile = '${_Naming.fileNameFromType(union.baseClass.name)}.dart';
      // Map base class to its file
      fileNameByType[union.baseClass.name] = baseFile;
      // Map variants to base file
      for (final variant in union.variants) {
        final variantName = variant.classSpec.name;
        if (unionByBase.containsKey(variantName)) {
          continue;
        }
        fileNameByType[variantName] = baseFile;
      }
    }

    // Map enums to their files
    for (final enumeration in ir.enums) {
      final fileName = '${_Naming.fileNameFromType(enumeration.name)}.dart';
      fileNameByType[enumeration.name] = fileName;
    }

    // Map mixed enums to their files
    for (final mixedEnum in ir.mixedEnums) {
      final fileName = '${_Naming.fileNameFromType(mixedEnum.name)}.dart';
      fileNameByType[mixedEnum.name] = fileName;
    }

    // Map regular classes to their files (those not already mapped as union variants)
    for (final klass in ir.classes) {
      if (!fileNameByType.containsKey(klass.name)) {
        final fileName = '${_Naming.fileNameFromType(klass.name)}.dart';
        fileNameByType[klass.name] = fileName;
      }
    }

    final emittedClasses = <String>{};
    final partFiles = <String>{};

    for (final klass in ir.classes) {
      if (emittedClasses.contains(klass.name)) {
        continue;
      }
      final fileName = '${_Naming.fileNameFromType(klass.name)}.dart';
      final union = unionByBase[klass.name];
      if (union != null) {
        final variantClasses = union.variants
            .map((variant) => variant.classSpec)
            .toList();
        final variantNames = variantClasses
            .map((variant) => variant.name)
            .toSet();

        final dependencies = _dependenciesForClass(
          klass,
          unionByBase: unionByBase,
          unionVariants: unionVariantLookup,
        ).where((type) => !variantNames.contains(type)).toSet();

        // Separate class variants from enum/mixed enum variants and existing sealed classes
        final classVariants = <IrClass>[];
        final enumVariantNames = <String>{};
        final allEnumNames = {
          ...ir.enums.map((e) => e.name),
          ...ir.mixedEnums.map((e) => e.name),
        };

        for (var i = 0; i < variantClasses.length; i++) {
          final variant = variantClasses[i];
          final variantSpec = union.variants[i];
          final variantName = variant.name;
          
          // Collect dependencies from ALL variants regardless of type
          final variantDeps = _dependenciesForClass(
            variant,
            unionByBase: unionByBase,
            unionVariants: unionVariantLookup,
          ).where((type) => type != klass.name && !variantNames.contains(type));
          dependencies.addAll(variantDeps);
          
          // Also collect from primitive type if this is a primitive wrapper
          if (variantSpec.primitiveType != null) {
            final primDeps = <String>{};
            _collectTypeDependencies(
              variantSpec.primitiveType!,
              primDeps,
              owner: klass.name,
              unionVariants: unionVariantLookup,
            );
            dependencies.addAll(primDeps.where((type) => !variantNames.contains(type)));
          }
          
          // If variant is an enum, import it
          if (allEnumNames.contains(variantName)) {
            enumVariantNames.add(variantName);
            dependencies.add(variantName); // Add enum as dependency to be imported
          } 
          // If variant is itself a sealed base class from another union, import it
          else if (unionByBase.containsKey(variantName)) {
            dependencies.add(variantName); // Import the sealed base class
          }
          // Otherwise it's a class variant specific to this union, use as part
          else {
            classVariants.add(variant);
          }
        }

        final content = StringBuffer()
          ..write(_buildHeader())
          ..write(
            _renderImports(
              dependencies: dependencies,
              fileNameByType: fileNameByType,
              currentFile: fileName,
            ),
          );
        // Render the sealed base class
        content.write(emitter.renderClass(klass));
        // Render all class variants directly in the same file
        for (final variant in classVariants) {
          content.write(emitter.renderClass(variant));
          emittedClasses.add(variant.name);
        }
        files[fileName] = content.toString();
        emittedClasses.add(klass.name);
        continue;
      }

      final variantUnion = unionVariantLookup[klass.name];
      if (variantUnion != null) {
        // Skip - variants are already emitted with their base class
        continue;
      }

      final content = StringBuffer()
        ..write(_buildHeader())
        ..write(
          _renderImports(
            dependencies: _dependenciesForClass(
              klass,
              unionByBase: unionByBase,
              unionVariants: unionVariantLookup,
            ),
            fileNameByType: fileNameByType,
            currentFile: fileName,
          ),
        )
        ..write(emitter.renderClass(klass));
      files[fileName] = content.toString();
      emittedClasses.add(klass.name);
    }

    for (final enumeration in ir.enums) {
      final fileName = '${_Naming.fileNameFromType(enumeration.name)}.dart';
      final content = StringBuffer()
        ..write(_buildHeader())
        ..write(emitter.renderEnum(enumeration));
      files[fileName] = content.toString();
    }

    for (final mixedEnum in ir.mixedEnums) {
      final fileName = '${_Naming.fileNameFromType(mixedEnum.name)}.dart';
      final content = StringBuffer()
        ..write(_buildHeader())
        ..write(emitter.renderMixedEnum(mixedEnum));
      files[fileName] = content.toString();
    }

    for (final helper in ir.helpers) {
      final content = StringBuffer()..write(_buildHeader());
      if (helper.imports.isNotEmpty) {
        for (final import in helper.imports) {
          content.writeln("import '$import';");
        }
        content.writeln();
      }
      content.write(helper.code.trim());
      content.writeln();
      files[helper.fileName] = content.toString();
    }

    final barrel = StringBuffer()..write(_buildHeader());
    for (final entry in files.keys) {
      if (partFiles.contains(entry)) {
        continue;
      }
      barrel.writeln("export '$partsDirectory/$entry';");
    }

    return MultiOutputPlan(
      barrel: barrel.toString(),
      files: LinkedHashMap.of(files),
      partsDirectory: partsDirectory,
      readmeFileName: readmeSnippet != null ? 'README.schema.md' : null,
      readmeContents: readmeSnippet,
    );
  }

  String _buildHeader() {
    final buffer = StringBuffer()
      ..writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
    if (options.sourcePath != null) {
      buffer.writeln('// Source: ${options.sourcePath}');
    }
    final header = options.effectiveHeader.trim();
    if (header.isNotEmpty) {
      buffer.writeln('// $header');
    }
    
    // Add usage documentation if enabled
    if (options.emitUsageDocs) {
      buffer.writeln('//');
      buffer.writeln('// To parse JSON data:');
      buffer.writeln('//');
      buffer.writeln("//     import 'dart:convert';");
      buffer.writeln('//');
      buffer.writeln('//     final obj = ClassName.fromJson(jsonDecode(jsonString));');
      buffer.writeln('//     final jsonString = jsonEncode(obj.toJson());');
      if (options.generateHelpers) {
        buffer.writeln('//');
        buffer.writeln('// Or use the helper functions:');
        buffer.writeln('//');
        buffer.writeln('//     final obj = classNameFromJson(jsonString);');
        buffer.writeln('//     final jsonString = classNameToJson(obj);');
      }
    }
    
    buffer.writeln();
    return buffer.toString();
  }

  Iterable<String> _dependenciesForClass(
    IrClass klass, {
    required Map<String, IrUnion> unionByBase,
    required Map<String, IrUnion> unionVariants,
  }) {
    final collected = <String>{};
    final unionBaseNames = unionByBase.keys.toSet();
    for (final property in klass.properties) {
      _collectTypeDependencies(
        property.typeRef,
        collected,
        owner: klass.name,
        unionVariants: unionVariants,
        unionBaseNames: unionBaseNames,
      );
    }

    final additionalField = klass.additionalPropertiesField;
    if (additionalField != null) {
      _collectTypeDependencies(
        additionalField.valueType,
        collected,
        owner: klass.name,
        unionVariants: unionVariants,
        unionBaseNames: unionBaseNames,
      );
    }

    final unevaluatedField = klass.unevaluatedPropertiesField;
    if (unevaluatedField != null) {
      _collectTypeDependencies(
        unevaluatedField.valueType,
        collected,
        owner: klass.name,
        unionVariants: unionVariants,
        unionBaseNames: unionBaseNames,
      );
    }

    final patternField = klass.patternPropertiesField;
    if (patternField != null) {
      _collectTypeDependencies(
        patternField.valueType,
        collected,
        owner: klass.name,
        unionVariants: unionVariants,
        unionBaseNames: unionBaseNames,
      );
      for (final matcher in patternField.matchers) {
        _collectTypeDependencies(
          matcher.typeRef,
          collected,
          owner: klass.name,
          unionVariants: unionVariants,
          unionBaseNames: unionBaseNames,
        );
      }
    }

    for (final constraint in klass.dependentSchemas.values) {
      final ref = constraint.typeRef;
      if (ref != null) {
        _collectTypeDependencies(
        ref,
        collected,
        owner: klass.name,
        unionVariants: unionVariants,
        unionBaseNames: unionBaseNames,
      );
    }
    }

    final baseUnion = unionByBase[klass.name];
    if (baseUnion != null) {
      collected.addAll(
        baseUnion.variants.map((variant) => variant.classSpec.name),
      );
    }

    final variantUnion = unionVariants[klass.name];
    if (variantUnion != null) {
      collected.add(variantUnion.baseClass.name);
    }

    if (options.emitValidationHelpers) {
      collected.add('ValidationError');
    }

    return collected;
  }

  void _collectTypeDependencies(
    TypeRef ref,
    Set<String> out, {
    required String owner,
    Map<String, IrUnion>? unionVariants,
    Set<String>? unionBaseNames,
  }) {
    if (ref is ValidatedTypeRef) {
      _collectTypeDependencies(
        ref.inner,
        out,
        owner: owner,
        unionVariants: unionVariants,
        unionBaseNames: unionBaseNames,
      );
      return;
    }
    if (ref is ObjectTypeRef) {
      var name = ref.spec.name;
      if (name != owner) {
        // If this type is a variant of a union, depend on the base class instead
        if (unionVariants != null) {
          final variantUnion = unionVariants[name];
          if (variantUnion != null &&
              (unionBaseNames == null || !unionBaseNames.contains(name))) {
            name = variantUnion.baseClass.name;
          }
        }
        out.add(name);
      }
    } else if (ref is EnumTypeRef) {
      out.add(ref.spec.name);
    } else if (ref is FormatTypeRef) {
      final helper = ref.helperTypeName;
      if (helper != null) {
        out.add(helper);
      }
    } else if (ref is ListTypeRef) {
      _collectTypeDependencies(
        ref.itemType,
        out,
        owner: owner,
        unionVariants: unionVariants,
        unionBaseNames: unionBaseNames,
      );
      for (final type in ref.prefixItemTypes) {
        _collectTypeDependencies(
          type,
          out,
          owner: owner,
          unionVariants: unionVariants,
          unionBaseNames: unionBaseNames,
        );
      }
      final containsType = ref.containsType;
      if (containsType != null) {
        _collectTypeDependencies(
          containsType,
          out,
          owner: owner,
          unionVariants: unionVariants,
          unionBaseNames: unionBaseNames,
        );
      }
      final unevaluatedItemsType = ref.unevaluatedItemsType;
      if (unevaluatedItemsType != null) {
        _collectTypeDependencies(
          unevaluatedItemsType,
          out,
          owner: owner,
          unionVariants: unionVariants,
          unionBaseNames: unionBaseNames,
        );
      }
    }
  }

  String _renderImports({
    required Iterable<String> dependencies,
    required Map<String, String> fileNameByType,
    required String currentFile,
  }) {
    final entries =
        dependencies
            .map((type) => fileNameByType[type])
            .whereType<String>()
            .where((file) => file != currentFile)
            .toSet()
            .toList()
          ..sort();
    if (entries.isEmpty) {
      return '';
    }
    final buffer = StringBuffer();
    for (final file in entries) {
      buffer.writeln("import '$file';");
    }
    buffer.writeln();
    return buffer.toString();
  }

  String? _buildReadmeSnippet(SchemaIr ir) {
    if (!options.emitReadmeSnippets) {
      return null;
    }

    final buffer = StringBuffer();
    final rootClass = ir.rootClass;
    final rootDescription = rootClass.description?.trim();

    buffer.writeln('# Schema Summary: ${options.effectiveRootClassName}');
    buffer.writeln();

    if (options.sourcePath != null) {
      buffer.writeln('- Source: `${options.sourcePath}`');
    }
    buffer.writeln('- Root type: `${rootClass.name}`');
    buffer.writeln('- Classes: ${ir.classes.length}');
    buffer.writeln('- Enums: ${ir.enums.length}');
    buffer.writeln(
      '- Format hints: ${options.enableFormatHints ? 'enabled' : 'disabled'}',
    );
    buffer.writeln(
      '- Format assertions: ${options.enableFormatAssertions ? 'enabled' : 'disabled'}',
    );
    buffer.writeln(
      '- Validation helpers: ${options.emitValidationHelpers ? 'enabled' : 'disabled'}',
    );
    buffer.writeln(
      '- Content validation: ${options.enableContentValidation ? 'enabled' : 'disabled'}',
    );
    buffer.writeln();

    if (rootDescription != null && rootDescription.isNotEmpty) {
      buffer.writeln(rootDescription);
      buffer.writeln();
    }

    final rootProperties = rootClass.properties;
    if (rootProperties.isNotEmpty) {
      buffer.writeln('## Root Properties');
      buffer.writeln();
      buffer.writeln('| Property | Type | Notes |');
      buffer.writeln('| --- | --- | --- |');
      for (final property in rootProperties) {
        final notes = property.description?.split('\n').first.trim();
        final sanitizedNotes = (notes == null || notes.isEmpty)
            ? '—'
            : notes.replaceAll('|', '\\|');
        buffer.writeln(
          '| `${property.jsonName}` | `${property.dartType}` | $sanitizedNotes |',
        );
      }
      buffer.writeln();
    }

    if (ir.enums.isNotEmpty) {
      buffer.writeln('## Enums');
      buffer.writeln();
      for (final enumeration in ir.enums) {
        buffer.writeln(
          '- `${enumeration.name}` (${enumeration.values.length} values)',
        );
      }
      buffer.writeln();
    }

    buffer.writeln('## Generator Options');
    buffer.writeln();
    buffer.writeln(
      '- `enableFormatHints`: ${options.enableFormatHints ? 'true' : 'false'}',
    );
    buffer.writeln(
      '- `enableFormatAssertions`: ${options.enableFormatAssertions ? 'true' : 'false'}',
    );
    buffer.writeln(
      '- `emitValidationHelpers`: ${options.emitValidationHelpers ? 'true' : 'false'}',
    );
    buffer.writeln(
      '- `emitReadmeSnippets`: ${options.emitReadmeSnippets ? 'true' : 'false'}',
    );
    buffer.writeln(
      '- `enableContentValidation`: ${options.enableContentValidation ? 'true' : 'false'}',
    );

    return buffer.toString();
  }

  String _sanitizeBaseName(String baseName) {
    return baseName
        .replaceAll(RegExp(r'[^a-zA-Z0-9]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '')
        .toLowerCase();
  }

  Uri _inferBaseUri() {
    final path = options.sourcePath;
    if (path == null || path.isEmpty) {
      return Uri.parse('$_memoryScheme://schema.json');
    }
    final normalized = p.normalize(path);
    final absolute = p.isAbsolute(normalized)
        ? normalized
        : p.join(Directory.current.path, normalized);
    return Uri.file(absolute);
  }
}

typedef SchemaDocumentLoader = Map<String, dynamic> Function(Uri uri);

class MultiOutputPlan {
  MultiOutputPlan({
    required this.barrel,
    required this.files,
    required this.partsDirectory,
    this.readmeFileName,
    this.readmeContents,
  });

  final String barrel;
  final LinkedHashMap<String, String> files;
  final String partsDirectory;
  final String? readmeFileName;
  final String? readmeContents;
}

class _DefaultSchemaDocumentLoader {
  _DefaultSchemaDocumentLoader({
    required this.allowNetworkRefs,
    this.allowedNetworkHosts,
    this.allowedFilePaths,
    this.cacheDirectoryPath,
    this.onWarning,
  });

  final bool allowNetworkRefs;
  final List<String>? allowedNetworkHosts;
  final List<String>? allowedFilePaths;
  final String? cacheDirectoryPath;
  final void Function(String message)? onWarning;
  Directory? _cacheDirectory;

  Map<String, dynamic> call(Uri uri) {
    final resolved = _ensureScheme(uri);
    if (resolved.scheme == 'file') {
      if (allowedFilePaths != null && allowedFilePaths!.isNotEmpty) {
        final filePath = resolved.toFilePath();
        final isAllowed = allowedFilePaths!.any((allowedPath) {
          return filePath.startsWith(allowedPath);
        });
        if (!isAllowed) {
          throw StateError(
            'File path $filePath is not in the allowed paths: '
            '${allowedFilePaths!.join(", ")}',
          );
        }
      }
      final file = File.fromUri(resolved);
      if (!file.existsSync()) {
        throw ArgumentError('Referenced schema not found at $resolved');
      }
      return _decodeDocument(file.readAsStringSync(), resolved.toString());
    }

    if (resolved.scheme == 'http' || resolved.scheme == 'https') {
      if (!allowNetworkRefs) {
        throw StateError(
          'Network references are disabled. Unable to load $resolved. '
          'Consider vendoring the schema locally or enable allow_network_refs.',
        );
      }
      if (allowedNetworkHosts != null && allowedNetworkHosts!.isNotEmpty) {
        final host = resolved.host;
        if (!allowedNetworkHosts!.contains(host)) {
          throw StateError(
            'Network host $host is not in the allowed hosts: '
            '${allowedNetworkHosts!.join(", ")}',
          );
        }
      }
      final cacheFile = _prepareCacheFile(resolved);
      if (cacheFile != null && cacheFile.existsSync()) {
        onWarning?.call(
          'Using cached copy for $resolved (cached at ${cacheFile.path}).',
        );
        return _decodeDocument(
          cacheFile.readAsStringSync(),
          resolved.toString(),
        );
      }
      final contents = _download(resolved);
      if (cacheFile != null) {
        cacheFile.createSync(recursive: true);
        cacheFile.writeAsStringSync(contents);
        onWarning?.call(
          'Fetched $resolved and cached at ${cacheFile.path}. '
          'Consider vendoring the schema for reproducible builds.',
        );
      }
      return _decodeDocument(contents, resolved.toString());
    }

    throw UnsupportedError('Unsupported schema reference scheme: $resolved');
  }

  Uri _ensureScheme(Uri uri) {
    if (uri.scheme.isEmpty) {
      if (uri.path.isEmpty) {
        return Uri.file(uri.toString());
      }
      return Uri.file(uri.toFilePath());
    }
    return uri;
  }

  File? _prepareCacheFile(Uri uri) {
    if (cacheDirectoryPath == null || cacheDirectoryPath!.isEmpty) {
      return null;
    }
    _cacheDirectory ??= Directory(cacheDirectoryPath!);
    final hash = base64UrlEncode(
      utf8.encode(uri.toString()),
    ).replaceAll('=', '');
    final fileName = '$hash.json';
    final dir = _cacheDirectory!;
    return File(p.join(dir.path, fileName));
  }

  String _download(Uri uri) {
    final client = HttpClient();
    client.autoUncompress = true;
    try {
      final request = _waitFor(client.getUrl(uri));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = _waitFor(request.close());
      if (response.statusCode >= 400) {
        throw StateError(
          'Failed to fetch $uri (status ${response.statusCode}).',
        );
      }
      final completer = Completer<String>();
      final buffer = StringBuffer();
      response
          .transform(utf8.decoder)
          .listen(
            buffer.write,
            onDone: () => completer.complete(buffer.toString()),
            onError: completer.completeError,
            cancelOnError: true,
          );
      return _waitFor(completer.future);
    } finally {
      client.close();
    }
  }

  Map<String, dynamic> _decodeDocument(String contents, String origin) {
    final decoded = jsonDecode(contents);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded == true) {
      return <String, dynamic>{};
    }
    if (decoded == false) {
      return <String, dynamic>{'type': 'never'};
    }
    throw StateError('Schema at $origin is not a JSON object.');
  }

  T _waitFor<T>(Future<T> future) {
    T? result;
    Object? error;
    StackTrace? stackTrace;
    var completed = false;
    future.then(
      (value) {
        result = value;
        completed = true;
      },
      onError: (Object err, StackTrace st) {
        error = err;
        stackTrace = st;
        completed = true;
      },
    );
    while (!completed) {
      sleep(const Duration(milliseconds: 10));
    }
    if (error != null) {
      Error.throwWithStackTrace(error!, stackTrace!);
    }
    return result as T;
  }
}
