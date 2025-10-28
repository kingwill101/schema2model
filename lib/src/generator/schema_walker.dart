part of 'package:schemamodeschema/src/generator.dart';

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

class _SchemaWalker {
  _SchemaWalker(
    this._rootSchema,
    this._options, {
    required Uri baseUri,
    required SchemaDocumentLoader documentLoader,
  }) : _typeCache = {},
       _classes = LinkedHashMap<String, IrClass>(),
       _enums = LinkedHashMap<String, IrEnum>(),
       _unions = <IrUnion>[],
       _usedClassNames = <String>{},
       _usedEnumNames = <String>{},
       _classByLocation = <_SchemaCacheKey, IrClass>{},
       _enumByLocation = <_SchemaCacheKey, IrEnum>{},
       _rootUri = baseUri,
       _documentLoader = documentLoader,
       _documentCache = {baseUri: _rootSchema};

  final Map<String, dynamic> _rootSchema;
  final SchemaGeneratorOptions _options;
  final Map<_SchemaCacheKey, TypeRef> _typeCache;
  final LinkedHashMap<String, IrClass> _classes;
  final LinkedHashMap<String, IrEnum> _enums;
  final List<IrUnion> _unions;
  final Set<String> _usedClassNames;
  final Set<String> _usedEnumNames;
  final Map<_SchemaCacheKey, IrClass> _classByLocation;
  final Map<_SchemaCacheKey, IrEnum> _enumByLocation;
  final Uri _rootUri;
  final SchemaDocumentLoader _documentLoader;
  final Map<Uri, Map<String, dynamic>> _documentCache;

  SchemaIr build() {
    final rootLocation = _SchemaLocation(uri: _rootUri, pointer: '#');
    final root = _ensureRootClass(rootLocation);
    _processDefinitions(_rootSchema, rootLocation);
    final classes = _orderedClasses(root);
    final enums = _enums.values.toList(growable: false);
    return SchemaIr(
      rootClass: root,
      classes: classes,
      enums: enums,
      unions: List<IrUnion>.unmodifiable(_unions),
    );
  }

  IrClass _ensureRootClass(_SchemaLocation location) {
    final ref = _resolveSchema(
      _rootSchema,
      location,
      suggestedClassName: _options.effectiveRootClassName,
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
          description: null,
        ),
      ],
      conditionals: JsonConditionals(
        ifSchema: _rootSchema['if'] as Map<String, dynamic>?,
        thenSchema: _rootSchema['then'] as Map<String, dynamic>?,
        elseSchema: _rootSchema['else'] as Map<String, dynamic>?,
      ),
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

