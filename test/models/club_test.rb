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
  # Zugriffsumfang bleibt am Spielbetrieb – die Tests
  # 'admin_user_clubs zeigt Gast-Vereine nicht in der eigenen Verbandsliste' und
  # 'admin_user_clubs zeigt freigegebene Vereine im eigenen Block' am Anfang
  # dieser Datei gelten unverändert weiter.

  test 'admin_user_clubs gruppiert nach eingestelltem Landesverband, nicht nach Spielbetrieb' do
    create(:setting, current_season_id: '18')
    lv_nb = create(:state_association, name: 'Floorball Verband Niedersachsen')
    lv_sh = create(:state_association, name: 'Floorballverband Schleswig-Holstein')
    go_nb = create(:game_operation, state_association_id: lv_nb.id)

    # Beide Vereine haben denselben Heimat-Spielbetrieb, gehören aber
    # verschiedenen Landesverbänden – der Fall, der die Fehlanzeige auslöste.
    heimisch = create(:club, name: 'A Verein NB', state_association_id: lv_nb.id,
                             game_operations_hash: home_hash(go_nb))
    fremd = create(:club, name: 'B Verein SH', state_association_id: lv_sh.id,
                          game_operations_hash: home_hash(go_nb))

    groups = Club.admin_user_clubs(create(:user, :admin))

    assert_equal [heimisch.id], club_ids(find_group(groups, 'Floorball Verband Niedersachsen'))
    assert_equal [fremd.id], club_ids(find_group(groups, 'Floorballverband Schleswig-Holstein'))
  end

  test 'admin_user_clubs zeigt Vereine des eigenen Spielbetriebs auch bei fremdem Landesverband' do
    create(:setting, current_season_id: '18')
    lv_nb = create(:state_association, name: 'Niedersachsen')
    lv_hh = create(:state_association, name: 'Hamburg')
    go_nb = create(:game_operation, state_association_id: lv_nb.id)

    # Wie ETV Hamburg: Heimat-Spielbetrieb Niedersachsen, Landesverband Hamburg.
    # Das ist kein Gast-Eintrag – der Verein gehört in diesen Spielbetrieb und
    # muss dem SBK deshalb erhalten bleiben, nur unter eigener Überschrift.
    etv = create(:club, state_association_id: lv_hh.id, game_operations_hash: home_hash(go_nb))

    groups = Club.admin_user_clubs(create(:user, :sbk_scoped, game_operation_id: go_nb.id))
    hamburg = find_group(groups, 'Hamburg')

    assert hamburg, "Erwartet Gruppe 'Hamburg', vorhanden: #{group_names(groups).inspect}"
    assert_equal [etv.id], club_ids(hamburg)
    # Nicht als „freigegeben" markiert: der Verein ist bearbeitbar, es braucht
    # keine Freigabe.
    refute hamburg[:released]
  end

  test 'admin_user_clubs führt Vereine ohne Landesverband unter dem Bundesverband' do
    create(:setting, current_season_id: '18')
    fvd = create(:state_association, name: 'Floorball-Verband Deutschland e.V.', short_name: 'FVD')
    go = create(:game_operation, state_association_id: create(:state_association).id)

    ohne_lv = create(:club, state_association_id: nil, game_operations_hash: home_hash(go))

    groups = Club.admin_user_clubs(create(:user, :admin))
    fvd_group = groups.find { |g| g[:state_association_id] == fvd.id }

    assert fvd_group, 'Verein ohne Landesverband darf nicht aus der Liste fallen'
    assert_includes club_ids(fvd_group), ohne_lv.id
  end

  # Der Bundesverband wird über das Kürzel aufgelöst, nicht über eine feste ID.
  # db/seeds.rb legt unter id 1 „SBK Ost" an – eine hartkodierte 1 hätte die
  # Vereine ohne Landesverband dort unter genau den Dachverband gruppiert, den
  # diese Gruppierung loswerden soll.
  test 'admin_user_clubs nutzt ohne FVD-Datensatz die Restgruppe statt einer fremden ID' do
    create(:setting, current_season_id: '18')
    fremd = create(:state_association, name: 'SBK Ost', short_name: 'SBKOST')
    go = create(:game_operation, state_association_id: fremd.id)
    ohne_lv = create(:club, state_association_id: nil, game_operations_hash: home_hash(go))

    groups = Club.admin_user_clubs(create(:user, :admin))

    assert_equal [ohne_lv.id], club_ids(find_group(groups, 'Ohne Landesverband'))
    assert_empty club_ids(find_group(groups, 'SBK Ost'))
  end

  test 'admin_user_clubs verliert Vereine mit ins Leere zeigendem Landesverband nicht' do
    create(:setting, current_season_id: '18')
    go = create(:game_operation, state_association_id: create(:state_association).id)
    # Verweis auf einen gelöschten Landesverband – auf clubs.state_association_id
    # liegt kein Fremdschlüssel. Der Verein muss trotzdem auftauchen, sonst wird
    # er unauffindbar.
    waise = create(:club, state_association_id: 999_999, game_operations_hash: home_hash(go))

    groups = Club.admin_user_clubs(create(:user, :admin))
    rest = find_group(groups, 'Ohne Landesverband')

    assert rest, "Erwartet Restgruppe, vorhanden: #{group_names(groups).inspect}"
    assert_equal [waise.id], club_ids(rest)
  end

  # Vereine ohne Heim-Spielbetrieb waren in der Vereinsverwaltung unsichtbar und
  # damit nicht bearbeitbar (in Produktion 13 neu angelegte Vereine). Sie hängen
  # an keinem Spielbetrieb, deshalb sieht sie nur der globale Zugriff.
  test 'admin_user_clubs zeigt Vereine ohne Heim-Spielbetrieb dem globalen Zugriff' do
    create(:setting, current_season_id: '18')
    create(:state_association, name: 'Floorball-Verband Deutschland e.V.', short_name: 'FVD')
    go = create(:game_operation, state_association_id: create(:state_association).id)

    ohne_go = create(:club, state_association_id: nil, game_operations_hash: [])
    gast_hash = [{ 'game_operation_id' => go.id, 'home_game_operation' => false }]
    nur_gast = create(:club, state_association_id: nil, game_operations_hash: gast_hash)

    ids = all_club_ids(Club.admin_user_clubs(create(:user, :admin)))

    assert_includes ids, ohne_go.id
    assert_includes ids, nur_gast.id
  end

  test 'admin_user_clubs zeigt Vereine ohne Heim-Spielbetrieb nicht einem einzelnen Verband' do
    create(:setting, current_season_id: '18')
    go = create(:game_operation, state_association_id: create(:state_association).id)
    create(:club, state_association_id: nil, game_operations_hash: [])

    # Ein einzelner Landesverband soll nicht die unzugeordneten Vereine aller
    # anderen in seiner Liste haben.
    ids = all_club_ids(Club.admin_user_clubs(create(:user, :sbk_scoped, game_operation_id: go.id)))

    assert_empty ids
  end

  test 'admin_user_clubs listet einen Verein genau einmal, auch mit Gast-Eintrag' do
    create(:setting, current_season_id: '18')
    lv = create(:state_association, name: 'Niedersachsen')
    go_home = create(:game_operation, state_association_id: lv.id)
    go_guest = create(:game_operation, state_association_id: create(:state_association).id)

    goh = [
      { 'game_operation_id' => go_home.id, 'home_game_operation' => true },
      { 'game_operation_id' => go_guest.id, 'home_game_operation' => false }
    ]
    club = create(:club, state_association_id: lv.id, game_operations_hash: goh)

    assert_equal [club.id], all_club_ids(Club.admin_user_clubs(create(:user, :admin)))
  end

  # Zwei ausdrücklich angelegte Spielbetriebe mit bekannter Reihenfolge: der
  # deaktivierte Verein hängt am zuerst geprüften. Ohne die Klammern um die
  # OR-Kette in home_clubs_of griffe die Deaktiviert-Bedingung nur für den
  # letzten Zweig, und dieser Test fiele auf.
  test 'admin_user_clubs zeigt deaktivierte Vereine nur mit include_deactivated' do
    create(:setting, current_season_id: '18')
    lv = create(:state_association)
    go_first = create(:game_operation, state_association_id: lv.id)
    go_second = create(:game_operation, state_association_id: lv.id)

    inaktiv = create(:club, state_association_id: lv.id, game_operations_hash: home_hash(go_first),
                            deactivated_at: Time.current)
    aktiv = create(:club, state_association_id: lv.id, game_operations_hash: home_hash(go_second))
    admin = create(:user, :admin)

    assert_equal [aktiv.id], all_club_ids(Club.admin_user_clubs(admin))
    assert_equal [aktiv.id, inaktiv.id].sort,
                 all_club_ids(Club.admin_user_clubs(admin, include_deactivated: true)).sort
  end

  test 'admin_user_clubs zeigt freigegebene Vereine nicht zusätzlich in der Landesverbands-Gruppe' do
    create(:setting, current_season_id: '18')
    grantor_sa = create(:state_association, name: 'Hamburg')
    eigen_go = create(:game_operation, state_association_id: create(:state_association).id)

    # Gehört dem freigebenden Landesverband und hat seinen Heimat-Spielbetrieb
    # beim Empfänger – steht deshalb schon in der Landesverbands-Gruppe.
    im_spielbetrieb = create(:club, state_association_id: grantor_sa.id,
                                    game_operations_hash: home_hash(eigen_go))
    # Nur über die Freigabe sichtbar.
    nur_freigabe = create(:club, state_association_id: grantor_sa.id, game_operations_hash: [])

    StateAssociationRelease.create!(grantor_state_association_id: grantor_sa.id,
                                    recipient_game_operation_id: eigen_go.id,
                                    season_id: Setting.current_season_id)

    groups = Club.admin_user_clubs(create(:user, :sbk_scoped, game_operation_id: eigen_go.id))
    released = groups.select { |g| g[:released] }
    own = groups.reject { |g| g[:released] }

    assert_equal [nur_freigabe.id], released.flat_map { |g| club_ids(g) }.sort
    assert_equal [im_spielbetrieb.id], own.flat_map { |g| club_ids(g) }.sort
    # Die Überschrift macht kenntlich, dass der Verein einem fremden Verband
    # gehört und hier nur lesend steht.
    assert_equal ['Hamburg (freigegeben)'], group_names(released)
  end

  test 'admin_user_clubs behält den Block „Eigene Vereine" für die VM-Rolle' do
    create(:setting, current_season_id: '18')
    eigen_go = create(:game_operation, state_association_id: create(:state_association).id)
    fremd_go = create(:game_operation, state_association_id: create(:state_association).id)

    # Verein außerhalb des eigenen Spielbetriebs, auf den der Nutzer nur als
    # Vereinsmanager Zugriff hat.
    vm_club = create(:club, state_association_id: create(:state_association).id,
                            game_operations_hash: home_hash(fremd_go))

    # Bewusst ohne Traits: :sbk_scoped und :vm überschreiben beide `permissions`
    # und lassen sich nicht kombinieren. 2 = SBK, 4 = Vereinsmanager.
    perms = [
      { 'user_group_id' => 2, 'game_operation_id' => eigen_go.id },
      { 'user_group_id' => 4, 'game_operation_id' => 0, 'club_id' => vm_club.id }
    ]
    user = create(:user, permissions: perms)

    eigene = find_group(Club.admin_user_clubs(user), 'Eigene Vereine')

    assert eigene, 'Block „Eigene Vereine" fehlt'
    assert_equal [vm_club.id], club_ids(eigene)
  end

  test 'admin_user_clubs liefert einer reinen VM-Rolle nur die eigenen Vereine' do
    create(:setting, current_season_id: '18')
    go = create(:game_operation, state_association_id: create(:state_association).id)
    vm_club = create(:club, state_association_id: create(:state_association).id,
                            game_operations_hash: home_hash(go))
    create(:club, state_association_id: create(:state_association).id,
                  game_operations_hash: home_hash(go))

    groups = Club.admin_user_clubs(create(:user, :vm, club_id: vm_club.id))

    assert_equal ['Eigene Vereine'], group_names(groups)
    assert_equal [vm_club.id], all_club_ids(groups)
  end

  test 'admin_user_clubs liefert ohne Rollen keine Gruppen' do
    create(:setting, current_season_id: '18')
    go = create(:game_operation, state_association_id: create(:state_association).id)
    create(:club, state_association_id: create(:state_association).id,
                  game_operations_hash: home_hash(go))

    assert_empty Club.admin_user_clubs(create(:user))
  end

  # --- Leere Landesverbände und Verbandshierarchie ----------------------------

  # Ein Landesverband ohne Vereine muss sichtbar bleiben: der Knopf zum Anlegen
  # des ersten Vereins steht in der Oberfläche je Gruppe.
  test 'admin_user_clubs zeigt den eigenen Landesverband auch ohne Vereine' do
    create(:setting, current_season_id: '18')
    lv = create(:state_association, name: 'Leerer Landesverband')
    go = create(:game_operation, state_association_id: lv.id)

    groups = Club.admin_user_clubs(create(:user, :sbk_scoped, game_operation_id: go.id))

    assert_equal ['Leerer Landesverband'], group_names(groups)
    assert_empty club_ids(find_group(groups, 'Leerer Landesverband'))
  end

  test 'admin_user_clubs zeigt Unterverbände einzeln statt des leeren Dachverbands' do
    create(:setting, current_season_id: '18')
    dach = create(:state_association, name: 'SBK Ost', short_name: 'SBKOST')
    sachsen = create(:state_association, name: 'Sachsen', parent_id: dach.id)
    anhalt = create(:state_association, name: 'Sachsen-Anhalt', parent_id: dach.id)
    go = create(:game_operation, state_association_id: dach.id)

    groups = Club.admin_user_clubs(create(:user, :sbk_scoped, game_operation_id: go.id))

    assert_equal [anhalt.name, sachsen.name].sort, group_names(groups).sort
    refute_includes group_names(groups), 'SBK Ost'
  end

  # Der Dachverband verschwindet nur als *leere* Gruppe. Solange ihm aus
  # Altdaten Vereine zugeordnet sind, muss er sichtbar bleiben – sonst wären
  # genau die Vereine unauffindbar, die der Wartungs-Task umhängen soll.
  test 'admin_user_clubs zeigt den Dachverband weiter, wenn ihm Vereine zugeordnet sind' do
    create(:setting, current_season_id: '18')
    dach = create(:state_association, name: 'SBK Ost', short_name: 'SBKOST')
    create(:state_association, name: 'Sachsen', parent_id: dach.id)
    go = create(:game_operation, state_association_id: dach.id)

    altlast = create(:club, state_association_id: dach.id, game_operations_hash: home_hash(go))

    groups = Club.admin_user_clubs(create(:user, :sbk_scoped, game_operation_id: go.id))

    assert_equal [altlast.id], club_ids(find_group(groups, 'SBK Ost'))
  end

  # Ein Verband mittlerer Ebene darf nicht über den Elternteil-Zweig doch noch
  # als leere Gruppe erscheinen. StateAssociation erlaubt beliebige Tiefe.
  test 'admin_user_clubs zeigt einen leeren Verband mittlerer Ebene nicht' do
    create(:setting, current_season_id: '18')
    bund = create(:state_association, name: 'Bundesebene', short_name: 'FVD')
    mitte = create(:state_association, name: 'Mittlere Ebene', parent_id: bund.id)
    blatt = create(:state_association, name: 'Blattverband', parent_id: mitte.id)

    go_bund = create(:game_operation, state_association_id: bund.id)
    go_mitte = create(:game_operation, state_association_id: mitte.id)

    perms = [
      { 'user_group_id' => 2, 'game_operation_id' => go_bund.id },
      { 'user_group_id' => 2, 'game_operation_id' => go_mitte.id }
    ]
    groups = Club.admin_user_clubs(create(:user, permissions: perms))

    assert_equal [blatt.name], group_names(groups)
  end

  test 'admin_user_clubs sortiert die Gruppen nach Namen und hängt die Restgruppe an' do
    create(:setting, current_season_id: '18')
    lv_b = create(:state_association, name: 'B-Verband')
    lv_a = create(:state_association, name: 'A-Verband')
    go_b = create(:game_operation, state_association_id: lv_b.id)
    go_a = create(:game_operation, state_association_id: lv_a.id)

    create(:club, state_association_id: lv_b.id, game_operations_hash: home_hash(go_b))
    create(:club, state_association_id: lv_a.id, game_operations_hash: home_hash(go_a))
    create(:club, state_association_id: 999_999, game_operations_hash: home_hash(go_a))

    assert_equal ['A-Verband', 'B-Verband', 'Ohne Landesverband'],
                 group_names(Club.admin_user_clubs(create(:user, :admin)))
  end

  # Führende Leerzeichen in Verbandsnamen kommen in Produktion vor und würden
  # sonst in der Überschrift landen und die Sortierung verdrehen.
  test 'admin_user_clubs entfernt Leerzeichen am Rand des Verbandsnamens' do
    create(:setting, current_season_id: '18')
    lv = create(:state_association, name: ' Floorball Verband Niedersachsen e.V. ')
    go = create(:game_operation, state_association_id: lv.id)

    groups = Club.admin_user_clubs(create(:user, :sbk_scoped, game_operation_id: go.id))

    assert_equal ['Floorball Verband Niedersachsen e.V.'], group_names(groups)
  end

  private

  # Gruppen-Helfer. Auch gegen Lint/AmbiguousBlockAssociation: ein Block direkt
  # als letztes assert-Argument (`assert_equal [x], g[:clubs].map { ... }`) ist
  # mehrdeutig.
  def club_ids(group)
    return [] if group.nil?

    group[:clubs].map { |c| c[:id] }
  end

  def all_club_ids(groups)
    groups.flat_map { |g| club_ids(g) }
  end

  def group_names(groups)
    groups.map { |g| g[:name] }
  end

  def find_group(groups, name)
    groups.find { |g| g[:name] == name }
  end

  def home_hash(game_operation)
    [{ 'game_operation_id' => game_operation.id, 'home_game_operation' => true }]
  end

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
  # --- main_game_operation_id: Boolean-Cast auf home_game_operation ----------
  #
  # In Altdaten liegt das Flag als String. `'false'` ist truthy und galt damit als
  # Heimat-Eintrag; weil diese Methode den zustaendigen Verband bestimmt, bekam
  # die SBK des Gastverbands Zugriff auf jeden Spieler mit Heimat in dem Verein.
  # `home_game_operation` und `without_home_game_operation` pruefen strikt auf
  # true, hier lief es auseinander.

  test 'main_game_operation_id ignoriert home_game_operation als String false' do
    heimat = create(:game_operation)
    gast = create(:game_operation)
    club = create(:club, game_operations_hash: [
      { 'game_operation_id' => gast.id, 'home_game_operation' => 'false' },
      { 'game_operation_id' => heimat.id, 'home_game_operation' => true }
    ])

    assert_equal heimat.id, club.main_game_operation_id,
                 'der Gast-Eintrag darf den Heimat-Spielbetrieb nicht verdraengen'
  end

  test 'main_game_operation_id bleibt ohne echten Heimat-Eintrag leer' do
    gast = create(:game_operation)
    club = create(:club, game_operations_hash: [
      { 'game_operation_id' => gast.id, 'home_game_operation' => 'f' }
    ])

    assert_nil club.main_game_operation_id
    assert_nil club.home_game_operation, 'beide Wege muessen dasselbe sagen'
  end
end
