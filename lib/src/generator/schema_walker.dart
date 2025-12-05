part of 'package:schema2model/src/generator.dart';

/// Walks a JSON Schema graph and produces an intermediate representation that
/// downstream emitters can translate into Dart source.
class _SchemaCacheKey {
  _SchemaCacheKey(Uri uri, this.pointer) : uriKey = _normalizeUri(uri);

  final String uriKey;
  final String pointer;

  @override
  int get hashCode => Object.hash(uriKey, pointer);

  @override
  bool operator ==(Object other) {
    return other is _SchemaCacheKey &&
        other.uriKey == uriKey &&
        other.pointer == pointer;
  }

  static String _normalizeUri(Uri uri) {
    final raw = uri.toString();
    final hashIndex = raw.indexOf('#');
    if (hashIndex == -1) {
      return raw;
    }
    return raw.substring(0, hashIndex);
  }
}

class _SchemaLocation {
  const _SchemaLocation({required this.uri, required this.pointer});

  final Uri uri;
  final String pointer;
}

class _ResolvedSchema {
  const _ResolvedSchema({required this.schema, required this.location});

  final Map<String, dynamic>? schema;
  final _SchemaLocation location;
}

class _DynamicScopeEntry {
  const _DynamicScopeEntry({required this.name, required this.location});

  final String name;
  final _SchemaLocation location;
}

class _SchemaWalker {
  _SchemaWalker(
    this._rootSchema,
    this._options, {
    required Uri baseUri,
    required SchemaDocumentLoader documentLoader,
  }) : _typeCache = {},
       _inProgress = <_SchemaCacheKey>{},
       _classes = LinkedHashMap<String, IrClass>(),
       _enums = LinkedHashMap<String, IrEnum>(),
       _mixedEnums = LinkedHashMap<String, IrMixedEnum>(),
       _unions = <IrUnion>[],
       _usedClassNames = <String>{},
       _usedEnumNames = <String>{},
       _classByLocation = <_SchemaCacheKey, IrClass>{},
       _enumByLocation = <_SchemaCacheKey, IrEnum>{},
       _mixedEnumByLocation = <_SchemaCacheKey, IrMixedEnum>{},
       _helpers = LinkedHashMap<String, IrHelper>(),
       _rootUri = baseUri,
       _documentLoader = documentLoader,
       _documentCache = {baseUri: _rootSchema},
       _documentDialects = <Uri, SchemaDialect>{},
       _anchorsByDocument = <Uri, Map<String, _SchemaLocation>>{},
       _dynamicAnchorsByDocument = <Uri, Map<String, _SchemaLocation>>{},
       _idOrigins = <String, _SchemaLocation>{},
       _dynamicScope = <_DynamicScopeEntry>[],
       _indexedDocuments = <Uri>{},
       _indexedLocations = <_SchemaCacheKey>{} {
    final rootDialect = _detectDocumentDialect(baseUri, _rootSchema);
    _documentDialects[baseUri] = rootDialect;
    _indexDocument(baseUri, _rootSchema);
  }

  final Map<String, dynamic> _rootSchema;
  final SchemaGeneratorOptions _options;
  final Map<_SchemaCacheKey, TypeRef> _typeCache;
  final Set<_SchemaCacheKey> _inProgress;
  final LinkedHashMap<String, IrClass> _classes;
  final LinkedHashMap<String, IrEnum> _enums;
  final LinkedHashMap<String, IrMixedEnum> _mixedEnums;
  final List<IrUnion> _unions;
  final Set<String> _usedClassNames;
  final Set<String> _usedEnumNames;
  final Map<_SchemaCacheKey, IrClass> _classByLocation;
  final Map<_SchemaCacheKey, IrEnum> _enumByLocation;
  final Map<_SchemaCacheKey, IrMixedEnum> _mixedEnumByLocation;
  final LinkedHashMap<String, IrHelper> _helpers;
  final Uri _rootUri;
  final SchemaDocumentLoader _documentLoader;
  final Map<Uri, Map<String, dynamic>> _documentCache;
  final Map<Uri, SchemaDialect> _documentDialects;
  final Map<Uri, Map<String, _SchemaLocation>> _anchorsByDocument;
  final Map<Uri, Map<String, _SchemaLocation>> _dynamicAnchorsByDocument;
  final Map<String, _SchemaLocation> _idOrigins;
  final List<_DynamicScopeEntry> _dynamicScope;
  final Set<Uri> _indexedDocuments;
  final Set<_SchemaCacheKey> _indexedLocations;

  SchemaIr build() {
    final rootLocation = _SchemaLocation(uri: _rootUri, pointer: '#');
    final rootDialect = _documentDialect(_rootUri);
    _log('Building IR starting at $_rootUri (dialect: ${rootDialect.uri})');
    final root = _ensureRootClass(rootLocation, rootDialect);
    _processDefinitions(_rootSchema, rootLocation, rootDialect);
    final classes = _orderedClasses(root);
    final enums = _enums.values.toList(growable: false);
    final mixedEnums = _mixedEnums.values.toList(growable: false);
    if (_options.emitValidationHelpers) {
      _helpers.putIfAbsent(_validationHelper.name, () => _validationHelper);
    }
    return SchemaIr(
      rootClass: root,
      classes: classes,
      enums: enums,
      mixedEnums: mixedEnums,
      unions: List<IrUnion>.unmodifiable(_unions),
      helpers: List<IrHelper>.unmodifiable(_helpers.values),
    );
  }

  void _log(String message) {
    if (_options.onWarning != null) {
      _options.onWarning!('[identifiers] $message');
    }
    // Fallback to print for interactive debugging
    // ignore: avoid_print
    print('[SchemaWalker] $message');
  }

  void _indexDocument(Uri uri, Map<String, dynamic> schema) {
    if (!_indexedDocuments.add(uri)) {
      return;
    }

    void visit(Map<String, dynamic>? node, Uri currentUri, String pointer) {
      if (node == null) {
        return;
      }

      final key = _SchemaCacheKey(currentUri, pointer);
      if (!_indexedLocations.add(key)) {
        return;
      }

      final location = _SchemaLocation(uri: currentUri, pointer: pointer);

      // Check if this location is a non-schema map (e.g., properties, patternProperties, dependentSchemas)
      // These maps have property/pattern names as keys, not schema keywords
      final isNonSchemaMap = pointer.endsWith('/properties') ||
          pointer.endsWith('/patternProperties') ||
          pointer.endsWith('/dependentSchemas') ||
          pointer == '#/properties' ||
          pointer == '#/patternProperties' ||
          pointer == '#/dependentSchemas';

      // Only process schema keywords if we're in a schema context
      if (!isNonSchemaMap) {
        final anchorValue = node[r'$anchor'];
        if (anchorValue is String && anchorValue.isNotEmpty) {
          _registerAnchor(currentUri, anchorValue, location);
        } else if (anchorValue != null && anchorValue is! String) {
          _schemaError('Expected "\$anchor" to be a string', location);
        }

        final dynamicAnchorValue = node[r'$dynamicAnchor'];
        if (dynamicAnchorValue is String && dynamicAnchorValue.isNotEmpty) {
          _registerDynamicAnchor(currentUri, dynamicAnchorValue, location);
        } else if (dynamicAnchorValue != null && dynamicAnchorValue is! String) {
          _schemaError('Expected "\$dynamicAnchor" to be a string', location);
        }
      }

      Uri effectiveUri = currentUri;
      var effectivePointer = pointer;
      
      if (!isNonSchemaMap) {
        final idValue = node[r'$id'];
        if (idValue is String && idValue.isNotEmpty) {
          final canonical = _resolveIdentifierUri(idValue, currentUri, location);
          _registerId(canonical, location);
          effectiveUri = canonical;
          effectivePointer = '#';
          final canonicalKey = _SchemaCacheKey(effectiveUri, effectivePointer);
          _indexedLocations.add(canonicalKey);
        } else if (idValue != null && idValue is! String) {
          _schemaError('Expected "\$id" to be a string', location);
        }
      }

      for (final entry in node.entries) {
        final key = entry.key;
        final value = entry.value;
        if (value is Map<String, dynamic>) {
          final childPointer = _pointerChild(effectivePointer, key);
          visit(value, effectiveUri, childPointer);
        } else if (value is List) {
          for (var i = 0; i < value.length; i++) {
            final element = value[i];
            if (element is Map<String, dynamic>) {
              final parentPointer = _pointerChild(effectivePointer, key);
              final childPointer = _pointerChild(parentPointer, '$i');
              visit(element, effectiveUri, childPointer);
            }
          }
        }
      }
    }

    visit(schema, uri, '#');
  }

  IrClass _ensureRootClass(_SchemaLocation location, SchemaDialect dialect) {
    final ref = _resolveSchema(
      _rootSchema,
      location,
      suggestedClassName: _options.effectiveRootClassName,
      dialect: dialect,
    );

    if (ref is ObjectTypeRef) {
      return ref.spec;
    }

    final fallbackName = _allocateClassName(_options.effectiveRootClassName);
    final klass = IrClass(
      name: fallbackName,
      description: _rootSchema['description'] as String?,
      properties: [
        IrProperty(
          jsonName: 'value',
          fieldName: 'value',
          typeRef: ref,
          isRequired: true,
          schemaPointer: _pointerChild(location.pointer, 'value'),
          description: null,
        ),
      ],
      conditionals: JsonConditionals(
        ifSchema: _rootSchema['if'] as Map<String, dynamic>?,
        thenSchema: _rootSchema['then'] as Map<String, dynamic>?,
        elseSchema: _rootSchema['else'] as Map<String, dynamic>?,
      ),
      dependentRequired: <String, Set<String>>{},
      dependentSchemas: <String, DependentSchemaConstraint>{},
      extensionAnnotations: _extractExtensionAnnotations(_rootSchema),
    );
    _classByLocation[_SchemaCacheKey(location.uri, location.pointer)] = klass;
    _classes[fallbackName] = klass;
    return klass;
  }

  List<IrClass> _orderedClasses(IrClass root) {
    final list = _classes.values.toList();
    list.sort((a, b) {
      if (identical(a, b)) return 0;
      if (identical(a, root)) return -1;
      if (identical(b, root)) return 1;
      return 0;
    });
    return list;
  }

  String _describeLocation(_SchemaLocation location) {
    final pointer = location.pointer == '#' ? '' : location.pointer;
    return '${location.uri}$pointer';
  }

