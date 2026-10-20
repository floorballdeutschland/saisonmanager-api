require 'test_helper'

# Die 24h-Erinnerung an das Berichtsformular hängt am digitalen Berichtsworkflow.
# Maßgeblich ist der LV des Spielbetriebs, nicht der des Ausrichtervereins: ein
# Bundesliga-Spiel in der Halle eines anderen LV folgt dem ausrichtenden
# Spielbetrieb (siehe Game#state_association).
class GamesIncidentReportReminderTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  # Strafkatalog wie auf Prod (Stand 08.10.2026): id 5 ist die TECHNISCHE
  # Matchstrafe, id 6 die volle. Bis api#789 löste nur id 5 die Erinnerung aus.
  PENALTIES = {
    '1' => { 'mapping' => 'penalty_2', 'name' => '2 Minuten' },
    '5' => { 'mapping' => 'penalty_ms_tech', 'name' => 'Matchstrafe (technisch)' },
    '6' => { 'mapping' => 'penalty_ms_full', 'name' => 'Matchstrafe' }
  }.freeze

  setup do
    create(:setting, penalties: PENALTIES)
    @go_sa = create(:state_association, report_form_email_enabled: true)
    @club_sa = create(:state_association, report_form_email_enabled: false)
    @go = create(:game_operation, state_association_id: @go_sa.id)
    @league = create(:league, game_operation: @go)
    @club = create(:club, state_association_id: @club_sa.id)
    @arena = create(:arena)
    @game_day = GameDay.create!(league: @league, arena: @arena, club: @club, number: 1, date: '2026-01-01')
    @home = create(:team, league: @league, club: @club)
    @guest = create(:team, league: @league, club: @club)
    @game = Game.create!(
      game_day: @game_day,
      home_team: @home,
      guest_team: @guest,
      started: true,
      ended: true,
      forfait: 0,
      overtime: false,
      legacy: false, **all_signatures,
      events: [],
      players: { 'home' => [], 'guest' => [] },
      special_event: true,
      referee1_string: '12345 Eree, Ref'
    )
    r1 = create(:referee, email: 'ref1@example.de')
    r2 = create(:referee, email: 'ref2@example.de')
    RefereeAssignment.create!(game: @game, referee1_id: r1.id, referee2_id: r2.id, status: 'published')
  end

  test 'aktivierter Berichtsworkflow des Spielbetriebs-LV löst die Erinnerung aus' do
    login(create(:user, :admin))

    assert_enqueued_emails 1 do
      close_match_record
    end
    assert_response :success
  end

  test 'deaktivierter Berichtsworkflow des Spielbetriebs-LV löst keine Erinnerung aus' do
    @go_sa.update!(report_form_email_enabled: false)
    login(create(:user, :admin))

    assert_no_enqueued_emails do
      close_match_record
    end
    assert_response :success
  end

  test 'der LV des Ausrichtervereins entscheidet nicht über die Erinnerung' do
    @go_sa.update!(report_form_email_enabled: false)
    @club_sa.update!(report_form_email_enabled: true)
    login(create(:user, :admin))

    assert_no_enqueued_emails do
      close_match_record
    end
    assert_response :success
  end

  test 'ohne besonderes Ereignis und ohne Matchstrafe bleibt es still' do
    @game.update!(special_event: false)
    login(create(:user, :admin))

    assert_no_enqueued_emails do
      close_match_record
    end
    assert_response :success
  end

  test 'eine technische Matchstrafe löst die Erinnerung auch ohne besonderes Ereignis aus' do
    @game.update!(special_event: false, events: [{ 'id' => 1, 'penalty_id' => '5', 'penalty_code_id' => '7' }])
    login(create(:user, :admin))

    assert_enqueued_emails 1 do
      close_match_record
    end
    assert_response :success
  end

  # Der eigentliche Fehler aus api#789: 40 von 42 Spielen mit voller
  # Matchstrafe bekamen in zwölf Monaten keine Erinnerung.
  test 'eine volle Matchstrafe löst die Erinnerung aus und nennt die VSK' do
    @game.update!(special_event: false, events: [{ 'id' => 1, 'penalty_id' => '6' }])
    login(create(:user, :admin))

    perform_enqueued_jobs { close_match_record }
    assert_response :success

    body = reminder_body
    assert_includes body, 'ist eine Matchstrafe vermerkt worden'
    assert_includes body, 'an die zuständige VSK weitergeleitet'
    assert_not_includes body, 'Spielausschluss'
  end

  test 'die Erinnerung nennt im Mischfall VSK und SBK' do
    @game.update!(events: [{ 'id' => 1, 'penalty_id' => '6' }])
    login(create(:user, :admin))

    perform_enqueued_jobs { close_match_record }

    body = reminder_body
    assert_includes body, 'eine Matchstrafe und ein besonderes Ereignis'
    assert_includes body, 'an die zuständige VSK und die zuständige SBK weitergeleitet'
  end

  test 'die Erinnerung nennt im manuellen Modus nur die SBK' do
    @go_sa.update!(manual_proceeding_creation: true)
    @game.update!(special_event: false, events: [{ 'id' => 1, 'penalty_id' => '6' }])
    login(create(:user, :admin))

    perform_enqueued_jobs { close_match_record }

    assert_includes reminder_body, 'an die zuständige SBK weitergeleitet'
  end

  test 'eine Zeitstrafe allein löst keine Erinnerung aus' do
    @game.update!(special_event: false, events: [{ 'id' => 1, 'penalty_id' => '1' }])
    login(create(:user, :admin))

    assert_no_enqueued_emails do
      close_match_record
    end
  end

  private

  def reminder_body
    mail = ActionMailer::Base.deliveries.find { |m| m.subject.include?('Berichtsformular') }
    assert mail, 'die Erinnerung muss zugestellt worden sein'
    (mail.html_part || mail).decoded.gsub(/\s+/, ' ')
  end

  def close_match_record
    post "/api/v2/user/games/#{@game.id}/game_status", params: { game_status: 'match_record_closed' }
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
