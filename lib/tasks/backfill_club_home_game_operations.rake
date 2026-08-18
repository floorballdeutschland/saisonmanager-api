# lib/tasks/backfill_club_home_game_operations.rake
#
# Setzt den Heimat-Spielbetrieb bei Vereinen, die keinen haben, und füllt dabei
# einen fehlenden Landesverband mit.
#
# Hintergrund: Ohne Heimat-Eintrag im `game_operations_hash` gehört ein Verein
# keinem Verband. Bis 1.68.0 fiel er dadurch aus jeder Vereinsliste und war auch
# nicht bearbeitbar; seither ist er für verbandsübergreifende Rollen sichtbar,
# hat aber weiterhin keinen zuständigen Verband. Stand 08/2026 sind das auf
# Produktion 22 Vereine aus zwei verschiedenen Quellen:
#
#   - 10 Vereine (angelegt 22.05.) mit Landesverband, aber ohne Mannschaften.
#     Es sind die Heimatvereine von Schiedsrichtern aus dem Kursergebnis-Import
#     (Judoschule, Uni, Kegelverein …), keine Floorballvereine.
#   - 12 Vereine (angelegt 24.06.) aus dem Altdaten-Import 2010–2014, ohne
#     Landesverband, aber mit echten Mannschaften in Alt-Ligen.
#
# Beide Quellen brauchen eine andere Ableitung, deshalb zwei Regeln in dieser
# Reihenfolge:
#
#   1. **Aus den eigenen Mannschaften.** Der Spielbetrieb, in dessen Ligen der
#      Verein die meisten Mannschaften hatte — und zwar die **Mehrheit**, nicht
#      bloß die meisten. Nationale Spielbetriebe (FD) zählen dabei nicht: ein
#      Zweitligist bestimmt keinen Heimatverband, sonst landeten alle
#      Bundesligisten beim Bundesverband.
#
#      Die Mehrheit statt der schlichten Mehrzahl, weil eine knappe Mehrzahl
#      nichts belegt: Die Frankfurt Falcons stehen mit 3 Mannschaften in
#      Baden-Württemberg und je 2 in Hessen und Nordrhein-Westfalen — nach
#      Mehrzahl käme für einen Frankfurter Verein Baden-Württemberg heraus.
#      Solche Vereine listet der Task auf, statt zu entscheiden.
#   2. **Aus dem Landesverband.** Der Spielbetrieb, der zu diesem Landesverband
#      gehört; bei einem untergeordneten Verband (Sachsen, Sachsen-Anhalt und
#      Thüringen unter „SBK Ost") der des übergeordneten. Landesverbände ohne
#      eigenen Spielbetrieb siehe SA_WITHOUT_GO_SHORT.
#
# Der Landesverband wird nur gesetzt, wenn keiner hinterlegt ist. Maßgeblich ist
# dann das Bundesland laut Postleitzahl — nicht der Spielbetrieb, denn beides
# fällt auseinander: der SV Eidelstedt (PLZ 22523) spielt im SH-Spielbetrieb,
# gehört aber zum Floorball Bund Hamburg, und der TV Jahn Salzwedel (29416)
# spielt in „SBK Ost", gehört aber nach Sachsen-Anhalt. Dieselbe Regel wie in
# clubs:fix_state_associations. Fehlt die Postleitzahl, gilt der Landesverband
# des ermittelten Spielbetriebs.
#
# `clubs.state` (Bundesland) bleibt unberührt: der Task füllt nur, was für die
# Zuordnung nötig ist. Vereine ohne Bundesland überspringt
# clubs:fix_state_associations deshalb weiterhin.
#
# Report (nie schreibend):
#   bundle exec rails clubs:home_game_operation_report
#
# Dry-Run (Standard) und Ausführen:
#   bundle exec rails clubs:backfill_home_game_operations
#   bundle exec rails clubs:backfill_home_game_operations DRY_RUN=false

