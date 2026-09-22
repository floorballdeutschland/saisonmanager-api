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

  test 'Zuruecknehmen raeumt die Kennzeichnung ab' do
    @player.hide_public_name!(@user.id, reason: 'DSGVO 2026-09-22')
    @player.show_public_name!(@user.id)

    @player.reload
    assert_not @player.public_name_hidden?
    assert_nil @player.public_name_hidden_at
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

    assert_equal entries, PublicPlayerNames.mask_lineup(entries)
  end

  test 'die ganze Aufstellungsseite wird maskiert' do
    other = create(:player, first_name: 'Anna', last_name: 'Meier')
    @player.hide_public_name!(@user.id)
    entries = [
      { 'player_id' => @player.id, 'player_firstname' => 'Pierre', 'player_name' => 'Beispiel' },
      { 'player_id' => other.id, 'player_firstname' => 'Anna', 'player_name' => 'Meier' }
    ]

    masked = PublicPlayerNames.mask_lineup(entries)

    assert_equal [PublicPlayerNames::HIDDEN_LAST_NAME, 'Meier'], masked.pluck('player_name')
  end

  # Der Altbestand traegt die Spieler-ID im JSONB teils als Zeichenkette. Genau
  # dieser Bestand ist bei einem Loeschantrag gemeint, denn es geht um Spiele von
  # frueher. Ohne die Normalisierung in #hidden? liefe die Maskierung daran
  # vorbei, und die Testreihe bliebe trotzdem gruen.
  test 'auch eine Spieler-ID als Zeichenkette wird getroffen' do
    @player.hide_public_name!(@user.id)
    entry = { 'player_id' => @player.id.to_s, 'player_firstname' => 'Pierre', 'player_name' => 'Beispiel' }

    assert_equal PublicPlayerNames::HIDDEN_LAST_NAME,
                 PublicPlayerNames.mask_lineup_entry(entry)['player_name']
  end

  # Mit dem Null-Store der Testumgebung laeuft der Block jedes Mal neu, das
  # Leeren waere also nicht pruefbar. Bleibt es aus, steht der Klarname bis zum
  # Ablauf von CACHE_TTL weiter an JEDER oeffentlichen Stelle.
  test 'das Umschalten leert den Satz der anonymisierten IDs' do
    with_real_cache do
      assert_empty PublicPlayerNames.hidden_ids

      @player.hide_public_name!(@user.id)
      Current.public_name_hidden_ids = nil

      assert_includes PublicPlayerNames.hidden_ids, @player.id
    end
  end

  test 'die Ruecknahme laesst den Vermerk als Beleg stehen' do
    @player.hide_public_name!(@user.id, reason: 'DSGVO 2026-09-22')
    @player.show_public_name!(@user.id)

    @player.reload
    assert_not @player.public_name_hidden?
    # Nach Art. 5 Abs. 2 DSGVO muss belegbar bleiben, dass und warum einmal
    # anonymisiert wurde. Sichtbar ist der Vermerk nur am anonymisierten Profil.
    assert_equal 'DSGVO 2026-09-22', @player.public_name_hidden_reason
    assert_equal @user.id, @player.public_name_hidden_by
  end
end
