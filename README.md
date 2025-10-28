# json_schema2dart (schemamodeschema)

A `build_runner` builder that turns local JSON Schema documents into strongly typed Dart models. Feed it a `*.schema.json` file and it will emit a sibling `*.schema.dart` file with immutable classes, manual `fromJson`/`toJson` methods, local `$ref` resolution, generated enums, and sensible naming.

## Quick start

1. Add this package to your dev dependencies and configure the builder (see `build.yaml`).
2. Drop schemas somewhere under `lib/` or `example/` and give them a `*.schema.json` suffix.
3. Run `dart run build_runner build --delete-conflicting-outputs`.

You'll get Dart source files right next to your schemas. For example, the included `example/schemas/pubspec.subset.schema.json` generates `example/schemas/pubspec.subset.schema.dart` with `Pubspec`, `PubspecEnvironment`, and a `PubspecPublishTo` enum.

Because the generator writes manual JSON serializers there is no dependency on a second pass (`json_serializable`, `freezed`, etc.), so the generated models are usable immediately after the build completes.

## Current capabilities

- Detects object, array, string, number, boolean, and integer types.
- Emits immutable classes with value semantics and optional fields marked nullable.
- Reads `required` to decide nullability.
- Resolves local `$ref` targets inside `definitions`/`$defs`.
- Generates `enum`s for string-only `enum` declarations together with helper extensions for `toJson`/`fromJson`.
- Carries schema `description` fields into `///` documentation comments.

See `github-action.json` at the repo root for a real-world schema we plan to support as we add features like discriminator-based unions, `additionalProperties`, and external `$ref` resolution.

## Roadmap

- `oneOf`/`anyOf` → sealed unions (likely via an opt-in `freezed` integration).
- `allOf` composition and flattening.
- Smarter map support for `additionalProperties`/`patternProperties`.
- External `$ref` resolution (relative files and URLs).
- Format hints → rich Dart types (`date-time` → `DateTime`, `uri` → `Uri`, …).
- Optional validation hooks and friendlier doc output (examples, defaults, deprecated flags).

## Development

- Run `dart analyze` to keep the generator clean. Generated `*.schema.dart` files are excluded automatically.
- Exercise the full pipeline with `dart run build_runner build --delete-conflicting-outputs`.

Contributions and feedback are welcome—especially around covering more of the GitHub Actions workflow schema.
