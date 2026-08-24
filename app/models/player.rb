class Player < ApplicationRecord
  include PlayerUnmerging

  has_paper_trail

  belongs_to :created_at_user, class_name: 'User', optional: true
  belongs_to :updated_at_user, class_name: 'User', optional: true

  has_many :license_documents, dependent: :destroy
  has_many :suspensions, class_name: 'PlayerSuspension', dependent: :destroy

  validates :nation_id, presence: true
  validate :nation_id_is_positive, if: -> { nation_id.present? }
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true

  # Führende und nachgestellte Leerzeichen verhindern das exakte Matching bei
  # Transfer/Freigabe (api#496) — am Bildschirm ist ein Leerzeichen am Namensende
  # unsichtbar, der Vergleich schlägt aber fehl. Neu angelegte und geänderte
  # Profile sind damit sauber; den Bestand zieht `trim_player_names.rake`
  # einmalig nach.
  before_validation :strip_names

  # Randleerzeichen in Namen (api#496). Die beiden Bereiche gehören zusammen:
  # `with_exact_name` muss genau den Rand ignorieren, den #strip_names beim
  # Speichern entfernt, sonst findet die Suche einen Teil des Altbestands
  # weiterhin nicht.
  #
  # Postgres `TRIM(x)` ist `btrim(x, ' ')` und kennt ausschließlich das
  # Leerzeichen, `String#strip` räumt zusätzlich Tabulator, Zeilenumbruch,
  # Wagenrücklauf, Zeilen- und Seitenvorschub weg. Ein Name mit Tabulator am
  # Ende (CSV-/Excel-Import) wäre mit `TRIM` weder auffindbar noch würde
  # `players:report_untrimmed_names` ihn melden — der Bericht meldete 0, und der
  # Fehler bliebe. Deshalb `BTRIM` mit derselben Zeichenmenge auf beiden Seiten.
  #
  # Nicht abgedeckt bleibt das geschützte Leerzeichen (U+00A0) aus Word/Excel:
  # `String#strip` entfernt es ebenfalls nicht, es hier wegzuräumen brächte die
  # beiden Seiten wieder auseinander.
  SQL_NAME_PADDING = "E' \\t\\n\\x0B\\f\\r'".freeze

  # Exakter Treffer auf Vorname, Nachname und Geburtsdatum; Groß-/Kleinschreibung
  # und Randleerzeichen auf beiden Seiten des Vergleichs ignoriert.
  scope :with_exact_name, lambda { |first_name, last_name, birthdate|
    where("LOWER(BTRIM(first_name, #{SQL_NAME_PADDING})) = ? AND " \
          "LOWER(BTRIM(last_name, #{SQL_NAME_PADDING})) = ? AND birthdate = ?",
          first_name.to_s.strip.downcase, last_name.to_s.strip.downcase, birthdate)
  }

  # Profile, deren Name am Rand Leerzeichen trägt. Grundlage von
  # `players:report_untrimmed_names` und `players:trim_names`.
  scope :with_padded_name, lambda {
    where("first_name <> BTRIM(first_name, #{SQL_NAME_PADDING}) OR " \
          "last_name <> BTRIM(last_name, #{SQL_NAME_PADDING})")
  }

  # wo kommt das her?
  # attr_accessor :hash, :prefix

  scope :active, -> { where(deactivated_at: nil) }

  def meta_hash
    attributes.with_indifferent_access.slice(:id, :last_name, :first_name, :birthdate, :gender, :security_id, :deactivated_at)
  end

  def search_hash
    club_id = clubs&.first&.dig('club_id')
    {
      id:,
      last_name:,
      first_name:,
      birthdate:,
      gender:,
      club_id:,
      # Damit die Suche kennzeichnen kann, dass der Verein dieses Profil aus seiner
      # aktiven Liste genommen hat. Seit api#472 ist es trotzdem auffindbar und
      # transferierbar, also braucht der Treffer diesen Hinweis.
      deactivated_at:
    }
  end

  def full_hash(with_licenses = false, only_current_licenses = false, license_with_titles = false)
    p = {
      id:,
      last_name:,
      first_name:,
      birthdate:,
      gender:,
      nation_id:,
      nation_string:,
      clubs:,
      security_id:,
      email:,
      deactivated_at:,
      deactivation_reason:
    }

    if with_licenses
      # licenses ist bei Spielern ohne jede Lizenz NULL – ohne Fallback lief das
      # anschliessende map! auf nil und die Spieler-Detailansicht im Admin
      # antwortete mit 500 (Sentry SAISONMANAGER-19).
      p[:licenses] = if only_current_licenses
                       # Die Schwelle einmal lesen, nicht je Lizenz: Setting.current_min_team
                       # kostet 0,93 ms (Messung auf Produktion, siehe Setting.current).
                       # Mal die Zahl der Lizenzen wird daraus der Posten, der die
                       # Lizenzliste des Verbandes ausgebremst hat — ein Spieler mit 41
                       # Lizenzen brauchte so 37 ms statt 0,02 ms fuer diesen Block.
                       min_team_id = Setting.current_min_team
                       (licenses || []).select { |l| l['team_id'].to_i >= min_team_id }
                     else
                       licenses || []
                     end

      if license_with_titles
        p[:licenses].map! do |lic|
          last_status_id = nil
          lic['history']&.map! do |lh|
            lh[:created_by_name] = User.find_by(id: lh['created_by'])&.full_with_username
            lh[:license_status] = License::NAMES[lh['license_status_id'].to_i]
            last_status_id = lh['license_status_id'].to_i

            lh
          end

          lic[:set_transfer_allowed] = (last_status_id == License::APPROVED)

          team = Team.find_by(id: lic['team_id'])
          lic[:team] = team&.full_hash
          lic[:league] = team&.league&.full_hash

          lic
        end
      end
    end

    p
  end

  def some_hash(hash_type = :full, with_licenses = false, only_current_licenses = false)
    case hash_type
    when :full
      full_hash(with_licenses, only_current_licenses)
    when :short
      full_hash(with_licenses, only_current_licenses).select do |k, _v|
        %i[id first_name last_name birthdate].include? k
      end
    else
      {}
    end
  end

  def admin_players_clubs
    {
      club_id:
    }
  end

  # Setting.current, nicht Setting.first: full_hash nimmt nation_string in JEDE
  # Zeile auf, und Setting.first ist eine ungepufferte Abfrage. In der
  # Lizenzliste des Verbandes lief sie damit einmal je Lizenzzeile.
  def nation_string
    Setting.current['nations']&.dig(nation_id.to_s, 'name')
  end

  def created_by_string
    created_at_user.user_name if created_at_user.present?
  end

  def updated_by_string
    updated_at_user.user_name if updated_at_user.present?
  end

  def main_license_hash(season_id, deadline = Date.today)
    # player clubs
    club_names = valid_clubs(deadline).map do |club_item|
      club = Club.find_by_id(club_item['club_id'])
      club ? club.name : 'CLUB(FEHLER)'
    end

    club_ids = valid_clubs(deadline).map do |club_item|
      club = Club.find_by_id(club_item['club_id'])
      club ? club.id : nil
    end.compact

    if current_licenses(season_id)
      sorted_licenses = current_licenses(season_id).map! do |x|
        x['sorting'] = League.class_rank(x['league_class_id'])
        x
      end
    end
    license = select_license sorted_licenses if sorted_licenses

    p = create_license_hash(license, sorted_licenses, club_names, club_ids, deadline)
    p.merge(other_license_count: (sorted_licenses || []).count - 1) if p
  end

  def secondary_license_hash(season_id, deadline = Date.today)
    # player clubs
    club_names = valid_clubs(deadline).map do |club_item|
      club = Club.find_by_id(club_item['club_id'])
      club ? club.name : 'CLUB(FEHLER)'
    end

    club_ids = valid_clubs(deadline).map do |club_item|
      club = Club.find_by_id(club_item['club_id'])
      club ? club.id : nil
    end.compact

    if current_licenses(season_id)
      sorted_licenses = current_licenses(season_id).map! do |x|
        x['sorting'] = League.class_rank(x['league_class_id'])
        x
      end
    end
    licenses = other_licenses sorted_licenses if sorted_licenses

    if sorted_licenses
      licenses.map do |license|
        create_license_hash(license, sorted_licenses, club_names, club_ids, deadline)
      end
    end
  end

  def create_license_hash(license, sorted_licenses, club_names, club_ids, deadline)
    p = HashWithIndifferentAccess.new({
                                        id:,
                                        last_name:,
                                        first_name:,
                                        birthdate:,
                                        gender:,
                                        license_hash: sorted_licenses,
                                        license: license.to_json.to_s,
                                        clubs: club_names.to_json,
                                        club_ids: club_ids.to_json
                                      })

    valid_home_club = home_club(deadline)
    if valid_home_club
      p.merge!(home_club_id: valid_home_club.id,
               home_club: valid_home_club.name,
               home_club_operation: valid_home_club.home_game_operation&.name,
               home_club_state: valid_home_club.state)
    end

    if license
      p.merge!(team_id: license['team_id'],
               license_id: license['id'],
               league_class_id: license['league_class_id'],
               history: license['history'],
               league_class: Setting.league_class(license['league_class_id']),
               league_category_id: license['league_category_id'],
               league_category: (license['league_category_id'].present? ? Setting.league_category(license['league_category_id']) : 'x'))
    end

    team = Team.find_by_id license['team_id'] if license
    team_clubs = team.all_clubs if team
    if team_clubs.present?
      p.merge!(license_clubs: team_clubs.to_json, license_club: '', league_id: team.league_id)

      if team_clubs.map(&:id).include? p[:license_hash_id]
        p[:license_club] = p[:home_club]
        p[:license_club_state] = p[:home_club_state]
      elsif (team_clubs.map(&:id) & club_ids).size > 0
        # check which club should be choosen
        club = Club.find_by_id (team_clubs.map(&:id) & club_ids).first
        p[:license_club] = club ? club.name : 'FEHLER (LC)'
        p[:license_club_state] = club ? club.state : 'FEHLER (LCS)'
      else
        # check which club should be choosen
        club = Club.find_by_id team_clubs.first.id
        p[:license_club] = club ? club.name : 'FEHLER (LCA)'
        p[:license_club_state] = club ? club.state : 'FEHLER (LCSA)'
      end
    end

    p
  end

  def valid_clubs(deadline)
    return [] unless clubs

    # Strukturell kaputte Eintraege (kein Objekt) zaehlen nicht als Mitgliedschaft. Ohne
    # den Riegel bricht jeder Leser darueber ab, und seit home_club_entry DIE Quelle fuer
    # den Heimatverein ist, gehoert er hierher statt in jeden Aufrufer einzeln.
    clubs.reject { |l| !l.is_a?(Hash) || valid_time?(l['valid_until'], deadline) }
  end

  def home_club(deadline)
    entry = home_club_entry(deadline)
    Club.find_by_id entry['club_id'] if entry
  end

  # Der clubs-Eintrag, der den aktuellen Heimatverein traegt — die eine Quelle fuer
  # jeden Leser, der wissen muss, aus welchem Verein eine Person gerade kommt.
  #
  # Es gab davon zwei, und sie widersprachen sich. `home_club` las den LETZTEN
  # gueltigen Heimat-Eintrag, `Admin::TransferRequestsController` suchte mit
  # `clubs.find { |c| c['home_club'] == true && c['valid_until'].nil? }` den ERSTEN.
  # Bei 238 Profilen im Bestand (Stand 18.08.2026) sind zwei Heimat-Eintraege offen,
  # und dort meinten die beiden verschiedene Vereine: Die Oberflaeche zeigte den
  # einen, der Transferantrag ging zur Genehmigung an den anderen.
  #
  # Die alte Controller-Fassung wich in zwei weiteren Punkten ab, beide zum Nachteil:
  #
  #   - `== true` statt Boolean-Cast. In Altdaten steht das Flag als String; ein
  #     solcher Eintrag galt dem Controller nicht als Heimat, und der Antrag scheiterte
  #     mit "Spieler hat keinen aktiven Heimverein", obwohl `home_club` einen findet.
  #   - `valid_until.nil?` statt Stichtagsvergleich. Eine Heimat-Zugehoerigkeit mit
  #     einem Ende in der Zukunft gilt heute noch; der Controller zaehlte sie nicht.
  def home_club_entry(deadline = Date.current)
    home_club_hash(deadline)&.last
  end

  # Heimat-Zugehörigkeiten, die am Stichtag noch gelten.
  #
  # Boolean-Cast statt Truthy-Prüfung: In Altdaten liegt das Flag auch als String,
  # und `'false'` wie `'f'` sind truthy. Ein Zweitspielrecht mit einem solchen Wert
  # zählte damit als Heimat und bestimmte über `home_club` den zuständigen
  # Spielbetrieb — in beide Richtungen falsch: Es verschaffte dem Gastverband
  # Zuständigkeit und nahm sie dem echten Heimatverband.
  def home_club_hash(deadline)
    return unless clubs

    # valid_clubs hat mit demselben Praedikat bereits gefiltert; ein zweiter
    # valid_time?-Aufruf waere tot und wuerde den Melde-Pfad doppelt anstossen.
    valid_clubs(deadline).reject { |l| !ActiveModel::Type::Boolean.new.cast(l['home_club']) }
  end

  def current_licenses(sid = Setting.current_season_id)
    current_licenses_meta(Team.teams_by_season(sid))
  end

  def current_licenses_meta(teams)
    if licenses
      result = licenses.reject do |l|
        !teams.map(&:id).map(&:to_s).include?(l['team_id'].to_s)
      end
    end
    if result
      result.map do |x|
        x['sorting'] = League.class_rank(x['league_class_id'])
        x
      end
    end
  end

  def licenses_by_team(team_id)
    if licenses
      licenses.each do |l|
        return l if team_id.to_i == l['team_id'].to_i
      end
    end

    nil
  end

  def current_license_status(license)
    status = license['history']&.sort_by { |h| h['created_at'] }&.last
    return unless status

    status[:created_by_name] = User.find_by(id: status['created_by'])&.full_with_username
    status[:license_status] = License::NAMES[status['license_status_id'].to_i]

    status
  end

  def license_status_by_team(team_id)
    l = licenses_by_team(team_id)

    current_license_status(l) if l.present?
  end

  def transfer(new_club_id, user_id)
    player_clubs = clubs
    # Derselbe Leser wie ueberall sonst, statt einer dritten eigenen Auslegung.
    old_club = home_club_entry&.dig('club_id')

    player_clubs.map! do |c|
      # Jede noch gueltige Zugehoerigkeit wird geschlossen, Heimat wie Zweitspielrecht:
      # Wer den Verein wechselt, nimmt keine der alten mit.
      #
      # Die fruehere Bedingung lautete `c['valid_until'].nil? || c['valid_until'] > Time.now`.
      # Fuer lesbare Daten war sie richtig — ActiveSupport patcht `Time#<=>`, sodass der
      # String-gegen-Time-Vergleich koerziert. Bei einem unlesbaren valid_until warf sie
      # aber `ArgumentError: comparison of String with Time failed`, und der Vereinswechsel
      # brach ab. Ueber valid_time? ist dieser Fall jetzt abgedeckt.
      if c.is_a?(Hash) && !valid_time?(c['valid_until'], Date.current)
        c['valid_until'] = Time.now
        c['valid_set_by'] = user_id
      end

      c
    end

    # set new home club
    player_clubs << {
      'club_id' => new_club_id,
      'home_club' => true,
      'created_at' => Time.now,
      'created_by' => user_id
    }

    updated_by_user = User.find user_id

    Transfer.create({
                      created_by: user_id,
                      former_club_id: old_club,
                      new_club_id:,
                      player_id: id,
                      season_id: Setting.current_season_id
                    })

    clear_deactivation

    save!(validate: false)
  end

  # Kaputter SQL-Default, der versehentlich als String in security_id landete.
  PLACEHOLDER_SECURITY_ID = 'uuid_generate_v4()'.freeze

  # Führt die Secondary (self) in den Master zusammen und deaktiviert self.
  # Gibt die Liste der Verknüpfungen zurück, die wegen Unique-Index-Kollision
  # NICHT auf den Master umgehängt werden konnten und am (deaktivierten)
  # Secondary-Datensatz verbleiben – der Aufrufer muss diese sichtbar machen.
  def merge_into!(master, user_id)
    raise ArgumentError, 'Master und Secondary dürfen nicht identisch sein' if id == master.id
    raise ArgumentError, 'Secondary ist bereits zusammengeführt' if merged_into_id.present?
    raise ArgumentError, 'Master ist bereits zusammengeführt' if master.merged_into_id.present?
    raise ArgumentError, 'Beide Spieler kommen im selben Spiel vor' if _shares_game_with?(master)

    skipped_associations = []
    ActiveRecord::Base.transaction do
      %w[first_name last_name birthdate gender nation_id email].each do |field|
        master[field] = self[field] if master[field].blank? && self[field].present?
      end
      # Eine echte security_id des Secondary schlägt einen Platzhalter des Masters,
      # auch wenn der Master (kleinste ID) bestehen bleibt.
      if _blank_security_id?(master.security_id) && !_blank_security_id?(security_id)
        master.security_id = security_id
      end

      # deep_dup: die zusammengeführten Einträge landen auf dem Master; das
      # anschließende deactivate! mutiert die Clubs/Lizenzen der Secondary und
      # darf die Master-Kopien nicht mit anfassen.
      master.clubs    = _merge_clubs(clubs, master.clubs, user_id)
      master.licenses = _merge_licenses(licenses, master.licenses)
      master.save!(validate: false)

      _rewrite_player_game_references(master.id)
      skipped_associations = _repoint_player_associations(master.id)

      self.merged_into_id = master.id
      # Beim Merge sind die Nebenwirkungen richtig: Zugehoerigkeiten und Lizenzen
      # liegen jetzt am Master (siehe _merge_clubs/_merge_licenses), und die Dublette
      # darf nirgends mehr als aktives Mitglied oder Lizenznehmer auftauchen. Die
      # regulaere Deaktivierung ruehrt beides bewusst nicht mehr an, deshalb steht das
      # hier explizit.
      _void_memberships_and_licenses!(user_id, reason: MERGE_REASON)
      deactivate!(user_id, reason: MERGE_REASON)

      MergeLog.record!(
        object_type: 'player',
        master_id: master.id, master_label: "#{master.last_name}, #{master.first_name}",
        merged_id: id, merged_label: "#{last_name}, #{first_name}",
        user_id: user_id
      )
    end
    skipped_associations
  end

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
  # Öffentliche Vorab-Prüfung für Merge-Anträge: kommen beide Spieler gemeinsam
  # in einer Aufstellung vor, sind es sicher zwei verschiedene Personen.
  def shares_game_with?(other)
    _shares_game_with?(other)
  end

  # Einheitlicher Helper für License-History-Mutationen.
  # Garantiert, dass season_id, created_by und created_at immer vorhanden sind,
  # um History-Inkonsistenzen (Bonner-Vorfall-Klasse) zu vermeiden.
  def append_license_history(license, status:, user_id:, reason: nil)
    license['history'] ||= []
    license['history'] << {
      'license_status_id' => status,
      'created_at' => Time.current.iso8601,
      'created_by' => user_id,
      'reason' => reason
    }.compact
  end

  # --- Erst-/Zweitlizenz im Großfeld-Erwachsenenbereich ----------------------
  #
  # Die Zuordnung ist eine manuelle Entscheidung (Wahl des Spielers, dokumentiert
  # durch SBK/Admin) und wird pro Wettbewerb (GF Erwachsene, getrennt nach
  # männlich/weiblich = League#female) im Lizenz-Eintrag gespeichert:
  #   gf_role:         'erstlizenz' | 'zweitlizenz' | nicht gesetzt
  #   gf_role_history: [{ gf_role, source, created_by, created_at }]
  # source: 'assign' = Erstzuordnung, 'swap' = Tausch (max. 1x/Saison),
  #         'auto' = automatische Gegenbuchung der Partner-Lizenz.

  GF_ROLES = %w[erstlizenz zweitlizenz].freeze
  GF_ROLE_SWAP_LIMIT = 1

  # Aktive Lizenz-Einträge desselben GF-Erwachsenen-Wettbewerbs (gleiche Saison,
  # gleiches female-Flag) – ohne den übergebenen Eintrag selbst.
  def gf_competition_licenses(license, league)
    (licenses || []).select do |l|
      next false if l['id'] == license['id']
      next false unless l['season_id'].to_s == license['season_id'].to_s

      last_status = l['history']&.max_by { |h| h['created_at'] }&.dig('license_status_id').to_i
      next false unless License::ACTIVE_STATUSES.include?(last_status)

      other_league = Team.find_by(id: l['team_id'])&.league
      other_league.present? && other_league.gf_adult? && other_league.female == league.female
    end
  end

  # Anzahl bereits erfolgter Tausch-Operationen in diesem Wettbewerb. Jeder
  # Tausch schreibt genau einen 'swap'-Eintrag auf die gewechselte Lizenz
  # (die Partner-Lizenz wird mit 'auto' gegengebucht); die Summe über alle
  # Wettbewerbs-Lizenzen zählt daher die Tausch-Vorgänge unabhängig davon,
  # von welcher Lizenz aus getauscht wurde.
  def gf_role_swap_count(license, league)
    ([license] + gf_competition_licenses(license, league)).sum do |l|
      Array(l['gf_role_history']).count { |h| h['source'] == 'swap' }
    end
  end

  # Setzt die Zuordnung einer Lizenz und bucht die Partner-Lizenzen des
  # Wettbewerbs gegen (mutiert nur, speichert nicht):
  # - Wird eine Lizenz Erstlizenz, werden alle anderen zur Zweitlizenz.
  # - Wird eine Lizenz Zweitlizenz und die einzige Partner-Lizenz ist noch
  #   nicht markiert, wird diese zur Erstlizenz.
  # role = nil entfernt die Zuordnung ohne Gegenbuchung.
  def apply_gf_role(license, role, league, user_id, source:)
    assign_gf_role(license, role, user_id, source)
    return if role.blank?

    partners = gf_competition_licenses(license, league)
    if role == 'erstlizenz'
      partners.each do |l|
        assign_gf_role(l, 'zweitlizenz', user_id, 'auto') unless l['gf_role'] == 'zweitlizenz'
      end
    elsif partners.size == 1 && partners.first['gf_role'] != 'erstlizenz'
      assign_gf_role(partners.first, 'erstlizenz', user_id, 'auto')
    end
  end

  def assign_gf_role(license, role, user_id, source)
    if role.blank?
      license.delete('gf_role')
    else
      license['gf_role'] = role
    end
    (license['gf_role_history'] ||= []) << {
      'gf_role' => role,
      'source' => source,
      'created_by' => user_id,
      'created_at' => Time.current.iso8601
    }
  end

  # Fenster um deactivated_at, in dem ein valid_until noch zu dieser Deaktivierung
  # gehört. Bis api#472 schrieb deactivate! beides im selben Aufruf, wenige
  # Anweisungen auseinander; die Spanne deckt allein die Rundung der
  # JSONB-Serialisierung ab. Sie kann naturgemäß nicht unterscheiden, ob im selben
  # Moment auch ein Transfer lief – eine engere Schranke gibt es ohne eigenen Marker
  # am Eintrag nicht. Fuer neue Deaktivierungen ist beides gegenstandslos: sie
  # ruehren die Zugehoerigkeiten nicht an.
  DEACTIVATION_CLOSE_WINDOW = 1.second

  # Schlüssel im clubs-Eintrag, unter dem deactivate! bis api#472 die Befristung
  # sicherte, die es selbst überschrieb. Nur gesetzt, wenn es überhaupt eine gab, und
  # von reset_deactivation_side_effects! wieder entfernt – bei Profilen, die vor
  # seiner Einführung deaktiviert wurden, fehlt er, dort bleibt es beim bisherigen
  # Verhalten (Befristung entfällt). Neue Deaktivierungen schreiben ihn nicht mehr.
  VALID_BEFORE_DEACTIVATION = 'valid_before_deactivation'.freeze

  # Auswählbare Deaktivierungsgründe. Einzige Quelle für die Oberfläche und für
  # die Whitelist in PlayersController#deactivate; freie Gründe kommen zusätzlich
  # als "Sonstiges: …" durch. "Wechsel ins Ausland" deckt den internationalen
  # Transfer ab: Der Transfer selbst läuft über FD und IFF außerhalb dieses
  # Systems, die Deaktivierung nimmt den Spieler danach aus der Vereinsliste.
  DEACTIVATION_REASONS = ['Vereinsaustritt', 'Karriereende', 'Temporäre Pause', 'Wechsel ins Ausland'].freeze

  # Gründe, die nur im Altbestand stehen: "Deaktiviert" schrieben frühere
  # Fassungen ohne Auswahl. reactivate! muss sie weiterhin erkennen, die
  # Oberfläche bietet sie nicht an.
  LEGACY_DEACTIVATION_REASONS = ['Deaktiviert'].freeze

  # Wahr, wenn das Ende dieser Vereinszugehörigkeit auf die Deaktivierung dieses
  # Profils zurückgeht. Trifft nur noch auf den Bestand zu: seit api#472 schliesst
  # `deactivate!` keine Zugehoerigkeit mehr.
  #
  # Der Stempel valid_set_by allein genügt als Merkmal nicht: den setzt jede Stelle,
  # die eine Zugehörigkeit schließt oder befristet anlegt (Vereinswechsel,
  # Zweitspielrecht anlegen und ablaufen lassen), nicht nur deactivate!. Deaktiviert
  # später dieselbe Person, zählte ein reiner valid_set_by-Vergleich eine längst
  # abgelaufene Zugehörigkeit als "durch die Deaktivierung geschlossen" – der Verein
  # bekäme das Profil in seine Liste und beim Reaktivieren eine unbefristete
  # Mitgliedschaft zurück, die er nie hatte. Daher zusätzlich das Zeitfenster.
  #
  # Beidseitig, nicht nur nach unten: ein Zweitspielrecht, das NACH der Deaktivierung
  # angelegt wird (TransferRequest, PlayersController#add_additional_club), trägt ein
  # valid_until in der Zukunft und gehört ebenso wenig zur Deaktivierung.
  #
  # Zugehörigkeiten, die ohne valid_set_by geschlossen wurden (Altdaten, Backfills),
  # erfüllen die Bedingung bewusst nicht: sie bleiben ausgeblendet, wie vorher auch.
  def membership_closed_by_deactivation?(membership)
    # Strukturell kaputter Eintrag (kein Objekt): Der Altbestand enthaelt clubs-Eintraege,
    # die kein Hash sind. Ohne diesen Riegel bricht schon der Lesezugriff darunter mit
    # NoMethodError ab, und zwar nicht nur im Wartungslauf (der faengt es je Profil ab),
    # sondern auch in `reactivate!` und `Club#players(include_deactivated: true)` – dort
    # als 500er. Denselben Riegel haben `LicenseAccessScope#player_in_team_clubs?` und
    # `PlayersController#membership_grants_access?`.
    return false unless membership.is_a?(Hash)
    return false if deactivated_at.blank? || membership['valid_until'].blank?
    return false unless membership['valid_set_by'].present? && membership['valid_set_by'] == deactivated_by

    membership['valid_until'].to_time.between?(deactivated_at - DEACTIVATION_CLOSE_WINDOW,
                                               deactivated_at + DEACTIVATION_CLOSE_WINDOW)
  end

  # Die Deaktivierung ist eine Kennzeichnung fuer die Vereins- und
  # Mannschaftsansichten, kein Eingriff in die Stammdaten. Sie haelt das Profil aus
  # der Spielerliste des Vereins heraus (`Club#players` filtert auf `Player.active`)
  # und damit aus der Auswahl beim Lizenzantrag. Mehr nicht: Vereinszugehoerigkeit
  # und Lizenzen bleiben, wie sie sind.
  #
  # Bis api#472 schloss sie zusaetzlich JEDE noch gueltige Zugehoerigkeit und setzte
  # alle laufenden Lizenzen (APPROVED/REQUESTED) auf DELETED. Damit war der
  # haeufigste Anlass der schaedlichste: Beim Grund "Vereinsaustritt" verlor die
  # Person ihren Heimatverein und fiel gleichzeitig aus jeder Suche, weil
  # `global_search` und `Admin::TransferRequestsController#search_player` auf
  # `Player.active` filterten. Der aufnehmende Verein fand sie nicht mehr, und weil
  # Transferantrag und Direktzuweisung einen gueltigen Heimatverein verlangen, gab
  # es keinen Weg zurueck ausser einer Reaktivierung durch die SBK. Auf Produktion
  # traf das am 25.07.2026 drei Profile eines Vereins innerhalb von sechs Minuten,
  # dazu weitere in anderen Vereinen.
  #
  # Die offene Zugehoerigkeit ist dabei nicht Kosmetik, sondern das Mittel: Sie ist
  # es, die das Profil transferierbar haelt.
  def deactivate!(user_id, reason: nil)
    self.deactivated_at = Time.current
    self.deactivated_by = user_id
    self.deactivation_reason = reason
    save!(validate: false)
  end

  # Nimmt die Deaktivierung samt ihrer Nebenwirkungen im Bestand zurueck: die von
  # ihr geschlossenen Zugehoerigkeiten gehen wieder auf, die von ihr geschriebenen
  # DELETED-Eintraege verschwinden aus dem Lizenz-Verlauf. Fuer alles, was seit
  # api#472 deaktiviert wurde, sind beide Schritte ein No-op, weil es diese
  # Nebenwirkungen nicht mehr gibt.
  def reactivate!
    # Vor dem Loeschen der Kennzeichnung: beide Schritte lesen `deactivated_at` und
    # `deactivated_by`.
    self.licenses ||= []
    pop_deactivation_license_entries!
    reopen_memberships_closed_by_deactivation!(persist: false)

    self.deactivated_at = nil
    self.deactivated_by = nil
    save!(validate: false)
  end

  # Oeffnet die Vereinszugehoerigkeiten, die eine Deaktivierung vor api#472
  # geschlossen hat. Fuer alles, was danach deaktiviert wurde, ein No-op:
  # `membership_closed_by_deactivation?` verlangt Stempel UND Zeitfenster der
  # Deaktivierung, und geschlossen wird seither keine Zugehoerigkeit mehr.
  #
  # Laesst Kennzeichnung und Lizenzen unangetastet, und das ist der Punkt: Dass der
  # Verein das Profil aus seiner Liste genommen hat, ist seine Entscheidung, und die
  # damals ungueltig gesetzten Lizenzen bleiben ungueltig. Zurueckzunehmen ist
  # allein die geschlossene Zugehoerigkeit, denn sie hat das Profil untransferierbar
  # gemacht. So heilt `rake players:reopen_memberships_after_deactivation` den
  # Bestand.
  #
  # `persist: false` ueberlaesst das Speichern dem Aufrufer (`reactivate!` raeumt im
  # selben Schreibvorgang auch die Kennzeichnung ab).
  #
  # Rueckgabe: ob eine Zugehoerigkeit geoeffnet wurde.
  def reopen_memberships_closed_by_deactivation!(persist: true)
    self.clubs ||= []

    targets = memberships_reopenable
    targets.each { |c| restore_membership_validity(c) }

    save!(validate: false) if persist && targets.any?
    targets.any?
  end

  # Die Zugehoerigkeiten, die `reopen_memberships_closed_by_deactivation!` oeffnen wuerde.
  # Eigene Methode, damit der Wartungslauf im Dry-Run genau das zaehlt, was er spaeter auch
  # tut, statt der blossen Kandidaten.
  #
  # Der frühere reine valid_set_by-Vergleich öffnete auch ein Zweitspielrecht wieder, das
  # lange vor der Deaktivierung abgelaufen war; dagegen steht das Zeitfenster in
  # `membership_closed_by_deactivation?`.
  #
  # Ein Heimatverein kommt zusaetzlich nur infrage, solange keiner offen ist. Das
  # Erkennungsmerkmal (valid_set_by == deactivated_by, valid_until im Sekundenfenster um
  # deactivated_at) trifft naemlich auch eine Zugehoerigkeit, die dieselbe Person
  # unmittelbar zuvor per Transfer regulaer geschlossen hat. Ohne den Riegel haette das
  # Profil danach zwei offene Heimatvereine – und die beiden Leser widersprechen sich:
  # `Player#home_club` nimmt den letzten Treffer (Neuverein),
  # `Admin::TransferRequestsController` bestimmt `former_club_id` als ersten (Altverein).
  # Ein Transferantrag ginge dann an den falschen abgebenden Verein zur Genehmigung.
  #
  # Ob das Oeffnen den Eintrag wirklich unbefristet macht, haengt am gesicherten
  # VALID_BEFORE_DEACTIVATION. Hier wird bewusst vom unguenstigsten Fall ausgegangen und
  # jeder wiederhergestellte Heimatverein als offen gewertet: lieber eine Zugehoerigkeit
  # zu wenig oeffnen als einen widerspruechlichen Zustand herstellen.
  def memberships_reopenable
    entries = Array(clubs)
    open_home_club = entries.any? { |c| c.is_a?(Hash) && c['home_club'] && c['valid_until'].blank? }

    entries.select do |c|
      next false unless membership_closed_by_deactivation?(c)
      next false if c['home_club'] && open_home_club

      open_home_club ||= c['home_club'].present?
      true
    end
  end

  # Einheitlicher Einstieg für beide Sperr-Ebenen aus Issue #508.
  # team_id == nil  → Beantragungssperre (Ebene 2): blockiert neue Anträge und
  #                   setzt ALLE aktuell aktiven Lizenzen auf "gesperrt".
  # team_id gesetzt → Lizenzaussetzung (Ebene 1): setzt nur die Lizenz dieses Teams aus.
  def suspend!(valid_until:, user_id:, team_id: nil, valid_from: Date.current, reason: nil)
    suspension = nil

    ActiveRecord::Base.transaction do
      lock! if persisted?
      self.licenses ||= []
      affected = []

      licenses.each do |license|
        next if team_id.present? && license['team_id'].to_i != team_id.to_i

        # Altdaten-Lizenzen können `_id` statt `id` oder gar keine id haben — vor dem
        # Speichern stabilisieren, damit lift_suspension! exakt dieselbe Lizenz findet.
        license['id'] ||= license.delete('_id') || Digest::UUID.uuid_v4

        last_status_id = license['history']&.max_by { |h| h['created_at'] }&.dig('license_status_id').to_i
        next unless License::ACTIVE_STATUSES.include?(last_status_id)

        license['history'] << {
          'license_status_id' => License::SUSPENDED,
          'reason' => reason.presence || 'Spielersperre',
          'created_by' => user_id,
          'created_at' => Time.now
        }
        affected << { 'license_id' => license['id'], 'previous_status_id' => last_status_id }
      end

      suspension = suspensions.create!(
        team_id:,
        valid_from:,
        valid_until:,
        reason:,
        affected_licenses: affected,
        created_by: user_id
      )

      save!(validate: false)
    end

    suspension
  end

  # Hebt eine Sperre auf: reaktiviert die betroffenen Lizenzen auf ihren vorherigen Status.
  def lift_suspension!(suspension, user_id:, reason: 'Sperre aufgehoben')
    return if suspension.lifted_at.present?

    ActiveRecord::Base.transaction do
      lock! if persisted?
      self.licenses ||= []

      Array(suspension.affected_licenses).each do |entry|
        next if entry['license_id'].blank?

        license = licenses.find { |l| l['id'] == entry['license_id'] }
        next unless license

        last_status_id = license['history']&.max_by { |h| h['created_at'] }&.dig('license_status_id').to_i
        # Nur reaktivieren, wenn die Lizenz seit der Sperre nicht manuell anders gesetzt wurde.
        next unless last_status_id == License::SUSPENDED

        license['history'] << {
          'license_status_id' => entry['previous_status_id'].to_i,
          'reason' => reason,
          'created_by' => user_id,
          'created_at' => Time.now
        }
      end

      suspension.update!(lifted_at: Time.current, lifted_by: user_id)
      save!(validate: false)
    end
  end

  # Lazy-Ablauf: hebt fällige Sperren dieses Spielers auf (auch ohne Cron korrekt).
  def expire_due_suspensions!(date: Date.current, user_id: nil)
    suspensions.due(date).each do |suspension|
      lift_suspension!(suspension, user_id: user_id || suspension.created_by, reason: 'Sperre abgelaufen')
    end
  end

  # Greift die Beantragungssperre (Ebene 2) zu einem bestimmten Datum?
  def application_blocked?(date: Date.current)
    expire_due_suspensions!(date:)
    suspensions.active.player_wide.covering(date).exists?
  end

  # Besteht eine aktive Lizenzaussetzung (Ebene 1) für ein konkretes Team?
  # Verhindert, dass eine gesperrte Team-Lizenz durch einen Neuantrag umgangen wird.
  def suspended_for_team?(team_id, date: Date.current)
    expire_due_suspensions!(date:)
    suspensions.active.where(team_id:).covering(date).exists?
  end

  def self.find_by_team_id(team_id)
    # alternative for array: extr_licenses->>'team_id' IN ('#{team_ids.join '\', \''

    # Player.find_by_sql(
    #   [
    #     "SELECT *, extr_license
    #     FROM
    #       (SELECT *, jsonb_array_elements(licenses) as extr_license
    #       FROM players) as subqry
    #     WHERE
    #       extr_license->>'team_id' = '?'
    #     ORDER BY last_name, first_name", id
    #   ]
    # )

    # Das `?` steht hier INNERHALB eines SQL-Stringliterals ('?') und ueberlebt nur,
    # weil find_by_sql ueber sanitize_sql_array laeuft — das ersetzt weiterhin
    # textuell. Wer diese Methode auf `where` umstellt (naheliegend, find_by_team_ids
    # daneben tut es schon), bekommt ab Rails 7.2 einen echten Bind-Parameter: Der
    # Arel-Visitor zerlegt auch innerhalb von Quotes, und die Abfrage scheitert mit
    # "bind message supplies 1 parameters, but prepared statement requires 0".
    # Das trifft die oeffentlichen Lizenzlisten und das Sekretariat, siehe die
    # Aufrufer in public_license_list_controller, public_secretary_controller,
    # leagues_controller, teams_controller, League und Team.
    Player.find_by_sql [
      "select *, extr_license from (SELECT *, jsonb_array_elements(licenses) as extr_license FROM players ) as subqry WHERE extr_license->>'team_id' ='?' ORDER BY extr_license->>'team_id', last_name, first_name", team_id
    ]
  end

  # Batch-Variante von find_by_team_id: lädt die Spieler für mehrere Teams in
  # EINER Query statt einer pro Team (vermeidet die N+1 in League#licenses, die
  # über alle Teams einer Liga schleift – und in admin/licenses_controller pro
  # Liga erneut). Liefert ein Hash { team_id(int) => [Player, …] }; jeder Key
  # ist vorbelegt (leeres Array, falls kein Spieler). Pro (Spieler, Team) ein
  # Eintrag – Duplikate werden, anders als bei jsonb_array_elements, vermieden
  # (Aufrufer wie leagues_controller#preround_players riefen dafür bisher
  # .uniq(&:id) auf).
  def self.find_by_team_ids(team_ids)
    ids = Array(team_ids).map(&:to_i).uniq
    result = ids.index_with { [] }
    return result if ids.empty?

    players = Player.where(
      "EXISTS (SELECT 1 FROM jsonb_array_elements(licenses) AS l " \
      "WHERE (l->>'team_id')::int = ANY (ARRAY[?]::int[]))", ids
    ).order(:last_name, :first_name)

    id_set = ids.to_set
    players.each do |player|
      (player.licenses || []).map { |l| l['team_id'].to_i }.uniq.each do |t_id|
        result[t_id] << player if id_set.include?(t_id)
      end
    end
    result
  end

  def self.admin_user_players(user, club_id)
    club_object = Club.find(club_id)

    # wenn admin oder sbk global: füge alle hinzu
    ph = user.permission_hash
    # Rollen additiv: die frühere elsif-Kette ließ die Admin-/SBK-Rolle gewinnen
    # und sperrte den Nutzer damit aus seinem eigenen Verein aus, sobald dieser
    # außerhalb der Verbands-Berechtigung liegt.
    club = if ph[:admin]&.include?(0) || ph[:sbk]&.include?(0)
             club_object
           else
             go_ids = []
             go_ids << ph[:admin] if ph[:admin].present?
             go_ids << ph[:sbk] if ph[:sbk].present?

             # Zustaendiger Spielbetrieb oder Vereins-Freigabe – gemeinsame Regel mit
             # ClubsController#can_read_admin_club? und Club.admin_user_clubs.
             #
             # Vorher: Intersection mit dem GESAMTEN game_operations_hash, also
             # auch mit bloßen Gast-Einträgen aus dem Altdaten-Import 2010–2014.
             # Damit konnte ein Landesverband die Spielerprofile fremder Vereine
             # auflisten, ohne dass es jemand erteilt hätte (auf Produktion
             # 2.513 Profile in einem einzigen Fall). Gleichzeitig fehlte die
             # Freigabe: Ein freigegebener Verein war über admin/clubs/:id
             # lesbar, seine Spielerliste antwortete aber leer.
             in_go = club_object.readable_by_game_operations?(go_ids.flatten)
             is_vm = ph[:vm].present? && ph[:vm].include?(club_id)

             club_object if in_go || is_vm
           end

    return unless club

    result = club.full_hash
    result[:players] = club.players.map(&:meta_hash)

    # this was the all club index code:
    # clubs = []

    # GameOperation.find(go_ids).each do |go|
    #   clubs << go.clubs
    # end

    # clubs << Club.find(ph[:vm]) if ph[:vm]&.present?

    # clubs = clubs.flatten.uniq

    # clubs.each do |c|
    #   item = c.full_hash
    #   item[:players] = c.players
    #   result << item
    # end

    result
  end

  def fix_player_licenses!
    team_ids = []
    licenses.reject! do |l|
      doublication = team_ids.include?(l['team_id'])
      team_ids << l['team_id']

      # filter licenses from current season
      doublication && Setting.current_min_team <= l['team_id']
    end

    save!
  end

  def delete_license!(team_id)
    licenses.reject! do |l|
      l['team_id'] == team_id
    end

    save!
  end

  # Schliesst jede noch gueltige Vereinszugehoerigkeit und setzt alle laufenden
  # Lizenzen (APPROVED/REQUESTED) auf DELETED. Ausschliesslich fuer `merge_into!`:
  # Die Dublette ist inhaltlich leer, ihre Eintraege liegen am Master.
  #
  # Bis api#472 stand dieser Rumpf in `deactivate!` und traf damit auch jede
  # Deaktivierung durch einen Verein — siehe die Begruendung dort. Speichert nicht;
  # `merge_into!` schreibt das Profil ohnehin.
  def _void_memberships_and_licenses!(user_id, reason:)
    self.clubs ||= []
    self.licenses ||= []

    clubs.map! do |c|
      if c['valid_until'].nil? || c['valid_until'].to_time > Time.now
        # Befristete Zugehörigkeiten (Zweitspielrecht) verlieren durch das Vorziehen
        # ihr Enddatum. Vorher festhalten, damit reset_deactivation_side_effects! sie
        # mit der ursprünglichen Befristung zurückgeben kann statt unbefristet.
        #
        # Der else-Zweig ist kein Beiwerk: die Sicherung muss immer den Stand DIESES
        # Vorgangs abbilden. Eine ältere, nicht abgeräumte Sicherung würde die
        # Rücknahme sonst auf eine Zugehörigkeit legen, die unbefristet war – genau
        # die Verfälschung, die sie verhindern soll.
        if c['valid_until'].present?
          c[VALID_BEFORE_DEACTIVATION] = { 'valid_until' => c['valid_until'],
                                           'valid_set_by' => c['valid_set_by'] }
        else
          c.delete(VALID_BEFORE_DEACTIVATION)
        end
        c['valid_until'] = Time.now
        c['valid_set_by'] = user_id
      end
      c
    end

    licenses.each do |license|
      last_status = license['history']&.last&.dig('license_status_id').to_i
      next unless last_status.in?([License::APPROVED, License::REQUESTED])

      license['history'] << {
        'license_status_id' => License::DELETED,
        'reason' => reason,
        'created_by' => user_id,
        'created_at' => Time.now
      }
    end
  end

  # Loescht die Deaktivierungs-Kennzeichnung ohne zu speichern; der Aufrufer schreibt
  # das Profil ohnehin.
  #
  # Aufgerufen von jedem Weg, der eine neue Vereinszugehoerigkeit anlegt: Wer gerade
  # aufgenommen wird, ist in diesem Verein aktiv, und die Kennzeichnung des
  # abgebenden Vereins wuerde die Spielerliste des aufnehmenden leer aussehen lassen.
  # Der Fall ist erst seit api#472 erreichbar — vorher lehnten Transferantrag und
  # Direktzuweisung ein deaktiviertes Profil ab.
  #
  # `deactivation_reason` bleibt stehen, wie schon bei `reactivate!`: der Grund ist
  # Historie, die Kennzeichnung ist der Zustand.
  def clear_deactivation
    # Eine zusammengefuehrte Dublette bleibt gekennzeichnet (api#486): Sie ist
    # nur deshalb deaktiviert, weil merge_into! sie ersetzt hat, und genau darauf
    # verlaesst sich der Merge -- ohne die Kennzeichnung stuende sie wieder als
    # aktives Mitglied in der Vereinsspielerliste und in der Auswahl beim
    # Lizenzantrag, neben dem fuehrenden Profil. PlayersController#reactivate
    # lehnt sie aus demselben Grund ausdruecklich ab.
    #
    # Der Aufruf tut hier still nichts, wie bei einem nicht deaktivierten Profil:
    # Die Aufnahme selbst abzulehnen waere die deutlichere Aussage, wuerde aber
    # das Verhalten der drei Aufnahmewege aendern, und ueber die Oberfläche ist
    # der Fall nicht erreichbar (die Spielersuche filtert merged_into_id).
    return false if merged_into_id.present?
    return false if deactivated_at.blank?

    self.deactivated_at = nil
    self.deactivated_by = nil
    true
  end

  # Die Heimat-Zugehoerigkeiten, die heute noch laufen -- die eine Definition von "offen"
  # fuer alle, die sie brauchen (Merge, Wartungslauf, Berichte).
  #
  # `valid_until.blank?` allein waere zu eng: `home_club_hash` laesst auch ein Ende in der
  # ZUKUNFT als laufend gelten. Zwei so gelagerte Eintraege sind fuer den Leser zwei offene
  # Heimatvereine, waeren aber an einer blank?-Pruefung vorbeigelaufen -- genau der
  # Widerspruch, den es hier zu beseitigen gilt, haette in dieser Form ueberlebt.
  #
  # Eigene Auswertung statt `home_club_hash`, weil der Merge auf einem noch nicht
  # gespeicherten Array arbeitet und nicht auf `self.clubs`.
  def self.open_home_club_entries(entries)
    Array(entries).select do |c|
      next false unless c.is_a?(Hash)
      next false unless ActiveModel::Type::Boolean.new.cast(c['home_club'])

      c['valid_until'].blank? || _ende_in_der_zukunft?(c['valid_until'])
    end
  end

  def self._ende_in_der_zukunft?(valid_until)
    Date.parse(valid_until.to_s) >= Date.current
  rescue ArgumentError, TypeError
    # Unlesbares Altdatum: nicht als laufend werten. Sonst wuerde der Merge einen Eintrag
    # schliessen, den kein Leser ohnehin als Heimat anerkennt.
    false
  end

  def open_home_club_entries
    self.class.open_home_club_entries(clubs)
  end

  private

  # Entfernt die DELETED-Eintraege, die `deactivate!` bis api#472 an jede laufende
  # Lizenz gehaengt hat. Erkennungsmerkmal ist das Tripel aus Status, Grund und
  # verfuegender Person: nur der oberste Eintrag, nur DELETED, nur mit einem Grund aus
  # der Auswahl (oder einem freien "Sonstiges: …") und nur von derselben Person, die
  # deaktiviert hat. Eine regulaere Loeschung durch die SBK traegt einen anderen Grund
  # und bleibt damit stehen.
  def pop_deactivation_license_entries!
    system_reasons = DEACTIVATION_REASONS + LEGACY_DEACTIVATION_REASONS
    popped = false

    licenses.each do |license|
      last = license['history']&.last
      next unless last &&
                  last['license_status_id'].to_i == License::DELETED &&
                  (system_reasons.include?(last['reason']) || last['reason']&.start_with?('Sonstiges: ')) &&
                  last['created_by'] == deactivated_by

      license['history'].pop
      popped = true
    end

    popped
  end

  # Nimmt einer Zugehörigkeit das von deactivate! gesetzte Ende wieder ab: entweder
  # zurück auf die ursprüngliche Befristung oder, wenn es keine gab, wieder unbefristet.
  #
  # Ohne den gesicherten Wert entfällt die Befristung – so verhielt es sich für alle
  # Profile, die vor der Einführung von VALID_BEFORE_DEACTIVATION deaktiviert wurden.
  def restore_membership_validity(membership)
    previous = membership.delete(VALID_BEFORE_DEACTIVATION)

    if previous.is_a?(Hash) && previous['valid_until'].present?
      membership['valid_until'] = previous['valid_until']
      if previous['valid_set_by'].present?
        membership['valid_set_by'] = previous['valid_set_by']
      else
        membership.delete('valid_set_by')
      end
    else
      membership.delete('valid_until')
      membership.delete('valid_set_by')
    end
  end

  # true, wenn die Zugehoerigkeit am Stichtag abgelaufen war.
  #
  # Ein unlesbares Datum aus dem Altbestand ("unbekannt", "0000-00-00") war bisher kein
  # Sonderfall: Date.parse brach ab, und jeder Leser darueber endete im 500er.
  #
  # Solche Eintraege gelten jetzt als abgelaufen — dieselbe Richtung wie
  # `LicenseAccessScope#membership_current?`, und die vorsichtige: Ein kaputtes Datum
  # darf keine Zustaendigkeit begruenden. Wuerde es als laufend gelten, machte es den
  # Verein ueber `home_club_entry` zum Heimatverein und damit dessen SBK zustaendig
  # (`sbk_can_access_player?`, `sbk_may_move_player?`) und zum abgebenden Verein eines
  # Transferantrags. Aus einem lauten 500er wuerde eine stille Falschzustaendigkeit.
  #
  # Gemeldet wird der Fall trotzdem, sonst verschwindet er ganz: einmal pro Tag und
  # Spieler, wie es `report_license_data_defect` haelt.
  def valid_time?(time, deadline)
    # blank?, nicht nil?: Ein leeres valid_until heisst im Bestand "kein Ende" und wird
    # von jedem Geschwistercode so gelesen (membership_current?, MembershipCloser, dem
    # Legacy-Backfill). Mit nil? galte es als unlesbar und damit als abgelaufen -- das
    # Profil haette keinen Heimatverein mehr und taeglich eine Sentry-Meldung.
    return false if time.blank?

    Date.parse(time.to_s) < deadline
  rescue ArgumentError, TypeError => e
    # Date::Error erbt von ArgumentError und ist damit mitgefangen.
    report_membership_date_defect(time, e)
    true
  end

  def report_membership_date_defect(time, error)
    # `sbk_can_undo_deactivation?` schickt eine bewusst id-lose Kopie (`player.dup`) durch
    # diesen Pfad. Ohne den Riegel kollabierte der Cache-Key auf einen globalen und
    # drosselte danach alle Faelle, und die Meldung nennte keinen Spieler.
    return if id.nil?
    return unless Rails.cache.write("player_membership_date_defect/#{id}", true,
                                    unless_exist: true, expires_in: 1.day)

    message = "Spieler##{id}: valid_until ist unlesbar (#{time.inspect}), " \
              "Zugehoerigkeit gilt als abgelaufen — #{error.class}"
    Rails.logger.error(message)
    Sentry.capture_message(message) if defined?(Sentry)
  end

  def select_license(licenses)
    licenses.map! do |license|
      last_status = license['history']&.last
      last_status ? license.merge(last_status) : license
    end

    # Höchste Liga (kleinstes 'sorting') = Hauptlizenz (Anzeige-Konzept, nicht
    # die manuelle Erst-/Zweitlizenz-Zuordnung gf_role); bei gleicher Ligastufe
    # die zeitlich früher genehmigte Lizenz.
    sorted = licenses.sort_by { |x| [x['sorting'], License.approval_time(x)] }
    sorted.first
  end

  def other_licenses(licenses)
    selected = select_license(licenses)

    licenses.reject { |l| l['id'] == selected['id'] }
  end

  private

  # `is_a?(String)` und nicht `present?`: Ein Name aus ausschließlich
  # Leerzeichen ist nicht `present?` und bliebe damit genau in dem Zustand
  # stehen, der am dringendsten normalisiert werden muss — unsichtbar gefüllt,
  # über keinen Namen findbar.
  def strip_names
    self.first_name = first_name.strip if first_name.is_a?(String)
    self.last_name = last_name.strip if last_name.is_a?(String)
  end

  def nation_id_is_positive
    errors.add(:nation_id, 'muss größer als 0 sein') unless nation_id.to_i > 0
  end

  # Clubs des Secondary auf den Master übernehmen: alle Master-Einträge behalten,
  # vom Secondary nur ergänzen, was nicht bereits durch denselben aktiven Club
  # abgedeckt ist. deep_dup entkoppelt die Hashes von der Secondary.
  def _merge_clubs(secondary_clubs, master_clubs, user_id = nil)
    secondary_clubs = (secondary_clubs || []).map(&:deep_dup)
    master_clubs    = (master_clubs || []).map(&:deep_dup)

    master_active_club_ids = master_clubs
                             .select { |c| c['valid_until'].nil? }
                             .map { |c| c['club_id'] }
                             .to_set
    additional = secondary_clubs.reject do |c|
      c['valid_until'].nil? && master_active_club_ids.include?(c['club_id'])
    end

    # club_id als zweiter Schluessel: sort_by ist in Ruby nicht als stabil zugesichert, und
    # Eintraege ohne created_at (Altdaten-Import) teilen sich denselben Schluessel. Ohne
    # Tiebreaker haenge die Auswahl an der Implementierung.
    sortiert = (master_clubs + additional).sort_by { |c| [c['created_at'].to_s, c['club_id'].to_i] }
    _close_surplus_home_clubs(sortiert, user_id)
  end

  # Nach dem Zusammenfuehren darf hoechstens ein Heimatverein offen sein.
  #
  # Die Entdoppelung darueber greift nur bei DEMSELBEN Verein. Zwei verschiedene offene
  # Heimatvereine -- einer vom Master, einer von der Dublette -- ueberlebten beide, und
  # danach widersprachen sich die Leser: `home_club` nimmt den letzten, der Transferantrag
  # bestimmte den abgebenden Verein als ersten. Stand 18.08.2026 trugen 239 der 1231
  # Merge-Ziele auf Produktion diesen Zustand, also fast jedes fuenfte.
  #
  # Behalten wird der zuletzt begonnene Eintrag: Der Merge fuehrt zwei Aufzeichnungen
  # derselben Person zusammen, und aktuell ist die juengere Zugehoerigkeit. Eintraege ohne
  # `created_at` (Altdaten-Import) sortieren dabei nach vorn und verlieren gegen einen
  # datierten -- gewollt, denn ein undatierter Eintrag stammt aus einem Bestand, der vor
  # allem Datierten liegt.
  def _close_surplus_home_clubs(entries, user_id)
    offen = self.class.open_home_club_entries(entries)
    return entries if offen.size < 2

    offen[0..-2].each do |c|
      c['valid_until']  = Time.now
      c['valid_set_by'] = user_id if user_id
    end
    entries
  end

  # Lizenzen zusammenführen: bei gleichem team_id UND season_id die History-Arrays
  # mergen (dedupliziert), sonst als eigenständige Lizenz anhängen. Unterschiedliche
  # Saisons desselben Teams bleiben getrennte Einträge.
  def _merge_licenses(secondary_licenses, master_licenses)
    result = (master_licenses || []).map(&:deep_dup)

    (secondary_licenses || []).map(&:deep_dup).each do |lic|
      existing = result.find do |l|
        l['team_id'].to_s == lic['team_id'].to_s && l['season_id'].to_s == lic['season_id'].to_s
      end
      if existing
        existing['history'] = ((existing['history'] || []) + (lic['history'] || []))
                              .uniq { |h| [h['created_at'].to_s, h['license_status_id'].to_s] }
                              .sort_by { |h| h['created_at'].to_s }
      else
        result << lic
      end
    end

    result
  end

  # Referenzen in Spielen (players, starting_players, awards – Hash- und
  # Legacy-Array-Format) von der Secondary auf den Master umschreiben.
  # Events referenzieren Spieler über die Trikotnummer und werden durch das
  # Umschreiben von players automatisch korrekt aufgelöst.
  def _rewrite_player_game_references(master_id)
    secondary_id = id

    Game.referencing_player(secondary_id).find_each do |game|
      changed = false

      %w[home guest].each do |side|
        game.players&.dig(side)&.each do |p|
          next unless p['player_id'] == secondary_id

          p['player_id'] = master_id
          changed = true
        end
      end

      changed = _rewrite_position_map(game.starting_players, secondary_id, master_id) || changed
      changed = _rewrite_position_map(game.awards, secondary_id, master_id) || changed

      game.save!(validate: false) if changed
    end
  end

  # starting_players/awards liegen entweder als {"home" => {"goal" => id, ...}}
  # (Normalformat) oder als {"home" => [{"player_id" => id, ...}]} (Legacy) vor.
  def _rewrite_position_map(container, old_id, new_id)
    return false if container.blank?

    changed = false
    %w[home guest].each do |side|
      entry = container[side]
      next if entry.blank?

      if entry.is_a?(Hash)
        entry.each do |key, value|
          next unless value == old_id

          entry[key] = new_id
          changed = true
        end
      elsif entry.is_a?(Array)
        entry.each do |e|
          next unless e.is_a?(Hash) && e['player_id'] == old_id

          e['player_id'] = new_id
          changed = true
        end
      end
    end
    changed
  end

  def _blank_security_id?(value)
    value.blank? || value == PLACEHOLDER_SECURITY_ID
  end

  # Kommen self und master gemeinsam in mindestens einer Aufstellung vor? Dann
  # würde ein Merge einen doppelten player_id-Eintrag im selben Spiel erzeugen.
  def _shares_game_with?(master)
    shared = Game.referencing_player(id).to_a & Game.referencing_player(master.id).to_a
    shared.any? { |game| game.player_in_lineup?(id) && game.player_in_lineup?(master.id) }
  end

  # Alle Kind-Datensätze mit player_id-Fremdschlüssel auf den Master umhängen.
  # Gibt die Verknüpfungen zurück, die wegen Unique-Index-Kollision am Secondary
  # verbleiben mussten (aktiver Transfer-Antrag, identisches Lizenzdokument).
  def _repoint_player_associations(master_id)
    secondary_id = id

    Transfer.where(player_id: secondary_id).update_all(player_id: master_id)
    PlayerChangeRequest.where(player_id: secondary_id).update_all(player_id: master_id)
    PlayerSuspension.where(player_id: secondary_id).update_all(player_id: master_id)

    _repoint_transfer_requests(secondary_id, master_id) +
      _repoint_license_documents(secondary_id, master_id)
  end

  ACTIVE_TRANSFER_REQUEST_STATUSES = %w[pending_club pending_player pending_lv scheduled].freeze

  def _repoint_transfer_requests(secondary_id, master_id)
    scope = TransferRequest.where(player_id: secondary_id)
    scope.where.not(status: ACTIVE_TRANSFER_REQUEST_STATUSES).update_all(player_id: master_id)

    # Partieller Unique-Index: höchstens ein aktiver Antrag pro Spieler.
    master_has_active = TransferRequest.where(player_id: master_id,
                                              status: ACTIVE_TRANSFER_REQUEST_STATUSES).exists?
    skipped = []
    scope.where(status: ACTIVE_TRANSFER_REQUEST_STATUSES).find_each do |tr|
      if master_has_active
        Rails.logger.warn(
          "merge_into!: aktiver Transfer-Antrag ##{tr.id} bleibt bei Spieler ##{secondary_id} " \
          "(Master ##{master_id} hat bereits einen aktiven Antrag)"
        )
        skipped << { type: 'transfer_request', id: tr.id }
        next
      end

      tr.update_columns(player_id: master_id)
      master_has_active = true
    end
    skipped
  end

  def _repoint_license_documents(secondary_id, master_id)
    existing = LicenseDocument.where(player_id: master_id)
                              .pluck(:license_id, :document_type).to_set
    skipped = []
    LicenseDocument.where(player_id: secondary_id).find_each do |doc|
      key = [doc.license_id, doc.document_type]
      if existing.include?(key)
        Rails.logger.warn(
          "merge_into!: Lizenzdokument ##{doc.id} bleibt bei Spieler ##{secondary_id} " \
          "(Master ##{master_id} hat ein identisches Dokument)"
        )
        skipped << { type: 'license_document', id: doc.id }
        next
      end

      doc.update_columns(player_id: master_id)
      existing << key
    end
    skipped
  end
end
