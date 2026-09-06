import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

class FFLocalizations {
  const FFLocalizations(this.locale);
  final Locale locale;
  String get languageCode =>
      locale.scriptCode == 'Hant' ? 'zh_Hant' : locale.languageCode;
  static FFLocalizations of(BuildContext context) =>
      Localizations.of<FFLocalizations>(context, FFLocalizations)!;
}

class FFLocalizationsDelegate extends LocalizationsDelegate<FFLocalizations> {
  const FFLocalizationsDelegate();
  @override
  bool isSupported(Locale locale) => ['en', 'zh'].contains(locale.languageCode);
  @override
  Future<FFLocalizations> load(Locale locale) =>
      SynchronousFuture(FFLocalizations(locale));
  @override
  bool shouldReload(FFLocalizationsDelegate old) => false;
}
