require 'test_helper'

class ClubTest < ActiveSupport::TestCase
  # Ein Verein gehört genau einem Verband; nur dessen SBK verwaltet die
  # Stammdaten. Ein Gast-Eintrag im game_operations_hash ist kein Zugriffsgrund –
  # die Einträge stammen aus dem Altdaten-Import 2010–2014 und werden nicht
  # nachgeführt. Der ausdrückliche Weg für fremde Vereine ist die Freigabe, und
  # die landet in einem eigenen Block, damit erkennbar bleibt, wem der Verein
  # gehört.
  test 'admin_user_clubs zeigt Gast-Vereine nicht in der eigenen Verbandsliste' do
    create(:setting, current_season_id: '18')
    fremd_sa = create(:state_association)
    fremd_go = create(:game_operation, state_association_id: fremd_sa.id)
    eigen_sa = create(:state_association)
    eigen_go = create(:game_operation, state_association_id: eigen_sa.id)

    eigener = create(:club, state_association_id: eigen_sa.id, game_operations_hash: [
      { 'home_game_operation' => true, 'game_operation_id' => eigen_go.id }
    ])
    gast = create(:club, state_association_id: fremd_sa.id, game_operations_hash: [
      { 'home_game_operation' => true, 'game_operation_id' => fremd_go.id },
      { 'home_game_operation' => false, 'game_operation_id' => eigen_go.id }
    ])

    sbk = create(:user, :sbk_scoped, game_operation_id: eigen_go.id)
    groups = Club.admin_user_clubs(sbk)

    eigene_box = groups.reject { |g| g[:released] }.flat_map { |g| g[:clubs] }.map { |c| c['id'] || c[:id] }
    assert_includes eigene_box, eigener.id
    assert_not_includes eigene_box, gast.id, 'Gast-Verein darf nicht in der eigenen Verbandsliste stehen'
    assert_empty groups.select { |g| g[:released] }, 'ohne Freigabe gibt es keinen Freigabe-Block'
  end

  test 'admin_user_clubs zeigt freigegebene Vereine im eigenen Block' do
    create(:setting, current_season_id: '18')
    grantor_sa = create(:state_association)
    grantor_go = create(:game_operation, state_association_id: grantor_sa.id)
    eigen_sa = create(:state_association)
    eigen_go = create(:game_operation, state_association_id: eigen_sa.id)

    freigegeben = create(:club, state_association_id: grantor_sa.id, game_operations_hash: [
      { 'home_game_operation' => true, 'game_operation_id' => grantor_go.id },
      { 'home_game_operation' => false, 'game_operation_id' => eigen_go.id }
    ])
    StateAssociationRelease.create!(grantor_state_association_id: grantor_sa.id,
                                    recipient_game_operation_id: eigen_go.id,
                                    season_id: Setting.current_season_id)

    sbk = create(:user, :sbk_scoped, game_operation_id: eigen_go.id)
    groups = Club.admin_user_clubs(sbk)

    eigene_box = groups.reject { |g| g[:released] }.flat_map { |g| g[:clubs] }.map { |c| c['id'] || c[:id] }
    frei_box = groups.select { |g| g[:released] }.flat_map { |g| g[:clubs] }.map { |c| c['id'] || c[:id] }

    # Genau einmal auf der Seite, und zwar im Freigabe-Block. Vorher stand der
    # Verein in beiden Boxen – auf Produktion traf das 5 Vereine.
    assert_not_includes eigene_box, freigegeben.id
    assert_includes frei_box, freigegeben.id
  end

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

    # Die beiden folgenden Faelle haben ihr valid_until bewusst am Zeitpunkt der
    # Deaktivierung: sie fallen allein am Auslöser-Vergleich heraus, nicht schon an der
    # Zeitschranke. Sonst wuerde der Vergleich von keinem Test festgehalten.
    #
    # Geschlossen von einer anderen Person als der, die deaktiviert hat.
    fremder_ausloeser = create(:player, clubs: [{ 'club_id' => club.id, 'home_club' => true }])
    fremder_ausloeser.deactivate!(user_id, reason: 'Karriereende')
    fremder_ausloeser.update_column(:deactivated_by, user_id + 1)

    # Altdaten: geschlossen ohne valid_set_by. Bleiben bewusst ausgeblendet, wie vor
    # der Aenderung auch.
    legacy = create(:player, clubs: [{ 'club_id' => club.id, 'home_club' => true }])
    legacy.deactivate!(user_id, reason: 'Karriereende')
    legacy.clubs.each { |c| c.delete('valid_set_by') }
    legacy.save!(validate: false)

    ids = club.players(include_deactivated: true).map(&:id)
    assert_includes ids, aktiv.id
    assert_includes ids, deaktiviert.id
    refute_includes ids, ausgelaufen.id, 'abgelaufenes Zweitspielrecht darf nicht wieder auftauchen'
    refute_includes ids, fremder_ausloeser.id, 'fremder valid_set_by darf nicht als Deaktivierung gelten'
    refute_includes ids, legacy.id, 'Altdaten ohne valid_set_by bleiben ausgeblendet'

    # Standardpfad unveraendert: nur aktive Spieler*innen.
    assert_equal [aktiv.id], club.players.map(&:id)
  end

  # Die Zeitschranke wird knapp geprueft, nicht nur auf Jahresabstand: ein Wechsel
  # wenige Sekunden vor der Deaktivierung gehoert schon nicht mehr zu ihr. Der alte
  # Verein darf das Profil also nicht zurueckbekommen, der neue schon.
  test 'players(include_deactivated: true) trennt Wechsel und Deaktivierung' do
    create(:setting)
    alt = create(:club)
    neu = create(:club)
    user_id = create(:user, :admin).id
    player = create(:player, clubs: [{ 'club_id' => alt.id, 'home_club' => true }])

    travel_to 10.seconds.ago do
      player.transfer(neu.id, user_id)
    end
    player.reload.deactivate!(user_id, reason: 'Karriereende')

    refute_includes alt.players(include_deactivated: true).map(&:id), player.id
    assert_includes neu.players(include_deactivated: true).map(&:id), player.id
  end

  # Tagesgrenze der bestehenden valid_until-Pruefung (to_date-Vergleich, unveraendert
  # aus der Zeit vor include_deactivated): heute ablaufend zaehlt als abgelaufen,
  # morgen ablaufend als gueltig. Festgehalten, weil der Ausdruck beim Einbau des
  # neuen Zweigs umgebaut wurde. Feste Uhrzeit, damit der Test nicht kurz vor
  # Mitternacht seine Bedeutung verliert.
  test 'players zaehlt eine heute ablaufende Zugehoerigkeit als abgelaufen' do
    travel_to Time.zone.parse('2026-08-01 12:00') do
      club = create(:club)
      heute  = create(:player, clubs: [{ 'club_id' => club.id, 'valid_until' => Time.current.end_of_day.iso8601 }])
      morgen = create(:player, clubs: [{ 'club_id' => club.id, 'valid_until' => 1.day.from_now.iso8601 }])

      ids = club.players.map(&:id)
      refute_includes ids, heute.id
      assert_includes ids, morgen.id
    end
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

  # --- Gruppierung nach Landesverband (statt nach Spielbetrieb) ---------------
  #
  # Die Überschriften der Vereinsverwaltung sind Landesverbände. Der
  # Zugriffsumfang bleibt am Spielbetrieb: die Tests oben (Gast-Vereine,
  # Freigabe-Block) gelten unverändert weiter.

  test 'admin_user_clubs gruppiert nach eingestelltem Landesverband, nicht nach Spielbetrieb' do
    create(:setting, current_season_id: '18')
    lv_nb = create(:state_association, name: 'Floorball Verband Niedersachsen')
    lv_sh = create(:state_association, name: 'Floorballverband Schleswig-Holstein')
    go_nb = create(:game_operation, state_association_id: lv_nb.id)

    # Beide Vereine haben denselben Heimat-Spielbetrieb, gehören aber
    # verschiedenen Landesverbänden – der Fall, der die Fehlanzeige auslöste.
    heimisch = create(:club, name: 'A Verein NB', state_association_id: lv_nb.id,
                             game_operations_hash: [{ 'game_operation_id' => go_nb.id,
                                                      'home_game_operation' => true }])
    fremd = create(:club, name: 'B Verein SH', state_association_id: lv_sh.id,
                          game_operations_hash: [{ 'game_operation_id' => go_nb.id,
                                                   'home_game_operation' => true }])

    groups = Club.admin_user_clubs(create(:user, :admin))
      .to_h { |g| [g[:name], g[:clubs].map { |c| c[:id] }] }

    assert_equal [heimisch.id], groups['Floorball Verband Niedersachsen']
    assert_equal [fremd.id], groups['Floorballverband Schleswig-Holstein']
  end

  test 'admin_user_clubs zeigt Vereine des eigenen Spielbetriebs auch bei fremdem Landesverband' do
    create(:setting, current_season_id: '18')
    lv_nb = create(:state_association, name: 'Niedersachsen')
    lv_hh = create(:state_association, name: 'Hamburg')
    go_nb = create(:game_operation, state_association_id: lv_nb.id)

    # Wie ETV Hamburg: Heimat-Spielbetrieb Niedersachsen, Landesverband Hamburg.
    # Das ist kein Gast-Eintrag – der Verein gehört in diesen Spielbetrieb und
    # muss dem SBK deshalb erhalten bleiben, nur unter eigener Überschrift.
    etv = create(:club, state_association_id: lv_hh.id,
                        game_operations_hash: [{ 'game_operation_id' => go_nb.id,
                                                 'home_game_operation' => true }])

    sbk_nb = create(:user, :sbk_scoped, game_operation_id: go_nb.id)
    groups = Club.admin_user_clubs(sbk_nb)
    hamburg = groups.find { |g| g[:name] == 'Hamburg' }

    assert hamburg, "Erwartet Gruppe 'Hamburg', vorhanden: #{groups.map { |g| g[:name] }.inspect}"
    assert_equal [etv.id], hamburg[:clubs].map { |c| c[:id] }
    # Nicht als „freigegeben" markiert: der Verein ist bearbeitbar, keine
    # Freigabe nötig.
    refute hamburg[:released]
  end

  test 'admin_user_clubs führt Vereine ohne Landesverband unter dem Bundesverband' do
    create(:setting, current_season_id: '18')
    # Der Fallback zeigt auf eine feste ID – hier wird der FVD-Datensatz mit
    # genau dieser ID angelegt, wie in Produktion vorhanden. Der explizite
    # Insert lässt die Postgres-Sequence unberührt, deshalb danach nachziehen,
    # sonst kollidiert der nächste Factory-Datensatz mit dieser ID.
    fvd = StateAssociation.create!(id: Club::FALLBACK_STATE_ASSOCIATION_ID,
                                   name: 'Floorball-Verband Deutschland e.V.', short_name: 'FVD')
    ActiveRecord::Base.connection.reset_pk_sequence!('state_associations')

    go = create(:game_operation, state_association_id: create(:state_association).id)
    ohne_lv = create(:club, state_association_id: nil,
                            game_operations_hash: [{ 'game_operation_id' => go.id,
                                                     'home_game_operation' => true }])

    groups = Club.admin_user_clubs(create(:user, :admin))
    fvd_group = groups.find { |g| g[:state_association_id] == fvd.id }

    assert fvd_group, 'Verein ohne Landesverband darf nicht aus der Liste fallen'
    assert_includes fvd_group[:clubs].map { |c| c[:id] }, ohne_lv.id
  end

  test 'admin_user_clubs verliert Vereine mit ins Leere zeigendem Landesverband nicht' do
    create(:setting, current_season_id: '18')
    go = create(:game_operation, state_association_id: create(:state_association).id)
    # Kein FVD-Datensatz und ein Verweis auf einen gelöschten Landesverband: der
    # Verein muss trotzdem auftauchen, sonst wird er unauffindbar.
    waise = create(:club, state_association_id: 999_999,
                          game_operations_hash: [{ 'game_operation_id' => go.id,
                                                   'home_game_operation' => true }])

    groups = Club.admin_user_clubs(create(:user, :admin))
    rest = groups.find { |g| g[:name] == 'Ohne Landesverband' }

    assert rest, "Erwartet Restgruppe, vorhanden: #{groups.map { |g| g[:name] }.inspect}"
    assert_equal [waise.id], rest[:clubs].map { |c| c[:id] }
  end

  test 'admin_user_clubs listet einen Verein genau einmal, auch mit Gast-Eintrag' do
    create(:setting, current_season_id: '18')
    lv = create(:state_association, name: 'Niedersachsen')
    go_home = create(:game_operation, state_association_id: lv.id)
    go_guest = create(:game_operation, state_association_id: create(:state_association).id)

    club = create(:club, state_association_id: lv.id,
                         game_operations_hash: [
                           { 'game_operation_id' => go_home.id, 'home_game_operation' => true },
                           { 'game_operation_id' => go_guest.id, 'home_game_operation' => false }
                         ])

    groups = Club.admin_user_clubs(create(:user, :admin))

    assert_equal [club.id], groups.flat_map { |g| g[:clubs].map { |c| c[:id] } }
  end

  test 'admin_user_clubs zeigt deaktivierte Vereine nur mit include_deactivated' do
    create(:setting, current_season_id: '18')
    lv = create(:state_association)
    go = create(:game_operation, state_association_id: lv.id)
    goh = [{ 'game_operation_id' => go.id, 'home_game_operation' => true }]

    aktiv = create(:club, state_association_id: lv.id, game_operations_hash: goh)
    inaktiv = create(:club, state_association_id: lv.id, game_operations_hash: goh,
                            deactivated_at: Time.current)
    admin = create(:user, :admin)

    assert_equal [aktiv.id],
                 Club.admin_user_clubs(admin).flat_map { |g| g[:clubs].map { |c| c[:id] } }
    assert_equal [aktiv.id, inaktiv.id].sort,
                 Club.admin_user_clubs(admin, include_deactivated: true)
                     .flat_map { |g| g[:clubs].map { |c| c[:id] } }.sort
  end

  test 'admin_user_clubs zeigt freigegebene Vereine nicht zusätzlich in der Landesverbands-Gruppe' do
    create(:setting, current_season_id: '18')
    grantor_sa = create(:state_association, name: 'Hamburg')
    eigen_go = create(:game_operation, state_association_id: create(:state_association).id)

    # Gehört dem freigebenden Landesverband und hat seinen Heimat-Spielbetrieb
    # beim Empfänger – steht deshalb schon in der Landesverbands-Gruppe.
    im_spielbetrieb = create(:club, state_association_id: grantor_sa.id,
                                    game_operations_hash: [{ 'game_operation_id' => eigen_go.id,
                                                             'home_game_operation' => true }])
    # Nur über die Freigabe sichtbar.
    nur_freigabe = create(:club, state_association_id: grantor_sa.id, game_operations_hash: [])

    StateAssociationRelease.create!(grantor_state_association_id: grantor_sa.id,
                                    recipient_game_operation_id: eigen_go.id,
                                    season_id: Setting.current_season_id)

    groups = Club.admin_user_clubs(create(:user, :sbk_scoped, game_operation_id: eigen_go.id))
    frei = groups.select { |g| g[:released] }.flat_map { |g| g[:clubs].map { |c| c[:id] } }
    eigen = groups.reject { |g| g[:released] }.flat_map { |g| g[:clubs].map { |c| c[:id] } }

    assert_equal [nur_freigabe.id], frei
    assert_equal [im_spielbetrieb.id], eigen
  end

  test 'admin_user_clubs behält den Block „Eigene Vereine" für die VM-Rolle' do
    create(:setting, current_season_id: '18')
    eigen_go = create(:game_operation, state_association_id: create(:state_association).id)
    fremd_go = create(:game_operation, state_association_id: create(:state_association).id)

    # Verein außerhalb des eigenen Spielbetriebs, auf den der Nutzer nur als
    # Vereinsmanager Zugriff hat.
    vm_club = create(:club, state_association_id: create(:state_association).id,
                            game_operations_hash: [{ 'game_operation_id' => fremd_go.id,
                                                     'home_game_operation' => true }])

    user = create(:user, permissions: [
                    { 'user_group_id' => 2, 'game_operation_id' => eigen_go.id },
                    { 'user_group_id' => 4, 'game_operation_id' => 0, 'club_id' => vm_club.id }
                  ])

    eigene = Club.admin_user_clubs(user).find { |g| g[:name] == 'Eigene Vereine' }

    assert eigene, 'Block „Eigene Vereine" fehlt'
    assert_equal [vm_club.id], eigene[:clubs].map { |c| c[:id] }
  end

  test 'admin_user_clubs liefert ohne Admin-/SBK-/VM-Rechte keine Gruppen' do
    create(:setting, current_season_id: '18')
    go = create(:game_operation, state_association_id: create(:state_association).id)
    create(:club, state_association_id: create(:state_association).id,
                  game_operations_hash: [{ 'game_operation_id' => go.id,
                                           'home_game_operation' => true }])

    assert_empty Club.admin_user_clubs(create(:user))
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
