require 'test_helper'

# api#515: `sync_qualifications` setzt die Zusatzqualifikationen komplett neu
# (destroy_all + create). Eine unbrauchbare Zeile fiel beim Einlesen ganz weg,
# nicht nur ihr Datum, und die bestehende Qualifikation war nach dem destroy_all
# damit weg. Die Antwort war eine 200 ohne Hinweis, ohne Meldung und ohne
# Log-Eintrag, und seit api#514 wird der Wegfall einer Qualifikation dem
# Schiedsrichter bewusst nicht gemeldet.
#
# Über die Oberfläche ist keiner dieser Fälle erreichbar (das Formular schickt
# immer ein parsbares Datum), über einen direkten API-Aufruf schon.
module Admin
  class RefereeQualificationInputTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting)
      @admin = create(:user, :admin)
      @coach = RefereeQualificationType.create!(name: "B-Coach #{SecureRandom.hex(3)}")
      @beob  = RefereeQualificationType.create!(name: "Beobachter #{SecureRandom.hex(3)}")
      @referee = create(:referee, email: 'schiri@example.org')
      @referee.referee_qualifications.create!(referee_qualification_type: @coach,
                                              valid_until: Date.new(2027, 6, 30))
      login(@admin)
    end

    test 'unparsbares Datum wird abgewiesen und loescht die bestehende Qualifikation nicht' do
      assert_no_enqueued_emails do
        put_referee(qualifications: [{ qualification_type_id: @coach.id, valid_until: '31.02.2027' }])
      end

      assert_response :unprocessable_entity
      assert_match(/valid_until/, errors.join)
      assert_match(/TT\.MM\.JJJJ/, errors.join)
      assert_equal [@coach.id], qualification_type_ids,
                   'die bestehende Qualifikation muss stehen bleiben'
    end

    test 'nicht-numerische qualification_type_id wird abgewiesen' do
      put_referee(qualifications: [{ qualification_type_id: 'B-Coach', valid_until: '30.06.2027' }])

      assert_response :unprocessable_entity
      assert_match(/qualification_type_id/, errors.join)
      assert_equal [@coach.id], qualification_type_ids
    end

    # Lief vorher in die Uniqueness-Validierung von RefereeQualification und
    # damit in einen 500.
    test 'dieselbe Qualifikation zweimal wird abgewiesen' do
      put_referee(qualifications: [{ qualification_type_id: @beob.id, valid_until: nil },
                                   { qualification_type_id: @beob.id, valid_until: '30.06.2027' }])

      assert_response :unprocessable_entity
      assert_match(/mehrfach|2-mal/, errors.join)
      assert_equal [@coach.id], qualification_type_ids
    end

    # Lief vorher über das erforderliche belongs_to in einen 500.
    test 'unbekannte Qualifikation wird abgewiesen' do
      put_referee(qualifications: [{ qualification_type_id: 999_999, valid_until: nil }])

      assert_response :unprocessable_entity
      assert_match(/gibt es nicht/, errors.join)
      assert_equal [@coach.id], qualification_type_ids
    end

    # Der Riegel greift vor dem Speichern: Auch die übrigen Felder des
    # Schiedsrichters bleiben unverändert, der Vorgang läuft nicht halb durch.
    test 'die abgewiesene Eingabe speichert auch die anderen Felder nicht' do
      put_referee(nachname: 'Neuername',
                  qualifications: [{ qualification_type_id: @coach.id, valid_until: '31.02.2027' }])

      assert_response :unprocessable_entity
      assert_not_equal 'Neuername', @referee.reload.nachname
    end

    # Gegenprobe: Die gültige Eingabe wird wie bisher komplett neu gesetzt.
    test 'gueltige Eingabe setzt die Qualifikationen neu' do
      put_referee(qualifications: [{ qualification_type_id: @beob.id, valid_until: '30.06.2028' }])

      assert_response :success
      assert_equal [@beob.id], qualification_type_ids
      assert_equal Date.new(2028, 6, 30), @referee.referee_qualifications.first.valid_until
    end

    private

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end

    def put_referee(**felder)
      put "/api/v2/admin/referees/#{@referee.id}", params: { referee: felder }
    end

    def errors
      Array(JSON.parse(response.body)['errors'])
    end

    def qualification_type_ids
      @referee.reload.referee_qualifications.pluck(:referee_qualification_type_id).sort
    end
  end
end
