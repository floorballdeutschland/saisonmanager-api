# frozen_string_literal: true

# Die öffentliche "Ausführliche Statistik" eines Tablet-Spiels (api#816,
# fe#344): Schüsse mit Position und Ergebnis, Summen je Team und Abschnitt,
# Paraden und Fangquote je Torhüter, Schüsse je Spieler. Dazu Freischläge
# (fe#589) mit Position und Summen je Team und Abschnitt sowie Schüsse und
# Tore aus Freischlägen. Freischläge zählen nirgends als Schuss.
#
# NAMEN IN ÖFFENTLICHER ANZEIGEFORM: aus dem Spielbericht-Schnappschuss und
# über PublicPlayerNames maskiert, genau wie auf der öffentlichen Spielseite.
# Steht ein Schütze nicht in der Aufstellung, kommt der Name aus dem
# Spielerprofil, ebenfalls maskiert.
#
# Gecacht für eine Minute, geleert bei jedem Schreibvorgang an Schüssen und
# an der Verknüpfung (#flush!).
class GameShotStats
  CACHE_TTL = 1.minute
  VARIANTS = %w[realtime delayed].freeze

  def self.cache_key(game, variant)
    "games/#{game.id}/detailed_stats/#{variant}"
  end

  def self.flush!(game)
    VARIANTS.each do |variant|
      Rails.cache.delete(cache_key(game, variant))
      Rails.cache.delete(GameHighlights.cache_key(game, variant))
    end
  end

  # `cutoff`: nur Schüsse vor diesem Zeitpunkt (verzögerte API-Schlüssel bei
  # laufenden Spielen, siehe ApplicationController#strip_delayed_events!).
  def self.cached(game, delayed:, cutoff: nil)
    variant = delayed ? 'delayed' : 'realtime'
    Rails.cache.fetch(cache_key(game, variant), expires_in: CACHE_TTL) do
      new(game, cutoff: cutoff).as_json
    end
  end

  def initialize(game, cutoff: nil)
    @game = game
    scope = game.game_shots.order(:tapped_at, :id)
    scope = scope.where(tapped_at: ...cutoff) if cutoff
    @shots, @free_hits = scope.to_a.partition(&:shot?)
    @names = PublicPersonRefs.new(game)
  end

  def as_json(*)
    {
      complete: @game.tablet_shots_complete,
      shots: @shots.map { |shot| shot_json(shot) },
      free_hits: @free_hits.map { |free_hit| free_hit_json(free_hit) },
      teams: GameShot::TEAMS.index_with { |team| team_json(team) },
      goalkeepers: goalkeepers,
      players: players
    }
  end

  private

  def shot_json(shot)
    {
      event_id: shot.event_id,
      team: shot.team,
      period: shot.period,
      game_time: shot.game_time,
      x: shot.x.to_f,
      y: shot.y.to_f,
      result: shot.result,
      from_free_hit: shot.from_free_hit,
      shooter: @names.ref(shot.team, shot.shooter_player_id)
    }
  end

  def free_hit_json(free_hit)
    {
      team: free_hit.team,
      period: free_hit.period,
      game_time: free_hit.game_time,
      x: free_hit.x.to_f,
      y: free_hit.y.to_f
    }
  end

  def team_json(team)
    eigene = (@shots + @free_hits).select { |shot| shot.team == team }
    perioden = (@shots + @free_hits).map(&:period).uniq.sort
    summen(eigene).merge(
      by_period: perioden.to_h { |period| [period.to_s, summen(eigene.select { |shot| shot.period == period })] }
    )
  end

  # `eintraege` mischt Schüsse und Freischläge eines Teams.
  def summen(eintraege)
    shots, free_hits = eintraege.partition(&:shot?)
    aus_freischlag = shots.select(&:from_free_hit)
    {
      shots: shots.size,
      on_goal: shots.count(&:on_goal?),
      goals: shots.count { |shot| shot.result == 'goal' },
      blocked: shots.count { |shot| shot.result == 'blocked' },
      missed: shots.count { |shot| shot.result == 'missed' },
      free_hits: free_hits.size,
      shots_from_free_hit: aus_freischlag.size,
      goals_from_free_hit: aus_freischlag.count { |shot| shot.result == 'goal' }
    }
  end

  # Je Torhüter des verteidigenden Teams. Schüsse ohne erfassten Torhüter
  # zählen in den Teamsummen, aber bei keinem Torhüter.
  def goalkeepers
    aufs_tor = @shots.select { |shot| shot.on_goal? && shot.goalkeeper_player_id.present? }
    aufs_tor.group_by { |shot| [gegner(shot.team), shot.goalkeeper_player_id] }.map do |(team, player_id), shots|
      ref = @names.ref(team, player_id)
      paraden = shots.count { |shot| shot.result == 'saved' }
      {
        team: team,
        trikot_number: ref&.dig(:trikot_number),
        name: ref&.dig(:name).to_s,
        saves: paraden,
        shots_against: shots.size,
        # Anteil 0..1, nicht Prozent. Gruppen entstehen nur aus Schüssen aufs
        # Tor, `shots.size` ist hier also nie 0.
        save_pct: shots.empty? ? nil : (paraden.to_f / shots.size).round(3)
      }
    end
  end

  def players
    mit_schuetze = @shots.select { |shot| shot.shooter_player_id.present? }
    eintraege = mit_schuetze.group_by { |shot| [shot.team, shot.shooter_player_id] }.map do |(team, player_id), shots|
      ref = @names.ref(team, player_id)
      {
        team: team,
        trikot_number: ref&.dig(:trikot_number),
        name: ref&.dig(:name).to_s,
        shots: shots.size,
        on_goal: shots.count(&:on_goal?),
        goals: shots.count { |shot| shot.result == 'goal' }
      }
    end
    eintraege.sort_by { |eintrag| [GameShot::TEAMS.index(eintrag[:team]), -eintrag[:shots], eintrag[:name]] }
  end

  def gegner(team)
    team == 'home' ? 'guest' : 'home'
  end
end
