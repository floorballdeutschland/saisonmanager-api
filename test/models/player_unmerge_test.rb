require 'test_helper'

# Die Dubletten-Heuristik matcht auch Geburtsdaten, die sich in genau einer Ziffer
# unterscheiden. Der Guard dagegen (`_shares_game_with?`) greift nur bei gemeinsamer
# Aufstellung im SELBEN Spiel — spielen zwei Personen in verschiedenen Ligen, gibt es kein
# gemeinsames Spiel und der Merge laeuft durch. Auf Produktion so passiert: 26679
# (TV Lilienthal) wurde in 24193 (SC Potsdam) gezogen, beide in S16/S17 parallel lizenziert.
class PlayerUnmergeTest < ActiveSupport::TestCase
  setup do
    create(:setting, current_season_id: '18')
    @user = create(:user)

    @club_master = create(:club)
    @club_dublette = create(:club)
    @team_master = create(:team, club: @club_master)
    @team_dublette = create(:team, club: @club_dublette)

    @master = create(:player, birthdate: '2015-07-12',
                              clubs: [{ 'club_id' => @club_master.id, 'home_club' => true,
                                        'created_at' => 3.years.ago.iso8601 }],
                              with_licenses: [{ team: @team_master }])
    @dublette = create(:player, birthdate: '2015-07-15',
                                clubs: [{ 'club_id' => @club_dublette.id, 'home_club' => true,
                                          'created_at' => 2.years.ago.iso8601 }],
                                with_licenses: [{ team: @team_dublette }])

    @spiel_dublette = spiel_mit(@team_dublette, @dublette)
    @spiel_master = spiel_mit(@team_master, @master)
  end

  def spiel_mit(team, player)
    gegner = create(:team)
    create(:game, home_team_id: team.id, guest_team_id: gegner.id,
                  players: { 'home' => [{ 'player_id' => player.id, 'trikot_number' => 7 }],
                             'guest' => [] })
  end

  def aufstellung_ids(game)
    game.reload.players['home'].map { |p| p['player_id'] }
  end

  def offene_vereine(player)
    Array(player.clubs).select { |c| c['valid_until'].blank? }.map { |c| c['club_id'] }
  end

  test 'die Umkehrung stellt Kennzeichnung, Zugehoerigkeit und Lizenz der Dublette wieder her' do
    @dublette.merge_into!(@master, @user.id)
    @dublette.reload.unmerge_from!(@user.id)
    @dublette.reload

    assert_nil @dublette.merged_into_id
    assert_nil @dublette.deactivated_at
    assert_nil @dublette.deactivation_reason
    assert_equal [@club_dublette.id], offene_vereine(@dublette)

    letzter = @dublette.licenses.first['history'].last
    assert_equal License::APPROVED, letzter['license_status_id'].to_i,
                 "der Zusammenfuehrungs-Eintrag muss weg sein, Verlauf: #{@dublette.licenses.first['history'].inspect}"
  end

  test 'die Umkehrung nimmt Lizenz und Zugehoerigkeit vom Master wieder ab' do
    @dublette.merge_into!(@master, @user.id)
    dublette_lizenz_id = @dublette.reload.licenses.first['id']
    assert_equal 2, @master.reload.licenses.size, 'Vorbedingung: der Merge hat kopiert'

    @dublette.unmerge_from!(@user.id)
    @master.reload

    assert_equal 1, @master.licenses.size
    assert_not_includes @master.licenses.map { |l| l['id'] }, dublette_lizenz_id
    assert_not_includes Array(@master.clubs).map { |c| c['club_id'] }, @club_dublette.id
    assert_equal [@club_master.id], offene_vereine(@master)
  end

  test 'die Umkehrung schreibt nur die Spiele der Dublette zurueck' do
    @dublette.merge_into!(@master, @user.id)
    assert_equal [@master.id], aufstellung_ids(@spiel_dublette), 'Vorbedingung: der Merge hat umgeschrieben'

    @dublette.reload.unmerge_from!(@user.id)

    assert_equal [@dublette.id], aufstellung_ids(@spiel_dublette)
    assert_equal [@master.id], aufstellung_ids(@spiel_master), 'das eigene Spiel des Masters bleibt unberuehrt'
  end

  test 'die Umkehrung verweigert sich, wenn beide Profile Lizenzen im selben Team haben' do
    geteilt = create(:team, club: @club_master)
    @master.update!(licenses: @master.licenses + [lizenz_fuer(geteilt)])
    @dublette.update!(licenses: @dublette.licenses + [lizenz_fuer(geteilt)])

    @dublette.merge_into!(@master, @user.id)

    fehler = assert_raises(ArgumentError) { @dublette.reload.unmerge_from!(@user.id) }
    assert_match(/denselben Teams/, fehler.message)
  end

  test 'die Umkehrung verweigert sich bei einer regulaeren Deaktivierung' do
    @dublette.deactivate!(@user.id, reason: 'Vereinsaustritt')
    @dublette.update_columns(merged_into_id: @master.id)

    fehler = assert_raises(ArgumentError) { @dublette.reload.unmerge_from!(@user.id) }
    assert_match(/Deaktivierungsgrund/, fehler.message)
  end

  test 'die Umkehrung verweigert sich bei einem Profil, das nicht zusammengefuehrt ist' do
    fehler = assert_raises(ArgumentError) { @dublette.unmerge_from!(@user.id) }
    assert_match(/nicht zusammengeführt/, fehler.message)
  end

  # Altbestand: Zugehoerigkeiten ohne created_at sind nicht von einer Kopie zu
  # unterscheiden. `_merge_clubs` verwirft die OFFENE Zugehoerigkeit der Dublette, wenn der
  # Master denselben Verein offen hat -- der gleichnamige Eintrag am Master ist dann sein
  # eigener und darf nicht verschwinden. Belegt an Moritz Winter 12635/8282.
  test 'eine Zugehoerigkeit ohne created_at wird gemeldet statt geloescht' do
    gemeinsam = create(:club)
    @master.update!(clubs: [{ 'club_id' => gemeinsam.id, 'home_club' => true }])
    @dublette.update!(clubs: [{ 'club_id' => gemeinsam.id, 'home_club' => true }])

    @dublette.merge_into!(@master, @user.id)
    bilanz = @dublette.reload.unmerge_from!(@user.id)
    @master.reload

    assert_equal 0, bilanz[:clubs], 'ohne created_at darf nichts entfernt werden'
    assert_equal [gemeinsam.id], bilanz[:clubs_manual]
    assert_equal [gemeinsam.id], Array(@master.clubs).map { |c| c['club_id'] },
                 'der eigene Eintrag des Masters muss stehen bleiben'
    assert_equal [gemeinsam.id], offene_vereine(@master),
                 'und er muss wieder offen sein'
  end

  def lizenz_fuer(team)
    { 'id' => Digest::UUID.uuid_v4, 'team_id' => team.id, 'season_id' => team.league.season_id,
      'history' => [{ 'license_status_id' => License::APPROVED,
                      'created_at' => 1.day.ago.iso8601, 'created_by' => nil }] }
  end
end
