part of 'package:schemamodeschema/src/generator.dart';

/// Intermediate representation root describing the generated model set.
class SchemaIr {
  SchemaIr({
    required this.rootClass,
    required this.classes,
    required this.enums,
    required this.unions,
    required this.helpers,
  });

  final IrClass rootClass;
  final List<IrClass> classes;
  final List<IrEnum> enums;
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
  });

  final String name;
  final String? description;
  final List<IrProperty> properties;
  bool allowAdditionalProperties;
  IrDynamicKeyField? additionalPropertiesField;
  IrPatternPropertyField? patternPropertiesField;
  final JsonConditionals? conditionals;
  String? superClassName;
}

/// Represents a property on an [IrClass].
class IrProperty {
  IrProperty({
    required this.jsonName,
    required this.fieldName,
    required this.typeRef,
    required this.isRequired,
    this.description,
    this.format,
    this.validation,
    this.isDeprecated = false,
    this.defaultValue,
    this.examples = const <Object?>[],
  });

  final String jsonName;
  final String fieldName;
  final TypeRef typeRef;
  final bool isRequired;
  final String? description;
  final String? format;
  final PropertyValidationRules? validation;
  final bool isDeprecated;
  final Object? defaultValue;
  final List<Object?> examples;

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
  });

  final String schemaPointer;
  final IrClass classSpec;
  final String? discriminatorValue;
  final Set<String> requiredProperties;
  final Map<String, Object?> constProperties;
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
  });

  final int? minLength;
  final int? maxLength;
  final num? minimum;
  final num? maximum;
  final bool exclusiveMinimum;
  final bool exclusiveMaximum;
  final String? pattern;
  final Object? constValue;

  bool get hasRules =>
      minLength != null ||
      maxLength != null ||
      minimum != null ||
      maximum != null ||
      pattern != null ||
      constValue != null;
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
