require 'test_helper'

module Admin
  # Sortierung der Schiedsrichter-Verwaltungsliste. Bis api#635 waren nur
  # Lizenznummer und Name sortierbar; die übrigen Spalten der Liste kommen hier
  # dazu, zwei davon (Qualifikationen, Einsätze) ohne eigene Datenbankspalte.
  class RefereeSortingTest < ActionDispatch::IntegrationTest
    setup do
      Rails.cache.clear
      create(:setting, current_season_id: '19')
      Setting.current.update!(seasons: { '19' => { 'name' => '2026/2027' } })
      Rails.cache.clear

      @admin = User.create!(
        user_name: "sortadmin_#{SecureRandom.hex(4)}",
        password: 'password123', password_confirmation: 'password123',
        permissions: [{ 'user_group_id' => 1, 'game_operation_id' => 0 }], teams: []
      )

      @lv_a = create(:state_association, name: 'Aalen-Verband', short_name: 'AAL')
      @lv_b = create(:state_association, name: 'Zwickau-Verband', short_name: 'ZWI')
      @club_a = create(:club, name: 'Aachener SV', state_association: @lv_a)
      @club_z = create(:club, name: 'Zittauer SV', state_association: @lv_b)

      # Drei Datensätze, deren Reihenfolge in jeder Spalte eine andere ist –
      # sonst könnte eine Sortierung zufällig richtig aussehen.
      @erst = create(:referee, lizenznummer: 720_001, nachname: 'Mueller', vorname: 'Anna',
                               lizenzstufe: 'B', club: @club_z, gueltigkeit: Date.new(2027, 9, 30))
      @zweit = create(:referee, lizenznummer: 720_002, nachname: 'Albers', vorname: 'Bert',
                                lizenzstufe: 'A', club: @club_a, gueltigkeit: Date.new(2027, 1, 31))
      @dritt = create(:referee, lizenznummer: 720_003, nachname: 'Zander', vorname: 'Carla',
                                lizenzstufe: nil, club: nil, gueltigkeit: nil)
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end

    # Die Fixtures bringen eigene Schiedsrichter mit, deshalb nur die Nummern
    # dieses Tests betrachten. Die Reihenfolge bleibt dabei erhalten.
    def nummern(params = {})
      get '/api/v2/admin/referees', params: params
      assert_response :success
      response.parsed_body.map { |r| r['lizenznummer'] }.select { |nr| nr.to_i >= 720_000 }
    end

    test 'ohne Sortierparameter bleibt es beim Namen aufsteigend' do
      login(@admin)

      assert_equal [720_002, 720_001, 720_003], nummern
    end

    test 'Name absteigend dreht die Liste' do
      login(@admin)

      assert_equal [720_003, 720_001, 720_002], nummern(sort: 'name', sort_dir: 'desc')
    end

    test 'Lizenznummer in beide Richtungen' do
      login(@admin)

      assert_equal [720_001, 720_002, 720_003], nummern(sort: 'lizenznummer')
      assert_equal [720_003, 720_002, 720_001], nummern(sort: 'lizenznummer', sort_dir: 'desc')
    end

    # Ohne Stufe heißt „nicht eingestuft" und nicht „ganz oben": Wer absteigend
    # sortiert, sucht die höchste Stufe.
    test 'Lizenzstufe sortiert, Datensätze ohne Stufe stehen in beiden Richtungen unten' do
      login(@admin)

      assert_equal [720_002, 720_001, 720_003], nummern(sort: 'lizenzstufe')
      assert_equal [720_001, 720_002, 720_003], nummern(sort: 'lizenzstufe', sort_dir: 'desc')
    end

    test 'Gültigkeit sortiert nach Datum, ohne Ablaufdatum unten' do
      login(@admin)

      assert_equal [720_002, 720_001, 720_003], nummern(sort: 'gueltigkeit')
      assert_equal [720_001, 720_002, 720_003], nummern(sort: 'gueltigkeit', sort_dir: 'desc')
    end

    test 'Verein sortiert nach Vereinsnamen, ohne Verein unten' do
      login(@admin)

      assert_equal [720_002, 720_001, 720_003], nummern(sort: 'verein')
      assert_equal [720_001, 720_002, 720_003], nummern(sort: 'verein', sort_dir: 'desc')
    end

    test 'Landesverband sortiert nach Verbandsnamen, ohne Verein unten' do
      login(@admin)

      assert_equal [720_002, 720_001, 720_003], nummern(sort: 'landesverband')
      assert_equal [720_001, 720_002, 720_003], nummern(sort: 'landesverband', sort_dir: 'desc')
    end

    # Der Landesverband-Filter joint dieselbe Kette wie die Sortierung. Beides
    # zusammen darf nicht in einem doppelten Join enden.
    test 'Landesverband-Sortierung neben dem Landesverband-Filter' do
      login(@admin)

      assert_equal [720_002], nummern(sort: 'landesverband', sort_dir: 'desc', landesverband: @lv_a.name)
    end

    test 'Qualifikationen sortieren nach der Beschriftung der Spalte, ohne Eintrag unten' do
      beobachter = RefereeQualificationType.create!(name: 'Beobachter', short_name: 'BEO')
      coach = RefereeQualificationType.create!(name: 'Coach', short_name: 'ACO')
      RefereeQualification.create!(referee: @erst, referee_qualification_type: beobachter,
                                   valid_until: Date.new(2027, 9, 30))
      RefereeQualification.create!(referee: @zweit, referee_qualification_type: coach,
                                   valid_until: Date.new(2027, 9, 30))
      login(@admin)

      assert_equal [720_002, 720_001, 720_003], nummern(sort: 'qualifikationen')
      assert_equal [720_001, 720_002, 720_003], nummern(sort: 'qualifikationen', sort_dir: 'desc')
    end

    test 'Einsätze der Saison sortieren, die Null ist ein echter Wert' do
      go = create(:game_operation)
      league = create(:league, game_operation: go, season_id: '19')
      day = GameDay.create!(league: league, arena: create(:arena), club: @club_a, number: 1, date: '2026-09-01')
      2.times do
        Game.create!(game_day: day, officiating_referee_ids: [@erst.id],
                     events: [], players: { 'home' => [], 'guest' => [] },
                     forfait: 0, overtime: false, legacy: false)
      end
      Game.create!(game_day: day, officiating_referee_ids: [@zweit.id],
                   events: [], players: { 'home' => [], 'guest' => [] },
                   forfait: 0, overtime: false, legacy: false)
      login(@admin)

      assert_equal [720_001, 720_002, 720_003], nummern(sort: 'spiele', sort_dir: 'desc')
      assert_equal [720_003, 720_002, 720_001], nummern(sort: 'spiele')
    end

    # Ein Sortierwunsch ist keine Eingabe, deren Ablehnung die Liste wert wäre:
    # ein unbekannter Wert liefert die Namensreihenfolge statt eines Fehlers.
    test 'unbekannte Sortierspalte fällt auf den Namen zurück' do
      login(@admin)

      assert_equal [720_002, 720_001, 720_003], nummern(sort: 'unfug')
    end
  end
end
