require 'test_helper'

# Die Spielinformationen des Ansetzers dürfen ausschließlich über bewusst
# gebaute Payloads herausgehen – niemals über eine pauschale Serialisierung des
# Spiel-Datensatzes (z. B. `render json: game` im Spielbericht).
class GameRefereeNotesTest < ActiveSupport::TestCase
  setup do
    create(:setting)
    @game = create(:game, referee_notes: 'Nur fürs Gespann')
    @referee1 = create(:referee)
    @referee2 = create(:referee)
    @coach = create(:referee)
  end

  test 'as_json enthält die Notiz und ihre Metadaten nicht' do
    json = @game.as_json

    assert_not_includes json.keys, 'referee_notes'
    assert_not_includes json.keys, 'referee_notes_updated_at'
    assert_not_includes json.keys, 'referee_notes_updated_by'
    assert_includes json.keys, 'game_number', 'reguläre Felder bleiben erhalten'
  end

  test 'as_json mit except behält die bestehende Ausnahme und ergänzt die Notiz' do
    json = @game.as_json(except: :game_number)

    assert_not_includes json.keys, 'game_number'
    assert_not_includes json.keys, 'referee_notes'
  end

  test 'as_json mit only liefert genau die angeforderten Felder' do
    assert_equal %w[id], @game.as_json(only: :id).keys
  end

  test 'Notiz ist für das veröffentlicht angesetzte Gespann und den Coach sichtbar' do
    RefereeAssignment.create!(
      game: @game, referee1: @referee1, referee2: @referee2, coach: @coach,
      status: 'published', published_at: Time.current
    )
    @game.reload

    assert @game.referee_notes_visible_to?(@referee1)
    assert @game.referee_notes_visible_to?(@referee2)
    assert @game.referee_notes_visible_to?(@coach)
    assert_not @game.referee_notes_visible_to?(create(:referee))
    assert_not @game.referee_notes_visible_to?(nil)
  end

  test 'Notiz ist vor dem Veröffentlichen für niemanden sichtbar' do
    RefereeAssignment.create!(game: @game, referee1: @referee1, referee2: @referee2, status: 'tentative')
    @game.reload

    assert_not @game.referee_notes_visible_to?(@referee1)
  end

  test 'Notiz ist ohne Ansetzung für niemanden sichtbar' do
    assert_not @game.referee_notes_visible_to?(@referee1)
  end
end
