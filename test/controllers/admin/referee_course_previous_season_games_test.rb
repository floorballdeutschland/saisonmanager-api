require 'test_helper'

# Spalte „Vorsaison" in der Pruefmaske eines Kursimports: Gezaehlt werden nur
# Einsaetze ab U15. Spiele in U13 und juenger sagen fuer die Einstufung nach dem
# Kurs nichts aus.
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

    def game_in(age_group, season: :previous_season)
      league = create(:league, season, age_group: age_group)
      create(:game, game_day: create(:game_day, league: league), officiating_referee_ids: [@referee.id])
    end

    def counted
      get "/api/v2/admin/referee_course_imports/#{@import.id}"
      assert_response :success
      response.parsed_body['results'].first['previous_season_game_count']
    end

    test 'zaehlt nur Spiele ab U15 und Ligen ohne Altersklasse' do
      ['Herren', 'Damen', 'U15 Junioren', 'U17 Juniorinnen', 'Ü30', nil, ''].each { |ag| game_in(ag) }
      ['U13 Junioren', 'U11 Juniorinnen', 'U9 Junioren'].each { |ag| game_in(ag) }
      game_in('Herren', season: :current_season)

      assert_equal 7, counted
    end
  end
end
