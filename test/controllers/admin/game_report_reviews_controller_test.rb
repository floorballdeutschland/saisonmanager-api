require 'test_helper'

module Admin
  # Erledigt-Vermerk der SBK an einem Spielbericht. Ohne ihn blieb in der
  # Arbeitsansicht „Spielberichte" jede Auffälligkeit und jeder Einspruch
  # stehen, bis der Spieltag aus der Ansicht fiel.
  class GameReportReviewsControllerTest < ActionDispatch::IntegrationTest
    OVERVIEW_PATH = '/api/v2/admin/game_days/report_overview'.freeze

    setup do
      create(:setting, current_season_id: '18')
      @sa = StateAssociation.create!(name: 'LV')
      @go = GameOperation.create!(name: 'GO', short_name: 'GO', state_association_id: @sa.id)
      @league = League.create!(game_operation: @go, name: 'Liga', season_id: '18', table_modus: 'classic')
      @club = Club.create!(name: 'Verein', state_association_id: @sa.id)
      @game_day = GameDay.create!(league: @league, arena: Arena.create!(name: 'Halle', city: 'Stadt'),
                                  club: @club, number: 1, date: '2026-02-01')
      @game = Game.create!(game_day: @game_day,
                           home_team: Team.create!(league: @league, club: @club, name: 'Heim'),
                           guest_team: Team.create!(league: @league, club: @club, name: 'Gast'),
                           game_number: '10', forfait: 0, overtime: false, legacy: false,
                           events: [], players: { 'home' => [], 'guest' => [] })
      @game.update_columns(record_updated_at: 2.days.ago)
      @other_go = GameOperation.create!(name: 'GO2', short_name: 'GO2',
                                        state_association_id: StateAssociation.create!(name: 'LV2').id)
    end

    test 'SBK des Spielbetriebs markiert als erledigt, die Übersicht zeigt den Vermerk' do
      sbk = create(:user, :sbk_scoped, game_operation_id: @go.id, first_name: 'Sara', last_name: 'Sbk')
      login(sbk)

      post review_path, params: { comment: "  Mit dem Ausrichter telefoniert.\n" }, as: :json

      assert_response :success
      @game.reload
      assert_not_nil @game.report_reviewed_at
      assert_equal sbk.id, @game.report_reviewed_by_user_id
      assert_equal 'Mit dem Ausrichter telefoniert.', @game.report_review_comment

      get OVERVIEW_PATH
      data = JSON.parse(response.body)['games'].find { |g| g['id'] == @game.id }
      assert data['can_review']
      assert data['report_reviewed_at'].present?
      assert_equal 'Sara Sbk', data['report_reviewed_by_name']
      assert_equal 'Mit dem Ausrichter telefoniert.', data['report_review_comment']
      assert_equal false, data['report_changed_since_review']
    end

    # Der Vermerk gehört der SBK, nicht dem Bericht: Er darf weder als
    # Bearbeitung des Berichts zählen noch Teams oder Caches anfassen.
    test 'der Vermerk lässt record_updated_at und updated_at unberührt' do
      before_record = @game.reload.record_updated_at
      before_updated = @game.updated_at
      login(create(:user, :admin))

      post review_path, as: :json

      assert_response :success
      @game.reload
      assert_equal before_record.to_i, @game.record_updated_at.to_i
      assert_equal before_updated.to_i, @game.updated_at.to_i
      assert_nil @game.report_review_comment
    end

    test 'Zurücknehmen löscht den Vermerk' do
      @game.update_columns(report_reviewed_at: Time.current, report_reviewed_by_user_id: 1,
                           report_review_comment: 'alt')
      login(create(:user, :sbk_global))

      delete review_path

      assert_response :success
      @game.reload
      assert_nil @game.report_reviewed_at
      assert_nil @game.report_reviewed_by_user_id
      assert_nil @game.report_review_comment
    end

    test 'SBK eines fremden Spielbetriebs darf nicht abhaken' do
      login(create(:user, :sbk_scoped, game_operation_id: @other_go.id))

      post review_path, as: :json

      assert_response :forbidden
      assert_nil @game.reload.report_reviewed_at
    end

    test 'Vereinsmanager darf nicht abhaken' do
      login(create(:user, :vm, club_id: @club.id))

      post review_path, as: :json

      assert_response :forbidden
      assert_nil @game.reload.report_reviewed_at
    end

    test 'ein zu langer Kommentar wird abgewiesen' do
      login(create(:user, :admin))

      post review_path, params: { comment: 'x' * (GameReportReviewsController::COMMENT_MAX_LENGTH + 1) }, as: :json

      assert_response :unprocessable_entity
      assert_nil @game.reload.report_reviewed_at
    end

    test 'eine spätere Änderung am Bericht oder ein neuer Einspruch holt die Zeile zurück' do
      @game.update_columns(report_reviewed_at: 1.day.ago, report_reviewed_by_user_id: 1)
      login(create(:user, :admin))

      get OVERVIEW_PATH
      assert_equal false, overview_row['report_changed_since_review']

      GameDayTeamConfirmation.create!(game_day: @game_day, team: @game.guest_team, confirmed_at: 1.hour.ago,
                                      properly_conducted: false)
      get OVERVIEW_PATH
      assert_equal true, overview_row['report_changed_since_review']

      GameDayTeamConfirmation.delete_all
      @game.update_columns(record_updated_at: Time.current)
      get OVERVIEW_PATH
      assert_equal true, overview_row['report_changed_since_review']
    end

    test 'unbekanntes Spiel liefert 404' do
      login(create(:user, :admin))

      post '/api/v2/admin/games/0/report_review', as: :json

      assert_response :not_found
    end

    private

    def review_path
      "/api/v2/admin/games/#{@game.id}/report_review"
    end

    def overview_row
      JSON.parse(response.body)['games'].find { |g| g['id'] == @game.id }
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
