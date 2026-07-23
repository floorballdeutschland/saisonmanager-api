require 'test_helper'

module Admin
  class FeedbackCommentsControllerTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting)
      @admin = create(:user, :admin)
      @fd = create(:game_operation, state_association_id: nil)
      @lv_sa = create(:state_association)
      @lv_go = create(:game_operation, state_association_id: @lv_sa.id)
      @league = create(:league, season_id: '18')
    end

    test 'LV-RSK darf den Feed nicht sehen, FD-RSK schon' do
      login(create(:user, :rsk_scoped, game_operation_id: @lv_go.id))
      get '/api/v2/admin/feedback_comments'
      assert_response :forbidden

      login(create(:user, :rsk_scoped, game_operation_id: @fd.id))
      get '/api/v2/admin/feedback_comments'
      assert_response :success
    end

    test 'Feed enthält nur sichtbare, kommentierte Rückmeldungen' do
      r1 = create(:referee)
      make_feedback(referee1: r1, comment: 'Linie war unsicher')
      make_feedback(referee1: r1, comment: nil) # ohne Kommentar -> nicht im Feed
      make_feedback(referee1: r1, comment: 'ausgeblendet', status: 'hidden')

      login(@admin)
      get '/api/v2/admin/feedback_comments'

      assert_response :success
      assert_equal 1, response.parsed_body.size
    end

    test 'Themen setzen wird im Feed gespiegelt' do
      r1 = create(:referee)
      feedback = make_feedback(referee1: r1, comment: 'Auftreten souverän')
      theme = create(:feedback_theme, name: 'Auftreten')

      login(@admin)
      patch "/api/v2/admin/feedback_comments/#{feedback.id}/themes", params: { theme_ids: [theme.id] }
      assert_response :success

      get '/api/v2/admin/feedback_comments'
      entry = response.parsed_body.find { |c| c['id'] == feedback.id }
      assert_equal ['Auftreten'], entry['themes'].map { |t| t['name'] }

      # Leere Liste entfernt die Zuordnung wieder.
      patch "/api/v2/admin/feedback_comments/#{feedback.id}/themes", params: { theme_ids: [] }
      assert_equal 0, feedback.reload.feedback_themes.count
    end

    test 'stats liefert Themen-Häufigkeiten und Gruppen-Zähler' do
      r1 = create(:referee)
      tag = RefereeTag.create!(name: 'Kader', game_operation_id: nil)
      RefereeTagging.create!(referee: r1, referee_tag: tag)
      theme = create(:feedback_theme, name: 'Positionierung')
      f1 = make_feedback(referee1: r1, comment: 'Position')
      FeedbackThemeTagging.create!(referee_feedback: f1, feedback_theme: theme)

      login(@admin)
      get '/api/v2/admin/feedback_comments/stats', params: { tag_id: tag.id }

      assert_response :success
      entry = response.parsed_body['themes'].find { |t| t['theme_id'] == theme.id }
      assert_equal 1, entry['count']
      assert_equal 1, entry['group_count']
    end

    private

    def make_feedback(referee1:, referee2: nil, comment: 'Kommentar', status: 'visible', line: 7, communication: 8)
      day = GameDay.create!(league: @league, arena: create(:arena), club: create(:club),
                            number: 1, date: '2026-01-15')
      game = Game.create!(game_day: day, officiating_referee_ids: [], events: [],
                          players: { 'home' => [], 'guest' => [] },
                          forfait: 0, overtime: false, legacy: false)
      RefereeFeedback.create!(game: game, team: create(:team, league: @league),
                              referee1_id: referee1&.id, referee2_id: referee2&.id,
                              line_rating: line, communication_rating: communication,
                              line_comment: comment, status: status)
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