# Eigene Klasse statt Methoden im rake-namespace-Block: Letztere landen als
# private Methoden auf Object und ihre Memoisierung überlebt den Task-Lauf —
# Report und Backfill im selben Prozess sähen sonst veraltete Verbände.
class ClubHomeGameOperationResolver
  # Landesverbände, zu denen es keinen eigenen Spielbetrieb gibt, samt dem
  # Spielbetrieb, in dem ihre Vereine tatsächlich spielen.
  #
  # Hamburg ist der einzige Fall: Für den Floorball Bund Hamburg gibt es keine
  # GameOperation, die Hamburger Vereine spielen im Spielbetrieb
  # Schleswig-Holstein (belegt am SV Eidelstedt, 11 von 11 Mannschaften). Das
  # ist eine fachliche Zuordnung und nicht aus den Daten ableitbar, deshalb
  # steht sie hier und wird nicht geraten.
  SA_WITHOUT_GO_SHORT = { 'FBH' => 'FLV-SH' }.freeze

  # Vereine, deren hinterlegter Landesverband nachweislich falsch ist und deren
  # Anschrift die Ableitung nicht hergibt (keine Postleitzahl). Ohne Eintrag hier
  # würde der Task den falschen Landesverband bestätigen, indem er dessen
  # Spielbetrieb setzt.
  #
  # Stand 08/2026 zwei Fälle, beide aus dem Kursergebnis-Import und beide am
  # Landesverband des Nachbarn statt am eigenen (fachlich bestätigt 08/2026):
  #
  #   #284 „UNIcorns Landau"        – steht an Baden-Württemberg, Landau liegt
  #                                   in der Pfalz.
  #   #275 „Fit & Gesund Hechtsheim" – steht an Hessen, Hechtsheim ist ein
  #                                   Mainzer Stadtteil.
  #
  # Zuständig ist in beiden Fällen Rheinland-Pfalz / Saarland.
  #
  # Ein Eintrag greift nur, wenn BEIDES stimmt: die id und ein Merkmal im Namen.
  # Jedes für sich allein trägt nicht.
  #
  # Die id allein nicht, weil sie nur in dem Bestand gilt, für den sie notiert
  # wurde. In einer anderen Datenbank – Entwicklung, Test, ein neu aufgesetzter
  # Bestand – trägt dieselbe Zahl einen beliebigen anderen Verein. In der CI ist
  # genau das passiert: Testvereine ziehen ihre id aus der Sequenz, unter einem
  # unglücklichen Seed wurde einer von ihnen zu „Landau in der Pfalz".
  #
  # Der Name allein auch nicht, denn keiner der Namensteile ist für sich
  # eindeutig: „Landau" gibt es außer in der Pfalz auch an der Isar
  # (Niederbayern) und als Ortsteil von Bad Arolsen (Hessen), „Unicorns" ist ein
  # verbreiteter Vereinsbeiname (Schwäbisch Hall und andere). Ein solcher Verein
  # würde nach Rheinland-Pfalz gezogen – und schlimmer: `resolve_override`
  # überschreibt den hinterlegten Landesverband, hier also einen richtigen.
  #
  # Deshalb verlangt #284 BEIDE Teile. `name_includes` nimmt auch eine Liste, dann
  # müssen alle Einträge vorkommen, je in `name` oder `long_name`. #275 kommt mit
  # dem Ortsnamen aus, „Hechtsheim" gibt es nur als Mainzer Stadtteil.
  #
  # Stimmt die id, aber das Merkmal nicht, greift der Eintrag nicht: Der Verein
  # läuft durch die normale Ableitung, und der Bericht nennt den Eintrag samt dem
  # Namen, den der Verein mit dieser id tatsächlich trägt (`overrides_mismatched`).
  # Das ist der Fall, auf den zu achten ist: Nach einer Umbenennung bestätigt die
  # normale Ableitung wieder den falschen Landesverband, und nur der Hinweis
  # verrät es. Ein „nicht schreiben" statt „normal ableiten" wäre keine Lösung,
  # sondern hinge wieder allein an der id — und damit im Test am Seed.
  #
  # Nicht abgedeckt: Hat der Verein von Hand schon einen Heimat-Spielbetrieb
  # bekommen, steht er nicht mehr auf der Liste, der Eintrag greift nie, und der
  # Bericht schweigt. Ein falscher Landesverband bleibt dann stehen.
  CLUB_OVERRIDES = {
    275 => { sa_short: 'RLPSAAR', name_includes: 'Hechtsheim',
             reason: 'Hechtsheim ist ein Mainzer Stadtteil, nicht Hessen' },
    284 => { sa_short: 'RLPSAAR', name_includes: %w[UNIcorns Landau],
             reason: 'Landau in der Pfalz, nicht Baden-Württemberg' }
  }.freeze

  Result = Struct.new(:club, :game_operation, :state_association, :status, :detail, keyword_init: true)

  # Status, die geschrieben werden. Der Rest ist Prüfliste.
  WRITABLE_STATUSES = %i[from_teams from_sa override].freeze

  def initialize
    @sa_by_id = StateAssociation.all.index_by(&:id)
    @sa_by_short_name = StateAssociation.all.index_by(&:short_name)
    @game_operations = GameOperation.all.to_a
    # Nationale Spielbetriebe sind hier bewusst enthalten: ein Verein am
    # Bundesverband hat „Floorball Deutschland" als Heimat-Spielbetrieb. Nur die
    # Ableitung aus den Mannschaften (game_operation_counts) klammert sie aus.
    @go_by_sa_id = @game_operations.index_by(&:state_association_id)
    @go_by_id = @game_operations.index_by(&:id)
  end

  # Vereine ohne Heimat-Spielbetrieb. `main_game_operation_id` ist die Quelle,
  # die auch die Anwendung liest — nicht eine eigene jsonb-Abfrage, sonst
  # bewertet der Task andere Vereine als betroffen als die Oberfläche.
  def affected_clubs
    Club.order(:id).reject(&:main_game_operation_id)
  end

  # Der Eintrag aus CLUB_OVERRIDES für diesen Verein, falls einer greift.
  def override_for(club)
    override = CLUB_OVERRIDES[club.id]
    override if override && override_fits?(club, override)
  end

  # Alle Merkmale müssen vorkommen, jedes davon in `name` ODER `long_name` — ein
  # Zusatz an einer der beiden Stellen hebelt den Eintrag damit nicht aus.
  #
  # Ein leeres oder fehlendes Merkmal passt auf NICHTS, und zwar auch als leeres
  # Element MITTEN in einer Liste. Ohne diese Prüfung träfe `include?('')` jeden
  # Namen: Ein Eintrag ohne Merkmal fiele still auf reine id-Zuordnung zurück,
  # eine halb nachgezogene Liste (`['UNIcorns', '']`) still auf ein Merkmal — und
  # das trifft dann „Unicorns Schwäbisch Hall". Genau die Sorte Fehler, die dieser
  # Task loswerden soll. Gemeldet würde es auch nicht, denn
  # `overrides_mismatched` fragt dieselbe Methode und bekäme „passt" zu hören.
  #
  # Reiner Leerraum zählt als leer, sonst passte ' ' auf jeden Namen mit
  # Leerzeichen.
  def override_fits?(club, override)
    needles = Array(override[:name_includes]).map { |needle| needle.to_s.strip.downcase }
    return false if needles.empty? || needles.any?(&:empty?)

    candidates = [club.name, club.long_name].compact.map(&:downcase)
    needles.all? { |needle| candidates.any? { |candidate| candidate.include?(needle) } }
  end

  # Einträge, deren Verein die id trägt, aber das Namensmerkmal nicht (oder deren
  # Verein es nicht gibt). Sie greifen nicht, und das muss in der Ausgabe stehen:
  # Nach einer Umbenennung bestätigt die normale Ableitung wieder den falschen
  # Landesverband, und nur dieser Hinweis verrät es.
  #
  # Geprüft wird mit derselben Methode, die auch entscheidet (`override_fits?`),
  # nicht mit einem nachgebauten SQL-Muster: Ein ILIKE-Muster mit `%`, `_` oder
  # abweichender Sortierreihenfolge in der Datenbank würde anders urteilen als der
  # Task, und dann meldet der Bericht das Gegenteil dessen, was passiert.
  #
  # Gesucht wird über alle Vereine mit diesen ids, unabhängig davon, ob sie noch
  # ohne Heimat-Spielbetrieb sind: Nach einem erfolgreichen Lauf wäre der Eintrag
  # sonst fälschlich als wirkungslos gemeldet.
  def overrides_mismatched
    clubs = Club.where(id: CLUB_OVERRIDES.keys).index_by(&:id)

    CLUB_OVERRIDES.filter_map do |club_id, override|
      club = clubs[club_id]
      next if club && override_fits?(club, override)

      # Beide Namensfelder nennen, weil beide verglichen werden: Sonst zieht wer
      # dem Hinweis folgt das Merkmal am falschen Feld nach.
      found = if club
                "heißt \"#{club.name}\", long_name \"#{club.long_name}\""
              else
                'kein Verein mit dieser id'
              end
      expected = Array(override[:name_includes]).map { |needle| "\"#{needle}\"" }.join(' und ')
      "##{club_id} → #{override[:sa_short]} (erwartet #{expected} im Namen, #{found})"
    end
  end

  # Kürzel aus den Tabellen oben, zu denen es keinen Landesverband gibt.
  def missing_short_names
    referenced = SA_WITHOUT_GO_SHORT.keys + SA_WITHOUT_GO_SHORT.values +
                 CLUB_OVERRIDES.values.map { |o| o[:sa_short] }
    referenced.uniq - @sa_by_short_name.keys
  end

  # Landesverbände ohne Spielbetrieb, die in SA_WITHOUT_GO_SHORT fehlen. Ein neu
  # gegründeter Verband ohne eigenen Spielbetrieb liefe sonst still in
  # :no_game_operation, statt hier benannt zu werden.
  def unmapped_state_associations_without_go
    @sa_by_id.values.reject(&:parent_id)
             .reject { |sa| @go_by_sa_id.key?(sa.id) }
             .reject { |sa| SA_WITHOUT_GO_SHORT.key?(sa.short_name) }
  end

  # Statuswerte:
  #   :from_teams     – aus den Ligen der eigenen Mannschaften abgeleitet.
  #   :from_sa        – aus dem hinterlegten Landesverband abgeleitet.
  #   :override       – ausdrücklich zugeordnet (CLUB_OVERRIDES).
  #   :no_majority    – kein Spielbetrieb trägt die Mehrheit der Mannschaften
  #                     (Gleichstand oder knappe Mehrzahl über drei Verbände).
  #   :no_source      – weder Mannschaften noch Landesverband.
  #   :no_go_for_sa   – Landesverband bekannt, aber kein Spielbetrieb dazu.
  #   :unknown_sa_short – ein Kürzel aus CLUB_OVERRIDES gibt es nicht.
  def resolve(club)
    if (override = override_for(club))
      return resolve_override(club, override)
    end

    counts = game_operation_counts(club)
    return resolve_from_teams(club, counts) if counts.any?

    resolve_from_state_association(club)
  end

  # Mannschaften des Vereins je nicht-nationalem Spielbetrieb ihrer Liga.
  # `by_club_id` deckt auch Spielgemeinschaften ab (teams.syndicate_clubs).
  #
  # Gezählt werden Mannschaften, nicht Ligen: Zwei Mannschaften in derselben Liga
  # sind zweimal Aktivität in diesem Verband. Über `leagues.group(...).count`
  # wären sie eine — und `reorder(nil)` bräuchte es dann auch, weil der
  # default_scope von League ein `order('order_key::int')` mitbringt, das
  # `group().count` zerlegt.
  def game_operation_counts(club)
    league_go_ids = League.where(id: Team.by_club_id(club.id).select(:league_id))
                          .reorder(nil).pluck(:id, :game_operation_id).to_h
    Team.by_club_id(club.id).pluck(:league_id)
        .filter_map { |league_id| league_go_ids[league_id] }
        .tally
        .reject { |go_id, _n| @go_by_id[go_id].nil? || @go_by_id[go_id].national }
  end

  private

  def resolve_override(club, override)
    sa = @sa_by_short_name[override[:sa_short]]
    if sa.nil?
      return Result.new(club: club, status: :unknown_sa_short,
                        detail: "Kürzel #{override[:sa_short]} gibt es nicht — #{override[:reason]}")
    end

    # game_operation_for statt @go_by_sa_id: Sonst fehlten dem Override die
    # Vererbung an den Dachverband (Sachsen/Sachsen-Anhalt/Thüringen unter „SBK
    # Ost") und der betreuende Spielbetrieb aus SA_WITHOUT_GO_SHORT (Hamburg).
    # Ein künftiger Eintrag mit einem solchen Kürzel liefe sonst in
    # :no_go_for_sa, obwohl die Ableitung die Antwort kennt.
    go = game_operation_for(sa)
    status = go ? :override : :no_go_for_sa
    Result.new(club: club, game_operation: go, state_association: sa, status: status, detail: override[:reason])
  end

  def resolve_from_teams(club, counts)
    ranked = counts.sort_by { |_go_id, n| -n }
    total = counts.values.sum
    detail = ranked.map { |go_id, n| "#{@go_by_id[go_id].name}=#{n}" }.join(', ')

    # Strenge Mehrheit: Gleichstand fällt damit ebenfalls durch (bei zwei
    # gleichen Werten erreicht keiner mehr als die Hälfte).
    return Result.new(club: club, status: :no_majority, detail: detail) if ranked.first.last * 2 <= total

    go = @go_by_id[ranked.first.first]
    Result.new(club: club, game_operation: go, state_association: target_state_association(club, go),
               status: :from_teams, detail: detail)
  end

  def resolve_from_state_association(club)
    sa = @sa_by_id[club.state_association_id]
    return Result.new(club: club, status: :no_source) if sa.nil?

    go = game_operation_for(sa)
    status = go ? :from_sa : :no_go_for_sa
    Result.new(club: club, game_operation: go, state_association: nil, status: status,
               detail: "Landesverband #{sa.short_name}")
  end

  # Spielbetrieb eines Landesverbands: der eigene, sonst der des übergeordneten
  # Verbands (Sachsen/Sachsen-Anhalt/Thüringen unter „SBK Ost"), sonst der
  # betreuende aus SA_WITHOUT_GO_SHORT (Hamburg).
  def game_operation_for(state_association)
    direct = @go_by_sa_id[state_association.id]
    return direct if direct

    if state_association.parent_id && (parent = @sa_by_id[state_association.parent_id])
      inherited = @go_by_sa_id[parent.id]
      return inherited if inherited
    end

    short = SA_WITHOUT_GO_SHORT[state_association.short_name]
    short && @go_by_sa_id[@sa_by_short_name[short]&.id]
  end

  # Landesverband nur, wenn keiner hinterlegt ist. Bundesland laut PLZ hat
  # Vorrang vor dem Landesverband des Spielbetriebs — beides fällt auseinander
  # (Eidelstedt: SH-Spielbetrieb, Landesverband Hamburg).
  def target_state_association(club, game_operation)
    return nil if club.state_association_id.present?

    state_association_from_postcode(club) || game_operation&.state_association
  end

  def state_association_from_postcode(club)
    return nil unless club.postcode.to_s.strip.match?(/\A\d{5}\z/)

    isocode = ApplicationRecord.state_for_postcode(club.postcode)
    short = ClubStateAssociationResolver::STATE_TO_SA_SHORT[isocode]
    short && @sa_by_short_name[short]
  end
