require 'test_helper'

# Aktiv ist je Spieler und Dokumentart genau eine Zeile. Archivierte Fassungen
# (abgeloest oder als Nachweis aufbewahrt) sind von dieser Regel ausgenommen --
# sonst liesse sich dieselbe Art kein zweites Mal hochladen, sobald einmal
# ersetzt wurde.
class LicenseDocumentTest < ActiveSupport::TestCase
  setup do
    @player = create(:player)
  end

  # Durchgesetzt wird das von der Validierung. Der partielle Index greift nur,
  # wenn license_id gesetzt ist: In Postgres sind NULL-Werte in einem
  # Unique-Index verschieden, und der Controller schreibt fuer spielerbezogene
  # Uploads NULL. Diese Luecke ist aelter als die Archivierung und bleibt
  # bestehen.
  test 'zwei aktive Fassungen derselben Art sind nicht erlaubt' do
    build_document.save!
    zweites = build_document

    assert_not zweites.valid?
    assert_includes zweites.errors.attribute_names, :player_id
  end

  test 'mit license_id faengt auch der Index die zweite aktive Fassung ab' do
    erstes = build_document
    erstes.license_id = 'lizenz-a'
    erstes.save!
    zweites = build_document
    zweites.license_id = 'lizenz-a'

    assert_not zweites.valid?
    assert_raises(ActiveRecord::RecordNotUnique) { zweites.save(validate: false) }
  end

  test 'nach dem Archivieren ist dieselbe Art wieder frei' do
    erstes = build_document
    erstes.save!
    erstes.archive!(reason: 'replaced')

    zweites = build_document
    assert zweites.save, zweites.errors.full_messages.join(', ')
    assert_equal 1, @player.license_documents.active.count
    assert_equal 1, @player.license_documents.archived.count
  end

  test 'mehrere archivierte Fassungen derselben Art duerfen nebeneinander stehen' do
    2.times do
      doc = build_document
      doc.save!
      doc.archive!(reason: 'replaced')
    end

    assert_equal 2, @player.license_documents.archived.count
  end

  test 'archive! haelt Zeitpunkt, Grund und Konto fest' do
    doc = build_document
    doc.save!
    user = create(:user, :admin)

    doc.archive!(reason: 'deleted', user: user)

    assert doc.reload.archived?
    assert_equal 'deleted', doc.archived_reason
    assert_equal user.id, doc.archived_by_id
    assert doc.file.attached?, 'der Anhang bleibt'
  end

  # Ohne diese Ausnahme meldete der Controller Erfolg fuer eine Archivierung,
  # die nicht stattgefunden hat.
  test 'archive! meldet sich, wenn die Zeile nicht mehr da ist' do
    doc = build_document
    doc.save!
    LicenseDocument.where(id: doc.id).delete_all

    assert_raises(ActiveRecord::RecordNotSaved) { doc.archive!(reason: 'replaced') }
  end

  test 'archive! nimmt keinen unbekannten Grund an' do
    doc = build_document
    doc.save!

    assert_raises(ArgumentError) { doc.archive!(reason: 'weggeworfen') }
    assert_not doc.reload.archived?
  end

  # Ein Datensatz ohne Anhang (verlorener Blob) muss archivierbar bleiben, sonst
  # haengt er als aktive Fassung fest und blockiert jeden neuen Upload.
  test 'archive! kommt auch ohne Anhang durch' do
    doc = build_document
    doc.save!
    doc.file.purge

    assert doc.archive!(reason: 'replaced')
    assert doc.reload.archived?
  end

  private

  def build_document
    doc = LicenseDocument.new(player: @player, document_type: 'use')
    doc.file.attach(io: StringIO.new('%PDF-1.4'), filename: 'd.pdf', content_type: 'application/pdf')
    doc
  end
end