  TypeRef _resolveSchema(
    Object? schema,
    _SchemaLocation location, {
    String? suggestedClassName,
    SchemaDialect? dialect,
  }) {
    final cacheKey = _SchemaCacheKey(location.uri, location.pointer);
    final cached = _typeCache[cacheKey];
    if (cached != null) {
      return cached;
    }

    final cachedClass = _classByLocation[cacheKey];
    if (cachedClass != null) {
      final ref = ObjectTypeRef(cachedClass);
      _typeCache[cacheKey] = ref;
      return ref;
    }

    final cachedEnum = _enumByLocation[cacheKey];
    if (cachedEnum != null) {
      final ref = EnumTypeRef(cachedEnum);
      _typeCache[cacheKey] = ref;
      return ref;
    }

    final cachedMixedEnum = _mixedEnumByLocation[cacheKey];
    if (cachedMixedEnum != null) {
      final ref = MixedEnumTypeRef(cachedMixedEnum);
      _typeCache[cacheKey] = ref;
      return ref;
    }

    if (schema == null) {
      const ref = DynamicTypeRef();
      _typeCache[cacheKey] = ref;
      return ref;
    }

    if (schema is bool) {
      final ref = schema ? const DynamicTypeRef() : const FalseTypeRef();
      _typeCache[cacheKey] = ref;
      return ref;
    }

    if (schema is! Map<String, dynamic>) {
      _schemaError(
        'Expected schema to be an object or boolean, got ${schema.runtimeType}.',
        location,
      );
    }

    final anchorValue = schema[r'$anchor'];
    if (anchorValue is String) {
      if (anchorValue.isEmpty) {
        _schemaError('"\$anchor" must be a non-empty string', location);
      }
      _registerAnchor(location.uri, anchorValue, location);
    } else if (anchorValue != null) {
      _schemaError('Expected "\$anchor" to be a string', location);
    }

    final dynamicAnchorValue = schema[r'$dynamicAnchor'];
    var pushedDynamicAnchor = false;
    if (dynamicAnchorValue is String) {
      if (dynamicAnchorValue.isEmpty) {
        _schemaError('"\$dynamicAnchor" must be a non-empty string', location);
      }
      _registerDynamicAnchor(location.uri, dynamicAnchorValue, location);
      _dynamicScope.add(
        _DynamicScopeEntry(name: dynamicAnchorValue, location: location),
      );
      pushedDynamicAnchor = true;
    } else if (dynamicAnchorValue != null) {
      _schemaError('Expected "\$dynamicAnchor" to be a string', location);
    }

    final idValue = schema[r'$id'];
    if (idValue is String && idValue.isNotEmpty) {
      final canonical = _resolveIdentifierUri(idValue, location.uri, location);
      _registerId(canonical, location);
      _documentCache.putIfAbsent(canonical, () => schema);
    }

    final inheritedDialect = dialect ?? _documentDialect(location.uri);

    if (_inProgress.contains(cacheKey)) {
      const ref = DynamicTypeRef();
      _typeCache[cacheKey] = ref;
      return ref;
    }
    
    if (_inProgress.length >= _options.maxReferenceDepth) {
      _schemaError(
        'Maximum reference depth of ${_options.maxReferenceDepth} exceeded. '
        'This may indicate a circular reference or excessively nested schema.',
        location,
      );
    }
    
    _inProgress.add(cacheKey);

    final pendingConstraints = <ConditionalConstraint>[];

    try {
      Map<String, dynamic> workingSchema = schema;
      final activeDialect = _dialectForSchema(
        workingSchema,
        location,
        inheritedDialect,
      );

      if (workingSchema case {'\$ref': final String refValue}) {
        final resolved = _resolveReference(refValue, location);
        final inferredName = _nameFromPointer(resolved.location.pointer);
        final refDialect = _documentDialect(resolved.location.uri);
        final typeRef = _resolveSchema(
          resolved.schema,
          resolved.location,
          suggestedClassName: suggestedClassName ?? inferredName,
          dialect: refDialect,
        );
        _typeCache[cacheKey] = typeRef;
        return typeRef;
      }

      if (workingSchema case {'\$dynamicRef': final String dynamicRef}) {
        final resolved = _resolveDynamicReference(dynamicRef, location);
        final inferredName = _nameFromPointer(resolved.location.pointer);
        final refDialect = _documentDialect(resolved.location.uri);
        final typeRef = _resolveSchema(
          resolved.schema,
          resolved.location,
          suggestedClassName: suggestedClassName ?? inferredName,
          dialect: refDialect,
        );
        _typeCache[cacheKey] = typeRef;
        return typeRef;
      }

      if (workingSchema case {
        'allOf': final List allOf,
      } when allOf.isNotEmpty) {
        workingSchema = _mergeAllOfSchemas(workingSchema, location);
      }

      _processDefinitions(workingSchema, location, activeDialect);

      final enumValues = workingSchema['enum'];
      if (enumValues is List && enumValues.isNotEmpty) {
        // Check if all values are strings (simple enum)
        if (enumValues.every((value) => value is String)) {
          final enumName = _allocateEnumName(
            workingSchema['title'] as String? ??
                suggestedClassName ??
                _nameFromPointer(location.pointer),
          );
          final description = workingSchema['description'] as String?;
          final spec = _enums.putIfAbsent(
            enumName,
            () => IrEnum(
              name: enumName,
              description: description,
              values: enumValues.mapIndexed((index, value) {
                final identifier = _Naming.enumValue(
                  value as String? ?? 'value$index',
                );
                return IrEnumValue(
                  identifier: identifier,
                  jsonValue: value as String,
                );
              }).toList(),
            ),
          );
          _enumByLocation[cacheKey] = spec;

          final ref = EnumTypeRef(spec);
          _typeCache[cacheKey] = ref;
          return ref;
        } else {
          // Mixed-type enum - use sealed class
          final enumName = _allocateEnumName(
            workingSchema['title'] as String? ??
                suggestedClassName ??
                _nameFromPointer(location.pointer),
          );
          final description = workingSchema['description'] as String?;
          
          // Group values by type
          final Map<String, List<dynamic>> valuesByType = {};
          for (final value in enumValues) {
            String typeKey;
            if (value == null) {
              typeKey = 'null';
            } else if (value is String) {
              typeKey = 'String';
            } else if (value is int) {
              typeKey = 'int';
            } else if (value is double) {
              typeKey = 'double';
            } else if (value is bool) {
              typeKey = 'bool';
            } else {
              typeKey = 'dynamic';
            }
            valuesByType.putIfAbsent(typeKey, () => []).add(value);
          }
          
          // Create variants for each type
          final variants = <IrMixedEnumVariant>[];
          valuesByType.forEach((dartType, values) {
            final className = '$enumName${dartType == 'null' ? 'Null' : dartType}';
            variants.add(IrMixedEnumVariant(
              className: className,
              dartType: dartType,
              values: values,
              isNullable: dartType == 'null',
            ));
          });
          
          final spec = _mixedEnums.putIfAbsent(
            enumName,
            () => IrMixedEnum(
              name: enumName,
              description: description,
              variants: variants,
            ),
          );
          _mixedEnumByLocation[cacheKey] = spec;
          
          final ref = MixedEnumTypeRef(spec);
          _typeCache[cacheKey] = ref;
          return ref;
        }
      }

      final unionKeyword = workingSchema.containsKey('oneOf')
          ? 'oneOf'
          : workingSchema.containsKey('anyOf')
          ? 'anyOf'
          : null;
      if (unionKeyword != null) {
        final members = workingSchema[unionKeyword];
        if (members is List && members.isNotEmpty) {
          final constraintBranches = _extractConstraintOnlyUnion(
            location,
            members.cast<dynamic>(),
            unionKeyword,
          );
          if (constraintBranches != null && constraintBranches.isNotEmpty) {
            final unionPointer = _pointerChild(location.pointer, unionKeyword);
            pendingConstraints.add(
              ConditionalConstraint(
                keyword: unionKeyword,
                schemaPointer: unionPointer,
                branches: constraintBranches,
              ),
            );
          } else {
            final ref = _resolveUnion(
              workingSchema,
              location,
              members.cast<dynamic>(),
              unionKeyword,
              suggestedClassName: suggestedClassName,
              dialect: activeDialect,
            );
            _typeCache[cacheKey] = ref;
            return ref;
          }
        }
      }

      final constValue = workingSchema['const'];
      if (constValue is String) {
        const ref = PrimitiveTypeRef('String');
        _typeCache[cacheKey] = ref;
        return ref;
      }
      if (constValue is num) {
        final ref = constValue is int
            ? const PrimitiveTypeRef('int')
            : const PrimitiveTypeRef('double');
        _typeCache[cacheKey] = ref;
        return ref;
      }
      if (constValue is bool) {
        const ref = PrimitiveTypeRef('bool');
        _typeCache[cacheKey] = ref;
        return ref;
      }
      if (workingSchema.containsKey('const') &&
          constValue == null &&
          workingSchema['type'] == 'null') {
        const ref = DynamicTypeRef();
        _typeCache[cacheKey] = ref;
        return ref;
      }

      final type = workingSchema['type'];
      final normalizedType = _normalizeTypeKeyword(type);

      // Treat schema with title (but no type) as an object
      final hasObjectLikeProperties = workingSchema.containsKey('properties') ||
          workingSchema.containsKey('patternProperties') ||
          workingSchema.containsKey('additionalProperties') ||
          workingSchema.containsKey('required') ||
          workingSchema.containsKey('dependentRequired') ||
          workingSchema.containsKey('dependentSchemas');
      
      final shouldBeObject = normalizedType == 'object' ||
          hasObjectLikeProperties ||
          (workingSchema.containsKey('title') && normalizedType == null && !workingSchema.containsKey('enum'));

      if (shouldBeObject) {
        final className = _allocateClassName(
          workingSchema['title'] as String? ??
              suggestedClassName ??
              _nameFromPointer(location.pointer),
        );
        final spec = _classes.putIfAbsent(className, () {
          final objSpec = IrClass(
            name: className,
            description: workingSchema['description'] as String?,
            properties: [],
            conditionals: JsonConditionals(
              ifSchema: workingSchema['if'] as Map<String, dynamic>?,
              thenSchema: workingSchema['then'] as Map<String, dynamic>?,
              elseSchema: workingSchema['else'] as Map<String, dynamic>?,
            ),
            dependentRequired: <String, Set<String>>{},
            dependentSchemas: <String, DependentSchemaConstraint>{},
            extensionAnnotations: _extractExtensionAnnotations(workingSchema),
          );
          final locationKey = _SchemaCacheKey(location.uri, location.pointer);
          _classByLocation[locationKey] = objSpec;
          _typeCache[cacheKey] = ObjectTypeRef(objSpec);
          _populateObjectSpec(objSpec, workingSchema, location, activeDialect);
          if (pendingConstraints.isNotEmpty) {
            final existingPointers = objSpec.conditionalConstraints
                .map((constraint) => constraint.schemaPointer)
                .toSet();
            for (final constraint in pendingConstraints) {
              if (existingPointers.add(constraint.schemaPointer)) {
                objSpec.conditionalConstraints.add(constraint);
              }
            }
          }
          return objSpec;
        });

        final ref = ObjectTypeRef(spec);
        if (pendingConstraints.isNotEmpty) {
          final existingPointers = spec.conditionalConstraints
              .map((c) => c.schemaPointer)
              .toSet();
          for (final constraint in pendingConstraints) {
            if (existingPointers.add(constraint.schemaPointer)) {
              spec.conditionalConstraints.add(constraint);
            }
          }
        }
        _typeCache[cacheKey] = ref;
        return ref;
      }

      if (normalizedType == 'string') {
        final format = workingSchema['format'] as String?;
        final hint = _lookupFormatHint(format);
        if (hint != null && _options.enableFormatHints) {
          if (hint.helper != null) {
            _helpers.putIfAbsent(hint.helper!.name, () => hint.helper!);
          }
          final ref = FormatTypeRef(
            format: hint.name,
            typeName: hint.typeName,
            deserialize: hint.deserialize,
            serialize: hint.serialize,
            helperTypeName: hint.helper?.name,
          );
          _typeCache[cacheKey] = ref;
          return ref;
        }
      }

      if (normalizedType == 'array') {
        final prefixItemsRaw = workingSchema['prefixItems'];
        final prefixPointer = _pointerChild(location.pointer, 'prefixItems');
        final prefixItemTypes = <TypeRef>[];
        if (prefixItemsRaw is List) {
          for (var index = 0; index < prefixItemsRaw.length; index++) {
            final element = prefixItemsRaw[index];
            final elementPointer = _pointerChild(prefixPointer, '$index');
            final pointerLocation = _SchemaLocation(
              uri: location.uri,
              pointer: elementPointer,
            );
            if (element is Map<String, dynamic>) {
              final nameSuffix = suggestedClassName != null
                  ? '${suggestedClassName}Prefix$index'
                  : null;
              prefixItemTypes.add(
                _resolveSchema(
                  element,
                  pointerLocation,
                  suggestedClassName: nameSuffix,
                  dialect: activeDialect,
                ),
              );
            } else if (element == true) {
              prefixItemTypes.add(const DynamicTypeRef());
            } else if (element == false) {
              prefixItemTypes.add(const DynamicTypeRef());
            } else {
              prefixItemTypes.add(const DynamicTypeRef());
            }
          }
        } else if (prefixItemsRaw != null && prefixItemsRaw is! List) {
          _schemaError(
            'Expected "prefixItems" to be an array of schemas',
            _SchemaLocation(uri: location.uri, pointer: prefixPointer),
          );
        }

        final items = workingSchema['items'];
        var allowAdditionalItems = true;
        var itemsEvaluatesAdditionalItems = false;
        TypeRef itemType = const DynamicTypeRef();
        if (items is Map<String, dynamic>) {
          String? itemClassName;
          if (suggestedClassName != null) {
            itemClassName = _elementClassName(suggestedClassName);
          }
          final itemPointer = _pointerChild(location.pointer, 'items');
          itemType = _resolveSchema(
            items,
            _SchemaLocation(uri: location.uri, pointer: itemPointer),
            suggestedClassName: itemClassName,
            dialect: activeDialect,
          );
          itemsEvaluatesAdditionalItems = true;
        } else if (items is bool) {
          if (!items) {
            allowAdditionalItems = false;
          } else {
            itemsEvaluatesAdditionalItems = true;
          }
        } else if (items is List && prefixItemTypes.isEmpty) {
          final legacyPointer = _pointerChild(location.pointer, 'items');
          for (var index = 0; index < items.length; index++) {
            final element = items[index];
            final elementPointer = _pointerChild(legacyPointer, '$index');
            final pointerLocation = _SchemaLocation(
              uri: location.uri,
              pointer: elementPointer,
            );
            if (element is Map<String, dynamic>) {
              prefixItemTypes.add(
                _resolveSchema(
                  element,
                  pointerLocation,
                  suggestedClassName: suggestedClassName != null
                      ? '${suggestedClassName}Item$index'
                      : null,
                  dialect: activeDialect,
                ),
              );
            } else if (element == true) {
              prefixItemTypes.add(const DynamicTypeRef());
            } else if (element == false) {
              prefixItemTypes.add(const DynamicTypeRef());
            } else {
              prefixItemTypes.add(const DynamicTypeRef());
            }
          }
        }

        TypeRef? containsType;
        final containsRaw = workingSchema['contains'];
        final containsPointer = _pointerChild(location.pointer, 'contains');
        if (containsRaw is Map<String, dynamic>) {
          String? containsClassName;
          if (suggestedClassName != null) {
            containsClassName = _elementClassName(suggestedClassName);
          }
          containsType = _resolveSchema(
            containsRaw,
            _SchemaLocation(uri: location.uri, pointer: containsPointer),
            suggestedClassName: suggestedClassName != null
                ? containsClassName
                : null,
            dialect: activeDialect,
          );
        } else if (containsRaw != null && containsRaw is! Map) {
          _schemaError(
            'Expected "contains" to be a schema object',
            _SchemaLocation(uri: location.uri, pointer: containsPointer),
          );
        }

        int? minContains;
        final minContainsRaw = workingSchema['minContains'];
        final minContainsPointer = _pointerChild(
          location.pointer,
          'minContains',
        );
        if (minContainsRaw is int) {
          minContains = minContainsRaw;
        } else if (minContainsRaw != null) {
          _schemaError(
            '"minContains" must be an integer',
            _SchemaLocation(uri: location.uri, pointer: minContainsPointer),
          );
        }
        if (containsType != null && minContains == null) {
          minContains = 1;
        }

        int? maxContains;
        final maxContainsRaw = workingSchema['maxContains'];
        final maxContainsPointer = _pointerChild(
          location.pointer,
          'maxContains',
        );
        if (maxContainsRaw is int) {
          maxContains = maxContainsRaw;
        } else if (maxContainsRaw != null) {
          _schemaError(
            '"maxContains" must be an integer',
            _SchemaLocation(uri: location.uri, pointer: maxContainsPointer),
          );
        }

        TypeRef? unevaluatedItemsType;
        var disallowUnevaluatedItems = false;
        final unevaluatedRaw = workingSchema['unevaluatedItems'];
        final unevaluatedPointer = _pointerChild(
          location.pointer,
          'unevaluatedItems',
        );
        if (unevaluatedRaw is bool) {
          if (!unevaluatedRaw) {
            disallowUnevaluatedItems = true;
          }
        } else if (unevaluatedRaw is Map<String, dynamic>) {
          unevaluatedItemsType = _resolveSchema(
            unevaluatedRaw,
            _SchemaLocation(uri: location.uri, pointer: unevaluatedPointer),
            suggestedClassName: suggestedClassName != null
                ? '${suggestedClassName}UnevaluatedItem'
                : null,
            dialect: activeDialect,
          );
        } else if (unevaluatedRaw != null) {
          _schemaError(
            'Expected "unevaluatedItems" to be a boolean or schema object',
            _SchemaLocation(uri: location.uri, pointer: unevaluatedPointer),
          );
        }

        final ref = ListTypeRef(
          itemType: itemType is DynamicTypeRef && containsType != null
              ? containsType
              : itemType,
          prefixItemTypes: prefixItemTypes,
          containsType: containsType,
          minContains: minContains,
          maxContains: maxContains,
          unevaluatedItemsType: unevaluatedItemsType,
          disallowUnevaluatedItems: disallowUnevaluatedItems,
          allowAdditionalItems: allowAdditionalItems,
          itemsEvaluatesAdditionalItems: itemsEvaluatesAdditionalItems,
        );
        _typeCache[cacheKey] = ref;
        return ref;
      }

      final primitive = _primitiveFromType(normalizedType);
      _typeCache[cacheKey] = primitive;
      return primitive;
    } finally {
      _inProgress.remove(cacheKey);
      if (pushedDynamicAnchor) {
        _dynamicScope.removeLast();
      }
    }
  }

