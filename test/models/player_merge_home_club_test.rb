require 'test_helper'

# Player#_merge_clubs entdoppelte nur bei DEMSELBEN Verein. Zwei verschiedene offene
# Heimatvereine -- einer vom Master, einer von der Dublette -- ueberlebten beide.
# Danach widersprachen sich die Leser: home_club nimmt den letzten, der Transferantrag
# bestimmte den abgebenden Verein als ersten. Auf Produktion trugen 239 der 1231
# Merge-Ziele diesen Zustand.
class PlayerMergeHomeClubTest < ActiveSupport::TestCase
  setup do
    create(:setting, current_season_id: '18')
    @user = create(:user)
  end

  def offene_heimat(player)
    Array(player.clubs).select do |c|
      ActiveModel::Type::Boolean.new.cast(c['home_club']) && c['valid_until'].blank?
    end
  end

  test 'nach dem Merge bleibt nur ein Heimatverein offen' do
    ablage = create(:club)
    verein = create(:club)
    master = create(:player, clubs: [{ 'club_id' => ablage.id, 'home_club' => true }])
    dublette = create(:player, clubs: [{ 'club_id' => verein.id, 'home_club' => true,
                                        'created_at' => 2.years.ago.iso8601 }])

    dublette.merge_into!(master, @user.id)
    master.reload

    offen = offene_heimat(master)
    assert_equal 1, offen.size, "genau ein offener Heimatverein, gefunden: #{offen.inspect}"
  end

  test 'der zuletzt begonnene Heimatverein bleibt offen' do
    alt = create(:club)
    neu = create(:club)
    master = create(:player, clubs: [{ 'club_id' => alt.id, 'home_club' => true,
                                       'created_at' => 5.years.ago.iso8601 }])
    dublette = create(:player, clubs: [{ 'club_id' => neu.id, 'home_club' => true,
                                        'created_at' => 1.year.ago.iso8601 }])

    dublette.merge_into!(master, @user.id)
    master.reload

    assert_equal([neu.id], offene_heimat(master).map { |c| c['club_id'] })
  end

  test 'der geschlossene Eintrag traegt den ausfuehrenden Benutzer' do
    alt = create(:club)
    neu = create(:club)
    master = create(:player, clubs: [{ 'club_id' => alt.id, 'home_club' => true,
                                       'created_at' => 5.years.ago.iso8601 }])
    dublette = create(:player, clubs: [{ 'club_id' => neu.id, 'home_club' => true,
                                        'created_at' => 1.year.ago.iso8601 }])

    dublette.merge_into!(master, @user.id)
    master.reload

    zu = master.clubs.find { |c| c['club_id'] == alt.id }
    assert_not_nil zu['valid_until'], 'der ueberzaehlige Eintrag muss geschlossen sein'
    assert_equal @user.id, zu['valid_set_by']
  end

  # Zweitspielrechte sind kein Heimatverein und duerfen unberuehrt bleiben.
  test 'ein offenes Zweitspielrecht wird nicht mitgeschlossen' do
    heimat = create(:club)
    zweit  = create(:club)
    master = create(:player, clubs: [{ 'club_id' => heimat.id, 'home_club' => true }])
    dublette = create(:player, clubs: [{ 'club_id' => zweit.id, 'home_club' => false }])

    dublette.merge_into!(master, @user.id)
    master.reload

    offen_zweit = master.clubs.find { |c| c['club_id'] == zweit.id }
    assert_nil offen_zweit['valid_until'], 'Zweitspielrecht bleibt offen'
    assert_equal 1, offene_heimat(master).size
  end

  test 'derselbe Verein auf beiden Seiten bleibt ein einziger offener Eintrag' do
    verein = create(:club)
    master = create(:player, clubs: [{ 'club_id' => verein.id, 'home_club' => true }])
    dublette = create(:player, clubs: [{ 'club_id' => verein.id, 'home_club' => true }])

    dublette.merge_into!(master, @user.id)
    master.reload

    assert_equal([verein.id], offene_heimat(master).map { |c| c['club_id'] })
  end
  test 'auch bei drei offenen Heimatvereinen bleibt genau einer' do
    a = create(:club)
    b = create(:club)
    c = create(:club)
    master = create(:player, clubs: [
      { 'club_id' => a.id, 'home_club' => true, 'created_at' => 5.years.ago.iso8601 },
      { 'club_id' => b.id, 'home_club' => true, 'created_at' => 3.years.ago.iso8601 }
    ])
    dublette = create(:player, clubs: [{ 'club_id' => c.id, 'home_club' => true,
                                        'created_at' => 1.year.ago.iso8601 }])

    dublette.merge_into!(master, @user.id)
    master.reload

    assert_equal([c.id], offene_heimat(master).map { |x| x['club_id'] })
  end

  # In Altdaten steht das Flag als String. Wuerde der Cast fehlen, saehe die Auswahl
  # einen solchen Eintrag nicht als Heimat und liesse ihn offen stehen.
  test 'home_club als String zaehlt beim Zusammenfuehren als Heimatverein' do
    alt = create(:club)
    neu = create(:club)
    master = create(:player, clubs: [{ 'club_id' => alt.id, 'home_club' => 'true',
                                       'created_at' => 5.years.ago.iso8601 }])
    dublette = create(:player, clubs: [{ 'club_id' => neu.id, 'home_club' => true,
                                        'created_at' => 1.year.ago.iso8601 }])

    dublette.merge_into!(master, @user.id)
    master.reload

    assert_equal(1, master.clubs.count { |c| ActiveModel::Type::Boolean.new.cast(c['home_club']) && c['valid_until'].blank? })
  end

  # Ein Ende in der Zukunft laeuft heute noch: `home_club_hash` zaehlt so einen Eintrag
  # als gueltigen Heimatverein. Eine reine blank?-Pruefung haette ihn uebersehen und den
  # Widerspruch bestehen lassen.
  test 'ein Heimatverein mit Ende in der Zukunft zaehlt als offen und wird mitgeschlossen' do
    alt = create(:club)
    neu = create(:club)
    master = create(:player, clubs: [{ 'club_id' => alt.id, 'home_club' => true,
                                       'created_at' => 5.years.ago.iso8601,
                                       'valid_until' => 60.days.from_now.iso8601 }])
    dublette = create(:player, clubs: [{ 'club_id' => neu.id, 'home_club' => true,
                                        'created_at' => 1.year.ago.iso8601 }])

    dublette.merge_into!(master, @user.id)
    master.reload

    zu = master.clubs.find { |c| c['club_id'] == alt.id }
    assert_not_nil zu['valid_until'], 'der Eintrag mit Zukunftsende muss geschlossen werden'
    assert_equal([neu.id], master.clubs.select { |c| c['valid_until'].blank? }.map { |c| c['club_id'] })

    # Bewusst NICHT gegen home_club_hash geprueft: Der Stichtagsvergleich ist tagesgenau,
    # ein heute geschlossener Eintrag gilt dort bis Mitternacht weiter. Genauso verhaelt
    # sich ein regulaerer Vereinswechsel. Massgeblich ist der gespeicherte Zustand.
  end

  # Ohne created_at teilen sich beide Eintraege den Sortierschluessel. sort_by ist in Ruby
  # nicht als stabil zugesichert, der Tiebreaker macht die Auswahl reproduzierbar.
  test 'ohne created_at ist die Auswahl trotzdem eindeutig' do
    a = create(:club)
    b = create(:club)
    ergebnisse = 3.times.map do
      master = create(:player, clubs: [{ 'club_id' => a.id, 'home_club' => true }])
      dublette = create(:player, clubs: [{ 'club_id' => b.id, 'home_club' => true }])
      dublette.merge_into!(master, @user.id)
      offene_heimat(master.reload).map { |c| c['club_id'] }
    end

    assert_equal 1, ergebnisse.uniq.size, "Auswahl schwankt: #{ergebnisse.inspect}"
  end
  # Seit #480 gibt es `home_club_entry` (ueber home_club_hash/valid_time?), seit diesem PR
  # `open_home_club_entries`. Beide beantworten dieselbe Frage, arbeiten aber auf
  # verschiedenen Eingaben -- die eine auf `self.clubs`, die andere auf einem noch nicht
  # gespeicherten Array aus dem Merge. Sie muessen sich decken, sonst ist der Widerspruch
  # nur verschoben statt beseitigt.
  test 'open_home_club_entries und home_club_hash sind sich einig' do
    a = create(:club)
    b = create(:club)
    faelle = [
      [{ 'club_id' => a.id, 'home_club' => true }],
      [{ 'club_id' => a.id, 'home_club' => 'true' }],
      [{ 'club_id' => a.id, 'home_club' => true, 'valid_until' => 60.days.from_now.iso8601 }],
      [{ 'club_id' => a.id, 'home_club' => true, 'valid_until' => 60.days.ago.iso8601 }],
      [{ 'club_id' => a.id, 'home_club' => true, 'valid_until' => 'unbekannt' }],
      [{ 'club_id' => a.id, 'home_club' => true, 'valid_until' => '' }],
      [{ 'club_id' => a.id, 'home_club' => false }],
      [{ 'club_id' => a.id, 'home_club' => true }, { 'club_id' => b.id, 'home_club' => true }],
      [nil, { 'club_id' => a.id, 'home_club' => true }]
    ]

    faelle.each_with_index do |clubs, i|
      player = create(:player, clubs: clubs)
      ueber_merge = player.open_home_club_entries.map { |c| c['club_id'] }
      ueber_leser  = (player.home_club_hash(Date.current) || []).map { |c| c['club_id'] }
      assert_equal ueber_leser, ueber_merge, "Fall #{i} weicht ab: #{clubs.inspect}"
    end
  end
end
