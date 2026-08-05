require 'test_helper'

class UserTest < ActiveSupport::TestCase
  ALL_GO = [1, 2, 3, 4, 5, 6, 8, 9, 10, 11].freeze

  def build_user(permissions:, teams: [])
    User.create!(
      user_name: "testuser_#{SecureRandom.hex(4)}",
      password: 'password123',
      password_confirmation: 'password123',
      permissions: permissions,
      teams: teams
    )
  end

  # ---------------------------------------------------------------------------
  # permission_hash
  # ---------------------------------------------------------------------------

  test 'permission_hash: leere Permissions ergibt leeren Hash' do
    u = build_user(permissions: [])
    assert_equal({}, u.permission_hash)
  end

  test 'permission_hash: Admin mit allen GOs ergibt [0]' do
    perms = ALL_GO.map { |go| { 'user_group_id' => 1, 'game_operation_id' => go } }
    u = build_user(permissions: perms)
    assert_equal [0], u.permission_hash[:admin]
    assert_nil u.permission_hash[:sbk]
    assert_nil u.permission_hash[:vm]
  end

  test 'permission_hash: Admin mit einzelnem GO ergibt spezifische ID' do
    u = build_user(permissions: [{ 'user_group_id' => 1, 'game_operation_id' => 2 }])
    assert_equal [2], u.permission_hash[:admin]
  end

  test 'permission_hash: SBK mit allen GOs ergibt [0]' do
    perms = ALL_GO.map { |go| { 'user_group_id' => 2, 'game_operation_id' => go } }
    u = build_user(permissions: perms)
    assert_equal [0], u.permission_hash[:sbk]
    assert_nil u.permission_hash[:admin]
  end

  test 'permission_hash: SBK für nationales GO (kein state_association_id) ergibt [0]' do
    national_go = GameOperation.create!(name: 'FD Test', short_name: 'FDT', path: 'fd-test', national: true)
    u = build_user(permissions: [{ 'user_group_id' => 2, 'game_operation_id' => national_go.id }])
    assert_equal [0], u.permission_hash[:sbk]
  end

  test 'permission_hash: RSK für nationales GO (kein state_association_id) ergibt [0]' do
    national_go = GameOperation.create!(name: 'FD RSK Test', short_name: 'FDRT', path: 'fd-rsk-test', national: true)
    u = build_user(permissions: [{ 'user_group_id' => 3, 'game_operation_id' => national_go.id }])
    assert_equal [0], u.permission_hash[:rsk]
  end

  test 'permission_hash: SBK für regionales GO (hat state_association_id) behält spezifische ID' do
    sa = StateAssociation.create!(name: 'Test LV', short_name: 'TLV')
    regional_go = GameOperation.create!(name: 'SBK Test', short_name: 'SBT', path: 'sbk-test', state_association: sa)
    u = build_user(permissions: [{ 'user_group_id' => 2, 'game_operation_id' => regional_go.id }])
    assert_equal [regional_go.id], u.permission_hash[:sbk]
  end

  test 'permission_hash: VM mit club_id ergibt club_ids-Array' do
    u = build_user(permissions: [
      { 'user_group_id' => 4, 'club_id' => 42 },
      { 'user_group_id' => 4, 'club_id' => 7 }
    ])
    assert_equal [7, 42], u.permission_hash[:vm]
  end

  test 'permission_hash: RSK mit allen GOs ergibt [0]' do
    perms = ALL_GO.map { |go| { 'user_group_id' => 3, 'game_operation_id' => go } }
    u = build_user(permissions: perms)
    assert_equal [0], u.permission_hash[:rsk]
  end

  test 'permission_hash: RSK mit spezifischen GOs ergibt sortiertes Array' do
    u = build_user(permissions: [
      { 'user_group_id' => 3, 'game_operation_id' => 5 },
      { 'user_group_id' => 3, 'game_operation_id' => 2 }
    ])
    assert_equal [2, 5], u.permission_hash[:rsk]
  end

  test 'permission_hash: Schiri-Rolle erzeugt keinen Hash-Eintrag' do
    u = build_user(permissions: [{ 'user_group_id' => 6 }])
    assert_equal({}, u.permission_hash)
  end

  test 'permission_hash: Mehrere Rollen gleichzeitig werden korrekt getrennt' do
    u = build_user(permissions: [
      { 'user_group_id' => 1, 'game_operation_id' => 1 },
      { 'user_group_id' => 4, 'club_id' => 10 }
    ])
    ph = u.permission_hash
    assert_equal [1], ph[:admin]
    assert_equal [10], ph[:vm]
    assert_nil ph[:sbk]
  end

  # ---------------------------------------------------------------------------
  # permissions_items
  # ---------------------------------------------------------------------------

  test 'permissions_items: Admin bekommt alle admin-gebundenen Menüeinträge' do
    perms = ALL_GO.map { |go| { 'user_group_id' => 1, 'game_operation_id' => go } }
    u = build_user(permissions: perms)
    items = u.permissions_items

    assert items[:menu_item_league_admin]
    assert items[:menu_item_referee_admin]
    assert items[:menu_item_state_association_admin]
    assert items[:menu_item_api_key_admin]
    assert items[:menu_item_season_admin]
    assert items[:admin], 'Admin muss den expliziten admin-Boolean für das Frontend bekommen'
    assert_not items[:login_blocked]
  end

  test 'permissions_items: VM bekommt vm-spezifische Einträge, nicht admin-Einträge' do
    u = build_user(permissions: [{ 'user_group_id' => 4, 'club_id' => 5 }])
    items = u.permissions_items

    assert items[:menu_item_referee_vm]
    assert items[:menu_item_player_admin_vm]
    assert items[:menu_item_user_vm]
    assert_not items[:menu_item_league_admin]
    assert_not items[:menu_item_state_association_admin]
    assert_not items[:menu_item_referee_admin]
    assert_not items[:admin], 'VM darf den admin-Boolean nicht bekommen'
    assert_not items[:login_blocked]
  end

  test 'permissions_items: RSK bekommt Schiri-Admin, aber KEINE Ansetzungen' do
    u = build_user(permissions: [{ 'user_group_id' => 3, 'game_operation_id' => 1 }])
    items = u.permissions_items

    assert items[:menu_item_referee_admin]
    # Ansetzungen sind eine eigene Rolle (Ansetzer) – die reine RSK sieht sie nicht.
    assert_not items[:menu_item_referee_assignments]
    assert_not items[:menu_item_league_admin]
    # RSK darf seinen Landesverband NICHT verwalten (nur SBK).
    assert_not items[:menu_item_state_association_sbk]
  end

  test 'permissions_items: Ansetzer bekommt Ansetzungen und Schiri-Admin' do
    sa = create(:state_association, referee_assignment_enabled: true)
    go = create(:game_operation, state_association: sa)
    u = build_user(permissions: [{ 'user_group_id' => 7, 'game_operation_id' => go.id }])
    items = u.permissions_items

    assert items[:menu_item_referee_assignments]
    assert items[:menu_item_referee_availability]
    # Ansetzer braucht (eingeschränkten) Lesezugriff auf die Schiedsrichterdaten.
    assert items[:menu_item_referee_admin]
    assert items[:referee_edit_restricted]
    assert_not items[:referee_can_create]
    assert_not items[:menu_item_league_admin]
  end

  test 'permissions_items: Ansetzer ohne freigeschalteten Landesverband sieht keine Ansetzungen' do
    sa = create(:state_association, referee_assignment_enabled: false)
    go = create(:game_operation, state_association: sa)
    u = build_user(permissions: [{ 'user_group_id' => 7, 'game_operation_id' => go.id }])
    items = u.permissions_items

    assert_not items[:menu_item_referee_assignments]
    assert_not items[:menu_item_referee_availability]
    # Lesezugriff auf die Schiedsrichterdaten bleibt davon unberührt.
    assert items[:menu_item_referee_admin]
  end

  # ---------------------------------------------------------------------------
  # menu_item_team_game_days (Meine Auswärtsspieltage)
  # ---------------------------------------------------------------------------

  def checklist_league(with_checklist:)
    create(:setting, current_season_id: '18')
    sa = create(:state_association)
    sa.checklist_items.create!(question: 'War die Halle rechtzeitig geöffnet?') if with_checklist
    create(:league, game_operation: create(:game_operation, state_association: sa))
  end

  test 'permissions_items: TM sieht Auswärtsspieltage nur mit Spieltagscheckliste im Landesverband' do
    league = checklist_league(with_checklist: true)
    team = create(:team, league: league)
    u = build_user(permissions: [{ 'user_group_id' => 5, 'game_operation_id' => league.game_operation_id }],
                   teams: [team.id])

    assert u.permissions_items[:menu_item_team_game_days]
  end

  test 'permissions_items: TM ohne Spieltagscheckliste sieht die Auswärtsspieltage nicht' do
    league = checklist_league(with_checklist: false)
    team = create(:team, league: league)
    u = build_user(permissions: [{ 'user_group_id' => 5, 'game_operation_id' => league.game_operation_id }],
                   teams: [team.id])

    assert_not u.permissions_items[:menu_item_team_game_days]
  end

  test 'permissions_items: Zugriff auf die Auswärtsspieltage bleibt ohne Checkliste erlaubt' do
    # Der Berechtigungs-Hash liegt nach dem Login im localStorage. Wird die erste
    # Checklistenfrage mitten in der Saison angelegt, muss die Seite für bereits
    # angemeldete TM/VM erreichbar bleiben (Bestätigungsfenster nur 48 Stunden).
    league = checklist_league(with_checklist: false)
    team = create(:team, league: league)
    tm = build_user(permissions: [{ 'user_group_id' => 5, 'game_operation_id' => league.game_operation_id }],
                    teams: [team.id])
    vm = build_user(permissions: [{ 'user_group_id' => 4, 'club_id' => create(:club).id }])

    assert_not tm.permissions_items[:menu_item_team_game_days]
    assert tm.permissions_items[:page_team_game_days]
    assert vm.permissions_items[:page_team_game_days]
  end

  test 'permissions_items: ohne TM-/VM-Rolle kein Zugriff auf die Auswärtsspieltage' do
    u = build_user(permissions: [{ 'user_group_id' => 2, 'game_operation_id' => 1 }])

    assert_not u.permissions_items[:page_team_game_days]
  end

  test 'permissions_items: VM sieht Auswärtsspieltage über die Teams des eigenen Vereins' do
    league = checklist_league(with_checklist: true)
    club = create(:club)
    create(:team, league: league, club: club)
    u = build_user(permissions: [{ 'user_group_id' => 4, 'club_id' => club.id }])

    assert u.permissions_items[:menu_item_team_game_days]
  end

  test 'permissions_items: VM mit Teams nur in Ligen ohne Checkliste sieht die Auswärtsspieltage nicht' do
    league = checklist_league(with_checklist: false)
    club = create(:club)
    create(:team, league: league, club: club)
    # Zweiter Landesverband MIT Checkliste, aber ohne Team dieses Vereins.
    other_sa = create(:state_association)
    other_sa.checklist_items.create!(question: 'War die Halle rechtzeitig geöffnet?')
    create(:league, game_operation: create(:game_operation, state_association: other_sa))
    u = build_user(permissions: [{ 'user_group_id' => 4, 'club_id' => club.id }])

    assert_not u.permissions_items[:menu_item_team_game_days]
  end

  test 'permissions_items: VM mit Teams nur in vergangenen Saisons sieht die Auswärtsspieltage nicht' do
    # Der Verein hat die Checkliste in der Vorsaison durchlaufen, spielt aber in
    # der aktuellen Saison (noch) nicht – dann ist nichts zu bestätigen.
    create(:setting, current_season_id: '18')
    sa = create(:state_association)
    sa.checklist_items.create!(question: 'War die Halle rechtzeitig geöffnet?')
    go = create(:game_operation, state_association: sa)
    club = create(:club)
    create(:team, league: create(:league, :previous_season, game_operation: go), club: club)
    u = build_user(permissions: [{ 'user_group_id' => 4, 'club_id' => club.id }])

    assert_not u.permissions_items[:menu_item_team_game_days]
  end

  test 'permission_hash: Ansetzer mit allen GOs ergibt [0]' do
    perms = ALL_GO.map { |go| { 'user_group_id' => 7, 'game_operation_id' => go } }
    u = build_user(permissions: perms)
    assert_equal [0], u.permission_hash[:ansetzer]
  end

  test 'permission_hash: Ansetzer mit spezifischen GOs ergibt sortiertes Array' do
    u = build_user(permissions: [
      { 'user_group_id' => 7, 'game_operation_id' => 5 },
      { 'user_group_id' => 7, 'game_operation_id' => 2 }
    ])
    assert_equal [2, 5], u.permission_hash[:ansetzer]
  end

  test 'permissions_items: kombinierte RSK+Ansetzer-Rolle bekommt beide Funktionen' do
    sa = create(:state_association, referee_assignment_enabled: true)
    go = create(:game_operation, state_association: sa)
    u = build_user(permissions: [
      { 'user_group_id' => 3, 'game_operation_id' => go.id },
      { 'user_group_id' => 7, 'game_operation_id' => go.id }
    ])
    items = u.permissions_items

    assert items[:menu_item_referee_admin]
    assert items[:menu_item_referee_assignments]
  end

  test 'permissions_items: regionaler SBK bekommt den eigenen LV-Verwaltungseintrag' do
    sa = StateAssociation.create!(name: 'SBK-LV Test', short_name: 'SLT')
    regional_go = GameOperation.create!(name: 'SBK Region', short_name: 'SBR', path: 'sbk-region',
                                        state_association: sa)
    u = build_user(permissions: [{ 'user_group_id' => 2, 'game_operation_id' => regional_go.id }])
    items = u.permissions_items

    assert items[:menu_item_state_association_sbk]
    assert_not items[:menu_item_state_association_admin]
  end

  test 'permissions_items: SBK sieht Verfahrensvorschläge nur bei manueller Verfahrenseröffnung' do
    sa = StateAssociation.create!(name: 'Verfahren LV', short_name: 'VLV', manual_proceeding_creation: true)
    go = GameOperation.create!(name: 'Verfahren Region', short_name: 'VFR', path: 'verfahren-region',
                               state_association: sa)
    u = build_user(permissions: [{ 'user_group_id' => 2, 'game_operation_id' => go.id }])

    assert u.permissions_items[:menu_item_proceeding_proposal_admin]
  end

  test 'permissions_items: SBK ohne manuelle Verfahrenseröffnung sieht keine Verfahrensvorschläge' do
    sa = StateAssociation.create!(name: 'Auto LV', short_name: 'ALV', manual_proceeding_creation: false)
    go = GameOperation.create!(name: 'Auto Region', short_name: 'AUR', path: 'auto-region',
                               state_association: sa)
    u = build_user(permissions: [{ 'user_group_id' => 2, 'game_operation_id' => go.id }])

    assert_not u.permissions_items[:menu_item_proceeding_proposal_admin]
    # Die übrigen SBK-Menüpunkte bleiben unberührt.
    assert u.permissions_items[:menu_item_transfer_requests_sbk]
  end

  test 'permissions_items: Admin sieht Verfahrensvorschläge unabhängig vom Landesverband' do
    perms = ALL_GO.map { |go| { 'user_group_id' => 1, 'game_operation_id' => go } }
    u = build_user(permissions: perms)

    assert u.permissions_items[:menu_item_proceeding_proposal_admin]
  end

  test 'permissions_items: globale SBK sieht Verfahrensvorschläge, sobald ein LV sie nutzt' do
    perms = ALL_GO.map { |go| { 'user_group_id' => 2, 'game_operation_id' => go } }
    u = build_user(permissions: perms)

    assert_not u.permissions_items[:menu_item_proceeding_proposal_admin]

    StateAssociation.create!(name: 'Globaler LV', short_name: 'GLV', manual_proceeding_creation: true)

    assert u.permissions_items[:menu_item_proceeding_proposal_admin]
  end

  test 'permissions_items: regionaler RSK bekommt KEINEN LV-Verwaltungseintrag' do
    sa = StateAssociation.create!(name: 'RSK-LV Test', short_name: 'RLT')
    regional_go = GameOperation.create!(name: 'RSK Region', short_name: 'RSR', path: 'rsk-region',
                                        state_association: sa)
    u = build_user(permissions: [{ 'user_group_id' => 3, 'game_operation_id' => regional_go.id }])
    items = u.permissions_items

    assert_not items[:menu_item_state_association_sbk]
    assert_not items[:menu_item_state_association_admin]
  end

  test 'permissions_items: Schiri-only bekommt nur Profil-Zugriff' do
    u = build_user(permissions: [{ 'user_group_id' => 6 }])
    items = u.permissions_items

    assert items[:menu_item_referee_profile]
    assert items[:show_page_referee_profile]
    assert_not items[:login_blocked]
    assert_nil items[:menu_item_league_admin]
  end

  test 'permissions_items: TM ohne Teams in aktueller Saison ist login_blocked' do
    u = build_user(
      permissions: [{ 'user_group_id' => 5 }],
      teams: []
    )
    items = u.permissions_items

    assert items[:login_blocked]
  end

  # --- Phase 2 Extensions ---

  test 'club_ids: VM-Nutzer gibt permission_hash[:vm] zurück' do
    u = build_user(permissions: [
      { 'user_group_id' => 4, 'club_id' => 15 },
      { 'user_group_id' => 4, 'club_id' => 3 }
    ])
    assert_equal u.permission_hash[:vm], u.club_ids
    assert_equal [3, 15], u.club_ids
  end

  test 'club_ids: Admin gibt nil/leeres Ergebnis zurück (kein :vm im Hash)' do
    perms = ALL_GO.map { |go| { 'user_group_id' => 1, 'game_operation_id' => go } }
    u = build_user(permissions: perms)
    assert_nil u.club_ids
  end

  test 'club_ids: SBK gibt nil/leeres Ergebnis zurück (kein :vm im Hash)' do
    perms = ALL_GO.map { |go| { 'user_group_id' => 2, 'game_operation_id' => go } }
    u = build_user(permissions: perms)
    assert_nil u.club_ids
  end

  # Die Vereinsverwaltung gruppiert nach Landesverband, nicht mehr nach
  # Spielbetrieb – die Zahl der Gruppen richtet sich deshalb nach den
  # Landesverbänden. Leere Landesverbände bleiben dabei sichtbar, damit ein
  # Verband ohne Vereine nicht samt Anlege-Knopf aus der Verwaltung fällt.
  #
  # game_operation_id 0 = global. Die vorherige Fassung listete stattdessen
  # ALL_GO auf; diese IDs gibt es als Fixture nicht, der Zugriff war also in
  # Wahrheit leer und die Zusicherung hing an den Platzhalter-Fixtures.
  test 'Club.admin_user_clubs: globaler Admin erhält Einträge für alle Landesverbände' do
    create(:setting, current_season_id: '18')
    lv_a = create(:state_association, name: 'LV A')
    lv_b = create(:state_association, name: 'LV B')
    GameOperation.find_each { |go| go.update!(state_association: lv_a) }
    create(:game_operation, state_association_id: lv_b.id)

    admin = build_user(permissions: [{ 'user_group_id' => 1, 'game_operation_id' => 0 }])

    # Ein Landesverband je Gruppe – auch ohne Vereine, und unabhängig davon, wie
    # viele Spielbetriebe an ihm hängen.
    assert_equal ['LV A', 'LV B'], Club.admin_user_clubs(admin).map { |g| g[:name] }
  end

  test 'permission_hash: deterministisch – gleicher Nutzer ergibt immer denselben Hash' do
    u = build_user(permissions: [
      { 'user_group_id' => 1, 'game_operation_id' => 3 },
      { 'user_group_id' => 4, 'club_id' => 7 }
    ])
    first_call  = u.permission_hash
    second_call = u.permission_hash
    assert_equal first_call, second_call
  end

  test 'permissions_items: Admin darf Lizenzstatus auf TRANSFER setzen' do
    u = build_user(permissions: [{ 'user_group_id' => 1, 'game_operation_id' => 0 }])
    assert u.permissions_items[:player_set_license_to_transfer]
  end

  test 'permissions_items: früher hartcodierter Sonder-Nutzer ohne Admin-Rechte darf NICHT mehr Lizenzstatus auf TRANSFER setzen' do
    # Das frühere special_user-Sonderrecht (hartcodierte Nutzernamen) wurde
    # entfernt; ohne Admin-Rolle gibt es das Recht nicht mehr.
    u = User.create!(
      user_name: 'jho_admin',
      password: 'password123',
      password_confirmation: 'password123',
      permissions: [{ 'user_group_id' => 4, 'club_id' => 1 }],
      teams: []
    )
    assert_not u.permissions_items[:player_set_license_to_transfer]
  end

  test 'permissions_items: normaler VM-Nutzer (kein Admin) darf NICHT Lizenzstatus auf TRANSFER setzen' do
    u = build_user(permissions: [{ 'user_group_id' => 4, 'club_id' => 99 }])
    assert_not u.permissions_items[:player_set_license_to_transfer]
  end

  # ---------------------------------------------------------------------------
  # self.login (ausschliesslich Benutzername)
  # ---------------------------------------------------------------------------

  test 'login: per Benutzername' do
    u = build_user(permissions: [])
    assert_equal u.id, User.login(u.user_name, 'password123')&.id
  end

  test 'login: falsches Passwort schlaegt fehl' do
    u = build_user(permissions: [])
    assert_nil User.login(u.user_name, 'falsch')
  end

  test 'login: E-Mail-Adresse ist keine Login-Kennung' do
    u = build_user(permissions: [])
    u.update!(email: 'login.test@example.com')
    assert_nil User.login('login.test@example.com', 'password123')
  end

  test 'login: auch eine eindeutige E-Mail-Adresse wird nicht akzeptiert' do
    # Frueher genuegte Eindeutigkeit fuer den E-Mail-Login. Das Verhalten kippte
    # still, sobald ein zweites Konto dieselbe Adresse bekam.
    u = build_user(permissions: [])
    u.update!(email: 'einmalig@example.com')
    assert_equal 1, User.where('LOWER(email) = ?', 'einmalig@example.com').count
    assert_nil User.login('einmalig@example.com', 'password123')
  end

  test 'login: mehrfach vergebene E-Mail stoert den Benutzernamen-Login nicht' do
    a = build_user(permissions: [])
    b = build_user(permissions: [])
    a.update!(email: 'shared@example.com')
    b.update!(email: 'shared@example.com')
    assert_equal a.id, User.login(a.user_name, 'password123')&.id
    assert_equal b.id, User.login(b.user_name, 'password123')&.id
  end

  test 'login: leere Eingabe ergibt nil' do
    assert_nil User.login('', 'password123')
    assert_nil User.login('irgendwer', '')
  end

  test 'login: Benutzername ist kleinschreibungsneutral' do
    u = User.create!(
      user_name: "MixedCase_#{SecureRandom.hex(4)}",
      password: 'password123',
      password_confirmation: 'password123',
      permissions: [],
      teams: []
    )
    # Der SessionsController schreibt die Eingabe klein; der gemischt
    # geschriebene Bestandsname muss trotzdem gefunden werden.
    assert_equal u.id, User.login(u.user_name.downcase, 'password123')&.id
    # Der gespeicherte Name behält seine Schreibweise (kein Zwangs-Downcase).
    assert_equal u.user_name, u.reload.user_name
  end

  test 'login: last_login_at-Update scheitert nicht an bestehender CI-Dublette' do
    a = build_user(permissions: [])
    # Zweites Konto mit gleichem Namen in anderer Schreibweise, unter Umgehung
    # der Eindeutigkeitsprüfung (simuliert Altbestand von vor deren Einführung).
    b = a.dup
    b.user_name = a.user_name.upcase
    b.save!(validate: false)
    # Der Login stempelt last_login_at; die Uniqueness darf dabei NICHT greifen,
    # sonst würde das Konto ausgesperrt.
    assert_not_nil User.login(a.user_name.downcase, 'password123')
  end

  # ---------------------------------------------------------------------------
  # user_name-Format / Eindeutigkeit
  # ---------------------------------------------------------------------------

  test 'user_name: Groß- und Kleinbuchstaben sind erlaubt' do
    u = User.new(
      user_name: "MaxMuster_#{SecureRandom.hex(4)}",
      password: 'password123',
      password_confirmation: 'password123',
      permissions: [],
      teams: []
    )
    assert u.valid?, u.errors.full_messages.join(', ')
  end

  test 'user_name: Umlaute werden abgelehnt' do
    u = User.new(
      user_name: "möller_#{SecureRandom.hex(4)}",
      password: 'password123',
      password_confirmation: 'password123',
      permissions: [],
      teams: []
    )
    assert_not u.valid?
    assert u.errors[:user_name].present?
  end

  test 'user_name: doppelter Name wird kleinschreibungsneutral abgelehnt' do
    base = "dupcheck#{SecureRandom.hex(4)}"
    User.create!(
      user_name: base.capitalize,
      password: 'password123',
      password_confirmation: 'password123',
      permissions: [],
      teams: []
    )
    dup = User.new(
      user_name: base,
      password: 'password123',
      password_confirmation: 'password123',
      permissions: [],
      teams: []
    )
    assert_not dup.valid?
    assert dup.errors[:user_name].present?
  end
end
