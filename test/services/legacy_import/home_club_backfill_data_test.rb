# frozen_string_literal: true

require 'test_helper'

# Zusammenspiel mit der Datenbank: Scope, Dubletten-Auflösung über echte Records
# und die eigentliche Wirkung, nämlich dass das Profil danach im Vereinskonto
# steht und ein Merge-Antrag des Vereins validiert.
class LegacyImport::HomeClubBackfillDataTest < ActiveSupport::TestCase # rubocop:disable Style/ClassAndModuleChildren
  def setup
    @club = create(:club, name: 'ATS Buntentor')
    @other_club = create(:club, name: 'ETV Hamburg')
    @team = create(:team, club: @club)
    @data = LegacyImport::HomeClubBackfillData.new
  end

  # Vereinsloses Legacy-Profil mit einer Lizenz beim Team von @club.
  def legacy_player(first_name: 'Phillip', last_name: 'Oelgemöller', birthdate: '1997-09-17',
                    team: @team, status: License::APPROVED)
    create(:player, first_name:, last_name:, birthdate:, clubs: [],
                    with_licenses: [{ id: 'LIC:fvn:2013_2014:1541', team:, status:,
                                      created_at: '2013-09-10T16:36:37' }])
  end

  def home_entry(club, valid_until: nil)
    { 'club_id' => club.id, 'home_club' => true, 'created_at' => '2015-08-01T00:00:00+02:00',
      'valid_until' => valid_until }.compact
  end

  # ── Scope ─────────────────────────────────────────────────────────────────

  test 'Scope enthaelt nur aktive, nicht gemergte Profile ohne fremde clubs-Eintraege' do
    vereinslos = legacy_player
    mit_verein = create(:player, clubs: [home_entry(@club)])
    deaktiviert = create(:player, clubs: [], deactivated_at: Time.current)
    gemergt = create(:player, clubs: [], merged_into_id: mit_verein.id)

    ids = @data.scope.pluck(:id)

    assert_includes ids, vereinslos.id
    assert_not_includes ids, mit_verein.id
    assert_not_includes ids, deaktiviert.id
    assert_not_includes ids, gemergt.id
  end

  test 'Scope behaelt bereits bearbeitete Profile, damit ein zweiter Lauf idempotent ist' do
    player = legacy_player
    player.update!(clubs: [LegacyImport::HomeClubBackfill.build_entry(club_id: @club.id)])

    assert_includes @data.scope.pluck(:id), player.id
  end

  # ── Zuordnung ─────────────────────────────────────────────────────────────

  test 'ohne Dublette entscheidet der Verein des Lizenz-Teams' do
    player = legacy_player
    result = @data.decide_for(player)

    assert_equal 'E', result[:group]
    assert_equal @club.id, result[:club_id]
  end

  test 'abgelehnte Lizenz ist kein Mitgliedsnachweis' do
    player = legacy_player(status: License::DENIED)
    result = @data.decide_for(player)

    assert_equal 'G', result[:group]
    assert_nil result[:club_id]
  end

  test 'aktive Dublette mit abweichender Vornamens-Schreibweise gewinnt gegen den Lizenz-Verein' do
    player = legacy_player(first_name: 'Per Flemming', last_name: 'Kühl', birthdate: '1998-03-19')
    dublette = create(:player, first_name: 'Flemming Per', last_name: 'Kühl', birthdate: '1998-03-19',
                               clubs: [home_entry(@other_club)])

    result = @data.decide_for(player)

    assert_equal 'A', result[:group]
    assert_equal @other_club.id, result[:club_id]
    assert_equal dublette.id, result[:candidate_id]
  end

  test 'Merge-Kette wird bis zum Master verfolgt' do
    player = legacy_player(first_name: 'Bertram', last_name: 'Wagner', birthdate: '1983-07-07')
    master = create(:player, first_name: 'Bertram', last_name: 'Wagner', birthdate: '1983-07-07',
                             clubs: [home_entry(@other_club)])
    zwischen = create(:player, first_name: 'Bertram', last_name: 'Wagner', birthdate: '1983-07-07',
                               clubs: [], deactivated_at: Time.current, merged_into_id: master.id)

    result = LegacyImport::HomeClubBackfillData.new.decide_for(player)

    assert_equal 'A', result[:group]
    assert_equal @other_club.id, result[:club_id]
    assert_equal master.id, result[:candidate_id], "erwartet den Master #{master.id}, nicht #{zwischen.id}"
  end

  test 'eine in das Legacy-Profil hineingemergte Dublette ist kein Kandidat' do
    player = legacy_player(first_name: 'Kathleen', last_name: 'Hübner', birthdate: '1990-08-10')
    create(:player, first_name: 'Kathleen', last_name: 'Hübner', birthdate: '1990-08-10',
                    clubs: [], deactivated_at: Time.current, merged_into_id: player.id)

    result = LegacyImport::HomeClubBackfillData.new.decide_for(player)

    assert_equal 'E', result[:group], 'die Kette zeigt auf das Profil selbst zurueck'
    assert_equal @club.id, result[:club_id]
  end

  test 'deaktivierte Dublette liefert Gruppe D mit ihrem letzten Verein' do
    player = legacy_player(first_name: 'Mark Oli', last_name: 'Bothe', birthdate: '1993-11-07')
    dublette = create(:player, first_name: 'Mark-Oliver', last_name: 'Bothe', birthdate: '1993-11-07',
                               clubs: [home_entry(@other_club, valid_until: 1.week.ago.iso8601)],
                               deactivated_at: 1.week.ago)

    result = LegacyImport::HomeClubBackfillData.new.decide_for(player)

    assert_equal 'D', result[:group]
    assert_equal @other_club.id, result[:club_id]
    assert_equal dublette.id, result[:candidate_id]
  end

  test 'Profil ohne Geburtsdatum bekommt keine Dublette zugeordnet' do
    player = create(:player, first_name: 'Max', last_name: 'Namenlos', birthdate: nil, clubs: [])
    create(:player, first_name: 'Max', last_name: 'Namenlos', birthdate: '1990-01-01',
                    clubs: [home_entry(@other_club)])

    result = LegacyImport::HomeClubBackfillData.new.decide_for(player)

    assert_equal 'G', result[:group]
  end

  test 'Platzhalter-Vereine landen in der Ignore-Liste' do
    junk = create(:club, name: 'Ablage Doppelung')
    inaktiv = create(:club, name: 'TSV Alt', deactivated_at: Time.current)

    ids = LegacyImport::HomeClubBackfillData.new.ignore_club_ids

    assert_includes ids, junk.id
    assert_includes ids, inaktiv.id
    assert_not_includes ids, @club.id
  end

  test 'earliest_license_start liefert den fruehesten Verlaufszeitpunkt beim Zielverein' do
    player = legacy_player
    assert_equal '2013-09-10T16:36:37', @data.earliest_license_start(player, @club.id)
    assert_nil @data.earliest_license_start(player, @other_club.id)
  end

  # ── Wirkung ───────────────────────────────────────────────────────────────

  test 'nach dem Backfill steht das Profil in der Vereins-Spielerliste' do
    player = legacy_player
    assert_not_includes @club.players.map(&:id), player.id

    entry = LegacyImport::HomeClubBackfill.build_entry(
      club_id: @club.id, created_at: @data.earliest_license_start(player, @club.id)
    )
    new_clubs, changed = LegacyImport::HomeClubBackfill.apply(player.clubs, entry)
    assert changed
    player.update!(clubs: new_clubs)

    assert_includes @club.reload.players.map(&:id), player.id
  end

  test 'ein geschlossener Eintrag wuerde das Profil NICHT sichtbar machen' do
    # Begründung für valid_until = nil: Club#players filtert auf Gültigkeit, und
    # diese Liste fuellt das Duplikat-Dropdown des Merge-Antrags.
    player = legacy_player
    player.update!(clubs: [home_entry(@club, valid_until: '2014-07-31T23:59:59')])

    assert_not_includes @club.reload.players.map(&:id), player.id
  end

  test 'der Verein kann danach einen Merge-Antrag stellen' do
    player = legacy_player
    master = create(:player, first_name: 'Phillip', last_name: 'Oelgemöller', birthdate: '1997-09-17',
                             clubs: [home_entry(@club)])
    user = create(:user)

    player.update!(clubs: [LegacyImport::HomeClubBackfill.build_entry(club_id: @club.id)])

    request = PlayerChangeRequest.new(player: master, club: @club, correction_type: 'merge',
                                      secondary_player_id: player.id, status: 'pending',
                                      requested_by_user_id: user.id)

    assert request.valid?, "erwartet gueltig, Fehler: #{request.errors.full_messages.join(', ')}"
  end

  test 'ohne clubs-Eintrag scheitert der Merge-Antrag an der Vereinszugehoerigkeit' do
    player = legacy_player
    master = create(:player, first_name: 'Phillip', last_name: 'Oelgemöller', birthdate: '1997-09-17',
                             clubs: [home_entry(@club)])
    user = create(:user)

    request = PlayerChangeRequest.new(player: master, club: @club, correction_type: 'merge',
                                      secondary_player_id: player.id, status: 'pending',
                                      requested_by_user_id: user.id)

    assert_not request.valid?
    assert_includes request.errors.full_messages.join(', '), 'gehört nicht zum angegebenen Verein'
  end
end
