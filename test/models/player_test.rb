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

  test 'deactivate! setzt valid_until auf allen Clubs ohne Ablaufdatum' do
    create(:setting, current_season_id: '18')
    user = create(:user)
    player = create(:player)
    player.clubs = [
      { 'club_id' => 1, 'home_club' => true },
      { 'club_id' => 2, 'home_club' => false }
    ]
    player.save!(validate: false)

    player.deactivate!(user.id)
    player.reload

    player.clubs.each do |c|
      assert_not_nil c['valid_until'], "club_id #{c['club_id']} sollte valid_until haben"
      assert_equal user.id, c['valid_set_by']
    end
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

  test 'deactivate! hängt DELETED-Eintrag an APPROVED-Lizenzen an' do
    create(:setting, current_season_id: '18')
    user   = create(:user)
    league = create(:league, :current_season)
    team   = create(:team, league: league)
    player = create(:player, with_licenses: [
      { team: team, status: License::APPROVED }
    ])

    player.deactivate!(user.id, reason: 'Karriereende')
    player.reload

    last = player.licenses.first['history'].last
    assert_equal License::DELETED, last['license_status_id'].to_i
    assert_equal 'Karriereende',   last['reason']
    assert_equal user.id,          last['created_by']
  end

  test 'deactivate! hängt DELETED-Eintrag an REQUESTED-Lizenzen an' do
    create(:setting, current_season_id: '18')
    user   = create(:user)
    league = create(:league, :current_season)
    team   = create(:team, league: league)
    player = create(:player, with_licenses: [
      { team: team, status: License::REQUESTED }
    ])

    player.deactivate!(user.id)
    player.reload

    last = player.licenses.first['history'].last
    assert_equal License::DELETED, last['license_status_id'].to_i
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

  test 'deactivate! ohne reason verwendet Standard-Grund Deaktiviert' do
    create(:setting, current_season_id: '18')
    user   = create(:user)
    league = create(:league, :current_season)
    team   = create(:team, league: league)
    player = create(:player, with_licenses: [
      { team: team, status: License::APPROVED }
    ])

    player.deactivate!(user.id)
    player.reload

    last = player.licenses.first['history'].last
    assert_equal 'Deaktiviert', last['reason']
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

  test 'reactivate! stellt valid_until auf Clubs wieder her, die durch deactivate! gesetzt wurden' do
    create(:setting, current_season_id: '18')
    user   = create(:user)
    player = create(:player)
    player.clubs = [{ 'club_id' => 1, 'home_club' => true }]
    player.save!(validate: false)

    player.deactivate!(user.id)
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

    player.deactivate!(user.id)
    player.reload
    player.reactivate!
    player.reload

    # valid_set_by gehört other — reactivate! darf diesen Club nicht anfassen
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

    player.deactivate!(user.id, reason: 'Deaktiviert')
    player.reload
    original_size = player.licenses.first['history'].size

    player.reactivate!
    player.reload

    assert_equal original_size - 1, player.licenses.first['history'].size,
                 'DELETED-Eintrag mit System-Grund soll nach reactivate! entfernt sein'
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
  # Player#merge_into!(master, user_id)
  # ---------------------------------------------------------------------------

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

  private

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
end
