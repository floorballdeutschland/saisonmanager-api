# frozen_string_literal: true

require 'test_helper'

# Zusammenspiel mit der Datenbank: Scope, Dubletten-Auflösung über echte Records
# und die eigentliche Wirkung, nämlich dass das Profil danach im Vereinskonto
# steht und ein Merge-Antrag des Vereins validiert.
#
# ACHTUNG Eine HomeClubBackfillData-Instanz entspricht EINEM Lauf: die Indizes
# werden beim ersten Zugriff gebaut. Jeder Test legt seine Datensätze deshalb
# zuerst an und instanziert danach (Helper `data`).
class LegacyImport::HomeClubBackfillDataTest < ActiveSupport::TestCase # rubocop:disable Style/ClassAndModuleChildren
  SOURCE = LegacyImport::HomeClubBackfill::SOURCE

  def setup
    @club = create(:club, name: 'Verein A')
    @other_club = create(:club, name: 'Verein B')
    @team = create(:team, club: @club)
  end

  def data
    LegacyImport::HomeClubBackfillData.new
  end

  # Vereinsloses Profil mit einer Legacy-Lizenz beim Team von @club.
  def legacy_player(first_name: 'Phillip', last_name: 'Musterberg', birthdate: '1997-09-17',
                    team: @team, status: License::APPROVED, licenses: nil, gender: 'M')
    create(:player, first_name:, last_name:, birthdate:, gender:, clubs: [],
                    with_licenses: licenses || [{ id: 'LIC:fvn:2013_2014:1541', team:, status:,
                                                  created_at: '2013-09-10T16:36:37' }])
  end

  def home_entry(club, valid_until: nil, home: true, created_at: '2015-08-01T00:00:00+02:00')
    { 'club_id' => club.id, 'home_club' => home, 'created_at' => created_at,
      'valid_until' => valid_until }.compact
  end

  # ── Scope ─────────────────────────────────────────────────────────────────

  test 'Scope enthält nur aktive, nicht gemergte Profile ohne fremde clubs-Einträge' do
    vereinslos = legacy_player
    mit_verein = create(:player, clubs: [home_entry(@club)])
    deaktiviert = create(:player, clubs: [], deactivated_at: Time.current)
    gemergt = create(:player, clubs: [], merged_into_id: mit_verein.id)

    ids = data.scope.pluck(:id)

    assert_includes ids, vereinslos.id
    assert_not_includes ids, mit_verein.id
    assert_not_includes ids, deaktiviert.id
    assert_not_includes ids, gemergt.id
  end

  test 'Scope schließt manuell angelegte Profile aus (created_by gesetzt)' do
    # Nur der Import lässt created_by leer. Ohne diese Grenze geriete ein
    # abgebrochen angelegtes modernes Profil in den Lauf.
    manuell = legacy_player
    manuell.update!(created_by: create(:user).id)

    assert_not_includes data.scope.pluck(:id), manuell.id
  end

  test 'Scope behält bereits bearbeitete Profile, damit ein zweiter Lauf idempotent ist' do
    player = legacy_player
    player.update!(clubs: [LegacyImport::HomeClubBackfill.build_entry(club_id: @club.id)])

    assert_includes data.scope.pluck(:id), player.id
  end

  test 'Scope verliert das Profil, sobald ein echter Eintrag NEBEN dem eigenen liegt' do
    # Die eigentliche Schutzwirkung der NOT-EXISTS-Formulierung: sobald ein Verein
    # eine echte Mitgliedschaft ergänzt, hört der Backfill auf, das Profil anzufassen.
    player = legacy_player
    player.update!(clubs: [LegacyImport::HomeClubBackfill.build_entry(club_id: @club.id),
                           home_entry(@other_club)])

    assert_not_includes data.scope.pluck(:id), player.id
  end

  # ── Zuordnung ─────────────────────────────────────────────────────────────

  test 'ohne Dublette entscheidet der Verein des Lizenz-Teams' do
    result = data.decide_for(legacy_player)

    assert_equal 'E', result[:group]
    assert_equal @club.id, result[:club_id]
  end

  test 'abgelehnte Lizenz ist kein Mitgliedsnachweis' do
    result = data.decide_for(legacy_player(status: License::DENIED))

    assert_equal 'G', result[:group]
    assert_nil result[:club_id]
  end

  test 'eine Transfer-Lizenz belegt die Mitgliedschaft im abgebenden Verein' do
    result = data.decide_for(legacy_player(status: License::TRANSFER))

    assert_equal 'E', result[:group]
    assert_equal @club.id, result[:club_id]
  end

  test 'eine beantragte Lizenz belegt die Mitgliedschaft' do
    assert_equal 'E', data.decide_for(legacy_player(status: License::REQUESTED))[:group]
  end

  test 'moderne Lizenzen ohne LIC:-Präfix zählen nicht' do
    player = legacy_player(licenses: [{ id: 'a4f1c2de-0000-0000-0000-000000000000', team: @team,
                                        status: License::APPROVED }])

    assert_equal 'G', data.decide_for(player)[:group], 'nur Altdaten-Lizenzen sind Beleg'
  end

  test 'der LETZTE Verlaufsstatus entscheidet, nicht der erste' do
    player = legacy_player
    licenses = player.licenses
    licenses.first['history'] = [
      { 'license_status_id' => License::APPROVED, 'created_at' => '2013-09-10T16:36:37' },
      { 'license_status_id' => License::WITHDRAWN, 'created_at' => '2014-06-01T10:00:00' }
    ]
    player.update!(licenses:)

    assert_equal 'G', data.decide_for(player)[:group], 'zurückgezogen belegt nichts'
  end

  test 'eine zunächst abgelehnte, später erteilte Lizenz belegt die Mitgliedschaft' do
    player = legacy_player
    licenses = player.licenses
    licenses.first['history'] = [
      { 'license_status_id' => License::DENIED, 'created_at' => '2013-09-10T16:36:37' },
      { 'license_status_id' => License::APPROVED, 'created_at' => '2014-01-15T10:00:00' }
    ]
    player.update!(licenses:)

    assert_equal 'E', data.decide_for(player)[:group]
  end

  test 'eine Lizenz ohne Verlauf belegt nichts' do
    player = legacy_player
    licenses = player.licenses
    licenses.first['history'] = []
    player.update!(licenses:)

    assert_equal 'G', data.decide_for(player)[:group]
  end

  test 'ein Lizenz-Team ohne auflösbaren Verein blockiert statt Eindeutigkeit vorzutäuschen' do
    other_team = create(:team, club: @other_club)
    licenses = [
      { id: 'LIC:fvn:2012_2013:1', team: @team, status: License::APPROVED },
      { id: 'LIC:fvn:2013_2014:2', team: other_team, status: License::APPROVED }
    ]
    player = legacy_player(licenses:)
    other_team.delete

    result = data.decide_for(player)

    assert_equal 'L', result[:group]
    assert_nil result[:club_id], 'aus zwei Vereinen darf nicht stillschweigend einer werden'
  end

  test 'aktive Dublette mit abweichender Vornamens-Schreibweise gewinnt gegen den Lizenz-Verein' do
    player = legacy_player(first_name: 'Per Flemming', last_name: 'Beispiel', birthdate: '1998-03-19')
    dublette = create(:player, first_name: 'Flemming Per', last_name: 'Beispiel', birthdate: '1998-03-19',
                               clubs: [home_entry(@other_club)])

    result = data.decide_for(player)

    assert_equal 'A', result[:group]
    assert_equal @other_club.id, result[:club_id]
    assert_equal dublette.id, result[:candidate_id]
  end

  test 'eine Dublette mit abweichendem Geschlecht zählt nicht' do
    player = legacy_player(first_name: 'Jan', last_name: 'Zwilling', birthdate: '2001-05-05', gender: 'M')
    create(:player, first_name: 'Jana', last_name: 'Zwilling', birthdate: '2001-05-05', gender: 'W',
                    clubs: [home_entry(@other_club)])

    result = data.decide_for(player)

    assert_equal 'E', result[:group]
    assert_equal @club.id, result[:club_id]
  end

  test 'Merge-Kette wird bis zum Master verfolgt' do
    player = legacy_player(first_name: 'Bertram', last_name: 'Kettental', birthdate: '1983-07-07')
    master = create(:player, first_name: 'Bertram', last_name: 'Kettental', birthdate: '1983-07-07',
                             clubs: [home_entry(@other_club)])
    zwischen = create(:player, first_name: 'Bertram', last_name: 'Kettental', birthdate: '1983-07-07',
                               clubs: [], deactivated_at: Time.current, merged_into_id: master.id)

    result = data.decide_for(player)

    assert_equal 'A', result[:group]
    assert_equal @other_club.id, result[:club_id]
    assert_equal master.id, result[:candidate_id], "erwartet den Master, nicht #{zwischen.id}"
  end

  test 'der Master der Kette darf Nachname und Geburtsdatum abweichen lassen' do
    # Der Treffer gilt für die getroffene Zeile; der Master ist deren überlebendes
    # Profil, sein eigener Schlüssel wird bewusst nicht erneut geprüft. Dieser Fall
    # deckt außerdem ab, dass clubs für Master AUSSERHALB der Trefferliste geladen
    # werden.
    player = legacy_player(first_name: 'Nora', last_name: 'Kettental', birthdate: '1990-02-02')
    master = create(:player, first_name: 'Nora', last_name: 'Neuname', birthdate: '1991-03-03',
                             clubs: [home_entry(@other_club)])
    create(:player, first_name: 'Nora', last_name: 'Kettental', birthdate: '1990-02-02',
                    clubs: [], deactivated_at: Time.current, merged_into_id: master.id)

    result = data.decide_for(player)

    assert_equal 'A', result[:group]
    assert_equal @other_club.id, result[:club_id]
    assert_equal master.id, result[:candidate_id]
  end

  test 'eine Merge-Kette im Kreis bricht die Auflösung nicht' do
    player = legacy_player(first_name: 'Ada', last_name: 'Kreis', birthdate: '1988-01-01')
    a = create(:player, first_name: 'Ada', last_name: 'Kreis', birthdate: '1988-01-01', clubs: [])
    b = create(:player, first_name: 'Ada', last_name: 'Kreis', birthdate: '1988-01-01', clubs: [])
    a.update_columns(merged_into_id: b.id)
    b.update_columns(merged_into_id: a.id)

    assert_nothing_raised { data.decide_for(player) }
  end

  test 'eine in das Profil selbst hineingemergte Dublette ist kein Kandidat' do
    player = legacy_player(first_name: 'Kathleen', last_name: 'Selbstbezug', birthdate: '1990-08-10')
    create(:player, first_name: 'Kathleen', last_name: 'Selbstbezug', birthdate: '1990-08-10',
                    clubs: [], deactivated_at: Time.current, merged_into_id: player.id)

    result = data.decide_for(player)

    assert_equal 'E', result[:group], 'die Kette zeigt auf das Profil selbst zurück'
    assert_equal @club.id, result[:club_id]
  end

  test 'deaktivierte Dublette liefert Gruppe D mit ihrem letzten Verein' do
    player = legacy_player(first_name: 'Mark Oli', last_name: 'Ruhend', birthdate: '1993-11-07')
    dublette = create(:player, first_name: 'Mark-Oliver', last_name: 'Ruhend', birthdate: '1993-11-07',
                               clubs: [home_entry(@other_club, valid_until: 1.week.ago.iso8601)],
                               deactivated_at: 1.week.ago)

    result = data.decide_for(player)

    assert_equal 'D', result[:group]
    assert_equal @other_club.id, result[:club_id]
    assert_equal dublette.id, result[:candidate_id]
  end

  test 'eine Dublette mit nur einer Freigabe ist kein Heimat-Merge-Ziel' do
    player = legacy_player(first_name: 'Frida', last_name: 'Freigabe', birthdate: '1995-04-04')
    create(:player, first_name: 'Frida', last_name: 'Freigabe', birthdate: '1995-04-04',
                    clubs: [home_entry(@other_club, home: false, valid_until: 1.year.from_now.iso8601)])

    result = data.decide_for(player)

    assert_equal 'E', result[:group], 'eine Freigabe ist kein Heimatverein'
    assert_equal @club.id, result[:club_id]
  end

  test 'ein eigener Backfill-Eintrag der Dublette gilt NICHT als Beleg' do
    # Sonst würde eine frühere Vermutung dieses Tasks beim nächsten Lauf als
    # hochvertrauenswürdige Gruppe A zurückgelesen.
    player = legacy_player(first_name: 'Ida', last_name: 'Rueckkopplung', birthdate: '1992-06-06')
    create(:player, first_name: 'Ida', last_name: 'Rueckkopplung', birthdate: '1992-06-06',
                    clubs: [LegacyImport::HomeClubBackfill.build_entry(club_id: @other_club.id),
                            home_entry(@other_club, valid_until: 1.year.ago.iso8601)])

    result = data.decide_for(player)

    assert_equal 'M', result[:group], 'nur der echte, geschlossene Eintrag zählt'
    assert_nil result[:club_id]
  end

  test 'ein unlesbares valid_until bricht den Lauf nicht ab' do
    player = legacy_player(first_name: 'Kai', last_name: 'Kaputtdatum', birthdate: '1994-04-14')
    create(:player, first_name: 'Kai', last_name: 'Kaputtdatum', birthdate: '1994-04-14',
                    clubs: [{ 'club_id' => @other_club.id, 'home_club' => true,
                              'created_at' => '2015-08-01T00:00:00+02:00', 'valid_until' => '0000-00-00' }])

    result = nil
    assert_nothing_raised { result = data.decide_for(player) }
    assert_equal 'M', result[:group], 'unlesbar gilt als abgelaufen'
  end

  test 'Profil ohne Geburtsdatum wird nicht geschrieben' do
    player = create(:player, first_name: 'Max', last_name: 'Ohnedatum', birthdate: nil, clubs: [],
                             with_licenses: [{ id: 'LIC:fvn:2013_2014:9', team: @team, status: License::APPROVED }])
    create(:player, first_name: 'Max', last_name: 'Ohnedatum', birthdate: '1990-01-01',
                    clubs: [home_entry(@other_club)])

    result = data.decide_for(player)

    assert_equal 'K', result[:group]
    assert_nil result[:club_id], 'ohne Abgleich darf kein Verein gesetzt werden'
  end

  test 'Platzhalter- und deaktivierte Vereine landen in der Ignore-Liste' do
    junk = create(:club, name: 'Ablage Doppelung')
    inaktiv = create(:club, name: 'TSV Alt', deactivated_at: Time.current)

    ids = data.ignore_club_ids

    assert_includes ids, junk.id
    assert_includes ids, inaktiv.id
    assert_not_includes ids, @club.id
  end

  test 'earliest_license_start liefert den frühesten Verlaufszeitpunkt beim Zielverein' do
    other_team = create(:team, club: @other_club)
    licenses = [
      { id: 'LIC:fvn:2013_2014:1', team: @team, status: License::APPROVED,
        created_at: '2013-09-10T16:36:37' },
      { id: 'LIC:fvn:2012_2013:2', team: @team, status: License::APPROVED,
        created_at: '2012-08-31T15:14:19' },
      { id: 'LIC:fvn:2011_2012:3', team: other_team, status: License::APPROVED,
        created_at: '2011-01-01T00:00:00' }
    ]
    player = legacy_player(licenses:)
    subject = data

    assert_equal '2012-08-31T15:14:19', subject.earliest_license_start(player, @club.id),
                 'der frühere Eintrag desselben Vereins gewinnt, der noch frühere anderen Vereins zählt nicht'
    assert_equal '2011-01-01T00:00:00', subject.earliest_license_start(player, @other_club.id)
    assert_nil subject.earliest_license_start(player, create(:club).id)
  end

  # ── Berichtshilfen ────────────────────────────────────────────────────────

  test 'profiles_without_legacy_marker findet Profile ohne LIC:-Lizenz' do
    mit = legacy_player
    ohne = create(:player, clubs: [], licenses: [])

    assert_equal [ohne.id], data.profiles_without_legacy_marker([mit, ohne]).map(&:id)
  end

  test 'profiles_failing_validation findet Profile ohne nation_id' do
    gueltig = legacy_player
    ungueltig = legacy_player(first_name: 'Ohne', last_name: 'Nation')
    ungueltig.update_columns(nation_id: nil)

    assert_equal [ungueltig.id], data.profiles_failing_validation([gueltig, ungueltig.reload]).map(&:id)
  end

  # ── Wirkung ───────────────────────────────────────────────────────────────

  test 'nach dem Backfill steht das Profil in der Vereins-Spielerliste' do
    player = legacy_player
    assert_not_includes @club.players.map(&:id), player.id

    subject = data
    entry = LegacyImport::HomeClubBackfill.build_entry(
      club_id: @club.id, created_at: subject.earliest_license_start(player, @club.id)
    )
    new_clubs, status = LegacyImport::HomeClubBackfill.apply(player.clubs, entry)
    assert_equal :written, status
    player.update!(clubs: new_clubs)

    assert_includes @club.reload.players.map(&:id), player.id
  end

  test 'Club#players zeigt einen geschlossenen Eintrag nicht (Begründung für valid_until = nil)' do
    player = legacy_player
    player.update!(clubs: [home_entry(@club, valid_until: '2014-07-31T23:59:59')])

    assert_not_includes @club.reload.players.map(&:id), player.id
  end

  test 'der Verein kann nach dem Backfill einen Merge-Antrag stellen' do
    player = legacy_player
    master = create(:player, first_name: 'Phillip', last_name: 'Musterberg', birthdate: '1997-09-17',
                             clubs: [home_entry(@club)])
    user = create(:user)

    player.update!(clubs: [LegacyImport::HomeClubBackfill.build_entry(club_id: @club.id)])

    request = PlayerChangeRequest.new(player: master, club: @club, correction_type: 'merge',
                                      secondary_player_id: player.id, status: 'pending',
                                      requested_by_user_id: user.id)

    assert request.valid?, "erwartet gültig, Fehler: #{request.errors.full_messages.join(', ')}"
  end

  test 'ohne clubs-Eintrag scheitert der Merge-Antrag an der Vereinszugehörigkeit' do
    player = legacy_player
    master = create(:player, first_name: 'Phillip', last_name: 'Musterberg', birthdate: '1997-09-17',
                             clubs: [home_entry(@club)])
    user = create(:user)

    request = PlayerChangeRequest.new(player: master, club: @club, correction_type: 'merge',
                                      secondary_player_id: player.id, status: 'pending',
                                      requested_by_user_id: user.id)

    assert_not request.valid?
    assert_includes request.errors.full_messages.join(', '), 'gehört nicht zum angegebenen Verein'
  end
end
