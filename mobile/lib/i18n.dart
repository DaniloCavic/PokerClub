/// Jezik aplikacije: engleski (podrazumevano) ili srpski — bira se u Profile.
class Lang {
  static String code = 'en';
  static bool get sr => code == 'sr';
}

/// Tekst na izabranom jeziku: tr('Engleski', 'Srpski').
String tr(String en, String sr) => Lang.code == 'sr' ? sr : en;
