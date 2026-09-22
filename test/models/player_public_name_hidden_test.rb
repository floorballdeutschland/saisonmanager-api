require 'test_helper'

# Der Schalter selbst: Er nimmt den Namen aus der oeffentlichen Ausgabe und
# laesst den Datensatz unangetastet. Genau das ist der Punkt der Loesung --
# ohne Name und Geburtsdatum im Bestand waere dieselbe Person jederzeit ein
# zweites Mal anlegbar.
class PlayerPublicNameHiddenTest < ActiveSupport::TestCase
  setup do
    @user = create(:user, :admin)
    @player = create(:player, first_name: 'Pierre', last_name: 'Beispiel')
  end

  test 'Anonymisieren laesst Name und Geburtsdatum im Datensatz stehen' do
    @player.hide_public_name!(@user.id, reason: 'DSGVO 2026-09-22')

    @player.reload
    assert @player.public_name_hidden?
    assert_equal 'Pierre', @player.first_name
    assert_equal 'Beispiel', @player.last_name
    assert_equal Date.parse('1990-01-01'), @player.birthdate
    assert_equal @user.id, @player.public_name_hidden_by
    assert_equal 'DSGVO 2026-09-22', @player.public_name_hidden_reason
  end

  test 'Zuruecknehmen raeumt Kennzeichnung und Vermerk ab' do
    @player.hide_public_name!(@user.id, reason: 'DSGVO 2026-09-22')
    @player.show_public_name!(@user.id)

    @player.reload
    assert_not @player.public_name_hidden?
    assert_nil @player.public_name_hidden_at
    assert_nil @player.public_name_hidden_reason
  end

  test 'ein Profil, das die heutigen Validierungen nicht erfuellt, laesst sich anonymisieren' do
    # Altbestand ohne nation_id: Ein Betroffenenantrag darf daran nicht
    # scheitern, deshalb speichert #hide_public_name! ohne Validierung.
    @player.update_column(:nation_id, nil)

    assert_nothing_raised { @player.reload.hide_public_name!(@user.id) }
    assert Player.public_name_hidden.exists?(@player.id)
  end

  test 'leerer Vermerk wird nicht als Leerzeichenkette gespeichert' do
    @player.hide_public_name!(@user.id, reason: '   ')

    assert_nil @player.reload.public_name_hidden_reason
  end

  test 'PublicPlayerNames maskiert nur die betroffene Spieler-ID' do
    other = create(:player)
    @player.hide_public_name!(@user.id)
    hidden = PublicPlayerNames.hidden_ids

    assert PublicPlayerNames.hidden?(@player.id, hidden)
    assert_not PublicPlayerNames.hidden?(other.id, hidden)
    assert_not PublicPlayerNames.hidden?(nil, hidden)
  end

  test 'ein Aufstellungseintrag wird kopiert, nicht im Bestand ueberschrieben' do
    @player.hide_public_name!(@user.id)
    entry = { 'player_id' => @player.id, 'player_firstname' => 'Pierre',
              'player_name' => 'Beispiel', 'trikot_number' => '7' }

    masked = PublicPlayerNames.mask_lineup_entry(entry)

    assert_equal PublicPlayerNames::HIDDEN_LAST_NAME, masked['player_name']
    assert_equal '', masked['player_firstname']
    assert_equal '7', masked['trikot_number']
    # Der Schnappschuss im Spielbericht bleibt, was er ist: der Nachweis
    # darueber, wer laut Bericht auf dem Feld stand.
    assert_equal 'Beispiel', entry['player_name']
  end

  test 'ohne anonymisiertes Profil kommt die Aufstellung unveraendert zurueck' do
    entries = [{ 'player_id' => @player.id, 'player_name' => 'Beispiel' }]

    assert_same entries, PublicPlayerNames.mask_lineup(entries)
  end
end
