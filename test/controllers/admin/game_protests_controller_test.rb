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
