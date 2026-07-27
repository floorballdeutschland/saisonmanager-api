require 'test_helper'

class RefereeTest < ActiveSupport::TestCase
  def make_referee(lizenznummer:, partner_lizenznummer: nil)
    Referee.create!(
      lizenznummer: lizenznummer,
      vorname: "V#{lizenznummer}",
      nachname: "N#{lizenznummer}",
      partner_lizenznummer: partner_lizenznummer
    )
  end

  test 'partner_lizenznummer: setzt Gegen-Eintrag beim Partner, wenn dort noch leer' do
    a = make_referee(lizenznummer: 20_001)
    b = make_referee(lizenznummer: 20_002)

    a.update!(partner_lizenznummer: b.lizenznummer)

    assert_equal b.lizenznummer, a.reload.partner_lizenznummer
    assert_equal a.lizenznummer, b.reload.partner_lizenznummer
  end

  test 'partner_lizenznummer: überschreibt bestehenden Partner-Eintrag NICHT' do
    a = make_referee(lizenznummer: 20_003)
    c = make_referee(lizenznummer: 20_005, partner_lizenznummer: 99_999)

    a.update!(partner_lizenznummer: c.lizenznummer)

    assert_equal c.lizenznummer, a.reload.partner_lizenznummer
    assert_equal 99_999, c.reload.partner_lizenznummer
  end

  test 'partner_lizenznummer: kein Fehler wenn Partner-Lizenznummer nicht existiert' do
    a = make_referee(lizenznummer: 20_006)

    assert_nothing_raised do
      a.update!(partner_lizenznummer: 88_888)
    end
    assert_equal 88_888, a.reload.partner_lizenznummer
  end

  test 'partner_lizenznummer: Self-Reference setzt keinen Gegen-Eintrag' do
    a = make_referee(lizenznummer: 20_007)

    assert_nothing_raised do
      a.update!(partner_lizenznummer: a.lizenznummer)
    end
  end

  # --- Phase 2 ---

  test 'valid referee with lizenznummer saves successfully' do
    ref = Referee.new(lizenznummer: 30_001, vorname: 'Max', nachname: 'Muster')
    assert ref.valid?, ref.errors.full_messages.inspect
    assert ref.save
  end

  test 'missing vorname is invalid' do
    ref = Referee.new(lizenznummer: 30_002, vorname: nil, nachname: 'Muster')
    assert_not ref.valid?
    assert_includes ref.errors[:vorname], "can't be blank"
  end

  test 'non-integer lizenznummer is invalid' do
    ref = Referee.new(lizenznummer: 'abc', vorname: 'Max', nachname: 'Muster')
    assert_not ref.valid?
    assert ref.errors[:lizenznummer].any?
  end

  test 'lizenznummer 0 is invalid' do
    ref = Referee.new(lizenznummer: 0, vorname: 'Max', nachname: 'Muster')
    assert_not ref.valid?
    assert ref.errors[:lizenznummer].any?
  end

  test 'guest referee without lizenznummer is valid' do
    ref = Referee.new(lizenznummer: nil, vorname: 'Gast', nachname: 'Schiri', guest: true)
    assert ref.valid?, ref.errors.full_messages.inspect
  end

  test 'games returns matching games filtered by season_id' do
    ref = make_referee(lizenznummer: 30_010)

    go    = GameOperation.create!(name: 'GO Referee Test', short_name: 'GRT')
    club  = Club.create!
    arena = Arena.create!(name: 'Testhalle', city: 'Teststadt')

    league_a = League.create!(game_operation: go, season_id: '10', name: 'Liga A', table_modus: 'classic')
    league_b = League.create!(game_operation: go, season_id: '11', name: 'Liga B', table_modus: 'classic')

    day_a = GameDay.create!(league: league_a, arena: arena, club: club, number: 1, date: '2024-01-01')
    day_b = GameDay.create!(league: league_b, arena: arena, club: club, number: 1, date: '2025-01-01')

    game_a = Game.create!(game_day: day_a, referee_ids: [ref.lizenznummer],
                          events: [], players: { 'home' => [], 'guest' => [] },
                          forfait: 0, overtime: false, legacy: false)
    game_b = Game.create!(game_day: day_b, referee_ids: [ref.lizenznummer],
                          events: [], players: { 'home' => [], 'guest' => [] },
                          forfait: 0, overtime: false, legacy: false)

    result = ref.games(season_id: '10')
    assert_includes result, game_a
    assert_not_includes result, game_b
  end

  test 'games ist leer, wenn kein Spiel den Schiri referenziert (Gast ohne Lizenznummer)' do
    ref = Referee.create!(lizenznummer: nil, vorname: 'Gast', nachname: 'Schiri', guest: true)
    assert_empty ref.games(season_id: '10').to_a
  end

  test 'games findet Spiele kanonisch über officiating_referee_ids (PK), auch ohne Lizenz-Treffer' do
    ref = make_referee(lizenznummer: 31_010)

    go     = GameOperation.create!(name: 'GO Officiating', short_name: 'GOF')
    club   = Club.create!
    arena  = Arena.create!(name: 'Halle O', city: 'Stadt O')
    league = League.create!(game_operation: go, season_id: '10', name: 'Liga O', table_modus: 'classic')
    day    = GameDay.create!(league: league, arena: arena, club: club, number: 1, date: '2024-01-01')
    # Bewusst ohne referee_ids/Strings – ausschließlich über die kanonische PK.
    game = Game.create!(game_day: day, officiating_referee_ids: [ref.id, 0],
                        events: [], players: { 'home' => [], 'guest' => [] },
                        forfait: 0, overtime: false, legacy: false)

    assert_includes ref.games(season_id: '10'), game
  end

  test 'games findet Spiele eines Gasts (ohne Lizenznummer) über officiating_referee_ids' do
    guest = Referee.create!(lizenznummer: nil, vorname: 'Gast', nachname: 'Pfeife', guest: true)

    go     = GameOperation.create!(name: 'GO Gast', short_name: 'GGA')
    club   = Club.create!
    arena  = Arena.create!(name: 'Halle G', city: 'Stadt G')
    league = League.create!(game_operation: go, season_id: '10', name: 'Liga G', table_modus: 'classic')
    day    = GameDay.create!(league: league, arena: arena, club: club, number: 1, date: '2024-01-01')
    game = Game.create!(game_day: day, officiating_referee_ids: [guest.id],
                        events: [], players: { 'home' => [], 'guest' => [] },
                        forfait: 0, overtime: false, legacy: false)

    assert_includes guest.games(season_id: '10'), game
  end

  test 'merge_into!: officiating_referee_ids werden auf die Master-PK umgeschrieben' do
    secondary = make_referee(lizenznummer: 40_001)
    master    = make_referee(lizenznummer: 40_002)

    go     = GameOperation.create!(name: 'GO Merge Test', short_name: 'GMT')
    club   = Club.create!
    arena  = Arena.create!(name: 'Mergehalle', city: 'Mergestadt')
    league = League.create!(game_operation: go, season_id: '10', name: 'Liga M', table_modus: 'classic')
    day    = GameDay.create!(league: league, arena: arena, club: club, number: 1, date: '2024-01-01')
    game   = Game.create!(game_day: day, officiating_referee_ids: [secondary.id, 0],
                          events: [], players: { 'home' => [], 'guest' => [] },
                          forfait: 0, overtime: false, legacy: false)

    secondary.merge_into!(master)

    assert_equal [master.id, 0], game.reload.officiating_referee_ids
  end

  # ---------------------------------------------------------------------------
  # partner_history / partner_stats (#222)
  # ---------------------------------------------------------------------------

  test 'partner_history: ein zusammengeführtes Profil erscheint nicht als eigener Partner' do
    create(:setting, current_season_id: '18')
    subject   = create(:referee)
    master    = create(:referee, gueltigkeit: Date.today + 1.year)
    secondary = create(:referee)
    # Stale Referenz, wie sie aus Altdaten/Backfill stammen kann: die Spiele
    # zeigen weiter auf die Secondary-PK, obwohl das Profil zusammengeführt ist.
    secondary.update_columns(merged_into_id: master.id)
    partner_game([subject.id, secondary.id])
    partner_game([subject.id, master.id])

    partners = subject.partner_history[:partners]

    assert_equal([master.id], partners.map { |p| p[:referee_id] })
  end

  test 'partner_history: ein Spiel mit doppelter Partner-PK zählt nur einmal' do
    create(:setting, current_season_id: '18')
    subject = create(:referee)
    partner = create(:referee)
    # array_replace beim Merge kann beide Slots auf dieselbe PK setzen.
    partner_game([subject.id, partner.id, partner.id])

    tally = subject.partner_history[:partners].first

    assert_equal 1, tally[:games_total]
    assert_equal 1, tally[:games_current_season]
  end

  test 'partner_history: liefert Verein und Lizenzgültigkeit des Partners' do
    create(:setting, current_season_id: '18')
    subject = create(:referee)
    club    = create(:club, name: 'SC Gespann')
    active_partner  = create(:referee, club_id: club.id, gueltigkeit: Date.today + 1.year)
    expired_partner = create(:referee, gueltigkeit: Date.today - 1.day)
    partner_game([subject.id, active_partner.id])
    partner_game([subject.id, expired_partner.id], season_id: '17')

    partners = subject.partner_history[:partners].index_by { |p| p[:referee_id] }

    assert partners[active_partner.id][:active]
    assert_equal 'SC Gespann', partners[active_partner.id][:club_name]
    assert_not partners[expired_partner.id][:active]
    assert_nil partners[expired_partner.id][:club_name]
  end

  test 'partner_history: bei gleicher Einsatzzahl entscheidet die Gesamthistorie' do
    create(:setting, current_season_id: '18')
    subject = create(:referee)
    more    = create(:referee)
    fewer   = create(:referee)
    partner_game([subject.id, more.id])
    partner_game([subject.id, more.id], season_id: '17')
    partner_game([subject.id, fewer.id])

    partners = subject.partner_history[:partners]

    assert_equal([1, 1], partners.map { |p| p[:games_current_season] })
    assert_equal([more.id, fewer.id], partners.map { |p| p[:referee_id] })
  end

  def partner_game(referee_ids, season_id: '18')
    league = create(:league, season_id: season_id)
    create(:game, game_day: create(:game_day, league: league), officiating_referee_ids: referee_ids)
  end
end
