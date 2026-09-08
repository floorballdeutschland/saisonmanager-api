require 'test_helper'

module Admin
  class RefereeAssignmentsControllerTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    setup do
      create(:setting)
    end

    test 'LV-Ansetzer ohne freigeschaltete Ansetzung (Feature-Flag) erhält 403' do
      sa = create(:state_association) # referee_assignment_enabled default: false
      go = create(:game_operation, state_association_id: sa.id)
      login(create(:user, :assigner_scoped, game_operation_id: go.id))

      get '/api/v2/admin/referee_assignments'

      assert_response :forbidden
    end

    test 'LV-Ansetzer mit freigeschalteter Ansetzung darf zugreifen' do
      sa = create(:state_association, referee_assignment_enabled: true)
      go = create(:game_operation, state_association_id: sa.id)
      login(create(:user, :assigner_scoped, game_operation_id: go.id))

      get '/api/v2/admin/referee_assignments'

      assert_response :success
    end

    test 'FD-Ansetzer (nationaler Spielbetrieb) ist immer aktiv' do
      fd = create(:game_operation, :national)
      login(create(:user, :assigner_scoped, game_operation_id: fd.id))

      get '/api/v2/admin/referee_assignments'

      assert_response :success
    end

    test 'available_coaches liefert dem LV-Ansetzer nur Coaches des eigenen Verbands' do
      sa_own = create(:state_association, referee_assignment_enabled: true)
      go_own = create(:game_operation, state_association_id: sa_own.id)
      sa_other = create(:state_association, referee_assignment_enabled: true)
      create(:game_operation, state_association_id: sa_other.id)

      club_own = create(:club, state_association_id: sa_own.id)
      club_other = create(:club, state_association_id: sa_other.id)

      date = Date.today + 7
      coach_own = coach_referee(club_own, date)
      coach_other = coach_referee(club_other, date)

      login(create(:user, :assigner_scoped, game_operation_id: go_own.id))
      get "/api/v2/admin/referee_assignments/available_coaches?date=#{date}"

      assert_response :success
      ids = JSON.parse(response.body).map { |c| c['id'] }
      assert_includes ids, coach_own.id
      assert_not_includes ids, coach_other.id
    end

    test 'available liefert die Vereins-Ausschlussliste mit, filtert aber niemanden heraus' do
      sa = create(:state_association, referee_assignment_enabled: true)
      go = create(:game_operation, state_association_id: sa.id)
      own_club = create(:club, state_association_id: sa.id)
      excluded_club = create(:club, state_association_id: sa.id)

      date = Date.today + 7
      referee = create(:referee, club_id: own_club.id)
      RefereeAvailability.create!(referee: referee, date: date)
      RefereeClubExclusion.create!(referee: referee, club: excluded_club, reason: 'Sohn spielt dort')

      login(create(:user, :assigner_scoped, game_operation_id: go.id))
      get "/api/v2/admin/referee_assignments/available?date=#{date}"

      assert_response :success
      entry = JSON.parse(response.body).find { |r| r['id'] == referee.id }
      assert_not_nil entry, 'gesperrte Person bleibt waehlbar'
      assert_equal [own_club.id, excluded_club.id].sort, entry['excluded_club_ids'].sort
    end

    # Die Ansetzung sieht am Kennzeichen „kurzfristig mobil", wen sie kurzfristig
    # fragen kann; ohne Telefonnummer im selben Datensatz blieb der Hinweis
    # folgenlos, weil die Nummer bis dahin nirgends in der Oberflaeche stand.
    test 'available liefert die Telefonnummer der Auswahl mit' do
      sa = create(:state_association, referee_assignment_enabled: true)
      go = create(:game_operation, state_association_id: sa.id)
      club = create(:club, state_association_id: sa.id)

      date = Date.today + 7
      referee = create(:referee, club_id: club.id, telefonnummer: '0170 1234567',
                                 kurzfristig_mobil: true)
      RefereeAvailability.create!(referee: referee, date: date)

      login(create(:user, :assigner_scoped, game_operation_id: go.id))
      get "/api/v2/admin/referee_assignments/available?date=#{date}"

      assert_response :success
      entry = JSON.parse(response.body).find { |r| r['id'] == referee.id }
      assert_equal '0170 1234567', entry['telefonnummer']
      assert_equal true, entry['kurzfristig_mobil']
    end

    # Der Frontend-Rueckfall der Ansetzungsansicht liest die Nummer einer bereits
    # gespeicherten Ansetzung ausschliesslich aus diesem Stub -- und zwar im
    # Regelfall, nicht als Notbehelf: #available wirft tagesgleich Angesetzte per
    # `where.not(id: assigned_ids)` aus der Kandidatenliste, fuer ein gesetztes
    # Gespann greift also immer der Stub. Faellt das Feld weg, zeigt die Ansicht
    # stumm keine Nummer mehr; bis hierher hat das kein Test bemerkt.
    test 'index liefert die Telefonnummer des angesetzten Gespanns mit' do
      sa = create(:state_association, referee_assignment_enabled: true)
      go = create(:game_operation, state_association_id: sa.id)
      game = assignable_game(go)
      referee = create(:referee, telefonnummer: '0170 1234567')
      assignment = RefereeAssignment.create!(game: game, referee1_id: referee.id,
                                             status: 'tentative')
      login(create(:user, :admin))

      get '/api/v2/admin/referee_assignments'

      assert_response :success
      entry = response.parsed_body.find { |a| a['id'] == assignment.id }
      assert_not_nil entry
      assert_equal '0170 1234567', entry['referee1']['telefonnummer']
    end

    test 'available_coaches liefert die Telefonnummer der Auswahl mit' do
      sa = create(:state_association, referee_assignment_enabled: true)
      go = create(:game_operation, state_association_id: sa.id)
      club = create(:club, state_association_id: sa.id)

      date = Date.today + 7
      coach = coach_referee(club, date)
      coach.update!(telefonnummer: '0151 7654321')

      login(create(:user, :assigner_scoped, game_operation_id: go.id))
      get "/api/v2/admin/referee_assignments/available_coaches?date=#{date}"

      assert_response :success
      entry = JSON.parse(response.body).find { |r| r['id'] == coach.id }
      assert_equal '0151 7654321', entry['telefonnummer']
    end

    test 'available_coaches liefert die Vereins-Ausschlussliste mit' do
      sa = create(:state_association, referee_assignment_enabled: true)
      go = create(:game_operation, state_association_id: sa.id)
      club = create(:club, state_association_id: sa.id)
      excluded_club = create(:club, state_association_id: sa.id)

      date = Date.today + 7
      coach = coach_referee(club, date)
      RefereeClubExclusion.create!(referee: coach, club: excluded_club, reason: 'Eigene Mannschaft')

      login(create(:user, :assigner_scoped, game_operation_id: go.id))
      get "/api/v2/admin/referee_assignments/available_coaches?date=#{date}"

      assert_response :success
      entry = JSON.parse(response.body).find { |r| r['id'] == coach.id }
      assert_equal [club.id, excluded_club.id].sort, entry['excluded_club_ids'].sort
    end

    test 'Ansetzer im Scope pflegt und leert die Spielinformationen' do
      sa = create(:state_association, referee_assignment_enabled: true)
      go = create(:game_operation, state_association_id: sa.id)
      game = assignable_game(go)
      user = create(:user, :assigner_scoped, game_operation_id: go.id,
                                             first_name: 'Anna', last_name: 'Ansetzer')
      login(user)

      patch "/api/v2/admin/referee_assignments/games/#{game.id}/notes",
            params: { game: { referee_notes: '  Halle nur über den Hintereingang  ' } }

      assert_response :success
      body = JSON.parse(response.body)
      assert_equal 'Halle nur über den Hintereingang', body['referee_notes']
      assert_equal 'Anna Ansetzer', body['referee_notes_updated_by_name']
      assert_not_nil body['referee_notes_updated_at']
      assert_equal 'Halle nur über den Hintereingang', game.reload.referee_notes
      assert_equal user.id, game.referee_notes_updated_by

      patch "/api/v2/admin/referee_assignments/games/#{game.id}/notes",
            params: { game: { referee_notes: '   ' } }

      assert_response :success
      assert_nil game.reload.referee_notes
    end

    test 'Ansetzer eines fremden Verbands darf die Spielinformationen nicht ändern' do
      sa_own = create(:state_association, referee_assignment_enabled: true)
      go_own = create(:game_operation, state_association_id: sa_own.id)
      sa_other = create(:state_association, referee_assignment_enabled: true)
      go_other = create(:game_operation, state_association_id: sa_other.id)
      game = assignable_game(go_other)
      game.update!(referee_notes: 'Fremder Hinweis')

      login(create(:user, :assigner_scoped, game_operation_id: go_own.id))
      patch "/api/v2/admin/referee_assignments/games/#{game.id}/notes",
            params: { game: { referee_notes: 'Übergriff' } }

      assert_response :forbidden
      assert_equal 'Fremder Hinweis', game.reload.referee_notes
    end

    test 'Rolle ohne Ansetzungsrecht darf die Spielinformationen nicht ändern' do
      go = create(:game_operation, :national)
      game = assignable_game(go)

      login(create(:user, :sbk_global))
      patch "/api/v2/admin/referee_assignments/games/#{game.id}/notes",
            params: { game: { referee_notes: 'Von der SBK' } }

      assert_response :forbidden
      assert_nil game.reload.referee_notes
    end

    test 'Liste der ansetzbaren Spiele liefert die Spielinformationen mit Autor' do
      go = create(:game_operation, :national)
      game = assignable_game(go)
      author = create(:user, :assigner_scoped, game_operation_id: go.id,
                                               first_name: 'Bea', last_name: 'Bezirk')
      game.update!(referee_notes: 'Turniermodus, 2×15 Minuten',
                   referee_notes_updated_at: Time.current,
                   referee_notes_updated_by: author.id)

      login(create(:user, :assigner_scoped, game_operation_id: go.id))
      get '/api/v2/admin/referee_assignments/games'

      assert_response :success
      entry = JSON.parse(response.body).find { |g| g['id'] == game.id }
      assert_equal 'Turniermodus, 2×15 Minuten', entry['referee_notes']
      assert_equal 'Bea Bezirk', entry['referee_notes_updated_by_name']
      assert_not_nil entry['referee_notes_updated_at']
    end

    # Der reduzierte Modus sortiert nach Liga und Spieltag. Der Personen-Weg darf
    # das nicht mitnehmen: dort grenzen die Zeitraum-Reiter ein, die Liste muss
    # also chronologisch bleiben.
    test 'Personen-Weg bleibt chronologisch sortiert, unabhaengig von der Liga' do
      go = create(:game_operation, :national)
      frueh_liga = create(:league, game_operation: go, name: 'Z-Liga')
      spaet_liga = create(:league, game_operation: go, name: 'A-Liga')
      frueh = create(:game, game_status: 'pregame', person_level_assignment: true,
                            game_day: create(:game_day, league: frueh_liga, number: 1,
                                             date: (Date.today + 3).to_s))
      spaet = create(:game, game_status: 'pregame', person_level_assignment: true,
                            game_day: create(:game_day, league: spaet_liga, number: 1,
                                             date: (Date.today + 21).to_s))

      login(create(:user, :assigner_scoped, game_operation_id: go.id))
      get '/api/v2/admin/referee_assignments/games'

      assert_response :success
      ids = JSON.parse(response.body).map { |g| g['id'] }
      assert_equal [frueh.id, spaet.id], ids
    end

    # -------------------------------------------------------------------------
    # notify – game_days.date ist eine Textspalte
    # -------------------------------------------------------------------------

    test 'vorlaeufige Ansetzung verschickt die Mail mit deutschem Datum' do
      sa = create(:state_association, referee_assignment_enabled: true)
      go = create(:game_operation, state_association_id: sa.id)
      game = assignable_game(go)
      game.game_day.update_columns(date: '2026-01-10')
      assignment = RefereeAssignment.create!(game: game, referee1_id: create(:referee, email: 'ref@example.de').id,
                                             status: 'tentative')
      login(create(:user, :admin))

      perform_enqueued_jobs do
        post "/api/v2/admin/referee_assignments/#{assignment.id}/notify"
      end

      assert_response :success
      mail = ActionMailer::Base.deliveries.last
      assert_not_nil mail
      assert_includes mail.subject, '10.01.2026'
      # I18n.l haette hier "January 10, 2026" geliefert: es gibt nur en.yml.
      assert_not_includes mail.subject, 'January'
      assert_includes mail.body.encoded, '10.01.2026'
    end

    test 'nicht lesbares Spieltagsdatum meldet statt still zu scheitern' do
      sa = create(:state_association, referee_assignment_enabled: true)
      go = create(:game_operation, state_association_id: sa.id)
      game = assignable_game(go)
      game.game_day.update_columns(date: 'unbekannt')
      assignment = RefereeAssignment.create!(game: game, referee1_id: create(:referee, email: 'ref@example.de').id,
                                             status: 'tentative')
      login(create(:user, :admin))

      # Vorher: I18n.l(nil) warf ArgumentError im Hintergrund-Job, waehrend die
      # Oberflaeche Erfolg meldete und notified_tentative_at gesetzt wurde.
      assert_no_enqueued_emails do
        post "/api/v2/admin/referee_assignments/#{assignment.id}/notify"
      end

      assert_response :unprocessable_entity
      assert_nil assignment.reload.notified_tentative_at
    end

    # -------------------------------------------------------------------------
    # Gastschiedsrichter: Aushilfen ohne eigene Zustaendigkeit im Verband. Sie
    # haben im Regelfall kein Selbstverwaltungskonto und koennen daher keine
    # Verfuegbarkeit hinterlegen -- die Auswahl verlangt von ihnen keine.
    # -------------------------------------------------------------------------

    test 'available bietet einen Gast ohne hinterlegte Verfuegbarkeit an' do
      sa = create(:state_association, referee_assignment_enabled: true)
      go = create(:game_operation, state_association_id: sa.id)
      club = create(:club, state_association_id: sa.id)
      date = Date.today + 7
      guest = create(:referee, guest: true, lizenznummer: nil, club_id: club.id)

      login(create(:user, :assigner_scoped, game_operation_id: go.id))
      get "/api/v2/admin/referee_assignments/available?date=#{date}"

      assert_response :success
      entry = response.parsed_body.find { |r| r['id'] == guest.id }
      assert_not_nil entry, 'Gast steht ohne Verfuegbarkeit in der Auswahl'
      assert_equal true, entry['guest']
      assert_equal "G-#{guest.id}", entry['lizenznummer_display']
    end

    # Gegenprobe: Die Verfuegbarkeits-Bedingung gilt fuer alle anderen weiter.
    # Ein OR, das sie versehentlich ganz aushebelt, fiele hier auf.
    test 'available bleibt fuer regulaere Schiris an die Verfuegbarkeit gebunden' do
      sa = create(:state_association, referee_assignment_enabled: true)
      go = create(:game_operation, state_association_id: sa.id)
      club = create(:club, state_association_id: sa.id)
      date = Date.today + 7
      without_availability = create(:referee, club_id: club.id)

      login(create(:user, :assigner_scoped, game_operation_id: go.id))
      get "/api/v2/admin/referee_assignments/available?date=#{date}"

      assert_response :success
      assert_not_includes response.parsed_body.map { |r| r['id'] }, without_availability.id
    end

    test 'available wirft einen tagesgleich angesetzten Gast aus der Auswahl' do
      sa = create(:state_association, referee_assignment_enabled: true)
      go = create(:game_operation, state_association_id: sa.id)
      club = create(:club, state_association_id: sa.id)
      game = assignable_game(go) # Spieltag: Date.today + 7
      guest = create(:referee, guest: true, lizenznummer: nil, club_id: club.id)
      RefereeAssignment.create!(game: game, referee1_id: guest.id, status: 'tentative')

      login(create(:user, :assigner_scoped, game_operation_id: go.id))
      get "/api/v2/admin/referee_assignments/available?date=#{Date.today + 7}"

      assert_response :success
      assert_not_includes response.parsed_body.map { |r| r['id'] }, guest.id
    end

    # Nach einem Merge bleibt der aufgeloeste Datensatz bestehen; er darf nicht
    # ueber die Gast-Ausnahme in die Auswahl zurueckkommen.
    test 'available bietet eine aufgeloeste Gast-Dublette nicht an' do
      sa = create(:state_association, referee_assignment_enabled: true)
      go = create(:game_operation, state_association_id: sa.id)
      club = create(:club, state_association_id: sa.id)
      master = create(:referee, club_id: club.id)
      merged = create(:referee, guest: true, lizenznummer: nil, club_id: club.id,
                                merged_into_id: master.id)

      login(create(:user, :assigner_scoped, game_operation_id: go.id))
      get "/api/v2/admin/referee_assignments/available?date=#{Date.today + 7}"

      assert_response :success
      assert_not_includes response.parsed_body.map { |r| r['id'] }, merged.id
    end

    # Der Verbands-Scope gilt fuer Gaeste unveraendert: Ein Gast ohne Verein und
    # ohne Spielbetrieb gehoert keinem Landesverband und ist deshalb nur fuer
    # Admin und die bundesweite Ansetzung sichtbar.
    test 'LV-Ansetzer sieht einen Gast ohne Verein nicht, der Admin schon' do
      sa = create(:state_association, referee_assignment_enabled: true)
      go = create(:game_operation, state_association_id: sa.id)
      date = Date.today + 7
      guest = create(:referee, guest: true, lizenznummer: nil, club_id: nil)

      login(create(:user, :assigner_scoped, game_operation_id: go.id))
      get "/api/v2/admin/referee_assignments/available?date=#{date}"

      assert_response :success
      assert_not_includes response.parsed_body.map { |r| r['id'] }, guest.id

      login(create(:user, :admin))
      get "/api/v2/admin/referee_assignments/available?date=#{date}"

      assert_response :success
      assert_includes response.parsed_body.map { |r| r['id'] }, guest.id
    end

    # Bewusst ein Gast im Verband des Ansetzers: `#create` prüft nur das Spiel
    # (`authorize_game_scope!`), nicht die Person — ein Gast ohne Verein wäre
    # für diesen Ansetzer in `#available` unsichtbar und trotzdem ansetzbar.
    # Diese Lücke ist Altbestand und gilt für jeden Schiedsrichter (siehe
    # api#635); ein Test darf sie nicht als gewolltes Verhalten festschreiben.
    test 'Ansetzung eines Gastes wird gespeichert' do
      sa = create(:state_association, referee_assignment_enabled: true)
      go = create(:game_operation, state_association_id: sa.id)
      club = create(:club, state_association_id: sa.id)
      game = assignable_game(go)
      guest = create(:referee, guest: true, lizenznummer: nil, club_id: club.id)
      login(create(:user, :assigner_scoped, game_operation_id: go.id))

      post '/api/v2/admin/referee_assignments',
           params: { assignment: { game_id: game.id, referee1_id: guest.id, status: 'tentative' } }

      assert_response :created
      assert_equal guest.id, RefereeAssignment.find(response.parsed_body['id']).referee1_id
    end

    # Gaeste tragen kein Ablaufdatum und fielen ueber Referee.active aus der
    # Matrix -- eine Gast-Ansetzung fehlte damit im Bild des Wochenendes.
    test 'Verfuegbarkeits-Matrix enthaelt den angesetzten Gast trotz fehlender Gueltigkeit' do
      sa = create(:state_association, referee_assignment_enabled: true)
      go = create(:game_operation, state_association_id: sa.id)
      club = create(:club, state_association_id: sa.id)
      game = assignable_game(go)
      guest = create(:referee, guest: true, lizenznummer: nil, club_id: club.id)
      RefereeAssignment.create!(game: game, referee1_id: guest.id, status: 'tentative')
      licensed = create(:referee, club_id: club.id, gueltigkeit: Date.today + 90)
      lapsed = create(:referee, club_id: club.id, gueltigkeit: Date.today - 1)

      login(create(:user, :assigner_scoped, game_operation_id: go.id))
      get '/api/v2/admin/referee_assignments/availability'

      assert_response :success
      ids = response.parsed_body['referees'].map { |r| r['id'] }
      assert_includes ids, guest.id
      assert_includes ids, licensed.id
      # Fuer regulaere Schiedsrichter bleibt das gueltige Lizenzdatum Bedingung.
      assert_not_includes ids, lapsed.id
    end

    # Die Gegenprobe zur Zeile darueber, und der Grund fuer die Einschraenkung:
    # Ein Gast kann keine Verfuegbarkeit hinterlegen, seine Zeile waere also an
    # JEDEM Wochenende durchgehend rot -- so viele dauerhaft rote Zeilen, wie es
    # Gast-Datensaetze gibt, und sie verschieben die Summen unter den
    # Wochenenden. In der Matrix stehen deshalb nur Gaeste mit Bezug zum
    # Fenster: angesetzt oder mit gemeldetem Termin.
    test 'Verfuegbarkeits-Matrix laesst einen Gast ohne Bezug zum Fenster weg' do
      sa = create(:state_association, referee_assignment_enabled: true)
      go = create(:game_operation, state_association_id: sa.id)
      club = create(:club, state_association_id: sa.id)
      game = assignable_game(go)
      ohne_bezug = create(:referee, guest: true, lizenznummer: nil, club_id: club.id)
      gemeldet = create(:referee, guest: true, lizenznummer: nil, club_id: club.id)
      RefereeAvailability.create!(referee: gemeldet, date: game.game_day.date.to_date)

      login(create(:user, :assigner_scoped, game_operation_id: go.id))
      get '/api/v2/admin/referee_assignments/availability'

      assert_response :success
      ids = response.parsed_body['referees'].map { |r| r['id'] }
      assert_includes ids, gemeldet.id
      assert_not_includes ids, ohne_bezug.id
    end

    # `#available_coaches` hat dieselbe Aenderung bekommen wie `#available`,
    # aber ohne Test -- und dort ist sie verschachtelter: Der OR steht vor dem
    # Join auf die Zusatzqualifikation, dem LIKE 'B%' und einem `distinct`,
    # und `scope_to_permitted_referees` legt selbst noch ein `.or` darum.
    test 'available_coaches enthaelt den Gast mit B-Qualifikation ohne Verfuegbarkeit' do
      sa = create(:state_association, referee_assignment_enabled: true)
      go = create(:game_operation, state_association_id: sa.id)
      club = create(:club, state_association_id: sa.id)
      game = assignable_game(go)
      date = game.game_day.date.to_date
      guest = create(:referee, guest: true, lizenznummer: nil, club_id: club.id)
      qualify_as_coach(guest, date)
      ohne_verfuegbarkeit = create(:referee, club_id: club.id)
      qualify_as_coach(ohne_verfuegbarkeit, date)
      login(create(:user, :assigner_scoped, game_operation_id: go.id))

      get "/api/v2/admin/referee_assignments/available_coaches?date=#{date}"

      assert_response :success
      eintraege = response.parsed_body
      gast = eintraege.find { |r| r['id'] == guest.id }
      assert_not_nil gast, 'Gast fehlt in der Coach-Auswahl'
      # Das Kennzeichen ist der ganze Vertrag, an dem die Oberflaeche haengt.
      assert_equal true, gast['guest']
      # Gegenprobe: Fuer regulaere Coaches bleibt die Verfuegbarkeit Bedingung,
      # der OR darf nicht zu weit greifen.
      assert_not_includes eintraege.map { |r| r['id'] }, ohne_verfuegbarkeit.id
    end

    # Abgedeckt war nur der Gast OHNE Verein. Der Gast mit Verein in einem
    # fremden Landesverband ist die Lage, in der ein fehlender Scope auffaellt:
    # Ein Leck dort zeigte jedem LV-Ansetzer bundesweit alle Gaeste.
    test 'ein Gast eines fremden Landesverbands bleibt unsichtbar' do
      sa = create(:state_association, referee_assignment_enabled: true)
      go = create(:game_operation, state_association_id: sa.id)
      eigener_club = create(:club, state_association_id: sa.id)
      game = assignable_game(go)
      date = game.game_day.date.to_date
      eigener_gast = create(:referee, guest: true, lizenznummer: nil, club_id: eigener_club.id)
      RefereeAvailability.create!(referee: eigener_gast, date: date)
      fremder_club = create(:club, state_association_id: create(:state_association).id)
      fremder_gast = create(:referee, guest: true, lizenznummer: nil, club_id: fremder_club.id)
      RefereeAvailability.create!(referee: fremder_gast, date: date)
      login(create(:user, :assigner_scoped, game_operation_id: go.id))

      get "/api/v2/admin/referee_assignments/available?date=#{date}"
      assert_response :success
      ids = response.parsed_body.map { |r| r['id'] }
      assert_includes ids, eigener_gast.id
      assert_not_includes ids, fremder_gast.id

      get '/api/v2/admin/referee_assignments/availability'
      assert_response :success
      matrix_ids = response.parsed_body['referees'].map { |r| r['id'] }
      assert_includes matrix_ids, eigener_gast.id
      assert_not_includes matrix_ids, fremder_gast.id
    end

    # Der eine Fall, in dem der `merged_into_id`-Riegel wirklich etwas tut: Die
    # Dublette hat VOR dem Zusammenfuehren einen Termin gemeldet und kaeme sonst
    # ueber die Verfuegbarkeits-Seite zurueck in die Auswahl -- mit dem
    # aufgeloesten Datensatz.
    test 'eine aufgeloeste Gast-Dublette mit gemeldetem Termin bleibt draussen' do
      sa = create(:state_association, referee_assignment_enabled: true)
      go = create(:game_operation, state_association_id: sa.id)
      club = create(:club, state_association_id: sa.id)
      game = assignable_game(go)
      date = game.game_day.date.to_date
      master = create(:referee, guest: true, lizenznummer: nil, club_id: club.id)
      dublette = create(:referee, guest: true, lizenznummer: nil, club_id: club.id,
                                  merged_into_id: master.id)
      RefereeAvailability.create!(referee: dublette, date: date)
      login(create(:user, :assigner_scoped, game_operation_id: go.id))

      get "/api/v2/admin/referee_assignments/available?date=#{date}"

      assert_response :success
      ids = response.parsed_body.map { |r| r['id'] }
      assert_not_includes ids, dublette.id
      assert_includes ids, master.id
    end

    # `lizenznummer_display` liefert fuer einen Gast die Ersatzform „G-<id>",
    # also die interne Datenbank-ID. Im oeffentlichen Spielplan hat die nichts
    # zu suchen -- vor der Ansetzbarkeit von Gaesten konnte sie dort nicht
    # auftreten.
    test 'der oeffentliche Spielplan zeigt zum Gast keine Ersatznummer' do
      sa = create(:state_association, referee_assignment_enabled: true)
      go = create(:game_operation, state_association_id: sa.id)
      club = create(:club, state_association_id: sa.id)
      game = assignable_game(go)
      guest = create(:referee, guest: true, lizenznummer: nil, club_id: club.id,
                               vorname: 'Max', nachname: 'Mustermann')
      regulaer = create(:referee, club_id: club.id, lizenznummer: 100_234,
                                  vorname: 'Tom', nachname: 'Meier')
      assignment = RefereeAssignment.create!(game: game, referee1_id: guest.id,
                                             referee2_id: regulaer.id, status: 'tentative')
      login(create(:user, :assigner_scoped, game_operation_id: go.id))

      post "/api/v2/admin/referee_assignments/#{assignment.id}/publish"

      assert_response :success
      oeffentlich = game.reload.nominated_referee_string
      assert_equal 'Mustermann, Max / 100234 Meier, Tom', oeffentlich
      assert_no_match(/G-/, oeffentlich)
    end

    private

    # Schiri mit gueltiger B-Zusatzlizenz, aber OHNE Verfuegbarkeit -- der
    # Unterschied zu `coach_referee`, an dem die Gast-Ausnahme haengt.
    def qualify_as_coach(referee, date)
      type = RefereeQualificationType.create!(name: "B-Coach #{SecureRandom.hex(3)}")
      RefereeQualification.create!(referee: referee, referee_qualification_type: type,
                                   valid_until: date + 1.year)
      referee
    end

    # Spiel, das in der Ansetzungs-Liste auftaucht: noch nicht begonnen und für die
    # Personenebene markiert. Die Markierung stand bis August 2026 als Sentinel-Text
    # im nominated_referee_string und ist seit #403 eine eigene Spalte.
    def assignable_game(game_operation)
      league = create(:league, game_operation: game_operation)
      game_day = create(:game_day, league: league, date: (Date.today + 7).to_s)
      create(:game, game_day: game_day, game_status: 'pregame', person_level_assignment: true)
    end

    # Schiri mit gültiger B-Zusatzlizenz und hinterlegter Verfügbarkeit am Datum.
    def coach_referee(club, date)
      referee = create(:referee, club_id: club.id)
      type = RefereeQualificationType.create!(name: "B-Coach #{SecureRandom.hex(3)}")
      # Ein Datum nach dem Spieltag: Die Gueltigkeit ist seit api#585 Pflichtfeld,
      # ein leeres Feld galt vorher als unbefristet.
      RefereeQualification.create!(referee: referee, referee_qualification_type: type,
                                   valid_until: date + 1.year)
      RefereeAvailability.create!(referee: referee, date: date)
      referee
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
