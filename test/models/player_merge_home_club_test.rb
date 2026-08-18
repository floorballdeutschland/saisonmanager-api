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
end
