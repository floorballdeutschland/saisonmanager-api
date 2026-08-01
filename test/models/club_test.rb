require 'test_helper'

class ClubTest < ActiveSupport::TestCase
  # Issue #193: meta_hash greift für den LV-Logo-Fallback auf
  # state_association#logo_url zu. Ohne Eager-Loading lud admin_user_clubs den
  # Landesverband samt Logo-Attachment einzeln pro GameOperation nach. Mit dem
  # Preload bleibt die state_associations-Query-Zahl konstant (= 1), statt
  # linear mit der Zahl der Verbände zu wachsen, und das Logo wird mitgeladen.
  #
  # Bewusst nicht geprüft: die separate, von #193 nicht abgedeckte N+1 über das
  # GameOperation-eigene `banner` (banner_url) – daher zählen wir gezielt die
  # state_associations- und die Logo-Attachment-Queries, nicht alle
  # active_storage_attachments-Queries.
  test 'admin_user_clubs lädt LV + Logo ohne N+1 (Issue #193)' do
    create(:setting, current_season_id: '18')
    sa1 = StateAssociation.create!(name: "LV A #{SecureRandom.hex(4)}", short_name: 'A')
    sa2 = StateAssociation.create!(name: "LV B #{SecureRandom.hex(4)}", short_name: 'B')
    GameOperation.create!(name: 'GO A', short_name: 'GOA', path: "go-a-#{SecureRandom.hex(4)}", state_association: sa1)
    GameOperation.create!(name: 'GO B', short_name: 'GOB', path: "go-b-#{SecureRandom.hex(4)}", state_association: sa2)

    admin = User.create!(user_name: "n1admin_#{SecureRandom.hex(4)}", password: 'password123',
                         password_confirmation: 'password123',
                         permissions: [{ 'user_group_id' => 1, 'game_operation_id' => 0 }], teams: [])

    sqls = capture_sql { Club.admin_user_clubs(admin) }
    sa_queries = sqls.count { |s| s =~ /\bfrom\s+"state_associations"/i }

    # Belongs-to-Preload: eine Query für alle Landesverbände statt einer pro GO.
    # Ohne den Fix skaliert dieser Wert linear mit der Zahl der GameOperations.
    assert_operator sa_queries, :<=, 1, "Erwartet höchstens 1 state_associations-Query, war #{sa_queries}"
  end

  # Ergänzend zum N+1-Test oben: das nested Preload lädt nicht nur den
  # Landesverband, sondern auch dessen Logo-Attachment vor, sodass der
  # logo_url-Fallback in meta_hash kein has_one_attached-Logo einzeln nachlädt.
  test 'state_association-Preload lädt das Logo-Attachment mit (Issue #193)' do
    sa = StateAssociation.create!(name: "LV #{SecureRandom.hex(4)}", short_name: 'L')
    GameOperation.create!(name: 'GO', short_name: 'GO', path: "go-#{SecureRandom.hex(4)}", state_association: sa)

    gos = GameOperation.includes(state_association: { logo_attachment: :blob })
                       .where(state_association_id: sa.id).to_a

    # Lazy nachgeladene has_one_attached-Logos erkennt man am LIMIT-Suffix.
    logo_lazy_queries = capture_sql { gos.each { |g| g.state_association&.logo_url } }
                        .count { |s| s =~ /from\s+"active_storage_attachments".*\blimit\b/im }

    assert_equal 0, logo_lazy_queries,
                 "Logo-Attachment wurde lazy nachgeladen (#{logo_lazy_queries} Queries) statt aus dem Preload"
  end

  # Club#players(include_deactivated:) – der Zweig, der die VM-Spielerliste speist.
  # Aufgenommen wird nur, wessen Zugehoerigkeit die Deaktivierung selbst geschlossen
  # hat; alles andere bleibt draussen wie bisher.
  test 'players(include_deactivated: true) nimmt nur von der Deaktivierung geschlossene Zugehoerigkeiten' do
    club = create(:club)
    user_id = 4711

    aktiv       = create(:player, clubs: [{ 'club_id' => club.id, 'home_club' => true }])
    deaktiviert = create(:player, clubs: [{ 'club_id' => club.id, 'home_club' => true }])
    deaktiviert.deactivate!(user_id, reason: 'Karriereende')

    # Zweitspielrecht, das vor einem Jahr ablief; deaktiviert wurde spaeter von
    # derselben Person. Der Verein ist nicht mehr zustaendig, valid_set_by allein
    # wuerde ihn aber wieder einblenden.
    ausgelaufen = create(:player, clubs: [
      { 'club_id' => create(:club).id, 'home_club' => true },
      { 'club_id' => club.id, 'home_club' => false,
        'valid_until' => 1.year.ago.iso8601, 'valid_set_by' => user_id }
    ])
    ausgelaufen.deactivate!(user_id, reason: 'Karriereende')

    # Deaktiviert von einer anderen Person als der, die die Zugehoerigkeit geschlossen
    # hat – dann hat diese Deaktivierung sie nicht geschlossen.
    fremder_ausloeser = create(:player, clubs: [
      { 'club_id' => create(:club).id, 'home_club' => true },
      { 'club_id' => club.id, 'home_club' => false,
        'valid_until' => 1.year.ago.iso8601, 'valid_set_by' => user_id }
    ])
    fremder_ausloeser.deactivate!(user_id + 1, reason: 'Karriereende')

    # Altdaten: geschlossen ohne valid_set_by. Bleiben bewusst ausgeblendet, wie vor
    # der Aenderung auch – reactivate! oeffnet diese Zugehoerigkeit ebenfalls nicht.
    legacy = create(:player, clubs: [{ 'club_id' => club.id, 'home_club' => true,
                                       'valid_until' => 2.years.ago.iso8601 }])
    legacy.deactivate!(user_id, reason: 'Karriereende')

    ids = club.players(include_deactivated: true).map(&:id)
    assert_includes ids, aktiv.id
    assert_includes ids, deaktiviert.id
    refute_includes ids, ausgelaufen.id, 'abgelaufenes Zweitspielrecht darf nicht wieder auftauchen'
    refute_includes ids, fremder_ausloeser.id, 'fremder valid_set_by darf nicht als Deaktivierung gelten'
    refute_includes ids, legacy.id, 'Altdaten ohne valid_set_by bleiben ausgeblendet'

    # Standardpfad unveraendert: nur aktive Spieler*innen.
    assert_equal [aktiv.id], club.players.map(&:id)
  end

  # Die Zeitschranke muss den realistischen Fall treffen, nicht nur Jahresabstaende:
  # Wechsel am Morgen, Deaktivierung am Abend, beides von derselben Person. Der alte
  # Verein darf das Profil dadurch nicht zurueckbekommen, der neue schon.
  test 'players(include_deactivated: true) trennt Wechsel und Deaktivierung am selben Tag' do
    create(:setting)
    alt = create(:club)
    neu = create(:club)
    user_id = create(:user, :admin).id
    player = create(:player, clubs: [{ 'club_id' => alt.id, 'home_club' => true }])

    travel_to 8.hours.ago do
      player.transfer(neu.id, user_id)
    end
    player.reload.deactivate!(user_id, reason: 'Karriereende')

    refute_includes alt.players(include_deactivated: true).map(&:id), player.id
    assert_includes neu.players(include_deactivated: true).map(&:id), player.id
  end

  # Tagesgrenze der bestehenden valid_until-Pruefung (to_date-Vergleich, unveraendert
  # aus der Zeit vor include_deactivated): heute ablaufend zaehlt als abgelaufen,
  # morgen ablaufend als gueltig. Festgehalten, weil der Ausdruck beim Einbau des
  # neuen Zweigs umgebaut wurde.
  test 'players zaehlt eine heute ablaufende Zugehoerigkeit als abgelaufen' do
    club = create(:club)
    heute  = create(:player, clubs: [{ 'club_id' => club.id, 'valid_until' => Time.current.end_of_day.iso8601 }])
    morgen = create(:player, clubs: [{ 'club_id' => club.id, 'valid_until' => 1.day.from_now.iso8601 }])

    ids = club.players.map(&:id)
    refute_includes ids, heute.id
    assert_includes ids, morgen.id
  end

  # merge_into! deaktiviert die Dublette, sie erfuellt damit die Bedingung oben.
  # Wieder eingeblendet und reaktiviert waere sie genau das zweite Profil, das der
  # Merge beseitigen sollte.
  test 'players(include_deactivated: true) laesst zusammengefuehrte Dubletten aus' do
    club = create(:club)
    master   = create(:player, clubs: [{ 'club_id' => club.id, 'home_club' => true }])
    dublette = create(:player, clubs: [{ 'club_id' => club.id, 'home_club' => true }])

    dublette.merge_into!(master, 4711)

    ids = club.players(include_deactivated: true).map(&:id)
    assert_includes ids, master.id
    refute_includes ids, dublette.id
  end

  private

  def capture_sql
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
