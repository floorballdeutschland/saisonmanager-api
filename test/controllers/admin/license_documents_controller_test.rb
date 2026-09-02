require 'test_helper'

module Admin
  # Spieler-Scope der Lizenz-Dokumente: Uploads gelten pro Spieler
  # (saisonübergreifend), nicht mehr pro Lizenz.
  class LicenseDocumentsControllerTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting, current_season_id: '18')
      @player = create(:player)
      login(create(:user, :admin))
    end

    test 'Upload ohne license_id legt ein Spieler-Dokument mit Saison an' do
      post "/api/v2/admin/players/#{@player.id}/license_documents",
           params: { document_type: 'use', file: fixture_file_upload('dokument.pdf', 'application/pdf') }

      assert_response :created
      body = JSON.parse(response.body)
      assert_equal 'use', body['document_type']
      assert_equal 18, body['season_id']

      doc = @player.license_documents.sole
      assert_nil doc.license_id
    end

    test 'neuer Upload loest alle vorhandenen Dokumente derselben Art ab (auch Lizenz-Altbestand)' do
      old_doc = LicenseDocument.new(player: @player, license_id: 'alte-lizenz-uuid', document_type: 'use')
      old_doc.file.attach(io: StringIO.new('%PDF-1.4 alt'), filename: 'alt.pdf', content_type: 'application/pdf')
      old_doc.save!

      post "/api/v2/admin/players/#{@player.id}/license_documents",
           params: { document_type: 'use', file: fixture_file_upload('dokument.pdf', 'application/pdf') }

      assert_response :created
      docs = @player.license_documents.active.where(document_type: 'use')
      assert_equal 1, docs.count
      assert_not_equal old_doc.id, docs.sole.id
    end

    test 'erneuter Upload ersetzt auch ein spielerbezogenes Dokument ohne license_id' do
      2.times do
        post "/api/v2/admin/players/#{@player.id}/license_documents",
             params: { document_type: 'use', file: fixture_file_upload('dokument.pdf', 'application/pdf') }
        assert_response :created
      end

      assert_equal 1, @player.license_documents.active.where(document_type: 'use').count
    end

    test 'ungültiger Upload lässt das bestehende Dokument unangetastet' do
      existing = LicenseDocument.new(player: @player, document_type: 'use')
      existing.file.attach(io: StringIO.new('%PDF-1.4'), filename: 'alt.pdf', content_type: 'application/pdf')
      existing.save!

      post "/api/v2/admin/players/#{@player.id}/license_documents",
           params: { document_type: 'use', file: fixture_file_upload('notiz.txt', 'text/plain') }

      assert_response :unprocessable_entity
      assert LicenseDocument.exists?(existing.id), 'Rollback muss das alte Dokument erhalten'
      # Seit der Archivierung genuegt "existiert noch" als Nachweis nicht mehr:
      # Ohne Rollback stuende die alte Fassung archiviert da und der Spieler
      # haette gar kein aktuelles Dokument dieser Art.
      existing.reload
      assert_not existing.archived?, 'die alte Fassung muss aktiv bleiben'
      assert_nil existing.archived_reason
      assert_equal 1, @player.license_documents.active.where(document_type: 'use').count
    end

    test 'Index liefert ohne license_id-Filter alle Dokumente des Spielers' do
      legacy = LicenseDocument.new(player: @player, license_id: 'lizenz-a', document_type: 'id_copy')
      legacy.file.attach(io: StringIO.new('%PDF-1.4'), filename: 'a.pdf', content_type: 'application/pdf')
      legacy.save!
      current = LicenseDocument.new(player: @player, document_type: 'use')
      current.file.attach(io: StringIO.new('%PDF-1.4'), filename: 'b.pdf', content_type: 'application/pdf')
      current.save!

      get "/api/v2/admin/players/#{@player.id}/license_documents"

      assert_response :success
      types = JSON.parse(response.body).map { |d| d['document_type'] }
      assert_equal %w[id_copy use], types.sort
    end

    test 'Index reichert Dokumente mit Verbands- und Katalogdaten an' do
      DocumentType.create!(name: 'LV-Attest', game_operation_id: create(:game_operation).id)
      doc = LicenseDocument.new(player: @player, document_type: DocumentType.last.key)
      doc.file.attach(io: StringIO.new('%PDF-1.4'), filename: 'a.pdf', content_type: 'application/pdf')
      doc.save!

      get "/api/v2/admin/players/#{@player.id}/license_documents"

      assert_response :success
      body = JSON.parse(response.body).first
      assert_equal 'LV-Attest', body['document_type_name']
      assert_equal DocumentType.last.game_operation_id, body['game_operation_id']
      assert body['game_operation_name'].present?
    end

    test 'gescopte SBK sieht globale und eigene, nicht aber fremde Verbandsdokumente' do
      # Zwei getrennte Landesverbaende, nicht zwei Spielbetriebe an einem: Sonst
      # entscheidet die Erzeugungsreihenfolge, welcher zustaendig ist
      # (GameOperation.id_by_state_association behaelt die niedrigere ID), und ein
      # Vertauschen der beiden Zeilen liesse den Test aus dem falschen Grund
      # gruen bleiben.
      own_go = create(:game_operation, state_association_id: create(:state_association).id)
      foreign_go = create(:game_operation, state_association_id: create(:state_association).id)
      # Der Spieler muss dem Verband des SBK zugeordnet sein, damit die
      # Lese-Berechtigung greift (admin_or_sbk_for_player?).
      club = create(:club, game_operation: own_go)
      @player.update!(clubs: [{ 'club_id' => club.id }])

      global = DocumentType.create!(name: 'Unterstellungserklärung')
      own = DocumentType.create!(name: 'Eigenes LV-Attest', game_operation_id: own_go.id)
      foreign = DocumentType.create!(name: 'Fremd-Attest', game_operation_id: foreign_go.id)
      [global, own, foreign].each_with_index do |dt, i|
        d = LicenseDocument.new(player: @player, document_type: dt.key)
        d.file.attach(io: StringIO.new('%PDF-1.4'), filename: "d#{i}.pdf", content_type: 'application/pdf')
        d.save!
      end

      login(create(:user, :sbk_scoped, game_operation_id: own_go.id))
      get "/api/v2/admin/players/#{@player.id}/license_documents"

      assert_response :success
      types = JSON.parse(response.body).map { |d| d['document_type'] }
      assert_includes types, global.key
      assert_includes types, own.key
      assert_not_includes types, foreign.key
    end

    test 'gescopte SBK darf ein fremdes Verbandsdokument nicht per show abrufen' do
      # Zwei getrennte Landesverbaende, nicht zwei Spielbetriebe an einem: Sonst
      # entscheidet die Erzeugungsreihenfolge, welcher zustaendig ist
      # (GameOperation.id_by_state_association behaelt die niedrigere ID), und ein
      # Vertauschen der beiden Zeilen liesse den Test aus dem falschen Grund
      # gruen bleiben.
      own_go = create(:game_operation, state_association_id: create(:state_association).id)
      foreign_go = create(:game_operation, state_association_id: create(:state_association).id)
      club = create(:club, game_operation: own_go)
      @player.update!(clubs: [{ 'club_id' => club.id }])

      foreign = DocumentType.create!(name: 'Fremd-Attest', game_operation_id: foreign_go.id)
      doc = LicenseDocument.new(player: @player, document_type: foreign.key)
      doc.file.attach(io: StringIO.new('%PDF-1.4'), filename: 'f.pdf', content_type: 'application/pdf')
      doc.save!

      login(create(:user, :sbk_scoped, game_operation_id: own_go.id))
      get "/api/v2/admin/players/#{@player.id}/license_documents/#{doc.id}"

      assert_response :forbidden
    end

    # --- available_types: Auswahlliste für den Upload am Spielerprofil ---

    test 'available_types liefert globale Arten und die des zustaendigen Spielbetriebs' do
      # Zwei getrennte Landesverbaende, nicht zwei Spielbetriebe an einem: Sonst
      # entscheidet die Erzeugungsreihenfolge, welcher zustaendig ist
      # (GameOperation.id_by_state_association behaelt die niedrigere ID), und ein
      # Vertauschen der beiden Zeilen liesse den Test aus dem falschen Grund
      # gruen bleiben.
      own_go = create(:game_operation, state_association_id: create(:state_association).id)
      foreign_go = create(:game_operation, state_association_id: create(:state_association).id)
      club = create(:club, game_operation: own_go)
      @player.update!(clubs: [{ 'club_id' => club.id, 'home_club' => true }])

      global = DocumentType.create!(name: 'Unterstellungserklärung')
      own = DocumentType.create!(name: 'Eigenes LV-Attest', game_operation_id: own_go.id)
      foreign = DocumentType.create!(name: 'Fremd-Attest', game_operation_id: foreign_go.id)

      get "/api/v2/admin/players/#{@player.id}/document_types"

      assert_response :success
      body = JSON.parse(response.body)
      keys = body.map { |t| t['key'] }
      assert_includes keys, global.key
      assert_includes keys, own.key
      assert_not_includes keys, foreign.key

      own_entry = body.find { |t| t['key'] == own.key }
      assert_equal own_go.name, own_entry['game_operation_name']
      assert_equal 'once', own_entry['validity']
    end

    # Eine abgelaufene Freigabe (Zweitspielrecht) ist keine Vereinszugehörigkeit
    # mehr und darf den Verband ihres Vereins nicht mehr in die Auswahl holen.
    test 'available_types beachtet nur aktuell gueltige Vereinszugehoerigkeiten' do
      sa = create(:state_association)
      home_go = create(:game_operation, state_association_id: sa.id)
      past_go = create(:game_operation)
      home_club = create(:club, game_operation: home_go)
      past_club = create(:club, game_operation: past_go)
      @player.update!(clubs: [
        { 'club_id' => home_club.id, 'home_club' => true },
        { 'club_id' => past_club.id, 'valid_until' => 1.year.ago.iso8601 }
      ])

      current = DocumentType.create!(name: 'Aktuelles LV-Attest', game_operation_id: home_go.id)
      expired = DocumentType.create!(name: 'Altes LV-Attest', game_operation_id: past_go.id)

      get "/api/v2/admin/players/#{@player.id}/document_types"

      assert_response :success
      keys = JSON.parse(response.body).map { |t| t['key'] }
      assert_includes keys, current.key
      assert_not_includes keys, expired.key
    end

    # Altersabhaengige Arten koennen fuer einen erwachsenen Spieler nie wieder
    # gefordert sein (DocumentType#required_for?) und gehoeren nicht in die Auswahl.
    test 'available_types blendet altersabhaengige Arten fuer Erwachsene aus' do
      consent = DocumentType.create!(name: 'Zustimmung Erziehungsberechtigte', required_below_age: 18)

      @player.update!(birthdate: 30.years.ago.to_date)
      get "/api/v2/admin/players/#{@player.id}/document_types"
      assert_response :success
      assert_not_includes JSON.parse(response.body).map { |t| t['key'] }, consent.key

      minor = create(:player, birthdate: 14.years.ago.to_date)
      get "/api/v2/admin/players/#{minor.id}/document_types"
      assert_response :success
      assert_includes JSON.parse(response.body).map { |t| t['key'] }, consent.key
    end

    # Dasselbe fuer die Jahrgangsform: Ein aelterer Jahrgang faellt aus der Auswahl,
    # der Jahrgang selbst bleibt drin. Und das neue Feld muss mit ausgeliefert
    # werden, sonst kann die Oberflaeche die Regel nicht anzeigen.
    test 'available_types blendet Jahrgangsarten fuer aeltere Jahrgaenge aus' do
      attest = DocumentType.create!(name: 'Sportaerztliches Attest', required_from_birth_year: 2012)

      @player.update!(birthdate: Date.new(2011, 12, 31))
      get "/api/v2/admin/players/#{@player.id}/document_types"
      assert_response :success
      assert_not_includes JSON.parse(response.body).map { |t| t['key'] }, attest.key

      im_jahrgang = create(:player, birthdate: Date.new(2012, 1, 1))
      get "/api/v2/admin/players/#{im_jahrgang.id}/document_types"
      assert_response :success
      listed = JSON.parse(response.body).find { |t| t['key'] == attest.key }
      assert_not_nil listed, 'der getroffene Jahrgang muss in der Auswahl stehen'
      assert_equal 2012, listed['required_from_birth_year']
    end

    # Der Spieler gehoert zwei Vereinen in verschiedenen Verbaenden. Der gescopte
    # SBK darf ihn lesen (eigener Verband), bekommt die Dokumente des fremden
    # Verbands aber nicht zu sehen – dann darf die Art auch nicht in der Auswahl
    # stehen, sonst laedt er in ein Loch hoch.
    test 'available_types haelt fremde Verbandsarten vom gescopten SBK fern' do
      # Zwei getrennte Landesverbaende, nicht zwei Spielbetriebe an einem: Sonst
      # entscheidet die Erzeugungsreihenfolge, welcher zustaendig ist
      # (GameOperation.id_by_state_association behaelt die niedrigere ID), und ein
      # Vertauschen der beiden Zeilen liesse den Test aus dem falschen Grund
      # gruen bleiben.
      own_go = create(:game_operation, state_association_id: create(:state_association).id)
      foreign_go = create(:game_operation, state_association_id: create(:state_association).id)
      own_club = create(:club, game_operation: own_go)
      foreign_club = create(:club, game_operation: foreign_go)
      @player.update!(clubs: [
        { 'club_id' => own_club.id, 'home_club' => true },
        { 'club_id' => foreign_club.id }
      ])

      global = DocumentType.create!(name: 'Unterstellungserklärung')
      own = DocumentType.create!(name: 'Eigenes LV-Attest', game_operation_id: own_go.id)
      foreign = DocumentType.create!(name: 'Fremd-Attest', game_operation_id: foreign_go.id)

      login(create(:user, :sbk_scoped, game_operation_id: own_go.id))
      get "/api/v2/admin/players/#{@player.id}/document_types"

      assert_response :success
      keys = JSON.parse(response.body).map { |t| t['key'] }
      assert_includes keys, global.key
      assert_includes keys, own.key
      assert_not_includes keys, foreign.key
    end

    # Der Katalog-Abruf (Admin::DocumentTypesController#index) gibt einem VM 403 –
    # genau deshalb gibt es diesen Endpunkt.
    test 'available_types ist fuer den VM des Vereins offen und fuer fremde VM gesperrt' do
      club = create(:club)
      other_club = create(:club)
      @player.update!(clubs: [{ 'club_id' => club.id, 'home_club' => true }])
      DocumentType.create!(name: 'Unterstellungserklärung')

      login(create(:user, :vm, club_id: club.id))
      get "/api/v2/admin/players/#{@player.id}/document_types"
      assert_response :success
      assert_equal 1, JSON.parse(response.body).size

      login(create(:user, :vm, club_id: other_club.id))
      get "/api/v2/admin/players/#{@player.id}/document_types"
      assert_response :forbidden
    end

    # Rollen additiv: Wer für DIESEN Spieler VM ist, behält seine Verbandsarten
    # auch dann, wenn er zusätzlich irgendwo eine verbandsgescopte SBK-Rolle
    # hält. Vorher genügte ein solcher Eintrag, um die Dokumentart des eigenen
    # Landesverbands aus Auswahl UND Dokumentliste zu nehmen – den von seinem
    # Verband geforderten Nachweis konnte der VM dann nicht mehr hochladen.
    test 'VM mit zusaetzlicher gescopter SBK-Rolle behaelt die eigenen Verbandsarten' do
      sa = create(:state_association)
      home_go = create(:game_operation, state_association_id: sa.id)
      other_go = create(:game_operation)
      club = create(:club, game_operation: home_go)
      @player.update!(clubs: [{ 'club_id' => club.id, 'home_club' => true }])

      own = DocumentType.create!(name: 'LV-Attest', game_operation_id: home_go.id)
      doc = LicenseDocument.new(player: @player, document_type: own.key)
      doc.file.attach(io: StringIO.new('%PDF-1.4'), filename: 'a.pdf', content_type: 'application/pdf')
      doc.save!

      login(create(:user, permissions: [
        { 'user_group_id' => 4, 'game_operation_id' => 0, 'club_id' => club.id },
        { 'user_group_id' => 2, 'game_operation_id' => other_go.id }
      ]))

      get "/api/v2/admin/players/#{@player.id}/document_types"
      assert_response :success
      assert_includes JSON.parse(response.body).map { |t| t['key'] }, own.key

      get "/api/v2/admin/players/#{@player.id}/license_documents"
      assert_response :success
      assert_includes JSON.parse(response.body).map { |d| d['document_type'] }, own.key
    end

    # --- Archivierung: abgeloeste und geloeschte Nachweise bleiben belegbar ---

    # Der Kern des Umbaus: Bis hierher loeschte ein neuer Upload die bisherige
    # Fassung samt Datei. Damit verschwand die Grundlage jeder Lizenz, die auf
    # ihr erteilt worden war -- created_at und uploaded_by galten immer nur fuer
    # die juengste Fassung.
    test 'abgeloeste Fassung bleibt mit Anhang, Grund und Konto erhalten' do
      old_doc = attach_document('use')
      handelnder = create(:user, :admin)
      login(handelnder)

      post "/api/v2/admin/players/#{@player.id}/license_documents",
           params: { document_type: 'use', file: fixture_file_upload('dokument.pdf', 'application/pdf') }
      assert_response :created

      old_doc.reload
      assert old_doc.archived?, 'die abgeloeste Fassung muss erhalten bleiben'
      assert_equal 'replaced', old_doc.archived_reason
      assert_equal handelnder.id, old_doc.archived_by_id
      assert old_doc.file.attached?, 'der Anhang darf nicht gepurged sein'
      assert_equal 1, @player.license_documents.active.count
    end

    test 'Index zeigt archivierte Fassungen nur auf Anforderung' do
      alt = attach_document('use')
      alt.archive!(reason: 'replaced')
      aktuell = attach_document('use')

      get "/api/v2/admin/players/#{@player.id}/license_documents"
      assert_response :success
      ids = JSON.parse(response.body).map { |d| d['id'] }
      assert_equal [aktuell.id], ids

      get "/api/v2/admin/players/#{@player.id}/license_documents", params: { include_archived: true }
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal [alt.id, aktuell.id].sort, body.map { |d| d['id'] }.sort
      archiviert = body.find { |d| d['id'] == alt.id }
      assert archiviert['archived_at'].present?
      assert_equal 'replaced', archiviert['archived_reason']
      assert_nil body.find { |d| d['id'] == aktuell.id }['archived_at']
    end

    test 'Loeschen eines Pflichtdokuments mit erteilter Lizenz archiviert, statt zu vernichten' do
      doc = required_document_with_approved_license
      login(create(:user, :vm, club_id: @doc_club.id))

      delete "/api/v2/admin/players/#{@player.id}/license_documents/#{doc.id}"

      assert_response :success
      assert JSON.parse(response.body)['archived']
      doc.reload
      assert_equal 'deleted', doc.archived_reason
      assert doc.file.attached?, 'der Nachweis muss abrufbar bleiben'

      # Aus dem aktuellen Bestand ist er trotzdem verschwunden.
      get "/api/v2/admin/players/#{@player.id}/license_documents"
      assert_empty JSON.parse(response.body)
    end

    test 'Loeschen ohne Lizenz, die darauf beruht, vernichtet weiterhin' do
      club = create(:club)
      team = create(:team, club: club, league: create(:league, required_documents: ['use']))
      @player.update!(clubs: [{ 'club_id' => club.id, 'home_club' => true }],
                      licenses: licenses_for(team))
      # Freiwilliger Upload: keine Liga verlangt diese Art.
      doc = attach_document('freiwillig')
      login(create(:user, :vm, club_id: club.id))

      delete "/api/v2/admin/players/#{@player.id}/license_documents/#{doc.id}"

      assert_response :success
      assert_not LicenseDocument.exists?(doc.id)
    end

    # Nur die ERTEILUNG bindet. Solange die Lizenz nur beantragt ist, hat der
    # Verband auf dieser Unterlage noch nichts entschieden.
    test 'beantragte Lizenz allein haelt das Dokument nicht' do
      club = create(:club)
      team = create(:team, club: club, league: create(:league, required_documents: ['use']))
      @player.update!(clubs: [{ 'club_id' => club.id, 'home_club' => true }],
                      licenses: build(:player, with_licenses: [{ team: team, status: License::REQUESTED }]).licenses)
      doc = attach_document('use')
      login(create(:user, :vm, club_id: club.id))

      delete "/api/v2/admin/players/#{@player.id}/license_documents/#{doc.id}"

      assert_response :success
      assert_not LicenseDocument.exists?(doc.id)
    end

    # Sonst liesse sich der Nachweis in zwei Schritten beseitigen: erst
    # ersetzen, dann die archivierte Fassung loeschen.
    test 'VM darf eine archivierte Fassung nicht loeschen' do
      doc = required_document_with_approved_license
      doc.archive!(reason: 'replaced')
      login(create(:user, :vm, club_id: @doc_club.id))

      delete "/api/v2/admin/players/#{@player.id}/license_documents/#{doc.id}"

      assert_response :forbidden
      assert LicenseDocument.exists?(doc.id)
    end

    # Der eine Weg, auf dem die Grundlage einer Erteilung doch verschwindet.
    # Er bleibt offen (Loeschverlangen nach Datenschutzrecht), aber nicht
    # geraeuschlos.
    test 'Admin loescht auch ein Dokument mit erteilter Lizenz endgueltig, hinterlaesst aber eine Spur' do
      doc = required_document_with_approved_license

      log = capture_rails_log do
        delete "/api/v2/admin/players/#{@player.id}/license_documents/#{doc.id}"
      end

      assert_response :success
      assert_not LicenseDocument.exists?(doc.id)
      assert_match(/endgueltig geloescht/, log)
      assert_match(/##{doc.id}/, log)
    end

    test 'ein Dokument ohne erteilte Lizenz wird ohne Aufhebens geloescht' do
      doc = attach_document('freiwillig')

      log = capture_rails_log do
        delete "/api/v2/admin/players/#{@player.id}/license_documents/#{doc.id}"
      end

      assert_response :success
      assert_no_match(/endgueltig geloescht/, log)
    end

    # per_season-Arten gelten je Saison. Eine Fassung aus einer anderen Saison
    # war nie die Grundlage dieser Lizenz.
    test 'per_season: Fassung aus einer anderen Saison als die Lizenz bleibt loeschbar' do
      DocumentType.create!(name: 'Attest', key: 'attest', validity: 'per_season')
      club = create(:club)
      team = create(:team, club: club,
                           league: create(:league, season_id: '18', required_documents: ['attest']))
      @player.update!(clubs: [{ 'club_id' => club.id, 'home_club' => true }],
                      licenses: licenses_for(team))
      alt = attach_document('attest')
      alt.update_columns(season_id: 17)
      login(create(:user, :vm, club_id: club.id))

      delete "/api/v2/admin/players/#{@player.id}/license_documents/#{alt.id}"

      assert_response :success
      assert_not LicenseDocument.exists?(alt.id)
    end

    test 'per_season: Fassung aus der Saison der Lizenz wird archiviert' do
      DocumentType.create!(name: 'Attest', key: 'attest', validity: 'per_season')
      club = create(:club)
      team = create(:team, club: club,
                           league: create(:league, season_id: '18', required_documents: ['attest']))
      @player.update!(clubs: [{ 'club_id' => club.id, 'home_club' => true }],
                      licenses: licenses_for(team))
      doc = attach_document('attest')
      doc.update_columns(season_id: 18)
      login(create(:user, :vm, club_id: club.id))

      delete "/api/v2/admin/players/#{@player.id}/license_documents/#{doc.id}"

      assert_response :success
      assert_equal 'deleted', doc.reload.archived_reason
    end

    # Ein Datensatz ohne Anhang (verlorener Blob) verschwand vor der
    # Archivierung mit dem naechsten Upload. Jetzt ueberdauert er ihn -- und
    # `rails_blob_url(nil)` haette die Archivansicht dauerhaft mit einem
    # Serverfehler beendet.
    test 'archivierte Fassung ohne Anhang bricht die Archivansicht nicht' do
      alt = attach_document('use')
      alt.file.purge

      post "/api/v2/admin/players/#{@player.id}/license_documents",
           params: { document_type: 'use', file: fixture_file_upload('dokument.pdf', 'application/pdf') }
      assert_response :created

      get "/api/v2/admin/players/#{@player.id}/license_documents", params: { include_archived: true }
      assert_response :success
      ohne_datei = JSON.parse(response.body).find { |d| d['id'] == alt.id }
      assert ohne_datei, 'die archivierte Fassung muss gelistet bleiben'
      assert_nil ohne_datei['url']
      assert_nil ohne_datei['filename']
    end

    test 'Abruf einer Fassung ohne Anhang meldet, statt zu werfen' do
      doc = attach_document('use')
      doc.file.purge

      get "/api/v2/admin/players/#{@player.id}/license_documents/#{doc.id}"

      assert_response :not_found
    end

    # --- Archivierte Nachweise gehoeren dem Verband, nicht dem Verein ---

    test 'VM sieht archivierte Fassungen auch mit include_archived nicht' do
      doc = required_document_with_approved_license
      doc.archive!(reason: 'deleted')
      login(create(:user, :vm, club_id: @doc_club.id))

      get "/api/v2/admin/players/#{@player.id}/license_documents", params: { include_archived: true }

      assert_response :success
      assert_empty JSON.parse(response.body)
    end

    test 'VM kommt auch nicht ueber den Einzelabruf an eine archivierte Fassung' do
      doc = required_document_with_approved_license
      doc.archive!(reason: 'deleted')
      login(create(:user, :vm, club_id: @doc_club.id))

      get "/api/v2/admin/players/#{@player.id}/license_documents/#{doc.id}"

      assert_response :forbidden
    end

    test 'gescopte SBK sieht auch mit include_archived kein fremdes Verbandsdokument' do
      foreign, doc = foreign_document_for_scoped_sbk
      doc.archive!(reason: 'replaced')

      get "/api/v2/admin/players/#{@player.id}/license_documents", params: { include_archived: true }

      assert_response :success
      assert_not_includes JSON.parse(response.body).map { |d| d['document_type'] }, foreign.key
    end

    # --- Was als Grundlage einer Erteilung zaehlt ---

    # Der Verein kann eine erteilte Lizenz ueber reenable_license_request ohne
    # Statusvorbedingung wieder auf "beantragt" setzen. Zaehlte nur der aktuelle
    # Status, waere der Nachweis danach in einem zweiten Aufruf endgueltig weg.
    test 'einmal erteilt bleibt geschuetzt, auch wenn der Status zurueckgesetzt wurde' do
      club = create(:club)
      team = create(:team, club: club, league: create(:league, required_documents: ['use']))
      lizenz = build(:player, with_licenses: [{ team: team }]).licenses.first
      lizenz['history'] << { 'license_status_id' => License::REQUESTED,
                             'created_at' => Time.current.iso8601 }
      @player.update!(clubs: [{ 'club_id' => club.id, 'home_club' => true }], licenses: [lizenz])
      doc = attach_document('use')
      login(create(:user, :vm, club_id: club.id))

      delete "/api/v2/admin/players/#{@player.id}/license_documents/#{doc.id}"

      assert_response :success
      assert LicenseDocument.exists?(doc.id), 'der Nachweis darf nicht vernichtet werden'
      assert_equal 'deleted', doc.reload.archived_reason
    end

    # Die Spalte season_id kam erst im Juli 2026 dazu und wurde nicht
    # rueckwirkend gefuellt. Fuer diese Zeilen ist die Saison unbekannt und
    # nicht "eine andere" -- sie tragen gerade den Altbestand erteilter Lizenzen.
    test 'per_season: Fassung ohne Saison gilt im Zweifel als Grundlage' do
      DocumentType.create!(name: 'Attest', key: 'attest', validity: 'per_season')
      club = create(:club)
      team = create(:team, club: club,
                           league: create(:league, season_id: '18', required_documents: ['attest']))
      @player.update!(clubs: [{ 'club_id' => club.id, 'home_club' => true }],
                      licenses: licenses_for(team))
      alt = attach_document('attest')
      alt.update_columns(season_id: nil)
      login(create(:user, :vm, club_id: club.id))

      delete "/api/v2/admin/players/#{@player.id}/license_documents/#{alt.id}"

      assert_response :success
      assert_equal 'deleted', alt.reload.archived_reason
    end

    # Laesst sich die Grundlage nicht mehr ermitteln, wird aufbewahrt statt
    # vernichtet -- ein Datenfehler darf keinen Nachweis kosten.
    test 'erteilte Lizenz ohne auflösbare Mannschaft schuetzt die Unterlagen' do
      club = create(:club)
      team = create(:team, club: club, league: create(:league, required_documents: ['use']))
      lizenzen = licenses_for(team)
      @player.update!(clubs: [{ 'club_id' => club.id, 'home_club' => true }], licenses: lizenzen)
      doc = attach_document('freiwillig')
      login(create(:user, :vm, club_id: club.id))
      team.destroy!

      delete "/api/v2/admin/players/#{@player.id}/license_documents/#{doc.id}"

      assert_response :success
      assert_equal 'deleted', doc.reload.archived_reason
    end

    test 'TM loescht ein Pflichtdokument mit erteilter Lizenz nicht endgueltig' do
      doc = required_document_with_approved_license
      team = Team.find(@player.licenses.first['team_id'])
      login(create(:user, :tm, team_id: team.id))

      delete "/api/v2/admin/players/#{@player.id}/license_documents/#{doc.id}"

      assert_response :success
      assert_equal 'deleted', doc.reload.archived_reason
    end

    test 'gescopte SBK loescht ein Pflichtdokument mit erteilter Lizenz nicht endgueltig' do
      go = create(:game_operation, state_association_id: create(:state_association).id)
      club = create(:club, game_operation: go)
      team = create(:team, club: club,
                           league: create(:league, game_operation: go, required_documents: ['use']))
      @player.update!(clubs: [{ 'club_id' => club.id, 'home_club' => true }],
                      licenses: licenses_for(team))
      doc = attach_document('use')
      login(create(:user, :sbk_scoped, game_operation_id: go.id))

      delete "/api/v2/admin/players/#{@player.id}/license_documents/#{doc.id}"

      assert_response :success
      assert_equal 'deleted', doc.reload.archived_reason
    end

    # --- Schreibseite: derselbe Verbands-Scope wie beim Lesen ---

    test 'gescopte SBK darf ein fremdes Verbandsdokument nicht loeschen' do
      foreign, doc = foreign_document_for_scoped_sbk

      delete "/api/v2/admin/players/#{@player.id}/license_documents/#{doc.id}"

      assert_response :forbidden
      assert LicenseDocument.exists?(doc.id), 'Das fremde Dokument muss erhalten bleiben'
      assert doc.reload.file.attached?, 'Die Datei darf nicht gepurged sein'
      assert_equal foreign.key, doc.document_type
    end

    test 'gescopte SBK darf ein eigenes Verbandsdokument weiterhin loeschen' do
      _foreign, _doc = foreign_document_for_scoped_sbk
      own = DocumentType.create!(name: 'Eigenes LV-Attest', game_operation_id: @own_go.id)
      own_doc = LicenseDocument.new(player: @player, document_type: own.key)
      own_doc.file.attach(io: StringIO.new('%PDF-1.4'), filename: 'o.pdf', content_type: 'application/pdf')
      own_doc.save!

      delete "/api/v2/admin/players/#{@player.id}/license_documents/#{own_doc.id}"

      assert_response :success
      assert_not LicenseDocument.exists?(own_doc.id)
    end

    test 'gescopte SBK kann nicht in eine fremde Verbandsart hochladen' do
      foreign, _doc = foreign_document_for_scoped_sbk

      post "/api/v2/admin/players/#{@player.id}/license_documents",
           params: { document_type: foreign.key, file: fixture_file_upload('dokument.pdf', 'application/pdf') }

      assert_response :forbidden
      assert_equal 1, @player.license_documents.where(document_type: foreign.key).count,
                   'Der abgewiesene Upload darf den Bestand nicht verändern'
    end

    test 'gescopte SBK kann in globale und eigene Verbandsarten hochladen' do
      foreign_document_for_scoped_sbk
      global = DocumentType.create!(name: 'Unterstellungserklärung')
      own = DocumentType.create!(name: 'Eigenes LV-Attest', game_operation_id: @own_go.id)

      [global, own].each do |dt|
        post "/api/v2/admin/players/#{@player.id}/license_documents",
             params: { document_type: dt.key, file: fixture_file_upload('dokument.pdf', 'application/pdf') }
        assert_response :created, "Upload in #{dt.name} muss erlaubt bleiben"
      end
    end

    # Der Umweg, der die Scope-Prüfung UND die Ersetzungs-Abfrage zugleich
    # aushebelte: document_type als Array statt als Zeichenkette.
    # `find_by(key: [...])` ist ein `WHERE key IN (...) LIMIT 1` ohne ORDER BY
    # und liefert irgendeinen Treffer der Liste; trifft es die globale Art
    # (game_operation_id nil), winkt die Scope-Prüfung durch. Anschließend
    # löscht `where(document_type: [...])` die Dokumente ALLER genannten Arten,
    # auch die des fremden Verbands, den der Aufrufer nicht einmal sehen darf.
    #
    # Die globale Art wird hier ZUERST angelegt, damit der Fall deterministisch
    # den durchwinkenden Zweig trifft. Bei umgekehrter Reihenfolge endete der
    # Aufruf zufällig in einem 403, und der Test hätte den Weg nicht belegt.
    test 'ein Array als Dokumentart hebelt weder Scope noch Ersetzung aus' do
      global = DocumentType.create!(name: 'Unterstellungserklärung')
      foreign, foreign_doc = foreign_document_for_scoped_sbk
      global_doc = LicenseDocument.new(player: @player, document_type: global.key)
      global_doc.file.attach(io: StringIO.new('%PDF-1.4'), filename: 'g.pdf', content_type: 'application/pdf')
      global_doc.save!

      post "/api/v2/admin/players/#{@player.id}/license_documents",
           params: { document_type: [global.key, foreign.key],
                     file: fixture_file_upload('dokument.pdf', 'application/pdf') }

      assert_response :unprocessable_entity
      assert LicenseDocument.exists?(foreign_doc.id), 'das fremde Verbandsdokument muss erhalten bleiben'
      assert LicenseDocument.exists?(global_doc.id), 'das globale Dokument muss erhalten bleiben'
      assert_equal [foreign.key, global.key].sort,
                   @player.license_documents.pluck(:document_type).sort,
                   'es darf keine Zeile mit dem Array als Text entstehen'
    end

    test 'ein verschachtelter Parameter als Dokumentart wird abgewiesen' do
      foreign_document_for_scoped_sbk

      post "/api/v2/admin/players/#{@player.id}/license_documents",
           params: { document_type: { key: 'use' },
                     file: fixture_file_upload('dokument.pdf', 'application/pdf') }

      assert_response :unprocessable_entity
    end

    # --- Gültigkeit und Saison: alte Lizenzen halten die Tür nicht auf ---

    # Der Kern von #397: Eine Lizenz aus der laufenden Saison genügte dem VM
    # dauerhaft, auch nachdem die Vereinszugehörigkeit des Spielers geendet hatte.
    # Am Spielerprofil war derselbe VM längst 403, die persönlichen Unterlagen
    # standen ihm weiter offen – lesend und löschend.
    test 'VM ohne laufende Mitgliedschaft kommt nicht mehr an die Unterlagen' do
      club = create(:club)
      team = create(:team, club: club)
      @player.update!(clubs: [{ 'club_id' => club.id, 'home_club' => true,
                                'valid_until' => 2.years.ago.iso8601 }],
                      licenses: licenses_for(team))
      doc = attach_document('use')

      login(create(:user, :vm, club_id: club.id))

      get "/api/v2/admin/players/#{@player.id}/license_documents"
      assert_response :forbidden

      get "/api/v2/admin/players/#{@player.id}/document_types"
      assert_response :forbidden

      delete "/api/v2/admin/players/#{@player.id}/license_documents/#{doc.id}"
      assert_response :forbidden
      assert LicenseDocument.exists?(doc.id), 'Das Dokument muss erhalten bleiben'

      post "/api/v2/admin/players/#{@player.id}/license_documents",
           params: { document_type: 'use', file: fixture_file_upload('dokument.pdf', 'application/pdf') }
      assert_response :forbidden
    end

    test 'VM mit laufender Mitgliedschaft kommt weiter an die Unterlagen' do
      club = create(:club)
      team = create(:team, club: club)
      @player.update!(clubs: [{ 'club_id' => club.id, 'home_club' => true }],
                      licenses: licenses_for(team))
      attach_document('use')

      login(create(:user, :vm, club_id: club.id))
      get "/api/v2/admin/players/#{@player.id}/license_documents"

      assert_response :success
      assert_equal 1, JSON.parse(response.body).size
    end

    # Der Grund, warum es den Lizenz-Weg überhaupt gibt: Bei SG-/Syndikats-Teams
    # gehört der Spieler dem Partnerverein, die Mannschaft dem anderen. Dessen VM
    # löst die Lizenz (players#request_license) und muss die Dokumente sehen.
    # Maßgeblich ist die Mitgliedschaft im Partnerverein.
    test 'VM eines Syndikats-Teams sieht die Unterlagen des Partnerclub-Spielers' do
      host_club = create(:club)
      partner_club = create(:club)
      team = create(:team, club: host_club, syndicate: true, syndicate_clubs: [partner_club.id])
      @player.update!(clubs: [{ 'club_id' => partner_club.id, 'home_club' => true }],
                      licenses: licenses_for(team))
      attach_document('use')

      login(create(:user, :vm, club_id: host_club.id))
      get "/api/v2/admin/players/#{@player.id}/license_documents"
      assert_response :success

      @player.update!(clubs: [{ 'club_id' => partner_club.id, 'home_club' => true,
                                'valid_until' => 1.year.ago.iso8601 }])
      get "/api/v2/admin/players/#{@player.id}/license_documents"
      assert_response :forbidden
    end

    # Für den TM zählte allein, dass eine Lizenz auf seine Mannschaft lautet.
    # Der Saisonfilter greift bei ihm schon eine Stufe früher (permission_hash
    # nimmt nur Mannschaften der laufenden Saison), die Zugehörigkeit dagegen
    # wurde nirgends geprüft: Ein weggewechselter Spieler blieb dem TM offen.
    test 'TM verliert den Zugriff mit dem Ende der Vereinszugehoerigkeit' do
      club = create(:club)
      team = create(:team, club: club)
      @player.update!(clubs: [{ 'club_id' => club.id, 'home_club' => true }],
                      licenses: licenses_for(team))
      attach_document('use')

      login(create(:user, :tm, team_id: team.id))
      get "/api/v2/admin/players/#{@player.id}/license_documents"
      assert_response :success

      @player.update!(clubs: [{ 'club_id' => club.id, 'home_club' => true,
                                'valid_until' => 1.year.ago.iso8601 }])
      get "/api/v2/admin/players/#{@player.id}/license_documents"
      assert_response :forbidden
    end

    # Der Kern von #595: Die Nachweise sind Voraussetzung für den Lizenzantrag,
    # die Rechteprüfung verlangte aber eine schon bestehende Lizenz auf genau der
    # Mannschaft des TM. Zu Saisonbeginn war damit gar kein Upload möglich –
    # obwohl der TM den Spieler in „Meine Spieler*innen" sieht (die Liste kommt
    # vereinsweit aus `Club#players`) und sein Profil öffnen darf.
    test 'TM laedt ohne bestehende Lizenz Dokumente des eigenen Vereinsspielers hoch' do
      club = create(:club)
      team = create(:team, club: club)
      @player.update!(clubs: [{ 'club_id' => club.id, 'home_club' => true }], licenses: [])
      DocumentType.create!(name: 'Anti-Doping', key: 'anti_doping')

      login(create(:user, :tm, team_id: team.id))

      get "/api/v2/admin/players/#{@player.id}/license_documents"
      assert_response :success

      get "/api/v2/admin/players/#{@player.id}/document_types"
      assert_response :success
      assert_includes JSON.parse(response.body).map { |t| t['key'] }, 'anti_doping'

      post "/api/v2/admin/players/#{@player.id}/license_documents",
           params: { document_type: 'anti_doping', file: fixture_file_upload('dokument.pdf', 'application/pdf') }
      assert_response :created
    end

    # Der zweite Alltagsfall: Der Trainer der ersten Mannschaft trägt für einen
    # Jugendspieler nach. Der steht in der Vereinsliste, seine Lizenz hängt aber
    # an einer anderen Mannschaft desselben Vereins.
    test 'TM kommt an die Unterlagen eines Vereinsspielers mit Lizenz an fremder Mannschaft' do
      club = create(:club)
      own_team = create(:team, club: club)
      other_team = create(:team, club: club)
      @player.update!(clubs: [{ 'club_id' => club.id, 'home_club' => true }],
                      licenses: licenses_for(other_team))
      attach_document('use')

      login(create(:user, :tm, team_id: own_team.id))
      get "/api/v2/admin/players/#{@player.id}/license_documents"

      assert_response :success
      assert_equal 1, JSON.parse(response.body).size
    end

    # Die Erweiterung reicht nur so weit wie das Spielerprofil selbst: Ein TM
    # eines fremden Vereins bleibt draußen, auch wenn seine Mannschaft in
    # derselben Liga spielt.
    test 'TM eines fremden Vereins kommt nicht an die Unterlagen' do
      club = create(:club)
      foreign_club = create(:club)
      league = create(:league)
      team = create(:team, club: club, league: league)
      foreign_team = create(:team, club: foreign_club, league: league)
      @player.update!(clubs: [{ 'club_id' => club.id, 'home_club' => true }],
                      licenses: licenses_for(team))
      doc = attach_document('use')

      login(create(:user, :tm, team_id: foreign_team.id))

      get "/api/v2/admin/players/#{@player.id}/license_documents"
      assert_response :forbidden

      get "/api/v2/admin/players/#{@player.id}/document_types"
      assert_response :forbidden

      delete "/api/v2/admin/players/#{@player.id}/license_documents/#{doc.id}"
      assert_response :forbidden
      assert LicenseDocument.exists?(doc.id), 'Das Dokument muss erhalten bleiben'

      post "/api/v2/admin/players/#{@player.id}/license_documents",
           params: { document_type: 'use', file: fixture_file_upload('dokument.pdf', 'application/pdf') }
      assert_response :forbidden
    end

    # Der Vereinsweg hängt an den Mannschaften der LAUFENDEN Saison
    # (`User#tm_club_ids` filtert über `Team.current_season`). Ein TM, dessen
    # Mannschaft nur in einer vergangenen Saison existiert, hat schon keine
    # `permission_hash[:tm]` mehr und darf auch über den Verein nicht hinein.
    test 'TM einer Mannschaft aus vergangener Saison kommt nicht hinein' do
      club = create(:club)
      past_team = create(:team, club: club, league: create(:league, :previous_season))
      @player.update!(clubs: [{ 'club_id' => club.id, 'home_club' => true }], licenses: [])
      attach_document('use')

      login(create(:user, :tm, team_id: past_team.id))
      get "/api/v2/admin/players/#{@player.id}/license_documents"

      assert_response :forbidden
    end

    # Die Kehrseite des Vereinswegs: Er ist zum Nachtragen da, nicht zum
    # Vernichten. Ohne eine erteilte Lizenz auf dem Dokument löscht #destroy
    # endgültig, und genau das ist der Zustand zu Saisonbeginn — der TM einer
    # anderen Mannschaft desselben Vereins bekäme sonst ein Recht, das er vor
    # dieser Änderung nicht hatte.
    test 'TM darf ueber den Vereinsweg hochladen, aber nicht loeschen' do
      club = create(:club)
      own_team = create(:team, club: club)
      other_team = create(:team, club: club)
      @player.update!(clubs: [{ 'club_id' => club.id, 'home_club' => true }],
                      licenses: licenses_for(other_team))
      doc = attach_document('use')
      DocumentType.create!(name: 'Anti-Doping', key: 'anti_doping')

      login(create(:user, :tm, team_id: own_team.id))

      post "/api/v2/admin/players/#{@player.id}/license_documents",
           params: { document_type: 'anti_doping', file: fixture_file_upload('dokument.pdf', 'application/pdf') }
      assert_response :created

      delete "/api/v2/admin/players/#{@player.id}/license_documents/#{doc.id}"
      assert_response :forbidden
      assert LicenseDocument.exists?(doc.id), 'Das Dokument muss erhalten bleiben'
    end

    # Gegenprobe: Der bisherige Weg bleibt unberührt. Liegt eine laufende Lizenz
    # an der eigenen Mannschaft, darf der TM löschen wie vorher.
    test 'TM mit laufender Lizenz an der eigenen Mannschaft darf loeschen' do
      club = create(:club)
      own_team = create(:team, club: club)
      @player.update!(clubs: [{ 'club_id' => club.id, 'home_club' => true }],
                      licenses: licenses_for(own_team))
      doc = attach_document('use')

      login(create(:user, :tm, team_id: own_team.id))

      delete "/api/v2/admin/players/#{@player.id}/license_documents/#{doc.id}"
      assert_response :success
      assert_not LicenseDocument.exists?(doc.id)
    end

    # Der Saisonfilter für sich: Der Spieler gehört dem Partnerverein weiterhin,
    # das Syndikats-Team ist aber aus einer vergangenen Saison. Die Zugehörigkeit
    # allein hielte die Tür sonst dauerhaft offen.
    test 'Lizenz einer vergangenen Saison gibt dem VM keinen Zugriff' do
      host_club = create(:club)
      partner_club = create(:club)
      past_team = create(:team, club: host_club, syndicate: true, syndicate_clubs: [partner_club.id],
                                league: create(:league, :previous_season))
      @player.update!(clubs: [{ 'club_id' => partner_club.id, 'home_club' => true }],
                      licenses: licenses_for(past_team))
      attach_document('use')

      login(create(:user, :vm, club_id: host_club.id))
      get "/api/v2/admin/players/#{@player.id}/license_documents"

      assert_response :forbidden
    end

    # `teams.league_id` ist nullable: Ein Team ohne Liga faellt aus
    # Team.current_season heraus (NULL IN (...) ist nie wahr). Der Zugriff endet
    # damit zu, das ist gewollt – aber als Datenfehler gemeldet, sonst ist die
    # Absage von einer regulaeren nicht zu unterscheiden.
    test 'Lizenz-Team ohne Liga wird gemeldet, nicht still verworfen' do
      club = create(:club)
      team = create(:team, club: club)
      team.update_columns(league_id: nil)
      # Abgelaufene Zugehoerigkeit, damit die Pruefung ueber den Lizenz-Weg laeuft
      # und nicht schon an den gueltigen Vereinen des Spielers vorbei entschieden wird.
      @player.update!(clubs: [{ 'club_id' => club.id, 'home_club' => true,
                                'valid_until' => 1.year.ago.iso8601 }],
                      licenses: licenses_for(team))
      login(create(:user, :vm, club_id: club.id))

      log = capture_rails_log do
        get "/api/v2/admin/players/#{@player.id}/license_documents"
      end

      assert_response :forbidden
      assert_match(/ohne Liga/, log, 'der Datenfehler muss im Log stehen')
    end

    # Ein unlesbares valid_until steht auf Prod im Altbestand. Es ist eine
    # Rechteentscheidung (Absage plus Meldung), kein Serverfehler – dafür rescued
    # LicenseAccessScope#membership_current?.
    test 'unlesbares valid_until endet in einer Absage, nicht in einem Serverfehler' do
      club = create(:club)
      team = create(:team, club: club)
      @player.update!(clubs: [{ 'club_id' => club.id, 'home_club' => true, 'valid_until' => 'unbekannt' }],
                      licenses: licenses_for(team))

      login(create(:user, :vm, club_id: club.id))
      get "/api/v2/admin/players/#{@player.id}/license_documents"

      assert_response :forbidden
    end

    private

    # Der Test-Cache ist ein :null_store, die Drosselung in
    # report_license_data_defect ist also nicht beobachtbar – gepruefet wird
    # deshalb, was der Helfer schreibt.
    def capture_rails_log
      buffer = StringIO.new
      original = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(buffer)
      yield
      buffer.string
    ensure
      Rails.logger = original
    end

    # Lizenz-Hashes in der Form, in der sie in Player#licenses liegen.
    def licenses_for(*teams)
      build(:player, with_licenses: teams.map { |team| { team: team } }).licenses
    end

    # Spieler mit erteilter Lizenz in einer Liga, die 'use' als Pflichtdokument
    # fuehrt, plus das dazugehoerige Dokument. Setzt @doc_club fuer den VM-Login.
    def required_document_with_approved_license
      @doc_club = create(:club)
      team = create(:team, club: @doc_club, league: create(:league, required_documents: ['use']))
      @player.update!(clubs: [{ 'club_id' => @doc_club.id, 'home_club' => true }],
                      licenses: licenses_for(team))
      attach_document('use')
    end

    def attach_document(document_type)
      doc = LicenseDocument.new(player: @player, document_type: document_type)
      doc.file.attach(io: StringIO.new('%PDF-1.4'), filename: 'd.pdf', content_type: 'application/pdf')
      doc.save!
      doc
    end

    # Spieler im Verband des gescopten SBK, dazu ein Dokument einer FREMDEN
    # Verbandsart – lesbar ist der Spieler damit (admin_or_sbk_for_player?),
    # dieses eine Dokument aber nicht (document_visible?). Loggt den SBK ein.
    def foreign_document_for_scoped_sbk
      # Zwei getrennte Landesverbaende, nicht zwei Spielbetriebe an einem: Sonst
      # entscheidet die Erzeugungsreihenfolge, welcher zustaendig ist
      # (GameOperation.id_by_state_association behaelt die niedrigere ID), und ein
      # Vertauschen der beiden Zeilen liesse den Test aus dem falschen Grund
      # gruen bleiben.
      @own_go = create(:game_operation, state_association_id: create(:state_association).id)
      foreign_go = create(:game_operation, state_association_id: create(:state_association).id)
      club = create(:club, game_operation: @own_go)
      @player.update!(clubs: [{ 'club_id' => club.id, 'home_club' => true }])

      foreign = DocumentType.create!(name: 'Fremd-Attest', game_operation_id: foreign_go.id)
      doc = LicenseDocument.new(player: @player, document_type: foreign.key)
      doc.file.attach(io: StringIO.new('%PDF-1.4'), filename: 'f.pdf', content_type: 'application/pdf')
      doc.save!

      login(create(:user, :sbk_scoped, game_operation_id: @own_go.id))
      [foreign, doc]
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
