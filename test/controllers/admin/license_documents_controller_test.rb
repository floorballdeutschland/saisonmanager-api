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

    private

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