  bool _isNullableComposition(Map<String, dynamic> schema) {
    // Check anyOf for null type
    if (schema['anyOf'] is List) {
      final anyOf = schema['anyOf'] as List;
      for (final member in anyOf) {
        if (member is Map<String, dynamic> && member['type'] == 'null') {
          return true;
        }
      }
    }
    // Check oneOf for null type
    if (schema['oneOf'] is List) {
      final oneOf = schema['oneOf'] as List;
      for (final member in oneOf) {
        if (member is Map<String, dynamic> && member['type'] == 'null') {
          return true;
        }
      }
    }
    return false;
  }

  TypeRef _resolveUnion(
    Map<String, dynamic> schema,
    _SchemaLocation location,
    List<dynamic> members,
    String keyword, {
    String? suggestedClassName,
    required SchemaDialect dialect,
  }) {
    final unionPointer = _pointerChild(location.pointer, keyword);
    final resolvedMembers = <_ResolvedSchema>[];
    var hasNullType = false;

    for (var index = 0; index < members.length; index++) {
      final memberPointer = _pointerChild(unionPointer, '$index');
      final memberLocation = _SchemaLocation(
        uri: location.uri,
        pointer: memberPointer,
      );
      final member = members[index];
      if (member is Map<String, dynamic>) {
        // Check if this member is a null type
        if (member['type'] == 'null') {
          hasNullType = true;
          continue; // Skip null types from union processing
        }
        if (member case {'\$ref': final String refValue}) {
          resolvedMembers.add(_resolveReference(refValue, memberLocation));
        } else {
          resolvedMembers.add(
            _ResolvedSchema(schema: member, location: memberLocation),
          );
        }
      } else {
        throw ArgumentError.value(
          member,
          '$keyword/$index',
          'Union variants must be valid JSON Schema objects',
        );
      }
    }

    // If all members were null, or only one non-null member remains
    if (resolvedMembers.isEmpty) {
      return const DynamicTypeRef();
    }
    
    if (resolvedMembers.length == 1 && hasNullType) {
      // Single type + null = nullable version of that type
      final resolved = resolvedMembers.first;
      final variantName = _unionVariantSuggestion(
        schema['title'] as String? ??
            suggestedClassName ??
            _nameFromPointer(location.pointer),
        resolved.schema,
        resolved.location,
        0,
      );
      final typeRef = _resolveSchema(
        resolved.schema,
        resolved.location,
        suggestedClassName: variantName,
        dialect: dialect,
      );
      // Return a nullable wrapper or mark as nullable somehow
      // For now, we'll return the type as-is and let the property handling deal with it
      return typeRef;
    }

    final variantTypes = <TypeRef>[];
    var allObjects = true;
    for (var index = 0; index < resolvedMembers.length; index++) {
      final resolved = resolvedMembers[index];
      final originalMember = members[index];
      final variantName = _unionVariantSuggestion(
        schema['title'] as String? ??
            suggestedClassName ??
            _nameFromPointer(location.pointer),
        resolved.schema,
        resolved.location,
        index,
      );
      final variantKey = _SchemaCacheKey(
        resolved.location.uri,
        resolved.location.pointer,
      );
      TypeRef typeRef;
      final cachedRef = _typeCache[variantKey];
      if (cachedRef != null) {
        typeRef = cachedRef;
      } else if (_classByLocation.containsKey(variantKey)) {
        typeRef = ObjectTypeRef(_classByLocation[variantKey]!);
        _typeCache[variantKey] = typeRef;
      } else if (_enumByLocation.containsKey(variantKey)) {
        typeRef = EnumTypeRef(_enumByLocation[variantKey]!);
        _typeCache[variantKey] = typeRef;
      } else {
        final bool isReference =
            originalMember is Map<String, dynamic> &&
            originalMember.containsKey('\$ref');
        final childDialect = isReference
            ? _documentDialect(resolved.location.uri)
            : dialect;
        typeRef = _resolveSchema(
          resolved.schema,
          resolved.location,
          suggestedClassName: variantName,
          dialect: childDialect,
        );
      }
      variantTypes.add(typeRef);
      if (typeRef is! ObjectTypeRef) {
        allObjects = false;
      }
    }

    final cacheKey = _SchemaCacheKey(location.uri, location.pointer);
    if (!allObjects) {
      final first = variantTypes.first;
      final same = variantTypes.every(
        (type) => type.identity == first.identity,
      );
      final fallback = same ? first : const DynamicTypeRef();
      _typeCache[cacheKey] = fallback;
      return fallback;
    }

    final className = _allocateClassName(
      schema['title'] as String? ??
          suggestedClassName ??
          _nameFromPointer(location.pointer),
    );

    final baseClass = _classes.putIfAbsent(className, () {
      final unionClass = IrClass(
        name: className,
        description: schema['description'] as String?,
        properties: [],
        conditionals: JsonConditionals(
          ifSchema: schema['if'] as Map<String, dynamic>?,
          thenSchema: schema['then'] as Map<String, dynamic>?,
          elseSchema: schema['else'] as Map<String, dynamic>?,
        ),
        dependentRequired: <String, Set<String>>{},
        dependentSchemas: <String, DependentSchemaConstraint>{},
        extensionAnnotations: _extractExtensionAnnotations(schema),
      );
      return unionClass;
    });

    final ref = ObjectTypeRef(baseClass);
    _typeCache[cacheKey] = ref;

    final variants = <IrUnionVariant>[];
    for (var index = 0; index < variantTypes.length; index++) {
      final resolved = resolvedMembers[index];
      final typeRef = variantTypes[index];
      if (typeRef is! ObjectTypeRef) {
        continue;
      }
      final spec = typeRef.spec;
      spec.superClassName ??= baseClass.name;
      final requiredProperties = _requiredPropertiesFromSchema(resolved.schema);
      final constProperties = _constPropertiesFromSchema(resolved.schema);
      variants.add(
        IrUnionVariant(
          schemaPointer: resolved.location.pointer,
          classSpec: typeRef.spec,
          discriminatorValue: null,
          requiredProperties: requiredProperties,
          constProperties: constProperties,
        ),
      );
    }

    final discriminator = _extractDiscriminator(schema);
    final linkedVariants = _applyDiscriminatorMapping(variants, discriminator);

    _unions.add(
      IrUnion(
        name: className,
        baseClass: baseClass,
        variants: linkedVariants,
        keyword: keyword,
        discriminator: discriminator,
      ),
    );

    return ref;
  }

