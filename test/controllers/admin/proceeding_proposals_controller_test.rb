require 'test_helper'

module Admin
  class ProceedingProposalsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @sa = StateAssociation.create!(name: 'LV', vsk_email: 'vsk@example.de', sbk_email: 'sbk@example.de')
      @go = GameOperation.create!(name: 'GO', short_name: 'GO', state_association_id: @sa.id)
      @league = League.create!(game_operation: @go, name: 'Liga', season_id: '18', table_modus: 'classic')
      @club = Club.create!(state_association_id: @sa.id)
      @arena = Arena.create!(name: 'Halle', city: 'Stadt')
      @game_day = GameDay.create!(league: @league, arena: @arena, club: @club, number: 1, date: '2026-02-01')
      @home = Team.create!(league: @league, club: @club, name: 'H')
      @guest = Team.create!(league: @league, club: @club, name: 'G')
      @game = Game.create!(game_day: @game_day, home_team: @home, guest_team: @guest, forfait: 0,
                           overtime: false, legacy: false, events: [], players: { 'home' => [], 'guest' => [] })
      @proposal = ProceedingProposal.create!(game: @game, state_association: @sa, status: 'pending')
    end

    test 'SBK im Scope sieht offene Vorschläge' do
      login(sbk_user(@go.id))
      get '/api/v2/admin/proceeding_proposals'
      assert_response :success
      ids = JSON.parse(response.body).map { |p| p['id'] }
      assert_equal [@proposal.id], ids
    end

    test 'fremder SBK sieht den Vorschlag nicht' do
      login(sbk_user(@go.id + 999))
      get '/api/v2/admin/proceeding_proposals'
      assert_response :success
      assert_empty JSON.parse(response.body)
    end

    test 'show liefert Detail' do
      login(sbk_user(@go.id))
      get "/api/v2/admin/proceeding_proposals/#{@proposal.id}"
      assert_response :success
      assert_equal @game.id, JSON.parse(response.body)['game_id']
    end

    test 'ablehnen setzt Status rejected und verwirft den Bericht' do
      attach_report!(create_user(user_group_id: 6, game_operation_id: 0))
      login(sbk_user(@go.id))
      post "/api/v2/admin/proceeding_proposals/#{@proposal.id}/reject"
      assert_response :success
      assert_equal 'rejected', @proposal.reload.status
      assert_nil @game.reload.game_referee_report
    end

    test 'eröffnen setzt Status opened' do
      uploader = create_user(user_group_id: 6, game_operation_id: 0)
      attach_report!(uploader)
      @proposal.update!(created_by_id: uploader.id)
      login(sbk_user(@go.id))
      post "/api/v2/admin/proceeding_proposals/#{@proposal.id}/open"
      assert_response :success
      assert_equal 'opened', @proposal.reload.status
    end

    test 'fremder SBK darf nicht ablehnen → 403' do
      login(sbk_user(@go.id + 999))
      post "/api/v2/admin/proceeding_proposals/#{@proposal.id}/reject"
      assert_response :forbidden
      assert_equal 'pending', @proposal.reload.status
    end

    test 'Nutzer ohne SBK-/Admin-Rechte → 403' do
      login(create_user(user_group_id: 4, game_operation_id: 0))
      get '/api/v2/admin/proceeding_proposals'
      assert_response :forbidden
    end

    private

    def attach_report!(uploader)
      report = @game.build_game_referee_report(uploaded_by: uploader)
      report.file.attach(io: StringIO.new('PDF'), filename: 'report.pdf', content_type: 'application/pdf')
      report.save!
    end

    def sbk_user(game_operation_id)
      create_user(user_group_id: 2, game_operation_id: game_operation_id)
    end

    def create_user(user_group_id:, game_operation_id:)
      User.create!(
        user_name: "authuser_#{SecureRandom.hex(4)}",
        password: 'password123',
        password_confirmation: 'password123',
        permissions: [{ 'user_group_id' => user_group_id, 'game_operation_id' => game_operation_id }],
        teams: []
      )
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
