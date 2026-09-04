# Wettbewerbszugehoerigkeit einer Liga (#603): Ligamodus, Wettbewerbsgruppe und
# der Wettbewerbsschluessel (Altersklasse plus Feldgroesse), auf dem der
# Geltungsbereich einer Spielersperre steht.
#
# Diese Datei ist die einzige Stelle, die entscheidet, welcher Ligamodus zu
# welchem Wettbewerb gehoert. Wer eine Regel dazu sucht, sucht hier.
module LeagueCompetition
  extend ActiveSupport::Concern

  # Ligamodi des Liga-Formulars. `playoff` verhaelt sich in Spielplan und
  # Darstellung wie `cup` (Ausscheidungswettbewerb, keine Ligaklasse), ist aber
  # die Fortsetzung einer bestehenden Liga und kein eigener Wettbewerb.
  #
  # Der Unterschied traegt eine fachliche Entscheidung: Eine Spielersperre im
  # Ligaspielbetrieb gilt in den Playoffs weiter, im Pokal nicht, weil der
  # Pokal separat gefuehrt wird. Solange Playoffs als `cup` angelegt sind, kann
  # das keine Pruefung auseinanderhalten.
  #
  # Altligen tragen keinen Modus (1597 Datensaetze, NULL) und leiten ihren Typ
  # aus `league_category_id` ab, siehe League#league_type. Daher allow_blank.
  MODI = %w[league cup playoff champ].freeze

  # Ausscheidungswettbewerbe: Turnierbaum statt Tabelle, keine Ligaklasse.
  KNOCKOUT_MODI = %w[cup playoff].freeze

  # Wettbewerbsgruppen fuer den Geltungsbereich einer Spielersperre.
  GROUP_LIGA          = 'liga'.freeze
  GROUP_POKAL         = 'pokal'.freeze
  GROUP_MEISTERSCHAFT = 'meisterschaft'.freeze
  COMPETITION_GROUPS  = [GROUP_LIGA, GROUP_POKAL, GROUP_MEISTERSCHAFT].freeze

  # `playoff` liegt bewusst bei `liga`: Playoffs und Playdowns sind dieselbe
  # Liga in kleinerer Besetzung. `champ` (DM/Endrunde) bleibt eine eigene
  # Gruppe, obwohl auch sie fachlich eine Fortfuehrung ist -- die Regel dazu
  # steckt in der Vorbelegung des Sperrformulars und nicht in dieser Zuordnung,
  # damit ein abweichender Einzelfall ein Klick bleibt und keine Migration.
  GROUP_BY_MODUS = {
    'league'  => GROUP_LIGA,
    'playoff' => GROUP_LIGA,
    'cup'     => GROUP_POKAL,
    'champ'   => GROUP_MEISTERSCHAFT
  }.freeze

  included do
    validates :league_modus, inclusion: { in: MODI }, allow_blank: true
  end

  # Ausscheidungswettbewerb (Pokal oder Playoff/Playdown).
  def knockout?
    KNOCKOUT_MODI.include?(league_type.to_s)
  end

  # Wettbewerbsgruppe fuer den Geltungsbereich einer Spielersperre.
  #
  # Ein unbekannter oder fehlender Modus ergibt `liga`. Das ist die sichere
  # Richtung: Eine Sperre im Ligaspielbetrieb greift dann eher zu weit als zu
  # kurz. Ein gesperrter Spieler, der wegen eines leeren Feldes auflaufen darf,
  # waere der schwerere Fehler.
  def competition_group
    GROUP_BY_MODUS.fetch(league_type.to_s, GROUP_LIGA)
  end

  # Die Liga, aus der Tabellenpunkte und Lizenzen uebernommen werden -- bei
  # einem Playoff also die Hauptrunde. `unscoped`, weil der default_scope der
  # Liga sortiert und hier nur ein Datensatz gesucht wird.
  def preround_league
    return nil if league_id_preround.blank? || league_id_preround == id

    @preround_league ||= League.unscoped.find_by(id: league_id_preround)
  end

  # Altersklasse und Feldgroesse bilden zusammen mit der Wettbewerbsgruppe den
  # Wettbewerbsschluessel einer Sperre. Beide Felder bleiben an Playoff- und
  # Endrundenligen erfahrungsgemaess oft leer (Saison 17: 21 der 28 Luecken
  # lagen bei cup/champ-Ligen), weil diese Ligen mitten in der Saison entstehen
  # und schnell angelegt werden. Fehlt der Wert, gilt der der Hauptrunde.
  def effective_age_group
    age_group.presence || preround_league&.age_group.presence
  end

  def effective_field_size
    field_size.presence || preround_league&.field_size.presence
  end
end