  void _processDefinitions(
    Map<String, dynamic> schema,
    _SchemaLocation location,
    SchemaDialect dialect,
  ) {
    final definitions = schema['definitions'];
    if (definitions is Map<String, dynamic>) {
      for (final entry in definitions.entries) {
        final key = entry.key;
        final value = entry.value;
        if (value is Map<String, dynamic>) {
          final pointer = _pointerChild(
            _pointerChild(location.pointer, 'definitions'),
            key,
          );
          _resolveSchema(
            value,
            _SchemaLocation(uri: location.uri, pointer: pointer),
            suggestedClassName: key,
            dialect: dialect,
          );
        }
      }
    }

    final defs = schema[r'$defs'];
    if (defs is Map<String, dynamic>) {
      for (final entry in defs.entries) {
        final key = entry.key;
        final value = entry.value;
        if (value is Map<String, dynamic>) {
          final pointer = _pointerChild(
            _pointerChild(location.pointer, r'$defs'),
            key,
          );
          _resolveSchema(
            value,
            _SchemaLocation(uri: location.uri, pointer: pointer),
            suggestedClassName: key,
            dialect: dialect,
          );
        }
      }
    }
  }

  SchemaDialect _detectDocumentDialect(Uri uri, Map<String, dynamic> document) {
    return _dialectForSchema(
      document,
      _SchemaLocation(uri: uri, pointer: '#'),
      _options.defaultDialect,
    );
  }

  SchemaDialect _dialectForSchema(
    Map<String, dynamic> schema,
    _SchemaLocation location,
    SchemaDialect? inherited,
  ) {
    final Object? declared = schema['\$schema'];
    SchemaDialect? active = inherited;
    if (declared != null) {
      if (declared is! String) {
        _schemaError('Expected "\$schema" to be a string', location);
      }
      final resolvedDialect = SchemaDialect.lookup(
        declared,
        _options.supportedDialects,
      );
      if (resolvedDialect == null) {
        final supported = _options.supportedDialects.keys.join(', ');
        _schemaError(
          'Unsupported JSON Schema dialect "$declared". '
          'Supported dialects: $supported',
          location,
        );
      }
      active = resolvedDialect;
    }
    if (active == null) {
      _schemaError(
        'No JSON Schema dialect declared and no default dialect configured.',
        location,
      );
    }
    _validateVocabulary(schema, active, location);
    return active;
  }

  Uri _resolveIdentifierUri(
    String value,
    Uri baseUri,
    _SchemaLocation location,
  ) {
    Uri parsed;
    try {
      parsed = Uri.parse(value);
    } on FormatException {
      _schemaError('Invalid "\$id" "$value"', location);
    }
    final resolved = baseUri.resolveUri(parsed);
    _log(
      'Resolving id $value from ${_describeLocation(location)} with base $baseUri -> $resolved (abs=${resolved.hasScheme && resolved.scheme.isNotEmpty}, fragment=${resolved.hasFragment})',
    );
    if (!resolved.hasScheme || resolved.scheme.isEmpty) {
      _schemaError('"\$id" must resolve to an absolute IRI', location);
    }
    if (resolved.hasFragment) {
      _schemaError(
        '"\$id" must not include a fragment. Use "\$anchor" instead.',
        location,
      );
    }
    return resolved;
  }

  void _registerAnchor(Uri documentUri, String anchor, _SchemaLocation where) {
    final map = _anchorsByDocument.putIfAbsent(
      documentUri,
      () => <String, _SchemaLocation>{},
    );
    final existing = map[anchor];
    if (existing != null) {
      if (existing.uri == where.uri && existing.pointer == where.pointer) {
        return;
      }
      _schemaError(
        'Duplicate "\$anchor" "$anchor" already defined at ${_describeLocation(existing)}.',
        where,
      );
    }
    map[anchor] = where;
    _log('Registered anchor $anchor at ${_describeLocation(where)}');
  }

  void _registerDynamicAnchor(
    Uri documentUri,
    String anchor,
    _SchemaLocation where,
  ) {
    final map = _dynamicAnchorsByDocument.putIfAbsent(
      documentUri,
      () => <String, _SchemaLocation>{},
    );
    final existing = map[anchor];
    if (existing != null) {
      if (existing.uri == where.uri && existing.pointer == where.pointer) {
        return;
      }
      _schemaError(
        'Duplicate "\$dynamicAnchor" "$anchor" already defined at ${_describeLocation(existing)}.',
        where,
      );
    }
    map[anchor] = where;
    _log('Registered dynamic anchor $anchor at ${_describeLocation(where)}');
  }

  void _registerId(Uri uri, _SchemaLocation origin) {
    final key = uri.toString();
    final existing = _idOrigins[key];
    if (existing != null) {
      if (existing.uri == origin.uri && existing.pointer == origin.pointer) {
        return;
      }
      _schemaError(
        'Duplicate "\$id" "$key" already defined at ${_describeLocation(existing)}.',
        origin,
      );
    }
    _idOrigins[key] = origin;
    _log('Registered id $key at ${_describeLocation(origin)}');
  }

  _SchemaLocation? _lookupAnchor(Uri documentUri, String anchor) {
    final map = _anchorsByDocument[documentUri];
    if (map != null && map.containsKey(anchor)) {
      return map[anchor];
    }
    final document = _loadDocument(documentUri);
    final refreshed = _anchorsByDocument[documentUri];
    if (refreshed != null) {
      return refreshed[anchor];
    }
    final location = _findAnchor(document, documentUri, anchor);
    if (location != null) {
      return location;
    }
    return null;
  }

  _SchemaLocation? _lookupDynamicAnchor(Uri documentUri, String anchor) {
    final map = _dynamicAnchorsByDocument[documentUri];
    if (map != null && map.containsKey(anchor)) {
      return map[anchor];
    }
    final document = _loadDocument(documentUri);
    final refreshed = _dynamicAnchorsByDocument[documentUri];
    if (refreshed != null && refreshed.containsKey(anchor)) {
      return refreshed[anchor];
    }
    final location = _findDynamicAnchor(document, documentUri, anchor);
    if (location != null) {
      return location;
    }
    return null;
  }

  _SchemaLocation? _findAnchor(
    Map<String, dynamic>? schema,
    Uri baseUri,
    String anchor,
  ) {
    if (schema == null) return null;
    if (schema case {'\$id': final String idValue}) {
      final canonical = _resolveIdentifierUri(
        idValue,
        baseUri,
        _SchemaLocation(uri: baseUri, pointer: '#'),
      );
      if (canonical != baseUri) {
        return _lookupAnchor(canonical, anchor);
      }
    }

    if (schema case {'\$anchor': final String value} when value == anchor) {
      final location = _SchemaLocation(uri: baseUri, pointer: '#');
      _registerAnchor(baseUri, anchor, location);
      return location;
    }

    for (final entry in schema.entries) {
      final value = entry.value;
      if (value is Map<String, dynamic>) {
        final childPointer = _pointerChild('#', entry.key);
        final result = _findAnchor(value, baseUri, anchor);
        if (result != null) {
          return _SchemaLocation(uri: result.uri, pointer: childPointer);
        }
      } else if (value is List) {
        for (var i = 0; i < value.length; i++) {
          final element = value[i];
          if (element is Map<String, dynamic>) {
            final childPointer = _pointerChild(
              _pointerChild('#', entry.key),
              '$i',
            );
            final result = _findAnchor(element, baseUri, anchor);
            if (result != null) {
              return _SchemaLocation(uri: result.uri, pointer: childPointer);
            }
          }
        }
      }
    }
    return null;
  }

  _SchemaLocation? _findDynamicAnchor(
    Map<String, dynamic>? schema,
    Uri baseUri,
    String anchor,
  ) {
    if (schema == null) return null;
    if (schema case {'\$id': final String idValue}) {
      final canonical = _resolveIdentifierUri(
        idValue,
        baseUri,
        _SchemaLocation(uri: baseUri, pointer: '#'),
      );
      if (canonical != baseUri) {
        return _lookupDynamicAnchor(canonical, anchor);
      }
    }

    if (schema case {
      '\$dynamicAnchor': final String value,
    } when value == anchor) {
      final location = _SchemaLocation(uri: baseUri, pointer: '#');
      _registerDynamicAnchor(baseUri, anchor, location);
      return location;
    }

    for (final entry in schema.entries) {
      final value = entry.value;
      if (value is Map<String, dynamic>) {
        final childPointer = _pointerChild('#', entry.key);
        final result = _findDynamicAnchor(value, baseUri, anchor);
        if (result != null) {
          return _SchemaLocation(uri: result.uri, pointer: childPointer);
        }
      } else if (value is List) {
        for (var i = 0; i < value.length; i++) {
          final element = value[i];
          if (element is Map<String, dynamic>) {
            final childPointer = _pointerChild(
              _pointerChild('#', entry.key),
              '$i',
            );
            final result = _findDynamicAnchor(element, baseUri, anchor);
            if (result != null) {
              return _SchemaLocation(uri: result.uri, pointer: childPointer);
            }
          }
        }
      }
    }
    return null;
  }

  void _validateVocabulary(
    Map<String, dynamic> schema,
    SchemaDialect dialect,
    _SchemaLocation location,
  ) {
    final Object? vocab = schema['\$vocabulary'];
    if (vocab == null) {
      for (final entry in dialect.defaultVocabularies.entries) {
        if (entry.value && !dialect.supportsVocabulary(entry.key)) {
          _schemaError(
            'Dialect ${dialect.uri} requires vocabulary ${entry.key}, '
            'which is not supported by this generator.',
            location,
          );
        }
      }
      return;
    }
    if (vocab is! Map<String, dynamic>) {
      _schemaError('Expected "\$vocabulary" to be an object', location);
    }
    for (final entry in vocab.entries) {
      final value = entry.value;
      if (value is! bool) {
        _schemaError('Expected "\$vocabulary" values to be booleans', location);
      }
      if (value && !dialect.supportsVocabulary(entry.key)) {
        _schemaError(
          'Vocabulary ${entry.key} is required but not supported.',
          location,
        );
      }
    }
  }

  SchemaDialect _documentDialect(Uri uri) {
    final dialect = _documentDialects[uri];
    if (dialect != null) {
      return dialect;
    }
    if (_options.defaultDialect == null) {
      _schemaError(
        'No JSON Schema dialect declared and no default dialect configured.',
        _SchemaLocation(uri: uri, pointer: '#'),
      );
    }
    return _options.defaultDialect!;
  }

  Never _schemaError(String message, _SchemaLocation location) {
    final pointer = location.pointer == '#' ? '' : location.pointer;
    final where = '${location.uri}$pointer';
    throw FormatException('$message (at $where)');
  }

