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
    assert_equal ['tm-gast@example.de'], mail.to
    assert_includes mail.subject, 'Spieltagscheckliste bestätigen'
  end

  # Der Kern der Kaskade: Gibt es einen Teammanager, bleibt der Verein außen
  # vor. Vorher ging dieselbe Mail zusätzlich an Kontaktadresse und
  # Vereinsmanager, für jede Mannschaft des Vereins aufs Neue.
  test 'mit Teammanager bekommt der Verein die Mail nicht' do
    create(:user, :vm, club_id: @gastverein.id, email: 'vm-gast@example.de')

    close_match_record_as_admin

    assert_equal ['tm-gast@example.de'], gast_mails.sole.to
  end

  test 'ohne Teammanager geht die Mail an die Vereinsmanager' do
    @tm.destroy!
    create(:user, :vm, club_id: @gastverein.id, email: 'vm-gast@example.de')
    create(:user, :vm, club_id: @gastverein.id, email: 'vm2-gast@example.de')

    close_match_record_as_admin

    assert_equal %w[vm-gast@example.de vm2-gast@example.de], gast_mails.sole.to.sort
  end

  test 'ohne Teammanager und ohne Vereinsmanager geht die Mail an die Kontaktadresse' do
    @tm.destroy!

    close_match_record_as_admin

    assert_equal ['gastverein@example.de'], gast_mails.sole.to
  end

  # Ein Vereinsmanager, der aus der Vereinspost abgewählt ist, zählt für diese
  # Stufe nicht mit. Bleibt danach niemand übrig, fällt die Mail weiter auf die
  # Kontaktadresse – sonst verschwände sie durch eine Verteiler-Einstellung.
  test 'abgewaehlte Vereinsmanager reichen an die Kontaktadresse weiter' do
    @tm.destroy!
    vm = create(:user, :vm, club_id: @gastverein.id, email: 'vm-gast@example.de')
    @gastverein.update!(notify_excluded_user_ids: [vm.id])

    close_match_record_as_admin

    assert_equal ['gastverein@example.de'], gast_mails.sole.to
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

  # `users.email` hat keine Formatvalidierung. Ein Teammanager, der den Verein
  # verlassen hat, steht oft mit einem kaputten oder gelöschten Postfach weiter
  # an der Mannschaft -- sonst besetzte er die erste Stufe, die Mail bounct, und
  # beide Auffangnetze blieben ungenutzt, während die Frist weiterläuft.
  test 'eine unzustellbare Teammanager-Adresse reicht an den Verein weiter' do
    @tm.update_columns(email: 'kein-postfach')

    close_match_record_as_admin

    assert_equal ['gastverein@example.de'], gast_mails.sole.to
  end

  test 'eine unbrauchbare Vereinsmanager-Adresse reicht an die Kontaktadresse weiter' do
    @tm.destroy!
    create(:user, :vm, club_id: @gastverein.id, email: 'auch kaputt')

    close_match_record_as_admin

    assert_equal ['gastverein@example.de'], gast_mails.sole.to
  end

  # Auf der Produktion tragen Vereine zwei Adressen mit Semikolon in der
  # Kontaktadresse. Der Mail-Versand zerlegt das in echte Empfaenger -- eine
  # reine Formatpruefung auf das ganze Feld haette diese Vereine aus dem
  # letzten Auffangnetz geworfen und damit ganz unerreichbar gemacht.
  test 'zwei Adressen in einem Feld erreichen beide Postfaecher' do
    @tm.destroy!
    @gastverein.update_columns(contact_email: 'vorstand@gast.de; geschaeftsstelle@gast.de')

    close_match_record_as_admin

    assert_equal %w[geschaeftsstelle@gast.de vorstand@gast.de], gast_mails.sole.to.sort
  end

  # Ein Anzeigename im Adressfeld ist zustellbar. Wuerde er verworfen, verlaere
  # ausgerechnet die Person den Verteiler, an die sich die Mail richtet.
  test 'ein Anzeigename im Adressfeld bleibt Teammanager-Stufe' do
    @tm.update_columns(email: 'Max Muster <max@gast.de>')

    close_match_record_as_admin

    assert_equal ['max@gast.de'], gast_mails.sole.to
  end

  # Abbestellte Info-Mails machen die Stufe leer, nicht die Mannschaft
  # unerreichbar: Die Bestätigung ist eine Pflicht des Vereins und fällt
  # deshalb auf die nächste Stufe durch.
  test 'ein Teammanager ohne Info-Mails reicht an den Verein weiter' do
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
      (ActiveSupport::TimeZone['Europe/Berlin'].parse(@game_day.date).end_of_day + 48.hours).iso8601,
      spieltag['confirmable_until']
    )
  end

  # Der Fragetext in `games.checklist_answers` kommt ungeprueft aus dem Request
  # (`set_checklist_answers` erlaubt `question`). Diese Mail geht an die
  # GEGENSEITE: Ohne die Lesart aus der Verbands-Checkliste koennte ein
  # Ausrichter beliebigen Text ueber den Absender des Saisonmanagers an den
  # Gastverein schicken. Der Einspruchsweg macht es aus demselben Grund so.
  test 'der Fragetext kommt aus der Checkliste des Verbandes, nicht aus der Antwort' do
    answers = @game.checklist_answers.deep_dup
    answers.first['question'] = 'Bitte 500 Euro an IBAN DE00 ueberweisen'
    @game.update!(checklist_answers: answers)

    close_match_record_as_admin

    body = gast_mails.sole.body.encoded.then { |b| b.encode('UTF-8').gsub("=\r\n", '') }
    assert_includes body, 'Einladung an das Gastteam zugegangen?'
    assert_not_includes body, 'IBAN'
  end

  # Der Stempel entsteht erst, wenn die Frist berechnet ist: Sonst haette ein
  # unlesbares Datum das Fenster um 48 Stunden verschoben, ohne dass eine
  # einzige Mail rausgegangen waere.
  test 'ein unlesbares Spieltagsdatum verschiebt die Frist nicht' do
    @game_day.update_columns(date: 'kein Datum')

    assert_raises(Date::Error) { GuestTeamChecklistNotifier.new(@game.reload).notify }

    assert_nil @game_day.reload.team_confirmation_notified_at
    assert_empty gast_mails
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
