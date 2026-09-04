# Spielersperre mit Geltungsbereich und Dauer (#508, erweitert in #604).
#
# Zwei Achsen, die unabhaengig voneinander sind:
#
# * **Dauer**: bis zu einem Datum (`valid_until`) oder ueber eine Anzahl von
#   Spielen (`games_total`). Beides gleichzeitig ist erlaubt und sinnvoll: Das
#   Datum ist dann die Obergrenze, damit eine Sperre nicht ueber Saisongrenzen
#   haengen bleibt, wenn die restlichen Spiele nie stattfinden.
# * **Geltungsbereich** (`scope_kind`): alles, ein Wettbewerb, eine Liga oder
#   eine Mannschaft.
#
# Der Wettbewerb ist die Kombination aus Altersklasse, Feldgroesse und
# Wettbewerbsgruppe (siehe LeagueCompetition). Damit gilt eine Sperre im
# Ligaspielbetrieb auch in den Playoffs, aber nicht im Pokal, der separat
# gefuehrt wird.
class PlayerSuspension < ApplicationRecord
  belongs_to :player

  # Der ganze Spieler. Blockiert zusaetzlich JEDEN neuen Lizenzantrag, wirkt
  # also weit ueber den eigenen Spielbetrieb hinaus -- deshalb darf sie nur der
  # Heimatverband setzen (siehe Admin::PlayerSuspensionsController).
  SCOPE_ALL = 'all'.freeze
  # Altersklasse + Feldgroesse + Wettbewerbsgruppen.
  SCOPE_COMPETITION = 'competition'.freeze
  # Genau eine Liga.
  SCOPE_LEAGUE = 'league'.freeze
  # Genau eine Mannschaft, also eine einzelne Team-Lizenz. Wirkt in jedem
  # Wettbewerb dieser Mannschaft, weil eine Lizenz ueber cup_leagues auch deren
  # Pokalspiele deckt.
  SCOPE_TEAM = 'team'.freeze
  SCOPE_KINDS = [SCOPE_ALL, SCOPE_COMPETITION, SCOPE_LEAGUE, SCOPE_TEAM].freeze

  # Vorbelegung des Wettbewerbs-Geltungsbereichs: Ligaspielbetrieb und
  # DM/Endrunde, nicht der Pokal. DM und Endrunden sind Fortfuehrungen des
  # Ligaspielbetriebs (Entscheidung vom 04.09.2026); dass sie trotzdem eine
  # eigene Gruppe sind, haelt den Einzelfall abwaehlbar.
  DEFAULT_COMPETITION_GROUPS = [League::GROUP_LIGA, League::GROUP_MEISTERSCHAFT].freeze

  # Ohne Angabe gilt dieselbe Ableitung wie bei der Migration des Bestands:
  # eine Sperre mit Mannschaft ist eine Team-Sperre, eine ohne gilt fuer alles.
  # Damit scheitert kein Datenlauf und kein Aufruf aus der Konsole am neuen
  # Pflichtfeld, und die Bedeutung bleibt die von vor #604.
  #
  # Zweimal registriert, und das mit Absicht: `before_validation`, damit die
  # Inklusionspruefung einen Wert sieht, und `before_create` fuer die Wege, die
  # mit `save(validate: false)` an den Validierungen vorbeigehen (Datenlauf,
  # Konsole, merge_into!). Die Spalte ist NOT NULL, ein nil darf sie also auf
  # keinem Weg erreichen. `||=` macht die zweite Ausfuehrung wirkungslos.
  before_validation :derive_scope_kind, on: :create
  before_create :derive_scope_kind

  validates :valid_from, presence: true
  validates :scope_kind, inclusion: { in: SCOPE_KINDS }
  validates :games_total, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validate :valid_until_after_valid_from
  validate :duration_given
  validate :scope_target_given

  scope :active, -> { where(lifted_at: nil) }
  # Sperren, die jeden Lizenzantrag blockieren. Bis #604 war das gleichbedeutend
  # mit `team_id IS NULL`; seit es Wettbewerbssperren gibt, ist es das nicht
  # mehr -- die tragen ebenfalls kein Team.
  scope :player_wide, -> { where(scope_kind: SCOPE_ALL) }
  scope :games_based, -> { where.not(games_total: nil) }
  # Ohne Enddatum laeuft eine Sperre, bis die Spiele abgesessen sind.
  scope :covering, ->(date) { where('valid_from <= :d AND (valid_until IS NULL OR valid_until >= :d)', d: date) }
  scope :due, ->(date) { active.where('valid_until IS NOT NULL AND valid_until < ?', date) }

  def player_wide?
    scope_kind == SCOPE_ALL
  end

  def active?
    lifted_at.nil?
  end

  def games_based?
    games_total.present?
  end

  def remaining_games
    return nil unless games_based?

    [games_total - games_served.to_i, 0].max
  end

  def served_out?
    games_based? && games_served.to_i >= games_total
  end

  # Laeuft die Sperre an diesem Tag?
  def window_covers?(date)
    return false if valid_from.blank? || valid_from > date

    valid_until.blank? || valid_until >= date
  end

  # Greift die Sperre in dieser Liga? Maßgeblich ist die Liga, in der gespielt
  # bzw. lizenziert wird, nicht die Stammliga der Mannschaft: Ein Pokalspiel
  # laeuft in der Pokalliga, auch wenn die Mannschaft in einer Liga zu Hause ist.
  def covers_league?(league)
    case scope_kind
    when SCOPE_ALL then true
    when SCOPE_TEAM then false
    when SCOPE_LEAGUE then league.present? && league_id.present? && league_id.to_i == league.id
    when SCOPE_COMPETITION then league.present? && competition_covers?(league)
    else true # unbekannter Scope: im Zweifel greift die Sperre
    end
  end

  # Greift die Sperre fuer diese Mannschaft, ueber ihre Stammliga bewertet?
  def covers_team?(team)
    return false if team.blank?
    return true if scope_kind == SCOPE_ALL
    return team_id.to_i == team.id if scope_kind == SCOPE_TEAM

    covers_league?(team.league)
  end

  # Greift die Sperre auf die Lizenzzeile dieser Mannschaft in der Liste DIESER
  # Liga? Genau diese Frage stellt die Lizenzliste: Dieselbe Lizenz steht in der
  # Liste der Liga und in der des Pokals, und die Antwort darf sich
  # unterscheiden.
  def covers_license_in?(league, team)
    return team_id.to_i == team&.id.to_i if scope_kind == SCOPE_TEAM

    covers_league?(league)
  end

  # Klartext des Geltungsbereichs fuer Oberflaeche und Protokoll.
  def scope_summary
    case scope_kind
    when SCOPE_ALL then 'alle Wettbewerbe'
    when SCOPE_TEAM then 'eine Mannschaft'
    when SCOPE_LEAGUE then League.unscoped.find_by(id: league_id)&.name || 'eine Liga'
    when SCOPE_COMPETITION
      [[age_group.presence, field_size_label].compact.join(' '),
       competition_group_labels].reject(&:blank?).join(', ')
    else scope_kind.to_s
    end
  end

  # Zaehlt ein abgeschlossenes Spiel auf alle Sperren an, fuer die es zaehlt.
  #
  # Der Einstieg laeuft ueber die Sperren und nicht ueber die Spieler des
  # Spiels: Aktive Sperren mit Spielezaehler sind eine Handvoll Datensaetze,
  # waehrend die Aufstellung eines Spiels jedes Mal ueber die players-Tabelle
  # ginge. Ausserdem ist gerade der gesperrte Spieler NICHT in der Aufstellung.
  def self.count_closed_game!(game, user_id: nil)
    return 0 unless game&.match_record_closed?

    league = game.league
    team_ids = [game.home_team_id, game.guest_team_id].compact
    return 0 if league.blank? || team_ids.empty?

    date = game_date(game)
    # Ohne lesbares Spieldatum laesst sich nicht feststellen, ob das Spiel in
    # die Sperre fiel. Dann zaehlt es nicht: Die Sperre laeuft eher zu lang als
    # zu kurz.
    return 0 if date.blank?

    active.games_based.includes(:player).count do |suspension|
      suspension.count_game!(game, league: league, team_ids: team_ids, date: date, user_id: user_id)
    end
  end

  # `game_days.date` ist eine ZEICHENKETTE, keine Datumsspalte (wie
  # `games.game_number` und `leagues.season_id` auch). Ein Vergleich mit einem
  # Date wirft deshalb `comparison of Date with String failed`, statt einfach
  # falsch zu rechnen.
  def self.game_date(game)
    raw = game.game_day&.date
    return nil if raw.blank?
    return raw.to_date if raw.respond_to?(:to_date) && !raw.is_a?(String)

    begin
      Date.parse(raw.to_s)
    rescue ArgumentError, TypeError
      nil
    end
  end

  # Ein Spiel auf diese Sperre anrechnen. Gibt zurueck, ob gezaehlt wurde.
  def count_game!(game, league:, team_ids:, date:, user_id: nil)
    return false unless countable?(game, league, team_ids, date)

    counted = false
    with_lock do
      # Zweiter Blick unter der Sperre der Zeile: Zwei Spielberichte, die
      # gleichzeitig geschlossen werden, duerfen nicht beide dasselbe Spiel
      # zaehlen.
      unless Array(served_game_ids).include?(game.id)
        update!(games_served: games_served.to_i + 1,
                served_game_ids: Array(served_game_ids) + [game.id])
        counted = true
      end
    end

    player.lift_suspension!(self, user_id: user_id || created_by, reason: 'Sperre abgesessen') if served_out?
    counted
  end

  private

  def derive_scope_kind
    self.scope_kind ||= team_id.present? ? SCOPE_TEAM : SCOPE_ALL
  end

  def countable?(game, league, team_ids, date)
    return false unless games_based?
    return false unless active?
    return false if Array(served_game_ids).include?(game.id)
    return false unless window_covers?(date)

    team_ids.any? { |team_id| counts_for_team?(team_id, league) }
  end

  # Es zaehlen nur Spiele, fuer die der Spieler ohne die Sperre spielberechtigt
  # gewesen waere. Gelesen wird deshalb der Status, den die Lizenz OHNE Sperre
  # haette -- bei einer spielerweiten Sperre steht in der History `gesperrt`.
  def counts_for_team?(team_id, league)
    return false unless player.eligible_for_team?(team_id, season_id: league.season_id)
    return self.team_id.to_i == team_id.to_i if scope_kind == SCOPE_TEAM

    covers_league?(league)
  end

  def competition_covers?(league)
    return false unless season_id.blank? || season_id.to_s == league.season_id.to_s
    return false unless Array(competition_groups).include?(league.competition_group)
    return false unless dimension_matches?(age_group, league.effective_age_group)

    dimension_matches?(field_size, league.effective_field_size)
  end

  # Ein leerer Wert auf einer der beiden Seiten gilt als Treffer. Das ist die
  # sichere Richtung: An Playoff- und Endrundenligen bleiben Altersklasse und
  # Feldgroesse oft leer (Saison 17: 21 der 28 Luecken lagen bei cup/champ),
  # und ein gesperrter Spieler, der wegen eines leeren Feldes auflaufen darf,
  # waere der schwerere Fehler.
  def dimension_matches?(mine, theirs)
    mine.blank? || theirs.blank? || mine.to_s == theirs.to_s
  end

  def field_size_label
    case field_size
    when 'GF' then 'Großfeld'
    when 'KF' then 'Kleinfeld'
    else field_size.presence
    end
  end

  def competition_group_labels
    labels = { League::GROUP_LIGA => 'Ligaspielbetrieb', League::GROUP_POKAL => 'Pokal',
               League::GROUP_MEISTERSCHAFT => 'DM/Endrunde' }
    Array(competition_groups).map { |g| labels.fetch(g, g) }.join(' und ')
  end

  def valid_until_after_valid_from
    return if valid_from.blank? || valid_until.blank?

    errors.add(:valid_until, 'muss nach dem Beginn liegen') if valid_until < valid_from
  end

  # Ohne Dauer waere die Sperre unbefristet, und aufheben koennte sie nur noch
  # jemand von Hand.
  def duration_given
    return if valid_until.present? || games_total.present?

    errors.add(:base, 'Eine Sperre braucht ein Enddatum oder eine Anzahl von Spielen.')
  end

  def scope_target_given
    case scope_kind
    when SCOPE_TEAM
      errors.add(:team_id, 'fehlt für eine Sperre auf eine Mannschaft') if team_id.blank?
    when SCOPE_LEAGUE
      errors.add(:league_id, 'fehlt für eine Sperre auf eine Liga') if league_id.blank?
    when SCOPE_COMPETITION
      if Array(competition_groups).empty?
        errors.add(:competition_groups, 'Mindestens ein Wettbewerb muss ausgewählt sein.')
      end
      unknown = Array(competition_groups) - League::COMPETITION_GROUPS
      errors.add(:competition_groups, "unbekannt: #{unknown.join(', ')}") if unknown.any?
    end
  end
end
