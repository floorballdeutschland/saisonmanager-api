require 'test_helper'

# Tests für Lizenz-Filter-Verhalten von Player. Decken die Pfade ab, die zum
# „Bonner-Anträge"-Vorfall (Mai 2026) geführt haben: 27 Februar-Anträge eines
# Vereins hingen weiter als „beantragt" in der Lizenzansicht, weil
# `Setting.current_min_team` über fehlende `min_team_id`-Werte auf 0 fiel und
# Vorsaison-Lizenzen dadurch durch den Filter rutschten.
class PlayerTest < ActiveSupport::TestCase
  # ---------------------------------------------------------------------------
  # Player#full_hash(with_licenses=true, only_current_licenses=true)
  # ---------------------------------------------------------------------------

  test 'full_hash mit only_current_licenses=true liefert nur Lizenzen oberhalb current_min_team' do
    previous_league = create(:league, :previous_season)
    current_league  = create(:league, :current_season)
    previous_team   = create(:team, league: previous_league)
    current_team    = create(:team, league: current_league)

    # Schwelle so legen, dass nur das spätere current_team durchgelassen wird.
    # Team-IDs in einem frischen Test sind aufsteigend; das früher angelegte
    # previous_team hat die kleinere ID.
    create(:setting, current_season_id: '18', current_min_team: current_team.id)

    player = create(:player, with_licenses: [
      { team: previous_team, status: License::APPROVED },
      { team: current_team,  status: License::APPROVED }
    ])

    result = player.full_hash(true, true)
    license_team_ids = result[:licenses].map { |l| l['team_id'] }
    assert_includes license_team_ids, current_team.id
    refute_includes license_team_ids, previous_team.id
  end

  test 'full_hash mit current_min_team=0 (Fallback aus PR #168) lässt alle Lizenzen durch' do
    # Genau dieser Pfad ist der Bonner-Vorfall: ohne min_team_id rutschen
    # Lizenzen aus jeder Saison durch den Filter.
    create(:setting, current_season_id: '18', current_min_team: nil)

    previous_league = create(:league, :previous_season)
    previous_team   = create(:team, league: previous_league)
    current_league  = create(:league, :current_season)
    current_team    = create(:team, league: current_league)

    player = create(:player, with_licenses: [
      { team: previous_team, status: License::APPROVED },
      { team: current_team,  status: License::APPROVED }
    ])

    assert_equal 0, Setting.current_min_team, 'Vorbedingung: min_team fällt auf 0'

    result = player.full_hash(true, true)
    assert_equal 2, result[:licenses].size,
                 'Mit min_team=0 sind ALLE Lizenzen current — exakt der Bug'
  end

  test 'full_hash mit only_current_licenses=false ignoriert current_min_team' do
    create(:setting, current_season_id: '18', current_min_team: 1500)
    league = create(:league, :previous_season)
    team   = create(:team, league: league)

    player = create(:player, with_licenses: [
      { team: team, status: License::APPROVED }
    ])

    result = player.full_hash(true, false)
    assert_equal 1, result[:licenses].size
  end

  test 'full_hash ohne with_licenses liefert keine licenses-Sektion' do
    create(:setting, current_season_id: '18')
    league = create(:league, :current_season)
    team   = create(:team, league: league)
    player = create(:player, with_licenses: [
      { team: team, status: License::APPROVED }
    ])

    result = player.full_hash
    refute result.key?(:licenses)
  end

  test 'full_hash mit license_with_titles verkraftet eine leere licenses-Spalte' do
    create(:setting, current_season_id: '18')
    # Altdaten-Spieler haben licenses = NULL statt []; das traf die
    # Spieler-Detailansicht im Admin (full_hash(true, false, true)).
    player = create(:player, licenses: nil)

    result = player.full_hash(true, false, true)

    assert_equal [], result[:licenses]
  end

  # ---------------------------------------------------------------------------
  # Player#current_licenses(season_id)
  # ---------------------------------------------------------------------------

  test 'current_licenses liefert nur Lizenzen, deren Team zur Saison gehört' do
    create(:setting, current_season_id: '18')

    current_league = create(:league, :current_season)
    other_league   = create(:league, :previous_season)
    current_team   = create(:team, league: current_league)
    other_team     = create(:team, league: other_league)

    player = create(:player, with_licenses: [
      { team: current_team, status: License::APPROVED },
      { team: other_team,   status: License::APPROVED }
    ])

    result = player.current_licenses('18')

    assert_equal 1, result.size
    assert_equal current_team.id, result.first['team_id']
  end

  test 'current_licenses verwendet teams_by_season, nicht season_id auf der Lizenz' do
    # Selbst wenn season_id auf der Lizenz falsch wäre, zählt die Team-Saison.
    # Sichert die Erwartung aus Issue #173 Punkt 2.
    create(:setting, current_season_id: '18')

    league = create(:league, :current_season)
    team   = create(:team, league: league)

    player = create(:player, with_licenses: [
      { team: team, status: License::APPROVED, season_id: '17' }
    ])

    assert_equal 1, player.current_licenses('18').size
  end

  test 'current_licenses ohne Lizenzen liefert nil oder leeres Array' do
    create(:setting, current_season_id: '18')
    player = create(:player)

    result = player.current_licenses('18')
    assert(result.nil? || result.empty?)
  end

  # --- Extensions from Phase 2 ---

  # ---------------------------------------------------------------------------
  # Player#deactivate!(user_id, reason: nil)
  # ---------------------------------------------------------------------------

  # Der Kern von api#472: Die Deaktivierung ist eine Kennzeichnung fuer die
  # Vereinsansicht und ruehrt die Stammdaten nicht an. Vorher schloss sie jede
  # gueltige Zugehoerigkeit — beim Grund "Vereinsaustritt" verlor die Person damit
  # ihren Heimatverein und war fuer den aufnehmenden Verein nicht mehr erreichbar.
  test 'deactivate! laesst Vereinszugehoerigkeiten unberuehrt' do
    create(:setting, current_season_id: '18')
    user = create(:user)
    player = create(:player)
    laeuft_bis = 3.months.from_now.iso8601
    player.clubs = [
      { 'club_id' => 1, 'home_club' => true },
      { 'club_id' => 2, 'home_club' => false, 'valid_until' => laeuft_bis, 'valid_set_by' => 99 }
    ]
    player.save!(validate: false)

    player.deactivate!(user.id, reason: 'Vereinsaustritt')
    player.reload

    heim = player.clubs.find { |c| c['club_id'] == 1 }
    assert_nil heim['valid_until'], 'Heimatzugehoerigkeit muss offen bleiben'
    assert_nil heim['valid_set_by']

    zweit = player.clubs.find { |c| c['club_id'] == 2 }
    assert_equal laeuft_bis, zweit['valid_until'], 'Befristung darf nicht vorgezogen werden'
    assert_equal 99, zweit['valid_set_by']
    refute zweit.key?(Player::VALID_BEFORE_DEACTIVATION), 'ohne Eingriff braucht es keine Sicherung'
  end

  test 'deactivate! und reactivate! funktionieren bei nil-Clubs/-Lizenzen (Altdaten)' do
    create(:setting, current_season_id: '18')
    user   = create(:user)
    player = create(:player)
    player.update_columns(clubs: nil, licenses: nil)
    player.reload

    player.deactivate!(user.id)
    assert_not_nil player.reload.deactivated_at

    player.reactivate!
    assert_nil player.reload.deactivated_at
  end

  test 'deactivate! überschreibt nicht Clubs, die bereits abgelaufen sind' do
    create(:setting, current_season_id: '18')
    user    = create(:user)
    other   = create(:user)
    past_ts = 1.year.ago.iso8601
    player  = create(:player)
    player.clubs = [
      { 'club_id' => 1, 'valid_until' => past_ts, 'valid_set_by' => other.id }
    ]
    player.save!(validate: false)

    player.deactivate!(user.id)
    player.reload

    # Club war bereits abgelaufen — valid_set_by darf nicht überschrieben werden
    assert_equal other.id, player.clubs.first['valid_set_by']
  end

  test 'deactivate! laesst laufende Lizenzen unberuehrt' do
    create(:setting, current_season_id: '18')
    user   = create(:user)
    league = create(:league, :current_season)
    player = create(:player, with_licenses: [
      { team: create(:team, league: league), status: License::APPROVED },
      { team: create(:team, league: league), status: License::REQUESTED }
    ])
    groessen = player.licenses.map { |l| l['history'].size }

    player.deactivate!(user.id, reason: 'Karriereende')
    player.reload

    assert_equal groessen, player.licenses.map { |l| l['history'].size },
                 'kein zusaetzlicher Verlaufseintrag'
    player.licenses.each do |l|
      refute_equal License::DELETED, l['history'].last['license_status_id'].to_i
    end
  end

  test 'deactivate! berührt keine nicht-aktiven Lizenzen' do
    create(:setting, current_season_id: '18')
    user   = create(:user)
    league = create(:league, :current_season)
    team   = create(:team, league: league)
    player = create(:player, with_licenses: [
      { team: team, status: License::DENIED }
    ])
    original_history_size = player.licenses.first['history'].size

    player.deactivate!(user.id)
    player.reload

    assert_equal original_history_size, player.licenses.first['history'].size
  end

  test 'deactivate! setzt deactivated_at, deactivated_by und deactivation_reason' do
    create(:setting, current_season_id: '18')
    user   = create(:user)
    player = create(:player)

    player.deactivate!(user.id, reason: 'Vereinsaustritt')
    player.reload

    assert_not_nil player.deactivated_at
    assert_equal   user.id, player.deactivated_by
    assert_equal   'Vereinsaustritt', player.deactivation_reason
  end

  test 'deactivate! ohne reason laesst deactivation_reason leer' do
    create(:setting, current_season_id: '18')
    user   = create(:user)
    player = create(:player)

    player.deactivate!(user.id)
    player.reload

    assert_nil player.deactivation_reason
  end

  # ---------------------------------------------------------------------------
  # Player#reactivate!
  # ---------------------------------------------------------------------------

  test 'reactivate! löscht deactivated_at und deactivated_by' do
    create(:setting, current_season_id: '18')
    user   = create(:user)
    player = create(:player)
    player.deactivate!(user.id)
    player.reload

    player.reactivate!
    player.reload

    assert_nil player.deactivated_at
    assert_nil player.deactivated_by
  end

  test 'reactivate! lässt deactivation_reason stehen (Modell löscht es nicht)' do
    # Hinweis: reactivate! räumt deactivation_reason bewusst nicht auf —
    # nur deactivated_at und deactivated_by werden zurückgesetzt.
    create(:setting, current_season_id: '18')
    user   = create(:user)
    player = create(:player)
    player.deactivate!(user.id, reason: 'Karriereende')
    player.reload

    player.reactivate!
    player.reload

    assert_equal 'Karriereende', player.deactivation_reason
  end

  test 'reactivate! stellt valid_until auf Clubs wieder her, die eine Alt-Deaktivierung gesetzt hat' do
    create(:setting, current_season_id: '18')
    user   = create(:user)
    player = create(:player)
    player.clubs = [{ 'club_id' => 1, 'home_club' => true }]
    player.save!(validate: false)

    legacy_deactivate!(player, user.id)
    player.reload
    player.reactivate!
    player.reload

    assert_nil player.clubs.first['valid_until'],
               'valid_until sollte nach reactivate! entfernt sein'
  end

  test 'reactivate! lässt Clubs unberührt, die von einem anderen Nutzer gesetzt wurden' do
    create(:setting, current_season_id: '18')
    user  = create(:user)
    other = create(:user)
    # Club ist bereits durch einen anderen Nutzer abgelaufen — deactivate! überspringt ihn
    player = create(:player)
    player.clubs = [
      { 'club_id' => 1, 'valid_until' => 1.year.ago.iso8601, 'valid_set_by' => other.id }
    ]
    player.save!(validate: false)

    legacy_deactivate!(player, user.id)
    player.reload
    player.reactivate!
    player.reload

    # valid_set_by gehört other, und geschlossen wurde lange vor der Deaktivierung —
    # nach beiden Kriterien von membership_closed_by_deactivation? darf reactivate!
    # diesen Club nicht anfassen
    assert_equal other.id, player.clubs.first['valid_set_by']
    assert_not_nil player.clubs.first['valid_until']
  end

  test 'reactivate! entfernt DELETED-History-Eintrag bei System-Grund und gleichem Nutzer' do
    create(:setting, current_season_id: '18')
    user   = create(:user)
    league = create(:league, :current_season)
    team   = create(:team, league: league)
    player = create(:player, with_licenses: [
      { team: team, status: License::APPROVED }
    ])

    legacy_deactivate!(player, user.id, reason: 'Deaktiviert')
    player.reload
    original_size = player.licenses.first['history'].size

    player.reactivate!
    player.reload

    assert_equal original_size - 1, player.licenses.first['history'].size,
                 'DELETED-Eintrag mit System-Grund soll nach reactivate! entfernt sein'
  end

  # Jeder auswählbare Grund muss auch wieder aufgeräumt werden. Stand ein Grund
  # nur in der Controller-Whitelist und nicht in der Liste, gegen die reactivate!
  # prüft, blieb die Lizenz nach dem Reaktivieren auf "gelöscht" stehen.
  test 'reactivate! entfernt den DELETED-Eintrag bei jedem auswählbaren Grund' do
    create(:setting, current_season_id: '18')
    user   = create(:user)
    league = create(:league, :current_season)

    Player::DEACTIVATION_REASONS.each do |reason|
      team   = create(:team, league: league)
      player = create(:player, with_licenses: [
        { team: team, status: License::APPROVED }
      ])

      legacy_deactivate!(player, user.id, reason: reason)
      player.reload
      original_size = player.licenses.first['history'].size

      player.reactivate!
      player.reload

      assert_equal original_size - 1, player.licenses.first['history'].size,
                   "DELETED-Eintrag mit Grund #{reason} soll nach reactivate! entfernt sein"
    end
  end

  test 'reactivate! bewahrt manuellen DELETED-Eintrag von anderem Nutzer' do
    create(:setting, current_season_id: '18')
    user  = create(:user)
    other = create(:user)
    league = create(:league, :current_season)
    team   = create(:team, league: league)

    player = create(:player, with_licenses: [
      { team: team, status: License::APPROVED, created_by: other.id }
    ])
    # Manuell DELETED durch anderen Nutzer hinzufügen (kein deactivate!-Aufruf)
    player.licenses.first['history'] << {
      'license_status_id' => License::DELETED,
      'reason'            => 'Deaktiviert',
      'created_by'        => other.id,
      'created_at'        => Time.now.iso8601
    }
    player.deactivated_by = user.id
    player.deactivated_at = Time.current
    player.save!(validate: false)
    player.reload
    history_size_before = player.licenses.first['history'].size

    player.reactivate!
    player.reload

    # created_by != deactivated_by → Eintrag bleibt erhalten
    assert_equal history_size_before, player.licenses.first['history'].size
  end

  test 'reactivate! bewahrt DELETED-Eintrag mit nicht-systemischem Grund' do
    create(:setting, current_season_id: '18')
    user   = create(:user)
    league = create(:league, :current_season)
    team   = create(:team, league: league)

    player = create(:player, with_licenses: [
      { team: team, status: License::APPROVED, created_by: user.id }
    ])
    # DELETED mit eigenem Grund (kein System-Grund, kein 'Sonstiges: '-Präfix)
    player.licenses.first['history'] << {
      'license_status_id' => License::DELETED,
      'reason'            => 'Eigener Grund',
      'created_by'        => user.id,
      'created_at'        => Time.now.iso8601
    }
    player.deactivated_by = user.id
    player.deactivated_at = Time.current
    player.save!(validate: false)
    player.reload
    history_size_before = player.licenses.first['history'].size

    player.reactivate!
    player.reload

    assert_equal history_size_before, player.licenses.first['history'].size
  end

  # ---------------------------------------------------------------------------
  # Player#reopen_memberships_closed_by_deactivation!
  # ---------------------------------------------------------------------------

  # Der Bestand: tausende Profile tragen die geschlossene Zugehoerigkeit einer alten
  # Deaktivierung. Der Rake-Task oeffnet sie, laesst aber die Entscheidung des
  # Vereins und die ungueltigen Lizenzen stehen.
  test 'reopen_memberships_closed_by_deactivation! oeffnet die Zugehoerigkeit, behaelt Kennzeichnung und Lizenzstatus' do
    create(:setting, current_season_id: '18')
    user   = create(:user)
    club   = create(:club)
    league = create(:league, :current_season)
    team   = create(:team, league: league)
    player = create(:player, clubs: [{ 'club_id' => club.id, 'home_club' => true }],
                             with_licenses: [{ team: team, status: License::APPROVED }])

    legacy_deactivate!(player, user.id, reason: 'Vereinsaustritt')
    player.reload
    assert_not_nil player.clubs.first['valid_until'], 'Vorbedingung: Alt-Zustand steht'
    verlauf_vorher = player.licenses.first['history'].size

    assert player.reopen_memberships_closed_by_deactivation!, 'es gab etwas zu oeffnen'
    player.reload

    assert_nil player.clubs.first['valid_until'], 'Zugehoerigkeit muss wieder offen sein'
    assert_equal verlauf_vorher, player.licenses.first['history'].size,
                 'die Lizenzen bleiben unangetastet'
    assert_equal License::DELETED, player.licenses.first['history'].last['license_status_id'].to_i
    assert_not_nil player.deactivated_at, 'die Kennzeichnung bleibt'
    assert_equal user.id, player.deactivated_by
    assert_includes club.players(include_deactivated: true).map(&:id), player.id
  end

  test 'reopen_memberships_closed_by_deactivation! ist ein No-op fuer neue Deaktivierungen' do
    create(:setting, current_season_id: '18')
    user   = create(:user)
    club   = create(:club)
    player = create(:player, clubs: [{ 'club_id' => club.id, 'home_club' => true }])

    player.deactivate!(user.id, reason: 'Vereinsaustritt')
    player.reload
    vorher = player.clubs.to_json

    refute player.reopen_memberships_closed_by_deactivation!, 'es gibt nichts zu oeffnen'
    player.reload

    assert_equal vorher, player.clubs.to_json
    assert_not_nil player.deactivated_at
  end

  # ---------------------------------------------------------------------------
  # Player#transfer(new_club_id, user_id)
  # ---------------------------------------------------------------------------

  # Ohne das waere die Person im aufnehmenden Verein sofort wieder aus der aktiven
  # Liste verschwunden – mit der Kennzeichnung des abgebenden Vereins, an die der
  # neue nicht gedacht hat.
  test 'transfer nimmt die Deaktivierung des abgebenden Vereins zurueck' do
    create(:setting, current_season_id: '18')
    user  = create(:user)
    alt   = create(:club)
    neu   = create(:club)
    player = create(:player, clubs: [{ 'club_id' => alt.id, 'home_club' => true }])
    player.deactivate!(user.id, reason: 'Vereinsaustritt')

    player.transfer(neu.id, user.id)
    player.reload

    assert_nil player.deactivated_at
    assert_nil player.deactivated_by
    assert_equal 'Vereinsaustritt', player.deactivation_reason, 'der Grund bleibt als Historie'
    assert_includes neu.players.map(&:id), player.id
  end

  # ---------------------------------------------------------------------------
  # Player#merge_into!(master, user_id)
  # ---------------------------------------------------------------------------

  # Beim Merge sind die Nebenwirkungen richtig: Die Dublette ist inhaltlich leer, ihre
  # Eintraege liegen am Master. Sie darf nirgends mehr als aktives Mitglied oder
  # Lizenznehmer auftauchen – seit api#472 steht das explizit in merge_into! und nicht
  # mehr in deactivate!.
  test 'merge_into! schliesst Zugehoerigkeit und Lizenz der Dublette' do
    create(:setting, current_season_id: '18')
    user   = create(:user)
    club   = create(:club)
    league = create(:league, :current_season)
    team   = create(:team, league: league)
    master = create(:player)
    dublette = create(:player, clubs: [{ 'club_id' => club.id, 'home_club' => true }],
                               with_licenses: [{ team: team, status: License::APPROVED }])

    dublette.merge_into!(master, user.id)
    dublette.reload

    assert_not_nil dublette.clubs.first['valid_until'], 'Zugehoerigkeit der Dublette muss geschlossen sein'
    assert_equal License::DELETED, dublette.licenses.first['history'].last['license_status_id'].to_i
    refute_includes club.players(include_deactivated: true).map(&:id), dublette.id
  end

  test 'merge_into! wirft ArgumentError wenn Secondary und Master identisch sind' do
    create(:setting, current_season_id: '18')
    player = create(:player)

    assert_raises(ArgumentError) { player.merge_into!(player, 1) }
  end

  test 'merge_into! wirft ArgumentError wenn Secondary bereits zusammengeführt wurde' do
    create(:setting, current_season_id: '18')
    master    = create(:player)
    secondary = create(:player)
    other     = create(:player)
    secondary.update_column(:merged_into_id, other.id)

    assert_raises(ArgumentError) { secondary.merge_into!(master, 1) }
  end

  test 'merge_into! wirft ArgumentError wenn Master bereits zusammengeführt wurde' do
    create(:setting, current_season_id: '18')
    master    = create(:player)
    secondary = create(:player)
    other     = create(:player)
    master.update_column(:merged_into_id, other.id)

    assert_raises(ArgumentError) { secondary.merge_into!(master, 1) }
  end

  test 'merge_into! überträgt Clubs ohne Duplikate' do
    create(:setting, current_season_id: '18')
    user      = create(:user)
    master    = create(:player)
    secondary = create(:player)

    master.clubs    = [{ 'club_id' => 1, 'home_club' => true }]
    secondary.clubs = [{ 'club_id' => 1, 'home_club' => false }, { 'club_id' => 2, 'home_club' => false }]
    master.save!(validate: false)
    secondary.save!(validate: false)

    secondary.merge_into!(master, user.id)
    master.reload

    club_ids = master.clubs.map { |c| c['club_id'] }
    assert_equal [1, 2], club_ids.sort, 'Clubs sollen zusammengeführt werden, club_id 1 darf nur einmal vorkommen'
  end

  test 'merge_into! überträgt Lizenzen ohne Duplikate nach team_id' do
    create(:setting, current_season_id: '18')
    user      = create(:user)
    league    = create(:league, :current_season)
    team1     = create(:team, league: league)
    team2     = create(:team, league: league)
    master    = create(:player, with_licenses: [{ team: team1, status: License::APPROVED }])
    secondary = create(:player, with_licenses: [
      { team: team1, status: License::APPROVED },
      { team: team2, status: License::APPROVED }
    ])

    secondary.merge_into!(master, user.id)
    master.reload

    team_ids = master.licenses.map { |l| l['team_id'] }
    assert_equal 2, team_ids.uniq.size, 'Lizenzen sollen zusammengeführt sein; team1 darf nur einmal vorkommen'
    assert_includes team_ids, team2.id
  end

  test 'merge_into! deaktiviert Secondary mit Grund Zusammenführung' do
    create(:setting, current_season_id: '18')
    user      = create(:user)
    master    = create(:player)
    secondary = create(:player)

    secondary.merge_into!(master, user.id)
    secondary.reload

    assert_not_nil secondary.deactivated_at
    assert_equal   'Zusammenführung', secondary.deactivation_reason
    assert_equal   master.id,         secondary.merged_into_id
  end

  test 'merge_into! schreibt Spieler-Referenzen in Spielen um' do
    create(:setting, current_season_id: '18')
    user      = create(:user)
    master    = create(:player)
    secondary = create(:player)

    game = Game.new(
      players: { 'home' => [{ 'player_id' => secondary.id, 'number' => 10 }], 'guest' => [] },
      events: []
    )
    game.save!(validate: false)

    secondary.merge_into!(master, user.id)
    game.reload

    assert_equal master.id, game.players['home'].first['player_id'],
                 'player_id im Spiel soll auf Master umgeschrieben sein'
  end

  test 'merge_into! schreibt awards und Legacy-starting_players-Array um' do
    create(:setting, current_season_id: '18')
    user      = create(:user)
    master    = create(:player)
    secondary = create(:player)

    game = Game.new(
      players: { 'home' => [{ 'player_id' => secondary.id, 'trikot_number' => 7 }], 'guest' => [] },
      # Legacy-Array-Format
      starting_players: { 'home' => [{ 'position' => 'goal', 'player_id' => secondary.id }], 'guest' => [] },
      awards: { 'home' => { 'mvp' => secondary.id }, 'guest' => {} },
      events: []
    )
    game.save!(validate: false)

    secondary.merge_into!(master, user.id)
    game.reload

    assert_equal master.id, game.players['home'].first['player_id']
    assert_equal master.id, game.starting_players['home'].first['player_id']
    assert_equal master.id, game.awards['home']['mvp']
  end

  test 'merge_into! haengt Transfers auf den Master um' do
    user      = create(:user)
    master    = create(:player)
    secondary = create(:player)
    transfer  = Transfer.new(player_id: secondary.id)
    transfer.save!(validate: false)

    secondary.merge_into!(master, user.id)

    assert_equal master.id, transfer.reload.player_id
  end

  test 'merge_into! fuehrt Lizenz-History bei gleichem Team+Saison zusammen' do
    league = create(:league, :current_season)
    team   = create(:team, league:)
    user   = create(:user)

    master = create(:player, with_licenses: [
      { team:, status: License::REQUESTED, created_at: 3.days.ago.iso8601 }
    ])
    secondary = create(:player, with_licenses: [
      { team:, status: License::APPROVED, created_at: 2.days.ago.iso8601 }
    ])

    secondary.merge_into!(master, user.id)
    master.reload

    licenses_for_team = master.licenses.select { |l| l['team_id'] == team.id }
    assert_equal 1, licenses_for_team.size, 'gleiche Team+Saison-Lizenz nicht dupliziert'
    status_ids = licenses_for_team.first['history'].map { |h| h['license_status_id'] }
    assert_includes status_ids, License::REQUESTED
    assert_includes status_ids, License::APPROVED
  end

  test 'merge_into! haelt Lizenzen unterschiedlicher Saisons desselben Teams getrennt' do
    league = create(:league, :current_season)
    team   = create(:team, league:)
    user   = create(:user)

    master    = create(:player, with_licenses: [{ team:, season_id: 17 }])
    secondary = create(:player, with_licenses: [{ team:, season_id: 18 }])

    secondary.merge_into!(master, user.id)
    master.reload

    assert_equal 2, master.licenses.count { |l| l['team_id'] == team.id },
                 'unterschiedliche Saisons desselben Teams bleiben getrennte Lizenzen'
  end

  test 'merge_into! haengt nicht-aktive und aktive Transfer-Anfragen auf den Master um' do
    user      = create(:user)
    master    = create(:player)
    secondary = create(:player)
    approved  = build_transfer_request(player: secondary, status: 'approved')
    approved.save!(validate: false)
    active = build_transfer_request(player: secondary, status: 'pending_lv')
    active.save!(validate: false)

    skipped = secondary.merge_into!(master, user.id)

    assert_empty skipped
    assert_equal master.id, approved.reload.player_id
    assert_equal master.id, active.reload.player_id
  end

  test 'merge_into! laesst aktive Transfer-Anfrage bei Kollision am Zweitprofil und meldet sie' do
    user       = create(:user)
    master     = create(:player)
    secondary  = create(:player)
    master_tr  = build_transfer_request(player: master, status: 'pending_lv')
    master_tr.save!(validate: false)
    sec_tr = build_transfer_request(player: secondary, status: 'pending_lv')
    sec_tr.save!(validate: false)

    skipped = secondary.merge_into!(master, user.id)

    assert_equal secondary.id, sec_tr.reload.player_id, 'kollidierender aktiver Antrag bleibt am Zweitprofil'
    assert_equal master.id,    master_tr.reload.player_id
    assert_includes skipped, { type: 'transfer_request', id: sec_tr.id }
  end

  test 'merge_into! haengt Lizenzdokumente um und laesst Duplikate am Zweitprofil' do
    user      = create(:user)
    master    = create(:player)
    secondary = create(:player)
    build_license_document(player: master,    license_id: 'L1', document_type: 'pass')
    dup      = build_license_document(player: secondary, license_id: 'L1', document_type: 'pass')
    distinct = build_license_document(player: secondary, license_id: 'L2', document_type: 'pass')

    skipped = secondary.merge_into!(master, user.id)

    assert_equal master.id,    distinct.reload.player_id
    assert_equal secondary.id, dup.reload.player_id, 'identisches Dokument bleibt am Zweitprofil'
    assert_includes skipped, { type: 'license_document', id: dup.id }
  end

  test 'merge_into! haengt Sperren auf den Master um' do
    user      = create(:user)
    master    = create(:player)
    secondary = create(:player)
    suspension = PlayerSuspension.new(player: secondary, valid_from: Date.current, valid_until: Date.current + 7)
    suspension.save!(validate: false)

    secondary.merge_into!(master, user.id)

    assert_equal master.id, suspension.reload.player_id
  end

  test 'merge_into! bevorzugt echte security_id gegenueber Platzhalter des Masters' do
    user      = create(:user)
    master    = create(:player, security_id: Player::PLACEHOLDER_SECURITY_ID)
    secondary = create(:player, security_id: 'echte-uuid-123')

    secondary.merge_into!(master, user.id)

    assert_equal 'echte-uuid-123', master.reload.security_id
  end

  test 'merge_into! verweigert Merge wenn beide Spieler im selben Spiel stehen' do
    user      = create(:user)
    master    = create(:player)
    secondary = create(:player)
    game = Game.new(
      players: { 'home' => [{ 'player_id' => master.id }, { 'player_id' => secondary.id }], 'guest' => [] },
      events: []
    )
    game.save!(validate: false)

    assert_raises(ArgumentError) { secondary.merge_into!(master, user.id) }
  end

  # ---------------------------------------------------------------------------
  # Player.find_by_team_ids – Batch-Laden statt N+1 (Issue #26)
  # ---------------------------------------------------------------------------

  test 'find_by_team_ids gruppiert Spieler je Team' do
    league = create(:league, :current_season)
    team_a = create(:team, league:)
    team_b = create(:team, league:)

    p1 = create(:player, last_name: 'Aaa', with_licenses: [{ team: team_a }])
    p2 = create(:player, last_name: 'Bbb', with_licenses: [{ team: team_a }, { team: team_b }])

    result = Player.find_by_team_ids([team_a.id, team_b.id])

    assert_equal [p1.id, p2.id].sort, result[team_a.id].map(&:id).sort
    assert_equal [p2.id], result[team_b.id].map(&:id)
  end

  test 'find_by_team_ids belegt jeden angefragten Team-Key (auch ohne Spieler)' do
    league = create(:league, :current_season)
    team   = create(:team, league:)

    result = Player.find_by_team_ids([team.id])
    assert_equal [], result[team.id]
  end

  test 'find_by_team_ids fuehrt fuer viele Teams nur eine Query aus' do
    league = create(:league, :current_season)
    teams = Array.new(5) { create(:team, league:) }
    teams.each { |t| create(:player, with_licenses: [{ team: t }]) }

    queries = capture_player_sql { Player.find_by_team_ids(teams.map(&:id)) }
    assert_equal 1, queries.size,
                 "Erwartet genau eine Query, war: #{queries.size}\n#{queries.join("\n")}"
  end

  # reactivate! nahm bisher jede Zugehoerigkeit mit demselben valid_set_by wieder auf.
  # Ein Zweitspielrecht, das vor einem Jahr ablief und nur zufaellig von derselben
  # Person eingetragen wurde, kam damit unbefristet zurueck – der Verein hatte danach
  # eine Mitgliedschaft, die er nie hatte. Nur die Zugehoerigkeit, die diese
  # Deaktivierung geschlossen hat, darf wieder aufgehen.
  test 'reactivate! oeffnet nur die von der Deaktivierung geschlossene Zugehoerigkeit' do
    heim = create(:club)
    zweit = create(:club)
    user_id = 4711
    abgelaufen_am = 1.year.ago.iso8601

    player = create(:player, clubs: [
      { 'club_id' => heim.id, 'home_club' => true },
      { 'club_id' => zweit.id, 'home_club' => false,
        'valid_until' => abgelaufen_am, 'valid_set_by' => user_id }
    ])
    player.deactivate!(user_id, reason: 'Karriereende')
    player.reactivate!

    heim_eintrag  = player.clubs.find { |c| c['club_id'] == heim.id }
    zweit_eintrag = player.clubs.find { |c| c['club_id'] == zweit.id }

    assert_nil heim_eintrag['valid_until'], 'Heimatverein muss wieder offen sein'
    assert_equal abgelaufen_am, zweit_eintrag['valid_until'],
                 'abgelaufenes Zweitspielrecht darf nicht wieder geoeffnet werden'
    refute_includes zweit.players.map(&:id), player.id
  end

  # Gegenstueck in die andere Richtung: ein Zweitspielrecht, das erst nach der
  # Deaktivierung angelegt wurde, laeuft in der Zukunft ab und gehoert damit ebenso
  # wenig zur Deaktivierung. Ohne beidseitiges Zeitfenster nahm reactivate! ihm die
  # Befristung und der Verein hatte eine unbefristete Mitgliedschaft.
  test 'reactivate! laesst ein nach der Deaktivierung angelegtes Zweitspielrecht befristet' do
    heim = create(:club)
    zweit = create(:club)
    user_id = 4711
    laeuft_bis = 1.year.from_now.iso8601

    player = create(:player, clubs: [{ 'club_id' => heim.id, 'home_club' => true }])
    player.deactivate!(user_id, reason: 'Temporäre Pause')
    player.clubs << { 'club_id' => zweit.id, 'home_club' => false,
                      'valid_until' => laeuft_bis, 'valid_set_by' => user_id }
    player.save!(validate: false)

    player.reactivate!

    zweit_eintrag = player.clubs.find { |c| c['club_id'] == zweit.id }
    assert_equal laeuft_bis, zweit_eintrag['valid_until'],
                 'Befristung des spaeter angelegten Zweitspielrechts muss bleiben'
  end

  # Ein laufendes Zweitspielrecht hat ein Enddatum in der Zukunft. deactivate! zieht es
  # auf "jetzt" vor, reactivate! nahm es danach ganz weg – aus der Befristung wurde
  # damit eine unbefristete Mitgliedschaft. Das Datum (und der Eintragende) muessen den
  # Zyklus ueberleben.
  test 'deactivate!/reactivate! erhaelt die Befristung eines laufenden Zweitspielrechts' do
    heim = create(:club)
    zweit = create(:club)
    eingetragen_von = 99
    laeuft_bis = 3.months.from_now.iso8601

    player = create(:player, clubs: [
      { 'club_id' => heim.id, 'home_club' => true },
      { 'club_id' => zweit.id, 'home_club' => false,
        'valid_until' => laeuft_bis, 'valid_set_by' => eingetragen_von }
    ])
    legacy_deactivate!(player, 4711, reason: 'Temporäre Pause')
    player.reactivate!

    zweit_eintrag = player.clubs.find { |c| c['club_id'] == zweit.id }
    assert_equal laeuft_bis, zweit_eintrag['valid_until'], 'Enddatum muss zurueckkommen'
    assert_equal eingetragen_von, zweit_eintrag['valid_set_by'], 'urspruenglicher Eintragender muss zurueckkommen'
    refute zweit_eintrag.key?(Player::VALID_BEFORE_DEACTIVATION), 'Sicherung muss aufgeraeumt sein'

    # Der Heimatverein war unbefristet und bleibt es.
    heim_eintrag = player.clubs.find { |c| c['club_id'] == heim.id }
    assert_nil heim_eintrag['valid_until']
    refute heim_eintrag.key?(Player::VALID_BEFORE_DEACTIVATION)

    # Zweiter Zyklus: die Sicherung wird neu geschrieben, nicht mit dem vorgezogenen
    # Datum ueberschrieben.
    legacy_deactivate!(player, 4711, reason: 'Temporäre Pause')
    player.reactivate!
    assert_equal laeuft_bis, player.clubs.find { |c| c['club_id'] == zweit.id }['valid_until']
  end

  # Der echte Ablauf sind zwei HTTP-Requests mit einem Neuladen aus der DB dazwischen.
  # Genau darauf beruht die Sicherung: der Wert muss die JSONB-Serialisierung
  # unveraendert ueberleben, sonst passt das zurueckgeschriebene Datum nicht mehr zu
  # dem, was andere Stellen als Zeichenkette vergleichen.
  test 'gesicherte Befristung uebersteht das Speichern zwischen Deaktivieren und Reaktivieren' do
    club = create(:club)
    laeuft_bis = 3.months.from_now.iso8601
    player = create(:player, clubs: [{ 'club_id' => club.id, 'home_club' => false,
                                       'valid_until' => laeuft_bis, 'valid_set_by' => 99 }])

    legacy_deactivate!(Player.find(player.id), 4711, reason: 'Temporäre Pause')
    Player.find(player.id).reactivate!

    eintrag = Player.find(player.id).clubs.first
    assert_equal laeuft_bis, eintrag['valid_until']
    assert_equal 99, eintrag['valid_set_by']
    refute eintrag.key?(Player::VALID_BEFORE_DEACTIVATION)
  end

  # Eine Sicherung darf nur den Stand der aktuellen Deaktivierung abbilden. Bleibt eine
  # aeltere liegen – zweimal deaktiviert ohne Reaktivierung, oder per merge_into! von
  # einer deaktivierten Dublette mitgekommen –, legte reactivate! das alte Enddatum auf
  # eine Zugehoerigkeit, die unbefristet war.
  test 'das Schliessen der Zugehoerigkeiten raeumt eine veraltete Sicherung ab' do
    club = create(:club)
    player = create(:player, clubs: [
      { 'club_id' => club.id, 'home_club' => true,
        Player::VALID_BEFORE_DEACTIVATION => { 'valid_until' => 2.months.ago.iso8601,
                                               'valid_set_by' => 99 } }
    ])

    legacy_deactivate!(player, 4711, reason: 'Karriereende')
    refute player.clubs.first.key?(Player::VALID_BEFORE_DEACTIVATION),
           'veraltete Sicherung muss beim Schliessen der Zugehoerigkeit verschwinden'

    player.reactivate!
    assert_nil player.clubs.first['valid_until'],
               'unbefristete Zugehoerigkeit darf kein fremdes Enddatum bekommen'
    assert_includes club.players.map(&:id), player.id
  end

  # Profile, die vor dieser Aenderung deaktiviert wurden, haben keine Sicherung am
  # Eintrag. Fuer sie bleibt es beim bisherigen Verhalten: die Zugehoerigkeit geht
  # unbefristet wieder auf, statt dass die Reaktivierung scheitert.
  test 'reactivate! ohne gesicherte Befristung oeffnet die Zugehoerigkeit unbefristet' do
    club = create(:club)
    player = create(:player, clubs: [{ 'club_id' => club.id, 'home_club' => false,
                                       'valid_until' => 3.months.from_now.iso8601, 'valid_set_by' => 99 }])
    legacy_deactivate!(player, 4711, reason: 'Temporäre Pause')

    # Altdaten-Zustand herstellen: Sicherung entfernen, vorgezogenes Ende behalten.
    player.clubs.each { |c| c.delete(Player::VALID_BEFORE_DEACTIVATION) }
    player.save!(validate: false)

    player.reactivate!

    assert_nil player.clubs.first['valid_until']
    assert_includes club.players.map(&:id), player.id
  end

  private

  def build_license_document(attrs = {})
    doc = LicenseDocument.new({ license_id: 'L1', document_type: 'pass' }.merge(attrs))
    doc.save!(validate: false)
    doc
  end

  def build_transfer_request(attrs = {})
    TransferRequest.new({
      requesting_club: create(:club),
      former_club:     create(:club),
      created_by:      create(:user).id,
      season_id:       18,
      request_type:    'transfer'
    }.merge(attrs))
  end

  def capture_player_sql
    sqls = []
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
      next if payload[:name] == 'SCHEMA'
      next if payload[:sql] =~ /^\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i

      sqls << payload[:sql]
    end
    yield
    sqls
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  # --- home_club: Boolean-Cast auf home_club --------------------------------
  #
  # In Altdaten liegt das Flag als String. `'false'` und `'f'` sind truthy, zählten
  # also als Heimat und bestimmten damit den zuständigen Spielbetrieb
  # (`sbk_can_access_player?`) — in beide Richtungen falsch.

  test 'home_club ignoriert Zugehoerigkeiten mit home_club als String false' do
    gast = create(:club)
    player = create(:player, clubs: [{ 'club_id' => gast.id, 'home_club' => 'false' }])

    assert_nil player.home_club(Date.current), "'false' ist keine Heimat"
    assert_empty player.home_club_hash(Date.current)
  end

  test 'home_club nimmt den echten Heimatverein neben einem Gast-Eintrag mit f' do
    heimat = create(:club)
    gast = create(:club)
    player = create(:player, clubs: [
      { 'club_id' => heimat.id, 'home_club' => true },
      { 'club_id' => gast.id, 'home_club' => 'f' }
    ])

    assert_equal heimat.id, player.home_club(Date.current)&.id,
                 'der Gast-Eintrag darf den Heimatverein nicht verdrängen'
  end

  test 'home_club akzeptiert wahre Flag-Schreibweisen aus Altdaten' do
    ['true', 't', 1].each do |flag|
      club = create(:club)
      player = create(:player, clubs: [{ 'club_id' => club.id, 'home_club' => flag }])

      assert_equal club.id, player.home_club(Date.current)&.id, "#{flag.inspect} sollte Heimat sein"
    end
  end
end
