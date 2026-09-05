require 'test_helper'

# Geltungsbereich und Spielezaehler der Spielersperre (#604) sowie der
# wirksame Status in den Lizenzlisten (#605).
class PlayerSuspensionScopeTest < ActiveSupport::TestCase
  setup do
    create(:setting, current_season_id: '18')
    @user = create(:user)
    @go = create(:game_operation)
    @liga    = league_with(modus: 'league')
    @playoff = league_with(modus: 'playoff')
    @pokal   = league_with(modus: 'cup')
    @dm      = league_with(modus: 'champ')
    @team = create(:team, league: @liga, cup_leagues: [@pokal.id])
    @gegner = create(:team, league: @liga)
  end

  def league_with(modus:, age_group: 'Herren', field_size: 'GF')
    create(:league, :current_season, game_operation: @go, league_modus: modus,
                                     age_group:, field_size:, league_class_id: 'rl')
  end

  def licensed_player(team: nil, status: License::APPROVED)
    create(:player, with_licenses: [{ team: team || @team, status: }])
  end

  def current_status(player, team)
    license = player.licenses.find { |l| l['team_id'].to_i == team.id }
    license['history'].max_by { |h| h['created_at'].to_s }['license_status_id'].to_i
  end

  def closed_game(league:, date: Date.current, home: nil, guest: nil)
    day = create(:game_day, league:, date:)
    create(:game, game_day: day, home_team: home || @team, guest_team: guest || @gegner,
                  game_status: 'match_record_closed')
  end

  # ---------------------------------------------------------------------------
  # Geltungsbereich
  # ---------------------------------------------------------------------------

  test 'Wettbewerbssperre gilt in Liga und Playoffs, aber nicht im Pokal' do
    player = licensed_player
    suspension = player.suspend!(user_id: @user.id, valid_until: Date.current + 30,
                                 scope: { kind: PlayerSuspension::SCOPE_COMPETITION, league: @liga,
                                          competition_groups: [League::GROUP_LIGA] })

    assert suspension.covers_league?(@liga)
    assert suspension.covers_league?(@playoff), 'Playoffs sind die Fortsetzung der Liga'
    assert_not suspension.covers_league?(@pokal), 'der Pokal wird separat geführt'
    assert_not suspension.covers_league?(@dm), 'DM ist eine eigene Gruppe und war nicht ausgewählt'
  end

  test 'Vorbelegung des Geltungsbereichs deckt Ligaspielbetrieb und DM, nicht den Pokal' do
    player = licensed_player
    suspension = player.suspend!(user_id: @user.id, valid_until: Date.current + 30,
                                 scope: { kind: PlayerSuspension::SCOPE_COMPETITION, league: @liga })

    assert_equal PlayerSuspension::DEFAULT_COMPETITION_GROUPS, suspension.competition_groups
    assert suspension.covers_league?(@liga)
    assert suspension.covers_league?(@dm)
    assert_not suspension.covers_league?(@pokal)
  end

  test 'Wettbewerbssperre greift nicht in einer anderen Altersklasse oder Feldgröße' do
    player = licensed_player
    suspension = player.suspend!(user_id: @user.id, valid_until: Date.current + 30,
                                 scope: { kind: PlayerSuspension::SCOPE_COMPETITION, league: @liga })

    assert_not suspension.covers_league?(league_with(modus: 'league', age_group: 'U17 Junioren'))
    assert_not suspension.covers_league?(league_with(modus: 'league', field_size: 'KF'))
  end

  test 'fehlt der Liga die Altersklasse, greift die Sperre trotzdem' do
    # Sichere Richtung: An Playoff-Ligen bleibt das Feld oft leer, und ein
    # gesperrter Spieler, der deshalb auflaufen darf, wäre der schwerere Fehler.
    player = licensed_player
    suspension = player.suspend!(user_id: @user.id, valid_until: Date.current + 30,
                                 scope: { kind: PlayerSuspension::SCOPE_COMPETITION, league: @liga })
    ohne_angabe = create(:league, :current_season, game_operation: @go, league_modus: 'playoff',
                                                   age_group: nil, field_size: nil)

    assert suspension.covers_league?(ohne_angabe)
  end

  test 'fehlt der Liga die Altersklasse, zählt die der Hauptrunde' do
    player = licensed_player
    suspension = player.suspend!(user_id: @user.id, valid_until: Date.current + 30,
                                 scope: { kind: PlayerSuspension::SCOPE_COMPETITION, league: @liga })
    fremde_hauptrunde = league_with(modus: 'league', age_group: 'U17 Junioren')
    playoff = create(:league, :current_season, game_operation: @go, league_modus: 'playoff',
                                               age_group: nil, field_size: nil,
                                               league_id_preround: fremde_hauptrunde.id)

    assert_not suspension.covers_league?(playoff), 'erbt U17 von der Hauptrunde'
  end

  test 'Ligasperre gilt nur in dieser einen Liga' do
    player = licensed_player
    suspension = player.suspend!(user_id: @user.id, valid_until: Date.current + 30,
                                 scope: { kind: PlayerSuspension::SCOPE_LEAGUE, league: @liga })

    assert suspension.covers_league?(@liga)
    assert_not suspension.covers_league?(@playoff)
  end

  test 'Team-Sperre gilt in jedem Wettbewerb dieser Mannschaft' do
    # Eine Lizenz deckt über cup_leagues auch die Pokalspiele der Mannschaft.
    player = licensed_player
    suspension = player.suspend!(user_id: @user.id, team_id: @team.id, valid_until: Date.current + 30)

    assert suspension.covers_team?(@team)
    assert suspension.covers_license_in?(@pokal, @team)
    assert_not suspension.covers_team?(@gegner)
  end

  test 'spielerweite Sperre gilt überall und blockiert Anträge' do
    player = licensed_player
    suspension = player.suspend!(user_id: @user.id, valid_until: Date.current + 30)

    assert suspension.player_wide?
    assert suspension.covers_league?(@pokal)
    assert player.application_blocked?
  end

  test 'Wettbewerbssperre blockiert nicht jeden Lizenzantrag' do
    player = licensed_player
    player.suspend!(user_id: @user.id, valid_until: Date.current + 30,
                    scope: { kind: PlayerSuspension::SCOPE_COMPETITION, league: @liga })

    assert_not player.application_blocked?, 'nur der Geltungsbereich "alles" blockiert alle Anträge'
    assert player.suspended_for_team?(@team.id), 'in der gesperrten Liga aber schon'
  end

  # ---------------------------------------------------------------------------
  # Status in der Lizenzhistorie
  # ---------------------------------------------------------------------------

  test 'Wettbewerbssperre lässt den Lizenzstatus unberührt' do
    # Der Status kann eine wettbewerbsbezogene Sperre nicht abbilden: Dieselbe
    # Lizenz steht in der Liste der Liga und in der des Pokals.
    player = licensed_player
    suspension = player.suspend!(user_id: @user.id, valid_until: Date.current + 30,
                                 scope: { kind: PlayerSuspension::SCOPE_COMPETITION, league: @liga })

    assert_equal License::APPROVED, current_status(player, @team)
    assert_empty suspension.affected_licenses
  end

  test 'Team-Sperre setzt die Lizenz weiterhin auf gesperrt' do
    player = licensed_player
    suspension = player.suspend!(user_id: @user.id, team_id: @team.id, valid_until: Date.current + 30)

    assert_equal License::SUSPENDED, current_status(player, @team)
    assert_equal 1, suspension.affected_licenses.size
  end

  # ---------------------------------------------------------------------------
  # Dauer und Validierung
  # ---------------------------------------------------------------------------

  test 'eine Sperre ohne Enddatum und ohne Spiele wird abgelehnt' do
    player = licensed_player
    error = assert_raises(ActiveRecord::RecordInvalid) do
      player.suspend!(user_id: @user.id, team_id: @team.id)
    end

    assert_match(/Enddatum oder eine Anzahl von Spielen/, error.message)
  end

  test 'eine Sperre über Spiele braucht kein Enddatum' do
    player = licensed_player
    suspension = player.suspend!(user_id: @user.id, team_id: @team.id, games_total: 3)

    assert suspension.games_based?
    assert_nil suspension.valid_until
    assert_equal 3, suspension.remaining_games
  end

  test 'eine Wettbewerbssperre ohne ausgewählten Wettbewerb wird abgelehnt' do
    player = licensed_player
    error = assert_raises(ActiveRecord::RecordInvalid) do
      player.suspend!(user_id: @user.id, games_total: 1,
                      scope: { kind: PlayerSuspension::SCOPE_COMPETITION, league: @liga,
                               competition_groups: [] })
    end

    assert_match(/Wettbewerb/, error.message)
  end

  # ---------------------------------------------------------------------------
  # Spiele abzählen
  # ---------------------------------------------------------------------------

  test 'ein abgeschlossener Spielbericht zählt ein Spiel ab' do
    player = licensed_player
    suspension = player.suspend!(user_id: @user.id, games_total: 2,
                                 scope: { kind: PlayerSuspension::SCOPE_COMPETITION, league: @liga })

    assert_equal 1, PlayerSuspension.count_closed_game!(closed_game(league: @liga))
    assert_equal 1, suspension.reload.games_served
    assert_equal 1, suspension.remaining_games
    assert suspension.active?
  end

  test 'ein nicht abgeschlossener Spielbericht zählt nicht' do
    player = licensed_player
    suspension = player.suspend!(user_id: @user.id, games_total: 2,
                                 scope: { kind: PlayerSuspension::SCOPE_COMPETITION, league: @liga })
    day = create(:game_day, league: @liga, date: Date.current)
    offen = create(:game, game_day: day, home_team: @team, guest_team: @gegner, game_status: 'pregame')

    assert_equal 0, PlayerSuspension.count_closed_game!(offen)
    assert_equal 0, suspension.reload.games_served
  end

  test 'dasselbe Spiel zählt nicht zweimal' do
    player = licensed_player
    suspension = player.suspend!(user_id: @user.id, games_total: 3,
                                 scope: { kind: PlayerSuspension::SCOPE_COMPETITION, league: @liga })
    game = closed_game(league: @liga)

    PlayerSuspension.count_closed_game!(game)
    assert_equal 0, PlayerSuspension.count_closed_game!(game), 'erneut geschlossener Bericht zählt nicht'
    assert_equal 1, suspension.reload.games_served
  end

  test 'ein Pokalspiel zählt nicht auf eine Sperre im Ligaspielbetrieb' do
    player = licensed_player
    suspension = player.suspend!(user_id: @user.id, games_total: 2,
                                 scope: { kind: PlayerSuspension::SCOPE_COMPETITION, league: @liga,
                                          competition_groups: [League::GROUP_LIGA] })

    assert_equal 0, PlayerSuspension.count_closed_game!(closed_game(league: @pokal))
    assert_equal 0, suspension.reload.games_served
  end

  test 'ein Playoffspiel zählt auf eine Sperre im Ligaspielbetrieb' do
    player = licensed_player
    suspension = player.suspend!(user_id: @user.id, games_total: 2,
                                 scope: { kind: PlayerSuspension::SCOPE_COMPETITION, league: @liga,
                                          competition_groups: [League::GROUP_LIGA] })

    assert_equal 1, PlayerSuspension.count_closed_game!(closed_game(league: @playoff))
    assert_equal 1, suspension.reload.games_served
  end

  test 'nur Spiele zählen, für die der Spieler sonst spielberechtigt gewesen wäre' do
    player = licensed_player
    suspension = player.suspend!(user_id: @user.id, games_total: 2,
                                 scope: { kind: PlayerSuspension::SCOPE_COMPETITION, league: @liga })
    fremd_a = create(:team, league: @liga)
    fremd_b = create(:team, league: @liga)

    assert_equal 0, PlayerSuspension.count_closed_game!(closed_game(league: @liga, home: fremd_a, guest: fremd_b))
    assert_equal 0, suspension.reload.games_served
  end

  test 'ein beantragter Lizenzantrag berechtigt nicht und zählt kein Spiel ab' do
    player = licensed_player(status: License::REQUESTED)
    suspension = player.suspend!(user_id: @user.id, games_total: 2,
                                 scope: { kind: PlayerSuspension::SCOPE_COMPETITION, league: @liga })

    assert_equal 0, PlayerSuspension.count_closed_game!(closed_game(league: @liga))
    assert_equal 0, suspension.reload.games_served
  end

  test 'ein Spiel vor Beginn der Sperre zählt nicht' do
    player = licensed_player
    suspension = player.suspend!(user_id: @user.id, games_total: 2, valid_from: Date.current + 7,
                                 scope: { kind: PlayerSuspension::SCOPE_COMPETITION, league: @liga })

    assert_equal 0, PlayerSuspension.count_closed_game!(closed_game(league: @liga, date: Date.current))
    assert_equal 1, PlayerSuspension.count_closed_game!(closed_game(league: @liga, date: Date.current + 8))
    assert_equal 1, suspension.reload.games_served
  end

  test 'Erst- und Zweitlizenz am selben Wochenende zählen als zwei Spiele' do
    # Entscheidung vom 04.09.2026: Jedes Spiel zählt einzeln.
    zweitteam = create(:team, league: @playoff)
    player = create(:player, with_licenses: [
      { team: @team, status: License::APPROVED },
      { team: zweitteam, status: License::APPROVED }
    ])
    suspension = player.suspend!(user_id: @user.id, games_total: 3,
                                 scope: { kind: PlayerSuspension::SCOPE_COMPETITION, league: @liga })

    PlayerSuspension.count_closed_game!(closed_game(league: @liga))
    PlayerSuspension.count_closed_game!(closed_game(league: @playoff, home: zweitteam,
                                                    guest: create(:team, league: @playoff)))

    assert_equal 2, suspension.reload.games_served
  end

  test 'sind die Spiele abgesessen, hebt sich die Sperre auf und die Lizenz gilt wieder' do
    player = licensed_player
    suspension = player.suspend!(user_id: @user.id, team_id: @team.id, games_total: 1)
    assert_equal License::SUSPENDED, current_status(player, @team)

    PlayerSuspension.count_closed_game!(closed_game(league: @liga))

    assert_not suspension.reload.active?
    assert_equal 0, suspension.remaining_games
    assert_equal License::APPROVED, current_status(player.reload, @team)
  end

  test 'expire_due_suspensions hebt auch eine abgesessene Sperre auf' do
    player = licensed_player
    suspension = player.suspend!(user_id: @user.id, team_id: @team.id, games_total: 1)
    suspension.update_columns(games_served: 1)

    player.expire_due_suspensions!

    assert_not suspension.reload.active?
  end

  test 'eine Sperre ohne Enddatum läuft nicht ab' do
    player = licensed_player
    suspension = player.suspend!(user_id: @user.id, team_id: @team.id, games_total: 5)

    player.expire_due_suspensions!(date: Date.current + 400)

    assert suspension.reload.active?
  end

  # ---------------------------------------------------------------------------
  # Lizenzlisten (#605)
  # ---------------------------------------------------------------------------

  def status_in(league, player)
    entry = League.licenses_for([league]).fetch(league.id, [])
                  .flat_map { |t| t[:players] }
                  .find { |p| p[:id] == player.id }
    entry && entry[:team_license]
  end

  test 'eine im Ligaspielbetrieb gesperrte Lizenz steht in der Ligaliste auf gesperrt' do
    player = licensed_player
    player.suspend!(user_id: @user.id, valid_until: Date.current + 30,
                    scope: { kind: PlayerSuspension::SCOPE_COMPETITION, league: @liga,
                             competition_groups: [League::GROUP_LIGA] })

    liga_row = status_in(@liga, player)
    assert_not_nil liga_row, 'die Zeile bleibt in der Liste stehen'
    assert_equal License::SUSPENDED, liga_row[:last_status_id].to_i
    assert_equal 'gesperrt', liga_row[:last_status_code]
    assert_equal License::APPROVED, liga_row[:base_status_id].to_i
    assert_not_nil liga_row[:suspension]
  end

  test 'dieselbe Lizenz steht in der Pokalliste weiterhin auf erteilt' do
    player = licensed_player
    player.suspend!(user_id: @user.id, valid_until: Date.current + 30,
                    scope: { kind: PlayerSuspension::SCOPE_COMPETITION, league: @liga,
                             competition_groups: [League::GROUP_LIGA] })

    pokal_row = status_in(@pokal, player)
    assert_not_nil pokal_row, 'im Pokal darf der Spieler spielen'
    assert_equal License::APPROVED, pokal_row[:last_status_id].to_i
    assert_equal 'erteilt', pokal_row[:last_status_code]
    assert_nil pokal_row[:suspension]
  end

  test 'eine Team-Sperre zeigt sich in beiden Listen' do
    player = licensed_player
    player.suspend!(user_id: @user.id, team_id: @team.id, valid_until: Date.current + 30)

    assert_equal License::SUSPENDED, status_in(@liga, player)[:last_status_id].to_i
    assert_equal License::SUSPENDED, status_in(@pokal, player)[:last_status_id].to_i,
                 'die Lizenz der Mannschaft deckt auch deren Pokalspiele'
  end

  test 'die Zeile nennt Erteilungsdatum und Sperrdaten' do
    player = licensed_player
    player.suspend!(user_id: @user.id, team_id: @team.id, games_total: 3, reason: 'Tätlichkeit')

    row = status_in(@liga, player)
    assert_not_nil row[:approved_at], 'eine gesperrte Lizenz ist erteilt'
    assert_equal 3, row[:suspension][:games_total]
    assert_equal 3, row[:suspension][:remaining_games]
    assert_equal 'Tätlichkeit', row[:suspension][:reason]
  end

  test 'eine abgelehnte Lizenz bleibt aus der Liste' do
    player = licensed_player(status: License::DENIED)

    assert_nil status_in(@liga, player)
  end

  test 'eine abgelaufene Sperre zeigt wieder den Status ohne Sperre' do
    player = licensed_player
    suspension = player.suspend!(user_id: @user.id, team_id: @team.id, valid_until: Date.current + 5)
    suspension.update_columns(valid_from: Date.current - 10, valid_until: Date.current - 1)

    row = status_in(@liga, player)
    assert_equal License::APPROVED, row[:last_status_id].to_i
    assert_nil row[:suspension]
  end

  test 'scope_summary benennt den Geltungsbereich im Klartext' do
    player = licensed_player
    suspension = player.suspend!(user_id: @user.id, valid_until: Date.current + 30,
                                 scope: { kind: PlayerSuspension::SCOPE_COMPETITION, league: @liga,
                                          competition_groups: [League::GROUP_LIGA] })

    assert_equal "Herren Großfeld, Ligaspielbetrieb, #{@go.name}", suspension.scope_summary
  end
  # ---------------------------------------------------------------------------
  # Spielbetriebs-Grenze (Rueckmeldung der SBK FD vom 04.09.2026)
  # ---------------------------------------------------------------------------

  test 'Wettbewerbssperre bleibt im Spielbetrieb, aus dem sie stammt' do
    # Bundesliga und Regionalliga sind beide "Herren Grossfeld,
    # Ligaspielbetrieb". Die SBK hat ihre Weisungsbefugnis aber nur im eigenen
    # Spielbetrieb; ohne die Grenze haette eine Sperre der SBK FD still auch
    # die Ligen der Landesverbaende erfasst.
    fremder_go = create(:game_operation)
    lv_liga = create(:league, :current_season, game_operation: fremder_go, league_modus: 'league',
                                               age_group: 'Herren', field_size: 'GF')
    player = licensed_player
    suspension = player.suspend!(user_id: @user.id, valid_until: Date.current + 30,
                                 scope: { kind: PlayerSuspension::SCOPE_COMPETITION, league: @liga })

    assert_equal @go.id, suspension.game_operation_id
    assert suspension.covers_league?(@liga)
    assert_not suspension.covers_league?(lv_liga)
  end

  test 'ohne Spielbetriebs-Grenze greift die Sperre in jedem Verband' do
    fremder_go = create(:game_operation)
    lv_liga = create(:league, :current_season, game_operation: fremder_go, league_modus: 'league',
                                               age_group: 'Herren', field_size: 'GF')
    player = licensed_player
    suspension = player.suspend!(user_id: @user.id, valid_until: Date.current + 30,
                                 scope: { kind: PlayerSuspension::SCOPE_COMPETITION, league: @liga,
                                          all_game_operations: true })

    assert_nil suspension.game_operation_id
    assert suspension.covers_league?(lv_liga)
  end

  test 'ein Spiel im fremden Spielbetrieb zaehlt nicht ab' do
    fremder_go = create(:game_operation)
    lv_liga = create(:league, :current_season, game_operation: fremder_go, league_modus: 'league',
                                               age_group: 'Herren', field_size: 'GF')
    lv_team = create(:team, league: lv_liga)
    player = create(:player, with_licenses: [
      { team: @team, status: License::APPROVED },
      { team: lv_team, status: License::APPROVED }
    ])
    suspension = player.suspend!(user_id: @user.id, games_total: 3,
                                 scope: { kind: PlayerSuspension::SCOPE_COMPETITION, league: @liga })

    PlayerSuspension.count_closed_game!(closed_game(league: lv_liga, home: lv_team,
                                                    guest: create(:team, league: lv_liga)))

    assert_equal 0, suspension.reload.games_served
  end

  test 'Zweitlizenz in einer anderen Altersklasse zaehlt kein Spiel ab' do
    # Rueckmeldung der SBK FD: U13 maennlich Kleinfeld und U13 weiblich
    # Grossfeld sind zwei Wettbewerbe, keine zwei abgesessenen Spiele.
    andere_ak = league_with(modus: 'league', age_group: 'U13 Juniorinnen', field_size: 'KF')
    andere_team = create(:team, league: andere_ak)
    player = create(:player, with_licenses: [
      { team: @team, status: License::APPROVED },
      { team: andere_team, status: License::APPROVED }
    ])
    suspension = player.suspend!(user_id: @user.id, games_total: 3,
                                 scope: { kind: PlayerSuspension::SCOPE_COMPETITION, league: @liga })

    PlayerSuspension.count_closed_game!(closed_game(league: andere_ak, home: andere_team,
                                                    guest: create(:team, league: andere_ak)))
    assert_equal 0, suspension.reload.games_served

    PlayerSuspension.count_closed_game!(closed_game(league: @liga))
    assert_equal 1, suspension.reload.games_served
  end

  test 'scope_summary nennt den Spielbetrieb' do
    player = licensed_player
    suspension = player.suspend!(user_id: @user.id, valid_until: Date.current + 30,
                                 scope: { kind: PlayerSuspension::SCOPE_COMPETITION, league: @liga,
                                          competition_groups: [League::GROUP_LIGA] })

    assert_equal "Herren Großfeld, Ligaspielbetrieb, #{@go.name}", suspension.scope_summary
  end
end
