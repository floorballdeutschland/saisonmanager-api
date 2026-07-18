# frozen_string_literal: true

puts 'Seeding database...'

# ============================================================
# SETTINGS (Stammdaten – alles in einem einzigen Record)
# ============================================================
Setting.delete_all

Setting.create!(
  nations: {
    '1'  => { 'name' => 'Deutschland' },
    '2'  => { 'name' => 'Österreich' },
    '3'  => { 'name' => 'Schweiz' },
    '4'  => { 'name' => 'Dänemark' },
    '5'  => { 'name' => 'Schweden' },
    '6'  => { 'name' => 'Finnland' },
    '7'  => { 'name' => 'Tschechien' },
    '99' => { 'name' => 'Sonstige' }
  },
  league_categories: {
    '1000' => { 'name' => 'Reguläre Saison' },
    '1001' => { 'name' => 'Cup' },
    '1002' => { 'name' => 'Freundschaftsspiel' }
  },
  league_classes: {
    '1fbl' => { 'name' => '1. Floorball Bundesliga' },
    '2fbl' => { 'name' => '2. Floorball Bundesliga' },
    'rl' => { 'name' => 'Regionalliga' },
    'vl' => { 'name' => 'Verbandsliga' },
    'll' => { 'name' => 'Landesliga' }
  },
  league_systems: {
    '1' => { 'name' => 'Einfachrunde' },
    '2' => { 'name' => 'Doppelrunde' },
    '3' => { 'name' => 'Dreifachrunde' },
    '4' => { 'name' => 'Standard' }
  },
  seasons: {
    '1' => { 'name' => '2023/24', 'min_league_id' => 0, 'min_team_id' => 0 },
    '2' => { 'name' => '2024/25', 'min_league_id' => 100, 'min_team_id' => 100 }
  },
  systems: {
    '1' => { 'current_season_id' => 2 }
  },
  user_groups: {
    '1' => { 'name' => 'Admin' },
    '2' => { 'name' => 'SBK' },
    '3' => { 'name' => 'RSK' },
    '4' => { 'name' => 'VM' },
    '5' => { 'name' => 'TM' },
    '7' => { 'name' => 'Ansetzer' }
  },
  penalties: {
    '1' => { 'name' => '2 Minuten' },
    '2' => { 'name' => '5 Minuten' },
    '3' => { 'name' => '10 Minuten' },
    '4' => { 'name' => '20 Minuten (Spieldauer)' },
    '5' => { 'name' => 'Spielausschluss' }
  },
  penalty_codes: {
    '1' => { 'name' => 'Behinderung' },
    '2' => { 'name' => 'Stockschlag' },
    '3' => { 'name' => 'Haken' },
    '4' => { 'name' => 'Halten' },
    '5' => { 'name' => 'Hoher Stock' },
    '6' => { 'name' => 'Unsportliches Verhalten' }
  },
  point_corrections: {},
  liveticker: {
    'game_day_for_league' => {
      '2' => {}
    },
    'cup_best_of_eight' => {}
  }
)

puts '  Settings created.'

# ============================================================
# STATE ASSOCIATIONS (Landesverbände)
# ============================================================
StateAssociation.delete_all

sa_ost = StateAssociation.create!(name: 'SBK Ost',     short_name: 'SBK Ost')
sa_wst = StateAssociation.create!(name: 'SBK West',    short_name: 'SBK West')
sa_bay = StateAssociation.create!(name: 'SBK Bayern',  short_name: 'SBK Bay')

puts '  State associations created.'

# ============================================================
# GAME OPERATIONS (Spielbetriebe)
# ============================================================
GameOperation.delete_all

fd  = GameOperation.create!(name: 'Floorball Deutschland', short_name: 'FD',         path: 'fd')
ost = GameOperation.create!(name: 'SBK Ost',               short_name: 'SBK Ost',   path: 'sbk-ost',    state_association_id: sa_ost.id)
wst = GameOperation.create!(name: 'SBK West',              short_name: 'SBK West',  path: 'sbk-west',   state_association_id: sa_wst.id)
bay = GameOperation.create!(name: 'SBK Bayern',            short_name: 'SBK Bayern', path: 'sbk-bayern', state_association_id: sa_bay.id)

puts '  Game operations created.'

# ============================================================
# ARENAS
# ============================================================
Arena.delete_all