  Map<String, dynamic> _mergeAllOfSchemas(
    Map<String, dynamic> schema,
    _SchemaLocation location,
  ) {
    String? mergedDescription = schema['description'] as String?;
    final mergedRequired = <String>{};
    final mergedProperties = <String, Map<String, dynamic>>{};
    final propertyPointers = <String, String>{};
    var isObject =
        _normalizeTypeKeyword(schema['type']) == 'object' ||
        schema['properties'] is Map<String, dynamic>;

    void mergeFrom(
      Map<String, dynamic>? source,
      _SchemaLocation sourceLocation,
    ) {
      if (source == null) return;
      final effective = source.containsKey('allOf')
          ? _mergeAllOfSchemas(source, sourceLocation)
          : source;

      if (mergedDescription == null && effective['description'] is String) {
        mergedDescription = effective['description'] as String?;
      }

      if (_normalizeTypeKeyword(effective['type']) == 'object' ||
          effective['properties'] is Map<String, dynamic>) {
        isObject = true;
      }

      final required = effective['required'];
      if (required is List) {
        mergedRequired.addAll(required.whereType<String>());
      }

      final properties = effective['properties'];
      if (properties is! Map<String, dynamic>) {
        return;
      }

      for (final entry in properties.entries) {
        final key = entry.key;
        final propertyPointer = _pointerChild(
          _pointerChild(sourceLocation.pointer, 'properties'),
          key,
        );
        final propertyMap = entry.value;
        if (propertyMap is! Map<String, dynamic>) {
          continue;
        }

        final existing = mergedProperties[key];
        if (existing != null) {
          _assertCompatibleProperty(
            key,
            existing,
            propertyPointers[key]!,
            propertyMap,
            propertyPointer,
          );
          mergedProperties[key] = _mergePropertyAnnotations(
            existing,
            propertyMap,
          );
        } else {
          mergedProperties[key] = Map<String, dynamic>.from(propertyMap);
          propertyPointers[key] = propertyPointer;
        }
      }
    }

    mergeFrom(Map<String, dynamic>.from(schema)..remove('allOf'), location);

    final allOf = schema['allOf'];
    if (allOf is List) {
      for (var index = 0; index < allOf.length; index++) {
        final entry = allOf[index];
        if (entry is! Map<String, dynamic>) {
          continue;
        }
        final entryPointer = _pointerChild(
          _pointerChild(location.pointer, 'allOf'),
          '$index',
        );
        var entryLocation = _SchemaLocation(
          uri: location.uri,
          pointer: entryPointer,
        );
        Map<String, dynamic>? entrySchema = entry;
        if (entry case {'\$ref': final String refValue}) {
          final resolved = _resolveReference(refValue, entryLocation);
          entrySchema = resolved.schema;
          entryLocation = resolved.location;
        }
        mergeFrom(entrySchema, entryLocation);
      }
    }

    final result = <String, dynamic>{
      if (isObject) 'type': 'object',
      if (mergedDescription != null) 'description': mergedDescription,
      if (mergedProperties.isNotEmpty) 'properties': mergedProperties,
      if (mergedRequired.isNotEmpty)
        'required': mergedRequired.toList(growable: false),
    };

    for (final entry in schema.entries) {
      if (entry.key == 'allOf' ||
          entry.key == 'properties' ||
          entry.key == 'required' ||
          entry.key == 'type' ||
          (entry.key == 'description' && mergedDescription != null)) {
        continue;
      }
      result[entry.key] = entry.value;
    }

    return result;
  }

  void _populateObjectSpec(
    IrClass spec,
    Map<String, dynamic> schema,
    _SchemaLocation location,
    SchemaDialect dialect,
  ) {
    final properties = schema['properties'];
    final requiredSet = switch (schema['required']) {
      List list => list.whereType<String>().toSet(),
      _ => const <String>{},
    };

    final usedFieldNames = <String>{};

    if (properties is Map<String, dynamic>) {
      final sortedEntries = properties.entries.toList()
        ..sort((a, b) {
          final orderA = _propertyOrder(a.value);
          final orderB = _propertyOrder(b.value);
          if (orderA != null && orderB != null) {
            final compare = orderA.compareTo(orderB);
            if (compare != 0) return compare;
          } else if (orderA != null) {
            return -1;
          } else if (orderB != null) {
            return 1;
          }
          return a.key.compareTo(b.key);
        });

      for (final entry in sortedEntries) {
        final key = entry.key;
        final propertySchema = entry.value;
        final propertyPointer = _pointerChild(
          _pointerChild(location.pointer, 'properties'),
          key,
        );
        final propertyMap = propertySchema is Map<String, dynamic>
            ? propertySchema
            : null;

        final suggestedName = '${spec.name}_$key';
        var propertyType = _resolveSchema(
          propertySchema,
          _SchemaLocation(uri: location.uri, pointer: propertyPointer),
          suggestedClassName: suggestedName,
          dialect: dialect,
        );

        // Override type if content encoding is present
        if (_options.enableContentKeywords &&
            propertyMap?['contentEncoding'] is String &&
            propertyType is PrimitiveTypeRef &&
            propertyType.typeName == 'String') {
          final encoding = propertyMap!['contentEncoding'] as String;
          // Supported encodings: base64, base16, base32, quoted-printable
          if (['base64', 'base16', 'base32', 'quoted-printable']
              .contains(encoding)) {
            propertyType = ContentEncodedTypeRef(encoding);
          }
        }

        // Check if property schema has nullable anyOf/oneOf
        var schemaIsNullable = false;
        if (propertyMap != null) {
          schemaIsNullable = _isNullableComposition(propertyMap);
        }
        
        final isRequired = requiredSet.contains(key) && !schemaIsNullable;
        final fieldName = _options.preferCamelCase
            ? _Naming.fieldName(key)
            : _Naming.identifier(key);
        usedFieldNames.add(fieldName);

        final format = propertyMap?['format'] as String?;
        final hint = _lookupFormatHint(format);
        final formatInfo = format != null ? _formatRegistry[format] : null;
        final deprecated = propertyMap?['deprecated'] == true;
        final defaultValue = propertyMap?['default'];
        final examples = propertyMap?['examples'] is List
            ? (propertyMap?['examples'] as List).cast<Object?>()
            : const <Object?>[];
        final description = _composePropertyDescription(
          description: propertyMap?['description'] as String?,
          format: format,
          formatInfo: formatInfo,
          hintAvailable: hint != null,
          convertedFormat: propertyType is FormatTypeRef,
          deprecated: deprecated,
          defaultValue: defaultValue,
          examples: examples,
        );
        final validation = _extractValidationRules(propertyMap);

        final extensionAnnotations = propertyMap != null
            ? _extractExtensionAnnotations(propertyMap)
            : <String, Object?>{};

        // Extract content keywords if enabled
        final contentMediaType = _options.enableContentKeywords
            ? (propertyMap?['contentMediaType'] as String?)
            : null;
        final contentEncoding = _options.enableContentKeywords
            ? (propertyMap?['contentEncoding'] as String?)
            : null;
        final contentSchema = (_options.enableContentKeywords &&
                propertyMap?['contentSchema'] is Map)
            ? (propertyMap?['contentSchema'] as Map<String, dynamic>?)
            : null;
        
        final readOnly = propertyMap?['readOnly'] == true;
        final writeOnly = propertyMap?['writeOnly'] == true;

        final prop = IrProperty(
          jsonName: key,
          fieldName: fieldName,
          typeRef: propertyType,
          isRequired: isRequired,
          schemaPointer: propertyPointer,
          description: description,
          title: propertyMap?['title'] as String?,
          format: format,
          validation: validation,
          isDeprecated: deprecated,
          defaultValue: defaultValue,
          examples: examples,
          contentMediaType: contentMediaType,
          contentEncoding: contentEncoding,
          contentSchema: contentSchema,
          isReadOnly: readOnly,
          isWriteOnly: writeOnly,
          extensionAnnotations: extensionAnnotations,
        );
        spec.properties.add(prop);
      }
    }

    spec.dependentRequired.clear();
    final dependentRequiredRaw = schema['dependentRequired'];
    if (dependentRequiredRaw is Map) {
      for (final entry in dependentRequiredRaw.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is! String) {
          continue;
        }
        if (value is List) {
          final set = value.whereType<String>().toSet();
          if (set.isNotEmpty) {
            spec.dependentRequired[key] = set;
          }
        } else {
          final pointer = _pointerChild(
            _pointerChild(location.pointer, 'dependentRequired'),
            key,
          );
          _schemaError(
            'Expected dependentRequired entries to be arrays of strings',
            _SchemaLocation(uri: location.uri, pointer: pointer),
          );
        }
      }
    } else if (dependentRequiredRaw != null) {
      _schemaError(
        'Expected "dependentRequired" to be an object',
        _SchemaLocation(
          uri: location.uri,
          pointer: _pointerChild(location.pointer, 'dependentRequired'),
        ),
      );
    }

