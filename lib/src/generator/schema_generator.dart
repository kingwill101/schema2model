part of 'package:schemamodeschema/src/generator.dart';

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
      for (final variant in union.variants) {
        fileNameByType[variant.classSpec.name] = baseFile;
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

        for (final variant in variantClasses) {
          final variantDeps = _dependenciesForClass(
            variant,
            unionByBase: unionByBase,
            unionVariants: unionVariantLookup,
          ).where((type) => type != klass.name && !variantNames.contains(type));
          dependencies.addAll(variantDeps);
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
        for (final variant in variantClasses) {
          final partFile = '${_Naming.fileNameFromType(variant.name)}.dart';
          content.writeln("part '$partFile';");
        }
        if (variantClasses.isNotEmpty) {
          content.writeln();
        }
        content.write(emitter.renderClass(klass));
        files[fileName] = content.toString();
        emittedClasses.add(klass.name);
        continue;
      }

      final variantUnion = unionVariantLookup[klass.name];
      if (variantUnion != null) {
        final baseFile =
            '${_Naming.fileNameFromType(variantUnion.baseClass.name)}.dart';
        final content = StringBuffer()
          ..write(_buildHeader())
          ..writeln("part of '$baseFile';")
          ..writeln()
          ..write(emitter.renderClass(klass));
        files[fileName] = content.toString();
        partFiles.add(fileName);
        emittedClasses.add(klass.name);
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
    buffer.writeln();
    return buffer.toString();
  }

  Iterable<String> _dependenciesForClass(
    IrClass klass, {
    required Map<String, IrUnion> unionByBase,
    required Map<String, IrUnion> unionVariants,
  }) {
    final collected = <String>{};
    for (final property in klass.properties) {
      _collectTypeDependencies(property.typeRef, collected, owner: klass.name);
    }

    final additionalField = klass.additionalPropertiesField;
    if (additionalField != null) {
      _collectTypeDependencies(
        additionalField.valueType,
        collected,
        owner: klass.name,
      );
    }

    final patternField = klass.patternPropertiesField;
    if (patternField != null) {
      _collectTypeDependencies(
        patternField.valueType,
        collected,
        owner: klass.name,
      );
      for (final matcher in patternField.matchers) {
        _collectTypeDependencies(matcher.typeRef, collected, owner: klass.name);
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

    if (_classNeedsValidation(klass, options)) {
      collected.add('ValidationError');
    }

    return collected;
  }

  void _collectTypeDependencies(
    TypeRef ref,
    Set<String> out, {
    required String owner,
  }) {
    if (ref is ObjectTypeRef) {
      final name = ref.spec.name;
      if (name != owner) {
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
      _collectTypeDependencies(ref.itemType, out, owner: owner);
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
      '- Validation helpers: ${options.emitValidationHelpers ? 'enabled' : 'disabled'}',
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
      '- `emitValidationHelpers`: ${options.emitValidationHelpers ? 'true' : 'false'}',
    );
    buffer.writeln(
      '- `emitReadmeSnippets`: ${options.emitReadmeSnippets ? 'true' : 'false'}',
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

class _SchemaEmitter {
  _SchemaEmitter(this.options);

  final SchemaGeneratorOptions options;
  Map<String, IrUnion> _unionByBaseName = const {};
  Map<String, _UnionVariantView> _unionVariantByClass = const {};

  void setUnions(List<IrUnion> unions) {
    _unionByBaseName = {
      for (final union in unions) union.baseClass.name: union,
    };
    final variants = <String, _UnionVariantView>{};
    for (final union in unions) {
      for (final variant in union.variants) {
        variants[variant.classSpec.name] = _UnionVariantView(
          union: union,
          variant: variant,
        );
      }
    }
    _unionVariantByClass = variants;
  }

  String renderLibrary(SchemaIr ir) {
    setUnions(ir.unions);
    final buffer = StringBuffer();
    for (var i = 0; i < ir.classes.length; i++) {
      buffer.write(renderClass(ir.classes[i]));
      final isLastClass = i == ir.classes.length - 1;
      final hasEnums = ir.enums.isNotEmpty;
      final hasHelpers = ir.helpers.isNotEmpty;
      if (!isLastClass || hasEnums || hasHelpers) {
        buffer.writeln();
      }
    }

    for (var i = 0; i < ir.enums.length; i++) {
      buffer.write(renderEnum(ir.enums[i]));
      if (i != ir.enums.length - 1) {
        buffer.writeln();
      }
      if (ir.helpers.isNotEmpty && i == ir.enums.length - 1) {
        buffer.writeln();
      }
    }

    if (ir.helpers.isNotEmpty) {
      final helperCount = ir.helpers.length;
      for (var i = 0; i < helperCount; i++) {
        final helper = ir.helpers[i];
        buffer.write(helper.code.trim());
        buffer.writeln();
        if (i != helperCount - 1) {
          buffer.writeln();
        }
      }
    }
    return buffer.toString();
  }

  String renderClass(IrClass klass) {
    final union = _unionByBaseName[klass.name];
    if (union != null) {
      return _renderUnionBase(klass, union);
    }
    final variantView = _unionVariantByClass[klass.name];
    if (variantView != null) {
      return _renderUnionVariant(klass, variantView.union, variantView.variant);
    }
    return _renderPlainClass(klass);
  }

  String _renderPlainClass(IrClass klass) {
    final buffer = StringBuffer();
    if (klass.description != null && klass.description!.trim().isNotEmpty) {
      _writeDocumentation(buffer, klass.description!);
    }

    final extendsClause = klass.superClassName != null
        ? ' extends ${klass.superClassName}'
        : '';
    buffer.writeln('class ${klass.name}$extendsClause {');
    _writeFieldDeclarations(buffer, klass);
    buffer.writeln();
    final superInitializer = klass.superClassName != null ? ': super()' : null;
    _writeConstructor(buffer, klass, superInitializer: superInitializer);
    buffer.writeln();
    _writeFromJson(buffer, klass);
    buffer.writeln();
    _writeToJson(buffer, klass);
    if (_classNeedsValidation(klass, options)) {
      buffer.writeln();
      _writeValidate(buffer, klass, override: false);
    }
    buffer.writeln('}');
    return buffer.toString();
  }

  String _renderUnionBase(IrClass klass, IrUnion union) {
    final buffer = StringBuffer();
    if (klass.description != null && klass.description!.trim().isNotEmpty) {
      _writeDocumentation(buffer, klass.description!);
    }

    buffer.writeln('sealed class ${klass.name} {');
    buffer.writeln('  const ${klass.name}();');
    buffer.writeln();
    if (options.emitValidationHelpers) {
      buffer.writeln("  void validate({String pointer = ''});");
      buffer.writeln();
    }
    buffer.writeln(
      '  factory ${klass.name}.fromJson(Map<String, dynamic> json) {',
    );

    final discriminator = union.discriminator;
    if (discriminator != null && discriminator.mapping.isNotEmpty) {
      buffer.writeln(
        "    final discriminator = json['${discriminator.propertyName}'];",
      );
      buffer.writeln('    if (discriminator is String) {');
      buffer.writeln('      switch (discriminator) {');
      for (final entry in discriminator.mapping.entries) {
        final variant = union.variants.firstWhereOrNull(
          (candidate) => candidate.discriminatorValue == entry.key,
        );
        if (variant == null) {
          continue;
        }
        buffer.writeln('        case ${_stringLiteral(entry.key)}:');
        buffer.writeln(
          '          return ${variant.classSpec.name}.fromJson(json);',
        );
      }
      buffer.writeln('      }');
      buffer.writeln('    }');
    }

    buffer.writeln('    final keys = json.keys.toSet();');
    buffer.writeln('    final sortedKeys = keys.toList()..sort();');

    final constVariants = union.variants
        .where((variant) => variant.constProperties.isNotEmpty)
        .toList();
    if (constVariants.isNotEmpty) {
      buffer.writeln(
        '    final constMatches = <${klass.name} Function(Map<String, dynamic>)>[];',
      );
      buffer.writeln("    final constMatchNames = <String>[];");
      for (final variant in constVariants) {
        final conditions = variant.constProperties.entries
            .map((entry) {
              final literal = _literalExpression(entry.value);
              return "json['${entry.key}'] == $literal";
            })
            .join(' && ');
        buffer.writeln('    if ($conditions) {');
        buffer.writeln(
          '      constMatches.add(${variant.classSpec.name}.fromJson);',
        );
        buffer.writeln(
          "      constMatchNames.add('${variant.classSpec.name}');",
        );
        buffer.writeln('    }');
      }
      buffer.writeln('    if (constMatches.length == 1) {');
      buffer.writeln('      return constMatches.single(json);');
      buffer.writeln('    }');
      buffer.writeln('    if (constMatches.length > 1) {');
      buffer.writeln(
        "      throw ArgumentError('Ambiguous ${klass.name} variant matched const heuristics: \${constMatchNames.join(', ')}');",
      );
      buffer.writeln('    }');
    }

    final requiredVariants = union.variants
        .where((variant) => variant.requiredProperties.isNotEmpty)
        .toList();
    if (requiredVariants.isNotEmpty) {
      buffer.writeln(
        '    final requiredMatches = <${klass.name} Function(Map<String, dynamic>)>[];',
      );
      buffer.writeln("    final requiredMatchNames = <String>[];");
      for (final variant in requiredVariants) {
        final conditions = variant.requiredProperties
            .map((prop) {
              return "keys.contains('$prop')";
            })
            .join(' && ');
        buffer.writeln('    if ($conditions) {');
        buffer.writeln(
          '      requiredMatches.add(${variant.classSpec.name}.fromJson);',
        );
        buffer.writeln(
          "      requiredMatchNames.add('${variant.classSpec.name}');",
        );
        buffer.writeln('    }');
      }
      buffer.writeln('    if (requiredMatches.length == 1) {');
      buffer.writeln('      return requiredMatches.single(json);');
      buffer.writeln('    }');
      buffer.writeln('    if (requiredMatches.length > 1) {');
      buffer.writeln(
        "      throw ArgumentError('Ambiguous ${klass.name} variant matched required-property heuristics: \${requiredMatchNames.join(', ')}');",
      );
      buffer.writeln('    }');
    }

    if (union.variants.length == 1) {
      buffer.writeln(
        '    return ${union.variants.single.classSpec.name}.fromJson(json);',
      );
    } else {
      buffer.writeln(
        "    throw ArgumentError('No ${klass.name} variant matched heuristics (keys: \${sortedKeys.join(', ')}).');",
      );
    }

    buffer.writeln('  }');
    buffer.writeln();
    buffer.writeln('  Map<String, dynamic> toJson();');
    buffer.writeln('}');
    return buffer.toString();
  }

  String _renderUnionVariant(
    IrClass klass,
    IrUnion union,
    IrUnionVariant variant,
  ) {
    final buffer = StringBuffer();
    if (klass.description != null && klass.description!.trim().isNotEmpty) {
      _writeDocumentation(buffer, klass.description!);
    }

    buffer.writeln('class ${klass.name} extends ${union.baseClass.name} {');
    _writeFieldDeclarations(buffer, klass);
    buffer.writeln();
    _writeConstructor(buffer, klass, superInitializer: ': super()');
    buffer.writeln();
    _writeFromJson(buffer, klass);
    buffer.writeln();
    _writeToJson(
      buffer,
      klass,
      override: true,
      discriminatorKey: union.discriminator?.propertyName,
      discriminatorValue: variant.discriminatorValue,
    );
    if (_classNeedsValidation(klass, options)) {
      buffer.writeln();
      _writeValidate(buffer, klass, override: true);
    }
    buffer.writeln('}');
    return buffer.toString();
  }

  String renderEnum(IrEnum enumeration) {
    final buffer = StringBuffer();
    if (options.emitDocumentation && enumeration.description != null) {
      _writeDocumentation(buffer, enumeration.description!);
    }

    final values = enumeration.values.map((v) => v.identifier).join(', ');
    buffer.writeln('enum ${enumeration.name} { $values }');
    buffer.writeln();
    buffer.writeln(
      'extension ${enumeration.extensionName} on ${enumeration.name} {',
    );
    buffer.writeln('  String toJson() => const {');
    for (final value in enumeration.values) {
      buffer.writeln(
        '        ${enumeration.name}.${value.identifier}: ${_stringLiteral(value.jsonValue)},',
      );
    }
    buffer.writeln('      }[this]!;');
    buffer.writeln();
    buffer.writeln(
      '  static ${enumeration.name} fromJson(String value) => const {',
    );
    for (final value in enumeration.values) {
      buffer.writeln(
        '        ${_stringLiteral(value.jsonValue)}: ${enumeration.name}.${value.identifier},',
      );
    }
    buffer.writeln('      }[value]!;');
    buffer.writeln('}');
    return buffer.toString();
  }

  static void _writeDocumentation(
    StringBuffer buffer,
    String doc, {
    String indent = '',
  }) {
    if (doc.trim().isEmpty) {
      return;
    }
    final lines = doc.split('\n');
    for (final line in lines) {
      buffer.writeln('$indent/// ${line.trim()}');
    }
  }

  static String _stringLiteral(String value) {
    final escaped = value
        .replaceAll('\\', r'\\')
        .replaceAll("'", r"\'")
        .replaceAll(r'$', r'\$');
    return "'$escaped'";
  }

  static String _literalExpression(Object? value) {
    if (value is String) {
      return _stringLiteral(value);
    }
    if (value is num || value is bool) {
      return value.toString();
    }
    if (value == null) {
      return 'null';
    }
    return _stringLiteral(value.toString());
  }

  void _writeFieldDeclarations(StringBuffer buffer, IrClass klass) {
    for (final property in klass.properties) {
      if (property.description != null &&
          property.description!.trim().isNotEmpty) {
        _writeDocumentation(buffer, property.description!, indent: '  ');
      }
      buffer.writeln('  final ${property.dartType} ${property.fieldName};');
    }

    final patternField = klass.patternPropertiesField;
    if (patternField != null) {
      buffer.writeln(
        '  final ${patternField.mapType()} ${patternField.fieldName};',
      );
    }

    final additionalField = klass.additionalPropertiesField;
    if (additionalField != null) {
      if (additionalField.description != null &&
          additionalField.description!.trim().isNotEmpty) {
        _writeDocumentation(buffer, additionalField.description!, indent: '  ');
      }
      buffer.writeln(
        '  final ${additionalField.mapType()} ${additionalField.fieldName};',
      );
    }
  }

  void _writeConstructor(
    StringBuffer buffer,
    IrClass klass, {
    String? superInitializer,
  }) {
    final hasFields =
        klass.properties.isNotEmpty ||
        klass.patternPropertiesField != null ||
        klass.additionalPropertiesField != null;
    if (!hasFields) {
      buffer.writeln('  const ${klass.name}()${superInitializer ?? ''};');
      return;
    }

    buffer.writeln('  const ${klass.name}({');
    for (final property in klass.properties) {
      if (property.isRequired) {
        buffer.writeln('    required this.${property.fieldName},');
      } else {
        buffer.writeln('    this.${property.fieldName},');
      }
    }

    final patternField = klass.patternPropertiesField;
    if (patternField != null) {
      buffer.writeln('    this.${patternField.fieldName},');
    }

    final additionalField = klass.additionalPropertiesField;
    if (additionalField != null) {
      buffer.writeln('    this.${additionalField.fieldName},');
    }

    final initializerSuffix =
        superInitializer != null && superInitializer.isNotEmpty
        ? ' $superInitializer'
        : '';
    buffer.writeln('  })$initializerSuffix;');
  }

  void _writeFromJson(StringBuffer buffer, IrClass klass) {
    buffer.writeln(
      '  factory ${klass.name}.fromJson(Map<String, dynamic> json) {',
    );
    buffer.writeln('    final remaining = Map<String, dynamic>.from(json);');
    for (final property in klass.properties) {
      buffer.writeln(
        '    final ${property.fieldName} = ${property.deserializeExpression('json')};',
      );
      buffer.writeln("    remaining.remove('${property.jsonName}');");
    }
    buffer.writeln('    var unmatched = Map<String, dynamic>.from(remaining);');

    final patternField = klass.patternPropertiesField;
    if (patternField != null) {
      final valueType = patternField.valueType.dartType();
      buffer.writeln(
        '    Map<String, $valueType>? ${patternField.fieldName}Value;',
      );
      buffer.writeln('    {');
      buffer.writeln(
        '      final ${patternField.fieldName}Map = <String, $valueType>{};',
      );
      buffer.writeln(
        '      final unmatchedAfterPattern = <String, dynamic>{};',
      );
      buffer.writeln('      for (final entry in unmatched.entries) {');
      buffer.writeln('        final key = entry.key;');
      buffer.writeln('        final value = entry.value;');
      buffer.writeln('        var matched = false;');
      for (var i = 0; i < patternField.matchers.length; i++) {
        final matcher = patternField.matchers[i];
        final condition =
            'RegExp(${_stringLiteral(matcher.pattern)}).hasMatch(key)';
        buffer.writeln('        if (!matched && $condition) {');
        final converted = matcher.typeRef.deserializeInline(
          'value',
          required: true,
        );
        buffer.writeln(
          '          ${patternField.fieldName}Map[key] = $converted;',
        );
        buffer.writeln('          matched = true;');
        buffer.writeln('        }');
      }
      buffer.writeln('        if (!matched) {');
      buffer.writeln('          unmatchedAfterPattern[key] = value;');
      buffer.writeln('        }');
      buffer.writeln('      }');
      buffer.writeln(
        '      ${patternField.fieldName}Value = ${patternField.fieldName}Map.isEmpty ? null : ${patternField.fieldName}Map;',
      );
      buffer.writeln('      unmatched = unmatchedAfterPattern;');
      buffer.writeln('    }');
    }

    final additionalField = klass.additionalPropertiesField;
    if (additionalField != null) {
      final valueType = additionalField.valueType.dartType();
      buffer.writeln(
        '    Map<String, $valueType>? ${additionalField.fieldName}Value;',
      );
      buffer.writeln('    if (unmatched.isNotEmpty) {');
      buffer.writeln(
        '      final ${additionalField.fieldName}Map = <String, $valueType>{};',
      );
      buffer.writeln('      for (final entry in unmatched.entries) {');
      buffer.writeln('        final value = entry.value;');
      final converted = additionalField.valueType.deserializeInline(
        'value',
        required: true,
      );
      buffer.writeln(
        '        ${additionalField.fieldName}Map[entry.key] = $converted;',
      );
      buffer.writeln('      }');
      buffer.writeln(
        '      ${additionalField.fieldName}Value = ${additionalField.fieldName}Map.isEmpty ? null : ${additionalField.fieldName}Map;',
      );
      buffer.writeln('      unmatched = <String, dynamic>{};');
      buffer.writeln('    } else {');
      buffer.writeln('      ${additionalField.fieldName}Value = null;');
      buffer.writeln('    }');
    }

    if (!klass.allowAdditionalProperties) {
      buffer.writeln('    if (unmatched.isNotEmpty) {');
      buffer.writeln(
        "      throw ArgumentError('Unexpected additional properties: \${unmatched.keys.join(', ')}');",
      );
      buffer.writeln('    }');
    }

    buffer.writeln('    return ${klass.name}(');
    for (final property in klass.properties) {
      buffer.writeln('      ${property.fieldName}: ${property.fieldName},');
    }
    if (patternField != null) {
      buffer.writeln(
        '      ${patternField.fieldName}: ${patternField.fieldName}Value,',
      );
    }
    if (additionalField != null) {
      buffer.writeln(
        '      ${additionalField.fieldName}: ${additionalField.fieldName}Value,',
      );
    }
    buffer.writeln('    );');
    buffer.writeln('  }');
  }

  void _writeToJson(
    StringBuffer buffer,
    IrClass klass, {
    bool override = false,
    String? discriminatorKey,
    String? discriminatorValue,
  }) {
    if (override) {
      buffer.writeln('  @override');
    }
    buffer.writeln('  Map<String, dynamic> toJson() {');
    buffer.writeln('    final map = <String, dynamic>{};');

    for (final property in klass.properties) {
      final expression = property.serializeExpression('map');
      if (expression != null) {
        buffer.writeln(expression);
      }
    }

    final patternField = klass.patternPropertiesField;
    if (patternField != null) {
      buffer.writeln('    if (${patternField.fieldName} != null) {');
      buffer.writeln(
        '      for (final entry in ${patternField.fieldName}!.entries) {',
      );
      buffer.writeln('        final key = entry.key;');
      buffer.writeln('        final value = entry.value;');
      buffer.writeln('        var matched = false;');
      for (final matcher in patternField.matchers) {
        final condition =
            'RegExp(${_stringLiteral(matcher.pattern)}).hasMatch(key)';
        final converted = matcher.typeRef.serializeInline(
          'value',
          required: true,
        );
        buffer.writeln('        if (!matched && $condition) {');
        buffer.writeln('          map[key] = $converted;');
        buffer.writeln('          matched = true;');
        buffer.writeln('        }');
      }
      buffer.writeln('        if (!matched) {');
      buffer.writeln('          map[key] = value;');
      buffer.writeln('        }');
      buffer.writeln('      }');
      buffer.writeln('    }');
    }

    final additionalField = klass.additionalPropertiesField;
    if (additionalField != null) {
      final converted = additionalField.valueType.serializeInline(
        'value',
        required: true,
      );
      buffer.writeln('    if (${additionalField.fieldName} != null) {');
      buffer.writeln(
        '      ${additionalField.fieldName}!.forEach((key, value) {',
      );
      buffer.writeln('        map[key] = $converted;');
      buffer.writeln('      });');
      buffer.writeln('    }');
    }

    if (discriminatorKey != null && discriminatorValue != null) {
      buffer.writeln(
        "    map['$discriminatorKey'] = ${_stringLiteral(discriminatorValue)};",
      );
    }

    buffer.writeln('    return map;');
    buffer.writeln('  }');
  }

  void _writeValidate(
    StringBuffer buffer,
    IrClass klass, {
    required bool override,
  }) {
    if (!_classNeedsValidation(klass, options)) {
      if (override) {
        buffer.writeln('  @override');
        buffer.writeln("  void validate({String pointer = ''}) {}");
      }
      return;
    }

    if (override) {
      buffer.writeln('  @override');
    }
    buffer.writeln("  void validate({String pointer = ''}) {");

    for (var index = 0; index < klass.properties.length; index++) {
      final property = klass.properties[index];
      final pointerVar = '_ptr$index';
      final valueVar = '_value$index';
      final suffix = 'p$index';
      buffer.writeln(
        "    final $pointerVar = _appendJsonPointer(pointer, '${property.jsonName}');",
      );
      buffer.writeln('    final $valueVar = ${property.fieldName};');
      if (!property.isRequired) {
        buffer.writeln('    if ($valueVar != null) {');
        _writeValidationBodyForProperty(
          buffer,
          property,
          valueVar,
          pointerVar,
          indent: '      ',
          suffix: suffix,
        );
        buffer.writeln('    }');
      } else {
        _writeValidationBodyForProperty(
          buffer,
          property,
          valueVar,
          pointerVar,
          indent: '    ',
          suffix: suffix,
        );
      }
    }

    final additionalField = klass.additionalPropertiesField;
    if (additionalField != null &&
        _typeRequiresValidation(additionalField.valueType)) {
      final mapVar = '_${additionalField.fieldName}Map';
      buffer.writeln('    final $mapVar = ${additionalField.fieldName};');
      buffer.writeln('    if ($mapVar != null) {');
      buffer.writeln('      $mapVar.forEach((key, value) {');
      buffer.writeln(
        '        final itemPointer = _appendJsonPointer(pointer, key);',
      );
      _writeNestedValidation(
        buffer,
        additionalField.valueType,
        'value',
        'itemPointer',
        '        ',
        additionalField.fieldName,
      );
      buffer.writeln('      });');
      buffer.writeln('    }');
    }

    final patternField = klass.patternPropertiesField;
    if (patternField != null &&
        _typeRequiresValidation(patternField.valueType)) {
      final mapVar = '_${patternField.fieldName}Map';
      buffer.writeln('    final $mapVar = ${patternField.fieldName};');
      buffer.writeln('    if ($mapVar != null) {');
      buffer.writeln('      $mapVar.forEach((key, value) {');
      buffer.writeln(
        '        final itemPointer = _appendJsonPointer(pointer, key);',
      );
      _writeNestedValidation(
        buffer,
        patternField.valueType,
        'value',
        'itemPointer',
        '        ',
        patternField.fieldName,
      );
      buffer.writeln('      });');
      buffer.writeln('    }');
    }

    buffer.writeln('  }');
  }

  void _writeValidationBodyForProperty(
    StringBuffer buffer,
    IrProperty property,
    String valueVar,
    String pointerVar, {
    required String indent,
    required String suffix,
  }) {
    final rules = property.validation;
    if (rules != null && rules.hasRules) {
      _writeValidationRules(
        buffer,
        property,
        rules,
        valueVar,
        pointerVar,
        indent: indent,
        suffix: suffix,
      );
    }

    _writeNestedValidation(
      buffer,
      property.typeRef,
      valueVar,
      pointerVar,
      indent,
      suffix,
    );
  }

  void _writeValidationRules(
    StringBuffer buffer,
    IrProperty property,
    PropertyValidationRules rules,
    String valueVar,
    String pointerVar, {
    required String indent,
    required String suffix,
  }) {
    if (rules.minLength != null && _isStringLike(property.typeRef)) {
      buffer.writeln('${indent}if ($valueVar.length < ${rules.minLength}) {');
      buffer.writeln(
        '$indent  _throwValidationError($pointerVar, "minLength", "Expected at least ${rules.minLength} characters but found " + $valueVar.length.toString() + ".");',
      );
      buffer.writeln('$indent}');
    }

    if (rules.maxLength != null && _isStringLike(property.typeRef)) {
      buffer.writeln('${indent}if ($valueVar.length > ${rules.maxLength}) {');
      buffer.writeln(
        '$indent  _throwValidationError($pointerVar, "maxLength", "Expected at most ${rules.maxLength} characters but found " + $valueVar.length.toString() + ".");',
      );
      buffer.writeln('$indent}');
    }

    if (rules.minimum != null && _isNumericType(property.typeRef)) {
      final comparison = rules.exclusiveMinimum ? '<=' : '<';
      final keywordComparison = rules.exclusiveMinimum ? '>' : '>=';
      buffer.writeln('${indent}if ($valueVar $comparison ${rules.minimum}) {');
      buffer.writeln(
        '$indent  _throwValidationError($pointerVar, "minimum", "Expected value $keywordComparison ${rules.minimum} but found " + $valueVar.toString() + ".");',
      );
      buffer.writeln('$indent}');
    }

    if (rules.maximum != null && _isNumericType(property.typeRef)) {
      final comparison = rules.exclusiveMaximum ? '>=' : '>';
      final keywordComparison = rules.exclusiveMaximum ? '<' : '<=';
      buffer.writeln('${indent}if ($valueVar $comparison ${rules.maximum}) {');
      buffer.writeln(
        '$indent  _throwValidationError($pointerVar, "maximum", "Expected value $keywordComparison ${rules.maximum} but found " + $valueVar.toString() + ".");',
      );
      buffer.writeln('$indent}');
    }

    if (rules.pattern != null && _isStringLike(property.typeRef)) {
      final patternVar = '_pattern$suffix';
      buffer.writeln(
        '${indent}final $patternVar = RegExp(${_stringLiteral(rules.pattern!)});',
      );
      buffer.writeln('${indent}if (!$patternVar.hasMatch($valueVar)) {');
      buffer.writeln(
        '$indent  _throwValidationError($pointerVar, "pattern", "Expected value to match pattern ${rules.pattern} but found " + $valueVar + ".");',
      );
      buffer.writeln('$indent}');
    }

    if (rules.constValue != null) {
      final actualExpr = _constComparableExpression(property, valueVar);
      if (actualExpr != null) {
        final actualVar = '_actual$suffix';
        final expectedLiteral = _literalExpression(rules.constValue);
        buffer.writeln('${indent}final $actualVar = $actualExpr;');
        buffer.writeln('${indent}if ($actualVar != $expectedLiteral) {');
        buffer.writeln(
          '$indent  _throwValidationError($pointerVar, "const", "Expected value equal to $expectedLiteral but found " + $actualVar.toString() + ".");',
        );
        buffer.writeln('$indent}');
      }
    }
  }

  void _writeNestedValidation(
    StringBuffer buffer,
    TypeRef ref,
    String valueExpression,
    String pointerExpression,
    String indent,
    String suffix,
  ) {
    if (ref is ObjectTypeRef) {
      buffer.writeln(
        '$indent$valueExpression.validate(pointer: $pointerExpression);',
      );
      return;
    }
    if (ref is ListTypeRef) {
      final indexVar = 'i_$suffix';
      final itemVar = '_item$suffix';
      buffer.writeln(
        '${indent}for (var $indexVar = 0; $indexVar < $valueExpression.length; $indexVar++) {',
      );
      buffer.writeln(
        '$indent  final itemPointer = _appendJsonPointer($pointerExpression, $indexVar.toString());',
      );
      buffer.writeln('$indent  final $itemVar = $valueExpression[$indexVar];');
      _writeNestedValidation(
        buffer,
        ref.itemType,
        itemVar,
        'itemPointer',
        '$indent  ',
        '${suffix}i',
      );
      buffer.writeln('$indent}');
    }
  }

  bool _isStringLike(TypeRef ref) {
    return ref is PrimitiveTypeRef && ref.typeName == 'String';
  }

  bool _isNumericType(TypeRef ref) {
    if (ref is! PrimitiveTypeRef) {
      return false;
    }
    return ref.typeName == 'int' ||
        ref.typeName == 'double' ||
        ref.typeName == 'num';
  }

  String? _constComparableExpression(IrProperty property, String valueVar) {
    final ref = property.typeRef;
    if (ref is PrimitiveTypeRef) {
      final typeName = ref.typeName;
      if (typeName == 'String' ||
          typeName == 'int' ||
          typeName == 'double' ||
          typeName == 'num' ||
          typeName == 'bool') {
        return valueVar;
      }
    }
    if (ref is FormatTypeRef) {
      return ref.serializeInline(valueVar, required: true);
    }
    return null;
  }
}

bool _classNeedsValidation(IrClass klass, SchemaGeneratorOptions options) {
  if (!options.emitValidationHelpers) {
    return false;
  }

  for (final property in klass.properties) {
    if (property.validation?.hasRules == true) {
      return true;
    }
    if (_typeRequiresValidation(property.typeRef)) {
      return true;
    }
  }

  final additionalField = klass.additionalPropertiesField;
  if (additionalField != null &&
      _typeRequiresValidation(additionalField.valueType)) {
    return true;
  }

  final patternField = klass.patternPropertiesField;
  if (patternField != null && _typeRequiresValidation(patternField.valueType)) {
    return true;
  }

  return false;
}

bool _typeRequiresValidation(TypeRef ref) {
  if (ref is ObjectTypeRef) {
    return true;
  }
  if (ref is ListTypeRef) {
    return _typeRequiresValidation(ref.itemType);
  }
  return false;
}

class _UnionVariantView {
  _UnionVariantView({required this.union, required this.variant});

  final IrUnion union;
  final IrUnionVariant variant;
}

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
    this.cacheDirectoryPath,
    this.onWarning,
  });

  final bool allowNetworkRefs;
  final String? cacheDirectoryPath;
  final void Function(String message)? onWarning;
  Directory? _cacheDirectory;

  Map<String, dynamic> call(Uri uri) {
    final resolved = _ensureScheme(uri);
    if (resolved.scheme == 'file') {
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