arena_berlin  = Arena.create!(name: 'Sporthalle Berlin-Mitte',    city: 'Berlin',  street: 'Musterstr.',   housenumber: '1',  postcode: '10115', active: true)
arena_hamburg = Arena.create!(name: 'Sportanlage Hamburg-Nord',   city: 'Hamburg', street: 'Hafenweg',     housenumber: '5',  postcode: '20095', active: true)
arena_munich  = Arena.create!(name: 'Sporthalle München-Süd',     city: 'München', street: 'Sportplatz',   housenumber: '3',  postcode: '80331', active: true)
arena_koeln   = Arena.create!(name: 'Sporthalle Köln-West',       city: 'Köln',    street: 'Kölner Ring',  housenumber: '7',  postcode: '50667', active: true)

puts '  Arenas created.'

# ============================================================
# CLUBS
# ============================================================
Club.delete_all

club_berlin  = Club.create!(name: 'Floorball Berlin',  short_name: 'FBB',  city: 'Berlin',  state_association_id: sa_ost.id)
club_hamburg = Club.create!(name: 'Floorball Hamburg', short_name: 'FBH',  city: 'Hamburg', state_association_id: sa_ost.id)
club_munich  = Club.create!(name: 'Floorball München', short_name: 'FBM',  city: 'München', state_association_id: sa_bay.id)
club_koeln   = Club.create!(name: 'Floorball Köln',    short_name: 'FBK',  city: 'Köln',    state_association_id: sa_wst.id)
club_bremen  = Club.create!(name: 'Floorball Bremen',  short_name: 'FBBr', city: 'Bremen',  state_association_id: sa_ost.id)
club_dresden = Club.create!(name: 'Floorball Dresden', short_name: 'FBD',  city: 'Dresden', state_association_id: sa_ost.id)

puts '  Clubs created.'

# ============================================================
# LEAGUES
# ============================================================
League.delete_all

buli = League.create!(
  name: '1. Bundesliga Herren 2024/25',
  short_name: 'BuLi H 24/25',
  game_operation_id: fd.id,
  season_id: '2',
  league_class_id: '1fbl',
  league_category_id: '1000',
  league_system_id: '2',
  female: false,
  enable_scorer: true,
  field_size: 'GF'
)

buli_f = League.create!(
  name: '1. Bundesliga Damen 2024/25',
  short_name: 'BuLi D 24/25',
  game_operation_id: fd.id,
  season_id: '2',
  league_class_id: '1fbl',
  league_category_id: '1000',
  league_system_id: '2',
  female: true,
  enable_scorer: true,
  field_size: 'GF'
)

rliga_ost = League.create!(
  name: 'Regionalliga Ost 2024/25',
  short_name: 'RL Ost 24/25',
  game_operation_id: ost.id,
  season_id: '2',
  league_class_id: 'rl',
  league_category_id: '1000',
  league_system_id: '2',
  female: false,
  enable_scorer: true,
  field_size: 'GF'
)

puts '  Leagues created.'

# ============================================================
# TEAMS
# ============================================================
Team.delete_all

team_berlin_1  = Team.create!(name: 'Floorball Berlin 1',  club_id: club_berlin.id,  league_id: buli.id,      approved: true)
team_berlin_2  = Team.create!(name: 'Floorball Berlin 2',  club_id: club_berlin.id,  league_id: rliga_ost.id, approved: true)
team_hamburg_1 = Team.create!(name: 'Floorball Hamburg 1', club_id: club_hamburg.id, league_id: buli.id,      approved: true)
team_hamburg_2 = Team.create!(name: 'Floorball Hamburg 2', club_id: club_hamburg.id, league_id: rliga_ost.id, approved: true)
team_munich_1  = Team.create!(name: 'Floorball München 1', club_id: club_munich.id,  league_id: buli.id,      approved: true)
team_koeln_1   = Team.create!(name: 'Floorball Köln 1',    club_id: club_koeln.id,   league_id: buli.id,      approved: true)
team_bremen_1  = Team.create!(name: 'Floorball Bremen 1',  club_id: club_bremen.id,  league_id: rliga_ost.id, approved: true)
team_dresden_1 = Team.create!(name: 'Floorball Dresden 1', club_id: club_dresden.id, league_id: rliga_ost.id, approved: true)

puts '  Teams created.'

# ============================================================
# GAME DAYS
# ============================================================
GameDay.delete_all

# Bundesliga – 3 Spieltage
gd_buli_1 = GameDay.create!(league_id: buli.id, number: 1, date: '2024-11-02', arena_id: arena_berlin.id,  club_id: club_berlin.id)
gd_buli_2 = GameDay.create!(league_id: buli.id, number: 2, date: '2024-11-16', arena_id: arena_hamburg.id, club_id: club_hamburg.id)
gd_buli_3 = GameDay.create!(league_id: buli.id, number: 3, date: '2024-12-07', arena_id: arena_munich.id,  club_id: club_munich.id)

