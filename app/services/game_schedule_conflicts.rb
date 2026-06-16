# Erkennt Hallen-Belegungskonflikte: Spiele, die in derselben Arena am selben Tag
# liegen und deren angenommenes Zeitfenster sich mit dem eines (geplanten) Spiels
# überschneidet.
#
# Das vorgeschlagene Spiel muss nicht persistiert sein — Arena und Datum kommen
# über den Spieltag, die Startzeit und (optional) eine abweichende Dauer werden
# direkt übergeben. So kann das Frontend bereits VOR dem Speichern warnen.
class GameScheduleConflicts
  BERLIN = ActiveSupport::TimeZone['Europe/Berlin'].freeze

  def initialize(game_day:, start_time:, exclude_game_id: nil, duration_minutes: nil)
    @game_day = game_day
    @start_time = start_time
    @exclude_game_id = exclude_game_id.presence
    @duration_minutes = duration_minutes.presence&.to_i
  end

  # Liste der überschneidenden Spiele (kann leer sein).
  def arena_conflicts
    return [] if proposed_window.nil?

    candidate_games.select do |game|
      other = game.occupancy_window
      other && overlap?(proposed_window, other)
    end
  end

  private

  # Andere Spiele in derselben Arena am selben Tag (das geprüfte Spiel selbst
  # ausgenommen). Über den Join werden auch Spiele anderer Spieltage erfasst,
  # die zufällig dieselbe Arena am selben Datum belegen.
  def candidate_games
    return Game.none if @game_day&.arena_id.blank? || @game_day.date.blank?

    # Eager-Load für occupancy_window (→ league) und die Serialisierung
    # (home_team/guest_team/league) → kein N+1 bei vielen Spielen je Halle/Tag.
    scope = Game.includes(:home_team, :guest_team, game_day: :league)
                .references(:game_days)
                .where(game_days: { arena_id: @game_day.arena_id, date: @game_day.date })
    scope = scope.where.not(id: @exclude_game_id) if @exclude_game_id
    scope
  end

  def proposed_window
    @proposed_window ||= build_window
  end

  def build_window
    return nil if @game_day&.date.blank? || @start_time.blank?

    start = BERLIN.parse("#{@game_day.date} #{@start_time}")
    return nil if start.nil?

    start...(start + duration_minutes.minutes)
  rescue ArgumentError
    # Unparsebare Startzeit (z. B. "25:99") → keine zuverlässige Prüfung möglich.
    nil
  end

  def duration_minutes
    @duration_minutes || @game_day.league.effective_game_duration_minutes
  end

  def overlap?(window_a, window_b)
    window_a.begin < window_b.end && window_b.begin < window_a.end
  end
end
