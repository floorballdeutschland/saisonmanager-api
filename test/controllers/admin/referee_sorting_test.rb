require 'test_helper'

module Admin
  # Sortierung der Schiedsrichter-Verwaltungsliste. Bis api#636 waren nur
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

      # Vier Datensätze, und die Reihenfolgen der Spalten sind PAARWEISE
      # VERSCHIEDEN. Mit drei Datensätzen ginge das nicht: Steht einer immer
      # unten, bleiben für die anderen zwei nur zwei Reihenfolgen, und vier
      # Spalten teilen sich zwangsläufig eine -- man könnte zwei Sortierzweige
      # vertauschen und der Test bliebe grün. Geprüft ist das durch
      # „jede Spalte aus SORT_COLUMNS sortiert wirklich" nur zur Namensfolge;
      # die Kreuzung hier trennt die Spalten auch voneinander.
      #
      # Kürzel und Name der Landesverbände laufen zusätzlich gegeneinander,
      # damit sichtbar wird, nach welchem von beiden die Spalte „Region"
      # sortiert.
      @lv_aaa = create(:state_association, name: 'Zwickauer Verband', short_name: 'AAA')
      @lv_mmm = create(:state_association, name: 'Aalener Verband', short_name: 'MMM')
      @lv_zzz = create(:state_association, name: 'Mittweidaer Verband', short_name: 'ZZZ')
      @club_a = create(:club, name: 'Aachener SV', state_association: @lv_mmm)
      @club_m = create(:club, name: 'Muendener SV', state_association: @lv_zzz)
      @club_z = create(:club, name: 'Zittauer SV', state_association: @lv_aaa)

      @erst = create(:referee, lizenznummer: 720_001, nachname: 'Mueller', vorname: 'Anna',
                               lizenzstufe: 'A', club: @club_m, gueltigkeit: Date.new(2027, 5, 15))
      @zweit = create(:referee, lizenznummer: 720_002, nachname: 'Albers', vorname: 'Bert',
                                lizenzstufe: 'B', club: @club_a, gueltigkeit: Date.new(2027, 9, 30))
      # Der leere Datensatz: ohne Stufe, ohne Verein, ohne Ablaufdatum. Er steht
      # in jeder dieser Spalten unten, in beiden Richtungen.
      @dritt = create(:referee, lizenznummer: 720_003, nachname: 'Zander', vorname: 'Carla',
                                lizenzstufe: nil, club: nil, gueltigkeit: nil)
      @viert = create(:referee, lizenznummer: 720_004, nachname: 'Kramer', vorname: 'Dora',
                                lizenzstufe: 'C', club: @club_z, gueltigkeit: Date.new(2027, 1, 31))
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end

    # Die Fixtures bringen eigene Schiedsrichter mit, deshalb nur die dieses
    # Tests betrachten. Gelesen wird lizenznummer_display und nicht
    # lizenznummer: Ein Gastschiedsrichter hat keine Nummer, fiele über
    # nil.to_i also lautlos aus jeder Behauptung heraus.
    def nummern(params = {})
      get '/api/v2/admin/referees', params: params
      assert_response :success
      response.parsed_body.map { |r| r['lizenznummer_display'] }
                          .select { |nr| nr.start_with?('720') || nr.start_with?('G-') }
    end

    test 'ohne Sortierparameter bleibt es beim Namen aufsteigend' do
      login(@admin)

      assert_equal %w[720002 720004 720001 720003], nummern
    end

    test 'Name absteigend dreht die Liste' do
      login(@admin)

      assert_equal %w[720003 720001 720004 720002], nummern(sort: 'name', sort_dir: 'desc')
    end

    test 'Lizenznummer in beide Richtungen' do
      login(@admin)

      assert_equal %w[720001 720002 720003 720004], nummern(sort: 'lizenznummer')
      assert_equal %w[720004 720003 720002 720001], nummern(sort: 'lizenznummer', sort_dir: 'desc')
    end

    # Gastschiedsrichter haben keine Lizenznummer. Ihr NULL-Schwanz braucht den
    # Namen als Zweitschlüssel, sonst liefern zwei gleiche Abrufe verschiedene
    # Reihenfolgen -- und zwar genau in der Spalte, in der es niemandem auffällt.
    test 'Gaeste stehen bei der Lizenznummer unten und dort nach Namen' do
      gast_z = create(:referee, lizenznummer: nil, guest: true, nachname: 'Zetter', vorname: 'Gast')
      gast_a = create(:referee, lizenznummer: nil, guest: true, nachname: 'Aster', vorname: 'Gast')
      login(@admin)

      assert_equal %W[720001 720002 720003 720004 G-#{gast_a.id} G-#{gast_z.id}],
                   nummern(sort: 'lizenznummer')
      assert_equal %W[720004 720003 720002 720001 G-#{gast_a.id} G-#{gast_z.id}],
                   nummern(sort: 'lizenznummer', sort_dir: 'desc')
    end

    # Ohne Stufe heißt „nicht eingestuft" und ist kein Extremwert: Solche Zeilen
    # stehen in beiden Richtungen unten. Sortiert wird alphabetisch nach dem
    # Stufennamen (der Katalog hat keine gepflegten Positionen).
    test 'Lizenzstufe sortiert, Datensaetze ohne Stufe stehen in beiden Richtungen unten' do
      login(@admin)

      assert_equal %w[720001 720002 720004 720003], nummern(sort: 'lizenzstufe')
      assert_equal %w[720004 720002 720001 720003], nummern(sort: 'lizenzstufe', sort_dir: 'desc')
    end

    # Der Leerstring ist im Bestand dasselbe wie „keine Stufe" und darf nicht
    # aufsteigend nach vorne springen -- dafür steht das NULLIF im SQL.
    test 'die leere Lizenzstufe zaehlt wie keine' do
      @dritt.update_column(:lizenzstufe, '')
      login(@admin)

      assert_equal %w[720001 720002 720004 720003], nummern(sort: 'lizenzstufe')
      assert_equal %w[720004 720002 720001 720003], nummern(sort: 'lizenzstufe', sort_dir: 'desc')
    end

    test 'Gueltigkeit sortiert nach Datum, ohne Ablaufdatum unten' do
      login(@admin)

      assert_equal %w[720004 720001 720002 720003], nummern(sort: 'gueltigkeit')
      assert_equal %w[720002 720001 720004 720003], nummern(sort: 'gueltigkeit', sort_dir: 'desc')
    end

    test 'Verein sortiert nach Vereinsnamen, ohne Verein unten' do
      login(@admin)

      assert_equal %w[720002 720001 720004 720003], nummern(sort: 'verein')
      assert_equal %w[720004 720001 720002 720003], nummern(sort: 'verein', sort_dir: 'desc')
    end

    # Die Spalte „Region" zeigt das Kürzel, also muss sie danach sortieren. Die
    # Fixtures haben Kürzel und Namen bewusst gegeneinander gesetzt: Nach dem
    # vollen Namen käme die umgekehrte Reihenfolge heraus.
    test 'Landesverband sortiert nach dem Kuerzel der Spalte, ohne Verein unten' do
      login(@admin)

      assert_equal %w[720004 720002 720001 720003], nummern(sort: 'landesverband')
      assert_equal %w[720001 720002 720004 720003], nummern(sort: 'landesverband', sort_dir: 'desc')
    end

    test 'ohne Kuerzel sortiert der Landesverband nach dem vollen Namen' do
      [@lv_aaa, @lv_mmm, @lv_zzz].each { |lv| lv.update!(short_name: nil) }
      login(@admin)

      # Jetzt zaehlen die Namen -- und die laufen den Kuerzeln entgegen:
      # Aalener (Aachener SV, 002), Mittweidaer (Muendener SV, 001),
      # Zwickauer (Zittauer SV, 004).
      assert_equal %w[720002 720001 720004 720003], nummern(sort: 'landesverband')
    end

    # Der Landesverband-Filter joint dieselbe Kette wie die Sortierung. Beides
    # zusammen darf nicht in einem doppelten Join enden.
    test 'Landesverband-Sortierung neben dem Landesverband-Filter' do
      login(@admin)

      assert_equal %w[720002], nummern(sort: 'landesverband', sort_dir: 'desc',
                                       landesverband: @lv_mmm.name)
    end

    test 'Qualifikationen sortieren nach der Beschriftung der Spalte, ohne Eintrag unten' do
      beobachter = RefereeQualificationType.create!(name: 'Beobachter', short_name: 'BEO')
      coach = RefereeQualificationType.create!(name: 'Coach', short_name: 'ACO')
      qualifiziere(@erst, beobachter)
      qualifiziere(@zweit, coach)
      login(@admin)

      assert_equal %w[720002 720001 720004 720003], nummern(sort: 'qualifikationen')
      assert_equal %w[720001 720002 720004 720003], nummern(sort: 'qualifikationen', sort_dir: 'desc')
    end

    # Ohne Kürzel steht der ausgeschriebene Name in der Zelle -- und dann muss
    # er auch den Sortierschlüssel tragen.
    test 'ohne Kuerzel sortieren die Qualifikationen nach dem Namen' do
      qualifiziere(@erst, RefereeQualificationType.create!(name: 'Ausbilder', short_name: nil))
      qualifiziere(@zweit, RefereeQualificationType.create!(name: 'Zeitnehmer', short_name: nil))
      login(@admin)

      assert_equal %w[720001 720002 720004 720003], nummern(sort: 'qualifikationen')
    end

    # Mehrere Qualifikationen: Der Schlüssel setzt die Beschriftungen alphabetisch
    # zusammen, und die Antwort liefert die Zelle in derselben Reihenfolge --
    # sonst sortierte die Liste nach einem String, der nirgends auf dem Schirm
    # steht.
    test 'mehrere Qualifikationen: Zelle und Sortierschluessel sind gleich geordnet' do
      beo = RefereeQualificationType.create!(name: 'Beobachter', short_name: 'BEO')
      aco = RefereeQualificationType.create!(name: 'Coach', short_name: 'ACO')
      qualifiziere(@erst, beo)
      qualifiziere(@erst, aco)
      qualifiziere(@zweit, beo)
      login(@admin)

      # @erst traegt „ACO, BEO", @zweit nur „BEO" -- also @erst zuerst.
      assert_equal %w[720001 720002 720004 720003], nummern(sort: 'qualifikationen')

      get '/api/v2/admin/referees', params: { sort: 'qualifikationen' }
      zeile = response.parsed_body.find { |r| r['lizenznummer'] == 720_001 }
      assert_equal(%w[ACO BEO], zeile['qualifications'].map { |q| q['qualification_type_short_name'] })
    end

    # Zwei ohne Qualifikation stehen beide unten -- und dort nach Namen, damit
    # die Reihenfolge nicht dem Zufall folgt.
    test 'zwei ohne Qualifikation stehen unten und dort nach Namen' do
      qualifiziere(@erst, RefereeQualificationType.create!(name: 'Beobachter', short_name: 'BEO'))
      login(@admin)

      assert_equal %w[720001 720002 720004 720003], nummern(sort: 'qualifikationen')
      assert_equal %w[720001 720002 720004 720003], nummern(sort: 'qualifikationen', sort_dir: 'desc')
    end

    test 'Einsaetze der Saison sortieren, die Null ist ein echter Wert' do
      spiele_fuer(@erst, 2)
      spiele_fuer(@zweit, 1)
      login(@admin)

      assert_equal %w[720001 720002 720004 720003], nummern(sort: 'spiele', sort_dir: 'desc')
      assert_equal %w[720004 720003 720002 720001], nummern(sort: 'spiele')
    end

    # Der Regelfall im Bestand: viele mit derselben Zahl, meist 0. Der
    # Zweitschlüssel ist der Name AUFSTEIGEND, auch wenn die Spalte absteigend
    # sortiert -- er ordnet innerhalb der Gruppe, er dreht sie nicht.
    test 'gleiche Einsatzzahl ordnet nach Namen, in beiden Richtungen aufsteigend' do
      spiele_fuer(@erst, 1)
      login(@admin)

      assert_equal %w[720001 720002 720004 720003], nummern(sort: 'spiele', sort_dir: 'desc')
      assert_equal %w[720002 720004 720003 720001], nummern(sort: 'spiele')
    end

    test 'unbekannte Sortierspalte wird abgewiesen' do
      login(@admin)

      get '/api/v2/admin/referees', params: { sort: 'unfug' }

      assert_response :unprocessable_entity
      assert_includes response.parsed_body['errors'].first, 'unfug'
    end

    test 'unbekannte Sortierrichtung wird abgewiesen' do
      login(@admin)

      get '/api/v2/admin/referees', params: { sort: 'verein', sort_dir: 'aufwaerts' }

      assert_response :unprocessable_entity
      assert_includes response.parsed_body['errors'].first, 'aufwaerts'
    end

    # Ein Array-Parameter (?sort[]=name) darf nicht als Spalte durchgehen und
    # auch nicht ungeprueft in die Meldung wandern.
    test 'ein Array als Sortierspalte wird abgewiesen' do
      login(@admin)

      get '/api/v2/admin/referees', params: { sort: ['name'] }

      assert_response :unprocessable_entity
    end

    # Ein Schlüssel, der in SORT_COLUMNS steht, aber keinen eigenen Zweig in
    # order_referees hat, fiele in den Namenszweig -- nicht von einer
    # unbekannten Spalte zu unterscheiden. Der Test läuft über die Konstante und
    # meldet sich, sobald jemand sie erweitert und den Zweig vergisst.
    test 'jede Spalte aus SORT_COLUMNS sortiert wirklich' do
      login(@admin)
      namensfolge = nummern(sort: 'name', sort_dir: 'desc')

      (RefereesController::SORT_COLUMNS - %w[name]).each do |col|
        assert_not_equal namensfolge, nummern(sort: col, sort_dir: 'desc'),
                         "#{col} liefert die Namensreihenfolge -- fehlt der Zweig?"
      end
    end

    test 'COMPUTED_SORTS ist eine Teilmenge von SORT_COLUMNS' do
      assert_empty RefereesController::COMPUTED_SORTS - RefereesController::SORT_COLUMNS
    end

    private

    def qualifiziere(referee, type)
      RefereeQualification.create!(referee: referee, referee_qualification_type: type,
                                   valid_until: Date.new(2027, 9, 30))
    end

    def spiele_fuer(referee, anzahl)
      @league ||= create(:league, game_operation: create(:game_operation), season_id: '19')
      @game_day ||= GameDay.create!(league: @league, arena: create(:arena), club: @club_a,
                                    number: 1, date: '2026-09-01')
      anzahl.times do
        Game.create!(game_day: @game_day, officiating_referee_ids: [referee.id],
                     events: [], players: { 'home' => [], 'guest' => [] },
                     forfait: 0, overtime: false, legacy: false)
      end
    end
  end
end
