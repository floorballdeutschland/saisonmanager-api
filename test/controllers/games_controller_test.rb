require 'test_helper'

class GamesControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    create(:setting)
    @sa = create(:state_association)
    @go = create(:game_operation, state_association_id: @sa.id)
    @league = create(:league, game_operation: @go)
    @club = create(:club)
    @arena = create(:arena)
    @game_day = GameDay.create!(league: @league, arena: @arena, club: @club, number: 1, date: '2026-01-01')
    @home = create(:team, league: @league, club: @club)
    @guest = create(:team, league: @league, club: @club)
    @game = Game.create!(
      game_day: @game_day,
      home_team: @home,
      guest_team: @guest,
      started: false,
      ended: false,
      forfait: 0,
      overtime: false,
      legacy: false,
      events: [],
      players: { 'home' => [], 'guest' => [] },
      special_event_string: 'Interner Vermerk'
    )
  end

  # Die Sammelliste aller Spiele (Game.all, ohne Filter und ohne Grenze) ist
  # bewusst weg – weder öffentlich noch für Angemeldete.
  test 'die Sammelliste aller Spiele ist nicht mehr erreichbar' do
    assert_raises(ActionController::RoutingError) { get '/api/v2/games.json' }
  end

  test 'die Sammelliste aller Spiele ist auch fuer Angemeldete weg' do
    login(create(:user, :admin))

    assert_raises(ActionController::RoutingError) { get '/api/v2/games.json' }
  end

  test 'ein einzelnes Spiel bleibt abrufbar' do
    login(create(:user, :admin))

    get "/api/v2/games/#{@game.id}.json"

    assert_response :success
  end

  test 'additional_fields liefert dem SBK des Spielbetriebs die internen Felder' do
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    get "/api/v2/user/games/#{@game.id}/additional_fields.json"

    assert_response :success
    assert_equal 'Interner Vermerk', JSON.parse(response.body)['special_event_string']
  end

  test 'additional_fields erlaubt dem TM der beteiligten Mannschaft' do
    login(create(:user, :tm, team_id: @home.id))

    get "/api/v2/user/games/#{@game.id}/additional_fields.json"

    assert_response :success
    assert_equal 'Interner Vermerk', JSON.parse(response.body)['special_event_string']
  end

  test 'additional_fields liefert unbeteiligten Logins ein leeres Objekt' do
    other_sa = create(:state_association)
    other_go = create(:game_operation, state_association_id: other_sa.id)
    login(create(:user, :sbk_scoped, game_operation_id: other_go.id))

    get "/api/v2/user/games/#{@game.id}/additional_fields.json"

    assert_response :success
    assert_equal({}, JSON.parse(response.body))
  end

  test 'update_start_end ist für Nicht-Admins gesperrt' do
    login(create(:user, :sbk_global))

    get '/internal/update_games/update_start_end'

    assert_response :forbidden
  end

  test 'update_start_end ist für Admins erlaubt' do
    login(create(:user, :admin))

    get '/internal/update_games/update_start_end'

    assert_response :success
  end

  test 'Anpfiff-Änderung benachrichtigt Schiri und Ausrichter bei veröffentlichter Ansetzung' do
    @club.update!(contact_email: 'ausrichter@example.de')
    referee = create(:referee, email: 'schiri@example.de')
    RefereeAssignment.create!(game: @game, referee1_id: referee.id, status: 'published')
    login(create(:user, :admin))

    # Schiri + Ausrichter
    assert_enqueued_emails 2 do
      patch "/api/v2/games/#{@game.id}", params: { game: { start_time: '15:00' } }
    end
    assert_response :success
  end

  test 'Absage (notice_type) benachrichtigt bei veröffentlichter Ansetzung' do
    referee = create(:referee, email: 'schiri@example.de')
    RefereeAssignment.create!(game: @game, referee1_id: referee.id, status: 'published')
    login(create(:user, :admin))

    # nur der Schiri (Ausrichter hat keine contact_email)
    assert_enqueued_emails 1 do
      patch "/api/v2/games/#{@game.id}", params: { game: { notice_type: 'Canceled' } }
    end
    assert_response :success
  end

  test 'kein Versand ohne Ansetzung' do
    login(create(:user, :admin))

    assert_no_enqueued_emails do
      patch "/api/v2/games/#{@game.id}", params: { game: { start_time: '15:00' } }
    end
    assert_response :success
  end

  test 'unveränderter Anpfiff/Absage löst keinen Versand aus' do
    referee = create(:referee, email: 'schiri@example.de')
    RefereeAssignment.create!(game: @game, referee1_id: referee.id, status: 'published')
    login(create(:user, :admin))

    # Nur ein anderes (erlaubtes) Feld ändern → keine Benachrichtigung
    assert_no_enqueued_emails do
      patch "/api/v2/games/#{@game.id}", params: { game: { game_number: '99' } }
    end
    assert_response :success
  end

  # ---------------------------------------------------------------------------
  # Spielbetriebs-Scoping der Schreibpfade (#214)
  # ---------------------------------------------------------------------------

  # Vollständige Nutzlast, seit add_event Ereignisart und Mannschaft prüft. Die
  # beiden Abweisungs-Fälle darunter kommen bewusst ohne aus: Die Rechteprüfung
  # läuft vor dem Guard, ein 403 darf nicht zu einem 422 werden.
  test 'add_event: SBK des Spielbetriebs darf ein Ereignis eintragen' do
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    post "/api/v2/user/games/#{@game.id}/events/add",
         params: { period: 1, time: '10:00', event_type: 'goal', event_team: 'home',
                   home_goals: 1, guest_goals: 0, home_number: 7 }

    assert_response :success
  end

  test 'add_event: SBK eines fremden Spielbetriebs wird abgewiesen' do
    other_go = create(:game_operation, state_association_id: create(:state_association).id)
    login(create(:user, :sbk_scoped, game_operation_id: other_go.id))

    post "/api/v2/user/games/#{@game.id}/events/add", params: { period: 1, time: '10:00' }

    assert_response :forbidden
    assert_empty @game.reload.events
  end

  test 'set_game_status: SBK eines fremden Spielbetriebs wird abgewiesen' do
    other_go = create(:game_operation, state_association_id: create(:state_association).id)
    login(create(:user, :sbk_scoped, game_operation_id: other_go.id))

    post "/api/v2/user/games/#{@game.id}/game_status", params: { game_status: 'ingame' }

    assert_response :forbidden
  end

  # editable steuert im Frontend, ob die Spielbericht-Oberfläche überhaupt
  # erscheint, und erreicht can_edit_lineup? auf einem anderen Weg als die
  # Schreib-Actions (direkt, nicht über can_edit_game?).
  test 'editable: true für den SBK des Spielbetriebs, false für einen fremden' do
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))
    get "/api/v2/user/games/#{@game.id}/editable"
    assert_response :success
    assert_equal true, response.parsed_body

    other_go = create(:game_operation, state_association_id: create(:state_association).id)
    login(create(:user, :sbk_scoped, game_operation_id: other_go.id))
    get "/api/v2/user/games/#{@game.id}/editable"
    assert_response :success
    assert_equal false, response.parsed_body
  end

  # Die Sperre bei abgeschlossenem Spielbericht darf nicht über eine
  # fachfremde SBK-Rolle aushebelbar sein (#214, Review-Fund).
  test 'add_event: fremde SBK-Rolle hebelt die Sperre des geschlossenen Berichts nicht aus' do
    other_go = create(:game_operation, state_association_id: create(:state_association).id)
    @game.update!(game_status: 'match_record_closed')
    user = create(:user, :sbk_scoped, game_operation_id: other_go.id)
    user.update!(permissions: user.permissions + [{ 'user_group_id' => 4, 'game_operation_id' => 0,
                                                    'club_id' => @club.id }])
    login(user)

    post "/api/v2/user/games/#{@game.id}/events/add", params: { period: 1, time: '10:00' }

    assert_response :forbidden
    assert_empty @game.reload.events
  end

  # ---------------------------------------------------------------------------
  # Technisches Tor: zugesprochen, also kein Strafschuss, aber mit Vorlage
  # ---------------------------------------------------------------------------

  test 'add_event: technisches Tor behält seine Vorlage und kommt beschriftet zurück' do
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    post "/api/v2/user/games/#{@game.id}/events/add", params: {
      period: 1, time: '10:00', event_type: 'goal', event_team: 'home',
      home_goals: 1, guest_goals: 0, home_number: 7, home_assist: 9,
      goal_type: 'technical'
    }

    assert_response :success
    event = @game.reload.events.first
    assert_equal 'technical', event['goal_type']
    assert_equal '9', event['home_assist'].to_s
    # Schreib- und Leseweg zusammen: nur so fällt auf, wenn die Markierung zwar
    # gespeichert, aber nicht mehr zu einem Label aufgelöst wird.
    assert_equal 'Technisches Tor', response.parsed_body.first['goal_type_string']
  end

  # Der Fall, den sonst nichts abfängt: ein Aufruf mit beiden Markierungen im
  # selben Request (direkter API-Zugriff oder veralteter Client). Das Formular
  # koppelt die Haken, und beim Umstellen eines bestehenden Strafschusses ist
  # der Code ohnehin schon weg, bevor die Bereinigung läuft.
  #
  # Je Schreibweg einmal, weil beide das Ereignis unterschiedlich aufbauen:
  # update_event ändert den string-keyed Hash aus dem JSONB, add_event einen
  # HashWithIndifferentAccess. Gelöscht wird mit String-Key.
  test 'add_event: technisches Tor und Strafschuss zugleich lässt nur die Markierung übrig' do
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    post "/api/v2/user/games/#{@game.id}/events/add", params: {
      period: 1, time: '10:00', event_type: 'goal', event_team: 'home',
      home_goals: 1, guest_goals: 0, home_number: 7,
      goal_type: 'technical', penalty_code_id: 23
    }

    assert_response :success
    event = @game.reload.events.first
    assert_equal 'technical', event['goal_type']
    assert_not event.key?('penalty_code_id')
  end

  test 'update_event: technisches Tor und Strafschuss zugleich lässt nur die Markierung übrig' do
    @game.update!(events: [{ 'id' => 1, 'period' => 1, 'time' => '10:00', 'event_type' => 'goal',
                             'event_team' => 'home', 'home_goals' => 1, 'guest_goals' => 0,
                             'home_number' => 7, 'home_assist' => 9 }])
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    post "/api/v2/user/games/#{@game.id}/events/update", params: {
      event_id: 1, period: 1, time: '10:00', event_type: 'goal', event_team: 'home',
      home_goals: 1, guest_goals: 0, home_number: 7, home_assist: 9,
      goal_type: 'technical', penalty_code_id: 23
    }

    assert_response :success
    event = @game.reload.events.first
    assert_equal 'technical', event['goal_type']
    assert_not event.key?('penalty_code_id')
    assert_equal '9', event['home_assist'].to_s
  end

  test 'update_event: Umstellen eines Strafschusses auf technisches Tor' do
    @game.update!(events: [{ 'id' => 1, 'period' => 1, 'time' => '10:00', 'event_type' => 'goal',
                             'event_team' => 'home', 'home_goals' => 1, 'guest_goals' => 0,
                             'home_number' => 7, 'home_assist' => 9, 'penalty_code_id' => 23 }])
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    post "/api/v2/user/games/#{@game.id}/events/update", params: {
      event_id: 1, period: 1, time: '10:00', event_type: 'goal', event_team: 'home',
      home_goals: 1, guest_goals: 0, home_number: 7, home_assist: 9, goal_type: 'technical'
    }

    assert_response :success
    event = @game.reload.events.first
    assert_equal 'technical', event['goal_type']
    assert_nil event['penalty_code_id']
    assert_equal '9', event['home_assist'].to_s
  end

  test 'update_event: Umstellen zurück auf reguläres Tor löscht die Markierung' do
    @game.update!(events: [{ 'id' => 1, 'period' => 1, 'time' => '10:00', 'event_type' => 'goal',
                             'event_team' => 'home', 'home_goals' => 1, 'guest_goals' => 0,
                             'home_number' => 7, 'home_assist' => 9, 'goal_type' => 'technical' }])
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    post "/api/v2/user/games/#{@game.id}/events/update", params: {
      event_id: 1, period: 1, time: '10:00', event_type: 'goal', event_team: 'home',
      home_goals: 1, guest_goals: 0, home_number: 7, home_assist: 9
    }

    assert_response :success
    event = @game.reload.events.first
    assert_nil event['goal_type']
    assert_equal '9', event['home_assist'].to_s
  end

  # ---------------------------------------------------------------------------
  # Ereignisart und Mannschaft: Wertebereich statt ungeprüfter Übernahme (#295)
  #
  # Der Schaden ist nicht der typlose Rumpf in events, sondern der Spielstand:
  # sort_events! zählt nur bei event_type == 'goal' hoch, und Game#result
  # überspringt Zeilen ohne Spielstand. Ein Tor, dem die Kennzeichnung genommen
  # wurde, verschwindet damit lautlos aus dem Ergebnis. Deshalb prüft jeder Fall
  # unten nicht nur den Statuscode, sondern auch das Ergebnis.
  # ---------------------------------------------------------------------------

  test 'update_event: ohne Ereignisart bleibt das Tor unangetastet und der Spielstand steht' do
    two_goals!
    assert_equal '2:0', score
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    post "/api/v2/user/games/#{@game.id}/events/update", params: {
      event_id: 2, period: 1, time: '20:00', event_team: 'home', home_goals: 2, guest_goals: 0
    }

    assert_response :unprocessable_entity
    assert_match(/Ereignisart/, response.parsed_body['message'])
    event = @game.reload.events.find { |e| e['id'].to_i == 2 }
    assert_equal 'goal', event['event_type'], 'die Kennzeichnung darf nicht verloren gehen'
    assert_equal '2:0', score, 'der Spielstand darf nicht um ein Tor sinken'
  end

  test 'update_event: leere Ereignisart wird genauso abgewiesen wie eine fehlende' do
    two_goals!
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    post "/api/v2/user/games/#{@game.id}/events/update", params: {
      event_id: 2, period: 1, time: '20:00', event_type: '', event_team: 'home',
      home_goals: 2, guest_goals: 0
    }

    assert_response :unprocessable_entity
    assert_equal '2:0', score
  end

  test 'update_event: unbekannte Ereignisart wird abgewiesen' do
    two_goals!
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    post "/api/v2/user/games/#{@game.id}/events/update", params: {
      event_id: 2, period: 1, time: '20:00', event_type: 'timeout', event_team: 'home',
      home_goals: 2, guest_goals: 0
    }

    assert_response :unprocessable_entity
    assert_equal 'goal', @game.reload.events.find { |e| e['id'].to_i == 2 }['event_type']
  end

  # event_team steuert ein if/else, in dem alles ausser 'home' als Gast gilt.
  # Ohne Wertebereich landete eine fehlende Angabe damit stumm bei der
  # Gastmannschaft, samt Löschen der Heim-Trikotnummern.
  test 'update_event: ohne Mannschaft bleiben die Trikotnummern der Heimseite stehen' do
    two_goals!
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    post "/api/v2/user/games/#{@game.id}/events/update", params: {
      event_id: 2, period: 1, time: '20:00', event_type: 'goal', home_goals: 2, guest_goals: 0
    }

    assert_response :unprocessable_entity
    assert_match(/Mannschaft/, response.parsed_body['message'])
    event = @game.reload.events.find { |e| e['id'].to_i == 2 }
    assert_equal 'home', event['event_team']
    assert_equal '9', event['home_number'].to_s
  end

  test 'update_event: ohne Zeit oder Abschnitt wird abgewiesen' do
    two_goals!
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))
    base = { event_id: 2, event_type: 'goal', event_team: 'home', home_goals: 2, guest_goals: 0 }

    post "/api/v2/user/games/#{@game.id}/events/update", params: base.merge(period: 1)
    assert_response :unprocessable_entity
    assert_match(/Ereigniszeit/, response.parsed_body['message'])

    post "/api/v2/user/games/#{@game.id}/events/update", params: base.merge(time: '20:00')
    assert_response :unprocessable_entity
    assert_match(/Spielabschnitt/, response.parsed_body['message'])

    event = @game.reload.events.find { |e| e['id'].to_i == 2 }
    assert_equal '20:00', event['time']
    assert_equal 1, event['period'].to_i
  end

  # Zweiter Schreibweg. Anders als in #295 vermutet setzt add_event event_type
  # nicht immer: Es schreibt params[:event_type] genauso unbedingt und legt bei
  # fehlendem Wert eine typlose Zeile gleich neu an.
  test 'add_event: ohne Ereignisart entsteht keine typlose Zeile' do
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    post "/api/v2/user/games/#{@game.id}/events/add",
         params: { period: 1, time: '10:00', event_team: 'home', home_goals: 1, guest_goals: 0 }

    assert_response :unprocessable_entity
    assert_empty @game.reload.events
  end

  # Gegenrichtung: Der Guard darf keinen regulären Vorgang blockieren. Umstellen
  # eines Tores auf eine Strafe ist der Fall, den das Formular am häufigsten
  # schickt.
  test 'update_event: Umstellen von Tor auf Strafe geht weiterhin durch' do
    two_goals!
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    post "/api/v2/user/games/#{@game.id}/events/update", params: {
      event_id: 2, period: 1, time: '20:00', event_type: 'penalty', event_team: 'guest',
      home_goals: 1, guest_goals: 0, guest_number: 4, penalty_id: 1, penalty_code_id: 1
    }

    assert_response :success
    event = @game.reload.events.find { |e| e['id'].to_i == 2 }
    assert_equal 'penalty', event['event_type']
    assert_equal 'guest', event['event_team']
    # Hier SOLL der Spielstand sinken: Das zweite Tor ist jetzt eine Strafe.
    assert_equal '1:0', score
  end

  # Zeit und Abschnitt hatten nur eine Anwesenheitsprüfung, und die reicht bei
  # einem Array nicht: `["20:00"].blank?` ist false. Die Werteliste bei
  # event_type/event_team fängt denselben Fall von sich aus ab.
  test 'update_event: eine Zeit als Array landet nicht im Spielbericht' do
    two_goals!
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    post "/api/v2/user/games/#{@game.id}/events/update", params: {
      event_id: 2, period: '1', time: ['20:00'], event_type: 'goal', event_team: 'home',
      home_goals: 2, guest_goals: 0
    }

    assert_response :unprocessable_entity
    assert_equal '20:00', @game.reload.events.find { |e| e['id'].to_i == 2 }['time'],
                 'im JSONB darf keine Liste stehen'
  end

  # sort_events! sortiert über [period, time, id, row]. Ein Array neben einer
  # Zeichenkette liess den Vergleich mit ArgumentError abbrechen, also ein 500er
  # allein durch die Nutzlast.
  test 'add_event: ein Abschnitt als Array bricht das Speichern nicht ab' do
    two_goals!
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    post "/api/v2/user/games/#{@game.id}/events/add", params: {
      period: ['1'], time: '30:00', event_type: 'goal', event_team: 'home',
      home_goals: 3, guest_goals: 0
    }

    assert_response :unprocessable_entity
    assert_equal 2, @game.reload.events.size
  end

  # Gegenrichtung, und der Grund, warum für den Abschnitt KEINE Zeichenkette
  # erzwungen wird: Das Spielbericht-Formular schickt JSON, `parseInt` macht
  # daraus eine Zahl. Ein String-Zwang hätte die Erfassung am Spieltag zerlegt.
  #
  # Der Fall deckt zugleich das gemischte Speichern ab: Die vorhandenen Zeilen
  # tragen '1' als Zeichenkette, die Änderung schreibt eine Zahl. Vor der
  # Normalisierung des Sortierschlüssels endete genau das in einem 500er.
  test 'update_event: ein Abschnitt als JSON-Zahl geht durch' do
    two_goals!
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    post "/api/v2/user/games/#{@game.id}/events/update",
         params: { event_id: 2, period: 2, time: '25:00', event_type: 'goal', event_team: 'home',
                   home_goals: 2, guest_goals: 0 }.to_json,
         headers: { 'CONTENT_TYPE' => 'application/json' }

    assert_response :success
    assert_equal 2, @game.reload.events.find { |e| e['id'].to_i == 2 }['period'].to_i
  end

  # ---------------------------------------------------------------------------
  # set_field: dieselbe Rechteregel wie für den übrigen Spielbericht
  #
  # Ein Turnier an einem Ort (DM) ist der Fall, der die frühere Sonderlogik
  # auffliegen ließ: Der ausrichtende Verein führt das Sekretariat für alle
  # Partien, spielt aber in den meisten nicht selbst mit.

  test 'set_field: der VM des ausrichtenden Vereins darf die Kopfdaten speichern' do
    hosting_club = create(:club)
    game = game_hosted_by(hosting_club)
    login(create(:user, :vm, club_id: hosting_club.id))

    post "/api/v2/user/games/#{game.id}/set_field", params: { game: { audience: '40' } }

    assert_response :success
    assert_equal 40, game.reload.audience.to_i
  end

  # Schreiben allein genügt nicht: Ohne Lesezugriff bekäme der Ausrichter ein
  # leeres Formular, in das er zwar eintragen darf, dessen bereits gefüllte
  # Felder er aber nicht sieht (Spielsekretariat, Zeitnehmer, Betreuer, Vermerk
  # der Schiedsrichter). Das war die zweite Hälfte des Fehlers.
  test 'additional_fields: der VM des ausrichtenden Vereins sieht die internen Felder' do
    hosting_club = create(:club)
    game = game_hosted_by(hosting_club)
    game.update!(record_keeper_string: 'Ziegler, Carolina')
    login(create(:user, :vm, club_id: hosting_club.id))

    get "/api/v2/user/games/#{game.id}/additional_fields.json"

    assert_response :success
    assert_equal 'Ziegler, Carolina', JSON.parse(response.body)['record_keeper_string']
  end

  test 'additional_fields: ein unbeteiligter VM sieht die internen Felder nicht' do
    game = game_hosted_by(create(:club))
    game.update!(record_keeper_string: 'Ziegler, Carolina')
    login(create(:user, :vm, club_id: create(:club).id))

    get "/api/v2/user/games/#{game.id}/additional_fields.json"

    assert_response :success
    assert_equal({}, JSON.parse(response.body))
  end

  # Gegenprobe zum Test darüber: Ohne Bezug zum Spiel bleibt es bei 403. Die
  # Zusammenlegung erweitert die Rechte nur um den Ausrichter, nicht um jeden VM.
  # Die Zustandsprüfung gehört dazu: Ein 403, der trotzdem schreibt, käme sonst
  # durch.
  test 'set_field: ein unbeteiligter VM bleibt draußen' do
    game = game_hosted_by(create(:club))
    login(create(:user, :vm, club_id: create(:club).id))

    post "/api/v2/user/games/#{game.id}/set_field", params: { game: { audience: '40' } }

    assert_response :forbidden
    assert_nil game.reload.audience
  end

  # set_string kennt wie set_flag keine Sperre für abgeschlossene Berichte. Für
  # den VM eines beteiligten Vereins war das immer schon so, für den Ausrichter
  # ist es neu. Der Test hält das Verhalten fest, damit eine spätere
  # Vereinheitlichung der Abschluss-Sperre eine bewusste Entscheidung wird und
  # keine stille Nebenwirkung.
  test 'set_field: der VM des Ausrichters darf auch den abgeschlossenen Bericht berichtigen' do
    hosting_club = create(:club)
    game = game_hosted_by(hosting_club)
    game.update!(game_status: 'match_record_closed')
    login(create(:user, :vm, club_id: hosting_club.id))

    post "/api/v2/user/games/#{game.id}/set_field", params: { game: { audience: '40' } }

    assert_response :success
    assert_equal 40, game.reload.audience.to_i
  end

  # --- Sekretariats-Token und Login treffen aufeinander -----------------------
  #
  # An einem Turnierwochenende mit mehreren Hallen arbeitet dieselbe
  # Registerkarte mit Token UND Login (Begründung am Concern). Hier stehen die
  # beiden Fälle für `set_field`; die Auth-Reihenfolge und die additive
  # Rechteprüfung aus #428 prüft `games_secretary_token_login_test.rb`.

  # Ausweitung: Vorher lief diese Person in den Rollenzweig, ihre Rolle passte
  # nicht, und der Token wurde nie befragt.
  test 'set_field: ein passender Token trägt auch eine angemeldete Person ohne passende Rolle' do
    game = game_hosted_by(create(:club))
    _link, token = GameDaySecretaryLink.generate!(game_days: [game.game_day],
                                                  created_by: create(:user, :admin))
    login(create(:user, :vm, club_id: create(:club).id))

    post "/api/v2/user/games/#{game.id}/set_field",
         params: { secretary_token: token, game: { audience: '40' } }

    assert_response :success
    assert_equal 40, game.reload.audience.to_i
  end

  # War die eine Verengung aus #437: can_edit_game? entschied bei gesetztem
  # @secretary_link allein über den Link, ein Token für eine andere Halle nahm
  # der eigenen Rolle also das Spiel weg. Seit #428 zählen Rolle und Token
  # additiv, hier trägt die Rolle.
  test 'set_field: ein Token für einen fremden Spieltag laesst die eigene Rolle unberuehrt' do
    game = game_hosted_by(create(:club))
    fremder_spieltag = GameDay.create!(league: @league, arena: @arena, club: create(:club),
                                       number: 3, date: '2026-01-03')
    _link, token = GameDaySecretaryLink.generate!(game_days: [fremder_spieltag],
                                                  created_by: create(:user, :admin))
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    post "/api/v2/user/games/#{game.id}/set_field",
         params: { secretary_token: token, game: { audience: '40' } }

    assert_response :success
    assert_equal 40, game.reload.audience.to_i
  end

  test 'set_field: die SBK des Spielbetriebs darf weiterhin' do
    game = game_hosted_by(create(:club))
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    post "/api/v2/user/games/#{game.id}/set_field",
         params: { game: { live_stream_link: 'https://example.org/live' } }

    assert_response :success
    assert_equal 'https://example.org/live', game.reload.live_stream_link
  end

  # Eine SBK aus einem fremden Spielbetrieb darf nicht bundesweit eintragen.
  test 'set_field: eine SBK eines fremden Spielbetriebs bleibt draußen' do
    game = game_hosted_by(create(:club))
    login(create(:user, :sbk_scoped, game_operation_id: create(:game_operation).id))

    post "/api/v2/user/games/#{game.id}/set_field", params: { game: { audience: '40' } }

    assert_response :forbidden
    assert_nil game.reload.audience
  end

  # ---------------------------------------------------------------------------
  # Spielstart: Schiedsrichter-1-Pflicht und ihre Begründung
  # ---------------------------------------------------------------------------

  # Der Fall aus Wernigerode am 30.08.2026: Das Gespann war eingetragen, nur in
  # Platz 2. Die alte Meldung nannte allein die Regel, vor einem sichtbar
  # gefüllten Schiri-Feld also scheinbar grundlos -- 23 abgewiesene Startversuche
  # über 88 Minuten. Die Meldung muss den Platz benennen.
  test 'set_flag: nur Schiedsrichter 2 eingetragen -- die Absage benennt den Platz' do
    @game.update!(players: { 'home' => [{ 'id' => 1 }], 'guest' => [{ 'id' => 2 }] },
                  referee1_string: '0 , ', referee2_string: '5824 Trosien, Max')
    login(create(:user, :admin))

    post "/api/v2/user/games/#{@game.id}/set_flag", params: { game: { started: true } }

    assert_response :unprocessable_entity
    message = JSON.parse(response.body)['message']
    assert_includes message, 'nur Schiedsrichter 2'
    assert_includes message, 'Schiedsrichter 1'
    assert_not @game.reload.started
  end

  test 'set_flag: gar kein Schiedsrichter -- die Absage nennt die Regel' do
    @game.update!(players: { 'home' => [{ 'id' => 1 }], 'guest' => [{ 'id' => 2 }] })
    login(create(:user, :admin))

    post "/api/v2/user/games/#{@game.id}/set_flag", params: { game: { started: true } }

    assert_response :unprocessable_entity
    message = JSON.parse(response.body)['message']
    assert_includes message, 'mindestens Schiedsrichter 1'
    assert_not_includes message, 'nur Schiedsrichter 2'
    assert_not @game.reload.started
  end

  test 'set_flag: mit Schiedsrichter 1 startet das Spiel' do
    @game.update!(players: { 'home' => [{ 'id' => 1 }], 'guest' => [{ 'id' => 2 }] },
                  referee1_string: '5605 Schröder, Tobias', referee2_string: '5824 Trosien, Max')
    login(create(:user, :admin))

    post "/api/v2/user/games/#{@game.id}/set_flag", params: { game: { started: true } }

    assert_response :success
    assert @game.reload.started
  end

  # Ohne dieses Flag müsste der Spielbericht den belegten Platz aus `referees`
  # erraten -- und das geht nicht: Auf den leeren Platzhalter "0 , " passt die
  # Regex in Game#referees, er erscheint dort also als vollwertiger Eintrag mit
  # Lizenz "0" und leerem Namen. Ein Blick auf referees[0] oder referees.size
  # meldet damit einen Schiedsrichter, den es nicht gibt.
  test 'das Spiel liefert referee1_present, weil referees den leeren Platz mitfuehrt' do
    @game.update!(referee1_string: '0 , ', referee2_string: '5824 Trosien, Max')
    login(create(:user, :admin))

    get "/api/v2/games/#{@game.id}.json"

    body = JSON.parse(response.body)
    assert_equal false, body['referee1_present']
    assert_equal 2, body['referees'].size, 'der leere Platzhalter zaehlt in referees mit'
    assert_equal '', body['referees'].first['last_name'], 'und steht dort an erster Stelle'
  end

  private

  # Ein Spiel, dessen Ausrichter weder Heim- noch Gastverein ist. Genau diese
  # Konstellation entsteht bei einem Turnier an einem Ort.
  def game_hosted_by(hosting_club)
    game_day = GameDay.create!(league: @league, arena: @arena, club: hosting_club, number: 2, date: '2026-01-02')
    home = create(:team, league: @league, club: create(:club))
    guest = create(:team, league: @league, club: create(:club))
    Game.create!(
      game_day: game_day, home_team: home, guest_team: guest,
      started: false, ended: false, forfait: 0, overtime: false, legacy: false,
      events: [], players: { 'home' => [], 'guest' => [] }
    )
  end

  # Zwei Heimtore, damit der Spielstand etwas hergibt, das sinken könnte.
  #
  # started, weil Game#result bei einem nicht angepfiffenen Spiel nil liefert.
  # period als String, weil der Controller Parameter schreibt und sort_events!
  # über [period, time, id, row] sortiert: Steht in einer Zeile die 1 als Zahl
  # und in der anderen als Zeichenkette, bricht der Vergleich mit ArgumentError.
  def two_goals!
    @game.update!(started: true, events: [
      { 'id' => 1, 'period' => '1', 'time' => '10:00', 'event_type' => 'goal',
        'event_team' => 'home', 'home_goals' => 1, 'guest_goals' => 0, 'home_number' => 7 },
      { 'id' => 2, 'period' => '1', 'time' => '20:00', 'event_type' => 'goal',
        'event_team' => 'home', 'home_goals' => 2, 'guest_goals' => 0, 'home_number' => 9 }
    ])
  end

  # Game#result liefert einen Hash; für die Lesbarkeit der Fälle oben auf
  # "heim:gast" heruntergebrochen.
  def score
    result = @game.reload.result
    "#{result[:home_goals]}:#{result[:guest_goals]}"
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
