class Referee < ApplicationRecord
  # Wird mit der Gespann-Historie ausgeliefert und gehört in der UI sichtbar an
  # die Auswertung: Es gibt bewusst keine Saison-Untergrenze, dafür muss die
  # eingeschränkte Belastbarkeit der Altdaten benannt sein.
  PARTNER_HISTORY_NOTICE = 'Gezählt werden ausschließlich tatsächliche Einsätze laut Spielbericht. ' \
                           'Für zurückliegende Saisons sind die Zuordnungen nicht lückenlos, ' \
                           'die Gesamtzahlen sind dort entsprechend nur eingeschränkt belastbar.'.freeze

  belongs_to :game_operation, optional: true
  belongs_to :club, optional: true
  has_one :user
  has_many :referee_availabilities, dependent: :destroy
  has_many :referee_qualifications, dependent: :destroy
  has_many :referee_taggings, dependent: :destroy
  has_many :referee_club_exclusions, dependent: :destroy
  has_many :referee_club_exclusion_requests, dependent: :destroy
  has_many :referee_change_requests, dependent: :destroy
  has_many :game_day_referee_confirmations, dependent: :destroy
  has_many :referee_qualification_types, through: :referee_qualifications
  has_many :referee_tags, through: :referee_taggings
  # Beobachtungsbögen, die diese Person als Schiedsrichtercoach geschrieben hat.
  # dependent: :destroy wie bei allen Schiri-Anhängen – dabei verschwinden auch
  # die Rückmeldungen, die dieser Coach ÜBER ANDERE geschrieben hat. Das Löschen
  # eines Schiedsrichters ist Admin/FD-RSK vorbehalten und für Fehlanlagen
  # gedacht; für den Regelfall zweier Profile derselben Person zieht
  # merge_into! die Bögen stattdessen auf das Masterprofil um.
  has_many :referee_observations, foreign_key: :coach_id, inverse_of: :coach, dependent: :destroy
  # Bewertungen, die diese Person als beobachtete Schiedsrichterin bzw.
  # beobachteter Schiedsrichter erhalten hat.
  has_many :referee_observation_ratings, dependent: :destroy

  validates :lizenznummer,
            uniqueness: { allow_nil: true },
            numericality: { only_integer: true, greater_than: 0, allow_nil: true }
  validates :lizenznummer, presence: true, unless: :guest?
  validates :vorname, presence: true
  validates :nachname, presence: true
  validates :partner_lizenznummer,
            numericality: { only_integer: true, greater_than: 0, allow_nil: true }

  after_save :sync_partner_lizenznummer, if: :saved_change_to_partner_lizenznummer?

  def lizenznummer_display
    guest? ? "G-#{id}" : lizenznummer.to_s
  end

  def landesverband
    club&.state_association&.name
  end

  # Kürzel des Landesverbands für Listenspalten. Nullable in der Datenbank,
  # deshalb muss die Anzeige auf den vollen Namen zurückfallen können.
  def landesverband_short_name
    club&.state_association&.short_name
  end

  # :active | :lapsed | :career_ended | :unknown. Für Listen den Stichtag einmal
  # berechnen und durchreichen, statt ihn je Datensatz neu zu ermitteln.
  def license_status(cutoff = self.class.career_end_cutoff)
    return :unknown if gueltigkeit.blank?
    return :active if gueltigkeit >= Date.current
    return :career_ended if gueltigkeit < cutoff

    :lapsed
  end

  def career_ended?(cutoff = self.class.career_end_cutoff)
    license_status(cutoff) == :career_ended
  end

  # Karriere-Ende: vier Lizenzjahre ohne Lizenz, danach ist der Grundkurs fällig
  # (FD-Regel). Gezählt wird in Lizenzjahren, nicht in Tagen ab Ablaufdatum —
  # wessen Lizenz beim Saisonstart vor vier Jahren schon abgelaufen war, hatte
  # vier volle Lizenzjahre keine. Für die Saison 2026/2027 ist die Grenze der
  # 01.08.2022; die Kohorte mit Ablauf 31.07.2022 (Kursjahr 2021) fällt damit
  # hinein, die mit Ablauf 30.09.2023 (Kursjahr 2022) noch nicht.
  #
  # Der Stichtag hängt bewusst an der aktiven Saison und nicht am Kalender: Der
  # Saisonwechsel wird manuell ausgeführt und kann vorgezogen werden, die
  # Neubewertung folgt ihm dann ohne Zutun.
  CAREER_END_LICENSE_YEARS = 4

  def self.career_end_cutoff(season_start_year = Setting.current_season_start_year)
    Date.new(season_start_year - CAREER_END_LICENSE_YEARS, 8, 1)
  end

  # Gemerkte Dubletten gehören in keine dieser Auswertungen: Nach einem Merge
  # bleibt der aufgelöste Datensatz mitsamt Lizenznummer bestehen.
  scope :canonical, -> { where(merged_into_id: nil) }
  scope :active, -> { canonical.where('gueltigkeit >= ?', Date.current) }
  # Karriere beendet. Datensätze ohne Ablaufdatum fallen NICHT hierunter, die
  # sind ein eigener Zustand (#without_license_proof) — für die Sichtbarkeit
  # werden beide gleich behandelt, fachlich sind sie es nicht.
  scope :career_ended, -> { canonical.where(gueltigkeit: ...career_end_cutoff) }
  # Nachweisbar im Fenster: Ablaufdatum vorhanden UND jünger als der Stichtag.
  # Für Auswertungen, die einen Lizenznachweis verlangen.
  scope :in_career_window, -> { canonical.where(gueltigkeit: career_end_cutoff..) }
  # Der Filter für alle Sichten: alles außer den Beendeten, also MIT den
  # Datensätzen ohne Ablaufdatum.
  #
  # Ohne Ablaufdatum ist ein eigener Zustand, nicht „beendet": Ein frisch
  # angelegter Schiedsrichter hat noch keine Gültigkeit, bis das erste
  # Kursergebnis kommt. Zählte man ihn zu den Beendeten, verschwände er sofort
  # nach dem Anlegen aus der Verwaltungsliste, aus der Vereinsliste und aus der
  # Namenssuche des Spielberichts — also genau dann, wenn er gebraucht wird.
  scope :not_career_ended, lambda {
    canonical.where(gueltigkeit: career_end_cutoff..).or(canonical.where(gueltigkeit: nil))
  }
  # Abgelaufen, aber noch keine vier Lizenzjahre her: Fortbildung genügt.
  scope :lapsed, -> { canonical.where(gueltigkeit: career_end_cutoff...Date.current) }
  scope :without_license_proof, -> { canonical.where(gueltigkeit: nil) }
  scope :by_landesverband, lambda { |lv|
    joins(club: :state_association).where(state_associations: { name: lv })
  }
  # Ein Eingabefeld, zwei Quellen: die Lizenzstufe des Schiedsrichters und seine
  # Zusatzqualifikationen. Wer nach „Beobachter" sucht, meint dieselbe Spalte der
  # Verwaltungsliste wie jemand, der „A" eingibt — ein zweites Filterfeld dafür
  # wäre nur eine weitere Stelle, an der man den Namen exakt treffen muss.
  #
  # Stufe, Kürzel und Qualifikationsname werden ganz verglichen (case-insensitiv).
  # Ab drei Zeichen zählt beim Namen zusätzlich der Wortanfang, damit „Beobacht"
  # reicht. Kürzere Eingaben bleiben bewusst exakt: Lizenzstufen sind ein bis zwei
  # Zeichen lang, und ein Präfix-Treffer auf „A" holte sonst jeden „Ausbilder" in
  # die Liste der A-Schiedsrichter.
  scope :by_lizenzstufe, lambda { |stufe|
    value = stufe.to_s.strip
    return all if value.blank?

    name_match = if value.length >= 3
                   'LOWER(referee_qualification_types.name) LIKE :prefix'
                 else
                   'LOWER(referee_qualification_types.name) = :exact'
                 end
    qualified = RefereeQualification
                .joins(:referee_qualification_type)
                .where(
                  "LOWER(referee_qualification_types.short_name) = :exact OR #{name_match}",
                  exact: value.downcase,
                  prefix: "#{Referee.sanitize_sql_like(value.downcase)}%"
                )
                .select(:referee_id)

    where('LOWER(referees.lizenzstufe) = ?', value.downcase).or(where(id: qualified))
  }

  # Schiedsrichtercoaches (Beobachter): gültige Zusatzqualifikation „B…" am
  # Stichtag. Bewusst ein Präfix-Vergleich und kein Flag – der Katalog der
  # Qualifikationstypen wird administrativ gepflegt und führt neben „B" auch
  # „B-Coach" und „Beobachter".
  #
  # Ein leeres valid_until galt bis api#585 als unbefristet. Seit die Gültigkeit
  # Pflichtfeld ist (RefereeQualification), gibt es diese Bedeutung nicht mehr:
  # Eine Zeile ohne Datum ist kein Dauerauftrag, sondern ein Altbestand, der mit
  # `referees:backfill_qualification_valid_until` bereinigt wurde. Sie zählt
  # deshalb nicht mehr mit – sonst wäre das Weglassen des Datums der bequemere
  # Weg zu einer nie ablaufenden Beobachterberechtigung als das Datum selbst.
  #
  # Einzige Definition dieser Gruppe; die Ansetzung (available_coaches) und die
  # Beobachtungsbögen (RefereeObservationPolicy) fragen beide hier.
  scope :coach_qualified, lambda { |date = Date.current|
    joins(referee_qualifications: :referee_qualification_type)
      .where('referee_qualification_types.name LIKE ?', 'B%')
      .where('referee_qualifications.valid_until >= ?', date)
      .distinct
  }
  scope :search, lambda { |q|
    tokens = q.to_s.strip.split(/\s+/).reject(&:empty?).first(5)
    return none if tokens.empty?

    # Reine Zahl → exakte Lizenznummer-Suche
    return where(lizenznummer: tokens[0].to_i) if tokens.size == 1 && tokens[0].match?(/\A\d+\z/)

    # Jeder Token muss in vorname, nachname oder lizenznummer vorkommen –
    # dadurch matchen Multi-Wort-Queries wie "Max Müller" auch, wenn Vor-
    # und Nachname in separaten Spalten stehen.
    tokens.reduce(all) { |relation, token| relation.where(*Referee.token_condition(token)) }
  }

  # Ein Name und seine Ersatzschreibweise sollen denselben Treffer liefern:
  # "Schröder", "Schroeder" und "Schroder" ebenso wie "Müller" und "Mueller".
  # Vorher fand die Suche nur die exakte Schreibweise; `Schroder` lieferte null
  # Treffer, obwohl `Schröder` neun hat. Aufgefallen bei der Aufarbeitung des
  # Spieltags in Wernigerode am 30.08.2026, wo ein Schiedsrichter nicht in den
  # Spielbericht kam.
  UMLAUT_TO_BASE = { 'ß' => 'ss', 'ä' => 'a', 'ö' => 'o', 'ü' => 'u' }.freeze

  # Nur für die Anfrage, nicht für die Spalte (Begründung an folded_sql).
  DIGRAPH_TO_UMLAUT = { 'ae' => 'ä', 'oe' => 'ö', 'ue' => 'ü', 'ss' => 'ß' }.freeze
  UMLAUT_TO_DIGRAPH = { 'ä' => 'ae', 'ö' => 'oe', 'ü' => 'ue', 'ß' => 'ss' }.freeze

  # Kürzere abgeleitete Formen prüft die Suche nicht mit. Der Grund ist "ae":
  # Digraph→Umlaut macht daraus "ä", entfaltet "a" -- und ein LIKE auf "%a%"
  # liefert praktisch den ganzen Bestand. Ab drei Zeichen bleibt genug Kontext,
  # dass die Zusatzform eine Suche und keine Sammelabfrage ist.
  MIN_DERIVED_FORM_LENGTH = 3

  def self.fold_umlauts(value)
    UMLAUT_TO_BASE.reduce(value.to_s.downcase) { |acc, (from, to)| acc.gsub(from, to) }
  end

  # Die Schreibweisen, unter denen ein Suchwort die entfaltete Spalte treffen
  # darf. Drei, und jede deckt einen eigenen Bestandsfall ab:
  #
  #   1. das Wort selbst, entfaltet          -- Bestand "Schröder", Eingabe egal
  #   2. Digraph→Umlaut, dann entfaltet      -- Bestand "Müller",   Eingabe "Mueller"
  #   3. Umlaut→Digraph, dann entfaltet      -- Bestand "Schroeder", Eingabe "Schröder"
  #
  # Form 3 kam nach dem Review dazu. Ohne sie blieb die Gegenrichtung offen: Ein
  # in Ersatzschreibweise erfasster Name (in Altimporten häufig) war mit Umlaut
  # nicht zu finden -- also derselbe Fehlschlag wie der gemeldete, nur mit
  # vertauschten Rollen.
  #
  # Nicht abgedeckt bleibt Bestand "Schroeder" mit Eingabe "Schroder": Das wäre
  # eine dritte Schreibweise, und sie einzufangen ginge nur über die Spalte, mit
  # dem Rauschen, das folded_sql beschreibt.
  def self.search_forms(token)
    plain = token.to_s.downcase
    derived = [
      DIGRAPH_TO_UMLAUT.reduce(plain) { |acc, (from, to)| acc.gsub(from, to) },
      UMLAUT_TO_DIGRAPH.reduce(plain) { |acc, (from, to)| acc.gsub(from, to) }
    ]

    forms = [fold_umlauts(plain)]
    forms += derived.map { |form| fold_umlauts(form) }
                    .select { |form| form.length >= MIN_DERIVED_FORM_LENGTH }
    forms.uniq
  end

  # Die Spalte wird nur entfaltet (ö → o), der Digraph bleibt außen vor. Sonst
  # fielen gespeicherte Namen zusammen, die nichts miteinander zu tun haben:
  # "Joel" mit "Jol", "Neuer" mit "Nur". Diese Richtung übernimmt die Anfrage
  # über search_forms.
  #
  # Ehrlich dazugesagt: Damit wandert das Rauschen von der Spalte auf die
  # Anfrage, es verschwindet nicht. Wer "Neuer" sucht, sieht auch "Neurath".
  # Der Unterschied ist, dass die Anfrage eine Wahl hat -- sie prüft die
  # Grundform IMMER mit, der eigentliche Treffer geht also nie verloren, und die
  # Längengrenze oben hält die Zusatzformen aus dem Sammelabfrage-Bereich.
  #
  # `column` kommt ausschließlich aus dem Literalpaar unten, nicht aus Parametern.
  def self.folded_sql(column)
    "translate(replace(lower(#{column}), 'ß', 'ss'), 'äöü', 'aou')"
  end

  # [sql, binds] für ein Suchwort: entfalteter Vor- oder Nachname in einer der
  # Schreibweisen, oder die Lizenznummer (die keine Umlaute kennt).
  #
  # `sanitize_sql_like` wie in by_lizenzstufe: Ohne die Maskierung wäre ein `%`
  # oder `_` in der Eingabe ein Suchmuster und keine Suche.
  def self.token_condition(token)
    binds = { lizenz: "%#{sanitize_sql_like(token.downcase)}%" }
    clauses = ['lizenznummer::text LIKE :lizenz']

    search_forms(token).each_with_index do |form, index|
      key = :"form#{index}"
      binds[key] = "%#{sanitize_sql_like(form)}%"
      clauses << "#{folded_sql('vorname')} LIKE :#{key}"
      clauses << "#{folded_sql('nachname')} LIKE :#{key}"
    end

    [clauses.join(' OR '), binds]
  end

  # Spiele dieses Schiris. Kanonisch über die stabile Referee-PK in
  # officiating_referee_ids (Fundament #45), sodass auch Gäste (ohne Lizenznummer)
  # und nach einem Merge verschobene Lizenzen stabil zugeordnet bleiben.
  # referee_ids (Lizenznummer) und die Bericht-Strings dienen als Übergangs-
  # Fallback, bis der Backfill (rake referees:backfill_officiating_ids) alle
  # Alt-Spiele rückbefüllt hat.
  def games(season_id: nil)
    conditions = ['? = ANY(officiating_referee_ids)']
    values = [id]

    if lizenznummer.present?
      license_prefix = "#{lizenznummer} %"
      conditions.push('? = ANY(referee_ids)', 'referee1_string LIKE ?', 'referee2_string LIKE ?')
      values.push(lizenznummer, license_prefix, license_prefix)
    end

    scope = Game.where(conditions.join(' OR '), *values)
    scope = scope.joins(game_day: :league).where(leagues: { season_id: season_id }) if season_id
    scope
  end

  # Gespann-Historie: mit wem dieser Schiri tatsächlich im Einsatz war, über
  # alle Saisons. Identische Aggregation für die RSK-/Ansetzer-Sicht
  # (admin/referees/:id/partners) und die Eigensicht (referee/history/partners),
  # die sich nur im Zugriffs-Scope unterscheiden.
  def partner_history
    {
      referee: {
        id: id,
        vorname: vorname,
        nachname: nachname,
        lizenznummer_display: lizenznummer_display
      },
      season_id: Setting.current_season_id.to_i,
      notice: PARTNER_HISTORY_NOTICE,
      partners: partner_stats
    }
  end

  # Basis sind ausschließlich die tatsächlichen Einsätze laut Spielbericht
  # (officiating_referee_ids, Referee-PK, Fundament #45), nicht die Ansetzung
  # (RefereeAssignment), weil kurzfristige Umbesetzungen die Zahlen sonst
  # verzerren. Die Lizenznummer-/Freitext-Fallbacks aus #games bleiben bewusst
  # außen vor: sie liefern keine Partner-PK und damit kein auflösbares Gespann.
  # Gäste (guest: true) werden nicht als Partner ausgewiesen.
  def partner_stats
    rows = Game.joins(game_day: :league)
               # Containment (@>) statt "= ANY", weil nur dieses Prädikat den
               # GIN-Index auf officiating_referee_ids nutzt. Die Auswertung
               # läuft über die gesamte Historie, nicht nur eine Saison.
               .where('games.officiating_referee_ids @> ARRAY[?]::integer[]', id)
               .pluck(:officiating_referee_ids, 'leagues.season_id', 'leagues.game_operation_id')

    tallies = tally_partner_games(rows)
    return [] if tallies.empty?

    # merged_into_id: nil analog zum active-Scope. merge_into! schreibt
    # officiating_referee_ids zwar auf die Master-PK um, Altdaten und Backfills
    # können aber noch auf ein zusammengeführtes Profil zeigen. Ohne den Filter
    # erschiene dieselbe Person als zweite, scheinbar aktive Zeile im Gespann.
    partners = Referee.where(id: tallies.keys, guest: false, merged_into_id: nil)
                      .includes(:club).index_by(&:id)
    seasons_map = Setting.seasons.to_h { |s| [s[:id], s[:name]] }
    go_names = GameOperation.where(id: tallies.values.flat_map { |t| t[:by_game_operation].keys }.uniq)
                            .pluck(:id, :name).to_h

    result = tallies.filter_map do |partner_id, tally|
      partner = partners[partner_id]
      partner_summary(partner, tally, seasons_map, go_names) if partner
    end

    result.sort_by! do |p|
      [-p[:games_current_season], -p[:games_total], p[:nachname].to_s, p[:vorname].to_s]
    end
    result
  end

  def merge_into!(master, user_id = nil)
    raise ArgumentError, 'Master und Secondary dürfen nicht identisch sein' if id == master.id
    raise ArgumentError, 'Secondary ist bereits zusammengeführt' if merged_into_id.present?
    raise ArgumentError, 'Master ist bereits zusammengeführt' if master.merged_into_id.present?

    merged_label = "#{nachname}, #{vorname}"

    ActiveRecord::Base.transaction do
      scalar_fields = %w[
        vorname nachname geburtsdatum email club_id game_operation_id
        lizenzstufe gueltigkeit strasse hausnummer plz ort
      ]
      scalar_fields.each do |field|
        master[field] = self[field] if master[field].blank? && self[field].present?
      end

      # Falls Master keine Lizenznummer hat, übertrage die der Secondary.
      # Wegen UNIQUE-Index auf lizenznummer muss die Secondary erst geleert werden.
      transferred_lizenznummer = nil
      if master.lizenznummer.blank? && lizenznummer.present?
        transferred_lizenznummer = lizenznummer
        update_columns(lizenznummer: nil)
        master.lizenznummer = transferred_lizenznummer
      end

      master.save!(validate: false)

      existing_qt_ids = master.referee_qualifications.pluck(:referee_qualification_type_id)
      referee_qualifications.where.not(referee_qualification_type_id: existing_qt_ids).update_all(referee_id: master.id)

      existing_tag_ids = master.referee_taggings.pluck(:referee_tag_id)
      referee_taggings.where.not(referee_tag_id: existing_tag_ids).update_all(referee_id: master.id)

      referee_availabilities.update_all(referee_id: master.id)

      # Ausschlussliste und Antragshistorie wandern mit; Dubletten (gleicher
      # Verein bzw. zwei offene Anträge zum selben Verein) fallen weg, sonst
      # bricht der jeweilige Unique-Index.
      # master.club_id gehört dazu: Der eigene Verein steht abgeleitet auf der
      # Liste, eine übernommene Zeile würde ihn doppelt anzeigen (update_all
      # umgeht die Validierung im Modell).
      existing_exclusion_club_ids =
        master.referee_club_exclusions.pluck(:club_id) + [master.club_id].compact
      referee_club_exclusions.where.not(club_id: existing_exclusion_club_ids).update_all(referee_id: master.id)
      referee_club_exclusions.reload.destroy_all

      master_pending_club_ids = master.referee_club_exclusion_requests.pending.pluck(:club_id)
      referee_club_exclusion_requests.pending.where(club_id: master_pending_club_ids).destroy_all
      referee_club_exclusion_requests.reload.update_all(referee_id: master.id)

      # Stammdaten-Korrekturen genauso: Bleiben sie am Zweitprofil, sieht der
      # Schiri seinen offenen Antrag nicht mehr (sein Konto hängt am Master),
      # die RSK könnte ihn aber weiter genehmigen und schriebe den korrigierten
      # Wert auf die tote Zeile. Der Teilindex lässt je Feld nur einen offenen
      # Antrag zu, deshalb fällt der zweite weg.
      master_pending_types = master.referee_change_requests.pending.pluck(:correction_type)
      referee_change_requests.pending.where(correction_type: master_pending_types).destroy_all
      referee_change_requests.reload.update_all(referee_id: master.id)

      # Beobachtungsbögen: Der Coach-Bezug und die erhaltenen Bewertungen wandern
      # aufs Masterprofil, sonst hinge die Entwicklungshistorie am toten
      # Zweitprofil und wäre für die betroffene Person unsichtbar (ihr Konto
      # hängt am Master). Beide Seiten müssen Dubletten überspringen: Hat das
      # Masterprofil zum selben Spiel bereits einen Bogen bzw. im selben Bogen
      # schon eine Bewertung, bricht sonst der jeweilige Unique-Index. Das ist
      # kein theoretischer Fall — bei zwei Profilen derselben Person kann ein
      # Coach beide nacheinander erwischt haben.
      master_observed_game_ids = master.referee_observations.pluck(:game_id)
      referee_observations.where.not(game_id: master_observed_game_ids).update_all(coach_id: master.id)
      referee_observations.reload.destroy_all

      master_rated_observation_ids =
        RefereeObservationRating.where(referee_id: master.id).pluck(:referee_observation_id)
      referee_observation_ratings
        .where.not(referee_observation_id: master_rated_observation_ids)
        .update_all(referee_id: master.id)
      referee_observation_ratings.reload.destroy_all

      if user.present?
        if master.user.nil?
          user.update!(referee_id: master.id)
        else
          user.update!(referee_id: nil)
        end
      end

      _rewrite_referee_game_references(master, secondary_lizenznummer: transferred_lizenznummer || lizenznummer)

      # validate: false – die Secondary kann nach dem Lizenznummern-Transfer
      # die Pflicht-Validierung (Lizenznummer für Nicht-Gäste) nicht mehr erfüllen.
      self.merged_into_id = master.id
      save!(validate: false)

      MergeLog.record!(
        object_type: 'referee',
        master_id: master.id, master_label: "#{master.nachname}, #{master.vorname}",
        merged_id: id, merged_label: merged_label,
        user_id: user_id
      )
    end
  end

  private

  # Zählt je Partner-PK die gemeinsamen Einsätze. Ein Spiel zählt pro Partner
  # genau einmal (uniq), der Schiri selbst wird übersprungen.
  def tally_partner_games(rows)
    current_season = Setting.current_season_id.to_i
    tallies = Hash.new do |hash, key|
      hash[key] = { games_total: 0, games_current_season: 0,
                    last_season_id: nil, by_game_operation: Hash.new(0) }
    end

    rows.each do |officiating_ids, season_id, go_id|
      # leagues.season_id ist eine String-Spalte und muss vor jedem Vergleich
      # bzw. Lookup nach Integer konvertiert werden.
      season = season_id.to_i
      Array(officiating_ids).uniq.each do |partner_id|
        next if partner_id == id

        tally = tallies[partner_id]
        tally[:games_total] += 1
        tally[:games_current_season] += 1 if season == current_season
        tally[:last_season_id] = season if tally[:last_season_id].nil? || season > tally[:last_season_id]
        tally[:by_game_operation][go_id] += 1 if go_id
      end
    end

    tallies
  end

  # Aufschlüsselung nach Spielbetrieb zusätzlich zur Gesamtzahl: Ein Schiri ist
  # oft in mehreren Spielbetrieben im Einsatz, eine auf den eigenen Verband
  # gekürzte Zahl würde die Belastung systematisch unterschätzen.
  def partner_summary(partner, tally, seasons_map, go_names)
    {
      referee_id: partner.id,
      vorname: partner.vorname,
      nachname: partner.nachname,
      lizenznummer_display: partner.lizenznummer_display,
      lizenzstufe: partner.lizenzstufe,
      club_name: partner.club&.name,
      games_current_season: tally[:games_current_season],
      games_total: tally[:games_total],
      last_season_id: tally[:last_season_id],
      last_season_name: seasons_map[tally[:last_season_id]] || tally[:last_season_id].to_s,
      active: partner.gueltigkeit.present? && partner.gueltigkeit >= Date.today,
      game_operations: game_operation_breakdown(tally[:by_game_operation], go_names)
    }
  end

  def game_operation_breakdown(counts, go_names)
    entries = counts.map do |go_id, count|
      { game_operation_id: go_id, game_operation_name: go_names[go_id], game_count: count }
    end
    entries.sort_by { |entry| [-entry[:game_count], entry[:game_operation_name].to_s] }
  end

  def sync_partner_lizenznummer
    return if partner_lizenznummer.blank? || lizenznummer.blank? || partner_lizenznummer == lizenznummer

    partner = Referee.where(lizenznummer: partner_lizenznummer).where(partner_lizenznummer: nil).first
    partner&.update_column(:partner_lizenznummer, lizenznummer)
  end

  def _rewrite_referee_game_references(master, secondary_lizenznummer: lizenznummer)
    if secondary_lizenznummer.present? && master.lizenznummer.present? &&
       secondary_lizenznummer != master.lizenznummer
      Game.where('? = ANY(referee_ids)', secondary_lizenznummer)
          .update_all("referee_ids = array_replace(referee_ids, #{secondary_lizenznummer.to_i}, #{master.lizenznummer.to_i})")

      Game.where('referee1_string LIKE ?', "#{secondary_lizenznummer} %")
          .update_all("referee1_string = REPLACE(referee1_string, '#{secondary_lizenznummer.to_i} ', '#{master.lizenznummer.to_i} ')")
      Game.where('referee2_string LIKE ?', "#{secondary_lizenznummer} %")
          .update_all("referee2_string = REPLACE(referee2_string, '#{secondary_lizenznummer.to_i} ', '#{master.lizenznummer.to_i} ')")
    end

    return unless id != master.id

    Game.where('? = ANY(nominated_referee_ids)', id)
        .update_all("nominated_referee_ids = array_replace(nominated_referee_ids, #{id.to_i}, #{master.id.to_i})")

    Game.where('? = ANY(officiating_referee_ids)', id)
        .update_all("officiating_referee_ids = array_replace(officiating_referee_ids, #{id.to_i}, #{master.id.to_i})")
  end

  public

  def self.incorrect_assignments(season_id: nil)
    scope = Game.where.not(referee1_string: [nil, '']).or(Game.where.not(referee2_string: [nil, '']))
    scope = scope.where(season_id: season_id) if season_id

    known_ids = pluck(:lizenznummer).compact.to_set

    # Process in batches to avoid loading all games into memory at once
    results = []
    scope.in_batches(of: 500) do |batch|
      batch.each do |game|
        unknown = [game.referee1_string, game.referee2_string].any? do |ref_string|
          next false if ref_string.blank?

          match = ref_string.match(/\A(\d+)\s/)
          match && !known_ids.include?(match[1].to_i)
        end
        results << game if unknown
      end
    end
    results
  end
end