    spec.dependentSchemas.clear();
    final dependentSchemasRaw = schema['dependentSchemas'];
    if (dependentSchemasRaw is Map) {
      for (final entry in dependentSchemasRaw.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is! String) {
          continue;
        }
        final schemaPointer = _pointerChild(
          _pointerChild(location.pointer, 'dependentSchemas'),
          key,
        );
        if (value == true) {
          continue;
        }
        if (value == false) {
          spec.dependentSchemas[key] = DependentSchemaConstraint(
            property: key,
            schemaPointer: schemaPointer,
            disallow: true,
          );
          continue;
        }
        if (value is Map<String, dynamic>) {
          final typeRef = _resolveSchema(
            value,
            _SchemaLocation(uri: location.uri, pointer: schemaPointer),
            suggestedClassName:
                '${spec.name}${_Naming.className(key)}Dependency',
            dialect: dialect,
          );
          spec.dependentSchemas[key] = DependentSchemaConstraint(
            property: key,
            schemaPointer: schemaPointer,
            typeRef: typeRef,
          );
          continue;
        }
        _schemaError(
          'Expected dependentSchemas entries to be boolean or schema objects',
          _SchemaLocation(uri: location.uri, pointer: schemaPointer),
        );
      }
    } else if (dependentSchemasRaw != null) {
      _schemaError(
        'Expected "dependentSchemas" to be an object',
        _SchemaLocation(
          uri: location.uri,
          pointer: _pointerChild(location.pointer, 'dependentSchemas'),
        ),
      );
    }

    spec.additionalPropertiesField = _buildAdditionalPropertiesField(
      spec,
      schema,
      location,
      usedFieldNames,
      dialect,
    );
    final patternField = _buildPatternPropertiesField(
      spec,
      schema,
      location,
      usedFieldNames,
      dialect,
    );
    if (patternField != null) {
      spec.patternPropertiesField = patternField;
    }

    _applyUnevaluatedProperties(
      spec,
      schema,
      location,
      dialect,
      usedFieldNames,
    );

    final propertyNamesConstraint = _buildPropertyNamesConstraint(
      schema,
      location,
    );
    if (propertyNamesConstraint != null) {
      spec.propertyNamesConstraint = propertyNamesConstraint;
    }
  }

  String _allocateClassName(String candidate) {
    final base = _Naming.className(
      candidate.isEmpty ? 'GeneratedClass' : candidate,
    );
    var unique = base;
    var counter = 2;
    while (_usedClassNames.contains(unique)) {
      unique = '$base$counter';
      counter++;
    }
    _usedClassNames.add(unique);
    return unique;
  }

  String _allocateEnumName(String candidate) {
    final base = _Naming.className(
      candidate.isEmpty ? 'GeneratedEnum' : candidate,
    );
    var unique = base;
    var counter = 2;
    while (_usedEnumNames.contains(unique)) {
      unique = '$base$counter';
      counter++;
    }
    _usedEnumNames.add(unique);
    return unique;
  }

  static String _pointerChild(String parent, String segment) {
    if (parent == '#') {
      return '#/${_escapePointerToken(segment)}';
    }
    return '$parent/${_escapePointerToken(segment)}';
  }

  static String _escapePointerToken(String value) =>
      value.replaceAll('~', '~0').replaceAll('/', '~1');

  static String _unescapePointerToken(String value) =>
      value.replaceAll('~1', '/').replaceAll('~0', '~');

  static String _normalizePointer(String ref) {
    if (ref == '#') return ref;
    if (!ref.startsWith('#/')) return '#';
    final segments = ref.substring(2).split('/');
    final normalized = segments.map(_unescapePointerToken).join('/');
    return '#/$normalized';
  }

  static String _nameFromPointer(String pointer) {
    if (pointer == '#') {
      return 'RootSchema';
    }
    final segments = pointer
        .substring(2)
        .split('/')
        .map(_unescapePointerToken)
        .toList();
    final relevant = segments.lastWhereOrNull((segment) {
      // Filter out structural keywords
      if (segment == 'properties' ||
          segment == r'$defs' ||
          segment == 'definitions' ||
          segment == 'items') {
        return false;
      }
      // Filter out union keywords (oneOf, anyOf, allOf)
      if (segment == 'oneOf' || segment == 'anyOf' || segment == 'allOf') {
        return false;
      }
      // Filter out numeric array indices
      if (int.tryParse(segment) != null) {
        return false;
      }
      return true;
    });
    return relevant ?? 'Generated';
  }

  /// Extracts x-* extension annotations from a schema object.
  /// Returns a map of extension keywords to their values.
  static Map<String, Object?> _extractExtensionAnnotations(
    Map<String, dynamic> schema,
  ) {
    final extensions = <String, Object?>{};
    for (final entry in schema.entries) {
      if (entry.key.startsWith('x-')) {
        extensions[entry.key] = entry.value;
      }
    }
    return extensions;
  }

  static String? _normalizeTypeKeyword(Object? type) {
    if (type is String && type.isNotEmpty) {
      return type;
    }
    if (type is List) {
      final nonNull = type
          .whereType<String>()
          .where((value) => value != 'null')
          .toList();
      return nonNull.isNotEmpty ? nonNull.first : null;
    }
    return null;
  }

  static PrimitiveTypeRef _primitiveFromType(String? type) {
    switch (type) {
      case 'string':
        return const PrimitiveTypeRef('String');
      case 'integer':
        return const PrimitiveTypeRef('int');
      case 'number':
        return const PrimitiveTypeRef('double');
      case 'boolean':
        return const PrimitiveTypeRef('bool');
      default:
        return const DynamicTypeRef();
    }
  }

  List<ConstraintBranch>? _extractConstraintOnlyUnion(
    _SchemaLocation location,
    List<dynamic> members,
    String keyword,
  ) {
    final pointer = _pointerChild(location.pointer, keyword);
    final branches = <ConstraintBranch>[];
    for (var index = 0; index < members.length; index++) {
      final entry = members[index];
      if (entry is! Map<String, dynamic>) {
        return null;
      }
      if (!_isConstraintOnlySchema(entry)) {
        return null;
      }
      final required = _requiredPropertiesFromSchema(entry);
      if (required.isEmpty) {
        return null;
      }
      final branchPointer = _pointerChild(pointer, '$index');
      branches.add(
        ConstraintBranch(
          schemaPointer: branchPointer,
          requiredProperties: required,
        ),
      );
    }
    return branches;
  }

  bool _isConstraintOnlySchema(Map<String, dynamic> schema) {
    const metadataKeys = <String>{
      'description',
      'title',
      r'$comment',
      'default',
      'deprecated',
      'examples',
    };
    for (final key in schema.keys) {
      if (key == 'required') {
        continue;
      }
      if (metadataKeys.contains(key)) {
        continue;
      }
      return false;
    }
    return true;
  }

  Set<String> _requiredPropertiesFromSchema(Map<String, dynamic>? schema) {
    if (schema == null) {
      return const <String>{};
    }
    final required = schema['required'];
    if (required is List) {
      return required.whereType<String>().toSet();
    }
    return const <String>{};
  }

  Map<String, Object?> _constPropertiesFromSchema(
    Map<String, dynamic>? schema,
  ) {
    if (schema == null) {
      return const <String, Object?>{};
    }
    final properties = schema['properties'];
    if (properties is! Map<String, dynamic>) {
      return const <String, Object?>{};
    }
    final result = <String, Object?>{};
    for (final entry in properties.entries) {
      final value = entry.value;
      if (value case {'const': final Object? constValue}) {
        result[entry.key] = constValue;
      }
    }
    return Map.unmodifiable(result);
  }

  IrDynamicKeyField? _buildAdditionalPropertiesField(
    IrClass spec,
    Map<String, dynamic> schema,
    _SchemaLocation location,
    Set<String> usedFieldNames,
    SchemaDialect dialect,
  ) {
    final additionalRaw = schema['additionalProperties'];
    if (additionalRaw is Map<String, dynamic>) {
      final fieldName = _allocateDynamicFieldName(
        usedFieldNames,
        'additionalProperties',
      );
      final additionalPointer = _pointerChild(
        location.pointer,
        'additionalProperties',
      );
      final typeRef = _resolveSchema(
        additionalRaw,
        _SchemaLocation(uri: location.uri, pointer: additionalPointer),
        suggestedClassName: '${spec.name}AdditionalProperty',
        dialect: dialect,
      );
      return IrDynamicKeyField(
        fieldName: fieldName,
        valueType: typeRef,
        description: additionalRaw['description'] as String?,
      );
    }

    if (additionalRaw is bool && additionalRaw == false) {
      spec.allowAdditionalProperties = false;
    }

    return spec.additionalPropertiesField;
  }

  IrPatternPropertyField? _buildPatternPropertiesField(
    IrClass spec,
    Map<String, dynamic> schema,
    _SchemaLocation location,
    Set<String> usedFieldNames,
    SchemaDialect dialect,
  ) {
    final raw = schema['patternProperties'];
    if (raw is! Map<String, dynamic> || raw.isEmpty) {
      return spec.patternPropertiesField;
    }

    final matchers = <IrPatternMatcher>[];
    final identities = <String>{};
    TypeRef? representative;
    var index = 0;

    for (final entry in raw.entries) {
      index++;
      final pattern = entry.key;
      final matcherSchema = entry.value;
      if (matcherSchema is! Map<String, dynamic>) {
        continue;
      }
      final patternPointer = _pointerChild(
        _pointerChild(location.pointer, 'patternProperties'),
        pattern,
      );
      final typeRef = _resolveSchema(
        matcherSchema,
        _SchemaLocation(uri: location.uri, pointer: patternPointer),
        suggestedClassName: '${spec.name}PatternProperty$index',
        dialect: dialect,
      );
      matchers.add(IrPatternMatcher(pattern: pattern, typeRef: typeRef));
      identities.add(typeRef.identity);
      representative ??= typeRef;
    }

    if (matchers.isEmpty) {
      return spec.patternPropertiesField;
    }

    final valueType = identities.length == 1
        ? representative!
        : const DynamicTypeRef();
    final fieldName = _allocateDynamicFieldName(
      usedFieldNames,
      'patternProperties',
    );
    return IrPatternPropertyField(
      fieldName: fieldName,
      valueType: valueType,
      matchers: matchers,
    );
  }

  void _applyUnevaluatedProperties(
    IrClass spec,
    Map<String, dynamic> schema,
    _SchemaLocation location,
    SchemaDialect dialect,
    Set<String> usedFieldNames,
  ) {
    final node = schema['unevaluatedProperties'];
    if (node == null) {
      return;
    }

    final pointer = _pointerChild(location.pointer, 'unevaluatedProperties');
    if (node is bool) {
      if (!node) {
        spec.disallowUnevaluatedProperties = true;
      }
      return;
    }
    if (node is Map<String, dynamic>) {
      final fieldName = _allocateDynamicFieldName(
        usedFieldNames,
        'unevaluatedProperties',
      );
      final typeRef = _resolveSchema(
        node,
        _SchemaLocation(uri: location.uri, pointer: pointer),
        suggestedClassName: '${spec.name}UnevaluatedProperty',
        dialect: dialect,
      );
      spec.unevaluatedPropertiesField = IrDynamicKeyField(
        fieldName: fieldName,
        valueType: typeRef,
        description: node['description'] as String?,
      );
      return;
    }

    _schemaError(
      'Expected "unevaluatedProperties" to be a boolean or schema object',
      _SchemaLocation(uri: location.uri, pointer: pointer),
    );
  }

  IrPropertyNamesConstraint? _buildPropertyNamesConstraint(
    Map<String, dynamic> schema,
    _SchemaLocation location,
  ) {
    final node = schema['propertyNames'];
    if (node == null) {
      return null;
    }
    final pointer = _pointerChild(location.pointer, 'propertyNames');
    if (node is bool) {
      if (!node) {
        return IrPropertyNamesConstraint(
          schemaPointer: pointer,
          validation: null,
          disallow: true,
        );
      }
      return null;
    }
    if (node is Map<String, dynamic>) {
      final rules = _extractValidationRules(node);
      if (rules == null || !rules.hasRules) {
        return null;
      }
      return IrPropertyNamesConstraint(
        schemaPointer: pointer,
        validation: rules,
      );
    }
    _schemaError(
      'Expected "propertyNames" to be a boolean or schema object',
      _SchemaLocation(uri: location.uri, pointer: pointer),
    );
  }

  PropertyValidationRules? _extractValidationRules(
    Map<String, dynamic>? schema,
  ) {
    if (schema == null) {
      return null;
    }

    int? minLength;
    final minLengthRaw = schema['minLength'];
    if (minLengthRaw is int) {
      minLength = minLengthRaw;
    }

    int? maxLength;
    final maxLengthRaw = schema['maxLength'];
    if (maxLengthRaw is int) {
      maxLength = maxLengthRaw;
    }

    num? minimum;
    bool exclusiveMinimum = false;
    final exclusiveMinimumRaw = schema['exclusiveMinimum'];
    if (exclusiveMinimumRaw is num) {
      minimum = exclusiveMinimumRaw;
      exclusiveMinimum = true;
    } else {
      final minimumRaw = schema['minimum'];
      if (minimumRaw is num) {
        minimum = minimumRaw;
        exclusiveMinimum = exclusiveMinimumRaw == true;
      }
    }

    num? maximum;
    bool exclusiveMaximum = false;
    final exclusiveMaximumRaw = schema['exclusiveMaximum'];
    if (exclusiveMaximumRaw is num) {
      maximum = exclusiveMaximumRaw;
      exclusiveMaximum = true;
    } else {
      final maximumRaw = schema['maximum'];
      if (maximumRaw is num) {
        maximum = maximumRaw;
        exclusiveMaximum = exclusiveMaximumRaw == true;
      }
    }

    final patternRaw = schema['pattern'];
    final pattern = patternRaw is String ? patternRaw : null;

    Object? constValue;
    if (schema.containsKey('const')) {
      final raw = schema['const'];
      if (raw is String || raw is num || raw is bool || raw == null) {
        constValue = raw;
      }
    }

    // Array constraints
    final multipleOfRaw = schema['multipleOf'];
    final multipleOf = multipleOfRaw is num ? multipleOfRaw : null;

    final minItemsRaw = schema['minItems'];
    final minItems = minItemsRaw is int ? minItemsRaw : null;

    final maxItemsRaw = schema['maxItems'];
    final maxItems = maxItemsRaw is int ? maxItemsRaw : null;

    final uniqueItemsRaw = schema['uniqueItems'];
    final uniqueItems = uniqueItemsRaw is bool ? uniqueItemsRaw : null;

    // Object constraints
    final minPropertiesRaw = schema['minProperties'];
    final minProperties = minPropertiesRaw is int ? minPropertiesRaw : null;

    final maxPropertiesRaw = schema['maxProperties'];
    final maxProperties = maxPropertiesRaw is int ? maxPropertiesRaw : null;

    if (minLength == null &&
        maxLength == null &&
        minimum == null &&
        maximum == null &&
        pattern == null &&
        constValue == null &&
        multipleOf == null &&
        minItems == null &&
        maxItems == null &&
        uniqueItems == null &&
        minProperties == null &&
        maxProperties == null) {
      return null;
    }

    return PropertyValidationRules(
      minLength: minLength,
      maxLength: maxLength,
      minimum: minimum,
      maximum: maximum,
      exclusiveMinimum: exclusiveMinimum,
      exclusiveMaximum: exclusiveMaximum,
      pattern: pattern,
      constValue: constValue,
      multipleOf: multipleOf,
      minItems: minItems,
      maxItems: maxItems,
      uniqueItems: uniqueItems,
      minProperties: minProperties,
      maxProperties: maxProperties,
    );
  }

  int? _propertyOrder(Object? schema) {
    if (schema is Map<String, dynamic>) {
      final raw = schema['propertyOrder'];
      if (raw is num) {
        return raw.toInt();
      }
    }
    return null;
  }

  String _stringifyMetadataValue(Object? value) {
    if (value is String) {
      return "'$value'";
    }
    if (value is num || value is bool) {
      return value.toString();
    }
    if (value == null) {
      return 'null';
    }
    return value.toString();
  }

  String? _composePropertyDescription({
    String? description,
    String? format,
    _FormatInfo? formatInfo,
    required bool hintAvailable,
    required bool convertedFormat,
    required bool deprecated,
    Object? defaultValue,
    List<Object?>? examples,
  }) {
    final sections = <String>[];
    final base = description?.trim();
    if (base != null && base.isNotEmpty) {
      sections.add(base);
    }

    if (deprecated) {
      sections.add('Deprecated.');
    }

    if (defaultValue != null) {
      sections.add('Default: ${_stringifyMetadataValue(defaultValue)}.');
    }

    if (examples != null && examples.isNotEmpty) {
      final rendered = examples.map(_stringifyMetadataValue).join(', ');
      sections.add('Examples: $rendered.');
    }

    if (format != null && format.trim().isNotEmpty) {
      final normalizedFormat = format.trim();
      final recognizedFormat = formatInfo != null || hintAvailable;
      if (!recognizedFormat) {
        sections.add(
          'Format: $normalizedFormat (unsupported format, emitted as String).',
        );
      } else {
        String reasonSuffix = '';
        if (!convertedFormat) {
          final reason = !_options.enableFormatHints && hintAvailable
              ? 'format hints disabled'
              : hintAvailable
              ? 'conversion not applied'
              : 'no type mapping available';
          reasonSuffix = ' ($reason)';
        }
        sections.add('Format: $normalizedFormat$reasonSuffix.');
        if (formatInfo?.description != null &&
            formatInfo!.description.trim().isNotEmpty) {
          final desc = formatInfo.description.trim();
          sections.add(desc.endsWith('.') ? desc : '$desc.');
        }
        if (formatInfo?.definition != null &&
            formatInfo!.definition!.trim().isNotEmpty) {
          final uri = formatInfo.definition!.trim();
          sections.add('See $uri.');
        }
      }
    }

    if (sections.isEmpty) {
      return null;
    }
    return sections.join('\n\n');
  }

  _ResolvedSchema _resolveReference(String ref, _SchemaLocation context) {
    if (_isRelativeJsonPointer(ref)) {
      final pointer = _resolveRelativeJsonPointer(ref, context.pointer);
      final document = _loadDocument(context.uri);
      final schema = _schemaAtPointer(document, pointer);
      return _ResolvedSchema(
        schema: schema,
        location: _SchemaLocation(uri: context.uri, pointer: pointer),
      );
    }

    Uri parsed;
    try {
      parsed = Uri.parse(ref);
    } on FormatException {
      _log('Invalid ref $ref at ${_describeLocation(context)}');
      return _ResolvedSchema(schema: null, location: context);
    }
    final resolved = context.uri.resolveUri(parsed);
    final fragment = resolved.fragment;
    final targetUri = fragment.isEmpty
        ? resolved
        : Uri.parse(resolved.toString().split('#').first);

    if (fragment.isNotEmpty && !fragment.startsWith('/')) {
      final anchorLocation = _lookupAnchor(targetUri, fragment);
      if (anchorLocation != null) {
        final document = _loadDocument(anchorLocation.uri);
        final schema = _schemaAtPointer(document, anchorLocation.pointer);
        return _ResolvedSchema(schema: schema, location: anchorLocation);
      }
      _log('Anchor $fragment not found in $targetUri');
      return _ResolvedSchema(schema: null, location: context);
    }

    final pointer = fragment.isEmpty ? '#' : _normalizePointer('#$fragment');
    final document = _loadDocument(targetUri);
    final schema = _schemaAtPointer(document, pointer);
    return _ResolvedSchema(
      schema: schema,
      location: _SchemaLocation(uri: targetUri, pointer: pointer),
    );
  }

  _ResolvedSchema _resolveDynamicReference(
    String ref,
    _SchemaLocation context,
  ) {
    Uri parsed;
    try {
      parsed = Uri.parse(ref);
    } on FormatException {
      _log('Invalid dynamicRef $ref at ${_describeLocation(context)}');
      return _ResolvedSchema(schema: null, location: context);
    }
    final resolved = context.uri.resolveUri(parsed);
    final fragment = resolved.fragment;
    final targetUri = fragment.isEmpty
        ? resolved
        : Uri.parse(resolved.toString().split('#').first);

    if (fragment.isEmpty) {
      final document = _loadDocument(targetUri);
      final schema = _schemaAtPointer(document, '#');
      return _ResolvedSchema(
        schema: schema,
        location: _SchemaLocation(uri: targetUri, pointer: '#'),
      );
    }

    if (fragment.startsWith('/')) {
      final pointer = _normalizePointer('#$fragment');
      final document = _loadDocument(targetUri);
      final schema = _schemaAtPointer(document, pointer);
      return _ResolvedSchema(
        schema: schema,
        location: _SchemaLocation(uri: targetUri, pointer: pointer),
      );
    }

    for (final entry in _dynamicScope.reversed) {
      if (entry.name == fragment) {
        final document = _loadDocument(entry.location.uri);
        final schema = _schemaAtPointer(document, entry.location.pointer);
        return _ResolvedSchema(schema: schema, location: entry.location);
      }
    }

    final dynamicAnchorLocation = _lookupDynamicAnchor(targetUri, fragment);
    if (dynamicAnchorLocation != null) {
      final document = _loadDocument(dynamicAnchorLocation.uri);
      final schema = _schemaAtPointer(document, dynamicAnchorLocation.pointer);
      return _ResolvedSchema(schema: schema, location: dynamicAnchorLocation);
    }

    final anchorLocation = _lookupAnchor(targetUri, fragment);
    if (anchorLocation != null) {
      final document = _loadDocument(anchorLocation.uri);
      final schema = _schemaAtPointer(document, anchorLocation.pointer);
      return _ResolvedSchema(schema: schema, location: anchorLocation);
    }

    _log('Unable to resolve dynamicRef $ref at ${_describeLocation(context)}');
    return _ResolvedSchema(schema: null, location: context);
  }

  Map<String, dynamic>? _schemaAtPointer(
    Map<String, dynamic> document,
    String pointer,
  ) {
    if (pointer == '#') {
      return document;
    }
    final segments = _pointerSegments(pointer);
    dynamic current = document;
    for (final segment in segments) {
      if (current is Map<String, dynamic>) {
        current = current[segment];
        continue;
      }
      if (current is List) {
        final index = int.tryParse(segment);
        if (index == null || index < 0 || index >= current.length) {
          current = null;
          break;
        }
        current = current[index];
        continue;
      }
      current = null;
      break;
    }

    if (current is Map<String, dynamic>) {
      return current;
    }
    if (current == null) {
      return null;
    }
    if (current is bool) {
      return current ? <String, dynamic>{} : <String, dynamic>{'type': 'never'};
    }
    return current as Map<String, dynamic>?;
  }

  Map<String, dynamic> _loadDocument(Uri uri) {
    // Remove fragment for document lookup - fragments point within a document
    final documentUri = uri.removeFragment();
    
    final cached = _documentCache[documentUri];
    if (cached != null) {
      return cached;
    }
    final document = _documentLoader(documentUri);
    _documentCache[documentUri] = document;
    if (!_documentDialects.containsKey(documentUri)) {
      final dialect = _detectDocumentDialect(documentUri, document);
      _documentDialects[documentUri] = dialect;
    }
    _indexDocument(documentUri, document);
    return document;
  }

  List<String> _pointerSegments(String pointer) {
    if (pointer == '#') {
      return const <String>[];
    }
    final raw = pointer.substring(2).split('/');
    return raw.map(_unescapePointerToken).toList();
  }

  String _pointerFromSegments(List<String> segments) {
    if (segments.isEmpty) {
      return '#';
    }
    final encoded = segments.map(_escapePointerToken).join('/');
    return '#/$encoded';
  }

  bool _isRelativeJsonPointer(String ref) {
    final first = ref.isNotEmpty ? ref.codeUnitAt(0) : null;
    return first != null && first >= 0x30 && first <= 0x39; // '0'..'9'
  }

  String _resolveRelativeJsonPointer(String ref, String contextPointer) {
    final match = RegExp(r'^(\d+)(#|(?:/(.*))?)$').firstMatch(ref);
    if (match == null) {
      throw ArgumentError('Invalid relative JSON pointer "$ref".');
    }
    final steps = int.parse(match.group(1)!);
    final suffix = match.group(2) ?? '';
    final suffixTail = match.group(3);

    final segments = _pointerSegments(contextPointer);
    if (steps > segments.length) {
      throw StateError(
        'Relative JSON pointer "$ref" navigates beyond the document root from $contextPointer.',
      );
    }
    final baseSegments = segments.sublist(0, segments.length - steps);

    if (suffix == '#') {
      return _pointerFromSegments(baseSegments);
    }

    var additionalSegments = <String>[];
    if (suffixTail != null && suffixTail.isNotEmpty) {
      additionalSegments = suffixTail
          .split('/')
          .map(_unescapePointerToken)
          .toList();
    }

    return _pointerFromSegments([...baseSegments, ...additionalSegments]);
  }

  void _assertCompatibleProperty(
    String propertyName,
    Map<String, dynamic> existing,
    String existingPointer,
    Map<String, dynamic> incoming,
    String incomingPointer,
  ) {
    final existingType = _normalizeTypeKeyword(existing['type']);
    final incomingType = _normalizeTypeKeyword(incoming['type']);

    if (existingType != null &&
        incomingType != null &&
        existingType != incomingType) {
      throw StateError(
        'Conflicting types for property "$propertyName": '
        '$existingType at $existingPointer vs '
        '$incomingType at $incomingPointer',
      );
    }
  }

  Map<String, dynamic> _mergePropertyAnnotations(
    Map<String, dynamic> base,
    Map<String, dynamic> incoming,
  ) {
    final merged = Map<String, dynamic>.from(base);
    for (final entry in incoming.entries) {
      merged.putIfAbsent(entry.key, () => entry.value);
    }
    return merged;
  }

  String _allocateDynamicFieldName(Set<String> usedNames, String baseName) {
    final base = _options.preferCamelCase
        ? _Naming.fieldName(baseName)
        : _Naming.identifier(baseName);
    var candidate = base;
    var counter = 2;
    while (usedNames.contains(candidate)) {
      candidate = '$base$counter';
      counter++;
    }
    usedNames.add(candidate);
    return candidate;
  }

  UnionDiscriminator? _extractDiscriminator(Map<String, dynamic> schema) {
    final raw = schema['discriminator'];
    if (raw is! Map<String, dynamic>) {
      return null;
    }
    final propertyName = raw['propertyName'];
    if (propertyName is! String || propertyName.isEmpty) {
      return null;
    }
    final mappingRaw = raw['mapping'];
    if (mappingRaw is Map) {
      final mapping = <String, String>{};
      mappingRaw.forEach((key, value) {
        if (key is String && value is String) {
          mapping[key] = _normalizePointer(value);
        }
      });
      return UnionDiscriminator(
        propertyName: propertyName,
        mapping: Map.unmodifiable(mapping),
      );
    }
    return UnionDiscriminator(propertyName: propertyName, mapping: const {});
  }

  List<IrUnionVariant> _applyDiscriminatorMapping(
    List<IrUnionVariant> variants,
    UnionDiscriminator? discriminator,
  ) {
    if (discriminator == null || discriminator.mapping.isEmpty) {
      return variants;
    }
    final mappingByPointer = discriminator.mapping.map((key, value) {
      return MapEntry(value, key);
    });

    return variants.map((variant) {
      final discriminatorValue = mappingByPointer[variant.schemaPointer];
      return IrUnionVariant(
        schemaPointer: variant.schemaPointer,
        classSpec: variant.classSpec,
        discriminatorValue: discriminatorValue,
        requiredProperties: variant.requiredProperties,
        constProperties: variant.constProperties,
      );
    }).toList();
  }

  String _unionVariantSuggestion(
    String baseName,
    Map<String, dynamic>? schema,
    _SchemaLocation location,
    int index,
  ) {
    final title = schema != null ? schema['title'] : null;
    if (title is String && title.trim().isNotEmpty) {
      return _Naming.className(title.trim());
    }
    final pointerName = _nameFromPointer(location.pointer);
    if (pointerName.isNotEmpty && pointerName != 'Generated') {
      return _Naming.className(pointerName);
    }
    return '${baseName}Variant${index + 1}';
  }

  _FormatHint? _lookupFormatHint(String? format) {
    if (format == null || format.isEmpty) {
      return null;
    }
    return _formatHintTable[format];
  }
}