end

namespace :clubs do
  def hgo_dry_run?
    ENV.fetch('DRY_RUN', 'true') != 'false'
  end

  # Nur die exakten Werte gelten. Ein Tippfehler (`DRY_RUN=False`, `0`, `no`)
  # bliebe sonst lautlos ein Dry-Run, und wer die Ausgabe nicht von oben liest,
  # hält den Lauf für erledigt.
  def hgo_check_dry_run_flag!
    value = ENV['DRY_RUN']
    return if value.nil? || %w[true false].include?(value)

    abort "DRY_RUN muss 'true' oder 'false' sein, war '#{value}'."
  end

  def hgo_build_resolver
    resolver = ClubHomeGameOperationResolver.new

    # Warnen, nicht abbrechen: die Kürzel-Tabellen decken Ausnahmen ab, nicht
    # jeden Verein. Ein fehlendes Kürzel betrifft genau die Vereine, die es
    # brauchen — die landen mit :unknown_sa_short bzw. :no_go_for_sa in der
    # Prüfliste. Ein `abort` hier wäre außerdem eine Falle: im Test (und überall,
    # wo die Ausgabe umgeleitet ist) beendet SystemExit den Prozess stumm.
    missing = resolver.missing_short_names
    puts "HINWEIS: Landesverband-Kürzel ohne Treffer: #{missing.join(', ')}" if missing.any?

    # Wirkungslose Zuordnung: Zur id gibt es keinen Verein, oder sein Name trägt das
    # Merkmal nicht. Entweder ist es nicht der Produktionsbestand — dann ist das zu
    # erwarten —, oder der Verein wurde umbenannt. Im zweiten Fall bestätigt die
    # normale Ableitung wieder den falschen Landesverband, deshalb laut und mit
    # Ansage.
    mismatched = resolver.overrides_mismatched
    if mismatched.any?
      puts "HINWEIS: Ausdrückliche Zuordnungen, die nicht greifen: #{mismatched.join(', ')}"
      puts '         Gibt es den Verein, leitet ihn dieser Lauf normal ab und bestätigt'
      puts '         womöglich den falschen Verband — ein Schreiblauf hält dafür nicht an,'
      puts '         der Hinweis dient dem Prüfen. Falls der Verein hier sein müsste: auf'
      puts '         Umbenennung prüfen, Merkmal nachziehen, Lauf wiederholen.'
    end

    unmapped = resolver.unmapped_state_associations_without_go
    if unmapped.any?
      puts 'HINWEIS: Landesverbände ohne eigenen Spielbetrieb und ohne Eintrag in ' \
           "SA_WITHOUT_GO_SHORT: #{unmapped.map { |sa| "#{sa.short_name} (#{sa.id})" }.join(', ')}"
      puts '         Vereine dieser Verbände werden übersprungen.'
      puts
    end

    resolver
  end

  def hgo_line(result)
    club = result.club
    go = result.game_operation ? "#{result.game_operation.name} (#{result.game_operation.id})" : '—'
    sa = if result.state_association
           "+ LV #{result.state_association.short_name} (#{result.state_association.id})"
         else
           ''
         end
    format('  #%<id>-4d %<name>-46s → SB %<go>-44s %<sa>s',
           id: club.id, name: club.name.to_s[0, 46], go: go, sa: sa)
  end

  desc 'Übersicht der Vereine ohne Heimat-Spielbetrieb samt abgeleiteter Zuordnung (nur lesend).'
  task home_game_operation_report: :environment do
    resolver = hgo_build_resolver
    clubs = resolver.affected_clubs
    puts "=== #{clubs.size} Verein(e) ohne Heimat-Spielbetrieb ==="
    puts

    clubs.map { |club| resolver.resolve(club) }
         .group_by(&:status).each do |status, results|
      puts "--- #{status} (#{results.size}) ---"
      results.each do |result|
        puts hgo_line(result)
        puts "         #{result.detail}" if result.detail.present?
      end
      puts
    end
  end

  desc 'Heimat-Spielbetrieb bei Vereinen ohne setzen (+ fehlenden Landesverband). DRY_RUN=false zum Ausführen.'
  task backfill_home_game_operations: :environment do
    hgo_check_dry_run_flag!
    dry_run = hgo_dry_run?
    resolver = hgo_build_resolver

    puts "=== Heimat-Spielbetrieb nachziehen #{dry_run ? '[DRY RUN]' : '[LIVE]'} ==="
    puts

    results = resolver.affected_clubs.map { |club| resolver.resolve(club) }
    writable, skipped = results.partition do |r|
      ClubHomeGameOperationResolver::WRITABLE_STATUSES.include?(r.status)
    end

    writable.each do |result|
      puts hgo_line(result)
      puts "         #{result.status}: #{result.detail}"
      next if dry_run

      club = result.club
      # Nur der Heimat-Eintrag. Gast-Einträge wurden hier früher mitgeschleift,
      # das Konzept gibt es nicht mehr. game_operation_id bewusst als Integer:
      # alle Abfragen vergleichen per jsonb `@>` gegen eine Zahl, ein String
      # macht den Verein in jeder Vereinsliste unsichtbar.
      attrs = { game_operations_hash: [{ 'home_game_operation' => true,
                                         'game_operation_id' => result.game_operation.id }] }
      attrs[:state_association_id] = result.state_association.id if result.state_association
      club.update_columns(attrs)
      # update_columns rührt updated_at nicht an, der cache_key bleibt gleich –
      # Club#home_game_operation läge sonst als veralteter nil im Cache.
      Rails.cache.delete("#{club.cache_key}/home_game_operation")
    end

    puts
    if skipped.any?
      puts "--- Nicht zugeordnet (#{skipped.size}), zur Prüfung ---"
      skipped.each do |result|
        puts hgo_line(result)
        puts "         #{result.status}: #{result.detail}"
      end
      puts
    end

    puts "#{writable.size} Verein(e) #{dry_run ? 'würden geändert' : 'geändert'}, #{skipped.size} übersprungen."
    puts 'DRY RUN – nichts gespeichert. Mit DRY_RUN=false ausführen.' if dry_run
  end
end
