require 'test_helper'

# Die Wege, auf denen der Nachname oeffentlich herausfaellt. Alle lesen ihn aus
# dem Spielbericht-Schnappschuss (`games.players`) und nicht aus dem
# Spielerdatensatz -- ein umbenanntes Profil wuerde hier nichts aendern, deshalb
# haengt die Behandlung an der Spieler-ID. Der Vorname bleibt ueberall stehen.
class GamePublicLastNameHiddenTest < ActiveSupport::TestCase
  PLACEHOLDER = PublicPlayerNames::HIDDEN_LAST_NAME

  setup do
    create(:setting)
    @user = create(:user, :admin)
    @sa = create(:state_association)
    @go = create(:game_operation, state_association_id: @sa.id)
    @league = create(:league, game_operation: @go)
    @club = create(:club, state_association_id: @sa.id)
    @arena = create(:arena)
    @game_day = GameDay.create!(league: @league, arena: @arena, club: @club, number: 1, date: '2026-01-10')
    @home = create(:team, league: @league, club: @club)
    @guest = create(:team, league: @league, club: @club)

    @player = create(:player, first_name: 'Pierre', last_name: 'Beispiel')
    @mate = create(:player, first_name: 'Anna', last_name: 'Meier')

    @game = Game.create!(
      game_day: @game_day, home_team: @home, guest_team: @guest,
      started: true, ended: true, forfait: 0, overtime: false, legacy: false,
      events: [{ 'row' => 1, 'period' => 1, 'time' => '01:00', 'home_goals' => 1, 'guest_goals' => 0,
                 'event_team' => 'home', 'home_number' => '7', 'home_assist' => '9' }],
      players: {
        'home' => [
          { 'player_id' => @player.id, 'player_firstname' => 'Pierre', 'player_name' => 'Beispiel',
            'trikot_number' => '7', 'goalkeeper' => false },
          { 'player_id' => @mate.id, 'player_firstname' => 'Anna', 'player_name' => 'Meier',
            'trikot_number' => '9', 'goalkeeper' => false }
        ],
        'guest' => []
      },
      starting_players: { 'home' => { 'center' => @player.id }, 'guest' => {} },
      awards: { 'home' => { 'mvp' => @player.id }, 'guest' => {} }
    )
  end

  def hide!
    @player.hide_public_last_name!(@user.id)
    @game.reload
  end

  test 'die Aufstellung im Spielbericht laesst den Nachnamen weg' do
    hide!
    lineup = @game.full_hash[:players]['home']

    entry = lineup.find { |p| p['player_id'] == @player.id }
    assert_equal PLACEHOLDER, entry['player_name']
    # Der Vorname bleibt: Er ist die Stufe, auf die dieser Schalter reduziert.
    assert_equal 'Pierre', entry['player_firstname']
    # Trikotnummer und Position stehen weiter, der Bericht bleibt lesbar.
    assert_equal '7', entry['trikot_number']
    assert_equal 'Feld', entry['position']

    mate = lineup.find { |p| p['player_id'] == @mate.id }
    assert_equal 'Meier', mate['player_name']
  end

  test 'Startaufstellung und Auszeichnung lassen den Nachnamen weg' do
    hide!
    hash = @game.full_hash

    center = hash[:starting_players]['home'].find { |p| p[:position] == 'center' }
    assert_equal PLACEHOLDER, center[:player_name]
    assert_equal 'Pierre', center[:player_firstname]

    mvp = hash[:awards]['home'].first
    assert_equal PLACEHOLDER, mvp[:player_name]
    assert_equal 'Pierre', mvp[:player_firstname]
  end

  test 'ohne den Schalter bleibt der Spielbericht unveraendert' do
    hash = @game.full_hash

    entry = hash[:players]['home'].find { |p| p['player_id'] == @player.id }
    assert_equal 'Beispiel', entry['player_name']
    assert_equal 'Pierre', entry['player_firstname']
    assert_equal 'Beispiel', hash[:awards]['home'].first[:player_name]
  end

  test 'die Scorerliste der Liga fuehrt nur noch den Vornamen' do
    hide!
    entry = @league.scorer.find { |s| s[:player_id] == @player.id }

    assert_equal PLACEHOLDER, entry[:last_name]
    assert_equal 'Pierre', entry[:first_name]
    assert_equal 1, entry[:goals]

    mate = @league.scorer.find { |s| s[:player_id] == @mate.id }
    assert_equal 'Meier', mate[:last_name]
  end

  test 'die Scorerliste zieht den Nachnamen nicht aus dem Spielerdatensatz nach' do
    # Der Rueckfall auf den Datensatz greift, wenn der Schnappschuss keinen
    # Namen traegt (sehr alte Importe). Der weggelassene Nachname ist leer und
    # sieht damit genauso aus -- ohne die Reihenfolge in League#scorer holte
    # `presence` an dieser Stelle den echten Nachnamen zurueck.
    @game.update_column(:players, {
                          'home' => [{ 'player_id' => @player.id, 'player_firstname' => nil,
                                       'player_name' => nil, 'trikot_number' => '7' }],
                          'guest' => []
                        })
    hide!

    entry = @league.scorer.find { |s| s[:player_id] == @player.id }
    assert_equal PLACEHOLDER, entry[:last_name]
    assert_not_includes @league.scorer.to_json, 'Beispiel'
  end

  test 'die Overlay-Nutzlast zeigt nur noch den Vornamen' do
    hide!
    payload = OverlayPayload.new(@game).as_json
    goal = payload[:events].find { |e| e[:event_type] == :goal }

    # Die Bauchbinde kuerzt den Vornamen sonst zur Initiale ("P. Beispiel").
    # Ohne Nachnamen faellt sie auf den vollen Vornamen zurueck.
    assert_equal 'Pierre', goal[:scorer_name]
    assert_equal 'Pierre', goal[:scorer_full_name]
    assert_not_includes payload.to_json, 'Beispiel'
    # Der Vorlagengeber steht weiter mit vollem Namen da.
    assert_equal 'A. Meier', goal[:assist_name]
  end
end
