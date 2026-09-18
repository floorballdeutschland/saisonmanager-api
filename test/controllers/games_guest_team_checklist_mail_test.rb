require 'test_helper'

# Die Gastmannschaften bekommen beim Abschluss des Spielberichts eine Mail mit
# den Antworten des Ausrichters und der Frist, ihnen zu widersprechen.
#
# Vorher gab es diese Mail nicht: Der Ausrichter bekam seine Bestätigung mit
# Einspruchs-Link, das Gespann den Portal-Hinweis, die Gastmannschaft nichts. Am
# FD-Pokalspiel vom 13.09.2026 hatte der Ausrichter „Einladung an das Gastteam
# zugegangen" mit Ja beantwortet, ohne eine Einladung verschickt zu haben; die
# Gastmannschaft erfuhr davon nichts und fand den Spieltag zwei Tage später
# automatisch bestätigt vor.
class GamesGuestTeamChecklistMailTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    create(:setting)

    @sa = create(:state_association, sbk_email: 'sbk@example.de')
    @einladung = @sa.checklist_items.create!(question: 'Einladung an das Gastteam zugegangen?', position: 1)
    @halle = @sa.checklist_items.create!(question: 'Halle 90 Minuten vorher geöffnet?', position: 2)
    @go = create(:game_operation, state_association_id: @sa.id)
    @league = create(:league, game_operation: @go)

    @ausrichter = create(:club, state_association_id: @sa.id, contact_email: 'ausrichter@example.de')
    @gastverein = create(:club, state_association_id: @sa.id, contact_email: 'gastverein@example.de')

    @arena = create(:arena)
    @game_day = GameDay.create!(
      league: @league, arena: @arena, club: @ausrichter, number: 1, date: 3.days.ago.to_date.to_s
    )
    @heim = create(:team, league: @league, club: @ausrichter)
    @gast = create(:team, league: @league, club: @gastverein)
    @game = Game.create!(
      game_day: @game_day,
      home_team: @heim,
      guest_team: @gast,
      game_number: '7',
      start_time: '14:00',
      started: true,
      ended: true,
      forfait: 0,
      overtime: false,
      legacy: false,
      events: [],
      players: { 'home' => [], 'guest' => [] },
      referee1_string: '12345 Eree, Ref'
    )
    @game.update!(checklist_answers: [
      { 'item_id' => @einladung.id, 'question' => @einladung.question, 'answer' => true },
      { 'item_id' => @halle.id, 'question' => @halle.question, 'answer' => false }
    ])

    @tm = create(:user, :tm, team_id: @gast.id, email: 'tm-gast@example.de')
  end

  test 'die Gastmannschaft wird beim Abschluss benachrichtigt' do
    close_match_record_as_admin

    mail = gast_mails.sole
    assert_equal %w[gastverein@example.de tm-gast@example.de], mail.to.sort
    assert_includes mail.subject, 'Spieltagscheckliste bestätigen'
  end

  test 'die Mail nennt alle Antworten des Ausrichters, nicht nur die verneinten' do
    close_match_record_as_admin

    body = gast_mails.sole.body.encoded.then { |b| b.encode('UTF-8').gsub("=\r\n", '') }
    assert_includes body, 'Einladung an das Gastteam zugegangen?'
    assert_includes body, 'Halle 90 Minuten vorher'
    assert_includes body, "#{FrontendUrl.base}/verein/spieltage"
  end

  test 'der Ausrichter bekommt die Gastmannschafts-Mail nicht' do
    close_match_record_as_admin

    # Genau eine Gastmannschaft: Die Heimmannschaft gehört dem Ausrichterverein
    # und bestätigt ihren eigenen Spieltag nicht.
    assert_equal 1, gast_mails.size
    assert_not_includes gast_mails.sole.to, 'ausrichter@example.de'
  end

  test 'ohne Checkliste des Spielbetriebs keine Mail und keine Frist' do
    @sa.checklist_items.destroy_all
    @game.update_columns(checklist_answers: [])

    close_match_record_as_admin

    assert_empty gast_mails
    assert_nil @game_day.reload.team_confirmation_notified_at
  end

  test 'ohne erreichbare Adresse keine Mail und keine Frist' do
    @gastverein.update!(contact_email: nil)
    @tm.destroy!

    close_match_record_as_admin

    assert_empty gast_mails
    # Ohne Benachrichtigung bleibt es bei der Frist ab Ende des Spieltags: Ein
    # Zeitstempel ohne Mail würde das Fenster verlängern, ohne dass jemand
    # etwas erfahren hat.
    assert_nil @game_day.reload.team_confirmation_notified_at
  end

  test 'ein Teammanager ohne Info-Mails bleibt aussen vor, die Vereinspost nicht' do
    @tm.update!(receive_info_mails: false)

    close_match_record_as_admin

    assert_equal ['gastverein@example.de'], gast_mails.sole.to
  end

  test 'der Versandzeitpunkt verschiebt die Frist' do
    close_match_record_as_admin

    @game_day.reload
    assert_not_nil @game_day.team_confirmation_notified_at
    assert_in_delta @game_day.team_confirmation_notified_at + 48.hours,
                    @game_day.team_confirmation_deadline, 1.second
  end

  test 'nach spaetem Abschluss kann die Gastmannschaft noch bestaetigen' do
    # Spieltag vor drei Tagen: Nach der alten Regel (48 h ab Spieltagsende) war
    # das Fenster längst zu, als die Mail rausging.
    close_match_record_as_admin

    login(@tm)
    # as: :json, weil der Endpunkt einen echten Boolean verlangt: Ein
    # Formularwert kaeme als "true" an und wuerde abgewiesen.
    post "/api/v2/user/team_game_days/#{@game_day.id}/teams/#{@gast.id}/confirm",
         params: { properly_conducted: true }, as: :json

    assert_response :created
    assert GameDayTeamConfirmation.exists?(game_day_id: @game_day.id, team_id: @gast.id)
  end

  test 'ohne Benachrichtigung bleibt die alte Frist ab Spieltagsende' do
    request_team_game_days

    spieltag = JSON.parse(response.body).sole
    assert_equal true, spieltag['auto_confirmed']
    assert_equal(
      (Date.parse(@game_day.date).to_datetime.end_of_day.to_time + 48.hours).iso8601,
      spieltag['confirmable_until']
    )
  end

  private

  def gast_mails
    ActionMailer::Base.deliveries.select { |m| m.subject.to_s.start_with?('Spieltagscheckliste bestätigen') }
  end

  def close_match_record_as_admin
    login(create(:user, :admin))
    perform_enqueued_jobs do
      post "/api/v2/user/games/#{@game.id}/game_status", params: { game_status: 'match_record_closed' }
    end
    assert_response :success
  end

  def request_team_game_days
    login(@tm)
    get '/api/v2/user/team_game_days'
    assert_response :success
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
