part of 'package:schema2model/src/generator.dart';

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
  'idn-email': _FormatInfo(
    description: 'Internationalized email address as defined by RFC 6531.',
    definition:
        'https://json-schema.org/draft/2020-12/json-schema-validation.html#name-email-addresses',
  ),
  'hostname': _FormatInfo(
    description: 'Hostname as defined by RFC 1123.',
    definition:
        'https://json-schema.org/draft/2020-12/json-schema-validation.html#name-hostnames',
  ),
  'idn-hostname': _FormatInfo(
    description: 'Internationalized hostname as defined by RFC 5890.',
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

const Set<String> _formatAssertionRegistry = <String>{
  'date-time',
  'date',
  'time',
  'duration',
  'email',
  'idn-email',
  'hostname',
  'idn-hostname',
  'ipv4',
  'ipv6',
  'uri',
  'uri-reference',
  'iri',
  'iri-reference',
  'uri-template',
  'json-pointer',
  'relative-json-pointer',
  'regex',
};
