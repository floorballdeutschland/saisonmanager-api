module Admin
  class LicensesController < ApplicationController
    include LicenseDocumentPresentation

    # Diese Liste zeigt mehr als die Kaderlisten einer Liga: Sie ist die
    # Arbeitsliste des Verbandes über alle Ligen einer Saison und bietet einen
    # Statusfilter „abgelehnt"/„zurückgezogen" sowie den Knopf „Ablehnung
    # widerrufen" an. Beides lief ins Leere, solange League#build_license_items
    # auch hier nur erteilte und beantragte Lizenzen lieferte -- ein
    # zurückgenommener Antrag war danach nur noch über die Lizenzliste der
    # Mannschaft erreichbar, die der Verband nicht im Menü hat.
    #
    # Die Kaderlisten bleiben bei der Vorgabe: Dort ist ein abgelehnter Antrag
    # kein Teil der Mannschaft.
    LISTED_STATUSES = [License::APPROVED, License::REQUESTED, License::DENIED, License::WITHDRAWN].freeze

    def index
      ph = current_user.permission_hash
      unless ph[:admin].present? || ph[:sbk].present?
        return render json: { message: 'Keine Berechtigung!' }, status: :forbidden
      end

      season_id = params[:season_id].presence || Setting.current_season_id

      # All leagues for this season – needed for correct primary/secondary computation across all of a player's licenses
      all_season_leagues = League.where(season_id: season_id).index_by(&:id)
      # team_id → league_id map for primary/secondary sorting
      team_league_id_map = Team.where(league_id: all_season_leagues.keys).pluck(:id, :league_id).to_h

      # Filtered scope for the result set
      leagues = League.where(id: all_season_leagues.keys)
      leagues = leagues.where(game_operation_id: params[:game_operation_id].to_i) if params[:game_operation_id].present?
      unless ph[:admin].present?
        go_ids = ph[:sbk].include?(0) ? nil : ph[:sbk]
        leagues = leagues.where(game_operation_id: go_ids) if go_ids
      end

      leagues         = leagues.to_a
      game_operations = GameOperation.where(id: leagues.map(&:game_operation_id).uniq).index_by(&:id)
      # Wie League.license_teams_by_league auch die Mannschaften, die nur über
      # cup_leagues zur Liga gehören (Pokal/Endrunde). Ohne die Vereinigung blieb
      # deren Verein in der Lizenzübersicht leer: Die Zeilen kommen aus
      # League.licenses_for, das die Vereinigung kennt, der Verein aber aus dieser
      # Zuordnung, die nur league_id kannte. Betroffen war genau die Sicht der
      # Pokal-SBK, für die die Hauptliga der Mannschaft nicht in `leagues` steckt.
      league_ids      = leagues.map(&:id)
      team_club_map   = if league_ids.any?
                          Team.where(league_id: league_ids)
                              .or(Team.where('cup_leagues && ARRAY[?]::int[]', league_ids))
                              .pluck(:id, :club_id).to_h
                        else
                          {}
                        end
      clubs           = Club.where(id: team_club_map.values.uniq).index_by(&:id)

      # Die Lizenzlisten aller Ligen in einem Rutsch und genau einmal. Bisher lief
      # league.licenses zweimal – erst zum Sammeln der Spieler-IDs für die
      # Dokumente, dann erneut zum Bauen der Antwort – und beide Male Liga für
      # Liga, also je Liga eine eigene Spieler-Abfrage über die players-Tabelle.
      # Diese Liste liest weder Logos noch other_licenses noch das Freigabedatum,
      # daher :light und beide Schalter aus. with_release_dates: false spart eine
      # Abfrage ueber die Spieler ALLER Ligen der Saison.
      #
      # only_current_licenses: false, obwohl die Liste je Zeile nur eine Lizenz
      # zeigt: Der Schalter schneidet in Player#full_hash an
      # `Setting.current_min_team` ab, also an den Mannschafts-IDs der
      # LAUFENDEN Saison. Fragt die Uebersicht eine fruehere Saison ab, liegen
      # deren Lizenzen samt der abgefragten darunter, und license_type saehe
      # keine einzige -- jede Zeile der Vorsaison trueg dann dasselbe Etikett.
      # Teuer ist der Verzicht nicht: Der Titel-Block in full_hash (eine Abfrage
      # je Lizenz und History-Eintrag) haengt am dritten Schalter, den dieser
      # Weg nicht setzt, und license_type grenzt ueber team_league_id_map
      # ohnehin auf die abgefragte Saison ein.
      licenses_by_league = League.licenses_for(leagues, team_hash: :light, with_other_licenses: false,
                                               with_release_dates: false, statuses: LISTED_STATUSES,
                                               only_current_licenses: false)

      # Pre-load all license documents for players in these leagues (grouped by
      # [player_id, doc_type] – Dokumente gelten pro Spieler, saisonübergreifend)
      all_player_ids = licenses_by_league.each_value.flat_map do |team_items|
        team_items.flat_map { |t| t[:players].map { |p| p[:id] } }
      end.uniq
      license_docs_by_key = license_documents_by_player_and_type(all_player_ids)
      catalog = document_type_catalog(leagues.flat_map { |l| league_required_document_keys(l) } + ['parental_consent'])

      result = []
      leagues.each do |league|
        game_op       = game_operations[league.game_operation_id]
        category_name = license_category_name(league.league_category_id)
        class_name    = license_class_name(league.league_class_id)
        league_keys   = league_required_document_keys(league)

        licenses_by_league.fetch(league.id, []).each do |team_data|
          club = clubs[team_club_map[team_data[:id]]]

          team_data[:players].each do |player_data|
            lic = player_data[:team_license][:license]
            unless lic
              Rails.logger.error("Admin::LicensesController: nil license for player #{player_data[:id]} in team #{team_data[:id]}")
              next
            end
            last_status_id = player_data[:team_license][:last_status_id].to_i
            # Altersabhängige Dokumentarten: Stichtag ist das Datum der Lizenzbeantragung.
            required_keys = DocumentType.required_keys(
              league_keys,
              birthdate: player_data[:birthdate],
              requested_at: player_data[:team_license][:requested_at]&.to_time,
              catalog: catalog
            )

            counts = season_license_counts(player_data, season_id, team_league_id_map)
            # Tripwire: Die Lizenz, die diese Zeile erzeugt hat, MUSS in der
            # Zaehlmenge stecken. Faellt sie heraus, zeigt die Zeile eine Zahl,
            # die ihre eigene Lizenz nicht kennt -- und die Zahl wird gegen eine
            # Obergrenze gelesen. Genau so ist die fehlende Saisonangabe des
            # Altbestands aufgefallen.
            if lic['id'].present? && counts[:ids].exclude?(lic['id'])
              Rails.logger.error("Admin::LicensesController: Lizenz #{lic['id']} (Spieler #{player_data[:id]}, " \
                                 "Mannschaft #{team_data[:id]}) erzeugt eine Zeile, zaehlt aber nicht zur Saison #{season_id}")
            end

            result << {
              player_id:            player_data[:id],
              player_last_name:     player_data[:last_name],
              player_first_name:    player_data[:first_name],
              player_birthdate:     player_data[:birthdate],
              player_gender:        player_data[:gender],
              club_id:              club&.id,
              club_name:            club&.name,
              team_id:              team_data[:id],
              team_name:            team_data[:name],
              league_id:            league.id,
              league_name:          league.name,
              field_size:           league.field_size,
              female:               league.female,
              age_group:            league.age_group,
              league_category_id:   league.league_category_id,
              league_category_name: category_name,
              league_class_id:      league.league_class_id,
              league_class_name:    class_name,
              league_type:          league.league_type,
              league_modus:         league.league_modus,
              game_operation_id:    game_op&.id,
              game_operation_name:  game_op&.name,
              season_id:            league.season_id,
              license_id:           lic['id'],
              license_type:         license_type(player_data, lic, all_season_leagues, team_league_id_map),
              # Wie viele Lizenzen dieser Spieler in der abgefragten Saison
              # schon erteilt bekommen hat und wie viele davon noch offen
              # beantragt sind -- verbandsuebergreifend, siehe
              # season_license_counts.
              licenses_approved_season:  counts[:approved],
              licenses_requested_season: counts[:requested],
              # Manuelle Erst-/Zweitlizenz-Zuordnung im GF-Erwachsenenbereich
              # ('erstlizenz' | 'zweitlizenz' | nil = nicht zugeordnet).
              gf_role:              lic['gf_role'],
              license_status_id:    last_status_id,
              license_status:       License::NAMES[last_status_id],
              # Der Status ohne Sperre und die Sperre selbst (#605). Bis dahin
              # verschwand eine gesperrte Lizenz ganz aus dieser Uebersicht,
              # statt ihren Status zu zeigen.
              base_status_id:       player_data[:team_license][:base_status_id].to_i,
              base_status:          License::NAMES[player_data[:team_license][:base_status_id].to_i],
              suspension:           player_data[:team_license][:suspension],
              express:              lic['express'] || false,
              # Antrag nach Transfer und Freigabe zurueck auf dieselbe
              # Mannschaft: derselbe Eintrag, keine neue Gebuehr.
              reactivation:         License.reactivation?(lic),
              requested_at:         player_data[:team_license][:requested_at],
              approved_at:          player_data[:team_license][:approved_at],
              # Datum der Vereins-Freigabe (genehmigter Freigabe-Antrag), leer
              # bei Spielern, die keine brauchten.
              released_at:          player_data[:team_license][:released_at],
              required_documents:   required_keys,
              valid_until:          lic['valid_until'],
              documents:            document_map_for(player_data[:id], league.season_id, license_docs_by_key, required_keys, catalog)
            }
          end
        end
      end

      render json: result
    end

    private

    # Wie viele Lizenzen ein Spieler in dieser Saison hat: erteilte und noch
    # offene Antraege, getrennt gezaehlt. Landesverbaende genehmigen je Spieler
    # nur eine begrenzte Zahl von Lizenzen (sechs oder acht, je nach Verband);
    # die Zahl erspart das Durchzaehlen der Zeilen.
    #
    # Bewusst ueber ALLE Verbaende, nicht nur ueber die Ligen, die der
    # Betrachter in dieser Liste sieht: Eine Lizenz aus einem anderen Verband
    # zaehlt auf dieselbe Obergrenze ein. Die Zahl kostet nichts extra, weil
    # `player_data[:licenses]` hier ohnehin ungefiltert geladen ist
    # (`only_current_licenses: false`, siehe oben).
    #
    # Gezaehlt wird die abgefragte Saison, nicht die laufende: Die Uebersicht
    # laesst sich auf eine fruehere Saison stellen, und dort waere die Zahl der
    # laufenden Saison eine Aussage ueber etwas ganz anderes.
    #
    # Je Spieler einmal gerechnet, weil ein Spieler mit mehreren Lizenzen
    # mehrere Zeilen hat.
    def season_license_counts(player_data, season_id, team_league_id_map)
      @season_license_counts ||= {}
      # Die Saison gehoert in den Schluessel, auch wenn eine Anfrage heute nur
      # eine einzige abfragt: Der Wert haengt an ihr, der Schluessel muss das
      # aushalten, falls der Endpunkt je mehrere Saisons in einer Antwort
      # ausliefert.
      @season_license_counts[[player_data[:id], season_id.to_s]] ||= begin
        season_licenses = Array(player_data[:licenses]).select do |lic|
          lic.is_a?(Hash) && license_in_season?(lic, season_id, team_league_id_map)
        end

        approved = season_licenses.count { |lic| ever_approved?(lic) }
        # Nur die noch nicht erteilten: Eine Lizenz zaehlt genau einmal, sonst
        # stuende eine auf `beantragt` zurueckgesetzte Lizenz in beiden Zahlen.
        requested = season_licenses.count do |lic|
          !ever_approved?(lic) && LicenseEffectiveStatus.base_status_id(lic) == License::REQUESTED
        end

        { approved: approved, requested: requested, ids: season_licenses.filter_map { |lic| lic['id'] } }
      end
    end

    # Gehoert diese Lizenz in die abgefragte Saison?
    #
    # Die eigene Angabe der Lizenz zuerst, in denselben zwei Formen, die auch
    # League#build_license_items kennt (das verschachtelte `league` ist das alte
    # Format, Commit e6d9773f). Fehlt sie, entscheidet die Mannschaft: Ihre Liga
    # traegt die Saison, und `team_league_id_map` enthaelt genau die
    # Mannschaften der abgefragten Saison -- ueber alle Verbaende.
    #
    # Der Rueckgriff auf die Mannschaft ist nicht der Randfall, sondern der
    # Normalfall des Bestands. Messung auf Produktion am 21.09.2026 ueber die
    # Lizenzen, die in dieser Liste eine Zeile erzeugen (Status erteilt,
    # beantragt, abgelehnt, zurueckgezogen): In der laufenden Saison 18 tragen
    # alle 8.414 eine eigene `season_id`, in JEDER frueheren Saison KEINE
    # einzige (Saison 17: 175, Saison 16: 177, Saison 14: 168 ...). Ohne den
    # Rueckgriff zeigte die Vorsaison-Ansicht durchgehend eine 0, waehrend die
    # Zeilen daneben stehen -- die Zeilenauswahl laesst eine Lizenz ohne
    # Saisonangabe naemlich durch (league.rb:1096) und die Mannschaft haelt die
    # Saison fest. Das verschachtelte Format kommt im heutigen Bestand gar
    # nicht mehr vor (0 Treffer in derselben Messung); es bleibt nur, damit die
    # beiden Stellen dieselbe Lesart haben.
    def license_in_season?(license, season_id, team_league_id_map)
      lic_season = license['season_id'].presence || license.dig('league', 'season_id').presence
      return lic_season.to_s == season_id.to_s if lic_season

      team_league_id_map.key?(license['team_id'].to_i)
    end

    # Erteilt ist eine Lizenz, wenn ihre History den Status „erteilt" kennt.
    # Der heutige Status genuegt nicht: Eine gesperrte, durch einen Transfer
    # ungueltig gewordene oder geloeschte Lizenz traegt ihn nicht mehr, der
    # Verband hat sie aber erteilt und sie hat eine Gebuehr ausgeloest.
    #
    # Die History reicht als alleinige Quelle: Auf Produktion gibt es keine
    # Lizenz ohne History-Eintrag (Zaehlung vom 21.09.2026 ueber alle 164.048
    # Lizenzen, #713).
    def ever_approved?(license)
      Array(license['history']).any? do |entry|
        entry.is_a?(Hash) && entry['license_status_id'].to_i == License::APPROVED
      end
    end

    # Haupt-/Zusatzlizenz (Anzeige-Konzept): die Lizenz in der höchsten Liga ist
    # 'primary', alle weiteren sind Zusatzlizenzen ('secondary'). Unabhängig von
    # der manuellen Erst-/Zweitlizenz-Zuordnung (gf_role), die die
    # Spielberechtigung im GF-Erwachsenenbereich dokumentiert.
    #
    # Nur erteilte und beantragte Lizenzen nehmen an der Wahl teil. Die Aussage
    # ist eine über die Spielberechtigung, und eine gelöschte, abgelehnte,
    # zurückgezogene oder wegen eines Transfers ungültige Lizenz hat keine.
    # Vorher zählten sie mit, und weil die Ligaklasse zuerst entscheidet, gewann
    # eine tote Lizenz in der höheren Klasse: Der Verband sah die tatsächlich
    # erteilte Lizenz als „Zusatzlizenz", ohne dass die Zeile daneben stand, die
    # das erklärt hätte -- gelöscht und transferungültig stehen gar nicht in
    # dieser Liste. Auf der Produktion traf das am 18.09.2026 sieben Spieler der
    # laufenden Saison.
    #
    # Der Basis-Status (ohne Sperre) wie in League#build_license_items und
    # other_license_items: Eine gesperrte Lizenz ist erteilt und bleibt die
    # Hauptlizenz, sonst wanderte das Abzeichen für die Dauer der Sperre auf
    # eine andere Lizenz.
    #
    # Eine Zeile, die selbst nicht mitwählt, bekommt `nil`: keine Aussage.
    # 'secondary' wäre selbst eine -- nämlich, dass die Hauptlizenz woanders
    # liegt. Das Abzeichen bleibt dabei leer (das Frontend zeigt nur 'primary'
    # und 'secondary' an), und der Filter „nur Zusatzlizenzen" findet die Zeile
    # nicht mehr: Er dient der Prüfung der Erst-/Zweitlizenz-Zuordnung, und ein
    # abgelehnter Antrag gehört dort nicht hinein. Ebenso die CSV-Ausfuhr, aus
    # der abgerechnet und an den Landesverband gemeldet wird.
    #
    # Der Basis-Status dieser Zeile ist schon ermittelt und steht als
    # `base_status_id` daneben. Ihn hier ein zweites Mal herzuleiten hieße, dass
    # Abzeichen und Statusspalte derselben Zeile auseinanderlaufen können, wenn
    # sich eine der beiden Herleitungen je ändert.
    def license_type(player_data, current_lic, all_season_leagues, team_league_id_map)
      return nil unless License::ACTIVE_STATUSES.include?(player_data[:team_license][:base_status_id].to_i)

      lics = Array(player_data[:licenses]).select do |l|
        team_league_id_map.key?(l['team_id'].to_i) && active_license?(l)
      end

      primary = lics.min_by do |l|
        league_id = team_league_id_map[l['team_id'].to_i]
        lg        = all_season_leagues[league_id]
        # Höchste Liga zuerst; bei gleicher Ligastufe die früher genehmigte.
        # l['id'] als letzter Tiebreaker, damit die Auswahl bei vollständigem
        # Gleichstand deterministisch ist.
        [League.class_rank(lg&.league_class_id), License.approval_time(l), l['id'].to_s]
      end
      # Ohne sichtbare Mitbewerberin bleibt es bei der Zeile selbst: Sie ist
      # erteilt oder beantragt, und mehr weiß dieser Aufruf nicht.
      return 'primary' if primary.nil?

      # Über die Kennung, sonst über die Gleichheit des Eintrags selbst: Vorher
      # stand im Vergleich ein Vorgabewert (`fetch('id', current_lic['id'])`),
      # der jede Zeile eines Spielers still zur Hauptlizenz machte, sobald die
      # Gewinnerin keine Kennung trug. Alle Schreiber setzen heute eine, im
      # Altbestand ist das nicht garantiert -- und zwei Lizenzen desselben
      # Spielers können Feld für Feld gleich aussehen, ein Wertvergleich taugt
      # dafür also nicht.
      if primary.equal?(current_lic) ||
         (primary['id'].present? && primary['id'] == current_lic['id'])
        'primary'
      else
        'secondary'
      end
    end

    def active_license?(license)
      License::ACTIVE_STATUSES.include?(LicenseEffectiveStatus.base_status_id(license))
    end

    def license_category_name(category_id)
      return nil if category_id.blank?

      Setting.current['league_categories']&.dig(category_id.to_s, 'name') || category_id
    end

    def license_class_name(class_id)
      return nil if class_id.blank?

      Setting.current['league_classes']&.dig(class_id.to_s, 'name') || class_id
    end
  end
end
