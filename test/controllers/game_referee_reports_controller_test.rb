require 'test_helper'

class GameRefereeReportsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @sa = StateAssociation.create!(name: 'LV', vsk_email: 'vsk@example.de', sbk_email: 'sbk@example.de',
                                   report_form_email_enabled: true)
    @go = GameOperation.create!(name: 'GO', short_name: 'GO', state_association_id: @sa.id)
    @league = League.create!(game_operation: @go, name: 'Liga', season_id: '18', table_modus: 'classic')
    @club = Club.create!(state_association_id: @sa.id)
    @arena = Arena.create!(name: 'Halle', city: 'Stadt')
    @game_day = GameDay.create!(league: @league, arena: @arena, club: @club, number: 1, date: '2026-02-01')
    @home = Team.create!(league: @league, club: @club, name: 'H')
    @guest = Team.create!(league: @league, club: @club, name: 'G')
    @game = Game.create!(game_day: @game_day, home_team: @home, guest_team: @guest, forfait: 0,
                         overtime: false, legacy: false, events: [], players: { 'home' => [], 'guest' => [] })
    @referee = Referee.create!(vorname: 'Ref', nachname: 'Eree', lizenznummer: 12_345)
    @user = User.create!(
      user_name: "refuser_#{SecureRandom.hex(4)}",
      password: 'password123',
      password_confirmation: 'password123',
      permissions: [],
      teams: [],
      referee_id: @referee.id
    )
    RefereeAssignment.create!(game: @game, referee1_id: @referee.id, status: 'published')
  end

  test 'aktivierter Workflow versendet Bericht per E-Mail an die VSK' do
    login(@user)
    assert_enqueued_emails 1 do
      upload_report
    end
    assert_response :created
  end

  # `assert_enqueued_emails` allein prueft diesen Aufrufweg nicht zu Ende:
  # `deliver_later` serialisiert nur die Argumente, der Mailer laeuft dabei
  # nicht. Eine falsche Parameterzahl an dieser Stelle -- api#564 hat hier zwei
  # Parameter entfernt -- waere fuer CI unsichtbar geblieben und erst beim
  # Zustellen in Produktion aufgeschlagen, also lautlos fuer den Schiri, der den
  # Bericht hochgeladen hat.
  #
  # Zugleich die einzige Stelle, die das aus dem Spiel abgeleitete Gespann
  # prueft: Vorher gab der Controller referee1/referee2 mit, jetzt liest der
  # Mailer sie selbst aus `game.referee_assignment`. Waere die Ableitung leer,
  # bliebe der Schiedsrichter-Block im View still leer.
  test 'die zugestellte VSK-Mail nennt das Gespann und traegt keine Unterschrift' do
    login(@user)

    perform_enqueued_jobs do
      upload_report
      assert_response :created
    end

    mail = ActionMailer::Base.deliveries.last
    assert mail, 'die Mail muss tatsaechlich zugestellt worden sein'
    body = (mail.html_part || mail).decoded
    assert_includes body, 'Ref Eree'
    # Der automatische Weg kennt keine entscheidende Person: keine Grussformel.
    assert_not_includes body, 'Mit sportlichen'
  end

  test 'deaktivierter Workflow versendet keine E-Mail' do
    @sa.update!(report_form_email_enabled: false)
    login(@user)
    assert_no_enqueued_emails do
      upload_report
    end
    assert_response :created
  end

  test 'manueller Verfahrensvorschlag hat Vorrang und versendet keine E-Mail' do
    @sa.update!(manual_proceeding_creation: true)
    login(@user)
    assert_no_enqueued_emails do
      assert_difference -> { ProceedingProposal.count }, 1 do
        upload_report
      end
    end
    assert_response :created
  end

  test 'deaktivierter Berichtsworkflow erzeugt auch bei manual_proceeding_creation keinen Verfahrensvorschlag' do
    @sa.update!(report_form_email_enabled: false, manual_proceeding_creation: true)
    login(@user)
    assert_no_enqueued_emails do
      assert_no_difference -> { ProceedingProposal.count } do
        upload_report
      end
    end
    assert_response :created
  end

  test 'maßgeblich ist der LV des Spielbetriebs, nicht der des Ausrichtervereins' do
    club_sa = StateAssociation.create!(name: 'Ausrichter-LV', vsk_email: 'fremd@example.de',
                                       report_form_email_enabled: false)
    @club.update!(state_association_id: club_sa.id)
    login(@user)

    assert_enqueued_emails 1 do
      upload_report
    end
    assert_response :created
  end

  test 'abgeschalteter Spielbetriebs-LV versendet nichts, auch wenn der Ausrichter-LV aktiv ist' do
    club_sa = StateAssociation.create!(name: 'Ausrichter-LV', vsk_email: 'fremd@example.de',
                                       report_form_email_enabled: true)
    @club.update!(state_association_id: club_sa.id)
    @sa.update!(report_form_email_enabled: false)
    login(@user)

    assert_no_enqueued_emails do
      upload_report
    end
    assert_response :created
  end

  private

  def upload_report
    post "/api/v2/games/#{@game.id}/referee_report",
         params: { file: fixture_file_upload('dokument.pdf', 'application/pdf') }
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
