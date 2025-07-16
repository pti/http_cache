
class HttpDate {

  static const _monthsByAbbr = {
    'Jan': DateTime.january,
    'Feb': DateTime.february,
    'Mar': DateTime.march,
    'Apr': DateTime.april,
    'May': DateTime.may,
    'Jun': DateTime.june,
    'Jul': DateTime.july,
    'Aug': DateTime.august,
    'Sep': DateTime.september,
    'Oct': DateTime.october,
    'Nov': DateTime.november,
    'Dec': DateTime.december,
  };

  /// Doesn't support obsolete formats.
  /// If depedency to dart:io would be possible, then its HttpDate could be used instead.
  ///
  /// https://www.rfc-editor.org/rfc/rfc9110.html#http.date
  static DateTime? tryParse(String? value) {
    if (value == null || value.length != 29) {
      return null;
    }

    // Tue, 28 Feb 2022 22:22:22 GMT
    // <day-name>, <day> <month> <year> <hour>:<minute>:<second> GMT, e.g. "Tue, 28 Feb 2022 22:22:22 GMT"
    try {
      return DateTime.utc(
        int.parse(value.substring(12, 16)), // year
        _monthsByAbbr[value.substring( 8, 11)]!,   // month
        int.parse(value.substring( 5,  7)), // day
        int.parse(value.substring(17, 19)), // hour
        int.parse(value.substring(20, 22)), // minute
        int.parse(value.substring(23, 25)), // second
      );

    } on FormatException catch (_) {
      return null;
    }
  }

  HttpDate._internal();
}
