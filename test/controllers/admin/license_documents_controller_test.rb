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

    private

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
