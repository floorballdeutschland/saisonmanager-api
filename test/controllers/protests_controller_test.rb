require 'test_helper'

# Upload des Protestformulars über den Link an die Protestpartei, ohne
# Anmeldung.
class ProtestsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    create(:setting)
    @sa = create(:state_association, sbk_email: 'sbk@example.de')
    @go = create(:game_operation, state_association_id: @sa.id)
    @league = create(:league, game_operation: @go)
    @club = create(:club)
    @game_day = GameDay.create!(league: @league, arena: create(:arena), club: @club, number: 1, date: '2026-11-08')
    @home = create(:team, league: @league, club: @club, name: 'Heim')
    @guest = create(:team, league: @league, club: create(:club), name: 'Gast')
    @game = Game.create!(game_day: @game_day, home_team: @home, guest_team: @guest, forfait: 0,
                         overtime: false, legacy: false, events: [], players: { 'home' => [], 'guest' => [] },
                         game_number: '42', protest: true, protest_parties: %w[guest])
    @protest, @token = GameProtest.create_with_token!(game: @game, party: 'guest', recipients: ['gast@example.de'])
  end

  def pdf
    Rack::Test::UploadedFile.new(file_fixture('dokument.pdf'), 'application/pdf')
  end

  test 'ein unbekannter Token ist ungültig' do
    get '/api/v2/protests/falsch'
    assert_response :gone
  end

  test 'zeigt nur die Kopfdaten des einen Spiels' do
    get "/api/v2/protests/#{@token}"

    assert_response :success
    body = response.parsed_body
    assert_equal 'open', body['status']
    assert_equal 'Gastteam (Gast)', body['party_label']
    assert_equal '42', body['game_number']
    assert_equal %w[date filename game_number guest_team home_team league party_label start_time status
                    submitted_at], body.keys.sort
  end

  test 'nimmt ein PDF an, speichert es und schickt es mit Anhang an die SBK' do
    perform_enqueued_jobs do
      post "/api/v2/protests/#{@token}", params: { file: pdf }
    end

    assert_response :created
    @protest.reload
    assert @protest.submitted?
    assert @protest.file.attached?

    mail = ActionMailer::Base.deliveries.find { |m| m.subject.include?('Protestformular eingegangen') }
    assert mail
    assert_equal ['sbk@example.de'], mail.to
    assert_equal ['dokument.pdf'], mail.attachments.map(&:filename)
  end

  test 'ein zweiter Upload über denselben Link wird abgelehnt' do
    post "/api/v2/protests/#{@token}", params: { file: pdf }
    assert_response :created

    post "/api/v2/protests/#{@token}", params: { file: pdf }
    assert_response :unprocessable_entity
    assert_includes response.parsed_body['message'], 'bereits'
  end

  test 'ein Foto wird abgelehnt und nichts gespeichert' do
    foto = Rack::Test::UploadedFile.new(file_fixture('foto.png'), 'image/png')

    assert_no_enqueued_emails do
      post "/api/v2/protests/#{@token}", params: { file: foto }
    end

    assert_response :unprocessable_entity
    assert_includes response.parsed_body['message'], 'Nur PDF'
    assert_not @protest.reload.submitted?
  end

  test 'ohne Datei kommt eine verständliche Meldung' do
    post "/api/v2/protests/#{@token}"
    assert_response :unprocessable_entity
    assert_includes response.parsed_body['message'], 'PDF'
  end

  test 'ohne SBK-Adresse geht das Formular an das Ansetzungs-Postfach' do
    @sa.update!(sbk_email: nil)
    perform_enqueued_jobs do
      post "/api/v2/protests/#{@token}", params: { file: pdf }
    end

    mail = ActionMailer::Base.deliveries.find { |m| m.subject.include?('Protestformular eingegangen') }
    assert_equal [RefereeMailer::REPLY_TO], mail.to
  end

  test 'die Mail an die SBK nennt Partei, Zeitpunkt und den Weg zur Übersicht' do
    perform_enqueued_jobs do
      post "/api/v2/protests/#{@token}", params: { file: pdf }
    end

    mail = ActionMailer::Base.deliveries.find { |m| m.subject.include?('Protestformular eingegangen') }
    body = (mail.html_part || mail).decoded.gsub(/\s+/, ' ')
    assert_includes body, 'Gastteam (Gast)'
    assert_includes body, '08.11.2026'
    assert_includes body, '/verwaltung/spielberichte'
    assert_match(/\d{2}\.\d{2}\.\d{4} um \d{2}:\d{2} Uhr/, body)
  end

  test 'nach dem Zurücknehmen der Partei gilt ein offener Link nicht mehr' do
    @game.update!(protest_parties: %w[referees])

    get "/api/v2/protests/#{@token}"
    assert_response :gone
    assert_includes response.parsed_body['message'], 'zurückgenommen'

    post "/api/v2/protests/#{@token}", params: { file: pdf }
    assert_response :gone
    assert_not @protest.reload.submitted?
  end

  test 'ein hochgeladenes Formular bleibt nach dem Zurücknehmen einsehbar' do
    post "/api/v2/protests/#{@token}", params: { file: pdf }
    @game.update!(protest: false)

    get "/api/v2/protests/#{@token}"
    assert_response :success
    assert_equal 'submitted', response.parsed_body['status']
  end

  test 'die Antwort enthält weder Token noch Adressen' do
    get "/api/v2/protests/#{@token}"

    assert_not_includes response.body, @token
    assert_not_includes response.body, 'gast@example.de'
  end
end
