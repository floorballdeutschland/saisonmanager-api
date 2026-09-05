require 'test_helper'

# `players:merge_duplicates` fuehrt immer in die KLEINSTE ID zusammen. Bei einem echten
# Duplikat entscheidet damit die Anlagereihenfolge, welches Profil bestehen bleibt, und das
# ist regelmaessig nicht das, mit dem der Verein arbeitet. Gemeldet am 04.09.2026 fuer Pavel
# Lubentsov: 3743 wurde in 180 gezogen, danach stand der undatierte Alteintrag FBC Phoenix
# Leipzig als Heimatverein offen, waehrend die laufende Zugehoerigkeit beim SSC Leipzig der
# Merge geschlossen hatte.
class PlayerSwapMergeMasterTest < ActiveSupport::TestCase
  setup do
    create(:setting, current_season_id: '18')
    @user = create(:user)

    @club_alt = create(:club)     # der Verein, dem der alte Master seinen Alteintrag verdankt
    @club_neu = create(:club)     # die laufende Zugehoerigkeit des richtigen Profils
    @club_zweit = create(:club)   # Zweitspielrecht, an beiden Profilen als Kopie
    @team_alt = create(:team, club: @club_alt)
    @team_neu = create(:team, club: @club_neu)

    @zweit_stempel = '2022-10-15T07:20:49.782+02:00'

    # Der alte Master: kleinere ID, undatierter Heimateintrag, alte Lizenz.
    @alt = create(:player, birthdate: '1996-11-27',
                           clubs: [{ 'club_id' => @club_alt.id, 'home_club' => true }],
                           with_licenses: [{ team: @team_alt, created_at: 6.years.ago.iso8601 }])
    # Das Profil, das der Verein benutzt: laufende Zugehoerigkeit, junge Lizenz.
    @neu = create(:player, birthdate: '1996-11-27',
                           clubs: [{ 'club_id' => @club_neu.id, 'home_club' => true },
                                   { 'club_id' => @club_zweit.id, 'home_club' => false,
                                     'created_at' => @zweit_stempel,
                                     'valid_until' => '2023-07-15T00:00:00.000+02:00' }],
                           with_licenses: [{ team: @team_neu, created_at: 1.month.ago.iso8601 }])

    @spiel_neu = spiel_mit(@team_neu, @neu)
    @spiel_alt = spiel_mit(@team_alt, @alt)
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

  def offene_heimatvereine(player)
    Array(player.clubs).select { |c| c['home_club'] && c['valid_until'].blank? }.map { |c| c['club_id'] }
  end

  # Der Merge, wie ihn der Dubletten-Lauf gefahren hat: in die kleinere ID.
  def merge_in_die_falsche_richtung!
    @neu.merge_into!(@alt, @user.id)
    @neu.reload
    @alt.reload
  end

  test 'nach dem Richtungswechsel ist das richtige Profil der aktive Master' do
    merge_in_die_falsche_richtung!
    assert_equal @alt.id, @neu.merged_into_id, 'Vorbedingung: falsche Richtung'

    @neu.swap_merge_master!(@user.id)
    @neu.reload
    @alt.reload

    assert_nil @neu.merged_into_id
    assert_nil @neu.deactivated_at
    assert_nil @neu.deactivation_reason
    assert_equal @neu.id, @alt.merged_into_id
    assert_not_nil @alt.deactivated_at
    assert_equal 'Zusammenführung', @alt.deactivation_reason
  end

  # Der eigentliche Schaden des Muenzwurfs, und der Grund fuer die Meldung: Der Merge
  # schliesst die Zugehoerigkeiten der Dublette, und stand dort der laufende Heimatverein,
  # steht das Profil danach beim falschen Verein.
  #
  # Der Bestand wird hier von Hand hergestellt, weil er aus dem Stand vom 08.07.2026 stammt:
  # Damals landete die offene Zugehoerigkeit der Dublette nicht am Master, und die
  # Entscheidung ueber ueberzaehlige Heimatvereine (`_close_surplus_home_clubs`, Beleg
  # schlaegt Datum, api#481 ff.) gab es noch nicht. Heute trifft der Merge sie selbst, und
  # zwar richtig -- der Test darueber (offene Zugehoerigkeit nach dem Merge) wuerde die
  # Meldung deshalb nicht mehr nachstellen.
  test 'der Richtungswechsel holt die laufende Zugehoerigkeit zurueck' do
    merge_in_die_falsche_richtung!
    @alt.update_columns(clubs: [{ 'club_id' => @club_alt.id, 'home_club' => true }])
    assert_equal [@club_alt.id], offene_heimatvereine(@alt.reload),
                 'Vorbedingung: am Master steht sein eigener Alteintrag offen'

    @neu.swap_merge_master!(@user.id)

    assert_equal [@club_neu.id], offene_heimatvereine(@neu.reload),
                 'die laufende Zugehoerigkeit des richtigen Profils muss wieder offen sein'
  end

  test 'alle Spielreferenzen liegen danach am neuen Master' do
    merge_in_die_falsche_richtung!
    assert_equal [@alt.id], aufstellung_ids(@spiel_neu), 'Vorbedingung: der Merge hat umgeschrieben'

    bilanz = @neu.swap_merge_master!(@user.id)

    assert_equal [@neu.id], aufstellung_ids(@spiel_neu)
    assert_equal [@neu.id], aufstellung_ids(@spiel_alt),
                 'auch die Spiele des alten Masters wandern mit, es ist dieselbe Person'
    assert_equal 2, bilanz[:games]
    assert_equal 0, Game.referencing_player(@alt.id).count
  end

  test 'die Lizenzen beider Profile liegen danach am neuen Master' do
    merge_in_die_falsche_richtung!

    @neu.swap_merge_master!(@user.id)

    teams = Array(@neu.reload.licenses).map { |l| l['team_id'].to_i }.sort
    assert_equal [@team_alt.id, @team_neu.id].sort, teams
  end

  # Warum die Lizenz-Kopien am alten Master NICHT vorher abgezogen werden: Was nach dem
  # Merge am Master in den Verlauf geschrieben wurde, haengt nur an der Kopie. Bei Lubentsov
  # ist das der Saisonwechsel vom 12.08.2026 auf 13 Lizenzen. Wer die Kopie abzieht, stellt
  # abgelaufene Lizenzen wieder auf "erteilt".
  test 'ein Verlaufseintrag, der nach dem Merge am Master entstand, ueberlebt' do
    merge_in_die_falsche_richtung!
    kopie = @alt.licenses.find { |l| l['team_id'].to_i == @team_neu.id }
    kopie['history'] << { 'license_status_id' => License::DELETED,
                          'reason' => 'Saisonwechsel — Lizenz aus Vorsaison',
                          'created_by' => @user.id,
                          'created_at' => Time.now.iso8601 }
    @alt.save!(validate: false)

    @neu.reload.swap_merge_master!(@user.id)

    lizenz = Array(@neu.reload.licenses).find { |l| l['team_id'].to_i == @team_neu.id }
    assert_equal License::DELETED, lizenz['history'].last['license_status_id'].to_i
    assert_equal 'Saisonwechsel — Lizenz aus Vorsaison', lizenz['history'].last['reason']
  end

  # Ohne diesen Schritt legt der Gegenmerge jede kopierte Zugehoerigkeit ein zweites Mal an,
  # und die Historie des Profils behauptet zwei gleichzeitige Zweitspielrechte.
  test 'kopierte Zugehoerigkeiten werden nicht ein zweites Mal angelegt' do
    merge_in_die_falsche_richtung!
    assert_equal 1, Array(@alt.clubs).count { |c| c['club_id'] == @club_zweit.id },
                 'Vorbedingung: der Merge hat die Zweitzugehoerigkeit kopiert'

    bilanz = @neu.swap_merge_master!(@user.id)

    assert_equal 1, bilanz[:clubs]
    danach = Array(@neu.reload.clubs).count { |c| c['club_id'] == @club_zweit.id }
    assert_equal 1, danach
  end

  # Eine Kette `X -> alter Master -> neuer Master` loest ausser dem Legacy-Backfill niemand
  # auf: Jeder andere Leser vergleicht `merged_into_id` genau eine Stufe und landete damit
  # auf einem deaktivierten Profil.
  test 'weitere Dubletten des alten Masters werden mit umgehaengt' do
    geschwister = create(:player, birthdate: '1996-11-27')
    geschwister.merge_into!(@alt, @user.id)
    merge_in_die_falsche_richtung!

    bilanz = @neu.swap_merge_master!(@user.id)

    assert_equal 1, bilanz[:repointed]
    assert_equal @neu.id, geschwister.reload.merged_into_id
    assert_equal 0, Player.where(merged_into_id: @alt.id).count
  end

  test 'der Wechsel verweigert sich bei einem Profil, das nicht zusammengefuehrt ist' do
    fehler = assert_raises(PlayerUnmerging::UnmergeRefused) { @neu.swap_merge_master!(@user.id) }
    assert_match(/nicht zusammengeführt/, fehler.message)
  end

  test 'der Wechsel verweigert sich bei einer regulaeren Deaktivierung' do
    @neu.deactivate!(@user.id, reason: 'Vereinsaustritt')
    @neu.update_columns(merged_into_id: @alt.id)

    fehler = assert_raises(PlayerUnmerging::UnmergeRefused) { @neu.reload.swap_merge_master!(@user.id) }
    assert_match(/Deaktivierungsgrund/, fehler.message)
  end

  test 'der Wechsel verweigert sich, wenn der alte Master selbst zusammengefuehrt ist' do
    merge_in_die_falsche_richtung!
    dritter = create(:player, birthdate: '1996-11-27')
    @alt.update_columns(merged_into_id: dritter.id)

    fehler = assert_raises(PlayerUnmerging::UnmergeRefused) { @neu.reload.swap_merge_master!(@user.id) }
    assert_match(/ist selbst zusammengeführt/, fehler.message)
  end

  # Steht der Merge-Eintrag im Lizenzverlauf nicht oben, hat danach etwas anderes am PROFIL
  # geschrieben. Der Lauf verweigert, und weil alles in einer Transaktion liegt, bleibt auch
  # der halb vollzogene Richtungswechsel nicht stehen.
  test 'eine Verweigerung mitten im Ablauf laesst nichts halb Gedrehtes zurueck' do
    merge_in_die_falsche_richtung!
    @neu.licenses.first['history'] << { 'license_status_id' => License::DELETED,
                                        'reason' => 'Saisonwechsel — Lizenz aus Vorsaison',
                                        'created_by' => @user.id,
                                        'created_at' => Time.now.iso8601 }
    @neu.save!(validate: false)

    assert_raises(PlayerUnmerging::UnmergeRefused) { @neu.reload.swap_merge_master!(@user.id) }

    @neu.reload
    @alt.reload
    assert_equal @alt.id, @neu.merged_into_id, 'die Richtung darf nicht halb gedreht sein'
    assert_not_nil @neu.deactivated_at
    assert_nil @alt.merged_into_id
    assert_equal [@alt.id], aufstellung_ids(@spiel_neu)
  end
end
