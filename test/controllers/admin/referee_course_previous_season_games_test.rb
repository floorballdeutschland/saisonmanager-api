require 'test_helper'

# Spalte „Vorsaison" in der Pruefmaske eines Kursimports: gesamt und Grossfeld
# ab U15. Die zweite Zahl entscheidet nach einem F-Kurs ueber L1 (mindestens
# vier Spiele) oder L2.
module Admin
  class RefereeCoursePreviousSeasonGamesTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting)
      @admin = create(:user, :admin)
      @referee = create(:referee, lizenznummer: 4711)
      @import = RefereeCourseImport.create!(
        uploaded_by_user: @admin, filename: 'kurs.csv', total_rows: 1, status: 'in_review'
      )
      RefereeCourseResult.create!(
        referee_course_import: @import, referee: @referee, status: 'pending_review',
        match_type: 'exact_match', match_field_count: 6,
        csv_vorname: @referee.vorname, csv_nachname: @referee.nachname
      )
      post '/api/v2/login', params: { username: @admin.user_name, password: 'password123' }
      assert_response :success
    end

    def game_in(age_group, season: :previous_season, field_size: 'GF')
      league = create(:league, season, age_group: age_group, field_size: field_size)
      create(:game, game_day: create(:game_day, league: league), officiating_referee_ids: [@referee.id])
    end

    def counted
      get "/api/v2/admin/referee_course_imports/#{@import.id}"
      assert_response :success
      row = response.parsed_body['results'].first
      [row['previous_season_game_count'], row['previous_season_game_count_gf_u15_plus']]
    end

    test 'zaehlt die Vorsaison gesamt und Grossfeld ab U15 getrennt' do
      ['Herren', 'Damen', 'U15 Junioren', 'U17 Juniorinnen', 'Ü30', nil, ''].each { |ag| game_in(ag) }
      ['U13 Junioren', 'U11 Juniorinnen', 'U9 Junioren'].each { |ag| game_in(ag) }
      game_in('Herren', field_size: 'KF')
      game_in('Herren', season: :current_season)

      assert_equal [11, 7], counted
    end

    test 'neuer Schiedsrichter ohne Datensatz hat keine Einsaetze' do
      @import.referee_course_results.first.update!(referee: nil)

      assert_equal [0, 0], counted
    end
  end
end
