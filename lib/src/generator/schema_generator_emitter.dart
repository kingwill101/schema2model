part of 'package:schema2model/src/generator.dart';

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

  Set<String> _getRequiredEncodings(SchemaIr ir) {
    final encodings = <String>{};
    for (final klass in ir.classes) {
      for (final prop in klass.properties) {
        if (prop.typeRef is ContentEncodedTypeRef) {
          encodings.add((prop.typeRef as ContentEncodedTypeRef).encoding);
        }
        if (options.enableContentValidation &&
            prop.contentEncoding != null &&
            prop.contentEncoding!.isNotEmpty) {
          encodings.add(prop.contentEncoding!);
        }
      }
    }
    return encodings;
  }

  bool _needsContentValidation(SchemaIr ir) {
    if (!options.enableContentValidation) {
      return false;
    }
    for (final klass in ir.classes) {
      for (final prop in klass.properties) {
        if (prop.contentSchemaTypeRef != null) {
          return true;
        }
      }
    }
    return false;
  }

  String renderLibrary(SchemaIr ir) {
    setUnions(ir.unions);
    final buffer = StringBuffer();
    
    // Check if any property uses ContentEncodedTypeRef and add required imports/helpers
    final requiredEncodings = _getRequiredEncodings(ir);
    final needsContentValidation = _needsContentValidation(ir);
    if (requiredEncodings.isNotEmpty || needsContentValidation) {
      buffer.writeln("import 'dart:convert';");
    }
    if (requiredEncodings.isNotEmpty) {
      buffer.writeln("import 'dart:typed_data';");
      buffer.writeln();
      
      // Add helper functions for non-base64 encodings
      if (requiredEncodings.contains('base16')) {
        buffer.writeln(_base16Helpers);
        buffer.writeln();
      }
      if (requiredEncodings.contains('base32')) {
        buffer.writeln(_base32Helpers);
        buffer.writeln();
      }
      if (requiredEncodings.contains('quoted-printable')) {
        buffer.writeln(_quotedPrintableHelpers);
        buffer.writeln();
      }
    }
    
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
      if (i != ir.enums.length - 1 || ir.mixedEnums.isNotEmpty) {
        buffer.writeln();
      }
      if (ir.helpers.isNotEmpty && i == ir.enums.length - 1 && ir.mixedEnums.isEmpty) {
        buffer.writeln();
      }
    }

    for (var i = 0; i < ir.mixedEnums.length; i++) {
      buffer.write(renderMixedEnum(ir.mixedEnums[i]));
      if (i != ir.mixedEnums.length - 1) {
        buffer.writeln();
      }
      if (ir.helpers.isNotEmpty && i == ir.mixedEnums.length - 1) {
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
    
    // Generate optional helper functions for root class
    if (options.generateHelpers) {
      final rootClassName = ir.rootClass.name;
      final funcPrefix = _Naming.fieldName(rootClassName);
      
      // Ensure dart:convert is imported
      if (!buffer.toString().contains("import 'dart:convert'")) {
        // Insert import at the top if needed
        final content = buffer.toString();
        buffer.clear();
        buffer.writeln("import 'dart:convert';");
        buffer.writeln();
        buffer.write(content);
      }
      
      buffer.writeln();
      buffer.writeln('/// Parses [str] as JSON and deserializes it into a [$rootClassName].');
      buffer.writeln('$rootClassName ${funcPrefix}FromJson(String str) =>');
      buffer.writeln('    $rootClassName.fromJson(json.decode(str) as Map<String, dynamic>);');
      buffer.writeln();
      buffer.writeln('/// Serializes [data] into a JSON string.');
      buffer.writeln('String ${funcPrefix}ToJson($rootClassName data) =>');
      buffer.writeln('    json.encode(data.toJson());');
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
    if (klass.propertyNamesConstraint != null &&
        klass.propertyNamesConstraint!.hasRules) {
      final constraint = klass.propertyNamesConstraint!;
      if (constraint.validation != null) {
        final rules = _formatValidationConstraints(constraint.validation!);
        if (rules.isNotEmpty) {
          buffer.writeln('/// propertyNames: $rules');
        }
      }
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

    // Check if union contains any primitive variants
    final hasPrimitiveVariants = union.variants.any((v) => v.isPrimitive);
    final hasObjectVariants = union.variants.any((v) => !v.isPrimitive);

    buffer.writeln('sealed class ${klass.name} {');
    buffer.writeln('  const ${klass.name}();');
    buffer.writeln();
    if (options.emitValidationHelpers) {
      buffer.writeln(
        "  void validate({String pointer = '', ValidationContext? context});",
      );
      buffer.writeln();
    }
    
    // Use dynamic parameter if we have primitive variants
    final paramType = hasPrimitiveVariants ? 'dynamic' : 'Map<String, dynamic>';
    buffer.writeln(
      '  factory ${klass.name}.fromJson($paramType json) {',
    );

    // For unions with primitive variants, try runtime type checking first
    if (hasPrimitiveVariants) {
      for (final variant in union.variants.where((v) => v.isPrimitive)) {
        final primitiveType = variant.primitiveType!;
        if (primitiveType is PrimitiveTypeRef) {
          switch (primitiveType.typeName) {
            case 'Null':
              buffer.writeln('    if (json == null) return ${variant.classSpec.name}(null);');
            case 'String':
              buffer.writeln('    if (json is String) return ${variant.classSpec.name}(json);');
            case 'int':
              buffer.writeln('    if (json is int) return ${variant.classSpec.name}(json);');
            case 'num':
              buffer.writeln('    if (json is num) return ${variant.classSpec.name}(json);');
            case 'double':
              buffer.writeln('    if (json is num) return ${variant.classSpec.name}(json.toDouble());');
            case 'bool':
              buffer.writeln('    if (json is bool) return ${variant.classSpec.name}(json);');
          }
        } else if (primitiveType is EnumTypeRef) {
          buffer.writeln(
            "    if (json is String) return ${variant.classSpec.name}(${primitiveType.spec.extensionName}.fromJson(json));",
          );
        } else if (primitiveType is MixedEnumTypeRef) {
          buffer.writeln(
            '    return ${variant.classSpec.name}(${primitiveType.spec.name}.fromJson(json));',
          );
        } else if (primitiveType is ListTypeRef) {
          buffer.writeln(
            '    if (json is List) return ${variant.classSpec.name}(${primitiveType.deserializeInline('json', required: true)});',
          );
        } else if (primitiveType is ObjectTypeRef) {
          buffer.writeln(
            '    if (json is Map<String, dynamic>) return ${variant.classSpec.name}(${primitiveType.deserializeInline('json', required: true)});',
          );
        }
      }
      
      // If we have object variants, check if json is a Map
      if (hasObjectVariants) {
        buffer.writeln('    if (json is! Map<String, dynamic>) {');
        buffer.writeln(
          "      throw ArgumentError('Invalid ${klass.name} value: \${json.runtimeType}');",
        );
        buffer.writeln('    }');
      }
    }

    // Handle object variants with discriminator
    if (hasObjectVariants) {
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

      // Only process const/required variants for object variants
      final constVariants = union.variants
          .where((variant) => !variant.isPrimitive && variant.constProperties.isNotEmpty)
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
            .where((variant) => !variant.isPrimitive && variant.requiredProperties.isNotEmpty)
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

        final objectVariants = union.variants.where((v) => !v.isPrimitive).toList();
        if (objectVariants.length == 1) {
          buffer.writeln(
            '    return ${objectVariants.single.classSpec.name}.fromJson(json);',
          );
        } else if (objectVariants.isNotEmpty) {
          buffer.writeln(
            "    throw ArgumentError('No ${klass.name} variant matched heuristics (keys: \${sortedKeys.join(', ')}).');",
          );
        }
      } else {
        // No object variants, only primitives  - should not reach here due to early returns
        buffer.writeln(
          "    throw ArgumentError('Invalid ${klass.name} value type: \${json.runtimeType}');",
        );
      }

    buffer.writeln('  }');
    buffer.writeln();
    
    // Use dynamic return type if we have primitive variants
    final returnType = hasPrimitiveVariants ? 'dynamic' : 'Map<String, dynamic>';
    buffer.writeln('  $returnType toJson();');
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
    
    // Handle primitive variants
    if (variant.isPrimitive) {
      final primitiveType = variant.primitiveType!;
      final dartType = primitiveType.dartType();
      final serialized = primitiveType.serializeInline('value', required: true);
      
      // Add value field for primitive wrapper
      buffer.writeln('  final $dartType value;');
      buffer.writeln();
      buffer.writeln('  const ${klass.name}(this.value) : super();');
      buffer.writeln();
      buffer.writeln('  @override');
      buffer.writeln('  dynamic toJson() => $serialized;');
    } else {
      // Handle object variants (existing logic)
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

  String renderMixedEnum(IrMixedEnum mixedEnum) {
    final buffer = StringBuffer();
    if (options.emitDocumentation && mixedEnum.description != null) {
      _writeDocumentation(buffer, mixedEnum.description!);
    }

    // Base sealed class
    buffer.writeln('sealed class ${mixedEnum.name} {');
    buffer.writeln('  const ${mixedEnum.name}();');
    buffer.writeln();
    buffer.writeln('  factory ${mixedEnum.name}.fromJson(dynamic json) {');
    
    // Generate type checks for each variant
    for (final variant in mixedEnum.variants) {
      if (variant.dartType == 'null') {
        buffer.writeln('    if (json == null) return const ${variant.className}();');
      } else if (variant.dartType == 'String') {
        buffer.writeln('    if (json is String) return ${variant.className}(json);');
      } else if (variant.dartType == 'int') {
        buffer.writeln('    if (json is int) return ${variant.className}(json);');
      } else if (variant.dartType == 'double') {
        buffer.writeln('    if (json is double) return ${variant.className}(json);');
      } else if (variant.dartType == 'bool') {
        buffer.writeln('    if (json is bool) return ${variant.className}(json);');
      }
    }
    
    buffer.writeln('    throw Exception(\'Unknown ${mixedEnum.name} type: \${json.runtimeType}\');');
    buffer.writeln('  }');
    buffer.writeln();
    buffer.writeln('  dynamic toJson();');
    buffer.writeln('}');
    buffer.writeln();

    // Generate variant classes
    for (final variant in mixedEnum.variants) {
      if (variant.dartType == 'null') {
        buffer.writeln('class ${variant.className} extends ${mixedEnum.name} {');
        buffer.writeln('  const ${variant.className}();');
        buffer.writeln();
        buffer.writeln('  @override');
        buffer.writeln('  dynamic toJson() => null;');
        buffer.writeln('}');
      } else {
        buffer.writeln('class ${variant.className} extends ${mixedEnum.name} {');
        buffer.writeln('  const ${variant.className}(this.value);');
        buffer.writeln();
        buffer.writeln('  final ${variant.dartType} value;');
        buffer.writeln();
        buffer.writeln('  @override');
        buffer.writeln('  dynamic toJson() => value;');
        buffer.writeln('}');
      }
      if (variant != mixedEnum.variants.last) {
        buffer.writeln();
      }
    }

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
    return _defaultLiteralForType(property.typeRef, value);
  }

  String? _defaultLiteralForType(TypeRef typeRef, Object? value) {
    if (typeRef is ValidatedTypeRef) {
      return _defaultLiteralForType(typeRef.inner, value);
    }
    if (typeRef is ObjectTypeRef) {
      final union = _unionByBaseName[typeRef.spec.name];
      if (union != null) {
        final variant = _selectUnionVariantForDefault(union, value);
        if (variant != null) {
          return _unionDefaultExpression(variant, value);
        }
      }
    }
    if (typeRef is EnumTypeRef && value is String) {
      return '${typeRef.spec.extensionName}.fromJson(${_stringLiteral(value)})';
    }
    if (typeRef is MixedEnumTypeRef) {
      return '${typeRef.spec.name}.fromJson(${_literalExpression(value)})';
    }
    return _valueToLiteral(value);
  }

  IrUnionVariant? _selectUnionVariantForDefault(
    IrUnion union,
    Object? value,
  ) {
    if (value == null) {
      return union.variants.firstWhereOrNull(
        (variant) =>
            variant.isPrimitive &&
            variant.primitiveType is PrimitiveTypeRef &&
            (variant.primitiveType as PrimitiveTypeRef).typeName == 'Null',
      );
    }

    for (final variant in union.variants) {
      if (!variant.isPrimitive) {
        continue;
      }
      final primitive = variant.primitiveType!;
      if (primitive is PrimitiveTypeRef) {
        final typeName = primitive.typeName;
        if (value is String && typeName == 'String') return variant;
        if (value is bool && typeName == 'bool') return variant;
        if (value is int && typeName == 'int') return variant;
        if (value is num && (typeName == 'double' || typeName == 'num')) {
          return variant;
        }
      } else if (primitive is ListTypeRef && value is List) {
        return variant;
      } else if (primitive is EnumTypeRef && value is String) {
        return variant;
      }
    }

    if (value is Map) {
      final objectVariants = union.variants.where((v) => !v.isPrimitive);
      if (objectVariants.length == 1) {
        return objectVariants.single;
      }
    }

    return null;
  }

  String? _unionDefaultExpression(IrUnionVariant variant, Object? value) {
    final className = variant.classSpec.name;
    if (variant.isPrimitive) {
      final primitive = variant.primitiveType!;
      if (primitive is PrimitiveTypeRef) {
        return 'const $className(${_valueToLiteral(value) ?? 'null'})';
      }
      if (primitive is ListTypeRef) {
        final literal = _valueToLiteral(value) ?? 'const []';
        return 'const $className($literal)';
      }
      if (primitive is EnumTypeRef && value is String) {
        final enumValue =
            '${primitive.spec.extensionName}.fromJson(${_stringLiteral(value)})';
        return '$className($enumValue)';
      }
    } else if (value is Map) {
      final literal = _valueToLiteral(value) ?? 'const {}';
      return '$className.fromJson($literal)';
    }
    return null;
  }
  
  String? _valueToLiteral(Object? value) {
    if (value == null) {
      return 'null';
    }
    if (value is num || value is bool) {
      return value.toString();
    }
    if (value is String) {
      return _stringLiteral(value);
    }
    if (value is List) {
      final items = value.map((item) => _valueToLiteral(item) ?? 'null').join(', ');
      return 'const [$items]';
    }
    if (value is Map) {
      final entries = value.entries.map((entry) {
        final key = _stringLiteral(entry.key.toString());
        final val = _valueToLiteral(entry.value) ?? 'null';
        return '$key: $val';
      }).join(', ');
      return 'const {$entries}';
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
      if (property.isReadOnly) {
        buffer.writeln('  /// READ-ONLY: This property is managed by the server and should not be sent in requests.');
      }
      if (property.isWriteOnly) {
        buffer.writeln('  /// WRITE-ONLY: This property should not be included in responses (e.g., passwords, secrets).');
      }
      if (property.validation != null && property.validation!.hasRules) {
        final constraints = _formatValidationConstraints(property.validation!);
        if (constraints.isNotEmpty) {
          buffer.writeln('  /// Constraints: $constraints');
        }
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

  String _formatValidationConstraints(PropertyValidationRules rules) {
    final parts = <String>[];
    
    // String constraints
    if (rules.minLength != null) parts.add('minLength: ${rules.minLength}');
    if (rules.maxLength != null) parts.add('maxLength: ${rules.maxLength}');
    if (rules.pattern != null) parts.add('pattern: ${rules.pattern}');
    
    // Numeric constraints
    if (rules.minimum != null) {
      if (rules.exclusiveMinimum) {
        parts.add('exclusiveMinimum: ${rules.minimum}');
      } else {
        parts.add('minimum: ${rules.minimum}');
      }
    }
    if (rules.maximum != null) {
      if (rules.exclusiveMaximum) {
        parts.add('exclusiveMaximum: ${rules.maximum}');
      } else {
        parts.add('maximum: ${rules.maximum}');
      }
    }
    if (rules.multipleOf != null) parts.add('multipleOf: ${rules.multipleOf}');
    
    // Array constraints
    if (rules.minItems != null) parts.add('minItems: ${rules.minItems}');
    if (rules.maxItems != null) parts.add('maxItems: ${rules.maxItems}');
    if (rules.uniqueItems != null && rules.uniqueItems!) {
      parts.add('uniqueItems: true');
    }
    
    // Object constraints
    if (rules.minProperties != null) {
      parts.add('minProperties: ${rules.minProperties}');
    }
    if (rules.maxProperties != null) {
      parts.add('maxProperties: ${rules.maxProperties}');
    }
    
    // Const value
    if (rules.constValue != null) {
      parts.add('const: ${rules.constValue}');
    }

    if (rules.allowedTypes != null && rules.allowedTypes!.isNotEmpty) {
      final joined = rules.allowedTypes!.join(', ');
      parts.add('types: [$joined]');
    }
    if (rules.format != null) {
      parts.add('format: ${rules.format}');
    }
    
    return parts.join(', ');
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
      _writeValidationRulesForType(
        buffer,
        property.typeRef,
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

    _writeContentValidation(
      buffer,
      property,
      valueVar,
      pointerVar,
      indent: indent,
      suffix: suffix,
    );
  }

  void _writeContentValidation(
    StringBuffer buffer,
    IrProperty property,
    String valueVar,
    String pointerVar, {
    required String indent,
    required String suffix,
  }) {
    if (!options.enableContentValidation) {
      return;
    }
    final contentTypeRef = property.contentSchemaTypeRef;
    if (contentTypeRef == null) {
      return;
    }
    if (!_isJsonMediaType(property.contentMediaType)) {
      return;
    }

    final decodedVar = '_contentDecoded$suffix';
    final jsonVar = '_contentJson$suffix';
    final contentVar = '_contentValue$suffix';

    final encoding = property.contentEncoding;
    if (encoding != null && encoding.isNotEmpty) {
      if (property.typeRef is ContentEncodedTypeRef) {
        buffer.writeln(
          '$indent final $decodedVar = utf8.decode($valueVar);',
        );
      } else {
        final decodeExpr = _contentDecodeExpression(encoding, valueVar);
        if (decodeExpr == null) {
          return;
        }
        buffer.writeln(
          '$indent final $decodedVar = utf8.decode($decodeExpr);',
        );
      }
    } else {
      buffer.writeln('$indent final $decodedVar = $valueVar;');
    }

    buffer.writeln('$indent dynamic $jsonVar;');
    buffer.writeln('$indent try {');
    buffer.writeln('$indent  $jsonVar = jsonDecode($decodedVar);');
    buffer.writeln('$indent } catch (_) {');
    final decodeMessage = _stringLiteral(
      'Expected content to be valid JSON for contentSchema validation.',
    );
    buffer.writeln(
      '$indent  throwValidationError($pointerVar, \'contentSchema\', $decodeMessage);',
    );
    buffer.writeln('$indent }');

    buffer.writeln('$indent try {');
    buffer.writeln(
      '$indent  final $contentVar = ${contentTypeRef.deserializeInline(jsonVar, required: true)};',
    );
    _writeNestedValidation(
      buffer,
      contentTypeRef,
      contentVar,
      pointerVar,
      '$indent  ',
      '${suffix}content',
    );
    buffer.writeln('$indent } on ValidationError {');
    buffer.writeln('$indent  rethrow;');
    buffer.writeln('$indent } catch (_) {');
    final schemaMessage = _stringLiteral(
      'Content does not match schema defined by contentSchema.',
    );
    buffer.writeln(
      '$indent  throwValidationError($pointerVar, \'contentSchema\', $schemaMessage);',
    );
    buffer.writeln('$indent }');
  }

  String? _contentDecodeExpression(String encoding, String valueExpression) {
    switch (encoding) {
      case 'base64':
        return 'base64Decode($valueExpression)';
      case 'base16':
        return '_base16Decode($valueExpression)';
      case 'base32':
        return '_base32Decode($valueExpression)';
      case 'quoted-printable':
        return '_quotedPrintableDecode($valueExpression)';
      default:
        return null;
    }
  }

  bool _isJsonMediaType(String? mediaType) {
    if (mediaType == null) {
      return true;
    }
    final base = mediaType.split(';').first.trim().toLowerCase();
    return base == 'application/json' ||
        base == 'text/json' ||
        base.endsWith('+json');
  }

  void _writeValidationRulesForType(
    StringBuffer buffer,
    TypeRef ref,
    PropertyValidationRules rules,
    String valueVar,
    String pointerVar, {
    required String indent,
    required String suffix,
  }) {
    final baseRef = _unwrapValidated(ref);
    if (rules.allowedTypes != null && rules.allowedTypes!.isNotEmpty) {
      final condition = _allowedTypesCondition(baseRef, rules.allowedTypes!, valueVar);
      final allowedList = rules.allowedTypes!.join(', ');
      buffer.writeln('$indent if (!($condition)) {');
      final message = _stringLiteral(
        'Expected value to match one of the allowed types [$allowedList].',
      );
      buffer.writeln(
        '$indent  throwValidationError($pointerVar, \'type\', $message);',
      );
      buffer.writeln('$indent }');
    }
    if (rules.format != null) {
      final condition =
          _formatValidationCondition(baseRef, rules.format!, valueVar);
      if (condition != null) {
        buffer.writeln('$indent if ($condition) {');
        final message = _stringLiteral(
          'Value does not match format ${rules.format}.',
        );
        buffer.writeln(
          '$indent  throwValidationError($pointerVar, \'format\', $message);',
        );
        buffer.writeln('$indent }');
      }
    }
    if (rules.minLength != null && _isStringLike(ref)) {
      buffer.writeln('${indent}if ($valueVar.length < ${rules.minLength}) {');
      final message = _stringLiteral(
        'Expected at least ${rules.minLength} characters but found ',
      );
      buffer.writeln(
        '$indent  throwValidationError($pointerVar, \'minLength\', $message + $valueVar.length.toString() + \'.\');',
      );
      buffer.writeln('$indent}');
    }

    if (rules.maxLength != null && _isStringLike(ref)) {
      buffer.writeln('${indent}if ($valueVar.length > ${rules.maxLength}) {');
      final message = _stringLiteral(
        'Expected at most ${rules.maxLength} characters but found ',
      );
      buffer.writeln(
        '$indent  throwValidationError($pointerVar, \'maxLength\', $message + $valueVar.length.toString() + \'.\');',
      );
      buffer.writeln('$indent}');
    }

    if (rules.minimum != null && _isNumericType(ref)) {
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

    if (rules.maximum != null && _isNumericType(ref)) {
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

    if (rules.multipleOf != null && _isNumericType(ref)) {
      final remainderVar = '_remainder$suffix';
      buffer.writeln(
        '${indent}final $remainderVar = $valueVar % ${rules.multipleOf};',
      );
      buffer.writeln('${indent}if ($remainderVar != 0) {');
      final message = _stringLiteral(
        'Expected value to be a multiple of ${rules.multipleOf} but found ',
      );
      buffer.writeln(
        '$indent  throwValidationError($pointerVar, \'multipleOf\', $message + $valueVar.toString() + \'.\');',
      );
      buffer.writeln('$indent}');
    }

    if (rules.pattern != null && _isStringLike(ref)) {
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
      final actualExpr = _constComparableExpressionForType(ref, valueVar);
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

    if (rules.minItems != null && baseRef is ListTypeRef) {
      buffer.writeln('${indent}if ($valueVar.length < ${rules.minItems}) {');
      final message = _stringLiteral(
        'Expected at least ${rules.minItems} items but found ',
      );
      buffer.writeln(
        '$indent  throwValidationError($pointerVar, \'minItems\', $message + $valueVar.length.toString() + \'.\');',
      );
      buffer.writeln('$indent}');
    }

    if (rules.maxItems != null && baseRef is ListTypeRef) {
      buffer.writeln('${indent}if ($valueVar.length > ${rules.maxItems}) {');
      final message = _stringLiteral(
        'Expected at most ${rules.maxItems} items but found ',
      );
      buffer.writeln(
        '$indent  throwValidationError($pointerVar, \'maxItems\', $message + $valueVar.length.toString() + \'.\');',
      );
      buffer.writeln('$indent}');
    }

    if (rules.uniqueItems == true && baseRef is ListTypeRef) {
      final seenVar = '_seen$suffix';
      buffer.writeln('${indent}final $seenVar = <String>{};');
      buffer.writeln('${indent}for (var i = 0; i < $valueVar.length; i++) {');
      buffer.writeln('$indent  final item = $valueVar[i];');
      final serialized = baseRef.itemType.serializeInline(
        'item',
        required: true,
      );
      buffer.writeln('$indent  final key = uniqueItemKey($serialized);');
      buffer.writeln('$indent  if (!$seenVar.add(key)) {');
      final message = _stringLiteral(
        'Expected all items to be unique but found a duplicate at index ',
      );
      buffer.writeln(
        '$indent    throwValidationError($pointerVar, \'uniqueItems\', $message + i.toString() + \'.\');',
      );
      buffer.writeln('$indent  }');
      buffer.writeln('$indent}');
    }

    if ((rules.minProperties != null || rules.maxProperties != null) &&
        baseRef is ObjectTypeRef) {
      final countVar = '_propertyCount$suffix';
      buffer.writeln('${indent}final $countVar = $valueVar.toJson().length;');
      if (rules.minProperties != null) {
        buffer.writeln(
          '${indent}if ($countVar < ${rules.minProperties}) {',
        );
        final message = _stringLiteral(
          'Expected at least ${rules.minProperties} properties but found ',
        );
        buffer.writeln(
          '$indent  throwValidationError($pointerVar, \'minProperties\', $message + $countVar.toString() + \'.\');',
        );
        buffer.writeln('$indent}');
      }
      if (rules.maxProperties != null) {
        buffer.writeln(
          '${indent}if ($countVar > ${rules.maxProperties}) {',
        );
        final message = _stringLiteral(
          'Expected at most ${rules.maxProperties} properties but found ',
        );
        buffer.writeln(
          '$indent  throwValidationError($pointerVar, \'maxProperties\', $message + $countVar.toString() + \'.\');',
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
    if (ref is ApplicatorTypeRef) {
      _writeNestedValidation(
        buffer,
        ref.inner,
        valueExpression,
        pointerExpression,
        indent,
        suffix,
      );
      _writeApplicatorValidation(
        buffer,
        ref,
        valueExpression,
        pointerExpression,
        indent,
        suffix,
      );
      return;
    }
    if (ref is ValidatedTypeRef) {
      if (ref.validation.hasRules) {
        _writeValidationRulesForType(
          buffer,
          ref.inner,
          ref.validation,
          valueExpression,
          pointerExpression,
          indent: indent,
          suffix: suffix,
        );
      }
      _writeNestedValidation(
        buffer,
        ref.inner,
        valueExpression,
        pointerExpression,
        indent,
        suffix,
      );
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
        final matchCondition = _containsMatchCondition(containsType, 'item');
        buffer.writeln('$indent  var matches = $matchCondition;');
        if (_typeRequiresValidation(containsType, options)) {
          buffer.writeln('$indent  if (matches) {');
          buffer.writeln('$indent    try {');
          _writeNestedValidation(
            buffer,
            containsType,
            'item',
            'itemPointer',
            '$indent    ',
            '${suffix}c',
          );
          buffer.writeln('$indent    } on ValidationError {');
          buffer.writeln('$indent      matches = false;');
          buffer.writeln('$indent    }');
          buffer.writeln('$indent  }');
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

  void _writeApplicatorValidation(
    StringBuffer buffer,
    ApplicatorTypeRef ref,
    String valueExpression,
    String pointerExpression,
    String indent,
    String suffix,
  ) {
    if (ref.constraints.isEmpty) {
      return;
    }
    final jsonVar = '_json$suffix';
    final jsonExpression = ref.inner.serializeInline(
      valueExpression,
      required: true,
    );
    buffer.writeln('$indent final $jsonVar = $jsonExpression;');

    for (var constraintIndex = 0;
        constraintIndex < ref.constraints.length;
        constraintIndex++) {
      final constraint = ref.constraints[constraintIndex];
      final matchVars = <String>[];
      final contextVars = <String>[];

      for (var branchIndex = 0;
          branchIndex < constraint.branches.length;
          branchIndex++) {
        final branch = constraint.branches[branchIndex];
        final matchVar = '_constraint${suffix}m${constraintIndex}_$branchIndex';
        final contextVar =
            '_constraint${suffix}c${constraintIndex}_$branchIndex';
        final valueVar =
            '_constraint${suffix}v${constraintIndex}_$branchIndex';

        buffer.writeln('$indent final $contextVar = context == null ? null : ValidationContext();');
        buffer.writeln('$indent var $matchVar = false;');
        buffer.writeln('$indent try {');
        buffer.writeln('$indent  final context = $contextVar;');
        buffer.writeln(
          '$indent  final $valueVar = ${branch.typeRef.deserializeInline(jsonVar, required: true)};',
        );
        _writeNestedValidation(
          buffer,
          branch.typeRef,
          valueVar,
          pointerExpression,
          '$indent  ',
          '${suffix}c${constraintIndex}b$branchIndex',
        );
        buffer.writeln('$indent  $matchVar = true;');
        buffer.writeln('$indent } on ValidationError {');
        buffer.writeln('$indent } catch (_) {');
        buffer.writeln('$indent }');
        matchVars.add(matchVar);
        contextVars.add(contextVar);
      }

      final matchesVar = '_constraint${suffix}matches$constraintIndex';
      buffer.writeln(
        '$indent final $matchesVar = <bool>[${matchVars.join(', ')}];',
      );

      switch (constraint.keyword) {
        case 'allOf':
          buffer.writeln('$indent if ($matchesVar.any((value) => !value)) {');
          buffer.writeln(
            '$indent  throwValidationError($pointerExpression, \'allOf\', ${_stringLiteral('Expected all subschemas in ${constraint.schemaPointer} to validate.')});',
          );
          buffer.writeln('$indent }');
          for (var branchIndex = 0;
              branchIndex < matchVars.length;
              branchIndex++) {
            buffer.writeln(
              '$indent if (context != null && ${matchVars[branchIndex]} && ${contextVars[branchIndex]} != null) {',
            );
            buffer.writeln(
              '$indent  context.mergeFrom(${contextVars[branchIndex]}!);',
            );
            buffer.writeln('$indent }');
          }
          break;
        case 'anyOf':
          buffer.writeln('$indent if (!$matchesVar.any((value) => value)) {');
          buffer.writeln(
            '$indent  throwValidationError($pointerExpression, \'anyOf\', ${_stringLiteral('Expected at least one subschema in ${constraint.schemaPointer} to validate.')});',
          );
          buffer.writeln('$indent }');
          for (var branchIndex = 0;
              branchIndex < matchVars.length;
              branchIndex++) {
            buffer.writeln(
              '$indent if (context != null && ${matchVars[branchIndex]} && ${contextVars[branchIndex]} != null) {',
            );
            buffer.writeln(
              '$indent  context.mergeFrom(${contextVars[branchIndex]}!);',
            );
            buffer.writeln('$indent }');
          }
          break;
        case 'oneOf':
          final countVar = '_constraint${suffix}count$constraintIndex';
          buffer.writeln(
            '$indent final $countVar = $matchesVar.where((value) => value).length;',
          );
          buffer.writeln('$indent if ($countVar != 1) {');
          buffer.writeln(
            '$indent  throwValidationError($pointerExpression, \'oneOf\', ${_stringLiteral('Expected exactly one subschema in ${constraint.schemaPointer} to validate.')});',
          );
          buffer.writeln('$indent }');
          for (var branchIndex = 0;
              branchIndex < matchVars.length;
              branchIndex++) {
            buffer.writeln(
              '$indent if (context != null && ${matchVars[branchIndex]} && ${contextVars[branchIndex]} != null) {',
            );
            buffer.writeln(
              '$indent  context.mergeFrom(${contextVars[branchIndex]}!);',
            );
            buffer.writeln('$indent }');
          }
          break;
        case 'not':
          buffer.writeln('$indent if ($matchesVar.any((value) => value)) {');
          buffer.writeln(
            '$indent  throwValidationError($pointerExpression, \'not\', ${_stringLiteral('Expected subschema at ${constraint.schemaPointer} to fail validation.')});',
          );
          buffer.writeln('$indent }');
          break;
        default:
          break;
      }
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

  TypeRef _unwrapValidated(TypeRef ref) {
    if (ref is ValidatedTypeRef) {
      return _unwrapValidated(ref.inner);
    }
    if (ref is ApplicatorTypeRef) {
      return _unwrapValidated(ref.inner);
    }
    return ref;
  }

  String _allowedTypesCondition(
    TypeRef ref,
    List<String> allowedTypes,
    String valueExpression,
  ) {
    final checks = <String>[];
    for (final type in allowedTypes) {
      switch (type) {
        case 'null':
          checks.add('$valueExpression == null');
          break;
        case 'string':
          checks.add(_stringTypeCheck(ref, valueExpression));
          break;
        case 'integer':
          checks.add('$valueExpression is int');
          break;
        case 'number':
          checks.add('$valueExpression is num');
          break;
        case 'boolean':
          checks.add('$valueExpression is bool');
          break;
        case 'array':
          checks.add('$valueExpression is List');
          break;
        case 'object':
          if (ref is ObjectTypeRef) {
            checks.add('$valueExpression is ${ref.spec.name}');
          } else {
            checks.add('$valueExpression is Map');
          }
          break;
        default:
          break;
      }
    }
    if (checks.isEmpty) {
      return 'true';
    }
    return checks.join(' || ');
  }

  String _stringTypeCheck(TypeRef ref, String valueExpression) {
    if (ref is FormatTypeRef) {
      return '$valueExpression is ${ref.typeName}';
    }
    if (ref is ContentEncodedTypeRef) {
      return '$valueExpression is Uint8List';
    }
    if (ref is EnumTypeRef) {
      return '$valueExpression is ${ref.spec.name}';
    }
    if (ref is MixedEnumTypeRef) {
      return '$valueExpression is ${ref.spec.name}';
    }
    if (ref is PrimitiveTypeRef && ref.typeName != 'dynamic') {
      return '$valueExpression is ${ref.typeName}';
    }
    return '$valueExpression is String';
  }

  String? _formatValidationCondition(
    TypeRef ref,
    String format,
    String valueExpression,
  ) {
    if (ref is DynamicTypeRef) {
      return '$valueExpression is String && !isValidFormat(${_stringLiteral(format)}, $valueExpression)';
    }
    if (ref is PrimitiveTypeRef && ref.typeName == 'String') {
      return '!isValidFormat(${_stringLiteral(format)}, $valueExpression)';
    }
    if (ref is FormatTypeRef ||
        ref is EnumTypeRef ||
        ref is MixedEnumTypeRef ||
        ref is ContentEncodedTypeRef) {
      final serialized = ref.serializeInline(valueExpression, required: true);
      return '!isValidFormat(${_stringLiteral(format)}, $serialized)';
    }
    return null;
  }

  bool _isStringLike(TypeRef ref) {
    final base = _unwrapValidated(ref);
    return base is PrimitiveTypeRef && base.typeName == 'String';
  }

  bool _isNumericType(TypeRef ref) {
    final base = _unwrapValidated(ref);
    if (base is! PrimitiveTypeRef) {
      return false;
    }
    return base.typeName == 'int' ||
        base.typeName == 'double' ||
        base.typeName == 'num';
  }

  String? _constComparableExpressionForType(TypeRef ref, String valueVar) {
    final base = _unwrapValidated(ref);
    if (base is PrimitiveTypeRef) {
      final typeName = base.typeName;
      if (typeName == 'String' ||
          typeName == 'int' ||
          typeName == 'double' ||
          typeName == 'num' ||
          typeName == 'bool') {
        return valueVar;
      }
    }
    if (base is FormatTypeRef) {
      return base.serializeInline(valueVar, required: true);
    }
    return null;
  }

  // Helper functions for content encoding
  static const String _base16Helpers = '''
// Base16 (hex) encoding/decoding helpers
Uint8List _base16Decode(String input) {
  final hex = input.toUpperCase().replaceAll(RegExp(r'\\s'), '');
  if (hex.length % 2 != 0) {
    throw FormatException('Invalid base16 string length');
  }
  final bytes = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < bytes.length; i++) {
    final byte = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    bytes[i] = byte;
  }
  return bytes;
}

String _base16Encode(Uint8List bytes) {
  final buffer = StringBuffer();
  for (final byte in bytes) {
    buffer.write(byte.toRadixString(16).toUpperCase().padLeft(2, '0'));
  }
  return buffer.toString();
}''';

  static const String _base32Helpers = '''
// Base32 encoding/decoding helpers
Uint8List _base32Decode(String input) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  final normalized = input.toUpperCase().replaceAll(RegExp(r'[=\\s]'), '');
  final bits = <int>[];
  
  for (final char in normalized.split('')) {
    final value = alphabet.indexOf(char);
    if (value == -1) {
      throw FormatException('Invalid base32 character: \$char');
    }
    for (var i = 4; i >= 0; i--) {
      bits.add((value >> i) & 1);
    }
  }
  
  final bytes = <int>[];
  for (var i = 0; i < bits.length - (bits.length % 8); i += 8) {
    var byte = 0;
    for (var j = 0; j < 8; j++) {
      byte = (byte << 1) | bits[i + j];
    }
    bytes.add(byte);
  }
  
  return Uint8List.fromList(bytes);
}

String _base32Encode(Uint8List bytes) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  final bits = <int>[];
  
  for (final byte in bytes) {
    for (var i = 7; i >= 0; i--) {
      bits.add((byte >> i) & 1);
    }
  }
  
  final buffer = StringBuffer();
  for (var i = 0; i < bits.length; i += 5) {
    var value = 0;
    for (var j = 0; j < 5 && i + j < bits.length; j++) {
      value = (value << 1) | bits[i + j];
    }
    if (i + 5 > bits.length) {
      value <<= 5 - (bits.length - i);
    }
    buffer.write(alphabet[value]);
  }
  
  while (buffer.length % 8 != 0) {
    buffer.write('=');
  }
  
  return buffer.toString();
}''';

  static const String _quotedPrintableHelpers = '''
// Quoted-printable encoding/decoding helpers
Uint8List _quotedPrintableDecode(String input) {
  final bytes = <int>[];
  var i = 0;
  
  while (i < input.length) {
    if (input[i] == '=') {
      if (i + 2 < input.length) {
        final hex = input.substring(i + 1, i + 3);
        if (hex == '\\r\\n' || hex == '\\n') {
          // Soft line break, skip
          i += hex == '\\r\\n' ? 3 : 2;
          continue;
        }
        try {
          bytes.add(int.parse(hex, radix: 16));
          i += 3;
        } catch (_) {
          bytes.add(input.codeUnitAt(i));
          i++;
        }
      } else {
        bytes.add(input.codeUnitAt(i));
        i++;
      }
    } else {
      bytes.add(input.codeUnitAt(i));
      i++;
    }
  }
  
  return Uint8List.fromList(bytes);
}

String _quotedPrintableEncode(Uint8List bytes) {
  final buffer = StringBuffer();
  var lineLength = 0;
  
  for (final byte in bytes) {
    if (lineLength >= 75) {
      buffer.write('=\\n');
      lineLength = 0;
    }
    
    if ((byte >= 33 && byte <= 60) || (byte >= 62 && byte <= 126)) {
      buffer.writeCharCode(byte);
      lineLength++;
    } else {
      final hex = byte.toRadixString(16).toUpperCase().padLeft(2, '0');
      buffer.write('=\$hex');
      lineLength += 3;
    }
  }
  
  return buffer.toString();
}''';
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
    if (options.enableContentValidation &&
        property.contentSchemaTypeRef != null) {
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
  if (ref is ValidatedTypeRef) {
    if (ref.validation.hasRules) {
      return true;
    }
    return _typeRequiresValidation(ref.inner, options, stack);
  }
  if (ref is ApplicatorTypeRef) {
    if (ref.constraints.isNotEmpty) {
      return true;
    }
    return _typeRequiresValidation(ref.inner, options, stack);
  }
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
  if (ref is ValidatedTypeRef) {
    return _containsMatchCondition(ref.inner, valueExpression);
  }
  if (ref is ApplicatorTypeRef) {
    return _containsMatchCondition(ref.inner, valueExpression);
  }
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