# Regionalliga Ost – 2 Spieltage
gd_rl_1 = GameDay.create!(league_id: rliga_ost.id, number: 1, date: '2024-11-09', arena_id: arena_berlin.id,  club_id: club_berlin.id)
gd_rl_2 = GameDay.create!(league_id: rliga_ost.id, number: 2, date: '2024-11-23', arena_id: arena_hamburg.id, club_id: club_hamburg.id)

puts '  Game days created.'

# ============================================================
# GAMES
# Note: game_number stored as text – sorting bug fix (PR #22)
# intentionally using out-of-order numbers to verify fix
# ============================================================
Game.delete_all

# Bundesliga Spieltag 1 – numbers deliberately non-sequential to test sort fix
[[team_berlin_1,  team_hamburg_1, '10', '10:00'],
 [team_munich_1,  team_koeln_1,   '2',  '12:00'],
 [team_berlin_1,  team_koeln_1,   '1',  '14:00'],
 [team_hamburg_1, team_munich_1,  '20', '16:00']].each do |home, guest, num, time|
  Game.create!(
    game_day_id:   gd_buli_1.id,
    game_number:   num,
    home_team_id:  home.id,
    guest_team_id: guest.id,
    start_time:    time,
    game_status:   'pregame',
    forfait:       0
  )
end

# Bundesliga Spieltag 2
[[team_hamburg_1, team_berlin_1,  '3', '10:00'],
 [team_koeln_1,   team_munich_1,  '4', '12:00']].each do |home, guest, num, time|
  Game.create!(
    game_day_id:   gd_buli_2.id,
    game_number:   num,
    home_team_id:  home.id,
    guest_team_id: guest.id,
    start_time:    time,
    game_status:   'pregame',
    forfait:       0
  )
end

# Ein abgeschlossenes Spiel zum Testen von reopen_game (PR #21)
finalized_game = Game.create!(
  game_day_id:   gd_buli_3.id,
  game_number:   '5',
  home_team_id:  team_munich_1.id,
  guest_team_id: team_berlin_1.id,
  start_time:    '10:00',
  game_status:   'finalized',
  forfait:       0,
  events: [
    { 'event_type' => 'goal', 'team' => 'home', 'player_id' => nil, 'minute' => 15 },
    { 'event_type' => 'goal', 'team' => 'guest', 'player_id' => nil, 'minute' => 32 }
  ]
)

# Regionalliga Spieltag 1
[[team_berlin_2,  team_hamburg_2, '6', '10:00'],
 [team_bremen_1,  team_dresden_1, '7', '12:00']].each do |home, guest, num, time|
  Game.create!(
    game_day_id:   gd_rl_1.id,
    game_number:   num,
    home_team_id:  home.id,
    guest_team_id: guest.id,
    start_time:    time,
    game_status:   'pregame',
    forfait:       0
  )
end

puts '  Games created.'

# ============================================================
# PLAYERS
# ============================================================
Player.delete_all

players_data = [
  { first_name: 'Max',     last_name: 'Mustermann', birthdate: '1995-03-15', nation_id: '1', gender: 'M', club: club_berlin,  team: team_berlin_1 },
  { first_name: 'Lena',    last_name: 'Müller',     birthdate: '1998-07-22', nation_id: '1', gender: 'W', club: club_berlin,  team: team_berlin_1 },
  { first_name: 'Jonas',   last_name: 'Schmidt',    birthdate: '2000-01-05', nation_id: '1', gender: 'M', club: club_berlin,  team: team_berlin_2 },
  { first_name: 'Anna',    last_name: 'Weber',      birthdate: '1997-11-30', nation_id: '1', gender: 'W', club: club_hamburg, team: team_hamburg_1 },
  { first_name: 'Tim',     last_name: 'Fischer',    birthdate: '1993-06-18', nation_id: '1', gender: 'M', club: club_hamburg, team: team_hamburg_1 },
  { first_name: 'Sophie',  last_name: 'Wagner',     birthdate: '2001-02-14', nation_id: '1', gender: 'W', club: club_munich,  team: team_munich_1 },
  { first_name: 'Felix',   last_name: 'Becker',     birthdate: '1996-09-03', nation_id: '1', gender: 'M', club: club_munich,  team: team_munich_1 },
  { first_name: 'Laura',   last_name: 'Hoffmann',   birthdate: '1999-04-27', nation_id: '1', gender: 'W', club: club_koeln,   team: team_koeln_1 },
  { first_name: 'Patrick', last_name: 'Schulz',     birthdate: '2003-01-08', nation_id: '1', gender: 'M', club: club_koeln,   team: team_koeln_1 },
  { first_name: 'Erik',    last_name: 'Larsson',    birthdate: '1992-12-01', nation_id: '5', gender: 'M', club: club_berlin,  team: team_berlin_1 },
]

