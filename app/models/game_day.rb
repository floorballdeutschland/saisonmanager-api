class GameDay < ApplicationRecord
  has_many :games, inverse_of: :game_day
  has_many :game_day_referee_confirmations, dependent: :destroy
  has_many :game_day_team_confirmations, dependent: :destroy
  # Seit der Link mehrere Spieltage abdecken kann, hängt er nicht mehr an einem
  # einzelnen: gelöscht wird nur die Zuordnung. Ein Link, der dadurch keinen
  # Spieltag mehr abdeckt, erlaubt nichts und läuft ohnehin nach 72 h ab.
  has_many :game_day_secretary_link_game_days, dependent: :destroy
  has_many :game_day_secretary_links, through: :game_day_secretary_link_game_days
  belongs_to :league
  # arena/club sind bewusst optional: Der Spielplan-Import erlaubt lückenhafte
  # Vorlagen (Halle/Ausrichter noch offen -> nil). DB-Spalten sind nullable und
  # die Serialisierung (full_hash/hosting_club) ist durchgängig nil-sicher.
  belongs_to :arena, optional: true
  belongs_to :club, optional: true

  # `date` ist eine Textspalte, und der ganze Bestand liest sie defensiv, weil
  # sie als unzuverlässig bekannt ist: TO_DATE(NULLIF(...)) in
  # admin/game_days_controller, Date.strptime mit rescue in
  # referee_feedback_window, Date.parse mit rescue in
  # admin/referee_assignments_controller. Geschrieben wurde sie dagegen ungeprüft,
  # `GameDay.create!(date: '11.08.2026')` ging durch. Solange jeder Leser sich
  # selbst schützt, bleibt das beherrschbar; beim öffentlichen Livestream-Abruf
  # ist es das nicht, weil dort eine leere Liste als Aussage gerendert wird
  # ("heute wird nichts übertragen") und ein abweichend formatierter Datensatz
  # nicht von einem ruhigen Tag zu unterscheiden ist.
  #
  # allow_blank wegen der Altbestände: Halle und Ausrichter dürfen offen bleiben
  # (s. oben), das Datum ebenso.
  #
  # `if: date_changed?` ist der Kern und nicht Beiwerk: Eine bestehende Zeile mit
  # abweichendem Format bleibt speicherbar, solange niemand ihr Datum anfasst.
  # Ohne diese Bedingung würde die Validierung an einem solchen Datensatz jedes
  # Speichern blockieren, auch das Setzen von Halle oder Ausrichter, und zwar
  # bevor irgendwer den Bestand gesichtet hat. Wer das Datum ändert, muss es
  # dagegen richtig hinschreiben.
  DATE_FORMAT = /\A\d{4}-\d{2}-\d{2}\z/
  validates :date, format: { with: DATE_FORMAT, message: 'muss im Format JJJJ-MM-TT vorliegen' },
                   allow_blank: true, if: :date_changed?

  # Das Formular schickt für eine leere Auswahl bei Halle und Ausrichter eine 0
  # statt nichts. Als ID ist die 0 wertlos, und weil `optional: true` die
  # Existenz nicht prüft, lief sie ungebremst bis in die Fremdschlüssel und kam
  # als 500 zurück (PG::ForeignKeyViolation, Sentry SAISONMANAGER-3F). Gemeint
  # ist "nicht gesetzt", also wird sie dazu gemacht.
  before_validation :normalize_blank_references

  # `optional: true` erlaubt nil, prüft aber nicht, ob eine gesetzte ID
  # existiert. Ohne diese Prüfung entscheidet das erst die Datenbank, und dann
  # ist es ein Serverfehler statt einer Rückmeldung am Feld.
  validates :club, presence: true, if: -> { club_id.present? }
  validates :arena, presence: true, if: -> { arena_id.present? }

  # 14
  scope :past_games, lambda {
                       where("TO_DATE(date, 'YYYY-MM-DD') > (now()::date - interval '14 days') AND TO_DATE(date, 'YYYY-MM-DD') <= (now()::date + interval '100 days') ")
                     }

  # Alle Spieltage, die am selben Tag in derselben Halle stattfinden, inklusive
  # self. Das Spielsekretariat sitzt pro Halle und Tag am Tisch, nicht pro Liga:
  # spielen dort nacheinander mehrere Ligen, gehören sie in denselben Link.
  #
  # `date` ist eine Text-Spalte, der Vergleich also ein reiner Stringvergleich.
  # Der Spielplan-Import schreibt durchgängig YYYY-MM-DD; ein abweichend
  # formatierter Altdatensatz fände seine Geschwister nicht und bekäme einfach
  # einen Link nur für sich – kein Rechteproblem, nur weniger Komfort.
  def hall_day_siblings
    return GameDay.where(id: id) if arena_id.blank? || date.blank?

    GameDay.where(arena_id: arena_id, date: date)
  end

  def hosting_club
    club.name if club.present?
  end

  def deletable?
    !games.present? # TODO: current_season?!
  end

  def full_hash(with_games = false)
    h = {
      id:,
      arena_id:,
      arena: arena&.full_hash,
      club_id:,
      club: club&.full_hash,
      date:,
      league_id:,
      deletable: deletable?,
      number:
    }

    # home_team/guest_team (+ club für die Logo-Fallbacks) eager laden, sonst
    # zieht meta_hash pro Spiel je eine Team-/Club-Query nach.
    if with_games
      h[:games] = games.includes(home_team: :club, guest_team: :club)
                       .order(Arel.sql("NULLIF(game_number, '')::integer NULLS LAST"))
                       .map(&:meta_hash)
    end

    h
  end

  private

  def normalize_blank_references
    self.club_id = nil if club_id.to_i.zero?
    self.arena_id = nil if arena_id.to_i.zero?
  end
end
