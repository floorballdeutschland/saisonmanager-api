require 'test_helper'

# Mehrere Vorrunden-Ligen und was aus ihnen in die Tabelle der Folgeliga
# übernommen wird (LeaguePrerounds).
class LeaguePreroundsTest < ActiveSupport::TestCase
  setup do
    @go = create(:game_operation)
    @staffel_a = create(:league, game_operation: @go, name: 'Staffel A')
    @staffel_b = create(:league, game_operation: @go, name: 'Staffel B')
    @club_a = create(:club)
    @club_b = create(:club)
    @club_c = create(:club)
  end

  def play(league, home, guest, home_goals, guest_goals)
    game_day = GameDay.find_by(league: league) || create(:game_day, league: league)
    Game.create!(game_day: game_day, home_team: home, guest_team: guest, started: true, ended: true,
                 forfait: 0, overtime: false, legacy: false,
                 events: [{ 'row' => 1, 'period' => 1, 'home_goals' => home_goals, 'guest_goals' => guest_goals }])
  end

  def entry(table, team)
    table.find { |e| e[:team_id] == team.id }
  end

  # Staffel A: A1 schlägt C1 4:1. Staffel B: B1 schlägt X 2:0.
  def two_staffeln
    a1 = create(:team, league: @staffel_a, club: @club_a, name: 'Verein A')
    c1 = create(:team, league: @staffel_a, club: @club_c, name: 'Verein C')
    b1 = create(:team, league: @staffel_b, club: @club_b, name: 'Verein B')
    x = create(:team, league: @staffel_b, club: create(:club), name: 'Verein X')
    play(@staffel_a, a1, c1, 4, 1)
    play(@staffel_b, b1, x, 2, 0)
  end

  def zwischenrunde(**attrs)
    league = create(:league, game_operation: @go, name: 'Zwischenrunde',
                             league_ids_preround: [@staffel_a.id, @staffel_b.id], preround_point_modus: 'full', **attrs)
    [league,
     create(:team, league: league, club: @club_a, name: 'Verein A'),
     create(:team, league: league, club: @club_b, name: 'Verein B')]
  end

  test 'Punkte aus beiden Staffeln landen in der Folgeliga' do
    two_staffeln
    league, a, b = zwischenrunde

    table = league.table
    assert_equal 3, entry(table, a)[:points]
    assert_equal 3, entry(table, b)[:points]
    assert_equal 3, entry(table, a)[:preround_points]
  end

  test 'Stufe points übernimmt keine Tore und keine Spiele' do
    two_staffeln
    league, a, = zwischenrunde(preround_transfer_scope: 'points')

    row = entry(league.table, a)
    assert_equal 0, row[:goals_scored]
    assert_equal 0, row[:games]
    assert_equal({ points: 3 }, row[:preround])
  end

  test 'Stufe goals übernimmt Tore und Tordifferenz, aber keine Spiele' do
    two_staffeln
    league, a, = zwischenrunde(preround_transfer_scope: 'goals')

    row = entry(league.table, a)
    assert_equal 3, row[:points]
    assert_equal 4, row[:goals_scored]
    assert_equal 1, row[:goals_received]
    assert_equal 3, row[:goals_diff]
    assert_equal 0, row[:games]
  end

  test 'Stufe full übernimmt die komplette Bilanz' do
    two_staffeln
    league, a, b = zwischenrunde(preround_transfer_scope: 'full')
    play(league, a, b, 1, 1)

    row = entry(league.table, a)
    assert_equal 2, row[:games]
    assert_equal 1, row[:won]
    assert_equal 1, row[:draw]
    assert_equal 4, row[:points]
    assert_equal 5, row[:goals_scored]
    assert_equal 2, row[:goals_received]
  end

  test 'Tordifferenz aus der Vorrunde entscheidet bei Punktgleichheit' do
    two_staffeln # A +3, B +2
    league, a, b = zwischenrunde(preround_transfer_scope: 'goals')

    table = league.table
    assert_operator entry(table, a)[:sort], :<, entry(table, b)[:sort]
  end

  test 'halb gilt nur für Punkte und rundet erst nach der Summe ab' do
    two_staffeln
    league, a, = zwischenrunde(preround_point_modus: 'half', preround_transfer_scope: 'goals')

    row = entry(league.table, a)
    assert_equal 1, row[:points] # 3 * 0.5 abgerundet
    assert_equal 4, row[:goals_scored]
  end

  test 'ohne preround_point_modus wird nichts übernommen' do
    two_staffeln
    league, a, = zwischenrunde(preround_point_modus: nil, preround_transfer_scope: 'full')

    assert_equal 0, entry(league.table, a)[:points]
  end

  test 'Verein mit Mannschaften in beiden Staffeln: Zuordnung über den Namen' do
    a1 = create(:team, league: @staffel_a, club: @club_a, name: 'Verein A 1')
    a2 = create(:team, league: @staffel_b, club: @club_a, name: 'Verein A 2')
    gegner_a = create(:team, league: @staffel_a, club: @club_c, name: 'C')
    gegner_b = create(:team, league: @staffel_b, club: @club_b, name: 'B')
    play(@staffel_a, a1, gegner_a, 3, 0) # A 1: 3 Punkte
    play(@staffel_b, gegner_b, a2, 1, 1) # A 2: 1 Punkt

    league = create(:league, game_operation: @go, league_ids_preround: [@staffel_a.id, @staffel_b.id],
                             preround_point_modus: 'full')
    erste = create(:team, league: league, club: @club_a, name: 'Verein A 1')
    zweite = create(:team, league: league, club: @club_a, name: 'verein  a 2')

    table = league.table
    assert_equal 3, entry(table, erste)[:points]
    assert_equal 1, entry(table, zweite)[:points]
  end

  test 'nicht eindeutige Zuordnung gibt keine Punkte statt fremder' do
    a1 = create(:team, league: @staffel_a, club: @club_a, name: 'Verein A 1')
    a2 = create(:team, league: @staffel_b, club: @club_a, name: 'Verein A 2')
    play(@staffel_a, a1, create(:team, league: @staffel_a, club: @club_c), 3, 0)
    play(@staffel_b, a2, create(:team, league: @staffel_b, club: @club_b), 3, 0)

    league = create(:league, game_operation: @go, league_ids_preround: [@staffel_a.id, @staffel_b.id],
                             preround_point_modus: 'full')
    team = create(:team, league: league, club: @club_a, name: 'Verein A')

    assert_equal 0, entry(league.table, team)[:points]
  end

  test 'dieselbe Mannschaft (cup_leagues) wird direkt zugeordnet' do
    a1 = create(:team, league: @staffel_a, club: @club_a, name: 'Verein A 1')
    a2 = create(:team, league: @staffel_a, club: @club_a, name: 'Verein A 2')
    play(@staffel_a, a1, a2, 2, 0)

    playoff = create(:league, game_operation: @go, league_ids_preround: [@staffel_a.id], preround_point_modus: 'full')
    play(playoff, a1, a2, 0, 0)

    table = playoff.table
    assert_equal 4, entry(table, a1)[:points]
    assert_equal 1, entry(table, a2)[:points]
  end

  test 'league_id_preround folgt der ersten Vorrunde und umgekehrt' do
    league = create(:league, game_operation: @go, league_ids_preround: [@staffel_b.id, @staffel_a.id])
    assert_equal @staffel_b.id, league.league_id_preround

    league.update!(league_id_preround: @staffel_a.id)
    assert_equal [@staffel_a.id], league.reload.league_ids_preround

    league.update!(league_ids_preround: [])
    assert_nil league.reload.league_id_preround
  end

  test 'Ring zwischen Vorrunden wird abgewiesen' do
    folge = create(:league, game_operation: @go, league_ids_preround: [@staffel_a.id])

    refute @staffel_a.update(league_ids_preround: [folge.id])
    assert @staffel_a.errors[:league_ids_preround].any?
    refute folge.update(league_ids_preround: [folge.id])
  end

  test 'Ring per update_column endet nicht in einer Endlosschleife' do
    folge = create(:league, game_operation: @go, league_ids_preround: [@staffel_a.id], preround_point_modus: 'full')
    @staffel_a.update_columns(league_ids_preround: [folge.id], preround_point_modus: 'full')

    assert_kind_of Array, folge.table
  end

  test 'unbekannte Stufe wird abgewiesen' do
    league = build(:league, game_operation: @go, preround_transfer_scope: 'alles')
    refute league.valid?
  end

  test 'dependent_on_preround findet Folgeligen über mehrere Stufen' do
    zwischen = create(:league, game_operation: @go, league_ids_preround: [@staffel_a.id, @staffel_b.id])
    meister = create(:league, game_operation: @go, league_ids_preround: [zwischen.id])

    assert_equal [zwischen.id, meister.id].sort, League.dependent_on_preround(@staffel_a.id).sort
    assert_empty League.dependent_on_preround(meister.id)
  end

  test 'Spiel in der Vorrunde leert den Tabellen-Cache der Folgeliga' do
    two_staffeln
    league, = zwischenrunde
    unbeteiligt = create(:league, game_operation: @go)
    game = Game.joins(:game_day).find_by(game_days: { league_id: @staffel_b.id })

    with_real_cache do
      Rails.cache.write("leagues/#{league.id}/table", 'alt')
      Rails.cache.write("leagues/#{unbeteiligt.id}/table", 'alt')
      game.update!(audience: 12)

      assert_nil Rails.cache.read("leagues/#{league.id}/table")
      assert_equal 'alt', Rails.cache.read("leagues/#{unbeteiligt.id}/table")
    end
  end
end
