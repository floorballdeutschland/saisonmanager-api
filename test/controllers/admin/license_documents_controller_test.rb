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

    test 'neuer Upload ersetzt alle vorhandenen Dokumente derselben Art (auch Lizenz-Altbestand)' do
      old_doc = LicenseDocument.new(player: @player, license_id: 'alte-lizenz-uuid', document_type: 'use')
      old_doc.file.attach(io: StringIO.new('%PDF-1.4 alt'), filename: 'alt.pdf', content_type: 'application/pdf')
      old_doc.save!

      post "/api/v2/admin/players/#{@player.id}/license_documents",
           params: { document_type: 'use', file: fixture_file_upload('dokument.pdf', 'application/pdf') }

      assert_response :created
      docs = @player.license_documents.where(document_type: 'use')
      assert_equal 1, docs.count
      assert_not_equal old_doc.id, docs.sole.id
    end

    test 'erneuter Upload ersetzt auch ein spielerbezogenes Dokument ohne license_id' do
      2.times do
        post "/api/v2/admin/players/#{@player.id}/license_documents",
             params: { document_type: 'use', file: fixture_file_upload('dokument.pdf', 'application/pdf') }
        assert_response :created
      end

      assert_equal 1, @player.license_documents.where(document_type: 'use').count
    end

    test 'ungültiger Upload lässt das bestehende Dokument unangetastet' do
      existing = LicenseDocument.new(player: @player, document_type: 'use')
      existing.file.attach(io: StringIO.new('%PDF-1.4'), filename: 'alt.pdf', content_type: 'application/pdf')
      existing.save!

      post "/api/v2/admin/players/#{@player.id}/license_documents",
           params: { document_type: 'use', file: fixture_file_upload('notiz.txt', 'text/plain') }

      assert_response :unprocessable_entity
      assert LicenseDocument.exists?(existing.id), 'Rollback muss das alte Dokument erhalten'
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
      sa = create(:state_association)
      own_go = create(:game_operation, state_association_id: sa.id)
      foreign_go = create(:game_operation, state_association_id: sa.id)
      # Der Spieler muss dem Verband des SBK zugeordnet sein, damit die
      # Lese-Berechtigung greift (admin_or_sbk_for_player?).
      club = create(:club, game_operations_hash: [{ 'home_game_operation' => true, 'game_operation_id' => own_go.id }])
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
      sa = create(:state_association)
      own_go = create(:game_operation, state_association_id: sa.id)
      foreign_go = create(:game_operation, state_association_id: sa.id)
      club = create(:club, game_operations_hash: [{ 'home_game_operation' => true, 'game_operation_id' => own_go.id }])
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

    test 'available_types liefert globale Arten und die des Heimat-Spielbetriebs' do
      sa = create(:state_association)
      own_go = create(:game_operation, state_association_id: sa.id)
      foreign_go = create(:game_operation, state_association_id: sa.id)
      club = create(:club, game_operations_hash: [{ 'home_game_operation' => true, 'game_operation_id' => own_go.id }])
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
      past_go = create(:game_operation, state_association_id: sa.id)
      home_club = create(:club, game_operations_hash: [{ 'home_game_operation' => true,
                                                         'game_operation_id' => home_go.id }])
      past_club = create(:club, game_operations_hash: [{ 'home_game_operation' => true,
                                                         'game_operation_id' => past_go.id }])
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

    # Der Spieler gehoert zwei Vereinen in verschiedenen Verbaenden. Der gescopte
    # SBK darf ihn lesen (eigener Verband), bekommt die Dokumente des fremden
    # Verbands aber nicht zu sehen – dann darf die Art auch nicht in der Auswahl
    # stehen, sonst laedt er in ein Loch hoch.
    test 'available_types haelt fremde Verbandsarten vom gescopten SBK fern' do
      sa = create(:state_association)
      own_go = create(:game_operation, state_association_id: sa.id)
      foreign_go = create(:game_operation, state_association_id: sa.id)
      own_club = create(:club, game_operations_hash: [{ 'home_game_operation' => true,
                                                       'game_operation_id' => own_go.id }])
      foreign_club = create(:club, game_operations_hash: [{ 'home_game_operation' => true,
                                                            'game_operation_id' => foreign_go.id }])
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
      other_go = create(:game_operation, state_association_id: sa.id)
      club = create(:club, game_operations_hash: [{ 'home_game_operation' => true,
                                                    'game_operation_id' => home_go.id }])
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

    private

    # Spieler im Verband des gescopten SBK, dazu ein Dokument einer FREMDEN
    # Verbandsart – lesbar ist der Spieler damit (admin_or_sbk_for_player?),
    # dieses eine Dokument aber nicht (document_visible?). Loggt den SBK ein.
    def foreign_document_for_scoped_sbk
      sa = create(:state_association)
      @own_go = create(:game_operation, state_association_id: sa.id)
      foreign_go = create(:game_operation, state_association_id: sa.id)
      club = create(:club, game_operations_hash: [{ 'home_game_operation' => true,
                                                    'game_operation_id' => @own_go.id }])
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