class _FormatHint {
  const _FormatHint({
    required this.name,
    required this.typeName,
    required this.deserialize,
    required this.serialize,
    this.helper,
  });

  final String name;
  final String typeName;
  final String Function(String source) deserialize;
  final String Function(String value) serialize;
  final IrHelper? helper;
}

class _FormatInfo {
  const _FormatInfo({required this.description, this.definition});

  final String description;
  final String? definition;
}

const IrHelper _emailAddressHelper = IrHelper(
  name: 'EmailAddress',
  code: '''
/// Value type representing an email address.
/// Generated because the originating schema used `format: email`.
class EmailAddress {
  const EmailAddress(this.value);

  final String value;

  String toJson() => value;

  @override
  String toString() => value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is EmailAddress && other.value == value;

  @override
  int get hashCode => value.hashCode;
}
''',
);

const IrHelper _uuidValueHelper = IrHelper(
  name: 'UuidValue',
  code: '''
/// Value type representing a UUID string.
/// Generated because the originating schema used `format: uuid`.
class UuidValue {
  const UuidValue(this.value);

  final String value;

  String toJson() => value;

  @override
  String toString() => value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is UuidValue && other.value == value;

  @override
  int get hashCode => value.hashCode;
}
''',
);

const IrHelper _hostnameHelper = IrHelper(
  name: 'Hostname',
  code: '''
/// Value type representing a hostname.
/// Generated because the originating schema used `format: hostname`.
class Hostname {
  const Hostname(this.value);

  final String value;

  String toJson() => value;

  @override
  String toString() => value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Hostname && other.value == value;

  @override
  int get hashCode => value.hashCode;
}
''',
);

