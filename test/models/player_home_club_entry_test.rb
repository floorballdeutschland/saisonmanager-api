require 'test_helper'

# Der Heimatverein wurde an drei Stellen verschieden ausgelegt. Player#home_club_entry
# ist jetzt die eine Quelle; diese Tests halten die drei Abweichungen fest, die es
# vorher gab. Eigene Datei, damit player_test.rb nicht ueber Metrics/ClassLength laeuft.
class PlayerHomeClubEntryTest < ActiveSupport::TestCase
  setup { create(:setting, current_season_id: '18') }

  # Der Bestand kennt 238 Profile mit zwei offenen Heimat-Eintraegen (18.08.2026).
  # home_club nahm den letzten, der Transferantrag den ersten — verschiedene Vereine.
  test 'bei zwei offenen Heimat-Eintraegen liefern home_club und home_club_entry denselben Verein' do
    alt = create(:club)
    neu = create(:club)
    player = create(:player, clubs: [
      { 'club_id' => alt.id, 'home_club' => true },
      { 'club_id' => neu.id, 'home_club' => true }
    ])

    assert_equal neu.id, player.home_club_entry['club_id']
    assert_equal neu.id, player.home_club(Date.current).id,
                 'home_club und home_club_entry duerfen nie auseinanderlaufen'
  end

  # Altdaten fuehren das Flag als String. `== true` uebersah solche Eintraege, der
  # Transferantrag scheiterte dann mit "Spieler hat keinen aktiven Heimverein".
  test 'home_club als String zaehlt als Heimatverein' do
    club = create(:club)
    player = create(:player, clubs: [{ 'club_id' => club.id, 'home_club' => 'true' }])

    assert_not_nil player.home_club_entry, 'String-Flag muss als Heimat gelten'
    assert_equal club.id, player.home_club_entry['club_id']
  end

  # `valid_until.nil?` liess eine erst kuenftig endende Heimat-Zugehoerigkeit
  # durchfallen, obwohl sie heute noch gilt.
  test 'Heimat-Zugehoerigkeit mit Ende in der Zukunft gilt heute noch' do
    club = create(:club)
    player = create(:player, clubs: [
      { 'club_id' => club.id, 'home_club' => true,
        'valid_until' => 30.days.from_now.iso8601 }
    ])

    assert_equal club.id, player.home_club_entry['club_id']
  end

  test 'abgelaufene Heimat-Zugehoerigkeit gilt nicht mehr' do
    club = create(:club)
    player = create(:player, clubs: [
      { 'club_id' => club.id, 'home_club' => true,
        'valid_until' => 30.days.ago.iso8601 }
    ])

    assert_nil player.home_club_entry
  end

  # Invariante, kein Regressionstest: Der alte Vergleich `valid_until > Time.now` war fuer
  # lesbare Daten korrekt (ActiveSupport patcht Time#<=>), diese Zusicherung galt also
  # schon vorher. Sie steht hier, weil transfer auf valid_time? umgestellt wurde und die
  # Menge der geschlossenen Eintraege dabei gleich bleiben muss.
  test 'transfer schliesst auch eine erst kuenftig endende Zugehoerigkeit' do
    alt = create(:club)
    zweit = create(:club)
    neu  = create(:club)
    user = create(:user)
    player = create(:player, clubs: [
      { 'club_id' => alt.id, 'home_club' => true },
      { 'club_id' => zweit.id, 'home_club' => false,
        'valid_until' => 30.days.from_now.iso8601 }
    ])

    player.transfer(neu.id, user.id)
    player.reload

    offen = player.clubs.select { |c| c['valid_until'].blank? }
    assert_equal [neu.id], offen.map { |c| c['club_id'] },
                 'nach dem Wechsel darf nur der neue Verein offen sein'
  end

  # DAS ist die Regression des alten Codes: `"unbekannt" > Time.now` wirft
  # ArgumentError, der Vereinswechsel brach ab.
  test 'transfer bricht an einem unlesbaren valid_until nicht ab' do
    alt  = create(:club)
    neu  = create(:club)
    user = create(:user)
    player = create(:player, clubs: [
      { 'club_id' => alt.id, 'home_club' => true, 'valid_until' => 'unbekannt' }
    ])

    assert_nothing_raised { player.transfer(neu.id, user.id) }
    player.reload
    offen = player.clubs.select { |c| c['valid_until'].blank? }
    assert_equal([neu.id], offen.map { |c| c['club_id'] })
  end
  # Der Lesepfad ist der riskantere: Vorher endete jeder Leser ueber valid_clubs an einem
  # unlesbaren Datum im 500er. Jetzt gilt der Eintrag als abgelaufen — die vorsichtige
  # Richtung, weil ein kaputtes Datum sonst eine Zustaendigkeit begruenden wuerde.
  test 'unlesbares valid_until bricht den Lesepfad nicht ab und begruendet keine Heimat' do
    club = create(:club)
    player = create(:player, clubs: [
      { 'club_id' => club.id, 'home_club' => true, 'valid_until' => 'unbekannt' }
    ])

    assert_nothing_raised do
      assert_nil player.home_club_entry, 'ein kaputtes Datum darf keine Zustaendigkeit begruenden'
      assert_nil player.home_club(Date.current)
    end
  end

  test 'strukturell kaputter clubs-Eintrag wird uebergangen statt zu werfen' do
    club = create(:club)
    player = create(:player, clubs: [nil, { 'club_id' => club.id, 'home_club' => true }])

    assert_nothing_raised { assert_equal club.id, player.home_club_entry['club_id'] }
  end
end
