require 'test_helper'

module Admin
  # Standardfilter der Verwaltungsliste: alles außer Karriere beendet. Die
  # Nummernsuche muss ihn durchstechen, sonst ist die Prüfung einer alten
  # Lizenznummer genau dann blind, wenn sie gebraucht wird.
  class RefereeStatusFilterTest < ActionDispatch::IntegrationTest
    setup do
      Rails.cache.clear
      create(:setting, current_season_id: '19')
      Setting.current.update!(seasons: { '19' => { 'name' => '2026/2027' } })
      Rails.cache.clear

      @admin = User.create!(
        user_name: "statusadmin_#{SecureRandom.hex(4)}",
        password: 'password123', password_confirmation: 'password123',
        permissions: [{ 'user_group_id' => 1, 'game_operation_id' => 0 }], teams: []
      )
      @aktiv = create(:referee, lizenznummer: 710_001, nachname: 'Aktivsen', gueltigkeit: Date.new(2027, 9, 30))
      @abgelaufen = create(:referee, lizenznummer: 710_002, nachname: 'Abgelaufsen',
                                     gueltigkeit: Date.new(2023, 9, 30))
      @beendet = create(:referee, lizenznummer: 710_003, nachname: 'Beendetsen', gueltigkeit: Date.new(2022, 7, 31))
      @ohne = create(:referee, lizenznummer: 710_004, nachname: 'Ohnesen', gueltigkeit: nil)
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end

    # Fixtures bringen eigene Schiedsrichter mit (u. a. ohne Ablaufdatum),
    # deshalb nur die Nummern dieses Tests betrachten.
    def nummern(params = {})
      get '/api/v2/admin/referees', params: params
      assert_response :success
      response.parsed_body.map { |r| r['lizenznummer'] }.select { |nr| nr.to_i >= 710_000 }
    end

    test 'ohne Filter fehlen die Beendeten' do
      login(@admin)

      assert_equal [710_001, 710_002, 710_004].sort, nummern.sort
    end

    # Ein frisch angelegter Schiedsrichter hat noch kein Ablaufdatum. Zählte man
    # das als „beendet", wäre er unmittelbar nach dem Anlegen unauffindbar.
    test 'neu angelegte Schiedsrichter ohne Ablaufdatum bleiben in der Liste' do
      login(@admin)

      post '/api/v2/admin/referees', params: {
        referee: { lizenznummer: 710_099, vorname: 'Frisch', nachname: 'Angelegt' }
      }
      assert_response :created

      assert_includes nummern, 710_099
    end

    test 'status=alle zeigt auch Beendete' do
      login(@admin)

      assert_equal [710_001, 710_002, 710_003, 710_004].sort, nummern(status: 'alle').sort
    end

    test 'status=beendet zeigt nur Beendete' do
      login(@admin)

      assert_equal [710_003], nummern(status: 'beendet')
    end

    test 'status=ohne_nachweis findet Datensätze ohne Ablaufdatum' do
      login(@admin)

      assert_equal [710_004], nummern(status: 'ohne_nachweis')
    end

    test 'Suche nach der Lizenznummer findet auch Beendete' do
      login(@admin)

      assert_equal [710_003], nummern(q: '710003')
    end

    test 'Namenssuche unterliegt weiter dem Standardfilter' do
      login(@admin)

      assert_empty nummern(q: 'Beendetsen')
    end

    test 'Alt-Parameter active=true funktioniert weiter' do
      login(@admin)

      assert_equal [710_001], nummern(active: 'true')
    end

    # Ein Tippfehler darf nicht still die Standardliste liefern: Wer nach
    # „beendet" filtert und sich vertippt, saehe sonst eine Liste ganz ohne
    # Beendete und schloesse daraus, der Nachimport sei nicht gelaufen.
    test 'unbekannter Status-Filter wird abgewiesen' do
      login(@admin)

      get '/api/v2/admin/referees', params: { status: 'beendete' }

      assert_response :unprocessable_entity
      assert_match(/Unbekannter Status-Filter/, response.parsed_body['errors'].first)
    end

    test 'license_status steht im JSON' do
      login(@admin)

      get '/api/v2/admin/referees', params: { status: 'alle' }
      status_je_nummer = response.parsed_body.to_h { |r| [r['lizenznummer'], r['license_status']] }

      assert_equal 'active', status_je_nummer[710_001]
      assert_equal 'lapsed', status_je_nummer[710_002]
      assert_equal 'career_ended', status_je_nummer[710_003]
      assert_equal 'unknown', status_je_nummer[710_004]
    end
  end
end
