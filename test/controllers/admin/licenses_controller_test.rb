require 'test_helper'

module Admin
  class LicensesControllerTest < ActionDispatch::IntegrationTest
    def login_as(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end

    setup do
      @setting = create(:setting, current_season_id: '18')

      # GOs müssen eine state_association haben – sonst löst sich das SBK-Permission
      # auf [0] (global) auf, weil GOs ohne state_association als national gelten.
      @sa1 = create(:state_association)
      @sa2 = create(:state_association)
      @go1 = GameOperation.create!(name: "GO1 #{SecureRandom.hex(4)}", short_name: "G1#{SecureRandom.hex(2)}",
                                   state_association: @sa1)
      @go2 = GameOperation.create!(name: "GO2 #{SecureRandom.hex(4)}", short_name: "G2#{SecureRandom.hex(2)}",
                                   state_association: @sa2)

      @club1 = create(:club)
      @club2 = create(:club)

      @league_go1 = create(:league, game_operation: @go1, season_id: '18')
      @team_go1   = create(:team,   league: @league_go1, club: @club1)

      @league_go2 = create(:league, game_operation: @go2, season_id: '18')
      @team_go2   = create(:team,   league: @league_go2, club: @club2)

      @league_prev = create(:league, game_operation: @go1, season_id: '17')
      @team_prev   = create(:team,   league: @league_prev, club: @club1)

      @admin = create(:user, :admin)
      @sbk   = create(:user, :sbk_scoped, game_operation_id: @go2.id)
      @vm    = create(:user, :vm, club_id: @club1.id)

      @player_go1  = create(:player, with_licenses: [{ team: @team_go1,  status: License::APPROVED, season_id: '18' }])
      @player_go2  = create(:player, with_licenses: [{ team: @team_go2,  status: License::APPROVED, season_id: '18' }])
      @player_prev = create(:player, with_licenses: [{ team: @team_prev, status: License::APPROVED, season_id: '17' }])
    end

    test 'GET as admin returns 200 with array' do
      login_as(@admin)
      get '/api/v2/admin/licenses'
      assert_response :success
      assert_kind_of Array, JSON.parse(response.body)
    end

    test 'GET with season_id filter returns licenses for that season only' do
      login_as(@admin)
      get '/api/v2/admin/licenses', params: { season_id: '17' }
      assert_response :success
      body = JSON.parse(response.body)
      assert_kind_of Array, body
      assert_equal ['17'], body.map { |r| r['season_id'].to_s }.uniq,
                   'only previous-season licenses should be returned'
      player_ids = body.map { |r| r['player_id'] }
      assert_includes     player_ids, @player_prev.id
      assert_not_includes player_ids, @player_go1.id
      assert_not_includes player_ids, @player_go2.id
    end

    test 'GET as SBK scoped to go2 returns only go2 licenses' do
      login_as(@sbk)
      get '/api/v2/admin/licenses'
      assert_response :success
      body = JSON.parse(response.body)
      assert_kind_of Array, body
      player_ids = body.map { |r| r['player_id'] }
      assert_includes     player_ids, @player_go2.id, 'go2 player should be present'
      assert_not_includes player_ids, @player_go1.id, 'go1 player must not appear for go2-scoped SBK'
      assert_equal [@go2.id], body.map { |r| r['game_operation_id'] }.uniq
    end

    test 'GET as VM returns 403' do
      login_as(@vm)
      get '/api/v2/admin/licenses'
      assert_response :forbidden
    end

    # Eine Mannschaft, die über cup_leagues in einem Pokal eines fremden
    # Spielbetriebs spielt: Für die SBK dieses Wettbewerbs steckt ihre Hauptliga
    # nicht in `leagues`, der Verein muss trotzdem an der Zeile stehen.
    test 'Verein steht an der Zeile einer per cup_leagues aufgenommenen Mannschaft' do
      cup = create(:league, game_operation: @go2, season_id: '18')
      @team_go1.update!(cup_leagues: [cup.id])
      login_as(@sbk)

      get '/api/v2/admin/licenses'

      assert_response :success
      row = JSON.parse(response.body).find { |r| r['player_id'] == @player_go1.id }
      assert_not_nil row, 'die Mannschaft muss in der Lizenzübersicht des Pokals erscheinen'
      assert_equal @club1.id, row['club_id']
      assert_equal @club1.name, row['club_name']
    end

    # -------------------------------------------------------------------------
    # license_type — Haupt-/Zusatzlizenz-Bestimmung (#291)
    # -------------------------------------------------------------------------

    test 'Hauptlizenz ist die höhere Liga – Bundesliga ("1") vor Regionalliga ("rl")' do
      buli_league = create(:league, game_operation: @go1, season_id: '18', league_class_id: '1fbl')
      buli_team   = create(:team, league: buli_league, club: @club1)
      rl_league   = create(:league, game_operation: @go1, season_id: '18', league_class_id: 'rl')
      rl_team     = create(:team, league: rl_league, club: @club1)

      create(:player, with_licenses: [
        { team: buli_team, status: License::APPROVED, season_id: '18' },
        { team: rl_team,   status: License::APPROVED, season_id: '18' }
      ])

      login_as(@admin)
      get '/api/v2/admin/licenses', params: { season_id: '18' }
      assert_response :success
      rows = JSON.parse(response.body)

      buli_row = rows.find { |r| r['team_id'] == buli_team.id }
      rl_row   = rows.find { |r| r['team_id'] == rl_team.id }
      refute_nil buli_row, '1.-Bundesliga-Zeile muss vorhanden sein'
      refute_nil rl_row,   'Regionalliga-Zeile muss vorhanden sein'
      assert_equal 'primary',   buli_row['license_type'], '1. Bundesliga muss Hauptlizenz sein'
      assert_equal 'secondary', rl_row['license_type'],   'Regionalliga (nicht-numerisch "rl") muss Zusatzlizenz sein'
    end

    test 'Bei gleicher Ligastufe ist die früher genehmigte Lizenz die Hauptlizenz' do
      league_a = create(:league, game_operation: @go1, season_id: '18', league_class_id: '2fbl')
      team_a   = create(:team, league: league_a, club: @club1)
      league_b = create(:league, game_operation: @go1, season_id: '18', league_class_id: '2fbl')
      team_b   = create(:team, league: league_b, club: @club1)

      create(:player, with_licenses: [
        { team: team_a, status: License::APPROVED, season_id: '18', created_at: 10.days.ago.iso8601 },
        { team: team_b, status: License::APPROVED, season_id: '18', created_at: 2.days.ago.iso8601 }
      ])

      login_as(@admin)
      get '/api/v2/admin/licenses', params: { season_id: '18' }
      assert_response :success
      rows = JSON.parse(response.body)

      row_a = rows.find { |r| r['team_id'] == team_a.id }
      row_b = rows.find { |r| r['team_id'] == team_b.id }
      assert_equal 'primary',   row_a['license_type'], 'früher genehmigte Lizenz ist Hauptlizenz'
      assert_equal 'secondary', row_b['license_type'], 'später genehmigte Lizenz ist Zusatzlizenz'
    end

    # -------------------------------------------------------------------------
    # gf_role — manuelle Erst-/Zweitlizenz-Zuordnung (GF-Erwachsenenbereich)
    # -------------------------------------------------------------------------

    test 'gespeicherte gf_role wird ausgegeben, ohne Zuordnung nil' do
      gf_buli = create(:league, game_operation: @go1, season_id: '18', league_class_id: '1fbl', field_size: 'GF')
      buli_team = create(:team, league: gf_buli, club: @club1)
      gf_rl = create(:league, game_operation: @go1, season_id: '18', league_class_id: 'rl', field_size: 'GF')
      rl_team = create(:team, league: gf_rl, club: @club1)

      create(:player, with_licenses: [
        { team: buli_team, status: License::APPROVED, season_id: '18', gf_role: 'zweitlizenz' },
        { team: rl_team,   status: License::APPROVED, season_id: '18', gf_role: 'erstlizenz' }
      ])

      login_as(@admin)
      get '/api/v2/admin/licenses', params: { season_id: '18' }
      assert_response :success
      rows = JSON.parse(response.body)

      buli_row = rows.find { |r| r['team_id'] == buli_team.id }
      rl_row   = rows.find { |r| r['team_id'] == rl_team.id }
      go1_row  = rows.find { |r| r['team_id'] == @team_go1.id }

      # Die Zuordnung ist manuell – sie folgt NICHT der Ligahöhe: hier ist die
      # niedrigere Liga (Wahl des Spielers) die Erstlizenz.
      assert_equal 'zweitlizenz', buli_row['gf_role']
      assert_equal 'erstlizenz',  rl_row['gf_role']
      assert_nil go1_row['gf_role'], 'ohne Zuordnung bleibt gf_role leer'
    end

    # -------------------------------------------------------------------------
    # Dokumente: saisonübergreifend am Spieler, per_season, Altersauflösung
    # -------------------------------------------------------------------------

    def attach_pdf(doc)
      doc.file.attach(io: StringIO.new('%PDF-1.4'), filename: 'doc.pdf', content_type: 'application/pdf')
      doc.save!
      doc
    end

    test 'einmaliges Dokument aus dem Altbestand (mit license_id) erfüllt auch die aktuelle Lizenz' do
      DocumentType.create!(name: 'Unterstellungserklärung', key: 'use')
      @league_go1.update!(required_documents: ['use'])
      attach_pdf(LicenseDocument.new(player: @player_go1, license_id: 'alte-lizenz-uuid', document_type: 'use'))

      login_as(@admin)
      get '/api/v2/admin/licenses'
      row = JSON.parse(response.body).find { |r| r['player_id'] == @player_go1.id }
      assert_includes row['required_documents'], 'use'
      assert row['documents']['use'], 'Altbestand-Dokument muss saisonübergreifend zählen'
      assert row['documents']['use_url'].present?
    end

    # Die Genehmigungsübersicht soll erkennbar machen, was seit dem letzten
    # Durchgang neu hochgeladen wurde. Dafür reist der Uploadzeitpunkt neben der
    # URL mit.
    test 'documents-Map führt den Uploadzeitpunkt je Dokumentart' do
      DocumentType.create!(name: 'Unterstellungserklärung', key: 'use')
      @league_go1.update!(required_documents: ['use'])
      doc = attach_pdf(LicenseDocument.new(player: @player_go1, document_type: 'use'))
      doc.update_columns(created_at: Time.zone.parse('2026-08-12 09:30:00'))

      login_as(@admin)
      get '/api/v2/admin/licenses'
      row = JSON.parse(response.body).find { |r| r['player_id'] == @player_go1.id }
      assert_equal Time.zone.parse('2026-08-12 09:30:00'),
                   Time.zone.parse(row['documents']['use_uploaded_at']),
                   'Uploadzeitpunkt muss dem created_at des Dokuments entsprechen'
    end

    # Kein Datum ohne abrufbares Dokument – sonst wiese die Übersicht einen
    # Upload aus, den dort niemand öffnen kann.
    test 'documents-Map lässt den Uploadzeitpunkt ohne Dokument leer' do
      DocumentType.create!(name: 'Unterstellungserklärung', key: 'use')
      @league_go1.update!(required_documents: ['use'])

      login_as(@admin)
      get '/api/v2/admin/licenses'
      row = JSON.parse(response.body).find { |r| r['player_id'] == @player_go1.id }
      assert row['documents'].key?('use_uploaded_at'), 'Frontend-Kontrakt: Key immer vorhanden'
      assert_nil row['documents']['use_uploaded_at']
    end

    # Ein erneuter Upload ersetzt den Datensatz, das Datum muss mitwandern –
    # sonst bliebe ein nachgereichtes Dokument in der Übersicht „alt".
    test 'erneuter Upload setzt den Uploadzeitpunkt neu' do
      DocumentType.create!(name: 'Unterstellungserklärung', key: 'use')
      @league_go1.update!(required_documents: ['use'])
      old = attach_pdf(LicenseDocument.new(player: @player_go1, document_type: 'use'))
      old.update_columns(created_at: Time.zone.parse('2026-06-01 08:00:00'))

      login_as(@admin)
      get '/api/v2/admin/licenses'
      row = JSON.parse(response.body).find { |r| r['player_id'] == @player_go1.id }
      assert_equal Time.zone.parse('2026-06-01 08:00:00'),
                   Time.zone.parse(row['documents']['use_uploaded_at'])

      old.destroy!
      neu = attach_pdf(LicenseDocument.new(player: @player_go1, document_type: 'use'))
      neu.update_columns(created_at: Time.zone.parse('2026-08-20 14:00:00'))

      get '/api/v2/admin/licenses'
      row = JSON.parse(response.body).find { |r| r['player_id'] == @player_go1.id }
      # Exakter Vergleich statt "irgendwann spaeter": Sonst haelt die Zusicherung
      # auch, wenn statt created_at des Dokuments ein beliebiger aktueller
      # Zeitstempel geliefert wuerde, etwa der des Anhangs.
      assert_equal Time.zone.parse('2026-08-20 14:00:00'),
                   Time.zone.parse(row['documents']['use_uploaded_at']),
                   'Nach dem Ersetzen muss der neue Uploadzeitpunkt gelten'
    end

    # Ein Dokument ohne abrufbare Datei (verlorener Blob) darf kein Datum
    # ausweisen -- sonst steht in der Uebersicht ein Upload, den dort niemand
    # oeffnen kann.
    test 'Dokument ohne Anhang liefert weder URL noch Uploadzeitpunkt' do
      DocumentType.create!(name: 'Unterstellungserklärung', key: 'use')
      @league_go1.update!(required_documents: ['use'])
      doc = attach_pdf(LicenseDocument.new(player: @player_go1, document_type: 'use'))
      doc.file.purge

      login_as(@admin)
      get '/api/v2/admin/licenses'
      row = JSON.parse(response.body).find { |r| r['player_id'] == @player_go1.id }
      assert row['documents']['use'], 'der Datensatz besteht weiter'
      assert_nil row['documents']['use_url']
      assert_nil row['documents']['use_uploaded_at']
    end

    # Zweiter Aufrufer von document_map_for: die Liga-Detailansicht der SBK
    # (players#admin_licenses). Sie speist im Frontend auch den
    # Genehmigungsdialog und war bisher ganz ohne Test -- die documents-Map
    # haengt dort unter team_license, nicht auf der obersten Ebene.
    test 'Liga-Detailansicht liefert den Uploadzeitpunkt unter team_license' do
      DocumentType.create!(name: 'Unterstellungserklärung', key: 'use')
      @league_go1.update!(required_documents: ['use'])
      doc = attach_pdf(LicenseDocument.new(player: @player_go1, document_type: 'use'))
      doc.update_columns(created_at: Time.zone.parse('2026-08-12 09:30:00'))

      login_as(@admin)
      get "/api/v2/admin/leagues/#{@league_go1.id}/licenses"
      assert_response :success

      players = JSON.parse(response.body).flat_map { |t| t['players'] || [] }
      entry = players.find { |pl| pl['id'] == @player_go1.id }
      assert entry, 'Spieler muss in der Liga-Detailansicht auftauchen'
      documents = entry.dig('team_license', 'documents')
      assert documents, 'team_license.documents muss gefuellt sein'
      assert_equal Time.zone.parse('2026-08-12 09:30:00'),
                   Time.zone.parse(documents['use_uploaded_at'])
    end

    test 'per_season-Dokument aus der Vorsaison zählt nicht für die aktuelle Lizenz' do
      DocumentType.create!(name: 'Sportärztliches Attest', key: 'attest', validity: 'per_season')
      @league_go1.update!(required_documents: ['attest'])
      old_doc = attach_pdf(LicenseDocument.new(player: @player_go1, document_type: 'attest', season_id: 17))

      login_as(@admin)
      get '/api/v2/admin/licenses'
      row = JSON.parse(response.body).find { |r| r['player_id'] == @player_go1.id }
      assert_not row['documents']['attest'], 'Vorsaison-Attest darf die Saison-18-Lizenz nicht erfüllen'
      assert_nil row['documents']['attest_uploaded_at'],
                 'ein Datum aus der Vorsaison saehe an dieser Lizenz plausibel aus und waere falsch'

      old_doc.destroy!
      attach_pdf(LicenseDocument.new(player: @player_go1, document_type: 'attest', season_id: 18))
      get '/api/v2/admin/licenses'
      row = JSON.parse(response.body).find { |r| r['player_id'] == @player_go1.id }
      assert row['documents']['attest'], 'Attest der laufenden Saison muss zählen'
    end

    test 'Volljährige: parental_consent entfällt aus required_documents, bleibt aber in der documents-Map' do
      DocumentType.create!(name: 'Zustimmung der Erziehungsberechtigten', key: 'parental_consent',
                           required_below_age: 18)
      @league_go1.update!(required_documents: ['parental_consent'])

      login_as(@admin)
      get '/api/v2/admin/licenses'
      row = JSON.parse(response.body).find { |r| r['player_id'] == @player_go1.id }
      assert_not_includes row['required_documents'], 'parental_consent',
                          'Spieler Jahrgang 1990 ist volljährig – Zustimmung nicht erforderlich'
      assert row['documents'].key?('parental_consent'), 'Frontend-Kontrakt: Key immer vorhanden'
    end

    # Bis 1.81.0 markierten die Lizenzansichten die Zustimmung bundesweit bei
    # jeder minderjährigen Person als fehlend, auch in Ligen, die sie gar nicht
    # verlangen. Maßgeblich ist jetzt allein die Liga.
    test 'Elternzustimmung erst mit dem Liga-Flag gefordert' do
      DocumentType.create!(name: 'Zustimmung der Erziehungsberechtigten', key: 'parental_consent',
                           required_below_age: 18)
      minor = create(:player, birthdate: 15.years.ago.to_date.to_s,
                              with_licenses: [{ team: @team_go1, status: License::REQUESTED, season_id: '18' }])

      login_as(@admin)
      get '/api/v2/admin/licenses'
      row = JSON.parse(response.body).find { |r| r['player_id'] == minor.id }
      assert_not_includes row['required_documents'], 'parental_consent',
                          'Ohne Liga-Flag verlangt die Liga keine Zustimmung'

      @league_go1.update!(parental_consent_required: true)
      get '/api/v2/admin/licenses'
      row = JSON.parse(response.body).find { |r| r['player_id'] == minor.id }
      assert_includes row['required_documents'], 'parental_consent',
                      'Mit Liga-Flag ist die Zustimmung für Minderjährige Pflicht'
      assert_not row['documents']['parental_consent'], 'ohne Upload weiterhin offen'
    end

    test 'Liga-Flag macht die Zustimmung nicht für Volljährige erforderlich' do
      DocumentType.create!(name: 'Zustimmung der Erziehungsberechtigten', key: 'parental_consent',
                           required_below_age: 18)
      @league_go1.update!(parental_consent_required: true)

      login_as(@admin)
      get '/api/v2/admin/licenses'
      row = JSON.parse(response.body).find { |r| r['player_id'] == @player_go1.id }
      assert_not_includes row['required_documents'], 'parental_consent'
    end

    # Die Kosten dieser Liste hingen an der Zahl der Ligen, nicht an der Zahl der
    # Lizenzen: je Liga eine eigene Spieler-Abfrage – und das ist ein Sequential
    # Scan über die ganze players-Tabelle, weil die Lizenzen in einer JSONB-Spalte
    # ohne passenden Index liegen – und das Ganze zweimal, weil league.licenses
    # erst für die Spieler-IDs und dann für die Antwort lief. Ligen ohne eine
    # einzige Lizenz kosteten dabei genauso viel wie volle.
    def sql_counts_for_index
      counts = Hash.new(0)
      subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |_n, _s, _f, _i, payload|
        sql = payload[:sql]
        next if payload[:name] == 'SCHEMA' || sql.start_with?('BEGIN', 'COMMIT', 'ROLLBACK')

        counts[:total]   += 1
        counts[:players] += 1 if sql.include?('FROM "players"')
        counts[:teams]   += 1 if sql.include?('FROM "teams"')
      end
      get '/api/v2/admin/licenses'
      assert_response :success
      counts
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    test 'Abfragezahl der Liste wächst nicht mit der Zahl der Ligen' do
      login_as(@admin)
      baseline = sql_counts_for_index

      # Zehn weitere Ligen derselben Saison, alle ohne jede Lizenz.
      10.times do
        league = create(:league, game_operation: @go1, season_id: '18')
        create(:team, league: league, club: @club1)
      end

      grown = sql_counts_for_index

      assert_equal 1, baseline[:players],
                   'die Spieler aller Ligen werden in einer Abfrage geladen'
      assert_equal baseline[:players], grown[:players],
                   'zehn zusätzliche Ligen dürfen keine weitere Spieler-Abfrage kosten'
      assert_equal baseline[:teams], grown[:teams],
                   'auch die Teams werden gebündelt geladen'
      assert_operator grown[:total], :<=, baseline[:total] + 2,
                      'die Gesamtzahl der Abfragen darf mit den Ligen nicht mitwachsen ' \
                      "(#{baseline[:total]} → #{grown[:total]})"
    end
  end
end
