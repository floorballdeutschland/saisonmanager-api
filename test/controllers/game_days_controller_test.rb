require 'test_helper'

class GameDaysControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    create(:setting)
    @sa = create(:state_association)
    @go = create(:game_operation, state_association_id: @sa.id)
    @league = create(:league, game_operation: @go)
    @club = create(:club, contact_email: 'ausrichter@example.de')
    @arena = create(:arena)
    @arena2 = create(:arena)
    @game_day = GameDay.create!(league: @league, arena: @arena, club: @club, number: 1, date: '2026-04-01')
    @home = create(:team, league: @league, club: @club)
    @guest = create(:team, league: @league, club: @club)
    @game = Game.create!(game_day: @game_day, home_team: @home, guest_team: @guest,
                         start_time: '14:00', forfait: 0, overtime: false, legacy: false,
                         events: [], players: { 'home' => [], 'guest' => [] })
    @referee = create(:referee, email: 'schiri@example.de')
    RefereeAssignment.create!(game: @game, referee1_id: @referee.id, status: 'published')
  end

  test 'Datumsänderung benachrichtigt die Beteiligten der veröffentlichten Ansetzung' do
    login(create(:user, :admin))

    # Schiri + Ausrichter
    assert_enqueued_emails 2 do
      patch "/api/v2/game_days/#{@game_day.id}", params: { game_day: { date: '2026-04-08' } }
    end
    assert_response :success
  end

  test 'Hallenwechsel benachrichtigt die Beteiligten' do
    login(create(:user, :admin))

    assert_enqueued_emails 2 do
      patch "/api/v2/game_days/#{@game_day.id}", params: { game_day: { arena_id: @arena2.id } }
    end
    assert_response :success
  end

  test 'unveränderte Felder (Datum/Halle) lösen keinen Versand aus' do
    login(create(:user, :admin))

    assert_no_enqueued_emails do
      patch "/api/v2/game_days/#{@game_day.id}", params: { game_day: { number: 2 } }
    end
    assert_response :success
  end

  test 'kein Versand ohne veröffentlichte Ansetzung' do
    @game.reload.referee_assignment.update!(status: 'tentative')
    login(create(:user, :admin))

    assert_no_enqueued_emails do
      patch "/api/v2/game_days/#{@game_day.id}", params: { game_day: { date: '2026-04-08' } }
    end
    assert_response :success
  end

  # Sentry SAISONMANAGER-3F: Das Anlegen mit leerer Ausrichter-Auswahl kam als
  # 500 zurueck, weil die 0 des Formulars ungebremst in den Fremdschluessel lief.
  test 'Anlegen mit leerer Ausrichter-Auswahl legt den Spieltag an' do
    login(create(:user, :admin))

    post '/api/v2/game_days',
         params: { game_day: { league_id: @league.id, number: 2, date: '2026-05-01', club_id: 0, arena_id: 0 } }

    assert_response :created
    angelegt = GameDay.order(:id).last
    assert_nil angelegt.club_id
    assert_nil angelegt.arena_id
  end

  test 'Anlegen mit unbekanntem Ausrichter meldet den Fehler, statt zu scheitern' do
    login(create(:user, :admin))

    post '/api/v2/game_days',
         params: { game_day: { league_id: @league.id, number: 3, date: '2026-05-01',
                               club_id: Club.maximum(:id).to_i + 1000 } }

    assert_response :bad_request
    # Der Text landet unveraendert in der Meldung im Frontend, er muss also
    # lesbar sein. `errors` traegt die Zuordnung zum Feld. Der Attributname
    # bleibt englisch, wie bei jeder anderen Meldung hier auch (de.yml deckt
    # bewusst nur Datums- und Zeitformate ab, s. config/application.rb).
    fehler = JSON.parse(response.body)
    assert_kind_of String, fehler['error']
    assert_match(/club/i, fehler['error'])
    assert fehler['errors'].key?('club'), "keine Feldzuordnung: #{fehler['errors']}"
  end

  private

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
