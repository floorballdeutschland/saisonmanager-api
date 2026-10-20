require 'test_helper'

class GameRefereeReportsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  # Strafkatalog wie auf Prod (Stand 08.10.2026): id 5 ist die TECHNISCHE
  # Matchstrafe, id 6 die volle. Bis api#789 hing der Workflow an id 5.
  PENALTIES = {
    '1' => { 'mapping' => 'penalty_2', 'name' => '2 Minuten' },
    '5' => { 'mapping' => 'penalty_ms_tech', 'name' => 'Matchstrafe (technisch)' },
    '6' => { 'mapping' => 'penalty_ms_full', 'name' => 'Matchstrafe' }
  }.freeze
  MATCH = { 'id' => 1, 'penalty_id' => '6' }.freeze
  TECH = { 'id' => 2, 'penalty_id' => '5' }.freeze

  setup do
    create(:setting, penalties: PENALTIES)
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
                         overtime: false, legacy: false, events: [MATCH], players: { 'home' => [], 'guest' => [] })
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
  test 'Foto als Berichtsformular wird abgewiesen und nicht weitergeleitet' do
    login(@user)
    assert_no_enqueued_emails do
      upload_report(file: fixture_file_upload('foto.png', 'image/png'))
    end
    assert_response :unprocessable_entity
    assert_equal ['Nur PDF-Dateien bis 5 MB sind zulässig, Fotos werden nicht angenommen.'],
                 response.parsed_body['errors']
    assert_nil @game.reload.game_referee_report
  end

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

  # --- Empfänger je Strafart (api#789) ---------------------------------------

  test 'automatisch: Matchstrafe geht nur an die VSK' do
    assert_forwarded_to %w[vsk@example.de], proposals: 0
  end

  test 'automatisch: technische Matchstrafe geht nur an die SBK' do
    @game.update!(events: [TECH])
    assert_forwarded_to %w[sbk@example.de], proposals: 0
  end

  test 'automatisch: besonderes Ereignis geht nur an die SBK' do
    @game.update!(events: [], special_event: true)
    assert_forwarded_to %w[sbk@example.de], proposals: 0
  end

  test 'automatisch: Mischfall geht mit je eigener Mail an VSK und SBK' do
    @game.update!(events: [MATCH, TECH], special_event: true)
    mails = assert_forwarded_to %w[vsk@example.de sbk@example.de], proposals: 0
    sbk_body = body_of(mails.find { |m| m.to == ['sbk@example.de'] })
    # Die Matchstrafe ist Sache der VSK und steht nicht in der SBK-Mail.
    assert_includes sbk_body, 'eine technische Matchstrafe und ein besonderes Ereignis'
    assert_not_includes sbk_body, 'eine Matchstrafe'
  end

  test 'manuell: Matchstrafe geht an die SBK mit Verfahrensvorschlag und Aufforderung' do
    @sa.update!(manual_proceeding_creation: true)
    mails = assert_forwarded_to %w[sbk@example.de], proposals: 1
    body = body_of(mails.first)
    assert_includes body, 'Verfahren vor der VSK einzuleiten'
    assert_includes body, '/verwaltung/verfahrensvorschlaege'
  end

  test 'manuell: technische Matchstrafe geht an die SBK ohne Verfahrensvorschlag' do
    @sa.update!(manual_proceeding_creation: true)
    @game.update!(events: [TECH])
    mails = assert_forwarded_to %w[sbk@example.de], proposals: 0
    assert_not_includes body_of(mails.first), 'Verfahren vor der VSK einzuleiten'
  end

  test 'manuell: besonderes Ereignis geht an die SBK ohne Verfahrensvorschlag' do
    @sa.update!(manual_proceeding_creation: true)
    @game.update!(events: [], special_event: true)
    assert_forwarded_to %w[sbk@example.de], proposals: 0
  end

  test 'manuell: Mischfall ist eine SBK-Mail mit allen Gründen plus Verfahrensvorschlag' do
    @sa.update!(manual_proceeding_creation: true)
    @game.update!(events: [MATCH, TECH], special_event: true)
    mails = assert_forwarded_to %w[sbk@example.de], proposals: 1
    assert_includes body_of(mails.first),
                    'eine Matchstrafe, eine technische Matchstrafe und ein besonderes Ereignis'
  end

  test 'eine Zeitstrafe allein leitet nichts weiter' do
    @game.update!(events: [{ 'id' => 3, 'penalty_id' => '1' }])
    assert_forwarded_to [], proposals: 0
  end

  test 'das eingefrorene Mapping am Ereignis geht vor die id' do
    # Alt-Ereignis aus einem Import mit anderer id-Vergabe: id 5, aber volle
    # Matchstrafe laut eingefrorenem Label.
    @game.update!(events: [{ 'id' => 4, 'penalty_id' => '5', 'penalty_mapping' => 'penalty_ms_full' }])
    assert_forwarded_to %w[vsk@example.de], proposals: 0
  end

  test 'die SBK-Adresse wird vom übergeordneten Verband geerbt' do
    # Schalter kommen vom übergeordneten Verband (settings_source), die Adresse
    # nur, wenn der eigene Eintrag fehlt.
    parent = StateAssociation.create!(name: 'Dach', sbk_email: 'dach-sbk@example.de', report_form_email_enabled: true)
    @sa.update!(sbk_email: nil, parent_id: parent.id)
    @game.update!(events: [TECH])
    assert_forwarded_to %w[dach-sbk@example.de], proposals: 0
  end

  # --- Erneuter Upload im manuellen Modus ------------------------------------

  test 'manuell: erneuter Upload bei offenem Vorschlag fordert erneut zur Eröffnung auf' do
    @sa.update!(manual_proceeding_creation: true)
    assert_forwarded_to %w[sbk@example.de], proposals: 1
    mails = assert_forwarded_to %w[sbk@example.de], proposals: 0
    assert_includes body_of(mails.first), 'Verfahren vor der VSK einzuleiten'
    assert_equal 'pending', ProceedingProposal.find_by(game_id: @game.id).status
  end

  test 'manuell: erneuter Upload nach Ablehnung macht den Vorschlag wieder offen' do
    @sa.update!(manual_proceeding_creation: true)
    sbk = User.create!(user_name: "sbk_#{SecureRandom.hex(4)}", password: 'password123',
                       password_confirmation: 'password123', permissions: [], teams: [])
    ProceedingProposal.create!(game: @game, state_association: @sa, status: 'rejected',
                               decided_by_id: sbk.id, decided_at: 1.day.ago)

    mails = assert_forwarded_to %w[sbk@example.de], proposals: 0
    assert_includes body_of(mails.first), 'Verfahren vor der VSK einzuleiten'
    proposal = ProceedingProposal.find_by(game_id: @game.id)
    assert_equal 'pending', proposal.status
    assert_nil proposal.decided_by_id
    assert_nil proposal.decided_at
    assert_equal @user.id, proposal.created_by_id
  end

  test 'manuell: erneuter Upload bei eröffnetem Verfahren geht direkt an die VSK, SBK nur zur Kenntnis' do
    @sa.update!(manual_proceeding_creation: true)
    ProceedingProposal.create!(game: @game, state_association: @sa, status: 'opened', decided_at: 1.day.ago)

    mails = assert_forwarded_to %w[vsk@example.de sbk@example.de], proposals: 0
    sbk_body = body_of(mails.find { |m| m.to == ['sbk@example.de'] })
    assert_includes sbk_body, 'bereits eröffnet'
    assert_not_includes sbk_body, 'Verfahren vor der VSK einzuleiten'
    assert_equal 'opened', ProceedingProposal.find_by(game_id: @game.id).status
  end

  test 'ohne SBK-Adresse geht der Bericht ans Ansetzungs-Postfach' do
    @sa.update!(sbk_email: nil)
    @game.update!(events: [TECH])
    assert_forwarded_to [RefereeMailer::REPLY_TO], proposals: 0
  end

  # --- GET: Upload-Bereich ---------------------------------------------------

  test 'GET nennt angesetzten Schiris Pflicht und Empfänger' do
    @game.update!(events: [MATCH, TECH])
    login(@user)
    get "/api/v2/games/#{@game.id}/referee_report"
    assert_response :success
    json = response.parsed_body
    assert_equal true, json['required']
    assert_equal 'vsk_and_sbk', json['recipient']
    assert_equal false, json['uploaded']
  end

  test 'GET im manuellen Modus nennt die SBK' do
    @sa.update!(manual_proceeding_creation: true)
    login(@user)
    get "/api/v2/games/#{@game.id}/referee_report"
    assert_equal 'sbk', response.parsed_body['recipient']
  end

  test 'GET ohne Matchstrafe und ohne Ereignis verlangt keinen Bericht' do
    @game.update!(events: [{ 'id' => 3, 'penalty_id' => '1' }])
    login(@user)
    get "/api/v2/games/#{@game.id}/referee_report"
    assert_equal false, response.parsed_body['required']
  end

  test 'GET bei abgeschaltetem Berichtsworkflow verlangt keinen Bericht' do
    @sa.update!(report_form_email_enabled: false)
    login(@user)
    get "/api/v2/games/#{@game.id}/referee_report"
    assert_equal false, response.parsed_body['required']
  end

  test 'GET verrät Unbeteiligten nicht, dass ein Bericht verlangt ist' do
    @game.update!(events: [], special_event: true)
    other = User.create!(user_name: "other_#{SecureRandom.hex(4)}", password: 'password123',
                         password_confirmation: 'password123', permissions: [], teams: [])
    login(other)
    get "/api/v2/games/#{@game.id}/referee_report"
    assert_response :success
    assert_equal({ 'uploaded' => false, 'required' => false, 'recipient' => nil }, response.parsed_body)
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

  # Lädt hoch, stellt die Mails tatsächlich zu und prüft Empfänger und Zahl der
  # Verfahrensvorschläge. Gibt die zugestellten Mails zurück.
  def assert_forwarded_to(recipients, proposals:)
    login(@user)
    ActionMailer::Base.deliveries.clear
    assert_difference -> { ProceedingProposal.count }, proposals do
      perform_enqueued_jobs { upload_report }
    end
    assert_response :created
    mails = ActionMailer::Base.deliveries.to_a
    assert_equal recipients.sort, mails.flat_map(&:to).sort
    mails.each { |m| assert_equal 1, m.attachments.size, 'der Bericht muss anhängen' }
    mails
  end

  def body_of(mail)
    (mail.html_part || mail).decoded
  end

  def upload_report(file: fixture_file_upload('dokument.pdf', 'application/pdf'))
    post "/api/v2/games/#{@game.id}/referee_report", params: { file: file }
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
