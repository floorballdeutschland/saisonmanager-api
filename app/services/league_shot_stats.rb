# frozen_string_literal: true

# Schussstatistik einer Liga über alle beendeten Tabletspiele (Zusatzpaket
# `league_shot_stats`, siehe ApiKey::FEATURES). Die Website zeigt sie nicht;
# sie ist für Partner gedacht, die das Paket individuell vereinbart haben.
#
# Grundlage sind dieselben Schüsse wie bei GameShotStats, nur nicht je Spiel,
# sondern je Mannschaft, Spielerin/Spieler und Torhüter über die Saison
# summiert. Mannschaften und Personen tragen ihre ID, damit ein Partner sie
# mit Tabelle und Scorerliste derselben Liga zusammenführen kann.
#
# - `teams`: die Teamsummen aus GameShotStats, summiert, dazu dieselben Werte
#   des Gegners als `*_against` (Schüsse, aufs Tor, Tore).
# - `players`: nur wer in einem erfassten Spiel mindestens einen Schuss mit
#   erfasstem Schützen hat. `games` zählt die erfassten Spiele, in denen die
#   Person für diese Mannschaft in der Aufstellung stand.
# - `goalkeepers`: je Torhüter mit mindestens einem Schuss aufs Tor; `games`
#   zählt die erfassten Spiele mit einem solchen Schuss. Schüsse aufs leere
#   Tor zählen wie in GameShotStats bei keinem Torhüter.
#
# Wie vollständig die Zahlen sind, zeigen `games_ended`, `games_captured` und
# `games_complete`: Nur ein Teil der Spiele wird im Tabletmodus erfasst, und
# nicht jedes davon vollständig. Namen in öffentlicher Anzeigeform aus dem
# jeweils letzten erfassten Spiel (PublicPersonRefs).
#
# Gecacht für fünf Minuten, geleert über Game#flush_league_caches und
# GameShotStats.flush!.
class LeagueShotStats
  CACHE_TTL = 5.minutes
  # Werte aus GameShotStats, die zusätzlich als Gegenwert erscheinen.
  AGAINST_KEYS = %i[shots on_goal goals].freeze

  def self.cache_key(league_id)
    "leagues/#{league_id}/shot_stats"
  end

  def self.flush!(league_id)
    Rails.cache.delete(cache_key(league_id)) if league_id.present?
  end

  def self.cached(league)
    Rails.cache.fetch(cache_key(league.id), expires_in: CACHE_TTL) do
      new(league).as_json
    end
  end

  def initialize(league)
    ended = league.games.select { |game| game.ended? && !game.forfait? }
    @games_ended = ended.size
    @games = ended.select(&:tablet_capture?).sort_by { |game| [game.game_day&.date.to_s, game.game_number.to_i] }
    @shots = GameShot.where(game_id: @games.map(&:id), kind: 'shot').order(:tapped_at, :id).group_by(&:game_id)
  end

  def as_json(*)
    {
      games_ended: @games_ended,
      games_captured: @games.size,
      games_complete: @games.count(&:tablet_shots_complete),
      teams: teams,
      players: players,
      goalkeepers: goalkeepers
    }
  end

  private

  def team_of(game, side)
    side == 'home' ? game.home_team : game.guest_team
  end

  def gegner(side)
    side == 'home' ? 'guest' : 'home'
  end

  def teams
    eintraege = {}
    @games.each do |game|
      summen = GameShotStats.cached(game, delayed: false)[:teams]
      GameShot::TEAMS.each do |side|
        team = team_of(game, side)
        next if team.nil?

        eigene = summen[side].except(:by_period)
        gegen = summen[gegner(side)]
        eintrag = eintraege[team.id] ||= { team_id: team.id, team_name: team.name, games: 0 }
        eintrag[:games] += 1
        eigene.each { |key, wert| eintrag[key] = eintrag.fetch(key, 0) + wert }
        AGAINST_KEYS.each { |key| eintrag[:"#{key}_against"] = eintrag.fetch(:"#{key}_against", 0) + gegen[key] }
      end
    end
    eintraege.values.sort_by { |eintrag| eintrag[:team_name].to_s }
  end

  def players
    eintraege = {}
    @games.each do |game|
      refs = PublicPersonRefs.new(game)
      shots = @shots.fetch(game.id, []).select { |shot| shot.shooter_player_id.present? }
      shots.group_by { |shot| [shot.team, shot.shooter_player_id] }.each do |(side, player_id), eigene|
        team = team_of(game, side)
        next if team.nil?

        eintrag = person(eintraege, team, player_id, refs.ref(side, player_id))
        eintrag[:shots] += eigene.size
        eintrag[:on_goal] += eigene.count(&:on_goal?)
        eintrag[:goals] += eigene.count { |shot| shot.result == 'goal' }
      end
    end
    zaehle_einsaetze(eintraege)
    eintraege.each_value { |eintrag| eintrag[:shooting_pct] = anteil(eintrag[:goals], eintrag[:shots]) }
    eintraege.values.sort_by { |eintrag| [-eintrag[:goals], -eintrag[:shots], eintrag[:name]] }
  end

  # Einsätze aus den Aufstellungen ALLER erfassten Spiele, nicht nur derer
  # mit Schuss: Sonst wären Schüsse je Spiel zu hoch.
  def zaehle_einsaetze(eintraege)
    @games.each do |game|
      GameShot::TEAMS.each do |side|
        team = team_of(game, side)
        next if team.nil?

        aufstellung(game, side).each do |player_id|
          eintrag = eintraege[[team.id, player_id]]
          eintrag[:games] += 1 if eintrag
        end
      end
    end
  end

  def goalkeepers
    eintraege = {}
    @games.each do |game|
      refs = PublicPersonRefs.new(game)
      aufs_tor = @shots.fetch(game.id, []).select do |shot|
        shot.on_goal? && !shot.empty_net && shot.goalkeeper_player_id.present?
      end
      aufs_tor.group_by { |shot| [gegner(shot.team), shot.goalkeeper_player_id] }.each do |(side, player_id), shots|
        team = team_of(game, side)
        next if team.nil?

        eintrag = person(eintraege, team, player_id, refs.ref(side, player_id), torhueter: true)
        eintrag[:games] += 1
        eintrag[:saves] += shots.count { |shot| shot.result == 'saved' }
        eintrag[:shots_against] += shots.size
      end
    end
    eintraege.each_value do |eintrag|
      eintrag[:goals_against] = eintrag[:shots_against] - eintrag[:saves]
      eintrag[:save_pct] = anteil(eintrag[:saves], eintrag[:shots_against])
    end
    eintraege.values.sort_by { |eintrag| [-eintrag[:shots_against], eintrag[:name]] }
  end

  # Eintrag je Mannschaft und Person. Name und Trikotnummer überschreibt jedes
  # spätere Spiel, so gilt der Stand des letzten erfassten Spiels.
  def person(eintraege, team, player_id, ref, torhueter: false)
    zaehler = torhueter ? { games: 0, saves: 0, shots_against: 0 } : { games: 0, shots: 0, on_goal: 0, goals: 0 }
    eintrag = eintraege[[team.id, player_id.to_i]] ||=
      { player_id: player_id.to_i, team_id: team.id, team_name: team.name, trikot_number: nil, name: '' }
      .merge(zaehler)
    eintrag.merge!(ref.slice(:trikot_number, :name)) if ref
    eintrag
  end

  def aufstellung(game, side)
    players = game.players.is_a?(Hash) ? game.players : {}
    Array(players[side]).filter_map { |entry| entry['player_id'].presence&.to_i }.uniq
  end

  # Anteil 0..1 wie in GameShotStats, nil ohne Grundmenge.
  def anteil(teil, ganzes)
    ganzes.zero? ? nil : (teil.to_f / ganzes).round(3)
  end
end
