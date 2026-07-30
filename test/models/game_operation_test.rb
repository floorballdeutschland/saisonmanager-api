require 'test_helper'

class GameOperationTest < ActiveSupport::TestCase
  # Issue #276: Einzige Logo-Quelle ist der Upload am Landesverband. Vorher fiel
  # meta_hash auf die Textspalte game_operations.logo_url zurück, für die es keine
  # Pflege-Oberfläche gab und deren Werte teils auf fremde Server zeigten.
  test 'meta_hash liefert das hochgeladene Logo des Landesverbands' do
    sa = StateAssociation.create!(name: "LV mit Logo #{SecureRandom.hex(4)}", short_name: 'MLL')
    sa.logo.attach(io: StringIO.new(png_bytes), filename: 'lv.png', content_type: 'image/png')
    go = GameOperation.create!(name: 'Spielbetrieb mit LV', short_name: 'SML',
                               path: "sml-#{SecureRandom.hex(4)}", state_association: sa)

    # Kein Vergleich mit einem festen Pfad-Präfix: ActiveStorage hängt im Test unter
    # /rails/active_storage, produktiv unter /api/storage.
    assert_equal sa.logo_url, go.meta_hash[:logo_url]
    assert go.meta_hash[:logo_url].present?
  end

  test 'meta_hash liefert ohne Upload kein Logo' do
    sa = StateAssociation.create!(name: "LV ohne Logo #{SecureRandom.hex(4)}", short_name: 'OLL')
    go = GameOperation.create!(name: 'Spielbetrieb ohne Logo', short_name: 'SOL',
                               path: "sol-#{SecureRandom.hex(4)}", state_association: sa)

    assert_nil go.meta_hash[:logo_url]
  end

  test 'meta_hash liefert ohne Landesverband kein Logo' do
    go = GameOperation.create!(name: 'Spielbetrieb ohne LV', short_name: 'SOV',
                               path: "sov-#{SecureRandom.hex(4)}")

    assert_nil go.meta_hash[:logo_url]
  end

  # logo_quad_url wurde vom Frontend nie gerendert und ist mit den Spalten entfallen.
  test 'meta_hash kennt logo_quad_url nicht mehr' do
    go = GameOperation.create!(name: 'Spielbetrieb Quad', short_name: 'SQD',
                               path: "sqd-#{SecureRandom.hex(4)}")

    assert_not_includes go.meta_hash.keys, 'logo_quad_url'
  end

  private

  # Kleinstes gültiges PNG (1x1, schwarz), damit der Test ohne Bildbibliothek auskommt.
  def png_bytes
    Base64.decode64(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=='
    )
  end
end