  TypeRef _resolveSchema(
    Map<String, dynamic>? schema,
    _SchemaLocation location, {
    String? suggestedClassName,
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

    if (schema == null) {
      const ref = DynamicTypeRef();
      _typeCache[cacheKey] = ref;
      return ref;
    }

    if (schema case {'\$ref': final String refValue}) {
      final resolved = _resolveReference(refValue, location);
      final inferredName = _nameFromPointer(resolved.location.pointer);
      final typeRef = _resolveSchema(
        resolved.schema,
        resolved.location,
        suggestedClassName: suggestedClassName ?? inferredName,
      );
      _typeCache[cacheKey] = typeRef;
      return typeRef;
    }

    Map<String, dynamic>? workingSchema = schema;
    if (workingSchema case {'allOf': final List allOf} when allOf.isNotEmpty) {
      workingSchema = _mergeAllOfSchemas(workingSchema, location);
    }

    _processDefinitions(workingSchema ?? const {}, location);

    final enumValues = workingSchema?['enum'];
    if (enumValues is List &&
        enumValues.isNotEmpty &&
        enumValues.every((value) => value is String)) {
      final enumName = _allocateEnumName(
        workingSchema?['title'] as String? ??
            suggestedClassName ??
            _nameFromPointer(location.pointer),
      );
      final description = workingSchema?['description'] as String?;
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
    }

    final unionKeyword = schema.containsKey('oneOf')
        ? 'oneOf'
        : schema.containsKey('anyOf')
        ? 'anyOf'
        : null;
    if (unionKeyword != null) {
      final members = schema[unionKeyword];
      if (members is List && members.isNotEmpty) {
        final ref = _resolveUnion(
          schema,
          location,
          members.cast<dynamic>(),
          unionKeyword,
          suggestedClassName: suggestedClassName,
        );
        _typeCache[cacheKey] = ref;
        return ref;
      }
    }

    final type = workingSchema?['type'];
    final normalizedType = _normalizeTypeKeyword(type);

    if (normalizedType == 'object' ||
        workingSchema?.containsKey('properties') == true) {
      final className = _allocateClassName(
        workingSchema?['title'] as String? ??
            suggestedClassName ??
            _nameFromPointer(location.pointer),
      );
      final spec = _classes.putIfAbsent(className, () {
        final objSpec = IrClass(
          name: className,
          description: workingSchema?['description'] as String?,
          properties: [],
          conditionals: JsonConditionals(
            ifSchema: schema['if'] as Map<String, dynamic>?,
            thenSchema: schema['then'] as Map<String, dynamic>?,
            elseSchema: schema['else'] as Map<String, dynamic>?,
          ),
        );
        final locationKey = _SchemaCacheKey(location.uri, location.pointer);
        _classByLocation[locationKey] = objSpec;
        _typeCache[cacheKey] = ObjectTypeRef(objSpec);
        _populateObjectSpec(objSpec, workingSchema ?? const {}, location);
        return objSpec;
      });

      final ref = ObjectTypeRef(spec);
      _typeCache[cacheKey] = ref;
      return ref;
    }

    if (normalizedType == 'array') {
      final items = workingSchema?['items'];
      final itemPointer = _pointerChild(location.pointer, 'items');
      final itemType = _resolveSchema(
        items is Map<String, dynamic> ? items : null,
        _SchemaLocation(uri: location.uri, pointer: itemPointer),
        suggestedClassName: suggestedClassName != null
            ? '${suggestedClassName}Item'
            : null,
      );
      final ref = ListTypeRef(itemType);
      _typeCache[cacheKey] = ref;
      return ref;
    }

    final primitive = _primitiveFromType(normalizedType);
    _typeCache[cacheKey] = primitive;
    return primitive;
  }

  TypeRef _resolveUnion(
    Map<String, dynamic> schema,
    _SchemaLocation location,
    List<dynamic> members,
    String keyword, {
    String? suggestedClassName,
  }) {
    final unionPointer = _pointerChild(location.pointer, keyword);
    final resolvedMembers = <_ResolvedSchema>[];

    for (var index = 0; index < members.length; index++) {
      final memberPointer = _pointerChild(unionPointer, '$index');
      final memberLocation = _SchemaLocation(
        uri: location.uri,
        pointer: memberPointer,
      );
      final member = members[index];
      if (member is Map<String, dynamic>) {
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

    final variantTypes = <TypeRef>[];
    var allObjects = true;
    for (var index = 0; index < resolvedMembers.length; index++) {
      final resolved = resolvedMembers[index];
      final variantName = _unionVariantSuggestion(
        schema['title'] as String? ??
            suggestedClassName ??
            _nameFromPointer(location.pointer),
        resolved.schema,
        resolved.location,
        index,
      );
      final variantKey =
          _SchemaCacheKey(resolved.location.uri, resolved.location.pointer);
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
        typeRef = _resolveSchema(
          resolved.schema,
          resolved.location,
          suggestedClassName: variantName,
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
      final same = variantTypes.every((type) => type.identity == first.identity);
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
      if (spec.superClassName == null) {
        spec.superClassName = baseClass.name;
      }
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
          );
        }
      }
    }
  }

  Map<String, dynamic> _mergeAllOfSchemas(
    Map<String, dynamic> schema,
    _SchemaLocation location,
  ) {
    String? mergedDescription = schema['description'] as String?;
    final mergedRequired = LinkedHashSet<String>();
    final mergedProperties = LinkedHashMap<String, Map<String, dynamic>>();
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
  ) {
    final properties = schema['properties'];
    final requiredSet = switch (schema['required']) {
      List list => list.whereType<String>().toSet(),
      _ => const <String>{},
    };

    final usedFieldNames = <String>{};

    if (properties is Map<String, dynamic>) {
      for (final entry in properties.entries) {
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
        final propertyType = _resolveSchema(
          propertyMap,
          _SchemaLocation(uri: location.uri, pointer: propertyPointer),
          suggestedClassName: suggestedName,
        );

        final isRequired = requiredSet.contains(key);
        final fieldName = _options.preferCamelCase
            ? _Naming.fieldName(key)
            : _Naming.identifier(key);
        usedFieldNames.add(fieldName);

        final prop = IrProperty(
          jsonName: key,
          fieldName: fieldName,
          typeRef: propertyType,
          isRequired: isRequired,
          description: propertyMap?['description'] as String?,
        );
        spec.properties.add(prop);
      }
    }

    spec.additionalPropertiesField = _buildAdditionalPropertiesField(
      spec,
      schema,
      location,
      usedFieldNames,
    );
    final patternField = _buildPatternPropertiesField(
      spec,
      schema,
      location,
      usedFieldNames,
    );
    if (patternField != null) {
      spec.patternPropertiesField = patternField;
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
      return segment != 'properties' &&
          segment != r'$defs' &&
          segment != 'definitions' &&
          segment != 'items';
    });
    return relevant ?? 'Generated';
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

    final parsed = Uri.parse(ref);
    final resolved = context.uri.resolveUri(parsed);
    final targetUri = resolved.replace(fragment: '');
    final fragment = resolved.fragment;
    final pointer = fragment.isEmpty ? '#' : _normalizePointer('#$fragment');
    final document = _loadDocument(targetUri);
    final schema = _schemaAtPointer(document, pointer);
    return _ResolvedSchema(
      schema: schema,
      location: _SchemaLocation(uri: targetUri, pointer: pointer),
    );
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
    final cached = _documentCache[uri];
    if (cached != null) {
      return cached;
    }
    final document = _documentLoader(uri);
    _documentCache[uri] = document;
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
}
