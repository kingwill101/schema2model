# schema2model

[![Pub Version](https://img.shields.io/pub/v/schema2model)](https://pub.dev/packages/schema2model)
[![License](https://img.shields.io/github/license/kingwill101/schema2model)](LICENSE)

**Production-ready JSON Schema to Dart code generator with full JSON Schema 2020-12 support.**

Generate strongly-typed, immutable Dart models from JSON schemas with runtime validation, security controls, and excellent developer experience.

## ✨ Features

- 🔧 **Build Runner Integration** - Automatic code generation during development
- 📦 **Standalone API** - Programmatic generation for CLI tools and custom builds
- ✅ **Full JSON Schema 2020-12 Compliance** - All core applicators and keywords
- 🛡️ **Security-First** - Offline-by-default with configurable allowlists
- 🎯 **Type Safety** - Immutable classes with proper null safety
- ⚡ **Validation Helpers** - Optional runtime validation with detailed errors
- 🔗 **Reference Resolution** - `$ref`, `$anchor`, `$dynamicAnchor` support
- 📝 **Rich Documentation** - Schema descriptions become doc comments
- 🎨 **Extension Annotations** - Preserve `x-*` custom metadata

## 🚀 Quick Start

### Using build_runner (Recommended)

**1. Add dependency**

```yaml
# pubspec.yaml
dev_dependencies:
  schema2model: ^latest_version
  build_runner: ^2.4.0
```

**2. Configure builder**

```yaml
# build.yaml
targets:
  $default:
    builders:
      schema2model|schema_builder:
        options:
          emit_validation_helpers: true
        generate_for:
          - lib/schemas/**/*.json
```

**3. Add schema**

```json
// lib/schemas/person.json
{
  "type": "object",
  "properties": {
    "name": {"type": "string"},
    "age": {"type": "integer", "minimum": 0}
  },
  "required": ["name"]
}
```

**4. Generate**

```bash
dart run build_runner build --delete-conflicting-outputs
```

**5. Use**

```dart
import 'package:your_package/schemas/person.dart';

void main() {
  final person = Person(name: 'Alice', age: 30);
  print(person.toJson());
  
  person.validate(); // Runtime validation
}
```

### Using the API

```dart
import 'package:schema2model/schema2model.dart';

void main() {
  final schema = {
    'type': 'object',
    'properties': {
      'name': {'type': 'string'},
    },
  };

  final generator = SchemaGenerator(
    options: SchemaGeneratorOptions(
      rootClassName: 'Person',
      emitValidationHelpers: true,
    ),
  );

  final code = generator.generate(schema);
  print(code); // Generated Dart code
}
```

## 🌟 Advanced Features

### Helper Functions

Generate convenient top-level parse/stringify functions (programmatic API):

```dart
final generator = SchemaGenerator(
  options: const SchemaGeneratorOptions(
    generateHelpers: true,
  ),
);
```

```dart
// Generated code includes:
Person personFromJson(String str) => Person.fromJson(json.decode(str));
String personToJson(Person data) => json.encode(data.toJson());

// Usage:
final person = personFromJson('{"name": "Alice", "age": 30}');
print(personToJson(person));
```

### Sealed Class Unions (oneOf/anyOf)

Type-safe union types with exhaustive pattern matching:

```json
{
  "oneOf": [
    {"type": "string"},
    {"type": "integer"},
    {"type": "object", "properties": {"id": {"type": "string"}}}
  ]
}
```

```dart
// Generated sealed class hierarchy:
sealed class Value {}
class ValueString extends Value { final String value; }
class ValueInteger extends Value { final int value; }
class ValueObject extends Value { final String id; }

// Type-safe pattern matching:
String describe(Value v) => switch (v) {
  ValueString(value: final s) => 'String: $s',
  ValueInteger(value: final i) => 'Int: $i',
  ValueObject(id: final id) => 'Object: $id',
};
```

### Reserved Keyword Handling

Automatically handles Dart reserved words:

```json
{
  "properties": {
    "class": {"type": "string"},
    "const": {"type": "integer"}
  }
}
```

```dart
// Generated with safe field names and explicit mapping in toJson/fromJson:
class MyClass {
  final String class$;
  final int? const$;

  const MyClass({
    required this.class$,
    this.const$,
  });

  factory MyClass.fromJson(Map<String, dynamic> json) {
    final class$ = json['class'] as String;
    final const$ = json['const'] as int?;
    return MyClass(class$: class$, const$: const$);
  }

  Map<String, dynamic> toJson() => {
    'class': class$,
    if (const$ != null) 'const': const$,
  };
}
```

### Usage Documentation

Usage docs are available via the programmatic API (not exposed in the build
runner options yet):

```dart
final generator = SchemaGenerator(
  options: const SchemaGeneratorOptions(
    emitUsageDocs: true,
    emitReadmeSnippets: true,
  ),
);
```

## ⚙️ Configuration Options

### Build Runner Options

Build runner currently supports a focused set of options:

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `root_class` | String | derived | Override the root class name |
| `prefer_camel_case` | bool | `true` | Convert property names to camelCase |
| `emit_docs` | bool | `true` | Emit doc comments from schema metadata |
| `header` | String | _none_ | Custom file header |
| `single_file_output` | bool | `false` | Emit a single `.dart` file vs split parts |
| `emit_validation_helpers` | bool | `true` | Generate `validate()` methods |
| `enable_format_hints` | bool | `false` | Map known `format` values to richer Dart types |
| `enable_format_assertions` | bool | `false` | Enforce `format` validation for registry formats |
| `enable_content_keywords` | bool | `false` | Enable `contentEncoding`/`contentMediaType` typing |
| `enable_content_validation` | bool | `false` | Validate decoded content against `contentSchema` |
| `emit_usage_docs` | bool | `false` | Emit usage docs in generated output |
| `generate_helpers` | bool | `false` | Emit top-level JSON helper functions |
| `emit_readme_snippets` | bool | `false` | Emit README snippets in multi-file plans |
| `allow_network_refs` | bool | `false` | Permit network `$ref` resolution |
| `network_cache_path` | String | `.dart_tool/schema2model/cache` | Cache directory for fetched refs |
| `default_dialect` | String | `latest` | Dialect URI or `none` to require explicit `$schema` |
| `include_globs` | String or List<String> | `**/*.schema.json`, `**/*.json` | File globs to include |

Example `build.yaml`:

```yaml
targets:
  $default:
    builders:
      schema2model|schema_builder:
        options:
          emit_validation_helpers: true
          default_dialect: "latest"
          include_globs:
            - lib/schemas/**/*.json
        generate_for:
          - lib/schemas/**/*.json
```

`include_globs` is an additional filter applied inside the builder; `generate_for`
still controls what build_runner feeds into the builder.

For advanced options (format hints, usage docs, custom loaders, security
allowlists), use the programmatic API below.

### Programmatic API Options

```dart
SchemaGeneratorOptions(
  // Code generation
  rootClassName: 'MyClass',
  preferCamelCase: true,
  emitDocumentation: true,
  singleFileOutput: false,
  generateHelpers: true,
  emitUsageDocs: true,
  emitReadmeSnippets: true,

  // Validation & types
  emitValidationHelpers: true,
  enableFormatHints: true,
  enableFormatAssertions: false,
  enableContentKeywords: false,
  enableContentValidation: false,

  // Security (see REFERENCE_GOVERNANCE.md)
  allowNetworkRefs: false,
  allowedNetworkHosts: ['schemas.company.com'],
  allowedFilePaths: ['/workspace/schemas'],
  maxReferenceDepth: 50,
  networkCachePath: '.dart_tool/schema2model/cache',
  defaultDialect: SchemaDialect.latest,
  supportedDialects: SchemaDialect.defaultDialectRegistry,

  // Custom resolution
  documentLoader: customLoader,
  onWarning: (msg) => print(msg),
)
```

## 📋 Supported JSON Schema Features

### Core Types ✅
- Objects, arrays, strings, numbers, integers, booleans
- Nullable types and optional properties
- Enums with type-safe extensions
- **Mixed-type enums** - Sealed classes for heterogeneous enum values
- Const values

### Validation ✅
- String: `minLength`, `maxLength`, `pattern`, `format` (assertions opt-in)
- Number: `minimum`, `maximum`, `multipleOf`
- Array: `minItems`, `maxItems`, `uniqueItems`, `contains`, `minContains`, `maxContains`
- Object: `required`, `minProperties`, `maxProperties`, `propertyNames`

### Composition ✅
- `allOf` - Type intersection
- `oneOf` - **Discriminated unions with sealed classes**
- `anyOf` - **Flexible unions with sealed classes**
- `not` - Type negation
- **Sealed class unions** - Type-safe union types with exhaustive pattern matching

### Applicators ✅
- `properties`, `additionalProperties`, `patternProperties`
- `items`, `prefixItems` (2020-12)
- `dependentSchemas`, `dependentRequired`
- `unevaluatedProperties`, `unevaluatedItems` (2020-12)
- `if`/`then`/`else` conditionals

### References ✅
- `$ref` - Schema references
- `$anchor` - Named anchors
- `$dynamicAnchor`/`$dynamicRef` - Dynamic resolution
- `$id` - Schema identification
- Circular reference detection

### Metadata ✅
- `title`, `description` → Doc comments
- `deprecated` → `@Deprecated` annotation
- `default`, `examples` → Preserved
- `x-*` extensions → Custom annotations

### Dialects ✅
- JSON Schema Draft 2020-12 (full support)
- Draft 2019-09, Draft-07, Draft-06, Draft-04
- Configurable default dialect

### Limitations ⚠️
- `contentMediaType`, `contentEncoding`, `contentSchema` - Content decoding supported; contentSchema validation limited to JSON media types
- Format hints require `enableFormatHints: true`
- Format assertions require `enableFormatAssertions: true`
- Content validation requires `enableContentValidation: true`

See [LIMITATIONS.md](LIMITATIONS.md) for details and workarounds.

## 📚 Documentation

- **[Examples](example/)** - Build runner and standalone API examples
- **[Reference Governance](REFERENCE_GOVERNANCE.md)** - Security and reference resolution
- **[Anchor Support](ANCHOR_SUPPORT.md)** - Using `$anchor` and `$dynamicAnchor`
- **[Limitations](LIMITATIONS.md)** - Unsupported features and workarounds
- **[Changelog](CHANGELOG.md)** - Recent changes and migration guide

## 🎯 Examples

Check out the [`example/`](example/) directory for:

- **[build_runner_example](example/build_runner_example/)** - Full build runner setup
- **[schema2model_example.dart](example/schema2model_example.dart)** - Standalone API example
- **[helper_functions_example.dart](example/helper_functions_example.dart)** - Top-level helpers
- **[sealed_unions_example.dart](example/sealed_unions_example.dart)** - `oneOf`/`anyOf` unions
- **[format_assertions_example.dart](example/format_assertions_example.dart)** - `format` validation
- **[content_validation_example.dart](example/content_validation_example.dart)** - `contentSchema` validation
- **[reserved_keywords_example.dart](example/reserved_keywords_example.dart)** - Reserved words
- **[Real schemas](example/schemas/)** - GitHub workflows, actions, and more

## 🔒 Security

schema2model is **secure by default**:

- ✅ **Offline-by-default** - No network access without explicit opt-in
- ✅ **Allowlists** - Fine-grained control over hosts and file paths
- ✅ **Cycle detection** - Prevents infinite recursion
- ✅ **Depth limits** - Configurable maximum reference depth
- ✅ **Clear errors** - Actionable security messages

See [REFERENCE_GOVERNANCE.md](REFERENCE_GOVERNANCE.md) for full details.

## 🆚 Comparison

| Feature | schema2model | quicktype | json_serializable |
|---------|-------------|-----------|-------------------|
| JSON Schema 2020-12 | ✅ Full | ⚠️ Partial | ❌ No |
| Build runner | ✅ | ❌ | ✅ |
| Standalone API | ✅ | ✅ | ❌ |
| Runtime validation | ✅ | ❌ | ❌ |
| Security controls | ✅ | ❌ | N/A |
| Circular refs | ✅ | ✅ | ⚠️ |
| oneOf/anyOf | ✅ | ✅ | ❌ |
| Documentation | ✅ Excellent | ⚠️ Basic | ✅ Good |

## 🛠️ Development

### Setup

```bash
git clone https://github.com/kingwill101/schema2model.git
cd schema2model
dart pub get
```

### Running Tests

```bash
dart test
```

### Code Quality

```bash
dart analyze
dart format .
```

### Building Examples

```bash
cd example/build_runner_example
dart pub get
dart run build_runner build --delete-conflicting-outputs
dart run
```

## 🤝 Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Make your changes with tests
4. Run `dart analyze` and `dart test`
5. Submit a pull request

See [CONTRIBUTING.md](CONTRIBUTING.md) for detailed guidelines.

## 📝 License

MIT License - see [LICENSE](LICENSE) for details.

## 🙏 Acknowledgments

- Benchmarked against [quicktype](https://github.com/quicktype/quicktype)
- Inspired by the JSON Schema community
- Built with ❤️ for the Dart ecosystem

## 📞 Support

- 🐛 **Issues**: [GitHub Issues](https://github.com/yourusername/schema2model/issues)
- 💬 **Discussions**: [GitHub Discussions](https://github.com/yourusername/schema2model/discussions)
- 📧 **Email**: support@example.com

---

**Made with ❤️ by the schema2model team**
