import 'dart:typed_data';

/// An IEEE 754-2008 decimal128 value stored as its 16 raw bytes
/// (little endian, as in BSON).
///
/// String conversion follows the BSON Decimal128 specification, so values
/// such as `NaN`, `-Infinity`, `1.50` and `1E+3` keep their exact form.
final class Decimal128 {
  Decimal128.fromBytes(List<int> bytes) : bytes = Uint8List.fromList(bytes) {
    if (this.bytes.length != 16) {
      throw ArgumentError('A Decimal128 has 16 bytes, got ${bytes.length}');
    }
  }

  final Uint8List bytes;

  static const int _exponentBias = 6176;
  static const int _exponentMax = 6111;
  static const int _exponentMin = -6176;
  static const int _maxDigits = 34;
  static final BigInt _mask64 = (BigInt.one << 64) - BigInt.one;
  static final BigInt _maxCoefficient = BigInt.from(10).pow(34) - BigInt.one;

  BigInt get _low => _readU64(0);
  BigInt get _high => _readU64(8);

  BigInt _readU64(int offset) {
    var v = BigInt.zero;
    for (var i = 7; i >= 0; i--) {
      v = (v << 8) | BigInt.from(bytes[offset + i]);
    }
    return v;
  }

  static Decimal128 _fromParts(BigInt high, BigInt low) {
    final b = Uint8List(16);
    for (var i = 0; i < 8; i++) {
      b[i] = ((low >> (8 * i)) & BigInt.from(0xff)).toInt();
      b[8 + i] = ((high >> (8 * i)) & BigInt.from(0xff)).toInt();
    }
    return Decimal128.fromBytes(b);
  }

  /// Parses a decimal string. Accepts `NaN`, `Inf`, `Infinity` (with an
  /// optional sign), plain decimals and scientific notation. Throws a
  /// [FormatException] when the value can't be stored without rounding.
  factory Decimal128.parse(String input) {
    final s = input.trim();
    final lower = s.toLowerCase();
    final negative = s.startsWith('-');
    final unsigned =
        (s.startsWith('-') || s.startsWith('+')) ? lower.substring(1) : lower;
    final sign = negative ? BigInt.one << 63 : BigInt.zero;
    if (unsigned == 'nan') {
      return _fromParts(BigInt.from(0x7c00) << 48, BigInt.zero);
    }
    if (unsigned == 'inf' || unsigned == 'infinity') {
      return _fromParts(sign | (BigInt.from(0x7800) << 48), BigInt.zero);
    }
    final m = RegExp(r'^(\d*)(?:\.(\d*))?(?:e([+-]?\d+))?$').firstMatch(unsigned);
    if (m == null ||
        ((m.group(1) ?? '').isEmpty && (m.group(2) ?? '').isEmpty)) {
      throw FormatException('Invalid Decimal128 string', input);
    }
    final intPart = m.group(1) ?? '';
    final fracPart = m.group(2) ?? '';
    var exponent = int.parse(m.group(3) ?? '0') - fracPart.length;
    var digits = (intPart + fracPart).replaceFirst(RegExp(r'^0+'), '');
    if (digits.isEmpty) digits = '0';

    // Fold the value into range by dropping trailing zeros or adding them,
    // which never changes the numeric value.
    while (digits.length > _maxDigits && digits.endsWith('0')) {
      digits = digits.substring(0, digits.length - 1);
      exponent++;
    }
    if (digits.length > _maxDigits) {
      throw FormatException(
          'Decimal128 holds at most 34 significant digits', input);
    }
    while (exponent > _exponentMax && digits.length < _maxDigits) {
      if (digits == '0') {
        exponent = _exponentMax;
        break;
      }
      digits = '${digits}0';
      exponent--;
    }
    while (exponent < _exponentMin && digits.endsWith('0') && digits != '0') {
      digits = digits.substring(0, digits.length - 1);
      exponent++;
    }
    if (digits == '0' && exponent < _exponentMin) exponent = _exponentMin;
    if (exponent > _exponentMax || exponent < _exponentMin) {
      throw FormatException('Decimal128 exponent out of range', input);
    }

    final coefficient = BigInt.parse(digits);
    final biased = BigInt.from(exponent + _exponentBias);
    final high = sign | (biased << 49) | (coefficient >> 64);
    final low = coefficient & _mask64;
    return _fromParts(high, low);
  }

  bool get isNegative => (_high >> 63) == BigInt.one;

  bool get isNaN => (_high >> 58) & BigInt.from(0x1f) == BigInt.from(0x1f);

  bool get isInfinite =>
      (_high >> 58) & BigInt.from(0x1f) == BigInt.from(0x1e);

  @override
  String toString() {
    final high = _high;
    final low = _low;
    final sign = isNegative ? '-' : '';
    final combination = ((high >> 58) & BigInt.from(0x1f)).toInt();
    int biasedExponent;
    BigInt coefficient;
    if ((combination >> 3) == 3) {
      if (combination == 0x1e) return '${sign}Infinity';
      if (combination == 0x1f) return 'NaN';
      biasedExponent = ((high >> 47) & BigInt.from(0x3fff)).toInt();
      // The implied leading bits make the coefficient exceed 34 digits,
      // which the specification treats as zero.
      coefficient = BigInt.zero;
    } else {
      biasedExponent = ((high >> 49) & BigInt.from(0x3fff)).toInt();
      coefficient =
          ((high & ((BigInt.one << 49) - BigInt.one)) << 64) | low;
      if (coefficient > _maxCoefficient) coefficient = BigInt.zero;
    }
    final exponent = biasedExponent - _exponentBias;
    final digits = coefficient.toString();
    final adjusted = exponent + digits.length - 1;

    if (exponent > 0 || adjusted < -6) {
      final sb = StringBuffer(sign)..write(digits[0]);
      if (digits.length > 1) sb.write('.${digits.substring(1)}');
      sb.write('E${adjusted >= 0 ? '+' : ''}$adjusted');
      return sb.toString();
    }
    if (exponent == 0) return '$sign$digits';
    final pointPos = digits.length + exponent;
    if (pointPos > 0) {
      return '$sign${digits.substring(0, pointPos)}.${digits.substring(pointPos)}';
    }
    return '${sign}0.${'0' * -pointPos}$digits';
  }

  /// A double approximation, used for display and sorting only.
  double toDouble() => double.tryParse(toString()) ?? double.nan;

  @override
  bool operator ==(Object other) {
    if (other is! Decimal128) return false;
    for (var i = 0; i < 16; i++) {
      if (bytes[i] != other.bytes[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(bytes);
}
