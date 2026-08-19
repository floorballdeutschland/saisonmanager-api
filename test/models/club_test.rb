require 'test_helper'

class ClubTest < ActiveSupport::TestCase
  # Ein Verein gehört genau einem Verband; nur dessen SBK verwaltet die
  # Stammdaten. Der ausdrückliche Weg für fremde Vereine ist die Freigabe, und
  # die landet in einem eigenen Block, damit erkennbar bleibt, wem der Verein
  # gehört.
  test 'admin_user_clubs zeigt fremde Vereine nicht in der eigenen Verbandsliste' do
    create(:setting, current_season_id: '18')
    fremd_sa = create(:state_association)
    create(:game_operation, state_association_id: fremd_sa.id)
    eigen_sa = create(:state_association)
    eigen_go = create(:game_operation, state_association_id: eigen_sa.id)

    eigener = create(:club, state_association_id: eigen_sa.id)
    gast = create(:club, state_association_id: fremd_sa.id)

    sbk = create(:user, :sbk_scoped, game_operation_id: eigen_go.id)
    groups = Club.admin_user_clubs(sbk)

    eigene_box = groups.reject { |g| g[:released] }.flat_map { |g| g[:clubs] }.map { |c| c['id'] || c[:id] }
    assert_includes eigene_box, eigener.id
    assert_not_includes eigene_box, gast.id, 'fremder Verein darf nicht in der eigenen Verbandsliste stehen'
    assert_empty groups.select { |g| g[:released] }, 'ohne Freigabe gibt es keinen Freigabe-Block'
  end

  test 'admin_user_clubs zeigt freigegebene Vereine im eigenen Block' do
    create(:setting, current_season_id: '18')
    grantor_sa = create(:state_association)
    create(:game_operation, state_association_id: grantor_sa.id)
    eigen_sa = create(:state_association)
    eigen_go = create(:game_operation, state_association_id: eigen_sa.id)

    freigegeben = create(:club, state_association_id: grantor_sa.id)
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

    # Zwei Queries, beide konstant: der Verbandsbaum für die Zuständigkeit
    # (StateAssociation.tree, einmal je Request) und das Preload der Gruppenköpfe.
    # Ohne das Preload skaliert der Wert linear mit der Zahl der GameOperations,
    # genau das prüft die Schranke.
    assert_operator sa_queries, :<=, 2, "Erwartet höchstens 2 state_associations-Queries, war #{sa_queries}"
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
  #
  # Seit api#472 laesst die Deaktivierung die Zugehoerigkeit offen, deaktivierte
  # Profile kommen also ueber den regulaeren Zweig herein. Der Zweig fuer
  # geschlossene Zugehoerigkeiten deckt nur noch den Bestand ab (siehe
  # legacy_deactivate!): aufgenommen wird dort nur, wessen Zugehoerigkeit die
  # Deaktivierung selbst geschlossen hat.
  test 'players(include_deactivated: true) nimmt Deaktivierte und den Alt-Bestand mit geschlossener Zugehoerigkeit' do
    club = create(:club)
    user_id = 4711

    aktiv       = create(:player, clubs: [{ 'club_id' => club.id, 'home_club' => true }])
    deaktiviert = create(:player, clubs: [{ 'club_id' => club.id, 'home_club' => true }])
    deaktiviert.deactivate!(user_id, reason: 'Karriereende')

    alt_bestand = create(:player, clubs: [{ 'club_id' => club.id, 'home_club' => true }])
    legacy_deactivate!(alt_bestand, user_id, reason: 'Karriereende')

    # Zweitspielrecht, das vor einem Jahr ablief; deaktiviert wurde spaeter von
    # derselben Person. Der Verein ist nicht mehr zustaendig, valid_set_by allein
    # wuerde ihn aber wieder einblenden.
    ausgelaufen = create(:player, clubs: [
      { 'club_id' => create(:club).id, 'home_club' => true },
      { 'club_id' => club.id, 'home_club' => false,
        'valid_until' => 1.year.ago.iso8601, 'valid_set_by' => user_id }
    ])
    legacy_deactivate!(ausgelaufen, user_id, reason: 'Karriereende')

    # Die beiden folgenden Faelle haben ihr valid_until bewusst am Zeitpunkt der
    # Deaktivierung: sie fallen allein am Auslöser-Vergleich heraus, nicht schon an der
    # Zeitschranke. Sonst wuerde der Vergleich von keinem Test festgehalten.
    #
    # Geschlossen von einer anderen Person als der, die deaktiviert hat.
    fremder_ausloeser = create(:player, clubs: [{ 'club_id' => club.id, 'home_club' => true }])
    legacy_deactivate!(fremder_ausloeser, user_id, reason: 'Karriereende')
    fremder_ausloeser.update_column(:deactivated_by, user_id + 1)

    # Altdaten: geschlossen ohne valid_set_by. Bleiben bewusst ausgeblendet, wie vor
    # der Aenderung auch.
    legacy = create(:player, clubs: [{ 'club_id' => club.id, 'home_club' => true }])
    legacy_deactivate!(legacy, user_id, reason: 'Karriereende')
    legacy.clubs.each { |c| c.delete('valid_set_by') }
    legacy.save!(validate: false)

    ids = club.players(include_deactivated: true).map(&:id)
    assert_includes ids, aktiv.id
    assert_includes ids, deaktiviert.id, 'offene Zugehoerigkeit trotz Deaktivierung'
    assert_includes ids, alt_bestand.id, 'von der Alt-Deaktivierung geschlossene Zugehoerigkeit'
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

  # Ein untergeordneter Landesverband behält seine eigene Überschrift, während der
  # Verbund darüber den Zugriff trägt. So sind Sachsen, Sachsen-Anhalt und
  # Thüringen unter SBK Ost einzeln sichtbar.
  test 'admin_user_clubs gruppiert nach eingestelltem Landesverband, nicht nach Verbund' do
    create(:setting, current_season_id: '18')
    verbund = create(:state_association, name: 'SBK Ost')
    kind = create(:state_association, name: 'Floorballverband Sachsen', parent: verbund)
    go = create(:game_operation, state_association_id: verbund.id)

    beim_verbund = create(:club, name: 'A Verein Verbund', state_association_id: verbund.id)
    beim_kind = create(:club, name: 'B Verein Sachsen', state_association_id: kind.id)

    groups = Club.admin_user_clubs(create(:user, :sbk_scoped, game_operation_id: go.id))

    assert_equal [beim_verbund.id], club_ids(find_group(groups, 'SBK Ost'))
    assert_equal [beim_kind.id], club_ids(find_group(groups, 'Floorballverband Sachsen'))
  end

  # Der Verein des untergeordneten Verbands gehört dem Spielbetrieb des Verbunds,
  # nicht bloß lesend über eine Freigabe. Das ist der Weg, über den die Hamburger
  # Vereine beim Verbund landen, dem Hamburg untergeordnet ist.
  test 'admin_user_clubs gibt dem Verbund die Vereine seiner untergeordneten Verbände' do
    create(:setting, current_season_id: '18')
    verbund = create(:state_association, name: 'Schleswig-Holstein')
    hamburg = create(:state_association, name: 'Hamburg', parent: verbund)
    go = create(:game_operation, state_association_id: verbund.id)

    etv = create(:club, state_association_id: hamburg.id)

    groups = Club.admin_user_clubs(create(:user, :sbk_scoped, game_operation_id: go.id))
    gruppe = find_group(groups, 'Hamburg')

    assert gruppe, "Erwartet Gruppe 'Hamburg', vorhanden: #{group_names(groups).inspect}"
    assert_equal [etv.id], club_ids(gruppe)
    # Nicht als „freigegeben" markiert: der Verein ist bearbeitbar, es braucht
    # keine Freigabe.
    refute gruppe[:released]
  end

  # Der Auslöser der Umstellung, als Regressionsschutz: Verein 81 (ETV Hamburg)
  # stand mit Landesverband Hamburg in der Liste von Floorball Niedersachsen,
  # weil ein zweites Feld am Verein den Spielbetrieb trug und niemand es sehen
  # konnte. Ein fremder Landesverband darf keinen Zugriff mehr begründen.
  test 'admin_user_clubs zeigt Vereine fremder Landesverbaende nicht' do
    create(:setting, current_season_id: '18')
    lv_nb = create(:state_association, name: 'Niedersachsen')
    lv_hh = create(:state_association, name: 'Hamburg')
    go_nb = create(:game_operation, state_association_id: lv_nb.id)
    create(:game_operation, state_association_id: lv_hh.id)

    etv = create(:club, state_association_id: lv_hh.id)

    ids = all_club_ids(Club.admin_user_clubs(create(:user, :sbk_scoped, game_operation_id: go_nb.id)))

    assert_not_includes ids, etv.id
  end

  test 'admin_user_clubs führt Vereine ohne Landesverband unter dem Bundesverband' do
    create(:setting, current_season_id: '18')
    fvd = create(:state_association, name: 'Floorball-Verband Deutschland e.V.', short_name: 'FVD')
    create(:game_operation, state_association_id: create(:state_association).id)

    ohne_lv = create(:club, state_association_id: nil)

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
    create(:game_operation, state_association_id: fremd.id)
    ohne_lv = create(:club, state_association_id: nil)

    groups = Club.admin_user_clubs(create(:user, :admin))

    assert_equal [ohne_lv.id], club_ids(find_group(groups, 'Ohne Landesverband'))
    assert_empty club_ids(find_group(groups, 'SBK Ost'))
  end

  test 'admin_user_clubs verliert Vereine mit ins Leere zeigendem Landesverband nicht' do
    create(:setting, current_season_id: '18')
    create(:game_operation, state_association_id: create(:state_association).id)
    # Verweis auf einen gelöschten Landesverband – auf clubs.state_association_id
    # liegt kein Fremdschlüssel. Der Verein muss trotzdem auftauchen, sonst wird
    # er unauffindbar.
    waise = create(:club, state_association_id: 999_999)

    groups = Club.admin_user_clubs(create(:user, :admin))
    rest = find_group(groups, 'Ohne Landesverband')

    assert rest, "Erwartet Restgruppe, vorhanden: #{group_names(groups).inspect}"
    assert_equal [waise.id], club_ids(rest)
  end

  # Vereine ohne zuständigen Spielbetrieb waren in der Vereinsverwaltung
  # unsichtbar und damit nicht bearbeitbar. Sie gehören keinem Verband, deshalb
  # sieht sie nur der globale Zugriff – aber der muss sie sehen, sonst sind sie
  # nirgends zu reparieren.
  #
  # Drei Wege in diesen Zustand, siehe Club.unassigned. Der dritte ist der
  # Auslöser der Umstellung: In der Maske steht ein Landesverband, und trotzdem
  # ist niemand zuständig.
  test 'admin_user_clubs zeigt Vereine ohne zustaendigen Spielbetrieb dem globalen Zugriff' do
    create(:setting, current_season_id: '18')
    create(:state_association, name: 'Floorball-Verband Deutschland e.V.', short_name: 'FVD')

    ohne_lv = create(:club, state_association_id: nil)
    lv_ohne_spielbetrieb = create(:club, state_association_id: create(:state_association).id)

    ids = all_club_ids(Club.admin_user_clubs(create(:user, :admin)))

    assert_includes ids, ohne_lv.id
    assert_includes ids, lv_ohne_spielbetrieb.id
  end

  test 'admin_user_clubs zeigt Vereine ohne zustaendigen Spielbetrieb nicht einem einzelnen Verband' do
    create(:setting, current_season_id: '18')
    go = create(:game_operation, state_association_id: create(:state_association).id)
    create(:club, state_association_id: nil)

    # Ein einzelner Landesverband soll nicht die unzugeordneten Vereine aller
    # anderen in seiner Liste haben.
    ids = all_club_ids(Club.admin_user_clubs(create(:user, :sbk_scoped, game_operation_id: go.id)))

    assert_empty ids
  end

  # Ein Verein steht genau einmal in der Liste, auch wenn der globale Zugriff ihn
  # über den eigenen Verband UND über Club.unassigned erfassen könnte.
  test 'admin_user_clubs listet einen Verein genau einmal' do
    create(:setting, current_season_id: '18')
    lv = create(:state_association, name: 'Niedersachsen')
    create(:game_operation, state_association_id: lv.id)

    club = create(:club, state_association_id: lv.id)

    assert_equal [club.id], all_club_ids(Club.admin_user_clubs(create(:user, :admin)))
  end

  # Die Deaktiviert-Bedingung muss auch dann greifen, wenn der globale Zugriff die
  # Vereine über die OR-Verknüpfung aus eigenem Verband und Club.unassigned holt.
  test 'admin_user_clubs zeigt deaktivierte Vereine nur mit include_deactivated' do
    create(:setting, current_season_id: '18')
    lv = create(:state_association)
    create(:game_operation, state_association_id: lv.id)

    inaktiv = create(:club, state_association_id: lv.id, deactivated_at: Time.current)
    aktiv = create(:club, state_association_id: lv.id)
    admin = create(:user, :admin)

    assert_equal [aktiv.id], all_club_ids(Club.admin_user_clubs(admin))
    assert_equal [aktiv.id, inaktiv.id].sort,
                 all_club_ids(Club.admin_user_clubs(admin, include_deactivated: true)).sort
  end

  # Eine Freigabe des eigenen Unterverbands ist redundant: Der Verein gehört
  # ohnehin zum Verbund. Sie darf ihn deshalb nicht ein zweites Mal auf die Seite
  # bringen. Auf Produktion ist das der Stand nach der Umstellung – der Hamburger
  # Verband hatte dem Nachbarverband eine Freigabe erteilt, um die Betreuung
  # überhaupt zu ermöglichen, und braucht sie als Unterverband nicht mehr.
  test 'admin_user_clubs zeigt freigegebene Vereine nicht zusätzlich in der Landesverbands-Gruppe' do
    create(:setting, current_season_id: '18')
    verbund = create(:state_association, name: 'Schleswig-Holstein')
    hamburg = create(:state_association, name: 'Hamburg', parent: verbund)
    eigen_go = create(:game_operation, state_association_id: verbund.id)
    fremd_sa = create(:state_association, name: 'Bremen')

    # Gehört über die Verbandskette zum eigenen Spielbetrieb und ist zusätzlich
    # freigegeben – steht deshalb schon in der Landesverbands-Gruppe.
    im_verbund = create(:club, state_association_id: hamburg.id)
    # Nur über die Freigabe sichtbar.
    nur_freigabe = create(:club, state_association_id: fremd_sa.id)

    [hamburg, fremd_sa].each do |grantor|
      StateAssociationRelease.create!(grantor_state_association_id: grantor.id,
                                      recipient_game_operation_id: eigen_go.id,
                                      season_id: Setting.current_season_id)
    end

    groups = Club.admin_user_clubs(create(:user, :sbk_scoped, game_operation_id: eigen_go.id))
    released = groups.select { |g| g[:released] }
    own = groups.reject { |g| g[:released] }

    assert_equal [nur_freigabe.id], released.flat_map { |g| club_ids(g) }.sort
    assert_equal [im_verbund.id], own.flat_map { |g| club_ids(g) }.sort
    # Die Überschrift macht kenntlich, dass der Verein einem fremden Verband
    # gehört und hier nur lesend steht.
    assert_equal ['Bremen (freigegeben)'], group_names(released)
  end

  test 'admin_user_clubs behält den Block „Eigene Vereine" für die VM-Rolle' do
    create(:setting, current_season_id: '18')
    eigen_go = create(:game_operation, state_association_id: create(:state_association).id)
    create(:game_operation, state_association_id: create(:state_association).id)

    # Verein außerhalb des eigenen Spielbetriebs, auf den der Nutzer nur als
    # Vereinsmanager Zugriff hat.
    vm_club = create(:club, state_association_id: create(:state_association).id)

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
    create(:game_operation, state_association_id: create(:state_association).id)
    vm_club = create(:club, state_association_id: create(:state_association).id)
    create(:club, state_association_id: create(:state_association).id)

    groups = Club.admin_user_clubs(create(:user, :vm, club_id: vm_club.id))

    assert_equal ['Eigene Vereine'], group_names(groups)
    assert_equal [vm_club.id], all_club_ids(groups)
  end

  test 'admin_user_clubs liefert ohne Rollen keine Gruppen' do
    create(:setting, current_season_id: '18')
    create(:game_operation, state_association_id: create(:state_association).id)
    create(:club, state_association_id: create(:state_association).id)

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

    altlast = create(:club, state_association_id: dach.id)

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
    create(:game_operation, state_association_id: lv_b.id)
    create(:game_operation, state_association_id: lv_a.id)

    create(:club, state_association_id: lv_b.id)
    create(:club, state_association_id: lv_a.id)
    create(:club, state_association_id: 999_999)

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
  # --- home_clubs_of ist die Umkehrung von main_game_operation_id -------------
  #
  # Wer einen Verein LISTET, muss auch fuer ihn zustaendig sein. Liefen die beiden
  # auseinander, waere ein Verein gelistet, aber nicht bearbeitbar, und seine
  # Spielerliste antwortete leer -- genau die Art stillen Widerspruchs, die diese
  # Umstellung beseitigen soll.

  # Ein Spielbetrieb an einem UNTERGEORDNETEN Verband. Entsteht, sobald jemand
  # nach #492 einen Spielbetrieb fuer Hamburg anlegt, das seit dem Datenlauf ein
  # Unterverband von Schleswig-Holstein ist. Ohne die Filterung in
  # responsible_state_association_ids saehe er alle Vereine des ganzen Verbunds,
  # samt Kontaktadresse.
  test 'home_clubs_of gibt einem Spielbetrieb am Unterverband keine fremden Vereine' do
    verbund = create(:state_association)
    kind = create(:state_association, parent: verbund)
    verbund_go = create(:game_operation, state_association_id: verbund.id)
    kind_go = create(:game_operation, state_association_id: kind.id)

    im_verbund = create(:club, state_association_id: verbund.id)
    im_kind = create(:club, state_association_id: kind.id)

    # Zustaendig ist fuer beide der Spielbetrieb des Verbunds.
    assert_equal verbund_go.id, im_verbund.main_game_operation_id
    assert_equal verbund_go.id, im_kind.main_game_operation_id

    assert_equal [im_kind.id, im_verbund.id].sort, Club.home_clubs_of([verbund_go.id]).pluck(:id).sort
    assert_empty Club.home_clubs_of([kind_go.id]).pluck(:id),
                 'ein Spielbetrieb am Unterverband ist fuer keinen Verein zustaendig und darf keinen listen'
  end

  # Zwei Spielbetriebe an einem Verband. id_by_state_association behaelt den mit
  # der niedrigeren ID; der andere darf den Teilbaum deshalb nicht sehen.
  test 'home_clubs_of gibt nur dem zustaendigen von zwei Spielbetrieben die Vereine' do
    lv = create(:state_association)
    erster = create(:game_operation, state_association_id: lv.id)
    zweiter = create(:game_operation, state_association_id: lv.id)
    club = create(:club, state_association_id: lv.id)

    zustaendig, nicht_zustaendig = [erster, zweiter].partition { |go| go.id == club.main_game_operation_id }

    assert_equal 1, zustaendig.size, 'genau einer der beiden ist zustaendig'
    assert_equal [club.id], Club.home_clubs_of([zustaendig.first.id]).pluck(:id)
    assert_empty Club.home_clubs_of([nicht_zustaendig.first.id]).pluck(:id)
  end

  # Gegenprobe ueber den ganzen Bestand: Fuer jeden Verein muss der Spielbetrieb,
  # den main_game_operation_id nennt, ihn auch listen -- und kein anderer.
  test 'home_clubs_of und main_game_operation_id stimmen ueber den Bestand ueberein' do
    verbund = create(:state_association)
    kind = create(:state_association, parent: verbund)
    allein = create(:state_association)
    create(:game_operation, state_association_id: verbund.id)
    create(:game_operation, state_association_id: allein.id)
    create(:game_operation, state_association_id: kind.id)

    [verbund, kind, allein, create(:state_association)].each { |sa| create(:club, state_association_id: sa.id) }
    create(:club, state_association_id: nil)

    GameOperation.find_each do |go|
      gelistet = Club.home_clubs_of([go.id]).pluck(:id).sort
      zustaendig = Club.all.select { |c| c.main_game_operation_id == go.id }.map(&:id).sort
      assert_equal zustaendig, gelistet, "Spielbetrieb #{go.id} listet andere Vereine als er verwaltet"
    end
  end

  # --- main_game_operation_id: Ableitung aus dem Landesverband ----------------
  #
  # Die Zustaendigkeit stand frueher als zweites Feld am Verein
  # (`game_operations_hash`) und konnte dem Landesverband widersprechen. Jetzt
  # gibt es nur eine Quelle.

  test 'main_game_operation_id nimmt den Spielbetrieb des eigenen Landesverbands' do
    lv = create(:state_association)
    go = create(:game_operation, state_association_id: lv.id)

    assert_equal go.id, create(:club, state_association_id: lv.id).main_game_operation_id
  end

  # Der Fall der Untergliederung von SBK Ost und, nach der Umstellung, der
  # Hamburger Vereine: Der untergeordnete Verband hat keinen eigenen
  # Spielbetrieb, zustaendig ist der Verbund darueber.
  test 'main_game_operation_id folgt der Verbandskette bis zur Wurzel' do
    verbund = create(:state_association)
    kind = create(:state_association, parent: verbund)
    enkel = create(:state_association, parent: kind)
    go = create(:game_operation, state_association_id: verbund.id)

    assert_equal go.id, create(:club, state_association_id: kind.id).main_game_operation_id
    assert_equal go.id, create(:club, state_association_id: enkel.id).main_game_operation_id,
                 'die Kette muss ueber mehr als eine Ebene laufen'
  end

  # nil heisst hier „niemand ist zustaendig" und ist ein gueltiger Zustand: Die
  # Ablage-Vereine auf Produktion stehen so da. Er darf nur nicht unbemerkt
  # entstehen, siehe ClubsController#state_association_move_conflict.
  test 'main_game_operation_id bleibt ohne Landesverband leer' do
    club = create(:club, state_association_id: nil)

    assert_nil club.main_game_operation_id
    assert_nil club.home_game_operation, 'beide Wege muessen dasselbe sagen'
  end

  test 'main_game_operation_id bleibt leer, wenn der Verbund keinen Spielbetrieb hat' do
    ohne_spielbetrieb = create(:state_association)

    assert_nil create(:club, state_association_id: ohne_spielbetrieb.id).main_game_operation_id
  end

  # Auf clubs.state_association_id liegt kein Fremdschluessel, der Verweis kann
  # ins Leere zeigen. Das darf keine Ausnahme werden, sonst reisst die
  # Vereinsliste an einem einzigen kaputten Datensatz ab.
  test 'main_game_operation_id bleibt leer bei einem Landesverband, den es nicht gibt' do
    assert_nil create(:club, state_association_id: 999_999).main_game_operation_id
  end

  # Das Kuerzel steht auf der Anzeigetafel des Livestreams; mehr als vier
  # Zeichen sprengen dort die Bauchbinde.
  test 'short_name darf hoechstens vier Zeichen haben' do
    club = build(:club, short_name: 'ABCD')
    assert_predicate club, :valid?

    club.short_name = 'ABCDE'
    assert_not club.valid?
    assert_includes club.errors.attribute_names, :short_name
  end

  # Das Feld ist nullable, und 188 Mannschaften der laufenden Saison haengen an
  # einem Verein ohne Kuerzel. Eine Pflichtangabe wuerde jedes Speichern dieser
  # Vereine blockieren.
  test 'short_name darf leer bleiben' do
    assert_predicate build(:club, short_name: nil), :valid?
    assert_predicate build(:club, short_name: ''), :valid?
  end

  # Bestandswerte sind laenger als die neue Grenze. Eine unbedingte Pruefung
  # haette jedes Speichern dieser Vereine blockiert, auch das Deaktivieren, das
  # in einer Maske ohne Kuerzel-Feld an einer Meldung ueber das Kuerzel
  # gescheitert waere.
  test 'ein zu langer Bestandswert blockiert Deaktivieren und andere Felder nicht' do
    club = create(:club)
    club.update_column(:short_name, 'Floorball Butzbach')
    club.reload

    assert club.update(contact_email: 'neu@example.org'), club.errors.full_messages.join(', ')
    assert_nothing_raised { club.deactivate!(create(:user, :admin).id) }
    assert_not_nil club.reload.deactivated_at
    assert_nothing_raised { club.reactivate! }
    assert_equal 'Floorball Butzbach', club.reload.short_name, 'der Wert bleibt, bis er geaendert wird'
  end

  test 'wer den Bestandswert anfasst, muss die Grenze einhalten' do
    club = create(:club)
    club.update_column(:short_name, 'Floorball Butzbach')
    club.reload

    assert_not club.update(short_name: 'ABCDE')
    assert_includes club.errors.attribute_names, :short_name
  end

  # Aus dem Bündel des Vereinsmanagers bekommen Teammanager*innen
  # ausschließlich :create_player. :update_own_club bleibt beim
  # Vereinsmanager, Stammdaten ändern beim Verband.
  test 'Teammanager darf im Verein der eigenen Mannschaft Spieler anlegen' do
    create(:setting, current_season_id: '18')
    club = create(:club)
    team = create(:team, club:, league: create(:league, :current_season))
    tm = create(:user, :tm, team_id: team.id)

    perm = club.user_permissions(tm)

    assert_includes perm, :create_player
    assert_not_includes perm, :update_player
    assert_not_includes perm, :update_club
    assert_not_includes perm, :update_own_club
  end

  test 'Teammanager darf in einem fremden Verein keine Spieler anlegen' do
    create(:setting, current_season_id: '18')
    team = create(:team, club: create(:club), league: create(:league, :current_season))
    fremder_club = create(:club)
    tm = create(:user, :tm, team_id: team.id)

    assert_not_includes fremder_club.user_permissions(tm), :create_player
  end

  # Spielgemeinschaften stellen den Kader gemeinsam, also gilt die Anlage für
  # jeden beteiligten Verein. Es zählt Team#all_club_ids, wie überall bei
  # Spielgemeinschaften. Das ist die eine Stelle, an der ein TM weiter reicht
  # als ein VM, der nur im eigenen Verein anlegt.
  test 'Teammanager einer Spielgemeinschaft darf in allen beteiligten Vereinen anlegen' do
    create(:setting, current_season_id: '18')
    haupt = create(:club)
    partner = create(:club)
    team = create(:team, club: haupt, league: create(:league, :current_season),
                         syndicate: true, syndicate_clubs: [partner.id])
    tm = create(:user, :tm, team_id: team.id)

    assert_includes haupt.user_permissions(tm), :create_player
    assert_includes partner.user_permissions(tm), :create_player
  end

  # Wer nur eine Mannschaft einer vergangenen Saison betreut hat, legt nichts
  # an. Gepinnt wird das Außenverhalten; die Saisongrenze selbst zieht schon
  # User#permission_hash, ph[:tm] ist hier leer.
  test 'Teammanager einer Mannschaft aus einer alten Saison darf nichts anlegen' do
    create(:setting, current_season_id: '18')
    club = create(:club)
    team = create(:team, club:, league: create(:league, :previous_season))
    tm = create(:user, :tm, team_id: team.id)

    assert_not_includes club.user_permissions(tm), :create_player
  end

  # Mehrfachrollen sind schon einmal daran gescheitert, dass eine Rollenkette
  # nach dem ersten Treffer abbrach. Beide Rollen müssen nebeneinander gelten,
  # jede mit ihrem eigenen Umfang.
  test 'wer VM des einen und TM im anderen Verein ist, behaelt beide Rollen' do
    create(:setting, current_season_id: '18')
    vm_club = create(:club)
    tm_club = create(:club)
    team = create(:team, club: tm_club, league: create(:league, :current_season))
    user = create(:user, teams: [team.id], permissions: [
      { 'user_group_id' => 4, 'game_operation_id' => 0, 'club_id' => vm_club.id },
      { 'user_group_id' => 5, 'game_operation_id' => 0 }
    ])

    assert_includes vm_club.user_permissions(user), :create_player
    assert_includes vm_club.user_permissions(user), :update_own_club
    assert_includes tm_club.user_permissions(user), :create_player
    assert_not_includes tm_club.user_permissions(user), :update_own_club
  end
end
