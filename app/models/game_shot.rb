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
#
# FREISCHLÄGE (fe#589) liegen in derselben Tabelle mit `kind: 'free_hit'`:
# gleiche Grunddaten, gleiche Normierung (Angriffsrichtung des AUSFÜHRENDEN,
# also des gefoulten Teams), aber ohne Ergebnis, Spieler und Tor. Jede
# Auswertung von Schüssen muss sich deshalb auf `shots` beschränken. Ein
# Schuss kann `from_free_hit` tragen; das schaltet das Tablet, die API
# verknüpft nichts selbst. Mit Strafen wird nichts verbunden.
#
# VORGEMERKTE SZENEN (`kind: 'mark'`) sind ein Tipp auf "Szene vormerken": nur
# Abschnitt, Spielzeit und Zeitpunkt, Team und Position freiwillig. Sie zählen
# nie als Schuss, werden aber Highlight-Szenen (GameHighlights).
#
# STRAFSCHÜSSE UND TORWARTSITUATION (Feedback #61, #63, #64) sind Kennungen
# am Schuss wie `from_free_hit`, geschaltet am Tablet:
# - `from_penalty_shot`: Strafschuss. Nie zugleich aus Freischlag, nie
#   geblockt und nie bei herausgenommenem Torhüter, der Strafschuss geht
#   immer auf den Torhüter.
# - `empty_net`: aufs leere Tor, der Gegner spielt ohne Torhüter. Dann gibt
#   es keinen Torhüter am Schuss und keine Parade; der Schuss belastet so
#   keine Fangquote.
# - `extra_attacker`: das schießende Team spielt ohne eigenen Torhüter
#   (6 gegen 5).
# Der normale Spielbericht (`games.events`, `goal_type`) weiß davon nichts.
#
# PARADEN OHNE POSITION (Feedback #62): Der Schnellzähler am Tablet erfasst
# einen gehaltenen Schuss ohne Feldposition. `x` und `y` fehlen dann beide;
# das gibt es nur bei `result: 'saved'` ohne Strafschuss. Solche Schüsse
# zählen in Summen, Paraden und Fangquote, aber in keiner Schussgrafik.
#
# `in_highlights` ist die Auswahl für die öffentlichen Highlights, je Tor-Schuss
# und vorgemerkter Szene. Sie gehört nicht zu INPUT_FIELDS: Das Tablet gleicht
# seinen Puffer mit vollen Datensätzen ab und soll die Auswahl, die später über
# den Mail-Link oder von der SBK getroffen wird, nicht überschreiben.
class GameShot < ApplicationRecord
  TEAMS = %w[home guest].freeze
  KINDS = %w[shot free_hit mark].freeze
  # Was in die Statistik eingeht. Vorgemerkte Szenen gehören nicht dazu.
  STAT_KINDS = %w[shot free_hit].freeze
  RESULTS = %w[goal saved missed blocked].freeze
  # Auf das Tor: Tor oder vom Torhüter gehalten.
  ON_GOAL = %w[goal saved].freeze

  # Was der Client schreiben darf. `event_id` gehört nicht dazu, die
  # Verknüpfung läuft über einen eigenen Weg (GameShotsController#link) und
  # automatisch über GamesController#add_event.
  INPUT_FIELDS = %w[client_uuid kind team period game_time tapped_at x y result
                    shooter_player_id goalkeeper_player_id from_free_hit
                    from_penalty_shot empty_net extra_attacker].freeze
  # Kennungen, die es nur an Schüssen gibt.
  SHOT_FLAGS = %w[from_free_hit from_penalty_shot empty_net extra_attacker].freeze

  belongs_to :game

  validates :client_uuid, presence: true, uniqueness: true, length: { maximum: 64 }
  validates :kind, inclusion: { in: KINDS }
  validates :team, inclusion: { in: TEAMS }, unless: :mark?
  validates :team, inclusion: { in: TEAMS }, allow_nil: true, if: :mark?
  validates :result, inclusion: { in: RESULTS }, if: :shot?
  validates :result, :shooter_player_id, :goalkeeper_player_id, absence: true, unless: :shot?
  validates(*SHOT_FLAGS, inclusion: { in: [false], message: 'gibt es nur bei Schüssen' }, unless: :shot?)
  validate :penalty_shot_consistent, if: -> { shot? && from_penalty_shot }
  validates :goalkeeper_player_id, absence: { message: 'gibt es bei einem Schuss aufs leere Tor nicht' },
                                   if: -> { shot? && empty_net }
  validates :result, exclusion: { in: %w[saved], message: 'gehalten geht nicht aufs leere Tor' },
                     if: -> { shot? && empty_net }
  validates :period, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :game_time, format: { with: /\A\d{1,3}:\d{2}\z/ }, allow_blank: true
  validates :tapped_at, presence: true
  validates :x, :y, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 },
                    unless: -> { mark? || unplaced_save? }
  validates :x, :y, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true,
                    if: :mark?

  # Schütze aus der Aufstellung des schießenden Teams, Torhüter aus der des
  # verteidigenden. Geprüft nur beim Ändern: Wird die Aufstellung später
  # korrigiert, sollen vorhandene Schüsse weiter speicherbar bleiben.
  validate :shooter_in_lineup, if: -> { shot? && shooter_player_id.present? && (shooter_player_id_changed? || team_changed?) }
  validate :goalkeeper_in_lineup,
           if: -> { shot? && goalkeeper_player_id.present? && (goalkeeper_player_id_changed? || team_changed?) }

  # Nur ein Tor-Schuss kann an einem Tor hängen. Wird aus dem Tor nachträglich
  # ein gehaltener Schuss, fällt die Verknüpfung weg.
  before_validation { self.event_id = nil unless result == 'goal' }
  before_validation { SHOT_FLAGS.each { |flag| self[flag] = false if self[flag].nil? } }

  scope :linked, -> { where.not(event_id: nil) }
  scope :shots, -> { where(kind: 'shot') }
  scope :free_hits, -> { where(kind: 'free_hit') }
  scope :marks, -> { where(kind: 'mark') }

  def shot?
    kind == 'shot'
  end

  def free_hit?
    kind == 'free_hit'
  end

  def mark?
    kind == 'mark'
  end

  def on_goal?
    ON_GOAL.include?(result)
  end

  # Parade aus dem Schnellzähler: gehalten, ohne Feldposition.
  def unplaced_save?
    shot? && result == 'saved' && !from_penalty_shot && x.nil? && y.nil?
  end

  def placed?
    !x.nil? && !y.nil?
  end

  def defending_team
    team == 'home' ? 'guest' : 'home'
  end

  def as_api_json
    {
      id:,
      client_uuid:,
      kind:,
      team:,
      period:,
      game_time:,
      tapped_at: tapped_at&.utc&.iso8601(3),
      x: x&.to_f,
      y: y&.to_f,
      result:,
      shooter_player_id:,
      goalkeeper_player_id:,
      from_free_hit:,
      from_penalty_shot:,
      empty_net:,
      extra_attacker:,
      in_highlights:,
      event_id:
    }
  end

  private

  def penalty_shot_consistent
    errors.add(:from_penalty_shot, 'und aus Freischlag schließen sich aus') if from_free_hit
    errors.add(:from_penalty_shot, 'geht immer auf den Torhüter, nicht bei herausgenommenem Torhüter') \
      if empty_net || extra_attacker
    errors.add(:from_penalty_shot, 'kann nicht geblockt werden') if result == 'blocked'
  end

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
