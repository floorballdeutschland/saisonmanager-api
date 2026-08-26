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

    fehler = assert_raises(PlayerUnmerging::UnmergeRefused) { @dublette.reload.unmerge_from!(@user.id) }
    assert_match(/denselben Teams/, fehler.message)
  end

  test 'die Umkehrung verweigert sich bei einer regulaeren Deaktivierung' do
    @dublette.deactivate!(@user.id, reason: 'Vereinsaustritt')
    @dublette.update_columns(merged_into_id: @master.id)

    fehler = assert_raises(PlayerUnmerging::UnmergeRefused) { @dublette.reload.unmerge_from!(@user.id) }
    assert_match(/Deaktivierungsgrund/, fehler.message)
  end

  test 'die Umkehrung verweigert sich bei einem Profil, das nicht zusammengefuehrt ist' do
    fehler = assert_raises(PlayerUnmerging::UnmergeRefused) { @dublette.unmerge_from!(@user.id) }
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

  # Der gefaehrlichste Fall, von beiden Reviews unabhaengig reproduziert: `_merge_clubs`
  # VERWIRFT eine offene Zugehoerigkeit der Dublette, wenn der Master denselben Verein offen
  # hat. Es existiert dann keine Kopie, und der gleichnamige Eintrag am Master ist SEIN
  # eigener. Stimmen zusaetzlich die created_at ueberein (Backfills stempeln gleich), traf
  # die erste Fassung den Master und liess einen echten Menschen ohne Verein zurueck.
  test 'die eigene Zugehoerigkeit des Masters bleibt, wenn auch created_at uebereinstimmt' do
    gemeinsam = create(:club)
    stempel = 3.years.ago.iso8601
    @master.update!(clubs: [{ 'club_id' => gemeinsam.id, 'home_club' => true, 'created_at' => stempel }],
                    licenses: [lizenz_fuer(create(:team, club: gemeinsam))])
    @dublette.update!(clubs: [{ 'club_id' => gemeinsam.id, 'home_club' => true, 'created_at' => stempel }])

    @dublette.merge_into!(@master, @user.id)
    bilanz = @dublette.reload.unmerge_from!(@user.id)
    @master.reload

    assert_equal 0, bilanz[:clubs], 'ohne Beleg fuer eine Kopie darf nichts entfernt werden'
    assert_equal [gemeinsam.id], bilanz[:clubs_manual]
    assert_equal [gemeinsam.id], Array(@master.clubs).map { |c| c['club_id'] },
                 'der eigene Eintrag des Masters muss stehen bleiben'
    assert_equal [gemeinsam.id], offene_vereine(@master), 'und er muss wieder offen sein'
  end

  # Ohne lizenziertes Team ist die Pruefung auf geteilte Teams leer und damit wertlos, und
  # die Rueckschreibung findet nichts. Zusammen sieht das wie ein Erfolg aus, waehrend jede
  # Spielteilnahme beim anderen Menschen bleibt.
  test 'ohne lizenziertes Team der Dublette wird verweigert, solange der Master Spiele hat' do
    @dublette.merge_into!(@master, @user.id)
    @dublette.reload.update!(licenses: [])

    fehler = assert_raises(PlayerUnmerging::UnmergeRefused) { @dublette.reload.unmerge_from!(@user.id) }
    assert_match(/keine Lizenz mit team_id/, fehler.message)
    assert_equal [@master.id], aufstellung_ids(@spiel_dublette), 'nichts angefasst'
  end

  # Schreibt nach dem Merge etwas anderes in den Verlauf (Saisonwechsel, SBK-Entscheidung),
  # liegt der Merge-Eintrag nicht mehr oben. Ihn aus der Mitte zu ziehen verfaelscht den
  # Verlauf, ihn stehen zu lassen haelt die Lizenz ungueltig.
  test 'ein Verlaufseintrag nach der Zusammenfuehrung laesst verweigern' do
    @dublette.merge_into!(@master, @user.id)
    @dublette.reload
    @dublette.licenses.first['history'] << { 'license_status_id' => License::DELETED,
                                             'reason' => 'Saisonwechsel — Lizenz aus Vorsaison',
                                             'created_by' => @user.id,
                                             'created_at' => Time.now.iso8601 }
    @dublette.save!(validate: false)

    fehler = assert_raises(PlayerUnmerging::UnmergeRefused) { @dublette.reload.unmerge_from!(@user.id) }
    assert_match(/nicht der oberste/, fehler.message)
  end

  test 'Spielreferenzen ohne Bezug zu beiden Profilen werden gezaehlt und bleiben stehen' do
    fremdes_spiel = spiel_mit(create(:team), @dublette)

    @dublette.merge_into!(@master, @user.id)
    bilanz = @dublette.reload.unmerge_from!(@user.id)

    assert_equal 1, bilanz[:games_manual]
    assert_equal [@master.id], aufstellung_ids(fremdes_spiel),
                 'nicht zuordenbar heisst stehen lassen, aber melden'
  end

  # `_repoint_license_documents` laesst beim Merge ein kollidierendes Dokument bewusst an der
  # Dublette stehen. Ein pauschales update_all zurueck laeuft dann in den Unique-Index.
  test 'ein kollidierendes Lizenzdokument wird gemeldet statt verschoben' do
    lizenz_id = @dublette.licenses.first['id']
    @dublette.merge_into!(@master, @user.id)

    am_master = dokument(@master, lizenz_id, 'ausweis')
    dokument(@dublette, lizenz_id, 'ausweis')
    ohne_lizenz = dokument(@master, nil, 'zustimmung')

    bilanz = @dublette.reload.unmerge_from!(@user.id)

    assert_equal 0, bilanz[:documents]
    assert_equal [am_master.id, ohne_lizenz.id].sort, bilanz[:documents_manual].sort
    assert_equal @master.id, am_master.reload.player_id
  end

  # Gegenstueck zur Kollisionsregel im Merge: Eine archivierte Fassung besetzt
  # den Platz nicht, das Dokument darf also zurueck.
  test 'eine archivierte Fassung am Master geht trotz aktiver Zeile an der Dublette zurueck' do
    lizenz_id = @dublette.licenses.first['id']
    @dublette.merge_into!(@master, @user.id)
    am_master = dokument(@master, lizenz_id, 'ausweis')
    am_master.archive!(reason: 'replaced')
    dokument(@dublette, lizenz_id, 'ausweis')

    bilanz = @dublette.reload.unmerge_from!(@user.id)

    assert_equal 1, bilanz[:documents]
    assert_empty bilanz[:documents_manual]
    assert_equal @dublette.id, am_master.reload.player_id
  end

  test 'ein zuordenbares Lizenzdokument geht zurueck an die Dublette' do
    lizenz_id = @dublette.licenses.first['id']
    @dublette.merge_into!(@master, @user.id)
    doc = dokument(@master, lizenz_id, 'ausweis')

    bilanz = @dublette.reload.unmerge_from!(@user.id)

    assert_equal 1, bilanz[:documents]
    assert_equal @dublette.id, doc.reload.player_id
  end

  def dokument(player, lizenz_id, art)
    doc = LicenseDocument.new(player_id: player.id, license_id: lizenz_id, document_type: art)
    doc.save!(validate: false)
    doc
  end

  def lizenz_fuer(team)
    { 'id' => Digest::UUID.uuid_v4, 'team_id' => team.id, 'season_id' => team.league.season_id,
      'history' => [{ 'license_status_id' => License::APPROVED,
                      'created_at' => 1.day.ago.iso8601, 'created_by' => nil }] }
  end
end
