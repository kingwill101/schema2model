part of 'package:schema2model/src/generator.dart';

/// Intermediate representation root describing the generated model set.
class SchemaIr {
  SchemaIr({
    required this.rootClass,
    required this.classes,
    required this.enums,
    required this.mixedEnums,
    required this.unions,
    required this.helpers,
  });

  final IrClass rootClass;
  final List<IrClass> classes;
  final List<IrEnum> enums;
  final List<IrMixedEnum> mixedEnums;
  final List<IrUnion> unions;
  final List<IrHelper> helpers;
}

/// Represents an immutable Dart class derived from a JSON schema object.
class IrClass {
  IrClass({
    required this.name,
    required this.properties,
    this.description,
    this.additionalPropertiesField,
    this.patternPropertiesField,
    this.allowAdditionalProperties = true,
    this.conditionals,
    this.superClassName,
    List<ConditionalConstraint> conditionalConstraints = const [],
    this.unevaluatedPropertiesField,
    this.disallowUnevaluatedProperties = false,
    Map<String, Set<String>>? dependentRequired,
    Map<String, DependentSchemaConstraint>? dependentSchemas,
    this.propertyNamesConstraint,
    Map<String, Object?>? extensionAnnotations,
  }) : conditionalConstraints = List<ConditionalConstraint>.from(
         conditionalConstraints,
       ),
       dependentRequired = dependentRequired ?? <String, Set<String>>{},
       dependentSchemas =
           dependentSchemas ?? <String, DependentSchemaConstraint>{},
       extensionAnnotations = extensionAnnotations ?? <String, Object?>{};

  final String name;
  final String? description;
  final List<IrProperty> properties;
  bool allowAdditionalProperties;
  IrDynamicKeyField? additionalPropertiesField;
  IrPatternPropertyField? patternPropertiesField;
  final JsonConditionals? conditionals;
  String? superClassName;
  final List<ConditionalConstraint> conditionalConstraints;
  IrDynamicKeyField? unevaluatedPropertiesField;
  bool disallowUnevaluatedProperties;
  final Map<String, Set<String>> dependentRequired;
  final Map<String, DependentSchemaConstraint> dependentSchemas;
  IrPropertyNamesConstraint? propertyNamesConstraint;
  final Map<String, Object?> extensionAnnotations;
}

/// Represents a property on an [IrClass].
class IrProperty {
  IrProperty({
    required this.jsonName,
    required this.fieldName,
    required this.typeRef,
    required this.isRequired,
    required this.schemaPointer,
    this.description,
    this.title,
    this.format,
    this.validation,
    this.isDeprecated = false,
    this.defaultValue,
    this.examples = const <Object?>[],
    this.contentMediaType,
    this.contentEncoding,
    this.contentSchema,
    this.contentSchemaTypeRef,
    this.isReadOnly = false,
    this.isWriteOnly = false,
    Map<String, Object?>? extensionAnnotations,
  }) : extensionAnnotations = extensionAnnotations ?? <String, Object?>{};

  final String jsonName;
  final String fieldName;
  final TypeRef typeRef;
  final bool isRequired;
  final String? description;
  final String? title;
  final String? format;
  final PropertyValidationRules? validation;
  final bool isDeprecated;
  final Object? defaultValue;
  final List<Object?> examples;
  final String schemaPointer;
  final Map<String, Object?> extensionAnnotations;
  
  /// MIME type of the content (e.g., "image/png", "application/json")
  final String? contentMediaType;
  
  /// Encoding used for the content (e.g., "base64")
  final String? contentEncoding;
  
  /// Schema for validating decoded content
  final Map<String, dynamic>? contentSchema;

  /// Resolved type for validating decoded content (when enabled)
  final TypeRef? contentSchemaTypeRef;
  
  /// Property is read-only (managed by server, should not be sent in requests)
  final bool isReadOnly;
  
  /// Property is write-only (should not be returned in responses, e.g., passwords)
  final bool isWriteOnly;

  String get dartType => typeRef.dartType(nullable: !isRequired);

  String deserializeExpression(String jsonVariable) {
    final access = "$jsonVariable['$jsonName']";
    return typeRef.deserializeInline(access, required: isRequired);
  }

  String? serializeExpression(String mapVariable) {
    final target = "$mapVariable['$jsonName']";

    if (isRequired) {
      final value = typeRef.serializeInline(fieldName, required: true);
      if (value == fieldName && !typeRef.requiresConversionOnSerialize) {
        return '    $target = $fieldName;';
      }
      return '    $target = $value;';
    }

    if (!typeRef.requiresConversionOnSerialize) {
      return '    if ($fieldName != null) $target = $fieldName;';
    }

    final value = typeRef.serializeInline('$fieldName!', required: true);
    return '    if ($fieldName != null) $target = $value;';
  }
}

/// Represents an enum emitted for string `enum` keywords.
class IrEnum {
  IrEnum({required this.name, required this.values, this.description});

  final String name;
  final List<IrEnumValue> values;
  final String? description;

  String get extensionName => '${name}Json';
}

class IrEnumValue {
  IrEnumValue({required this.identifier, required this.jsonValue});

  final String identifier;
  final String jsonValue;
}

/// Represents a sealed class for mixed-type enums
class IrMixedEnum {
  IrMixedEnum({
    required this.name,
    required this.variants,
    this.description,
  });

  final String name;
  final List<IrMixedEnumVariant> variants;
  final String? description;
}

/// Represents a variant of a mixed-type enum
class IrMixedEnumVariant {
  IrMixedEnumVariant({
    required this.className,
    required this.dartType,
    required this.values,
    required this.isNullable,
  });

  final String className;
  final String dartType; // 'String', 'int', 'double', 'bool', 'null'
  final List<dynamic> values;
  final bool isNullable;
}

