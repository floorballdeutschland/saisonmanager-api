require 'test_helper'

# Vor `Player#merge_into!` wanderte ein doppelt angelegtes Profil per Transfer in einen
# Ablage-Verein ("Ablage Doppelung", "ZZ-Ablage", "zz_not in use" ...). Der Merge nahm
# diese Zugehoerigkeit auf den Master mit und machte die Ablage damit zum aktuellen Verein
# des echten Profils. Auf Produktion traf das am 26.08.2026 acht Merge-Ziele, darunter
# Spieler 4876 mit 148 Spielen und einer Lizenz in der laufenden Saison.
class PlayerMergeAblageTest < ActiveSupport::TestCase
  setup do
    create(:setting, current_season_id: '18')
    @user = create(:user)
  end

  # Bewusst `valid_until.blank?` und nicht `open_home_club_entries`: Dessen
  # Stichtagsvergleich ist tagesgenau, ein heute geschlossener Eintrag gilt dort bis
  # Mitternacht weiter. Massgeblich ist hier der gespeicherte Zustand.
  def offene_heimat(player)
    offen = Array(player.clubs).select do |c|
      ActiveModel::Type::Boolean.new.cast(c['home_club']) && c['valid_until'].blank?
    end
    offen.map { |c| c['club_id'] }
  end

  test 'Club.ablage_ids erkennt die Namensmuster des Bestands' do
    ablagen = ['Ablage Doppelung', 'ZZ-Ablage', 'zz_not in use', 'Z_TSV Ebersgöns 200 not in use',
               'Ablage', 'ZZZ neu', 'Ablage Ausland (IFF Trans)'].map { |n| create(:club, name: n) }
    echt = create(:club, name: 'UHC Elster')

    ids = Club.ablage_ids
    ablagen.each { |c| assert_includes ids, c.id, "#{c.name} muss als Ablage gelten" }
    assert_not_includes ids, echt.id
  end

  # Das Muster ist am Namensanfang verankert, weil ein Fehltreffer hier eine echte
  # Mitgliedschaft verwirft. Diese drei Namen traf das urspruengliche, weite Muster.
  test 'ein echter Verein mit Ablage-Wortteil im Namen ist keine Ablage' do
    treffer = ['Ablagerung SV', 'FC Doppelungen', 'TSV Halle not in used'].map { |n| create(:club, name: n) }

    ids = Club.ablage_ids
    treffer.each { |c| assert_not_includes ids, c.id, "#{c.name} darf keine Ablage sein" }
  end

  # Art. 21 DSGVO: In "Ablage Sperrung" liegen Personen, die nicht mehr im Saisonmanager
  # erscheinen wollen. Diese Zugehoerigkeit ist eine Entscheidung, kein Behelf.
  test 'Ablage Sperrung ist keine Ablage in diesem Sinn' do
    sperrung = create(:club, name: 'Ablage Sperrung')

    assert_not_includes Club.ablage_ids, sperrung.id
    assert_includes Club.widerspruch_ids, sperrung.id
  end

  # `Club` normalisiert den Namen nicht, ein fuehrendes oder doppeltes Leerzeichen kommt im
  # Bestand vor. Ein am Namensanfang verankertes Muster haette aus dem Widerspruchs-Verein
  # wortlos eine Ablage gemacht.
  test 'Namensvarianten der Sperrung bleiben ausgenommen' do
    varianten = [' Ablage Sperrung', 'Ablage  Sperrung', 'ZZ Ablage Sperrung',
                 'Sperrung (Art. 21 DSGVO)'].map { |n| create(:club, name: n) }

    ids = Club.ablage_ids
    varianten.each do |c|
      assert_not_includes ids, c.id, "#{c.name.inspect} darf keine Ablage sein"
      assert_includes Club.widerspruch_ids, c.id
    end
  end

  # Zweiter Riegel neben dem Namen: Wird Verein 213 umbenannt, gilt er weiter.
  test 'die Widerspruchs-Ablage haengt auch an der Vereins-ID' do
    assert_includes Club::WIDERSPRUCH_CLUB_IDS, 213
  end

  # Der Fall von Spieler 4876: Der Master hat keine offene Heimat, die Dublette liegt in der
  # Ablage. Vorher erbte der Master die Ablage und stand danach als deren Mitglied da.
  test 'die Ablage der Dublette wandert nicht auf den Master' do
    ablage = create(:club, name: 'Ablage Doppelung')
    verein = create(:club, name: 'UHC Elster')
    master = create(:player, clubs: [{ 'club_id' => verein.id, 'home_club' => true,
                                       'created_at' => 5.years.ago.iso8601,
                                       'valid_until' => 4.years.ago.iso8601 }])
    dublette = create(:player, clubs: [{ 'club_id' => ablage.id, 'home_club' => true,
                                         'created_at' => 1.year.ago.iso8601 }])

    dublette.merge_into!(master, @user.id)
    master.reload

    assert_equal [], offene_heimat(master), 'die Ablage darf nicht als Heimat auftauchen'
    assert_not_includes master.clubs.map { |c| c['club_id'] }, ablage.id
  end

  # Auch die abgeschlossene Ablage-Vergangenheit der Dublette ist kein Teil der Historie
  # der Person: Sie dokumentiert nur den Behelf.
  test 'auch eine geschlossene Ablage-Zugehoerigkeit der Dublette bleibt zurueck' do
    ablage = create(:club, name: 'ZZ-Ablage')
    verein = create(:club, name: 'SC DHfK Leipzig')
    master = create(:player, clubs: [{ 'club_id' => verein.id, 'home_club' => true }])
    dublette = create(:player, clubs: [{ 'club_id' => ablage.id, 'home_club' => true,
                                         'created_at' => 3.years.ago.iso8601,
                                         'valid_until' => 2.years.ago.iso8601 }])

    dublette.merge_into!(master, @user.id)
    master.reload

    assert_not_includes master.clubs.map { |c| c['club_id'] }, ablage.id
    assert_equal [verein.id], offene_heimat(master)
  end

  test 'der echte Verein des Masters bleibt offen, wenn die Dublette in der Ablage liegt' do
    ablage = create(:club, name: 'Ablage')
    verein = create(:club, name: 'UHC Elster')
    master = create(:player, clubs: [{ 'club_id' => verein.id, 'home_club' => true,
                                       'created_at' => 5.years.ago.iso8601 }])
    dublette = create(:player, clubs: [{ 'club_id' => ablage.id, 'home_club' => true,
                                         'created_at' => 1.year.ago.iso8601 }])

    dublette.merge_into!(master, @user.id)
    master.reload

    assert_equal [verein.id], offene_heimat(master)
  end

  # Die Gegenrichtung: Die Ablage steht am Master und ist der juengere Eintrag. Die Regel
  # "der zuletzt begonnene bleibt" haette sie gewinnen lassen und den echten Verein der
  # Dublette geschlossen -- der Mechanismus, der seit api#481 scharf ist.
  test 'eine Ablage am Master verliert gegen den echten Verein der Dublette' do
    ablage = create(:club, name: 'Ablage Doppelung')
    verein = create(:club, name: 'UHC Elster')
    master = create(:player, clubs: [{ 'club_id' => ablage.id, 'home_club' => true,
                                       'created_at' => 1.year.ago.iso8601 }])
    dublette = create(:player, clubs: [{ 'club_id' => verein.id, 'home_club' => true,
                                         'created_at' => 5.years.ago.iso8601 }])

    dublette.merge_into!(master, @user.id)
    master.reload

    assert_equal [verein.id], offene_heimat(master)
    zu = master.clubs.find { |c| c['club_id'] == ablage.id }
    assert_not_nil zu['valid_until'], 'die Ablage muss geschlossen werden'
    assert_equal @user.id, zu['valid_set_by']
  end

  # Die Sperrung wird uebernommen und nicht wie eine Ablage verworfen.
  test 'die Sperrung der Dublette wandert auf den Master' do
    sperrung = create(:club, name: 'Ablage Sperrung')
    verein = create(:club, name: 'UHC Elster')
    master = create(:player, clubs: [{ 'club_id' => verein.id, 'home_club' => true,
                                       'created_at' => 5.years.ago.iso8601 }])
    dublette = create(:player, clubs: [{ 'club_id' => sperrung.id, 'home_club' => true,
                                         'created_at' => 1.year.ago.iso8601 }])

    dublette.merge_into!(master, @user.id)
    master.reload

    assert_includes master.clubs.map { |c| c['club_id'] }, sperrung.id
    assert_equal [sperrung.id], offene_heimat(master)
  end

  # Der Fall, den die Datumsregel allein falsch entscheidet: Die Sperrung ist der AELTERE
  # Eintrag. Ein nach dem Widerspruch neu angelegtes Zweitprofil traegt den juengeren, das
  # ist der wahrscheinlichere Fall. Vorher stand die Person danach als offenes Mitglied
  # eines echten Vereins in dessen Spielerliste und war transferierbar.
  test 'die Sperrung gewinnt auch als aelterer Eintrag gegen den echten Verein' do
    sperrung = create(:club, name: 'Ablage Sperrung')
    verein = create(:club, name: 'UHC Elster')
    master = create(:player, clubs: [{ 'club_id' => sperrung.id, 'home_club' => true,
                                       'created_at' => 6.years.ago.iso8601 }])
    dublette = create(:player, clubs: [{ 'club_id' => verein.id, 'home_club' => true,
                                         'created_at' => 1.year.ago.iso8601 }])

    dublette.merge_into!(master, @user.id)
    master.reload

    assert_equal [sperrung.id], offene_heimat(master),
                 'der Widerspruch darf durch eine Zusammenlegung nicht aufgehoben werden'
    zu = master.clubs.find { |c| c['club_id'] == verein.id }
    assert_not_nil zu['valid_until'], 'der echte Verein muss geschlossen werden'
  end

  # Und in der anderen Richtung: Die Sperrung schlaegt auch eine Behelfs-Ablage.
  test 'die Sperrung gewinnt gegen eine Behelfs-Ablage' do
    sperrung = create(:club, name: 'Ablage Sperrung')
    ablage = create(:club, name: 'Ablage Doppelung')
    master = create(:player, clubs: [
      { 'club_id' => sperrung.id, 'home_club' => true, 'created_at' => 6.years.ago.iso8601 },
      { 'club_id' => ablage.id, 'home_club' => true, 'created_at' => 1.year.ago.iso8601 }
    ])
    dublette = create(:player, clubs: [])

    dublette.merge_into!(master, @user.id)
    master.reload

    assert_equal [sperrung.id], offene_heimat(master)
  end

  # Liegen beide Profile in Ablagen, gibt es keinen echten Verein zu bevorzugen. Dann greift
  # weiter die Datumsregel, und es bleibt genau ein Eintrag offen.
  test 'zwei Ablagen am Master lassen genau eine offen' do
    alt = create(:club, name: 'ZZ-Ablage')
    neu = create(:club, name: 'Ablage Doppelung')
    master = create(:player, clubs: [
      { 'club_id' => alt.id, 'home_club' => true, 'created_at' => 5.years.ago.iso8601 },
      { 'club_id' => neu.id, 'home_club' => true, 'created_at' => 1.year.ago.iso8601 }
    ])
    dublette = create(:player, clubs: [])

    dublette.merge_into!(master, @user.id)
    master.reload

    assert_equal [neu.id], offene_heimat(master)
  end

  # club_id steht im JSONB nicht typgarantiert als Integer.
  test 'eine Ablage mit club_id als String wird ebenfalls erkannt' do
    ablage = create(:club, name: 'Ablage Doppelung')
    verein = create(:club, name: 'UHC Elster')
    master = create(:player, clubs: [{ 'club_id' => verein.id, 'home_club' => true,
                                       'created_at' => 5.years.ago.iso8601 }])
    dublette = create(:player, clubs: [{ 'club_id' => ablage.id.to_s, 'home_club' => true,
                                         'created_at' => 1.year.ago.iso8601 }])

    dublette.merge_into!(master, @user.id)
    master.reload

    assert_equal [verein.id], offene_heimat(master)
  end

  # Die Ablage steht am MASTER und traegt club_id als String: Die Vorrangregel greift auf
  # der anderen Seite des Vergleichs ebenso.
  test 'eine Ablage am Master mit club_id als String verliert gegen den echten Verein' do
    ablage = create(:club, name: 'Ablage Doppelung')
    verein = create(:club, name: 'UHC Elster')
    master = create(:player, clubs: [{ 'club_id' => ablage.id.to_s, 'home_club' => true,
                                       'created_at' => 1.year.ago.iso8601 }])
    dublette = create(:player, clubs: [{ 'club_id' => verein.id, 'home_club' => true,
                                         'created_at' => 5.years.ago.iso8601 }])

    dublette.merge_into!(master, @user.id)
    master.reload

    assert_equal [verein.id], offene_heimat(master)
  end

  # In Altdaten steht das Flag als String, und das ist bei diesen Bestaenden der Normalfall.
  test 'eine Ablage mit home_club als String wird als Heimat erkannt und verliert' do
    ablage = create(:club, name: 'ZZ-Ablage')
    verein = create(:club, name: 'UHC Elster')
    master = create(:player, clubs: [{ 'club_id' => ablage.id, 'home_club' => 'true',
                                       'created_at' => 1.year.ago.iso8601 }])
    dublette = create(:player, clubs: [{ 'club_id' => verein.id, 'home_club' => true,
                                         'created_at' => 5.years.ago.iso8601 }])

    dublette.merge_into!(master, @user.id)
    master.reload

    assert_equal [verein.id], offene_heimat(master)
  end

  # Die Umkehrung muss die neue Regel aushalten: `unmerge_from!` verweigert, wenn der Master
  # danach mehr als einen offenen Heimatverein hat oder eine geschlossene Zugehoerigkeit der
  # Dublette nicht wieder aufgeht.
  test 'die Umkehrung eines Merges mit Ablage laeuft durch' do
    ablage = create(:club, name: 'Ablage Doppelung')
    verein = create(:club, name: 'UHC Elster')
    team = create(:team, club: verein)
    master = create(:player, clubs: [{ 'club_id' => verein.id, 'home_club' => true,
                                       'created_at' => 5.years.ago.iso8601 }],
                             with_licenses: [{ team: team }])
    dublette = create(:player, clubs: [{ 'club_id' => ablage.id, 'home_club' => true,
                                         'created_at' => 1.year.ago.iso8601 }])

    dublette.merge_into!(master, @user.id)
    bilanz = dublette.reload.unmerge_from!(@user.id)

    assert_equal [verein.id], offene_heimat(master.reload), 'der Master behaelt seinen Verein'
    assert_equal [ablage.id], offene_heimat(dublette.reload), 'die Ablage steht wieder an der Dublette'
    assert_nil dublette.merged_into_id
    # Die Ablage wurde nie kopiert, also gibt es am Master nichts zu entfernen. Gemeldet
    # wird sie trotzdem, weil ein Merge VOR dieser Aenderung sie kopiert hat und beide
    # Faelle hier nicht unterscheidbar sind.
    assert_equal 0, bilanz[:clubs]
    assert_includes bilanz[:clubs_manual], ablage.id
  end

  # Ein Zweitspielrecht in einer Ablage ist derselbe Behelf und hat am Master ebenso nichts
  # zu suchen.
  test 'ein Zweitspielrecht in der Ablage wandert nicht mit' do
    ablage = create(:club, name: 'Ablage Ausland (IFF Trans)')
    verein = create(:club, name: 'UHC Elster')
    master = create(:player, clubs: [{ 'club_id' => verein.id, 'home_club' => true }])
    dublette = create(:player, clubs: [{ 'club_id' => ablage.id, 'home_club' => false }])

    dublette.merge_into!(master, @user.id)
    master.reload

    assert_not_includes master.clubs.map { |c| c['club_id'] }, ablage.id
  end
end
