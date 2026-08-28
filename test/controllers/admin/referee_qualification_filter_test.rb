require 'test_helper'

module Admin
  # Das Stufenfeld der Verwaltungsliste sucht in zwei Quellen: Lizenzstufe und
  # Zusatzqualifikationen. Ohne den zweiten Zweig war die Frage „wer ist
  # Beobachter?" nur über das Durchklicken der Einzelprofile zu beantworten.
  class RefereeQualificationFilterTest < ActionDispatch::IntegrationTest
    setup do
      Rails.cache.clear
      create(:setting, current_season_id: '19')
      Setting.current.update!(seasons: { '19' => { 'name' => '2026/2027' } })
      Rails.cache.clear

      @admin = User.create!(
        user_name: "qualadmin_#{SecureRandom.hex(4)}",
        password: 'password123', password_confirmation: 'password123',
        permissions: [{ 'user_group_id' => 1, 'game_operation_id' => 0 }], teams: []
      )

      @beobachter = RefereeQualificationType.create!(name: 'Beobachter', short_name: 'BEO')
      @ausbilder = RefereeQualificationType.create!(name: 'Ausbilder', short_name: 'AUS')

      @lv = create(:state_association, name: 'Filterverband', short_name: 'FIL')
      @club = create(:club, state_association: @lv)

      # Die Lizenzstufen sind bewusst disjunkt zu den Qualifikationen verteilt,
      # damit jeder Test zeigt, aus welchem der beiden Zweige der Treffer kommt.
      @mit_qualifikation = create(:referee, lizenznummer: 720_001, nachname: 'Beobachtsen',
                                            lizenzstufe: 'B', club: @club, gueltigkeit: Date.new(2027, 9, 30))
      @andere_qualifikation = create(:referee, lizenznummer: 720_002, nachname: 'Ausbildsen',
                                               lizenzstufe: 'C', gueltigkeit: Date.new(2027, 9, 30))
      @ohne_qualifikation = create(:referee, lizenznummer: 720_003, nachname: 'Ohnesen',
                                             lizenzstufe: 'A', gueltigkeit: Date.new(2027, 9, 30))

      RefereeQualification.create!(referee: @mit_qualifikation, referee_qualification_type: @beobachter,
                                   valid_until: Date.new(2028, 6, 30))
      RefereeQualification.create!(referee: @andere_qualifikation, referee_qualification_type: @ausbilder)
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end

    # Fixtures bringen eigene Schiedsrichter mit, deshalb nur die Nummern dieses
    # Tests betrachten.
    def nummern(params = {})
      get '/api/v2/admin/referees', params: params
      assert_response :success
      response.parsed_body.map { |r| r['lizenznummer'] }.select { |nr| nr.to_i >= 720_000 }
    end

    # Ein einzelner Buchstabe ist eine Lizenzstufe und kein Wortanfang: „A" darf
    # nicht jeden „Ausbilder" in die Liste der A-Schiedsrichter holen.
    test 'Lizenzstufe filtert weiterhin exakt' do
      login(@admin)

      assert_equal [720_003], nummern(lizenzstufe: 'A')
    end

    test 'Lizenzstufe ist unabhaengig von der Schreibweise' do
      login(@admin)

      assert_equal [720_001], nummern(lizenzstufe: 'b')
    end

    test 'Kuerzel der Zusatzqualifikation findet den Schiedsrichter' do
      login(@admin)

      assert_equal [720_001], nummern(lizenzstufe: 'beo')
    end

    test 'Teil des Qualifikationsnamens genuegt' do
      login(@admin)

      assert_equal [720_001], nummern(lizenzstufe: 'Beobacht')
    end

    test 'voller Qualifikationsname findet den Schiedsrichter' do
      login(@admin)

      assert_equal [720_002], nummern(lizenzstufe: 'Ausbilder')
    end

    # Die Grenze der Praefix-Regel, und die einzige Stelle, an der sie still
    # kippen koennte: Zwei Zeichen sind noch kein Wortanfang. Ein spaeterer
    # Griff nach `>= 2` bliebe ohne diesen Test gruen und holte wieder jeden
    # Ausbilder in die Liste der Stufe „Au".
    test 'zwei Zeichen sind noch kein Wortanfang' do
      login(@admin)

      assert_empty nummern(lizenzstufe: 'Au')
      assert_empty nummern(lizenzstufe: 'Be')
    end

    # Der Landesverbandsfilter bringt einen JOIN mit; der Stufenfilter verodert
    # zwei Bedingungen. Beides zusammen muss die Schnittmenge liefern.
    test 'Qualifikationsfilter laesst sich mit dem Landesverband kombinieren' do
      login(@admin)

      assert_equal [720_001], nummern(landesverband: 'Filterverband', lizenzstufe: 'Beobachter')
      assert_empty nummern(landesverband: 'Filterverband', lizenzstufe: 'Ausbilder')
    end

    test 'unbekannter Wert liefert keine Treffer' do
      login(@admin)

      assert_empty nummern(lizenzstufe: 'Zeitnehmer')
    end

    # Die Listenspalte „Region" zeigt das Kürzel, der volle Name bleibt für
    # Filter und CSV-Export daneben stehen.
    test 'die Liste liefert Kuerzel und Namen des Landesverbands' do
      login(@admin)

      get '/api/v2/admin/referees', params: { landesverband: 'Filterverband' }
      assert_response :success
      row = response.parsed_body.find { |r| r['lizenznummer'] == 720_001 }

      assert_equal 'FIL', row['landesverband_short']
      assert_equal 'Filterverband', row['landesverband']
    end

    test 'die Liste liefert die Zusatzqualifikationen mit' do
      login(@admin)

      get '/api/v2/admin/referees', params: { lizenzstufe: 'BEO' }
      assert_response :success
      row = response.parsed_body.find { |r| r['lizenznummer'] == 720_001 }

      assert_equal(['Beobachter'], row['qualifications'].map { |q| q['qualification_type_name'] })
      assert_equal(['BEO'], row['qualifications'].map { |q| q['qualification_type_short_name'] })
      assert_equal(['30.06.2028'], row['qualifications'].map { |q| q['valid_until'] })
    end

    # Der Altbestand bleibt bewusst auffindbar: „Wer ist Beobachter?" fragt nach
    # dem Bestand und nicht nach der Restlaufzeit. Dann muss die Zeile aber
    # sagen, dass ihr Treffer abgelaufen ist -- sonst beantwortet die Liste die
    # Frage stillschweigend mit dem Altbestand mit.
    test 'abgelaufene Zusatzqualifikation wird gefunden und als abgelaufen ausgewiesen' do
      RefereeQualification.create!(referee: @andere_qualifikation, referee_qualification_type: @beobachter,
                                   valid_until: Date.current + 1)
      RefereeQualification.create!(referee: @ohne_qualifikation, referee_qualification_type: @beobachter,
                                   valid_until: Date.current - 1)
      login(@admin)

      get '/api/v2/admin/referees', params: { lizenzstufe: 'Beobachter' }
      assert_response :success
      rows = response.parsed_body.select { |r| r['lizenznummer'].to_i >= 720_000 }

      assert_equal [720_001, 720_002, 720_003], rows.map { |r| r['lizenznummer'] }.sort

      beobachter = rows.to_h do |r|
        [r['lizenznummer'], r['qualifications'].find { |q| q['qualification_type_name'] == 'Beobachter' }]
      end

      assert_not beobachter[720_002]['expired']
      assert beobachter[720_003]['expired']
      # Ohne Ablaufdatum ist nichts abgelaufen.
      ausbilder = rows.find { |r| r['lizenznummer'] == 720_002 }['qualifications']
                      .find { |q| q['qualification_type_name'] == 'Ausbilder' }

      assert_not ausbilder['expired']
    end
  end
end
