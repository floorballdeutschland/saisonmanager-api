require 'test_helper'

# Zeilenweises Einreichen eines Kursimports (#631).
#
# Vorher war die Datei die Einheit: `submit` lief ueber alle Zeilen, und eine
# einzige unklare Zeile blockierte in der Vorpruefung die ganzen 100. Die
# Zeilen, die der Importeur zurueckstellt, bleiben jetzt liegen -- er reicht sie
# nach der Klaerung nach oder verwirft sie.
module Admin
  class RefereeCoursePartialSubmitTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting)
      @admin = create(:user, :admin)
      # Ohne passenden Eintrag scheitert der Submit schon an der Vorpruefung
      # ("Unbekannte Lizenzstufen").
      RefereeLicenseLevel.create!(name: 'G', validity_years: 1)
      @import = RefereeCourseImport.create!(
        uploaded_by_user: @admin, filename: 'kurs.csv', total_rows: 3, status: 'in_review'
      )
    end

    # 6/6-Treffer laufen ohne LV-Review durch (RefereeCourseSubmitPolicy) und
    # sind damit der Fall, an dem sich ein doppeltes Anwenden zeigen wuerde:
    # Der Applier wirft auf einer bereits angewendeten Zeile.
    def row(match_type: 'exact_match', deferred: false, **overrides)
      referee = create(:referee, email: "#{SecureRandom.hex(4)}@example.org",
                                 lizenzstufe: nil, gueltigkeit: nil)
      RefereeCourseResult.create!(
        { referee_course_import: @import,
          referee: referee,
          status: 'pending_review',
          deferred: deferred,
          match_type: match_type,
          match_field_count: match_type == 'exact_match' ? 6 : 4,
          csv_vorname: referee.vorname, csv_nachname: referee.nachname,
          # Beide Seiten setzen, wie es der Import-Service tut: Ein `update`
          # spiegelt die Importeurs-Werte auf die finalen (der LV ueberschreibt
          # sie ggf. beim Freigeben). Stuenden hier nur die finalen, wuerde ein
          # PATCH sie leeren und der Schiri verlore seine Adresse.
          master_vorname_by_importer: referee.vorname,
          master_nachname_by_importer: referee.nachname,
          master_email_by_importer: referee.email,
          master_vorname_final: referee.vorname,
          master_nachname_final: referee.nachname,
          master_email_final: referee.email,
          lizenzstufe: 'G',
          gueltigkeit: Date.new(2026, 7, 31),
          kursstichtag: Date.new(2025, 8, 3) }.merge(overrides)
      )
    end

    # Ein RSK mit regionalem Scope ist kein Importeur: Der Kursimport liegt beim
    # RSK des Bundes (Scope 0) bzw. beim Admin.
    def regional_rsk(go_id)
      User.create!(
        user_name: "rsk_#{SecureRandom.hex(4)}",
        password: 'password123',
        password_confirmation: 'password123',
        permissions: [{ 'user_group_id' => 3, 'game_operation_id' => go_id }],
        teams: []
      )
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end

    test 'submit reicht die offenen Zeilen ein und laesst die zurueckgestellte liegen' do
      offen1 = row
      offen2 = row
      zurueck = row(deferred: true)
      login(@admin)

      post "/api/v2/admin/referee_course_imports/#{@import.id}/submit"

      assert_response :success
      # Der Import bleibt offen -- sonst gaebe es keinen Weg, die
      # zurueckgestellte Zeile nachzureichen.
      assert_equal 'partially_submitted', @import.reload.status
      assert_equal(%w[applied applied], [offen1, offen2].map { |r| r.reload.status })
      assert offen1.submitted_at.present?
      assert_equal 'pending_review', zurueck.reload.status
      assert_nil zurueck.submitted_at
      assert_equal 1, response.parsed_body.dig('progress', 'deferred')
      assert_equal 0, response.parsed_body.dig('progress', 'submittable')
    end

    # Der Kern der Beschwerde: Eine Zeile ohne Lizenzstufe wies die Vorpruefung
    # mit "Für 1 Datensätze fehlt die Lizenzstufe" ab -- fuer die ganze Datei.
    test 'die Vorpruefung uebergeht die zurueckgestellte Zeile' do
      offen = row
      row(deferred: true, lizenzstufe: nil, gueltigkeit: nil)
      login(@admin)

      post "/api/v2/admin/referee_course_imports/#{@import.id}/submit"

      assert_response :success
      assert_equal 'applied', offen.reload.status
      assert_equal 'partially_submitted', @import.reload.status
    end

    test 'sind alle offenen Zeilen zurueckgestellt, reicht der Submit nichts ein' do
      zurueck = row(deferred: true)
      login(@admin)

      post "/api/v2/admin/referee_course_imports/#{@import.id}/submit"

      assert_response :unprocessable_entity
      assert_match(/zurückgestellt/, response.parsed_body['error'])
      assert_equal 'in_review', @import.reload.status
      assert_equal 'pending_review', zurueck.reload.status
    end

    # Der zweite Lauf darf ausschliesslich die nachgereichte Zeile anfassen. Ohne
    # `submitted_at` je Zeile waere die schon angewendete von ihr nicht zu
    # unterscheiden (beide `pending_review` bzw. im selben Import) und der
    # Applier wuerde auf ihr scheitern.
    test 'der zweite Submit reicht nur die nachgereichte Zeile ein' do
      erste = row
      zurueck = row(deferred: true)
      login(@admin)
      post "/api/v2/admin/referee_course_imports/#{@import.id}/submit"
      assert_response :success
      applied_at = erste.reload.applied_at

      patch "/api/v2/admin/referee_course_results/#{zurueck.id}", params: { deferred: false }
      assert_response :success

      assert_enqueued_emails 1 do
        post "/api/v2/admin/referee_course_imports/#{@import.id}/submit"
        assert_response :success
      end

      assert_equal 'submitted', @import.reload.status
      assert_equal 'applied', zurueck.reload.status
      assert_equal applied_at, erste.reload.applied_at
    end

    # Gegenprobe zur Freigabe-Warteschlange: Zwischen der Zeile, die auf den LV
    # wartet, und der zurueckgestellten steht in einem teilweise eingereichten
    # Import nur `submitted_at`. Der Import-Status trennt sie nicht mehr.
    test 'eine zurueckgestellte Zeile steht nicht in der LV-Warteschlange' do
      wartet = row(match_type: 'partial_match', state_association_id: nil)
      zurueck = row(deferred: true)
      login(@admin)
      post "/api/v2/admin/referee_course_imports/#{@import.id}/submit"
      assert_response :success

      get '/api/v2/admin/referee_course_results'

      assert_response :success
      ids = response.parsed_body.map { |r| r['id'] }
      assert_includes ids, wartet.id
      assert_not_includes ids, zurueck.id
    end

    test 'der Importeur bearbeitet die zurueckgestellte Zeile weiter, die eingereichte nicht' do
      eingereicht = row
      zurueck = row(deferred: true)
      login(@admin)
      post "/api/v2/admin/referee_course_imports/#{@import.id}/submit"
      assert_response :success

      patch "/api/v2/admin/referee_course_results/#{zurueck.id}", params: { lizenzstufe: 'G' }
      assert_response :success

      patch "/api/v2/admin/referee_course_results/#{eingereicht.id}", params: { lizenzstufe: 'G' }
      assert_response :forbidden
    end

    test 'zurueckstellen und wieder aufnehmen laeuft ueber dieselbe Route' do
      offen = row
      login(@admin)

      patch "/api/v2/admin/referee_course_results/#{offen.id}", params: { deferred: true }
      assert_response :success
      assert offen.reload.deferred
      assert_equal 1, @import.referee_course_results.deferred.count

      patch "/api/v2/admin/referee_course_results/#{offen.id}", params: { deferred: false }
      assert_response :success
      assert_not offen.reload.deferred
    end

    test 'verworfene Zeile schliesst den teilweise eingereichten Import ab' do
      row
      zurueck = row(deferred: true)
      login(@admin)
      post "/api/v2/admin/referee_course_imports/#{@import.id}/submit"
      assert_response :success

      post "/api/v2/admin/referee_course_results/#{zurueck.id}/discard"

      assert_response :success
      assert_equal 'rejected', zurueck.reload.status
      assert_equal 'Vom Importeur verworfen', zurueck.rejection_reason
      assert_equal @admin.id, zurueck.reviewed_by_user_id
      # Keine offene Zeile mehr: Der Import darf nicht dauerhaft als
      # „teilweise eingereicht" stehen bleiben.
      assert_equal 'submitted', @import.reload.status
    end

    # Ohne den Statusfilter in `submittable` wuerde der naechste Submit die
    # verworfene Zeile doch noch anwenden. Zwei zurueckgestellte Zeilen, damit
    # der Import nach dem Verwerfen offen bleibt: Sonst blockt schon der
    # Status-Riegel den zweiten Submit und der Test bestuende auch ohne Filter.
    test 'eine verworfene Zeile reicht kein zweiter Submit nach' do
      row
      verworfen = row(deferred: true)
      nachgereicht = row(deferred: true)
      login(@admin)
      post "/api/v2/admin/referee_course_imports/#{@import.id}/submit"
      assert_response :success
      post "/api/v2/admin/referee_course_results/#{verworfen.id}/discard"
      assert_response :success
      patch "/api/v2/admin/referee_course_results/#{nachgereicht.id}", params: { deferred: false }
      assert_response :success

      post "/api/v2/admin/referee_course_imports/#{@import.id}/submit"

      assert_response :success
      assert_equal 'applied', nachgereicht.reload.status
      assert_equal 'rejected', verworfen.reload.status
      assert_nil verworfen.applied_at
      assert_nil verworfen.submitted_at
      assert_equal 'submitted', @import.reload.status
    end

    test 'verwerfen einer eingereichten Zeile ist gesperrt' do
      eingereicht = row(match_type: 'partial_match', state_association_id: nil)
      row(deferred: true)
      login(@admin)
      post "/api/v2/admin/referee_course_imports/#{@import.id}/submit"
      assert_response :success

      post "/api/v2/admin/referee_course_results/#{eingereicht.id}/discard"

      assert_response :forbidden
      assert_equal 'pending_review', eingereicht.reload.status
      assert_nil eingereicht.rejection_reason
    end

    test 'ein regionaler RSK darf keine Zeile verwerfen' do
      zeile = row(deferred: true)
      go = create(:game_operation)
      login(regional_rsk(go.id))

      post "/api/v2/admin/referee_course_results/#{zeile.id}/discard"

      assert_response :forbidden
      assert_equal 'pending_review', zeile.reload.status
    end

    # Der Verwerfen-Vermerk (Grund, Benutzer, Zeitpunkt) ist der Audit-Trail der
    # Zeile und darf nicht ueberschreibbar sein.
    test 'eine verworfene Zeile ist nicht weiter bearbeitbar' do
      zeile = row(deferred: true)
      login(@admin)
      post "/api/v2/admin/referee_course_results/#{zeile.id}/discard"
      assert_response :success
      vermerk = zeile.reload.reviewed_at

      post "/api/v2/admin/referee_course_results/#{zeile.id}/discard", params: { reason: 'Nochmal' }
      assert_response :forbidden

      patch "/api/v2/admin/referee_course_results/#{zeile.id}", params: { lizenzstufe: 'G' }
      assert_response :forbidden

      assert_equal 'Vom Importeur verworfen', zeile.reload.rejection_reason
      assert_equal vermerk.to_i, zeile.reviewed_at.to_i
    end

    # Der Entwurf, dessen Zeilen alle verworfen sind: Es ist keine Zeile
    # zurueckgestellt, es ist gar keine mehr offen. Die Meldung muss den
    # Unterschied machen, sonst sucht der Importeur eine Zeile zum
    # Wiederaufnehmen, die es nicht gibt -- der Weg ist Abbrechen.
    test 'sind alle Zeilen verworfen, sagt der Submit das und nicht etwas anderes' do
      zeile = row
      login(@admin)
      patch "/api/v2/admin/referee_course_results/#{zeile.id}", params: { deferred: true }
      assert_response :success
      post "/api/v2/admin/referee_course_results/#{zeile.id}/discard"
      assert_response :success

      post "/api/v2/admin/referee_course_imports/#{@import.id}/submit"

      assert_response :unprocessable_entity
      assert_match(/Keine offenen Zeilen mehr/, response.parsed_body['error'])
      assert_equal 'in_review', @import.reload.status
    end

    # Selbstheilung: Ueberholen sich ein Verwerfen und ein Submit, kann ein
    # Import auf `partially_submitted` mit null offenen Zeilen stehen bleiben --
    # dann ist er weder einreichbar noch abbrechbar. Der Submit zieht den
    # Abschluss nach, statt nur abzuweisen.
    test 'ein teilweise eingereichter Import ohne offene Zeilen wird beim Submit abgeschlossen' do
      row
      login(@admin)
      post "/api/v2/admin/referee_course_imports/#{@import.id}/submit"
      assert_response :success
      # Die Lage von Hand herstellen, wie sie das Rennen hinterlassen konnte.
      @import.update!(status: 'partially_submitted')

      post "/api/v2/admin/referee_course_imports/#{@import.id}/submit"

      assert_response :unprocessable_entity
      assert_equal 'submitted', @import.reload.status
    end

    test 'ein teilweise eingereichter Import laesst sich nicht abbrechen' do
      row
      row(deferred: true)
      login(@admin)
      post "/api/v2/admin/referee_course_imports/#{@import.id}/submit"
      assert_response :success

      delete "/api/v2/admin/referee_course_imports/#{@import.id}"

      assert_response :unprocessable_entity
      assert_match(/Teilweise eingereichte/, response.parsed_body['error'])
      assert_equal 'partially_submitted', @import.reload.status
    end

    # Die Freigabe haengt an der Zeile, nicht am Import: Ein teilweise
    # eingereichter Import ist fuer seine eingereichten Zeilen ein
    # eingereichter.
    test 'der LV kann eine Zeile aus einem teilweise eingereichten Import freigeben' do
      wartet = row(match_type: 'partial_match', state_association_id: nil)
      row(deferred: true)
      login(@admin)
      post "/api/v2/admin/referee_course_imports/#{@import.id}/submit"
      assert_response :success

      post "/api/v2/admin/referee_course_results/#{wartet.id}/approve"

      assert_response :success
      assert_equal 'applied', wartet.reload.status
      assert_equal 'partially_submitted', @import.reload.status
    end
  end
end
