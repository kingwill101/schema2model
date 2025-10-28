import 'package:build/build.dart';

import 'src/schema_to_dart_builder.dart';

Builder schemaToDartBuilder(BuilderOptions options) {
  return SchemaToDartBuilder.fromOptions(options);
}