/// Represents a sealed union derived from `oneOf`/`anyOf` schema keywords.
class IrUnion {
  IrUnion({
    required this.name,
    required this.baseClass,
    required this.variants,
    required this.keyword,
    this.discriminator,
  });

  final String name;
  final IrClass baseClass;
  final List<IrUnionVariant> variants;
  final String keyword;
  final UnionDiscriminator? discriminator;

  bool get isDiscriminated =>
      discriminator != null && discriminator!.mapping.isNotEmpty;
}

/// Represents an individual union variant.
class IrUnionVariant {
  IrUnionVariant({
    required this.schemaPointer,
    required this.classSpec,
    this.discriminatorValue,
    required this.requiredProperties,
    required this.constProperties,
    this.primitiveType,
  });

  final String schemaPointer;
  final IrClass classSpec;
  final String? discriminatorValue;
  final Set<String> requiredProperties;
  final Map<String, Object?> constProperties;
  final TypeRef? primitiveType;
  
  /// Returns true if this variant represents a primitive type (not an object)
  bool get isPrimitive => primitiveType != null;
}

/// Metadata describing a discriminator mapping.
class UnionDiscriminator {
  UnionDiscriminator({required this.propertyName, required this.mapping});

  final String propertyName;
  final Map<String, String> mapping;
}

class IrDynamicKeyField {
  IrDynamicKeyField({
    required this.fieldName,
    required this.valueType,
    this.description,
  });

  final String fieldName;
  final TypeRef valueType;
  final String? description;

  String mapType({bool nullable = true}) {
    final base = 'Map<String, ${valueType.dartType()}>';
    return nullable ? '$base?' : base;
  }
}

class IrPatternPropertyField {
  IrPatternPropertyField({
    required this.fieldName,
    required this.valueType,
    required this.matchers,
  });

  final String fieldName;
  final TypeRef valueType;
  final List<IrPatternMatcher> matchers;

  String mapType({bool nullable = true}) {
    final base = 'Map<String, ${valueType.dartType()}>';
    return nullable ? '$base?' : base;
  }
}

class IrPatternMatcher {
  IrPatternMatcher({required this.pattern, required this.typeRef});

  final String pattern;
  final TypeRef typeRef;
}

class DependentSchemaConstraint {
  DependentSchemaConstraint({
    required this.property,
    required this.schemaPointer,
    this.typeRef,
    this.disallow = false,
  });

  final String property;
  final String schemaPointer;
  final TypeRef? typeRef;
  final bool disallow;
}

class ConditionalConstraint {
  ConditionalConstraint({
    required this.keyword,
    required this.schemaPointer,
    required List<ConstraintBranch> branches,
  }) : branches = List<ConstraintBranch>.unmodifiable(branches);

  final String keyword;
  final String schemaPointer;
  final List<ConstraintBranch> branches;
}

class ConstraintBranch {
  ConstraintBranch({
    required this.schemaPointer,
    required Set<String> requiredProperties,
  }) : requiredProperties = Set.unmodifiable(requiredProperties);

  final String schemaPointer;
  final Set<String> requiredProperties;
}

class ApplicatorConstraint {
  ApplicatorConstraint({
    required this.keyword,
    required this.schemaPointer,
    required List<ApplicatorBranch> branches,
  }) : branches = List<ApplicatorBranch>.unmodifiable(branches);

  final String keyword;
  final String schemaPointer;
  final List<ApplicatorBranch> branches;
}

class ApplicatorBranch {
  ApplicatorBranch({
    required this.schemaPointer,
    required this.typeRef,
  });

  final String schemaPointer;
  final TypeRef typeRef;
}

class JsonConditionals {
  JsonConditionals({this.ifSchema, this.thenSchema, this.elseSchema});

  final Map<String, dynamic>? ifSchema;
  final Map<String, dynamic>? thenSchema;
  final Map<String, dynamic>? elseSchema;
}

class PropertyValidationRules {
  const PropertyValidationRules({
    this.minLength,
    this.maxLength,
    this.minimum,
    this.maximum,
    this.exclusiveMinimum = false,
    this.exclusiveMaximum = false,
    this.pattern,
    this.constValue,
    this.allowedTypes,
    this.format,
    this.multipleOf,
    this.minItems,
    this.maxItems,
    this.uniqueItems,
    this.minProperties,
    this.maxProperties,
  });

  final int? minLength;
  final int? maxLength;
  final num? minimum;
  final num? maximum;
  final bool exclusiveMinimum;
  final bool exclusiveMaximum;
  final String? pattern;
  final Object? constValue;
  final List<String>? allowedTypes;
  final String? format;
  final num? multipleOf;
  final int? minItems;
  final int? maxItems;
  final bool? uniqueItems;
  final int? minProperties;
  final int? maxProperties;

  bool get hasRules =>
      minLength != null ||
      maxLength != null ||
      minimum != null ||
      maximum != null ||
      pattern != null ||
      constValue != null ||
      (allowedTypes != null && allowedTypes!.isNotEmpty) ||
      format != null ||
      multipleOf != null ||
      minItems != null ||
      maxItems != null ||
      uniqueItems != null ||
      minProperties != null ||
      maxProperties != null;
}

class IrPropertyNamesConstraint {
  const IrPropertyNamesConstraint({
    required this.schemaPointer,
    this.validation,
    this.disallow = false,
  });

  final String schemaPointer;
  final PropertyValidationRules? validation;
  final bool disallow;

  bool get hasRules => disallow || (validation?.hasRules ?? false);
}

class IrHelper {
  const IrHelper({
    required this.name,
    required this.code,
    this.imports = const <String>{},
  });

  final String name;
  final String code;
  final Set<String> imports;

  String get fileName => '${_Naming.fileNameFromType(name)}.dart';
}
