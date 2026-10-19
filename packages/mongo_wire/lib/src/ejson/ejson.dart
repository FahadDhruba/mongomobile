import 'ejson_parser.dart';
import 'ejson_writer.dart';

export 'ejson_parser.dart' show EJsonParseException, EJsonParser, parseIsoDate;
export 'ejson_writer.dart'
    show EJsonMode, EJsonWriter, formatDouble, formatIsoDate;

/// Convenience entry points for Extended JSON.
abstract final class EJson {
  /// Writes [value] as Extended JSON, pretty-printed unless [pretty] is false.
  static String stringify(
    Object? value, {
    EJsonMode mode = EJsonMode.editable,
    bool pretty = true,
  }) => EJsonWriter(mode: mode, indent: pretty ? '  ' : '').write(value);

  /// Parses a document; see [EJsonParser] for the accepted syntax.
  static Map<String, dynamic> parseDocument(
    String source, {
    bool allowEmpty = false,
  }) => EJsonParser.parseDocument(source, allowEmpty: allowEmpty);

  /// Parses any value.
  static Object? parse(String source) => EJsonParser(source).parseValue();
}