const IrHelper _ipv4AddressHelper = IrHelper(
  name: 'Ipv4Address',
  code: '''
/// Value type representing an IPv4 address.
/// Generated because the originating schema used `format: ipv4`.
class Ipv4Address {
  const Ipv4Address(this.value);

  final String value;

  String toJson() => value;

  @override
  String toString() => value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Ipv4Address && other.value == value;

  @override
  int get hashCode => value.hashCode;
}
''',
);

const IrHelper _ipv6AddressHelper = IrHelper(
  name: 'Ipv6Address',
  code: '''
/// Value type representing an IPv6 address.
/// Generated because the originating schema used `format: ipv6`.
class Ipv6Address {
  const Ipv6Address(this.value);

  final String value;

  String toJson() => value;

  @override
  String toString() => value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Ipv6Address && other.value == value;

  @override
  int get hashCode => value.hashCode;
}
''',
);

const IrHelper _uriReferenceHelper = IrHelper(
  name: 'UriReference',
  code: '''
/// Value type representing a URI reference.
/// Generated because the originating schema used `format: uri-reference`.
class UriReference {
  const UriReference(this.value);

  final Uri value;

  String toJson() => value.toString();

  @override
  String toString() => value.toString();

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is UriReference && other.value == value;

  @override
  int get hashCode => value.hashCode;
}
''',
);

final Map<String, _FormatHint> _formatHintTable = <String, _FormatHint>{
  'date-time': _FormatHint(
    name: 'date-time',
    typeName: 'DateTime',
    deserialize: (source) => 'DateTime.parse($source)',
    serialize: (value) => '$value.toIso8601String()',
  ),
  'date': _FormatHint(
    name: 'date',
    typeName: 'DateTime',
    deserialize: (source) => 'DateTime.parse($source)',
    serialize: (value) => '$value.toIso8601String().split(\'T\').first',
  ),
  'uri': _FormatHint(
    name: 'uri',
    typeName: 'Uri',
    deserialize: (source) => 'Uri.parse($source)',
    serialize: (value) => '$value.toString()',
  ),
  'uri-reference': _FormatHint(
    name: 'uri-reference',
    typeName: 'UriReference',
    deserialize: (source) => 'UriReference(Uri.parse($source))',
    serialize: (value) => '$value.toJson()',
    helper: _uriReferenceHelper,
  ),
  'email': _FormatHint(
    name: 'email',
    typeName: 'EmailAddress',
    deserialize: (source) => 'EmailAddress($source)',
    serialize: (value) => '$value.toJson()',
    helper: _emailAddressHelper,
  ),
  'uuid': _FormatHint(
    name: 'uuid',
    typeName: 'UuidValue',
    deserialize: (source) => 'UuidValue($source)',
    serialize: (value) => '$value.toJson()',
    helper: _uuidValueHelper,
  ),
  'hostname': _FormatHint(
    name: 'hostname',
    typeName: 'Hostname',
    deserialize: (source) => 'Hostname($source)',
    serialize: (value) => '$value.toJson()',
    helper: _hostnameHelper,
  ),
  'ipv4': _FormatHint(
    name: 'ipv4',
    typeName: 'Ipv4Address',
    deserialize: (source) => 'Ipv4Address($source)',
    serialize: (value) => '$value.toJson()',
    helper: _ipv4AddressHelper,
  ),
  'ipv6': _FormatHint(
    name: 'ipv6',
    typeName: 'Ipv6Address',
    deserialize: (source) => 'Ipv6Address($source)',
    serialize: (value) => '$value.toJson()',
    helper: _ipv6AddressHelper,
  ),
  'iri': _FormatHint(
    name: 'iri',
    typeName: 'Uri',
    deserialize: (source) => 'Uri.parse($source)',
    serialize: (value) => '$value.toString()',
  ),
  'iri-reference': _FormatHint(
    name: 'iri-reference',
    typeName: 'UriReference',
    deserialize: (source) => 'UriReference(Uri.parse($source))',
    serialize: (value) => '$value.toJson()',
    helper: _uriReferenceHelper,
  ),
};

final Map<String, _FormatInfo> _formatRegistry = <String, _FormatInfo>{
  'date-time': _FormatInfo(
    description: 'Date and time as defined by RFC 3339 date-time.',
    definition:
        'https://json-schema.org/draft/2020-12/json-schema-validation.html#name-dates-times-and-duration',
  ),
  'date': _FormatInfo(
    description: 'Calendar date as defined by RFC 3339 full-date.',
    definition:
        'https://json-schema.org/draft/2020-12/json-schema-validation.html#name-dates-times-and-duration',
  ),
  'time': _FormatInfo(
    description: 'Time of day as defined by RFC 3339 full-time.',
    definition:
        'https://json-schema.org/draft/2020-12/json-schema-validation.html#name-dates-times-and-duration',
  ),
  'duration': _FormatInfo(
    description: 'Duration as defined by RFC 3339 duration.',
    definition:
        'https://json-schema.org/draft/2020-12/json-schema-validation.html#name-dates-times-and-duration',
  ),
  'email': _FormatInfo(
    description: 'Email address as defined by RFC 5321 Mailbox.',
    definition:
        'https://json-schema.org/draft/2020-12/json-schema-validation.html#name-email-addresses',
  ),
  'hostname': _FormatInfo(
    description: 'Hostname as defined by RFC 1123.',
    definition:
        'https://json-schema.org/draft/2020-12/json-schema-validation.html#name-hostnames',
  ),
  'ipv4': _FormatInfo(
    description: 'IPv4 address as defined by RFC 2673 section 3.2.',
    definition:
        'https://json-schema.org/draft/2020-12/json-schema-validation.html#name-ip-addresses',
  ),
  'ipv6': _FormatInfo(
    description: 'IPv6 address as defined by RFC 4291.',
    definition:
        'https://json-schema.org/draft/2020-12/json-schema-validation.html#name-ip-addresses',
  ),
  'uri': _FormatInfo(
    description: 'URI as defined by RFC 3986.',
    definition:
        'https://json-schema.org/draft/2020-12/json-schema-validation.html#name-resource-identifiers',
  ),
  'uri-reference': _FormatInfo(
    description: 'URI Reference as defined by RFC 3986.',
    definition:
        'https://json-schema.org/draft/2020-12/json-schema-validation.html#name-resource-identifiers',
  ),
  'uri-template': _FormatInfo(
    description: 'URI Template as defined by RFC 6570.',
    definition:
        'https://json-schema.org/draft/2020-12/json-schema-validation.html#name-uri-template',
  ),
  'iri': _FormatInfo(
    description:
        'Internationalized Resource Identifier as defined by RFC 3987.',
    definition:
        'https://json-schema.org/draft/2020-12/json-schema-validation.html#name-resource-identifiers',
  ),
  'iri-reference': _FormatInfo(
    description: 'IRI Reference as defined by RFC 3987.',
    definition:
        'https://json-schema.org/draft/2020-12/json-schema-validation.html#name-resource-identifiers',
  ),
  'uuid': _FormatInfo(
    description: 'Universally Unique Identifier as defined by RFC 4122.',
    definition:
        'https://json-schema.org/draft/2020-12/json-schema-validation.html#name-resource-identifiers',
  ),
  'regex': _FormatInfo(
    description: 'Regular expression as defined in ECMA-262.',
    definition:
        'https://json-schema.org/draft/2020-12/json-schema-validation.html#name-regular-expressions',
  ),
  'json-pointer': _FormatInfo(
    description: 'JSON Pointer as defined by RFC 6901.',
    definition:
        'https://json-schema.org/draft/2020-12/json-schema-validation.html#name-json-pointer',
  ),
  'relative-json-pointer': _FormatInfo(
    description:
        'Relative JSON Pointer as defined by relative-json-pointer draft-01.',
    definition:
        'https://json-schema.org/draft/2020-12/json-schema-validation.html#name-json-pointer',
  ),
};

const IrHelper _validationHelper = IrHelper(
  name: 'ValidationError',
  code: '''
String appendJsonPointer(String pointer, String token) {
  final escaped = token.replaceAll('~', '~0').replaceAll('/', '~1');
  if (pointer.isEmpty) return '/' + escaped;
  return pointer + '/' + escaped;
}

Never throwValidationError(String pointer, String keyword, String message) =>
    throw ValidationError(pointer: pointer, keyword: keyword, message: message);

class ValidationAnnotation {
  const ValidationAnnotation({
    required this.keyword,
    required this.value,
    this.schemaPointer,
  });

  final String keyword;
  final Object? value;
  final String? schemaPointer;
}

class ValidationContext {
  ValidationContext();

  final Map<String, List<ValidationAnnotation>> annotations = <String, List<ValidationAnnotation>>{};
  final Map<String, Set<String>> evaluatedProperties = <String, Set<String>>{};
  final Map<String, Set<int>> evaluatedItems = <String, Set<int>>{};

  void annotate(
    String pointer,
    String keyword,
    Object? value, {
    String? schemaPointer,
  }) {
    final list = annotations.putIfAbsent(pointer, () => <ValidationAnnotation>[]);
    list.add(
      ValidationAnnotation(
        keyword: keyword,
        value: value,
        schemaPointer: schemaPointer,
      ),
    );
  }

  void markProperty(String pointer, String property) {
    evaluatedProperties.putIfAbsent(pointer, () => <String>{}).add(property);
  }

  void markItem(String pointer, int index) {
    evaluatedItems.putIfAbsent(pointer, () => <int>{}).add(index);
  }
}

class ValidationError implements Exception {
  ValidationError({
    required this.pointer,
    required this.keyword,
    required this.message,
  });

  final String pointer;
  final String keyword;
  final String message;

  @override
  String toString() => 'ValidationError(' + keyword + ' @ ' + pointer + ': ' + message + ')';
}
''',
);
String _elementClassName(String base) {
  final lower = base.toLowerCase();
  if (lower.endsWith('ies') && base.length > 3) {
    return '${base.substring(0, base.length - 3)}y';
  }
  const esEndings = ['sses', 'ches', 'shes', 'xes', 'zes'];
  for (final ending in esEndings) {
    if (lower.endsWith(ending) && base.length > ending.length) {
      return base.substring(0, base.length - 2);
    }
  }
  if (lower.endsWith('s') && base.length > 1) {
    return base.substring(0, base.length - 1);
  }
  return '${base}Item';
}
