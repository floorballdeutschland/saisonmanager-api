class GameDay < ApplicationRecord
  has_many :games, inverse_of: :game_day
  has_many :game_day_referee_confirmations, dependent: :destroy
  has_many :game_day_team_confirmations, dependent: :destroy
  has_many :game_day_secretary_links, dependent: :destroy
  belongs_to :league
  # arena/club sind bewusst optional: Der Spielplan-Import erlaubt lückenhafte
  # Vorlagen (Halle/Ausrichter noch offen -> nil). DB-Spalten sind nullable und
  # die Serialisierung (full_hash/hosting_club) ist durchgängig nil-sicher.
  belongs_to :arena, optional: true
  belongs_to :club, optional: true

  # 14
  scope :past_games, lambda {
                       where("TO_DATE(date, 'YYYY-MM-DD') > (now()::date - interval '14 days') AND TO_DATE(date, 'YYYY-MM-DD') <= (now()::date + interval '100 days') ")
                     }

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
end
