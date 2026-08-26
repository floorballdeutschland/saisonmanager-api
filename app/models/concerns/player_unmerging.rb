# Umkehrung eines Merges zweier Spielerprofile: das Gegenstueck zu `Player#merge_into!`.
#
# Eigenes Concern, weil `Player` sonst ueber die Zeilengrenze laeuft und weil das Trennen
# eine geschlossene Aufgabe ist: Es liest denselben Bestand, den der Merge geschrieben hat,
# und muss jede seiner Nebenwirkungen einzeln kennen.
#
# Die Merge-Konstanten liegen hier, nicht in `Player`: `merge_into!` findet sie ueber die
# Ahnenkette. Umgekehrt geht es nicht, deshalb sind `Player::DEACTIVATION_CLOSE_WINDOW` und
# `Player::VALID_BEFORE_DEACTIVATION` unten ausgeschrieben.
module PlayerUnmerging
  extend ActiveSupport::Concern

  # Grund, den `merge_into!` an Deaktivierung und Lizenzverlauf schreibt. Bewusst NICHT in
  # DEACTIVATION_REASONS: `reactivate!` soll die Lizenzeintraege eines Merges gerade nicht
  # poppen, dafuer gibt es `unmerge_from!`.
  MERGE_REASON = 'Zusammenführung'.freeze

  # Zeitfenster, in dem eine am MASTER geschlossene Zugehoerigkeit als "vom Merge
  # geschlossen" gilt. Bewusst asymmetrisch und weit: `_close_surplus_home_clubs` schreibt
  # am ANFANG des Merges, `deactivate!` an der Dublette am ENDE, und dazwischen liegt das
  # Umschreiben jeder einzelnen Spielaufstellung. Der Abstand waechst also mit der Anzahl
  # der Spiele. Nach hinten reicht das enge Fenster, dort steht nur die Serialisierung.
  #
  # Fuer die Dublette selbst gilt weiter Player::DEACTIVATION_CLOSE_WINDOW: dort muss die Erkennung
  # genau die von `reactivate!` sein, sonst meldet die Nachbedingung Fehlalarm.
  MERGE_CLOSE_WINDOW = 30.minutes

  # Felder, die `merge_into!` von der Dublette auf einen leeren Master uebertraegt. Beim
  # Trennen sind sie nicht zurueckzurechnen (ob der Master sie vorher leer hatte, steht
  # nirgends), deshalb werden sie nur gemeldet.
  MERGE_COPIED_FIELDS = %w[first_name last_name birthdate gender nation_id email].freeze

  # Verweigerung einer Trennung wegen nicht erfuellter Vorbedingung. Eigene Klasse, damit
  # der Wartungslauf sie von einem echten Fehler unterscheiden kann: `ArgumentError` wirft
  # in diesem Modell auch das Parsen unlesbarer Altdaten.
  class UnmergeRefused < StandardError; end

  # Kehrt einen Merge um. Gegenstueck zu `merge_into!`, gedacht fuer Fehl-Merges: zwei
  # verschiedene Personen, die die Dubletten-Heuristik ueber ein um eine Ziffer abweichendes
  # Geburtsdatum zusammengezogen hat. `_shares_game_with?` kann die nicht erkennen, wenn
  # beide in verschiedenen Ligen spielen, denn verschiedene Ligen heissen nie dasselbe Spiel.
  #
  # Zurueck gehen:
  #   - die Spielaufstellungen, die `_rewrite_player_game_references` umgeschrieben hat.
  #     Zugeordnet wird ueber das Team der jeweiligen Spielseite: gehoert es zu einer Lizenz
  #     dieses Profils, war der Eintrag dieses Profils.
  #   - die auf den Master kopierten Lizenzen (ueber die Lizenz-UUID) und Zugehoerigkeiten
  #     (ueber club_id und created_at, die das deep_dup unveraendert laesst)
  #   - Lizenzdokumente, die an einer dieser Lizenzen haengen
  #   - Deaktivierung, `merged_into_id` und die vom Merge geschlossene Zugehoerigkeit
  #
  # Nicht automatisch zurueck, sondern gemeldet:
  #   - Transfers, Korrekturantraege, Sperren, Transferantraege. `_repoint_player_associations`
  #     hat sie per `update_all` verschoben, ohne Spur, welche Zeile von welchem Profil kam.
  #   - Felder, die der Merge von hier auf einen leeren Master uebertragen hat (Name,
  #     Geburtsdatum, Geschlecht, Nation, E-Mail, security_id).
  #
  # Der MergeLog-Eintrag bleibt stehen: er protokolliert, was passiert ist.
  #
  # Die wieder geoeffneten Lizenzen stehen danach auf ihrem Stand VOR dem Merge, also unter
  # Umstaenden APPROVED in einer abgelaufenen Saison. Den Saisonwechsel traegt
  # `rake seasons:invalidate_stale_licenses` nach.
  #
  # Rueckgabe: Hash mit den Anzahlen und `:manual`.
  def unmerge_from!(user_id)
    refuse_unmerge 'Profil ist nicht zusammengeführt' if merged_into_id.blank?

    master = Player.find_by(id: merged_into_id)
    refuse_unmerge "Master ##{merged_into_id} nicht gefunden" if master.nil?
    refuse_unmerge "Master ##{master.id} ist selbst zusammengeführt" if master.merged_into_id.present?

    unless deactivation_reason == MERGE_REASON
      refuse_unmerge "Deaktivierungsgrund ist #{deactivation_reason.inspect}, " \
                     "erwartet #{MERGE_REASON.inspect}"
    end

    bilanz = { games: 0, games_manual: 0, licenses: 0, licenses_self: 0, clubs: 0,
               clubs_manual: [], reopened: 0, reopened_manual: [], reopened_self: 0,
               documents: 0, documents_manual: [], fields: [], manual: {} }

    ActiveRecord::Base.transaction do
      # Sperren, bevor gelesen wird: beide JSONB-Arrays werden als Ganzes zurueckgeschrieben.
      # Eine gleichzeitige Lizenzerteilung am Master waere sonst still ueberschrieben, ohne
      # Konflikt und ohne Log. `suspend!` sperrt aus demselben Grund.
      lock!
      master.lock!

      own_license_ids = Array(licenses).filter_map { |l| l['id'] if l.is_a?(Hash) }
      if own_license_ids.size != Array(licenses).size
        refuse_unmerge 'Dublette hat Lizenzen ohne id; die Kopien am Master sind nicht zuordenbar'
      end

      master_own     = Array(master.licenses).reject { |l| l.is_a?(Hash) && own_license_ids.include?(l['id']) }
      eigene_teams   = _license_team_ids(licenses)
      master_teams   = _license_team_ids(master_own)
      geteilte_teams = eigene_teams & master_teams
      if geteilte_teams.any?
        refuse_unmerge "Beide Profile haben Lizenzen in denselben Teams " \
                       "(#{geteilte_teams.to_a.sort.join(', ')}); die Spielaufstellungen sind " \
                       'dann nicht eindeutig zuordenbar'
      end
      # Ohne lizenziertes Team ist die Pruefung oben leer und damit wertlos, und die
      # Rueckschreibung faende nichts. Beides zusammen sieht wie ein Erfolg aus.
      if eigene_teams.empty? && Game.referencing_player(master.id).exists?
        refuse_unmerge 'Dublette hat keine Lizenz mit team_id, der Master hat aber ' \
                       'Spielreferenzen; die Aufstellungen sind nicht zuordenbar'
      end

      stamp_at = deactivated_at
      stamp_by = deactivated_by
      offen_vorher = _merge_closed_membership_club_ids(stamp_at, stamp_by)

      bilanz[:games], bilanz[:games_manual] =
        _restore_player_game_references(master.id, eigene_teams, master_teams)

      bilanz[:licenses] = Array(master.licenses).size - master_own.size
      master.licenses   = master_own
      bilanz[:clubs], bilanz[:clubs_manual] = _remove_merged_clubs_from(master)
      bilanz[:reopened], bilanz[:reopened_manual] = _reopen_master_memberships_closed_by_merge(master)
      master.updated_by = user_id
      master.save!(validate: false)

      bilanz[:documents], bilanz[:documents_manual] = _restore_license_documents(master, own_license_ids)
      bilanz[:manual] = _associations_needing_review(master)
      bilanz[:fields] = _fields_possibly_copied_to(master)

      bilanz[:licenses_self] = _pop_merge_license_entries!
      self.merged_into_id = nil
      # reactivate! raeumt nur deactivated_at/_by ab, den Grund laesst es stehen (bei einer
      # regulaeren Reaktivierung gehoert er zur Historie). Hier muss er weg: der Merge, auf
      # den er sich beruft, gilt nicht mehr.
      self.deactivation_reason = nil
      self.updated_by = user_id
      # reactivate! oeffnet die vom Merge geschlossene Zugehoerigkeit der Dublette. Die
      # Lizenzeintraege des Merges popt es nicht, das ist eine Zeile darueber passiert.
      reactivate!

      offen_nachher = _merge_closed_membership_club_ids(stamp_at, stamp_by)
      bilanz[:reopened_self] = offen_vorher.size - offen_nachher.size
      if offen_nachher.any?
        # Genau der Fall, der sonst als Erfolg durchgeht: das Profil steht wieder da, ist
        # aber in keiner Vereinsliste, nicht lizenzierbar und nicht transferierbar.
        refuse_unmerge "Dublette ##{id}: vom Merge geschlossene Zugehoerigkeit(en) bei Verein " \
                       "#{offen_nachher.uniq.join(', ')} sind nicht wieder aufgegangen " \
                       "(Erkennungsfenster von reactivate! verpasst)"
      end
      # Auch hier die strenge Definition: ein heute geschlossener Eintrag gilt
      # `open_home_club_entries` bis Mitternacht als laufend, und eine Nachbedingung, die
      # verweigert, darf daran nicht falsch anschlagen.
      unbefristet_offen = Array(master.clubs).count do |c|
        c.is_a?(Hash) && ActiveModel::Type::Boolean.new.cast(c['home_club']) &&
          c['valid_until'].blank?
      end
      if unbefristet_offen > 1
        refuse_unmerge "Master ##{master.id} haette nach der Trennung #{unbefristet_offen} " \
                       'offene Heimatvereine; die Leser widersprechen sich dann'
      end
    end

    bilanz
  end

  def refuse_unmerge(nachricht)
    raise UnmergeRefused, nachricht
  end

  private

  # Kehrt `_rewrite_player_game_references` um: schreibt master_id dort auf dieses Profil
  # zurueck, wo die Spielseite zu einem Team einer Lizenz dieses Profils gehoert.
  #
  # Die Seitenbedingung ist Pflicht, sonst traefe es auch die eigenen Aufstellungen des
  # Masters. Sie ist aber auch die Schwachstelle: Der Merge hat JEDE Referenz umgeschrieben,
  # unabhaengig vom Team. Eine Aufstellung fuer ein Team, in dem die Dublette keine Lizenz
  # (mehr) hat, findet der Rueckweg nicht. Deshalb wird alles gezaehlt, was zu KEINEM der
  # beiden Profile gehoert -- dort ist die Herkunft offen und der Aufrufer muss es sehen.
  #
  # Rueckgabe: [Anzahl geaenderter Spiele, Anzahl nicht zuordenbarer Referenzen]
  def _restore_player_game_references(master_id, eigene_teams, master_teams)
    return [0, 0] if eigene_teams.empty?

    geaendert_gesamt = 0
    unzuordenbar = 0

    Game.referencing_player(master_id).find_each do |game|
      changed = false

      %w[home guest].each do |side|
        seiten_team = side == 'home' ? game.home_team_id : game.guest_team_id

        unless eigene_teams.include?(seiten_team)
          next if master_teams.include?(seiten_team)

          unzuordenbar += _references_on_side(game, side, master_id)
          next
        end

        lineup = game.players.is_a?(Hash) ? game.players[side] : nil
        Array(lineup).each do |p|
          next unless p.is_a?(Hash) && p['player_id'] == master_id

          p['player_id'] = id
          changed = true
        end

        changed = _restore_position_map_side(game.starting_players, side, master_id) || changed
        changed = _restore_position_map_side(game.awards, side, master_id) || changed
      end

      next unless changed

      game.save!(validate: false)
      geaendert_gesamt += 1
    end

    [geaendert_gesamt, unzuordenbar]
  end

  # Zaehlt die Referenzen auf player_id auf einer Spielseite, ueber Aufstellung,
  # starting_players und awards.
  def _references_on_side(game, side, player_id)
    lineup = game.players.is_a?(Hash) ? game.players[side] : nil
    treffer = Array(lineup).count { |p| p.is_a?(Hash) && p['player_id'] == player_id }

    [game.starting_players, game.awards].each do |container|
      next unless container.is_a?(Hash)

      entry = container[side]
      treffer += if entry.is_a?(Hash)
                   entry.count { |_key, value| value == player_id }
                 elsif entry.is_a?(Array)
                   entry.count { |e| e.is_a?(Hash) && e['player_id'] == player_id }
                 else
                   0
                 end
    end
    treffer
  end

  # Wie `_rewrite_position_map`, aber nur fuer eine Spielseite und in die andere Richtung.
  def _restore_position_map_side(container, side, master_id)
    return false unless container.is_a?(Hash)

    entry = container[side]
    return false if entry.blank?

    changed = false
    if entry.is_a?(Hash)
      entry.each do |key, value|
        next unless value == master_id

        entry[key] = id
        changed = true
      end
    elsif entry.is_a?(Array)
      entry.each do |e|
        next unless e.is_a?(Hash) && e['player_id'] == master_id

        e['player_id'] = id
        changed = true
      end
    end
    changed
  end

  def _license_team_ids(lics)
    Array(lics).filter_map { |l| l['team_id'].to_i if l.is_a?(Hash) && l['team_id'].present? }.to_set
  end

  def _license_club_ids(lics)
    ids = _license_team_ids(lics)
    return Set.new if ids.empty?

    Team.where(id: ids.to_a).pluck(:club_id).compact.to_set
  end

  # Liest ein Datum aus dem clubs-JSONB und prueft es gegen ein Zeitfenster. Eigene Methode
  # wegen des Altbestands: "0000-00-00" wirft beim Parsen, "unbekannt" ergibt nil. Beides
  # darf den Lauf nicht mit einer Meldung abbrechen, die wie eine Verweigerung aussieht.
  def _within_window?(valid_until, anchor, vor, nach)
    moment = valid_until.is_a?(Time) ? valid_until : Time.zone.parse(valid_until.to_s)
    return false if moment.nil?

    moment.between?(anchor - vor, anchor + nach)
  rescue ArgumentError, TypeError
    false
  end

  # Vereins-IDs der Zugehoerigkeiten DIESES Profils, die der Merge geschlossen hat.
  # Erkennung genau wie in `membership_closed_by_deactivation?`, aber mit uebergebenen
  # Stempeln: nach `reactivate!` sind deactivated_at/_by weg, und die Nachbedingung muss
  # danach noch messen koennen.
  def _merge_closed_membership_club_ids(stamp_at, stamp_by)
    return [] if stamp_at.blank? || stamp_by.blank?

    Array(clubs).filter_map do |c|
      next unless c.is_a?(Hash) && c['valid_until'].present?
      next unless c['valid_set_by'].present? && c['valid_set_by'] == stamp_by
      next unless _within_window?(c['valid_until'], stamp_at,
                                  Player::DEACTIVATION_CLOSE_WINDOW, Player::DEACTIVATION_CLOSE_WINDOW)

      c['club_id']
    end
  end

  # Entfernt die Zugehoerigkeiten, die der Merge von hier auf den Master kopiert hat.
  #
  # Schluessel ist club_id + created_at, denn `_merge_clubs` kopiert per deep_dup und laesst
  # beide Werte unveraendert. Geloescht wird aber nur mit POSITIVEM Beleg, dass der Eintrag
  # eine Kopie ist und nicht der eigene des Masters. Grund: `_merge_clubs` VERWIRFT eine
  # offene Zugehoerigkeit der Dublette, wenn der Master denselben Verein offen hat -- dann
  # existiert gar keine Kopie, und der gleichnamige Eintrag am Master ist SEIN eigener. Ihn
  # zu loeschen waere genau der Schaden, den dieser Lauf reparieren soll: ein echter Mensch
  # ohne Verein, aus der Vereinsliste gefallen und nicht transferierbar.
  #
  # Als Beleg zaehlt: der Master traegt denselben Verein mehrfach (dann bleibt sein eigener
  # stehen), oder er hat in diesem Verein ueberhaupt keine Lizenz (dann kann die
  # Zugehoerigkeit nicht seine sein). Fehlt der Beleg, wird gemeldet statt geloescht. Ebenso
  # bei fehlendem created_at (Altbestand, belegt an Moritz Winter 12635/8282) und bei einem
  # Eintrag, der kein Hash ist (kommt im Altbestand vor, siehe
  # `membership_closed_by_deactivation?`).
  #
  # Ablage-Zugehoerigkeiten der Dublette kopiert `_merge_clubs` nicht mehr. Bei einem Merge
  # ab dieser Aenderung findet sich am Master also gar kein Treffer, und die Ablage wird zur
  # Handpruefung gemeldet statt entfernt. Das ist richtig so: Bei Merges davor IST sie
  # kopiert worden und muss weg, und beide Faelle sind hier nicht unterscheidbar.
  #
  # Rueckgabe: [Anzahl entfernt, Vereins-IDs zur Handpruefung]
  def _remove_merged_clubs_from(master)
    bestand = Array(master.clubs)
    master_lizenz_vereine = _license_club_ids(master.licenses)
    zu_entfernen = []
    ambivalent = []

    Array(clubs).each do |c|
      unless c.is_a?(Hash)
        ambivalent << 'Eintrag ohne Struktur'
        next
      end

      if c['created_at'].blank?
        ambivalent << c['club_id']
        next
      end

      treffer = bestand.each_index.reject { |i| zu_entfernen.include?(i) }.select do |i|
        mc = bestand[i]
        mc.is_a?(Hash) && mc['club_id'] == c['club_id'] &&
          mc['created_at'].to_s == c['created_at'].to_s
      end
      if treffer.size != 1
        ambivalent << c['club_id']
        next
      end

      mehrfach = bestand.count { |mc| mc.is_a?(Hash) && mc['club_id'] == c['club_id'] } > 1
      unless mehrfach || master_lizenz_vereine.exclude?(c['club_id'])
        ambivalent << c['club_id']
        next
      end

      zu_entfernen << treffer.first
    end

    master.clubs = bestand.reject.with_index { |_, i| zu_entfernen.include?(i) }
    [zu_entfernen.size, ambivalent.uniq]
  end

  # Oeffnet die Zugehoerigkeiten, die der Merge am MASTER geschlossen hat. Seit api#481
  # raeumt `_merge_clubs` ueberzaehlige offene Heimatvereine per `_close_surplus_home_clubs`
  # ab, und das trifft je nach created_at auch den eigenen Eintrag des Masters. Merges vor
  # api#481 (u.a. der Dubletten-Lauf vom 08.07.2026) haben das nicht getan, dort ist der
  # Aufruf ein No-op.
  #
  # Zwei Riegel, beide aus `memberships_reopenable` uebernommen bzw. dort begruendet:
  #
  #   1. Ein Heimatverein geht nur auf, solange keiner offen ist. Sonst widersprechen sich
  #      `Player#home_club` (letzter Treffer) und `Admin::TransferRequestsController`
  #      (`former_club_id`, erster Treffer), und ein Transferantrag ginge an den falschen
  #      abgebenden Verein.
  #   2. Ohne gesicherte Befristung wird ein NICHT-Heimatverein nicht angefasst.
  #      `_close_surplus_home_clubs` sichert nichts, und `open_home_club_entries` wertet auch
  #      ein Enddatum in der Zukunft als laufend -- ein befristetes Zweitspielrecht wuerde
  #      beim Oeffnen unbefristet. Beim Heimatverein ist unbefristet der Normalfall, dort
  #      wird geoeffnet.
  #
  # Rueckgabe: [Anzahl geoeffnet, Vereins-IDs zur Handpruefung]
  def _reopen_master_memberships_closed_by_merge(master)
    return [0, []] if deactivated_at.blank? || deactivated_by.blank?

    geoeffnet = 0
    ambivalent = []

    Array(master.clubs).each do |c|
      next unless c.is_a?(Hash) && c['valid_until'].present?
      next unless c['valid_set_by'].present? && c['valid_set_by'] == deactivated_by
      next unless _within_window?(c['valid_until'], deactivated_at,
                                  MERGE_CLOSE_WINDOW, Player::DEACTIVATION_CLOSE_WINDOW)

      gesichert = c[Player::VALID_BEFORE_DEACTIVATION]
      if gesichert.is_a?(Hash) && gesichert['valid_until'].present?
        c.delete(Player::VALID_BEFORE_DEACTIVATION)
        c['valid_until']  = gesichert['valid_until']
        c['valid_set_by'] = gesichert['valid_set_by']
        c.delete('valid_set_by') if gesichert['valid_set_by'].blank?
        geoeffnet += 1
        next
      end

      heimat = ActiveModel::Type::Boolean.new.cast(c['home_club'])
      if !heimat || _other_home_club_open?(master, c)
        ambivalent << c['club_id']
        next
      end

      c.delete('valid_until')
      c.delete('valid_set_by')
      geoeffnet += 1
    end

    [geoeffnet, ambivalent.uniq]
  end

  # Ist bei diesem Profil ein ANDERER Heimatverein unbefristet offen?
  #
  # Bewusst `valid_until.blank?` und nicht `open_home_club_entries`, obwohl das die eine
  # Definition von "offen" ist: Jene wertet ein Enddatum von HEUTE bis Mitternacht als
  # laufend, und der Eintrag, den dieser Lauf gerade oeffnen will, traegt genau so eines
  # (der Merge hat es gesetzt). Der Riegel haette sich damit selbst blockiert. Die
  # Schwestermethode `memberships_reopenable` prueft aus demselben Grund auf blank?.
  #
  # `equal?` statt `==`: verglichen wird die Objektidentitaet, nicht der Inhalt. Zwei
  # Zugehoerigkeiten koennen wertgleich sein.
  def _other_home_club_open?(master, eintrag)
    Array(master.clubs).any? do |c|
      next false if c.equal?(eintrag)
      next false unless c.is_a?(Hash)

      ActiveModel::Type::Boolean.new.cast(c['home_club']) && c['valid_until'].blank?
    end
  end

  # Popt die DELETED-Eintraege, die `_void_memberships_and_licenses!` beim Merge an jede
  # damals laufende Lizenz gehaengt hat. Bewusst eng: nur der oberste Eintrag, nur DELETED,
  # nur mit dem Merge-Grund und derselben verfuegenden Person wie die Deaktivierung.
  #
  # Steht der Merge-Eintrag NICHT oben, hat danach etwas anderes geschrieben (Saisonwechsel,
  # eine SBK-Entscheidung). Ihn aus der Mitte zu entfernen wuerde den Verlauf verfaelschen,
  # ihn stehen zu lassen die Lizenz ungueltig -- beides darf nicht still passieren, also
  # wird verweigert.
  #
  # Rueckgabe: Anzahl zurueckgenommener Eintraege
  def _pop_merge_license_entries!
    self.licenses ||= []
    gepoppt = 0

    licenses.each do |license|
      verlauf = Array(license['history'])
      index = verlauf.rindex do |h|
        h.is_a?(Hash) && h['license_status_id'].to_i == License::DELETED &&
          h['reason'] == MERGE_REASON && h['created_by'] == deactivated_by
      end
      next if index.nil?

      unless index == verlauf.size - 1
        refuse_unmerge "Lizenz #{license['id']}: der Zusammenfuehrungs-Eintrag ist nicht der " \
                       'oberste im Verlauf, danach wurde weitergeschrieben'
      end

      license['history'].pop
      gepoppt += 1
    end

    gepoppt
  end

  # Holt die Lizenzdokumente zurueck, die an einer Lizenz dieses Profils haengen.
  #
  # Zeilenweise statt per update_all: `license_documents` hat einen partiellen Unique-Index
  # auf (player_id, license_id, document_type), der nur fuer aktive (nicht archivierte)
  # Zeilen gilt, und `_repoint_license_documents` laesst beim
  # Merge ein kollidierendes Dokument bewusst an der Dublette stehen -- genau der Zustand,
  # in dem ein pauschales update_all mit RecordNotUnique abbricht.
  #
  # Ein Dokument ohne license_id ist nicht zuordenbar (der Controller schreibt NULL, und das
  # Modell nennt license_id fachlich nur informativ). Es wird gemeldet, nicht verschoben.
  #
  # Rueckgabe: [Anzahl zurueckgeholt, Dokument-IDs zur Handpruefung]
  def _restore_license_documents(master, own_license_ids)
    zurueck = 0
    verbleibend = []

    LicenseDocument.where(player_id: master.id).find_each do |doc|
      if doc.license_id.blank?
        verbleibend << doc.id
        next
      end
      next unless own_license_ids.include?(doc.license_id)

      # Nur aktive Zeilen kollidieren (partieller Eindeutigkeits-Index).
      if doc.archived_at.nil? &&
         LicenseDocument.active.exists?(player_id: id, license_id: doc.license_id,
                                        document_type: doc.document_type)
        verbleibend << doc.id
        next
      end

      doc.update_columns(player_id: id)
      zurueck += 1
    end

    [zurueck, verbleibend]
  end

  # Felder, die der Merge von hier auf einen leeren Master uebertragen haben KANN. Ob er es
  # getan hat, steht nirgends -- gemeldet wird deshalb jedes Feld, dessen Wert am Master mit
  # dem hiesigen uebereinstimmt. Bei einem Fehl-Merge sind Name und Geschlecht typischerweise
  # gleich und das Geburtsdatum nicht; `security_id` ist ein Identitaetsschluessel und
  # gehoert in jedem Fall geprueft.
  def _fields_possibly_copied_to(master)
    felder = MERGE_COPIED_FIELDS.select do |f|
      self[f].present? && master[f].to_s == self[f].to_s
    end
    felder << 'security_id' if security_id.present? && master.security_id == security_id
    felder
  end

  # Assoziationen, die `_repoint_player_associations` per update_all auf den Master
  # verschoben hat. Welche Zeile von welchem Profil kam, steht nirgends, darum werden sie
  # nur gemeldet und nicht angefasst.
  def _associations_needing_review(master)
    {
      'transfer' => Transfer.where(player_id: master.id).pluck(:id),
      'player_change_request' => PlayerChangeRequest.where(player_id: master.id).pluck(:id),
      'player_suspension' => PlayerSuspension.where(player_id: master.id).pluck(:id),
      'transfer_request' => TransferRequest.where(player_id: master.id).pluck(:id)
    }.reject { |_typ, ids| ids.empty? }
  end
end