players = players_data.map.with_index(1) do |pd, i|
  Player.create!(
    first_name: pd[:first_name],
    last_name:  pd[:last_name],
    birthdate:  pd[:birthdate],
    nation_id:  pd[:nation_id],
    gender:     pd[:gender],
    clubs:      [{ 'club_id' => pd[:club].id, 'team_id' => pd[:team].id }],
    licenses: [
      {
        'id'                => i,
        'team_id'           => pd[:team].id,
        'league_id'         => pd[:team].league_id,
        'league_class_id'   => '1fbl',
        'league_category_id'=> '1000',
        'requested_at'      => '2024-09-01',
        'set_transfer_allowed' => true,
        'history' => [
          {
            'license_status_id' => 2,
            'created_by'        => 1,
            'created_by_name'   => 'Admin',
            'created_at'        => '2024-09-01T10:00:00Z',
            'reason'            => ''
          },
          {
            'license_status_id' => 1,
            'created_by'        => 1,
            'created_by_name'   => 'Admin',
            'created_at'        => '2024-09-02T09:00:00Z',
            'reason'            => 'Lizenz erteilt'
          }
        ]
      }
    ]
  )
end

puts '  Players created.'

# ============================================================
# USERS
# ============================================================
User.delete_all

# Passwort für alle: "password123"
password_hash = BCrypt::Password.create('password123')

# Admin (hat Zugriff auf alles, game_operation_id 0 = alle)
User.create!(
  user_name:       'admin',
  email:           'admin@saisonmanager.dev',
  first_name:      'Admin',
  last_name:       'User',
  password_digest: password_hash,
  permissions:     [{ 'user_group_id' => '1', 'game_operation_id' => '0' }]
)

# SBK Ost (Zugriff auf game_operation ost)
User.create!(
  user_name:       'sbk_ost',
  email:           'sbkost@saisonmanager.dev',
  first_name:      'SBK',
  last_name:       'Ost',
  password_digest: password_hash,
  permissions:     [{ 'user_group_id' => '2', 'game_operation_id' => ost.id.to_s }]
)

# SBK West
User.create!(
  user_name:       'sbk_west',
  email:           'sbkwest@saisonmanager.dev',
  first_name:      'SBK',
  last_name:       'West',
  password_digest: password_hash,
  permissions:     [{ 'user_group_id' => '2', 'game_operation_id' => wst.id.to_s }]
)

# Demo SBK Bayern
User.create!(
  user_name:       'demo_sbk_bay',
  email:           'sbk_bay@saisonmanager.dev',
  first_name:      'Demo SBK',
  last_name:       'Bayern',
  password_digest: password_hash,
  permissions:     [{ 'user_group_id' => '2', 'game_operation_id' => bay.id.to_s }]
)

# VM Berlin (Vereinsmanager für Floorball Berlin)
User.create!(
  user_name:       'vm_berlin',
  email:           'vm@berlin.dev',
  first_name:      'VM',
  last_name:       'Berlin',
  password_digest: password_hash,
  club_id:         club_berlin.id,
  permissions:     [{ 'user_group_id' => '4', 'game_operation_id' => '0', 'club_id' => club_berlin.id.to_s }]
)

# TM Berlin 1 (Teammanager für Team Berlin 1)
User.create!(
  user_name:       'tm_berlin1',
  email:           'tm@berlin.dev',
  first_name:      'TM',
  last_name:       'Berlin 1',
  password_digest: password_hash,
  club_id:         club_berlin.id,
  teams:           [team_berlin_1.id],
  permissions:     [{ 'user_group_id' => '5', 'game_operation_id' => '0', 'club_id' => club_berlin.id.to_s }]
)

puts '  Users created.'
puts ''
puts 'Done! Seed data summary:'
puts "  Settings:            1"
puts "  State associations:  #{StateAssociation.count}"
puts "  Game operations:     #{GameOperation.count}"
puts "  Arenas:              #{Arena.count}"
puts "  Clubs:               #{Club.count}"
puts "  Teams:               #{Team.count}"
puts "  Leagues:             #{League.count}"
puts "  Game days:           #{GameDay.count}"
puts "  Games:               #{Game.count} (incl. 1 finalized for reopen test)"
puts "  Players:             #{Player.count}"
puts "  Users:               #{User.count}"
puts ''
puts 'Login credentials (password: password123):'
puts '  admin        – Admin, alle Rechte'
puts '  sbk_ost      – SBK Ost'
puts '  sbk_west     – SBK West'
puts '  demo_sbk_bay – SBK Bayern (Demo)'
puts '  vm_berlin    – VM Floorball Berlin'
puts '  tm_berlin1   – TM Berlin Team 1'
