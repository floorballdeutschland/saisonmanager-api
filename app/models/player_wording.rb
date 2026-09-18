# Geschlechtergerechte Bezeichnungen fuer die Person, um die eine Mail geht.
# `players.gender` kennt „M", „W" und „D"; ein Teil des Bestands hat gar keinen
# Wert. Divers und leer teilen sich hier dieselbe neutrale Form: Sie wird fuer
# den unbekannten Fall ohnehin gebraucht, und sie verraet dem Vereinspostfach
# nicht, dass bei genau diesem Profil „divers" hinterlegt ist.
#
# Die Formen stehen ausgeschrieben in einer Tabelle, statt aus Artikel und Nomen
# zusammengesetzt zu werden. Die deutsche Deklination trifft hier auf zwei
# Genera und eine Umschreibung („die spielende Person"); eine Regel dafuer waere
# schwerer zu pruefen als die Tabelle, die sie ersetzt. Jede Form wird in
# mindestens einer Vorlage verwendet, neue kommen mit ihrer Verwendung dazu.
#
# Fachbegriffe bleiben unangetastet: „Spielerfreigabe", „Spielerprofil" und die
# generischen Pluralaussagen („nimmt keine Spieler mehr auf") bezeichnen keine
# konkrete Person und werden deshalb nicht gegendert.
class PlayerWording
  NEUTRAL = :neutral

  FORMS = {
    'M' => {
      noun: 'Spieler',
      nominative: 'der Spieler',
      genitive: 'des Spielers',
      by_agent: 'vom Spieler',
      accusative: 'den Spieler',
      following_nominative: 'der folgende Spieler',
      following_accusative: 'den folgenden Spieler',
      relative_nominative: 'der',
      as_role: 'als Spieler'
    }.freeze,
    'W' => {
      noun: 'Spielerin',
      nominative: 'die Spielerin',
      genitive: 'der Spielerin',
      by_agent: 'von der Spielerin',
      accusative: 'die Spielerin',
      following_nominative: 'die folgende Spielerin',
      following_accusative: 'die folgende Spielerin',
      relative_nominative: 'die',
      as_role: 'als Spielerin'
    }.freeze,
    NEUTRAL => {
      noun: 'Spieler*in',
      nominative: 'die spielende Person',
      genitive: 'der spielenden Person',
      by_agent: 'von der spielenden Person',
      accusative: 'die spielende Person',
      following_nominative: 'die folgende spielende Person',
      following_accusative: 'die folgende spielende Person',
      relative_nominative: 'die',
      as_role: 'als spielende Person'
    }.freeze
  }.freeze

  def self.for(player)
    new(player&.gender)
  end

  def initialize(gender)
    @forms = FORMS.fetch(gender.to_s.strip.upcase, FORMS[NEUTRAL])
  end

  # `fetch` und nicht `[]`: Die Zugriffe entstehen aus den Schluesseln der
  # neutralen Zeile. Fehlte einer in der maennlichen oder weiblichen (ein
  # Tippfehler genuegt), lieferte `[]` nil, und in der Mail fehlte das Wort --
  # nur fuer dieses Geschlecht, also genau dort, wo niemand hinsieht.
  FORMS[NEUTRAL].each_key do |form|
    define_method(form) { @forms.fetch(form) }
  end

  # Fuer den Satzanfang. Nicht String#capitalize: das schreibt den Rest klein,
  # aus „die spielende Person" wuerde „Die spielende person".
  def capitalized(form)
    public_send(form).sub(/\A./, &:upcase)
  end
end
