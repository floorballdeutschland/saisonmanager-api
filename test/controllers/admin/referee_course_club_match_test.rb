require 'test_helper'

# Der Vereinsabgleich des Kursimports an den beiden Masken (api#542).
#
# Wichtig ist hier nicht nur, DASS ein ausgeschriebener Vereinsname trifft,
# sondern dass alle drei Stellen dasselbe urteilen: der Import, das Bearbeiten
# einer Zeile (Score-Neuberechnung) und die Anzeige. Liefen sie auseinander,
# widerspräche die Markierung in der Maske der Zahl im Kopf der Zeile.
module Admin
  class RefereeCourseClubMatchTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting)
      @admin = create(:user, :admin)
      @sa = create(:state_association)
      @club = Club.create!(name: 'UV Zwigge 07', long_name: 'Unihockeyverein Zwigge 07 e.V.',
                           state_association_id: @sa.id)
      @referee = create(:referee, vorname: 'Paul', nachname: 'Morgenroth',
                                  geburtsdatum: Date.new(2000, 7, 18),
                                  email: 'paul@example.org', club_id: @club.id)
    end

    def import_with_row(status:, **overrides)
      import = RefereeCourseImport.create!(
        uploaded_by_user: @admin, filename: 'kurs.csv', total_rows: 1, status: status
      )
      result = RefereeCourseResult.create!(
        { referee_course_import: import,
          referee: @referee,
          status: 'pending_review',
          match_type: 'partial_match',
          match_field_count: 5,
          csv_lizenznummer: @referee.lizenznummer,
          csv_vorname: 'Paul', csv_nachname: 'Morgenroth',
          csv_geburtsdatum: Date.new(2000, 7, 18),
          csv_email: 'paul@example.org',
          csv_verein: 'Unihockeyverein Zwigge 07 e.V.',
          master_vorname_by_importer: 'Paul',
          master_nachname_by_importer: 'Morgenroth',
          master_club_id_by_importer: @club.id,
          master_club_id_final: @club.id,
          state_association_id: @sa.id,
          lizenzstufe: 'G',
          gueltigkeit: Date.new(2026, 7, 31),
          kursstichtag: Date.new(2025, 8, 3) }.merge(overrides)
      )
      [import, result]
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end

    # Die Importeurs-Maske hing für die Frage „trifft der Name?" an
    # `matched_club` — und das fällt beim Import auf den Verein des
    # Schiedsrichters zurück. Für den häufigsten Nicht-Treffer meldete sie also
    # Gleichheit. Gleiche Ursache wie api#540 in der Freigabe-Maske.
    test 'die Importeurs-Maske trennt den Namenstreffer vom Zielwert' do
      import, = import_with_row(status: 'in_review',
                                csv_verein: 'Gibt es nicht e.V.')
      login(@admin)

      get "/api/v2/admin/referee_course_imports/#{import.id}"

      assert_response :success
      row = response.parsed_body['results'].first
      # Zielwert: der Verein des Schiedsrichters (Rückfallwert des Imports).
      assert_equal @club.id, row.dig('matched_club', 'id')
      # Namenstreffer: keiner — und genau das muss die Maske zeigen können.
      assert_nil row['csv_club_match']
    end

    test 'die Importeurs-Maske nennt die Herkunft eines nicht-exakten Treffers' do
      import, = import_with_row(status: 'in_review')
      login(@admin)

      get "/api/v2/admin/referee_course_imports/#{import.id}"

      assert_response :success
      match = response.parsed_body['results'].first['csv_club_match']
      assert_equal @club.id, match['id']
      # Über den Langnamen, nicht über den Vereinsnamen: eine Schlussfolgerung
      # des Systems, die der Importeur prüfen können soll.
      assert_equal 'long_name', match['match_type']
    end

    test 'die Freigabe-Maske nennt die Herkunft ebenso' do
      import_with_row(status: 'submitted')
      login(@admin)

      get '/api/v2/admin/referee_course_results'

      assert_response :success
      match = response.parsed_body.first['csv_club_match']
      assert_equal @club.id, match['id']
      assert_equal 'long_name', match['match_type']
    end

    test 'ein exakter Namenstreffer wird als solcher gemeldet' do
      import, = import_with_row(status: 'in_review', csv_verein: 'UV Zwigge 07')
      login(@admin)

      get "/api/v2/admin/referee_course_imports/#{import.id}"

      assert_response :success
      assert_equal 'name',
                   response.parsed_body['results'].first.dig('csv_club_match', 'match_type')
    end

    # Symmetrie: Bearbeitet der Importeur eine Zeile, rechnet der Controller den
    # Score neu. Nutzte er dabei eine andere Vereinsauflösung als der Import,
    # sprang der Score beim ersten Speichern von 6/6 auf 5/6 — ohne dass sich
    # etwas geändert hätte.
    test 'das Bearbeiten einer Zeile rechnet den Vereinstreffer genauso' do
      _import, result = import_with_row(status: 'in_review')
      login(@admin)

      patch "/api/v2/admin/referee_course_results/#{result.id}",
            params: { lizenzstufe: 'G' }

      assert_response :success
      assert_equal 6, result.reload.match_field_count
      assert_equal 'exact_match', result.match_type
    end

    test 'eine mehrdeutige Schreibweise bleibt beim Bearbeiten ein Nicht-Treffer' do
      Club.create!(name: 'SV Test e.V.')
      Club.create!(name: 'SV Test')
      _import, result = import_with_row(status: 'in_review', csv_verein: 'S.V. Test e.V.')
      login(@admin)

      patch "/api/v2/admin/referee_course_results/#{result.id}",
            params: { lizenzstufe: 'G' }

      assert_response :success
      assert_equal 5, result.reload.match_field_count
      assert_equal 'partial_match', result.match_type
    end
  end
end
