require 'test_helper'

# Protestformulare in der SBK-Arbeitsansicht: Metadaten in der Übersicht, die
# Datei nur auf Abruf und nur für Admin und SBK des Spielbetriebs.
module Admin
  class GameProtestsControllerTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting, current_season_id: '18')
      @go = create(:game_operation, state_association_id: create(:state_association).id)
      @league = create(:league, :current_season, game_operation: @go)
      @club = create(:club)
      @game_day = GameDay.create!(league: @league, arena: create(:arena), club: @club,
                                  number: 1, date: Date.current.to_s)
      @game = Game.create!(game_day: @game_day, home_team: create(:team, league: @league, club: @club),
                           guest_team: create(:team, league: @league, club: create(:club)),
                           forfait: 0, overtime: false, legacy: false, events: [],
                           players: { 'home' => [], 'guest' => [] },
                           protest: true, protest_parties: %w[guest referees other])
      @protest, = GameProtest.create_with_token!(game: @game, party: 'guest', recipients: ['gast@example.de'])
      @protest.file.attach(io: file_fixture('dokument.pdf').open, filename: 'protest.pdf',
                           content_type: 'application/pdf')
      @protest.update!(submitted_at: Time.current)
      GameProtest.create_with_token!(game: @game, party: 'referees', recipients: [])
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end

    test 'die SBK des Spielbetriebs bekommt die Datei' do
      login(create(:user, :sbk_scoped, game_operation_id: @go.id))
      get "/api/v2/admin/games/#{@game.id}/protests/guest/file"

      assert_response :success
      assert_equal 'protest.pdf', response.parsed_body['filename']
      assert response.parsed_body['url'].present?
    end

    test 'eine fremde SBK bekommt sie nicht' do
      other = create(:game_operation, state_association_id: create(:state_association).id)
      login(create(:user, :sbk_scoped, game_operation_id: other.id))
      get "/api/v2/admin/games/#{@game.id}/protests/guest/file"

      assert_response :forbidden
    end

    test 'ohne Formular kommt 404 mit Meldung' do
      login(create(:user, :admin))
      get "/api/v2/admin/games/#{@game.id}/protests/referees/file"

      assert_response :not_found
    end

    test 'die SBK schickt den Link an eine eingegebene Adresse, der alte wird ungültig' do
      referees = @game.game_protests.find_by(party: 'referees')
      old_digest = referees.token_digest
      login(create(:user, :sbk_scoped, game_operation_id: @go.id))

      assert_enqueued_emails 1 do
        post "/api/v2/admin/games/#{@game.id}/protests/referees/resend", params: { email: 'schiri@example.de' },
                                                                          as: :json
      end

      assert_response :success
      assert_equal 1, response.parsed_body['recipient_count']
      referees.reload
      assert_equal ['schiri@example.de'], referees.recipients
      assert_not_equal old_digest, referees.token_digest
    end

    test 'ohne Adresse und ohne Eingabe sagt die Absage, was fehlt' do
      login(create(:user, :admin))
      post "/api/v2/admin/games/#{@game.id}/protests/referees/resend", as: :json

      assert_response :unprocessable_entity
      assert_includes response.parsed_body['message'], 'keine Adresse hinterlegt'
    end

    test 'eine ungültige Adresse wird abgelehnt' do
      login(create(:user, :admin))
      post "/api/v2/admin/games/#{@game.id}/protests/referees/resend", params: { email: 'keine-adresse' }, as: :json

      assert_response :unprocessable_entity
      assert_includes response.parsed_body['message'], 'gültige E-Mail-Adresse'
    end

    test 'ohne Eingabe geht der Link an die inzwischen hinterlegte Adresse' do
      @game.game_day.club.update!(contact_email: 'neu@example.de')
      host_team = @game.home_team
      assert_equal @game.game_day.club_id, host_team.club_id
      home, = GameProtest.create_with_token!(game: @game, party: 'home', recipients: [])
      login(create(:user, :admin))

      assert_enqueued_emails 1 do
        post "/api/v2/admin/games/#{@game.id}/protests/home/resend", as: :json
      end
      assert_includes home.reload.recipients, 'neu@example.de'
    end

    test 'nach dem Upload gibt es keinen neuen Link' do
      login(create(:user, :admin))
      post "/api/v2/admin/games/#{@game.id}/protests/guest/resend", params: { email: 'x@example.de' }, as: :json

      assert_response :unprocessable_entity
      assert_includes response.parsed_body['message'], 'bereits hochgeladen'
    end

    test 'eine fremde SBK darf keinen Link verschicken' do
      other = create(:game_operation, state_association_id: create(:state_association).id)
      login(create(:user, :sbk_scoped, game_operation_id: other.id))
      post "/api/v2/admin/games/#{@game.id}/protests/referees/resend", params: { email: 'x@example.de' }, as: :json

      assert_response :forbidden
    end

    test 'die Übersicht nennt jede Partei mit Stand' do
      login(create(:user, :sbk_scoped, game_operation_id: @go.id))
      get '/api/v2/admin/game_days/report_overview'

      row = response.parsed_body['games'].find { |g| g['id'] == @game.id }
      protests = row['protests'].index_by { |p| p['party'] }
      assert_equal %w[guest referees other], row['protests'].pluck('party')
      assert_equal 'protest.pdf', protests['guest']['filename']
      assert protests['guest']['submitted_at'].present?
      assert_equal 0, protests['referees']['recipient_count']
      assert protests['other']['manual']
      assert_nil protests['other']['invited_at']
    end
  end
end
