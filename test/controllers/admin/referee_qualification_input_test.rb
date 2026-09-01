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

    # api#585: Die Gueltigkeit ist Pflichtfeld. Der Riegel steht im Controller und
    # nicht erst im Modell, weil sync_qualifications nach @referee.save laeuft --
    # ein dort scheiterndes create! waere eine 500 auf einen schon geschriebenen
    # Schiedsrichter.
    test 'fehlende Gueltigkeit wird abgewiesen und loescht die bestehende Qualifikation nicht' do
      assert_no_enqueued_emails do
        put_referee(qualifications: [{ qualification_type_id: @beob.id, valid_until: nil }])
      end

      assert_response :unprocessable_entity
      assert_match(/valid_until/, errors.join)
      assert_match(/Pflichtfeld/, errors.join)
      assert_equal [@coach.id], qualification_type_ids,
                   'die bestehende Qualifikation muss stehen bleiben'
    end

    # Der leere String kommt aus einem Formular-Post mit unbefuelltem Datumsfeld
    # und ist derselbe Fall -- `nil` allein zu pruefen ginge daran vorbei.
    test 'leere Gueltigkeit wird abgewiesen' do
      put_referee(qualifications: [{ qualification_type_id: @beob.id, valid_until: '' }])

      assert_response :unprocessable_entity
      assert_match(/Pflichtfeld/, errors.join)
      assert_equal [@coach.id], qualification_type_ids
    end

    # Wie beim unparsbaren Datum: Der Riegel greift vor dem Speichern, der
    # Vorgang laeuft nicht halb durch.
    test 'die fehlende Gueltigkeit speichert auch die anderen Felder nicht' do
      put_referee(nachname: 'Neuername',
                  qualifications: [{ qualification_type_id: @beob.id, valid_until: nil }])

      assert_response :unprocessable_entity
      assert_not_equal 'Neuername', @referee.reload.nachname
    end

    # Das Anlegen laeuft durch dieselbe Pruefung (read_qualifications) und darf
    # den Schiedsrichter deshalb gar nicht erst entstehen lassen.
    test 'auch beim Anlegen wird die fehlende Gueltigkeit abgewiesen' do
      assert_no_difference 'Referee.count' do
        post '/api/v2/admin/referees', params: {
          referee: { vorname: 'Neu', nachname: 'Schiri', lizenznummer: 799_001,
                     qualifications: [{ qualification_type_id: @beob.id, valid_until: nil }] }
        }, as: :json
      end

      assert_response :unprocessable_entity
      assert_match(/Pflichtfeld/, errors.join)
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
      # Beide Zeilen mit Datum: Ohne eines faengt sie der Pflichtfeld-Riegel
      # (api#585) schon vorher ab und es bliebe keine Dublette zu melden.
      put_referee(qualifications: [{ qualification_type_id: @beob.id, valid_until: '30.06.2028' },
                                   { qualification_type_id: @beob.id, valid_until: '30.06.2027' }])

      assert_response :unprocessable_entity
      assert_match(/2-mal angegeben/, errors.join)
      assert_equal [@coach.id], qualification_type_ids
    end

    # Lief vorher über das erforderliche belongs_to in einen 500.
    test 'unbekannte Qualifikation wird abgewiesen' do
      put_referee(qualifications: [{ qualification_type_id: 999_999, valid_until: '30.06.2027' }])

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

    # Eine Zeile, die kein Objekt ist, lief in einen 500 (String#[] mit Symbol).
    test 'eine Zeile ohne Objektform wird abgewiesen' do
      put_referee(qualifications: ['B-Coach'])

      assert_response :unprocessable_entity
      assert_match(/erwartet wird ein Objekt/, errors.join)
      assert_equal [@coach.id], qualification_type_ids
    end

    # Formular-Posts adressieren die Zeilen über den Index; daraus macht Rails
    # einen Hash. Ohne Normalisierung spraeche die Meldung ueber eine Zeile, die
    # es so nicht gibt.
    test 'index-adressierte Zeilen werden wie ein Array gelesen' do
      put "/api/v2/admin/referees/#{@referee.id}", params: {
        referee: { qualifications: { '0' => { qualification_type_id: @beob.id, valid_until: '30.06.2028' } } }
      }

      assert_response :success
      assert_equal [@beob.id], qualification_type_ids
    end

    # Gegenprobe: Die gültige Eingabe wird wie bisher komplett neu gesetzt.
    test 'gueltige Eingabe setzt die Qualifikationen neu' do
      put_referee(qualifications: [{ qualification_type_id: @beob.id, valid_until: '30.06.2028' }])

      assert_response :success
      assert_equal [@beob.id], qualification_type_ids
      assert_equal Date.new(2028, 6, 30), @referee.referee_qualifications.first.valid_until
    end

    # Das Alles-Löschen haengt an der Truthiness der leeren Liste. Form-encoded
    # verwirft Rack sie, deshalb `as: :json`.
    test 'eine leere Liste loescht alle Qualifikationen' do
      put "/api/v2/admin/referees/#{@referee.id}",
          params: { referee: { qualifications: [] } }, as: :json

      assert_response :success
      assert_equal [], qualification_type_ids
    end

    # Ohne den Schluessel bleibt der Bestand unangetastet -- sonst loeschte jedes
    # Speichern aus einer anderen Maske die Qualifikationen mit.
    test 'ein Aufruf ohne qualifications laesst den Bestand stehen' do
      put_referee(nachname: 'Neuername')

      assert_response :success
      assert_equal [@coach.id], qualification_type_ids
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
