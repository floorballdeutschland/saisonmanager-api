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

  # Art. 21 DSGVO: In "Ablage Sperrung" liegen Personen, die nicht mehr im Saisonmanager
  # erscheinen wollen. Diese Zugehoerigkeit ist eine Entscheidung, kein Behelf.
  test 'Ablage Sperrung ist keine Ablage in diesem Sinn' do
    sperrung = create(:club, name: 'Ablage Sperrung')

    assert_not_includes Club.ablage_ids, sperrung.id
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

  # "Ablage Sperrung" muss sich wie ein echter Verein verhalten, sonst wuerde der
  # Widerspruch beim naechsten Merge stillschweigend aufgehoben.
  test 'Ablage Sperrung wird uebernommen und behandelt wie ein echter Verein' do
    sperrung = create(:club, name: 'Ablage Sperrung')
    verein = create(:club, name: 'UHC Elster')
    master = create(:player, clubs: [{ 'club_id' => verein.id, 'home_club' => true,
                                       'created_at' => 5.years.ago.iso8601 }])
    dublette = create(:player, clubs: [{ 'club_id' => sperrung.id, 'home_club' => true,
                                         'created_at' => 1.year.ago.iso8601 }])

    dublette.merge_into!(master, @user.id)
    master.reload

    assert_equal [sperrung.id], offene_heimat(master), 'die juengere Zugehoerigkeit bleibt'
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
