require 'test_helper'

# Eine Sperre muss beim Aufstellen sichtbar werden -- auch dann, wenn sie NICHT
# in der Lizenzhistorie steht.
#
# `Player#write_suspended_status!` stempelt den Status 9 nur bei den
# Geltungsbereichen `all` und `team`. Eine Wettbewerbs- oder Ligasperre betrifft
# je nach Auswahl viele Lizenzen, teils in fremden Verbaenden, und steht deshalb
# ausschliesslich in der Sperrtabelle.
#
# `lineup_license_warning` las bis #604 allein die Historie und sah eine solche
# Sperre gar nicht: Der Gesperrte galt als spielberechtigt, lief auf, und weil
# `count_closed_game!` nur `eligible_for_team?` prueft und nicht die
# Aufstellung, zaehlte das Spiel obendrein als abgesessen. Nach zwei Spielen hob
# sich die Sperre selbst auf, ohne je gewirkt zu haben.
class GamesLineupSuspensionTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @sa = create(:state_association)
    @go = create(:game_operation, state_association: @sa)
    @league = create(:league, :current_season, game_operation: @go, league_modus: 'league',
                                               age_group: 'Herren', field_size: 'GF')
    @club = create(:club, game_operation: @go)
    @home_team = create(:team, league: @league, club: @club)
    @guest_team = create(:team, league: @league, club: create(:club))
    game_day = GameDay.create!(league: @league, arena: create(:arena), club: @club,
                               number: 1, date: '2026-01-10')
    @game = Game.create!(game_day: game_day, home_team: @home_team, guest_team: @guest_team,
                         forfait: 0, overtime: false, legacy: false,
                         events: [], players: { 'home' => [], 'guest' => [] })

    @player = create(:player,
                     clubs: [{ 'club_id' => @club.id, 'home_club' => true }],
                     with_licenses: [{ team: @home_team, status: License::APPROVED }])

    @admin = create(:user, :admin)
    login(@admin)
  end

  test 'ohne Sperre gibt es keine Warnung' do
    assert_nil aufstellen(@player, 7)
  end

  test 'eine Wettbewerbssperre warnt beim Aufstellen' do
    @player.suspend!(scope: { kind: PlayerSuspension::SCOPE_COMPETITION, league: @league },
                     games_total: 2, reason: 'Taetlichkeit', user_id: @admin.id)

    warnung = aufstellen(@player, 7)

    assert_not_nil warnung, 'eine Wettbewerbssperre muss beim Aufstellen auffallen'
    assert_match(/gesperrt/, warnung)
  end

  test 'eine Ligasperre warnt beim Aufstellen' do
    @player.suspend!(scope: { kind: PlayerSuspension::SCOPE_LEAGUE, league: @league },
                     games_total: 1, reason: 'Taetlichkeit', user_id: @admin.id)

    warnung = aufstellen(@player, 8)

    assert_not_nil warnung
    assert_match(/gesperrt/, warnung)
  end

  # Gegenprobe: Eine Sperre auf eine ANDERE Liga darf hier nicht warnen.
  test 'eine Ligasperre auf eine fremde Liga warnt nicht' do
    andere = create(:league, :current_season, game_operation: @go, league_modus: 'league')
    @player.suspend!(scope: { kind: PlayerSuspension::SCOPE_LEAGUE, league: andere },
                     games_total: 1, reason: 'Taetlichkeit', user_id: @admin.id)

    assert_nil aufstellen(@player, 9)
  end

  # Die beiden Geltungsbereiche mit Stempel bleiben unveraendert: Der Statuszweig
  # darueber greift zuerst, es gibt keine doppelte Meldung.
  test 'eine spielerweite Sperre meldet weiterhin den Lizenzstatus' do
    @player.suspend!(scope: { kind: PlayerSuspension::SCOPE_ALL },
                     valid_until: 30.days.from_now.to_date, reason: 'Taetlichkeit',
                     user_id: @admin.id)

    warnung = aufstellen(@player, 10)

    assert_match(/nicht erteilt/, warnung)
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end

  def aufstellen(player, trikot_number)
    post "/api/v2/user/games/#{@game.id}/lineup/home/add_player",
         params: { player_id: player.id, trikot_number: trikot_number }

    assert_response :success
    JSON.parse(response.body)['warning']
  end
end
