require 'test_helper'

class ArenaTest < ActiveSupport::TestCase
  # Der Protokolleintrag steht in derselben Transaktion wie der Merge. Scheitert
  # der Merge, darf kein Eintrag für eine Zusammenlegung zurückbleiben, die nie
  # stattgefunden hat.
  test 'merge_into! hinterlässt bei fehlgeschlagenem destroy! weder MergeLog noch umgehängte Spieltage' do
    master = create(:arena)
    secondary = create(:arena)
    game_day = create(:game_day, arena: secondary)

    secondary.stub(:destroy!, -> { raise ActiveRecord::RecordNotDestroyed, 'boom' }) do
      assert_no_difference -> { MergeLog.count } do
        assert_raises(ActiveRecord::RecordNotDestroyed) { secondary.merge_into!(master) }
      end
    end

    assert_equal secondary.id, game_day.reload.arena_id
    assert Arena.exists?(secondary.id)
  end

  # Altdatensätze führen die Adresse nur in der Spalte `address`. Gerade sie
  # werden zusammengelegt, und ohne Adresse wären gleichnamige Hallen im
  # Protokoll nicht zu unterscheiden.
  test 'merge_label nimmt bei Altdatensätzen die Spalte address' do
    arena = create(:arena, name: 'Sporthalle Nord')
    arena.update_columns(city: nil, street: nil, housenumber: nil, postcode: nil,
                         address: 'Nordring 5, 12345 Musterstadt')

    assert_equal 'Sporthalle Nord (Nordring 5, 12345 Musterstadt)', arena.merge_label
  end

  test 'merge_label ohne jede Adressangabe ist nur der Name' do
    arena = create(:arena, name: 'Halle X')
    arena.update_columns(city: nil, street: '', housenumber: nil, postcode: nil, address: nil)

    assert_equal 'Halle X', arena.merge_label
  end

  test 'merge_label nur mit Ort setzt kein führendes Komma' do
    assert_equal 'Halle Y (Hamburg)', build(:arena, name: 'Halle Y', city: 'Hamburg').merge_label
  end
end
