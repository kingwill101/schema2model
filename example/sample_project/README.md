# schema2model sample project

This mini project shows how to enable validation helper generation through `build.yaml`.

## Files of interest

- `pubspec.yaml` – depends on the root package via a path dependency.
- `build.yaml` – enables `emit_validation_helpers` and narrows inputs to `lib/schemas/**/*.json`.
- `lib/schemas/todo_list.json` – a small schema with `contains` + `minContains`/`maxContains`.
- `bin/main.dart` – uses the generated `TodoList` model and runs validation.

## Usage

```bash
cd example/sample_project
dart pub get
dart run build_runner build --delete-conflicting-outputs
```

After the build finishes, the generated sources live next to the schema:

```
lib/
  schemas/
    todo_list.json
    todo_list.dart
    todo_list_generated/
      ...split files and validation helpers...
```

You can then execute the sample program:

```bash
dart run bin/main.dart
```

The `build.yaml` options apply globally, so any additional schemas you drop under
`lib/schemas/` will also emit validation helpers by default.
