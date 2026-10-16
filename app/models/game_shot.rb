# frozen_string_literal: true

# Ein im Tabletmodus erfasster Schuss (api#816, fe#344).
#
# Positionen sind über das GANZE Feld von Bande zu Bande normiert (40 x 20 m),
# nicht von Torlinie zu Torlinie, und auf eine einheitliche Angriffsrichtung
# umgerechnet: x = 0 ist die Bande hinter dem eigenen Tor des schießenden
# Teams, x = 1 die hinter dem gegnerischen; y = 0 die linke, y = 1 die rechte
# Seitenbande aus Sicht des Angreifers. Die Gegenrichtung ist eine Drehung um
# 180 Grad (x und y gespiegelt). Die Teams wechseln je Abschnitt die Seiten,
# ohne diese Umrechnung wären Schussgrafiken über ein Spiel unbrauchbar. Die
# Umrechnung macht das Tablet, die API speichert nur.
#
# `tapped_at` ist der Zeitpunkt des ERSTEN Antippens, nicht der Übertragung,
# und bereits um die Abweichung der Geräteuhr korrigiert. Er ist die einzige
# Quelle für den genauen Torzeitpunkt (Sprungmarken, Highlights): Das
# offizielle Tor wird regelgemäß erst mit dem Bully eingetragen.
class GameShot < ApplicationRecord
  TEAMS = %w[home guest].freeze
  RESULTS = %w[goal saved missed blocked].freeze
  # Auf das Tor: Tor oder vom Torhüter gehalten.
  ON_GOAL = %w[goal saved].freeze

  # Was der Client schreiben darf. `event_id` gehört nicht dazu, die
  # Verknüpfung läuft über einen eigenen Weg (GameShotsController#link) und
  # automatisch über GamesController#add_event.
  INPUT_FIELDS = %w[client_uuid team period game_time tapped_at x y result
                    shooter_player_id goalkeeper_player_id].freeze

  belongs_to :game

  validates :client_uuid, presence: true, uniqueness: true, length: { maximum: 64 }
  validates :team, inclusion: { in: TEAMS }
  validates :result, inclusion: { in: RESULTS }
  validates :period, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :game_time, format: { with: /\A\d{1,3}:\d{2}\z/ }, allow_blank: true
  validates :tapped_at, presence: true
  validates :x, :y, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }

  # Schütze aus der Aufstellung des schießenden Teams, Torhüter aus der des
  # verteidigenden. Geprüft nur beim Ändern: Wird die Aufstellung später
  # korrigiert, sollen vorhandene Schüsse weiter speicherbar bleiben.
  validate :shooter_in_lineup, if: -> { shooter_player_id.present? && (shooter_player_id_changed? || team_changed?) }
  validate :goalkeeper_in_lineup,
           if: -> { goalkeeper_player_id.present? && (goalkeeper_player_id_changed? || team_changed?) }

  # Nur ein Tor-Schuss kann an einem Tor hängen. Wird aus dem Tor nachträglich
  # ein gehaltener Schuss, fällt die Verknüpfung weg.
  before_validation { self.event_id = nil unless result == 'goal' }

  scope :linked, -> { where.not(event_id: nil) }

  def on_goal?
    ON_GOAL.include?(result)
  end

  def defending_team
    team == 'home' ? 'guest' : 'home'
  end

  def as_api_json
    {
      id:,
      client_uuid:,
      team:,
      period:,
      game_time:,
      tapped_at: tapped_at&.utc&.iso8601(3),
      x: x&.to_f,
      y: y&.to_f,
      result:,
      shooter_player_id:,
      goalkeeper_player_id:,
      event_id:
    }
  end

  private

  def shooter_in_lineup
    errors.add(:shooter_player_id, 'steht nicht in der Aufstellung des schießenden Teams') \
      unless lineup_ids(team).include?(shooter_player_id.to_i)
  end

  def goalkeeper_in_lineup
    errors.add(:goalkeeper_player_id, 'steht nicht in der Aufstellung des verteidigenden Teams') \
      unless lineup_ids(defending_team).include?(goalkeeper_player_id.to_i)
  end

  def lineup_ids(side)
    players = game&.players.is_a?(Hash) ? game.players : {}
    Array(players[side]).filter_map { |entry| entry['player_id'].presence&.to_i }
  end
end
