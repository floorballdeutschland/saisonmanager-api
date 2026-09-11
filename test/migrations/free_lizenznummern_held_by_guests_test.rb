require 'test_helper'
require Rails.root.join('db/migrate/20260909130000_free_lizenznummern_held_by_guests')

# Daten-Migration: Gäste geben ihre Lizenznummer frei, damit die automatische
# Vergabe sie wieder ausgeben kann. Getestet, weil `up` sonst im gesamten
# Testlauf kein einziges Mal ausgeführt würde — die Test-Datenbank kommt aus
# `db/schema.rb`. Und weil die Migration destruktiv arbeitet (`update_all`,
# `update_columns` am Spielplan-Text), also genau die Zeilen, die beim Deploy
# unbeaufsichtigt laufen.
class FreeLizenznummernHeldByGuestsTest < ActiveSupport::TestCase
  def run_migration
    ActiveRecord::Migration.suppress_messages { FreeLizenznummernHeldByGuests.new.up }
  end

  def spiel(text)
    create(:game, nominated_referee_string: text)
  end

  setup do
    # Bestand aus den Fixtures raus: Die Migration arbeitet über die ganze
    # Tabelle, ein fremder Gast mit Nummer würde die Erwartungen verschieben.
    Referee.where(guest: true).update_all(lizenznummer: nil)
  end

  test 'gibt die Nummer eines Gasts frei und lässt Nicht-Gäste in Ruhe' do
    gast = create(:referee, guest: true, lizenznummer: 8_725)
    echt = create(:referee, lizenznummer: 8_724)

    run_migration

    assert_nil gast.reload.lizenznummer
    assert_equal 8_724, echt.reload.lizenznummer
  end

  test 'nimmt im Spielplan-Text nur den Teil des Gasts' do
    create(:referee, guest: true, lizenznummer: 8_725)
    game = spiel('8726 Jarysz, Mateusz / 8725 Serocki, Kamil')

    run_migration

    # Der zweite Schiedsrichter ist kein Gast: seine Nummer bleibt stehen,
    # und das Trennzeichen darf die Zeile nicht verlieren.
    assert_equal '8726 Jarysz, Mateusz / Serocki, Kamil', game.reload.nominated_referee_string
  end

  test 'fasst Nummern nicht an, die nur zufällig als Präfix vorkommen' do
    create(:referee, guest: true, lizenznummer: 8_725)
    laenger  = spiel('87251 Meier, Hans')
    davor    = spiel('18725 Meier, Hans')

    run_migration

    assert_equal '87251 Meier, Hans', laenger.reload.nominated_referee_string
    assert_equal '18725 Meier, Hans', davor.reload.nominated_referee_string
  end

  test 'lässt Freitext stehen, in dem die Nummer nicht vorne steht' do
    create(:referee, guest: true, lizenznummer: 8_725)
    freitext = spiel('Gespann: 8725 Meier, Hans')

    run_migration

    assert_equal 'Gespann: 8725 Meier, Hans', freitext.reload.nominated_referee_string
  end

  # Der Kern des Riegels: Eine freigegebene Nummer wird sofort wieder
  # vergeben. Hängt an ihr noch eine Spielreferenz, erbte der nächste Inhaber
  # die Spiele des Gasts — bis in die Abrechnung.
  test 'behält die Nummer, solange sie in einem Spielbericht steht' do
    gast = create(:referee, guest: true, lizenznummer: 8_725)
    create(:game, referee1_string: '8725 Serocki, Kamil')

    run_migration

    assert_equal 8_725, gast.reload.lizenznummer
  end

  test 'behält die Nummer, solange sie in referee_ids steht' do
    gast = create(:referee, guest: true, lizenznummer: 8_725)
    create(:game, referee_ids: [8_725])

    run_migration

    assert_equal 8_725, gast.reload.lizenznummer
  end

  test 'behält die Nummer, solange sie als Gespannpartner eingetragen ist' do
    gast = create(:referee, guest: true, lizenznummer: 8_725)
    create(:referee, lizenznummer: 8_100, partner_lizenznummer: 8_725)

    run_migration

    assert_equal 8_725, gast.reload.lizenznummer
  end

  test 'ein festgehaltener Gast verhindert die Freigabe der anderen nicht' do
    gehalten = create(:referee, guest: true, lizenznummer: 8_725)
    frei     = create(:referee, guest: true, lizenznummer: 8_726)
    create(:game, referee_ids: [8_725])
    game = spiel('8726 Jarysz, Mateusz')

    run_migration

    assert_equal 8_725, gehalten.reload.lizenznummer
    assert_nil frei.reload.lizenznummer
    assert_equal 'Jarysz, Mateusz', game.reload.nominated_referee_string
  end

  test 'ohne Gast mit Nummer passiert nichts' do
    game = spiel('8725 Serocki, Kamil')

    run_migration

    assert_equal '8725 Serocki, Kamil', game.reload.nominated_referee_string
  end
end
