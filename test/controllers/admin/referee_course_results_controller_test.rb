require 'test_helper'

module Admin
  class RefereeCourseResultsControllerTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting)
      @admin = create(:user, :admin)
      # Eingereichter Import: nur dessen offene Zeilen sind Freigabe-Fälle.
      @import = RefereeCourseImport.create!(
        uploaded_by_user: @admin, filename: 't.csv', total_rows: 1, status: 'submitted'
      )
      # Kursjahr 2025: Ablaufjahr hängt an der Dauer der zugeordneten Stufe.
      @result = RefereeCourseResult.create!(
        referee_course_import: @import,
        status: 'pending_review',
        match_type: 'new_entry',
        match_field_count: 0,
        csv_vorname: 'V', csv_nachname: 'N',
        kursstichtag: Date.new(2025, 8, 3)
      )
      # Noch nicht eingereicht: Diese Zeile gehört dem Importeur, nicht dem LV.
      @draft_import = RefereeCourseImport.create!(
        uploaded_by_user: @admin, filename: 'entwurf.csv', total_rows: 1, status: 'in_review'
      )
      @draft_result = RefereeCourseResult.create!(
        referee_course_import: @draft_import,
        status: 'pending_review',
        match_type: 'new_entry',
        match_field_count: 0,
        csv_vorname: 'V', csv_nachname: 'N',
        kursstichtag: Date.new(2025, 8, 3)
      )
    end

    # Dritte Säule der Vereinheitlichung (#87): setzt der LV-Reviewer die Stufe,
    # leitet der Controller die Gültigkeit über RefereeLicenseLevel.gueltigkeit_for
    # ab — mit der Dauer DIESER Stufe und dem Regeljahr-Stichtag.
    test 'update leitet gueltigkeit aus der Stufe ab (Regeljahr → 31.07.)' do
      RefereeLicenseLevel.create!(name: 'G', validity_years: 1)
      login(@admin)

      # 2025 + 1 = 2026 (Regeljahr) → 31.07.2026
      patch "/api/v2/admin/referee_course_results/#{@draft_result.id}", params: { lizenzstufe: 'G' }

      assert_response :success
      assert_equal '2026-07-31', JSON.parse(response.body)['gueltigkeit']
      assert_equal Date.new(2026, 7, 31), @draft_result.reload.gueltigkeit
    end

    test 'update nutzt die validity_years der Stufe (kein Regeljahr → 30.09.)' do
      RefereeLicenseLevel.create!(name: 'N1', validity_years: 2)
      login(@admin)

      # 2025 + 2 = 2027 (kein Regeljahr) → 30.09.2027
      patch "/api/v2/admin/referee_course_results/#{@draft_result.id}", params: { lizenzstufe: 'N1' }

      assert_response :success
      assert_equal Date.new(2027, 9, 30), @draft_result.reload.gueltigkeit
    end

    test 'update belässt eine explizit mitgesendete gueltigkeit (manueller Wert hat Vorrang)' do
      RefereeLicenseLevel.create!(name: 'G', validity_years: 1)
      login(@admin)

      patch "/api/v2/admin/referee_course_results/#{@draft_result.id}",
            params: { lizenzstufe: 'G', gueltigkeit: '2099-01-15' }

      assert_response :success
      assert_equal Date.new(2099, 1, 15), @draft_result.reload.gueltigkeit
    end

    # Der „Anwenden"-Pfad (approve → RefereeCourseResultApplier) leitet die
    # Gültigkeit ebenfalls über gueltigkeit_for ab und überschreibt dabei einen
    # veralteten, zuvor gespeicherten Wert — hier end-to-end über HTTP geprüft.
    test 'approve leitet die gueltigkeit des Referees ueber gueltigkeit_for ab (Regeljahr → 31.07.)' do
      RefereeLicenseLevel.create!(name: 'G', validity_years: 1)
      referee = create(:referee, lizenzstufe: nil, gueltigkeit: nil)
      result = RefereeCourseResult.create!(
        referee_course_import: @import,
        referee: referee,
        status: 'pending_review',
        match_type: 'exact_match',
        match_field_count: 6,
        csv_vorname: referee.vorname, csv_nachname: referee.nachname,
        lizenzstufe: 'G',
        gueltigkeit: Date.new(2026, 9, 30), # veralteter 30.09.-Wert, wird neu abgeleitet
        kursstichtag: Date.new(2025, 8, 3)
      )
      login(@admin)

      post "/api/v2/admin/referee_course_results/#{result.id}/approve"

      assert_response :success
      # 2025 + 1 = 2026 (Regeljahr) → 31.07.2026, nicht der gespeicherte 30.09.
      assert_equal Date.new(2026, 7, 31), referee.reload.gueltigkeit
      assert_equal 'applied', result.reload.status
    end

    # Die Lizenzmail zu einer review-pflichtigen Zeile geht erst mit der Freigabe
    # des Landesverbands raus. Beim Submit stehen die Lizenzfelder zwar schon beim
    # Schiri, gemeldet wird sie aber erst hier — vermerkt über
    # license_notification_pending.
    test 'approve schickt die beim Submit vermerkte Lizenzmail' do
      result = pending_result(license_notification_pending: true)
      login(@admin)

      assert_enqueued_emails 1 do
        post "/api/v2/admin/referee_course_results/#{result.id}/approve"
        assert_response :success
      end

      perform_enqueued_jobs
      assert_equal ['schiri@example.org'], ActionMailer::Base.deliveries.last.to
      assert_not result.reload.license_notification_pending
    end

    # Hat der Submit an der Lizenz nichts geändert (nachgereichte Zeile,
    # Wiederholungsabnahme mit identischer Stufe), ist nichts vermerkt und die
    # Freigabe meldet auch nichts.
    test 'approve ohne vermerkte Aenderung schickt keine Mail' do
      result = pending_result(license_notification_pending: false)
      login(@admin)

      assert_enqueued_emails 0 do
        post "/api/v2/admin/referee_course_results/#{result.id}/approve"
        assert_response :success
      end
    end

    test 'reject schickt keine Mail und nimmt den Vermerk zurueck' do
      result = pending_result(license_notification_pending: true)
      login(@admin)

      assert_enqueued_emails 0 do
        post "/api/v2/admin/referee_course_results/#{result.id}/reject", params: { reason: 'Falscher Kurs' }
        assert_response :success
      end

      assert_not result.reload.license_notification_pending
    end

    # Dieselbe Ursache wie in RefereeScoping#lv_club_ids: In die Ergebniszeile
    # schreibt der Controller die rohe `clubs.state_association_id`, also den
    # untergeordneten Landesverband. Der Reviewer-Scope las dagegen nur die Wurzel
    # am Spielbetrieb -- der RSK eines Spielverbunds bekam seine eigenen
    # Kursergebnisse damit nie zur Freigabe.
    test 'RSK eines Spielverbunds sieht die Kursergebnisse der untergeordneten Landesverbaende' do
      verbund = create(:state_association, referee_license_review_enabled: true)
      go = create(:game_operation, state_association_id: verbund.id)
      kind = create(:state_association, parent_id: verbund.id)
      @result.update!(state_association_id: kind.id)

      login(rsk_user(go.id))
      get '/api/v2/admin/referee_course_results'

      assert_response :success
      assert_includes response.parsed_body.map { |r| r['id'] }, @result.id
    end

    test 'RSK eines Spielverbunds sieht die Kursergebnisse eines fremden Landesverbands nicht' do
      verbund = create(:state_association, referee_license_review_enabled: true)
      go = create(:game_operation, state_association_id: verbund.id)
      create(:state_association, parent_id: verbund.id)
      @result.update!(state_association_id: create(:state_association).id)

      login(rsk_user(go.id))
      get '/api/v2/admin/referee_course_results'

      assert_response :success
      assert_not_includes response.parsed_body.map { |r| r['id'] }, @result.id
    end

    # --- Import-Status: was gehoert ueberhaupt in die Freigabe? -------------
    # Der Import-Service legt jede Zeile sofort beim Upload mit `pending_review`
    # an. Ohne den Import-Status im Filter stand die Vorschau eines noch nicht
    # eingereichten Imports mit einem „Freigeben"-Knopf beim LV.
    test 'index zeigt keine Zeilen eines noch nicht eingereichten Imports' do
      login(@admin)

      get '/api/v2/admin/referee_course_results'

      assert_response :success
      ids = response.parsed_body.map { |r| r['id'] }
      assert_includes ids, @result.id
      assert_not_includes ids, @draft_result.id
    end

    test 'index zeigt keine Zeilen eines abgebrochenen Imports' do
      @import.update!(status: 'cancelled')
      login(@admin)

      get '/api/v2/admin/referee_course_results'

      assert_response :success
      assert_not_includes response.parsed_body.map { |r| r['id'] }, @result.id
    end

    # Der „Freigeben"-Knopf einer veralteten Liste im Browser darf nicht doch
    # noch schreiben: Ein Approve auf die Zeile eines abgebrochenen Imports hat
    # zuvor Lizenzstufe und Stammdaten auf den Schiri geschrieben.
    test 'approve auf die Zeile eines abgebrochenen Imports schreibt nicht' do
      result = pending_result(license_notification_pending: true)
      @import.update!(status: 'cancelled')
      referee = result.referee
      login(@admin)

      assert_enqueued_emails 0 do
        post "/api/v2/admin/referee_course_results/#{result.id}/approve"
      end

      assert_response :unprocessable_entity
      assert_equal 'pending_review', result.reload.status
      assert_nil result.applied_at
      assert_equal referee.attributes, referee.reload.attributes
    end

    # Bewusst mit einer vollstaendig anwendbaren Zeile: Fehlte ihr die
    # Lizenzstufe, wuerde approve schon im Applier scheitern und der Test
    # bestaende auch ohne den Import-Status-Guard.
    test 'approve auf die Zeile eines nicht eingereichten Imports schreibt nicht' do
      result = pending_result(license_notification_pending: true, import: @draft_import)
      referee = result.referee
      login(@admin)

      assert_enqueued_emails 0 do
        post "/api/v2/admin/referee_course_results/#{result.id}/approve"
      end

      assert_response :unprocessable_entity
      assert_equal 'pending_review', result.reload.status
      assert_nil result.applied_at
      assert_equal referee.attributes, referee.reload.attributes
    end

    test 'reject auf die Zeile eines abgebrochenen Imports aendert nichts' do
      @import.update!(status: 'cancelled')
      login(@admin)

      post "/api/v2/admin/referee_course_results/#{@result.id}/reject", params: { reason: 'Egal' }

      assert_response :unprocessable_entity
      assert_equal 'pending_review', @result.reload.status
    end

    # --- Snapshot: was sieht der LV? ---------------------------------------
    # Ohne geburtsdatum/email im Snapshot zeigt die Maske in der Spalte
    # „Datenbank" ein „—", obwohl der Wert beim Schiri steht — eine Abweichung
    # in genau diesen Feldern war unsichtbar (Fall „Paul Morgenroth").
    test 'index liefert Geburtsdatum und E-Mail des Schiris im Snapshot' do
      club = create(:club, name: 'UV Zwigge 07')
      referee = create(:referee, geburtsdatum: Date.new(2000, 7, 18),
                                 email: 'paul@example.org', club_id: club.id)
      @result.update!(referee: referee)
      login(@admin)

      get '/api/v2/admin/referee_course_results'

      assert_response :success
      snap = response.parsed_body.find { |r| r['id'] == @result.id }['referee_snapshot']
      assert_equal '2000-07-18', snap['geburtsdatum']
      assert_equal 'paul@example.org', snap['email']
      # Der Vereinsname, nicht nur die id — sonst ist der Verein in der Maske
      # nicht darstellbar.
      assert_equal 'UV Zwigge 07', snap['club_name']
    end

    # Der Verein ist das Merkmal, an dem die meisten Teilmatches haengen (die
    # Datei schreibt ihn aus, die Datenbank fuehrt die Kurzform). Die Maske
    # braucht beide Seiten: csv.verein aus der Datei und den gematchten Club.
    test 'index liefert den gematchten Verein der Zeile' do
      club = create(:club, name: 'UV Zwigge 07')
      @result.update!(master_club_id_final: club.id, csv_verein: 'Unihockeyverein Zwigge 07 e.V.')
      login(@admin)

      get '/api/v2/admin/referee_course_results'

      assert_response :success
      row = response.parsed_body.find { |r| r['id'] == @result.id }
      assert_equal 'UV Zwigge 07', row['matched_club']['name']
      assert_equal 'Unihockeyverein Zwigge 07 e.V.', row['csv']['verein']
    end

    private

    def rsk_user(go_id)
      User.create!(
        user_name: "rsk_#{SecureRandom.hex(4)}",
        password: 'password123',
        password_confirmation: 'password123',
        permissions: [{ 'user_group_id' => 3, 'game_operation_id' => go_id }],
        teams: []
      )
    end

    # Zeile, die auf die LV-Freigabe wartet: Lizenzfelder stehen (der Submit hat
    # sie geschrieben), der Schiri ist erreichbar.
    def pending_result(license_notification_pending:, import: @import)
      referee = create(:referee, email: 'schiri@example.org',
                                 lizenzstufe: 'G', gueltigkeit: Date.new(2026, 7, 31))
      RefereeCourseResult.create!(
        referee_course_import: import,
        referee: referee,
        status: 'pending_review',
        match_type: 'partial_match',
        match_field_count: 4,
        csv_vorname: referee.vorname, csv_nachname: referee.nachname,
        # Der Approve übernimmt die Stammdaten (apply_master_fields) und leert
        # dabei bewusst leere Felder — ohne die Adresse hier wäre der Schiri nach
        # der Freigabe ohne E-Mail und die Mail fiele aus.
        master_email_final: referee.email,
        lizenzstufe: 'G',
        gueltigkeit: Date.new(2026, 7, 31),
        kursstichtag: Date.new(2025, 8, 3),
        license_notification_pending: license_notification_pending
      )
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
