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

    final unevaluatedField = klass.unevaluatedPropertiesField;
    if (unevaluatedField != null) {
      _collectTypeDependencies(
        unevaluatedField.valueType,
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

    for (final constraint in klass.dependentSchemas.values) {
      final ref = constraint.typeRef;
      if (ref != null) {
        _collectTypeDependencies(ref, collected, owner: klass.name);
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
      for (final type in ref.prefixItemTypes) {
        _collectTypeDependencies(type, out, owner: owner);
      }
      final containsType = ref.containsType;
      if (containsType != null) {
        _collectTypeDependencies(containsType, out, owner: owner);
      }
      final unevaluatedItemsType = ref.unevaluatedItemsType;
      if (unevaluatedItemsType != null) {
        _collectTypeDependencies(unevaluatedItemsType, out, owner: owner);
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
  final Set<String> _validatedClassNames = <String>{};

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
    if (klass.extensionAnnotations.isNotEmpty) {
      for (final entry in klass.extensionAnnotations.entries) {
        buffer.writeln('/// ${entry.key}: ${entry.value}');
      }
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
    final needsValidation = _classNeedsValidation(klass, options);
    if (needsValidation) {
      _validatedClassNames.add(klass.name);
    }
    if (options.emitValidationHelpers) {
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
      buffer.writeln(
        "  void validate({String pointer = '', ValidationContext? context});",
      );
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
    final needsValidation = _classNeedsValidation(klass, options);
    if (needsValidation) {
      _validatedClassNames.add(klass.name);
    }
    if (options.emitValidationHelpers) {
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

  String? _defaultLiteralFor(IrProperty property) {
    final value = property.defaultValue;
    if (value == null) {
      return null;
    }
    if (value is num || value is bool) {
      return value.toString();
    }
    if (value is String) {
      return _stringLiteral(value);
    }
    return null;
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
      if (property.extensionAnnotations.isNotEmpty) {
        for (final entry in property.extensionAnnotations.entries) {
          buffer.writeln('  /// ${entry.key}: ${entry.value}');
        }
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

    final unevaluatedField = klass.unevaluatedPropertiesField;
    if (unevaluatedField != null) {
      if (unevaluatedField.description != null &&
          unevaluatedField.description!.trim().isNotEmpty) {
        _writeDocumentation(
          buffer,
          unevaluatedField.description!,
          indent: '  ',
        );
      }
      buffer.writeln(
        '  final ${unevaluatedField.mapType()} ${unevaluatedField.fieldName};',
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
        klass.additionalPropertiesField != null ||
        klass.unevaluatedPropertiesField != null;
    if (!hasFields) {
      buffer.writeln('  const ${klass.name}()${superInitializer ?? ''};');
      return;
    }

    buffer.writeln('  const ${klass.name}({');
    for (final property in klass.properties) {
      final defaultLiteral = !property.isRequired
          ? _defaultLiteralFor(property)
          : null;
      if (property.isRequired) {
        buffer.writeln('    required this.${property.fieldName},');
      } else if (defaultLiteral != null) {
        buffer.writeln('    this.${property.fieldName} = $defaultLiteral,');
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

    final unevaluatedField = klass.unevaluatedPropertiesField;
    if (unevaluatedField != null) {
      buffer.writeln('    this.${unevaluatedField.fieldName},');
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
    final patternField = klass.patternPropertiesField;
    final additionalField = klass.additionalPropertiesField;
    final unevaluatedField = klass.unevaluatedPropertiesField;
    final needsUnmatched =
        patternField != null ||
        additionalField != null ||
        unevaluatedField != null ||
        klass.disallowUnevaluatedProperties ||
        !klass.allowAdditionalProperties;
    final needsRemaining = klass.properties.isNotEmpty || needsUnmatched;
    if (needsRemaining) {
      buffer.writeln('    final remaining = Map<String, dynamic>.from(json);');
    }
    for (final property in klass.properties) {
      final expression = property.deserializeExpression('json');
      final defaultLiteral = !property.isRequired
          ? _defaultLiteralFor(property)
          : null;
      if (defaultLiteral != null) {
        buffer.writeln(
          '    final ${property.fieldName} = ($expression) ?? $defaultLiteral;',
        );
      } else {
        buffer.writeln('    final ${property.fieldName} = $expression;');
      }
      buffer.writeln("    remaining.remove('${property.jsonName}');");
    }
    if (needsUnmatched) {
      buffer.writeln(
        '    var unmatched = Map<String, dynamic>.from(remaining);',
      );
    }

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

    if (unevaluatedField != null) {
      final valueType = unevaluatedField.valueType.dartType();
      buffer.writeln(
        '    Map<String, $valueType>? ${unevaluatedField.fieldName}Value;',
      );
      buffer.writeln('    if (unmatched.isNotEmpty) {');
      buffer.writeln(
        '      final ${unevaluatedField.fieldName}Map = <String, $valueType>{};',
      );
      buffer.writeln('      for (final entry in unmatched.entries) {');
      buffer.writeln('        final value = entry.value;');
      final converted = unevaluatedField.valueType.deserializeInline(
        'value',
        required: true,
      );
      buffer.writeln(
        '        ${unevaluatedField.fieldName}Map[entry.key] = $converted;',
      );
      buffer.writeln('      }');
      buffer.writeln(
        '      ${unevaluatedField.fieldName}Value = ${unevaluatedField.fieldName}Map.isEmpty ? null : ${unevaluatedField.fieldName}Map;',
      );
      buffer.writeln('      unmatched = <String, dynamic>{};');
      buffer.writeln('    } else {');
      buffer.writeln('      ${unevaluatedField.fieldName}Value = null;');
      buffer.writeln('    }');
    }

    if (!klass.allowAdditionalProperties ||
        klass.disallowUnevaluatedProperties) {
      final reasons = <String>[];
      if (!klass.allowAdditionalProperties) {
        reasons.add('additional');
      }
      if (klass.disallowUnevaluatedProperties) {
        reasons.add('unevaluated');
      }
      final reasonText = reasons.join(' and ');
      buffer.writeln('    if (unmatched.isNotEmpty) {');
      buffer.writeln("      final unexpected = unmatched.keys.join(', ');");
      buffer.writeln(
        "      throw ArgumentError('Unexpected $reasonText properties: \$unexpected');",
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
    if (unevaluatedField != null) {
      buffer.writeln(
        '      ${unevaluatedField.fieldName}: ${unevaluatedField.fieldName}Value,',
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

    final unevaluatedField = klass.unevaluatedPropertiesField;
    if (unevaluatedField != null) {
      final converted = unevaluatedField.valueType.serializeInline(
        'value',
        required: true,
      );
      buffer.writeln('    if (${unevaluatedField.fieldName} != null) {');
      buffer.writeln(
        '      ${unevaluatedField.fieldName}!.forEach((key, value) {',
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
    final needsValidation = _classNeedsValidation(klass, options);
    if (!needsValidation) {
      if (!options.emitValidationHelpers) {
        return;
      }
      if (override) {
        buffer.writeln('  @override');
      }
      buffer.writeln(
        "  void validate({String pointer = '', ValidationContext? context}) {}",
      );
      return;
    }

    final propertyIndexByName = <String, int>{
      for (var i = 0; i < klass.properties.length; i++)
        klass.properties[i].jsonName: i,
    };

    if (override) {
      buffer.writeln('  @override');
    }
    buffer.writeln(
      "  void validate({String pointer = '', ValidationContext? context}) {",
    );

    for (var index = 0; index < klass.properties.length; index++) {
      final property = klass.properties[index];
      final pointerVar = '_ptr$index';
      final valueVar = '_value$index';
      final suffix = 'p$index';
      buffer.writeln(
        "    final $pointerVar = appendJsonPointer(pointer, '${property.jsonName}');",
      );
      buffer.writeln('    final $valueVar = ${property.fieldName};');
      final isFalseSchema = property.typeRef is FalseTypeRef;
      if (property.title != null) {
        buffer.writeln(
          "    context?.annotate($pointerVar, 'title', ${_stringLiteral(property.title!)}, schemaPointer: ${_stringLiteral(property.schemaPointer)});",
        );
      }
      if (property.defaultValue != null) {
        final literal = _literalExpression(property.defaultValue);
        buffer.writeln(
          "    context?.annotate($pointerVar, 'default', $literal, schemaPointer: ${_stringLiteral(property.schemaPointer)});",
        );
      }
      if (!property.isRequired) {
        if (isFalseSchema) {
          buffer.writeln('    if ($valueVar != null) {');
          final message = _stringLiteral(
            'Schema at ${property.schemaPointer} forbids property "${property.jsonName}".',
          );
          buffer.writeln(
            '      throwValidationError($pointerVar, \'const\', $message);',
          );
          buffer.writeln('    }');
        } else {
          buffer.writeln('    if ($valueVar != null) {');
          _writePropertyNameConstraint(
            buffer,
            klass,
            _stringLiteral(property.jsonName),
            pointerVar,
            '      ',
            suffix,
          );
          buffer.writeln(
            "      context?.markProperty(pointer, '${property.jsonName}');",
          );
          _writeValidationBodyForProperty(
            buffer,
            property,
            valueVar,
            pointerVar,
            indent: '      ',
            suffix: suffix,
          );
          buffer.writeln('    }');
        }
      } else {
        buffer.writeln(
          "    context?.markProperty(pointer, '${property.jsonName}');",
        );
        if (isFalseSchema) {
          final message = _stringLiteral(
            'Schema at ${property.schemaPointer} forbids property "${property.jsonName}".',
          );
          buffer.writeln(
            '    throwValidationError($pointerVar, \'const\', $message);',
          );
        } else {
          _writePropertyNameConstraint(
            buffer,
            klass,
            _stringLiteral(property.jsonName),
            pointerVar,
            '    ',
            suffix,
          );
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
    }

    if (klass.dependentRequired.isNotEmpty) {
      for (final entry in klass.dependentRequired.entries) {
        final triggerName = entry.key;
        final triggerIndex = propertyIndexByName[triggerName];
        if (triggerIndex == null) {
          continue;
        }
        final triggerProperty = klass.properties[triggerIndex];
        final triggerValueVar = '_value$triggerIndex';
        final dependencies = <MapEntry<String, int>>[];
        for (final candidate in entry.value) {
          final depIndex = propertyIndexByName[candidate];
          if (depIndex == null) {
            continue;
          }
          final depProperty = klass.properties[depIndex];
          if (depProperty.isRequired) {
            continue;
          }
          dependencies.add(MapEntry(candidate, depIndex));
        }
        if (dependencies.isEmpty) {
          continue;
        }
        if (!triggerProperty.isRequired) {
          buffer.writeln('    if ($triggerValueVar != null) {');
        }
        for (final dependency in dependencies) {
          final depIndex = dependency.value;
          final depValueVar = '_value$depIndex';
          final message = _stringLiteral(
            'Property "${dependency.key}" must be present when "$triggerName" is defined.',
          );
          buffer.writeln('      if ($depValueVar == null) {');
          buffer.writeln(
            '        throwValidationError(pointer, \'dependentRequired\', $message);',
          );
          buffer.writeln('      }');
        }
        if (!triggerProperty.isRequired) {
          buffer.writeln('    }');
        }
      }
    }

    if (klass.dependentSchemas.isNotEmpty) {
      for (final entry in klass.dependentSchemas.entries) {
        final triggerName = entry.key;
        final constraint = entry.value;
        final triggerIndex = propertyIndexByName[triggerName];
        if (triggerIndex == null) {
          continue;
        }
        final triggerProperty = klass.properties[triggerIndex];
        final triggerValueVar = '_value$triggerIndex';
        final triggerPointerVar = '_ptr$triggerIndex';
        final guard = !triggerProperty.isRequired;
        if (guard) {
          buffer.writeln('    if ($triggerValueVar != null) {');
        }
        if (constraint.disallow) {
          final message = _stringLiteral(
            'Property "$triggerName" is not allowed in this context.',
          );
          buffer.writeln(
            '      throwValidationError(pointer, \'dependentSchemas\', $message);',
          );
        } else if (constraint.typeRef != null) {
          final typeRef = constraint.typeRef!;
          if (typeRef is ObjectTypeRef) {
            final spec = typeRef.spec;
            final tempVar = '_dependent$triggerIndex';
            final valueExpression = guard
                ? '($triggerValueVar!).toJson()'
                : '$triggerValueVar.toJson()';
            buffer.writeln(
              '      final $tempVar = ${spec.name}.fromJson($valueExpression);',
            );
            if (_classNeedsValidation(spec, options)) {
              _validatedClassNames.add(spec.name);
            }
            buffer.writeln(
              '      $tempVar.validate(pointer: $triggerPointerVar, context: context);',
            );
          } else {
            final suffix = 'deps$triggerIndex';
            final valueExpression = guard
                ? '$triggerValueVar!'
                : triggerValueVar;
            _writeNestedValidation(
              buffer,
              typeRef,
              valueExpression,
              triggerPointerVar,
              '      ',
              suffix,
            );
          }
        }
        if (guard) {
          buffer.writeln('    }');
        }
      }
    }

    final additionalField = klass.additionalPropertiesField;
    if (additionalField != null &&
        (_typeRequiresValidation(additionalField.valueType, options) ||
            (klass.propertyNamesConstraint?.hasRules ?? false))) {
      final mapVar = '_${additionalField.fieldName}Map';
      buffer.writeln('    final $mapVar = ${additionalField.fieldName};');
      buffer.writeln('    if ($mapVar != null) {');
      buffer.writeln('      $mapVar.forEach((key, value) {');
      buffer.writeln(
        '        final itemPointer = appendJsonPointer(pointer, key);',
      );
      _writePropertyNameConstraint(
        buffer,
        klass,
        'key',
        'itemPointer',
        '        ',
        additionalField.fieldName,
      );
      buffer.writeln('        context?.markProperty(pointer, key);');
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
        (_typeRequiresValidation(patternField.valueType, options) ||
            (klass.propertyNamesConstraint?.hasRules ?? false))) {
      final mapVar = '_${patternField.fieldName}Map';
      buffer.writeln('    final $mapVar = ${patternField.fieldName};');
      buffer.writeln('    if ($mapVar != null) {');
      buffer.writeln('      $mapVar.forEach((key, value) {');
      buffer.writeln(
        '        final itemPointer = appendJsonPointer(pointer, key);',
      );
      _writePropertyNameConstraint(
        buffer,
        klass,
        'key',
        'itemPointer',
        '        ',
        patternField.fieldName,
      );
      buffer.writeln('        context?.markProperty(pointer, key);');
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

    final unevaluatedField = klass.unevaluatedPropertiesField;
    if (unevaluatedField != null &&
        (_typeRequiresValidation(unevaluatedField.valueType, options) ||
            (klass.propertyNamesConstraint?.hasRules ?? false))) {
      final mapVar = '_${unevaluatedField.fieldName}Map';
      buffer.writeln('    final $mapVar = ${unevaluatedField.fieldName};');
      buffer.writeln('    if ($mapVar != null) {');
      buffer.writeln('      $mapVar.forEach((key, value) {');
      buffer.writeln(
        '        final itemPointer = appendJsonPointer(pointer, key);',
      );
      _writePropertyNameConstraint(
        buffer,
        klass,
        'key',
        'itemPointer',
        '        ',
        unevaluatedField.fieldName,
      );
      buffer.writeln('        context?.markProperty(pointer, key);');
      _writeNestedValidation(
        buffer,
        unevaluatedField.valueType,
        'value',
        'itemPointer',
        '        ',
        unevaluatedField.fieldName,
      );
      buffer.writeln('      });');
      buffer.writeln('    }');
    }

    for (var index = 0; index < klass.conditionalConstraints.length; index++) {
      final constraint = klass.conditionalConstraints[index];
      _writeConditionalConstraintValidation(
        buffer,
        klass,
        constraint,
        indent: '    ',
        index: index,
      );
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
      final message = _stringLiteral(
        'Expected at least ${rules.minLength} characters but found ',
      );
      buffer.writeln(
        '$indent  throwValidationError($pointerVar, \'minLength\', $message + $valueVar.length.toString() + \'.\');',
      );
      buffer.writeln('$indent}');
    }

    if (rules.maxLength != null && _isStringLike(property.typeRef)) {
      buffer.writeln('${indent}if ($valueVar.length > ${rules.maxLength}) {');
      final message = _stringLiteral(
        'Expected at most ${rules.maxLength} characters but found ',
      );
      buffer.writeln(
        '$indent  throwValidationError($pointerVar, \'maxLength\', $message + $valueVar.length.toString() + \'.\');',
      );
      buffer.writeln('$indent}');
    }

    if (rules.minimum != null && _isNumericType(property.typeRef)) {
      final comparison = rules.exclusiveMinimum ? '<=' : '<';
      final keywordComparison = rules.exclusiveMinimum ? '>' : '>=';
      buffer.writeln('${indent}if ($valueVar $comparison ${rules.minimum}) {');
      final message = _stringLiteral(
        'Expected value $keywordComparison ${rules.minimum} but found ',
      );
      buffer.writeln(
        '$indent  throwValidationError($pointerVar, \'minimum\', $message + $valueVar.toString() + \'.\');',
      );
      buffer.writeln('$indent}');
    }

    if (rules.maximum != null && _isNumericType(property.typeRef)) {
      final comparison = rules.exclusiveMaximum ? '>=' : '>';
      final keywordComparison = rules.exclusiveMaximum ? '<' : '<=';
      buffer.writeln('${indent}if ($valueVar $comparison ${rules.maximum}) {');
      final message = _stringLiteral(
        'Expected value $keywordComparison ${rules.maximum} but found ',
      );
      buffer.writeln(
        '$indent  throwValidationError($pointerVar, \'maximum\', $message + $valueVar.toString() + \'.\');',
      );
      buffer.writeln('$indent}');
    }

    if (rules.pattern != null && _isStringLike(property.typeRef)) {
      final patternVar = '_pattern$suffix';
      buffer.writeln(
        '${indent}final $patternVar = RegExp(${_stringLiteral(rules.pattern!)});',
      );
      buffer.writeln('${indent}if (!$patternVar.hasMatch($valueVar)) {');
      final messagePrefix = _stringLiteral(
        'Expected value to match pattern ${rules.pattern} but found ',
      );
      buffer.writeln(
        '$indent  throwValidationError($pointerVar, \'pattern\', $messagePrefix + $valueVar + \'.\');',
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
        final message = _stringLiteral(
          'Expected value equal to $expectedLiteral but found ',
        );
        buffer.writeln(
          '$indent  throwValidationError($pointerVar, \'const\', $message + $actualVar.toString() + \'.\');',
        );
        buffer.writeln('$indent}');
      }
    }
  }

  void _writePropertyNameConstraint(
    StringBuffer buffer,
    IrClass klass,
    String nameExpression,
    String pointerExpression,
    String indent,
    String suffix,
  ) {
    final constraint = klass.propertyNamesConstraint;
    if (constraint == null || !constraint.hasRules) {
      return;
    }

    if (constraint.disallow) {
      final prefix = _stringLiteral('Property name "');
      final suffixMessage = _stringLiteral(
        '" is not allowed by schema at ${constraint.schemaPointer}.',
      );
      buffer.writeln(
        '$indent throwValidationError($pointerExpression, \'propertyNames\', $prefix + $nameExpression + $suffixMessage);',
      );
      return;
    }

    final rules = constraint.validation;
    if (rules == null) {
      return;
    }

    if (rules.minLength != null) {
      final message = _stringLiteral(
        'Property name must be at least ${rules.minLength} characters long (schema ${constraint.schemaPointer}).',
      );
      buffer.writeln(
        '$indent if ($nameExpression.length < ${rules.minLength}) {',
      );
      buffer.writeln(
        '$indent   throwValidationError($pointerExpression, \'propertyNames\', $message);',
      );
      buffer.writeln('$indent }');
    }

    if (rules.maxLength != null) {
      final message = _stringLiteral(
        'Property name must be at most ${rules.maxLength} characters long (schema ${constraint.schemaPointer}).',
      );
      buffer.writeln(
        '$indent if ($nameExpression.length > ${rules.maxLength}) {',
      );
      buffer.writeln(
        '$indent   throwValidationError($pointerExpression, \'propertyNames\', $message);',
      );
      buffer.writeln('$indent }');
    }

    if (rules.pattern != null) {
      final patternVar = '_propertyNamePattern$suffix';
      buffer.writeln(
        '$indent final $patternVar = RegExp(${_stringLiteral(rules.pattern!)});',
      );
      final message = _stringLiteral(
        'Property name must match pattern ${rules.pattern} (schema ${constraint.schemaPointer}).',
      );
      buffer.writeln('$indent if (!$patternVar.hasMatch($nameExpression)) {');
      buffer.writeln(
        '$indent   throwValidationError($pointerExpression, \'propertyNames\', $message);',
      );
      buffer.writeln('$indent }');
    }

    if (rules.constValue != null) {
      final literal = _literalExpression(rules.constValue);
      final message = _stringLiteral(
        'Property name must equal $literal (schema ${constraint.schemaPointer}).',
      );
      buffer.writeln('$indent if ($nameExpression != $literal) {');
      buffer.writeln(
        '$indent   throwValidationError($pointerExpression, \'propertyNames\', $message);',
      );
      buffer.writeln('$indent }');
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
    if (!_typeRequiresValidation(ref, options)) {
      return;
    }
    if (ref is FalseTypeRef) {
      final message = _stringLiteral(
        'Schema forbids any value at this location.',
      );
      buffer.writeln(
        '${indent}throwValidationError($pointerExpression, \'const\', $message);',
      );
      return;
    }
    if (ref is ObjectTypeRef) {
      if (_validatedClassNames.contains(ref.spec.name) ||
          _classNeedsValidation(ref.spec, options)) {
        _validatedClassNames.add(ref.spec.name);
        buffer.writeln(
          '$indent$valueExpression.validate(pointer: $pointerExpression, context: context);',
        );
      }
      return;
    }
    if (ref is ListTypeRef) {
      final lengthVar = '_len$suffix';
      final evaluatedVar = '_evaluated$suffix';
      buffer.writeln('${indent}final $lengthVar = $valueExpression.length;');
      buffer.writeln(
        '${indent}final $evaluatedVar = List<bool>.filled($lengthVar, false);',
      );

      for (var index = 0; index < ref.prefixItemTypes.length; index++) {
        final prefixType = ref.prefixItemTypes[index];
        buffer.writeln(
          '$indent'
          'if ($lengthVar > $index) {',
        );
        buffer.writeln(
          "$indent  final itemPointer = appendJsonPointer($pointerExpression, '$index');",
        );
        buffer.writeln('$indent  final item = $valueExpression[$index];');
        _writeNestedValidation(
          buffer,
          prefixType,
          'item',
          'itemPointer',
          '$indent  ',
          '${suffix}p$index',
        );
        buffer.writeln('$indent  $evaluatedVar[$index] = true;');
        buffer.writeln(
          '$indent  context?.markItem($pointerExpression, $index);',
        );
        buffer.writeln('$indent}');
      }

      final additionalStart = ref.prefixItemTypes.length;
      if (!ref.allowAdditionalItems) {
        final message = additionalStart == 0
            ? 'No items allowed in array.'
            : 'No additional items allowed beyond index ${additionalStart - 1}.';
        buffer.writeln(
          '$indent'
          'if ($lengthVar > $additionalStart) {',
        );
        buffer.writeln(
          '$indent  throwValidationError($pointerExpression, \'items\', ${_stringLiteral(message)});',
        );
        buffer.writeln('$indent}');
      } else {
        buffer.writeln(
          '$indent'
          'for (var i = $additionalStart; i < $lengthVar; i++) {',
        );
        buffer.writeln(
          '$indent  final itemPointer = appendJsonPointer($pointerExpression, i.toString());',
        );
        buffer.writeln('$indent  final item = $valueExpression[i];');
        _writeNestedValidation(
          buffer,
          ref.itemType,
          'item',
          'itemPointer',
          '$indent  ',
          '${suffix}i',
        );
        if (ref.itemsEvaluatesAdditionalItems) {
          buffer.writeln('$indent  $evaluatedVar[i] = true;');
          buffer.writeln('$indent  context?.markItem($pointerExpression, i);');
        }
        buffer.writeln('$indent}');
      }

      if (ref.containsType != null) {
        final containsType = ref.containsType!;
        final containsCountVar = '_containsCount$suffix';
        final minContains =
            ref.minContains ?? (ref.containsType != null ? 1 : null);
        final maxContains = ref.maxContains;
        buffer.writeln('$indent'
            'var $containsCountVar = 0;');
        buffer.writeln('$indent'
            'for (var i = 0; i < $lengthVar; i++) {');
        buffer.writeln(
          '$indent  final itemPointer = appendJsonPointer($pointerExpression, i.toString());',
        );
        buffer.writeln('$indent  final item = $valueExpression[i];');
        if (containsType is ObjectTypeRef &&
            _classNeedsValidation(containsType.spec, options)) {
          final klass = containsType.spec;
          buffer.writeln('$indent  var matches = item is ${klass.name};');
          buffer.writeln('$indent  if (matches) {');
          buffer.writeln('$indent    try {');
          buffer.writeln(
            '$indent      (item as ${klass.name}).validate(pointer: itemPointer, context: context);',
          );
          buffer.writeln('$indent    } on ValidationError {');
          buffer.writeln('$indent      matches = false;');
          buffer.writeln('$indent    }');
          buffer.writeln('$indent  }');
        } else {
          final matchCondition = _containsMatchCondition(containsType, 'item');
          buffer.writeln('$indent  final matches = $matchCondition;');
        }
        buffer.writeln('$indent  if (matches) {');
        buffer.writeln('$indent    $containsCountVar++;');
        buffer.writeln(
          '$indent    if (!$evaluatedVar[i]) { $evaluatedVar[i] = true; }',
        );
        buffer.writeln(
          '$indent    context?.markItem($pointerExpression, i);',
        );
        buffer.writeln('$indent  }');
        buffer.writeln('$indent}');
        if (minContains != null) {
          buffer.writeln('$indent'
              'if ($containsCountVar < $minContains) {');
          buffer.writeln(
            '$indent  throwValidationError($pointerExpression, \'contains\', ${_stringLiteral('Expected at least $minContains item(s) matching "contains" but found ')} + $containsCountVar.toString() + \'.\');',
          );
          buffer.writeln('$indent}');
        }
        if (maxContains != null) {
          buffer.writeln('$indent'
              'if ($containsCountVar > $maxContains) {');
          buffer.writeln(
            '$indent  throwValidationError($pointerExpression, \'contains\', ${_stringLiteral('Expected at most $maxContains item(s) matching "contains" but found ')} + $containsCountVar.toString() + \'.\');',
          );
          buffer.writeln('$indent}');
        }
      }

      if (ref.unevaluatedItemsType != null || ref.disallowUnevaluatedItems) {
        buffer.writeln(
          '$indent'
          'for (var i = 0; i < $lengthVar; i++) {',
        );
        buffer.writeln('$indent  if (!$evaluatedVar[i]) {');
        final unevaluatedType = ref.unevaluatedItemsType;
        if (unevaluatedType != null) {
          buffer.writeln(
            '$indent    final itemPointer = appendJsonPointer($pointerExpression, i.toString());',
          );
          buffer.writeln('$indent    final item = $valueExpression[i];');
          _writeNestedValidation(
            buffer,
            unevaluatedType,
            'item',
            'itemPointer',
            '$indent    ',
            '$suffix'
                'u',
          );
          buffer.writeln('$indent    $evaluatedVar[i] = true;');
          buffer.writeln(
            '$indent    context?.markItem($pointerExpression, i);',
          );
          if (ref.disallowUnevaluatedItems) {
            buffer.writeln('$indent    continue;');
          }
        }
        if (ref.disallowUnevaluatedItems) {
          buffer.writeln(
            '$indent    throwValidationError($pointerExpression, \'unevaluatedItems\', ${_stringLiteral('Unexpected unevaluated item at index ')} + i.toString() + \'.\');',
          );
        }
        buffer.writeln('$indent  }');
        buffer.writeln('$indent}');
      }

      return;
    }
  }

  void _writeConditionalConstraintValidation(
    StringBuffer buffer,
    IrClass klass,
    ConditionalConstraint constraint, {
    required String indent,
    required int index,
  }) {
    if (constraint.branches.isEmpty) {
      return;
    }

    final branchVarNames = <String>[];
    for (
      var branchIndex = 0;
      branchIndex < constraint.branches.length;
      branchIndex++
    ) {
      final branch = constraint.branches[branchIndex];
      final sortedProperties = branch.requiredProperties.toList()..sort();
      final checks = <String>[];
      for (final jsonName in sortedProperties) {
        final property = klass.properties.firstWhere(
          (prop) => prop.jsonName == jsonName,
          orElse: () => throw StateError(
            'Required property $jsonName not found on ${klass.name}',
          ),
        );
        if (property.isRequired) {
          continue;
        }
        checks.add('${property.fieldName} != null');
      }
      final expression = checks.isEmpty ? 'true' : checks.join(' && ');
      final branchVar = '_constraint${index}Match$branchIndex';
      buffer.writeln('$indent final $branchVar = $expression;');
      branchVarNames.add(branchVar);
    }

    final combinationsDescription = constraint.branches
        .map((branch) {
          final props = branch.requiredProperties.toList()..sort();
          final joined = props.map((name) => '"$name"').join(', ');
          return '[$joined]';
        })
        .join(', ');

    final matchesVar = '_constraint${index}Matches';
    buffer.writeln(
      '$indent final $matchesVar = <bool>[${branchVarNames.join(', ')}];',
    );

    if (constraint.keyword == 'oneOf') {
      final countVar = '_constraint${index}MatchCount';
      buffer.writeln(
        '$indent final $countVar = $matchesVar.where((value) => value).length;',
      );
      final message =
          'Expected exactly one of the combinations defined at ${constraint.schemaPointer} to be satisfied ($combinationsDescription).';
      buffer.writeln('$indent if ($countVar != 1) {');
      buffer.writeln(
        '$indent   throwValidationError(pointer, ${_stringLiteral(constraint.keyword)}, ${_stringLiteral(message)});',
      );
      buffer.writeln('$indent }');
    } else {
      final message =
          'Expected at least one of the combinations defined at ${constraint.schemaPointer} to be satisfied ($combinationsDescription).';
      buffer.writeln('$indent if (!$matchesVar.any((value) => value)) {');
      buffer.writeln(
        '$indent   throwValidationError(pointer, ${_stringLiteral(constraint.keyword)}, ${_stringLiteral(message)});',
      );
      buffer.writeln('$indent }');
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

bool _classNeedsValidation(
  IrClass klass,
  SchemaGeneratorOptions options, [
  Set<IrClass>? stack,
]) {
  if (!options.emitValidationHelpers) {
    return false;
  }

  stack ??= <IrClass>{};
  if (!stack.add(klass)) {
    // Cyclic reference already inspected higher in the stack.
    return false;
  }

  final propertyNames = klass.propertyNamesConstraint;
  if (propertyNames != null && propertyNames.hasRules) {
    stack.remove(klass);
    return true;
  }

  if (klass.conditionalConstraints.isNotEmpty) {
    stack.remove(klass);
    return true;
  }

  if (klass.dependentRequired.isNotEmpty || klass.dependentSchemas.isNotEmpty) {
    stack.remove(klass);
    return true;
  }

  for (final property in klass.properties) {
    if (property.validation?.hasRules == true) {
      stack.remove(klass);
      return true;
    }
    if (_typeRequiresValidation(property.typeRef, options, stack)) {
      stack.remove(klass);
      return true;
    }
  }

  final additionalField = klass.additionalPropertiesField;
  if (additionalField != null &&
      _typeRequiresValidation(additionalField.valueType, options, stack)) {
    stack.remove(klass);
    return true;
  }

  final patternField = klass.patternPropertiesField;
  if (patternField != null &&
      _typeRequiresValidation(patternField.valueType, options, stack)) {
    stack.remove(klass);
    return true;
  }

  final unevaluatedField = klass.unevaluatedPropertiesField;
  if (unevaluatedField != null &&
      _typeRequiresValidation(unevaluatedField.valueType, options, stack)) {
    stack.remove(klass);
    return true;
  }

  stack.remove(klass);
  return false;
}

bool _typeRequiresValidation(
  TypeRef ref,
  SchemaGeneratorOptions options, [
  Set<IrClass>? stack,
]) {
  if (ref is FalseTypeRef) {
    return true;
  }
  if (ref is ObjectTypeRef) {
    return _classNeedsValidation(ref.spec, options, stack);
  }
  if (ref is ListTypeRef) {
    if (_typeRequiresValidation(ref.itemType, options, stack)) {
      return true;
    }
    for (final type in ref.prefixItemTypes) {
      if (_typeRequiresValidation(type, options, stack)) {
        return true;
      }
    }
    final containsType = ref.containsType;
    if (containsType != null &&
        _typeRequiresValidation(containsType, options, stack)) {
      return true;
    }
    if (containsType != null) {
      return true;
    }
    final unevaluatedItemsType = ref.unevaluatedItemsType;
    if (unevaluatedItemsType != null &&
        _typeRequiresValidation(unevaluatedItemsType, options, stack)) {
      return true;
    }
    return false;
  }
  return false;
}

String _containsMatchCondition(TypeRef ref, String valueExpression) {
  if (ref is PrimitiveTypeRef) {
    final typeName = ref.typeName;
    if (typeName == 'dynamic') {
      return 'true';
    }
    return '$valueExpression is $typeName';
  }
  if (ref is EnumTypeRef) {
    return '$valueExpression is ${ref.spec.name}';
  }
  if (ref is FormatTypeRef) {
    return '$valueExpression is ${ref.typeName}';
  }
  if (ref is ListTypeRef) {
    return '$valueExpression is List';
  }
  if (ref is ObjectTypeRef) {
    return '$valueExpression is ${ref.spec.name}';
  }
  if (ref is DynamicTypeRef) {
    return 'true';
  }
  return 'true';
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
