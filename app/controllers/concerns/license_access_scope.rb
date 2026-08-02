# frozen_string_literal: true

# Spielbetriebs-Scope für das Lizenzwesen. Eine SBK-Rolle gilt immer nur für die
# Spielbetriebe, auf die sie ausgestellt ist (`game_operation_id == 0` = global);
# maßgeblich ist der Spielbetrieb der LIGA, nicht der Landesverband des Vereins,
# denn zuständig für den Spielbetrieb einer Liga ist allein deren Verband.
#
# Vorher prüften die Antrags-Endpunkte nur `permission_hash[:sbk].present?` und
# damit gar keinen Spielbetrieb: jede SBK-Rolle durfte in jeder Liga jedes
# Verbands Lizenzen beantragen, zurückziehen und wieder aktivieren. Von
# PlayersController und ClubsController geteilt, damit Antrag, Genehmigung und
# Anzeige denselben Scope benutzen.
module LicenseAccessScope
  extend ActiveSupport::Concern

  private

  def sbk_global?(ph)
    ph[:sbk].present? && ph[:sbk].include?(0)
  end

  # Mutierende Aktionen: bewusst nur `team.league` (die primäre Liga) und NICHT
  # `team.leagues`, da eine zusätzliche Cup-Liga zu einem anderen Spielbetrieb
  # gehören kann und den Scope sonst aufweichen würde.
  #
  # Ein Team ohne auflösbare Liga bzw. eine Liga ohne game_operation_id ist ein
  # Datenfehler, kein Rechte-Ergebnis: Die Prüfung fällt zwar zu (niemand soll
  # auf Verdacht Zugriff bekommen), meldet den Fall aber, sonst ist er von einer
  # regulären Absage nicht mehr zu unterscheiden.
  def sbk_can_access_team?(ph, team)
    return false if ph[:sbk].blank?
    return true if sbk_global?(ph)
    return false if team.blank?

    go_id = team.league&.game_operation_id
    if go_id.blank?
      report_license_data_defect("team_without_game_operation/#{team.id}",
                                 "Team##{team.id} (#{team.name}) ohne aufloesbaren Spielbetrieb, " \
                                 "league_id=#{team.league_id.inspect}")
      return false
    end

    ph[:sbk].include?(go_id)
  end

  # Die Lizenz hängt über ihr Team an dessen Liga und damit an einer
  # game_operation_id – exakt die GO, nach der auch die Anzeige
  # (Admin::LicensesController#index) filtert.
  def sbk_can_access_license?(ph, license)
    return false if ph[:sbk].blank?
    return true if sbk_global?(ph)
    return false if license.blank?

    team = Team.find_by(id: license['team_id'])
    if team.nil?
      # Verwaiste Referenz, kein Rechte-Ergebnis: Die Lizenz haengt an einem
      # geloeschten Team und laesst sich dann von niemandem ausser Admin mehr
      # bearbeiten. Ohne Meldung bliebe sie unbemerkt in ihrem Status haengen.
      report_license_data_defect("license_team_missing/#{license['team_id']}",
                                 "Lizenz #{license['id'].inspect} verweist auf geloeschtes " \
                                 "Team #{license['team_id'].inspect}")
      return false
    end

    sbk_can_access_team?(ph, team)
  end

  # Lesende Endpunkte hängen an einer Liga (Lizenzliste einer Liga) bzw. an allen
  # Ligen eines Teams (Team-Lizenzseite). Anders als bei den mutierenden Aktionen
  # genügt hier EINE Liga im Scope: die Seite bündelt die Daten über alle Ligen
  # des Teams, und der Verband einer Cup-Liga ist für diese Liga tatsächlich
  # zuständig.
  def sbk_can_access_leagues?(ph, leagues)
    return false if ph[:sbk].blank?
    return true if sbk_global?(ph)

    go_ids = Array(leagues).compact.map(&:game_operation_id).compact
    go_ids.intersection(ph[:sbk]).present?
  end

  # Rollen additiv auswerten statt per elsif-Kette nur die erste: wer neben
  # Admin/SBK auch VM oder TM ist, verlöre sonst genau die Teams außerhalb des
  # eigenen Spielbetriebs (z.B. ein SBK eines LV, der zugleich VM eines Vereins
  # mit Bundesliga-Team ist).
  def may_manage_team?(ph, team)
    ph[:admin].present? || sbk_can_access_team?(ph, team) ||
      (ph[:vm].present? &&
        (ph[:vm].include?(team.club_id) || ph[:vm].intersection(team.syndicate_clubs).present?)) ||
      (ph[:tm].present? && ph[:tm].include?(team.id))
  end

  # Eine Lizenz gilt für ein Team und damit für dessen Verein: beantragt werden
  # darf nur für Spieler mit laufender Mitgliedschaft in diesem Verein (bei
  # SG-/Syndikats-Teams in einem der beteiligten Vereine). Die player_id kommt
  # aus der URL und war bisher ungeprüft.
  #
  # Die Vereinsmenge ist bewusst dieselbe wie im VM-Zweig von
  # `may_manage_team?` und in der Gruppierung der Mannschaftsauswahl
  # (`ClubsController#current_teams_by_club`), also `syndicate_clubs` OHNE das
  # `syndicate`-Flag. `Team#all_club_ids` wertet das Flag zusätzlich aus; bei
  # gesetzten `syndicate_clubs` und nicht gesetztem Flag kämen die beiden
  # Prüfungen sonst innerhalb desselben Requests zu verschiedenen Ergebnissen,
  # und der Antrag scheiterte mit einer Meldung über die Person statt über die
  # Mannschaft.
  #
  # Nicht deckungsgleich mit `Club#players` (Spielerliste im Frontend): dort
  # wird `club_id` ohne Typumwandlung verglichen, der Stichtag ist `Time.now`
  # statt `Date.current`, und deaktivierte Profile fallen über `Player.active`
  # heraus. Alle drei Abweichungen sind hier die großzügigere Variante, führen
  # also nicht zu einer falschen Absage.
  def player_in_team_clubs?(player, team)
    club_ids = ([team.club_id] + team.syndicate_clubs.to_a).compact.uniq
    Array(player.clubs).any? do |entry|
      # Strukturell kaputter Eintrag (kein Objekt): zählt nicht als
      # Mitgliedschaft, wird aber gemeldet statt still verworfen.
      unless entry.is_a?(Hash)
        report_license_data_defect("player_clubs_entry_broken/#{player.id}",
                                   "Spieler##{player.id}: clubs-Eintrag ist kein Objekt (#{entry.class})")
        next false
      end
      next false unless club_ids.include?(entry['club_id'].to_i)

      membership_current?(player, entry['valid_until'])
    end
  end

  # Ein unparsbares valid_until ist kein Freibrief, aber auch keine saubere
  # Absage: ohne Meldung wäre die 422 nicht von einer echten Nicht-Mitgliedschaft
  # zu unterscheiden. Der rescue umschließt bewusst nur die Datumsumwandlung,
  # nicht den ganzen Schleifenrumpf.
  def membership_current?(player, valid_until)
    return true if valid_until.blank?

    valid_until.to_date >= Date.current
  rescue ArgumentError, TypeError, NoMethodError => e
    report_license_data_defect("player_valid_until_unparsable/#{player.id}",
                               "Spieler##{player.id}: valid_until #{valid_until.inspect} " \
                               "nicht lesbar (#{e.class})")
    false
  end

  # Datenfehler melden, aber nur einmal je Fall und Tag: Ohne Drosselung meldet
  # jeder Seitenaufruf erneut. Gleiche Vorgehensweise wie bei den Teams ohne
  # Liga (`TeamsController#render_team_without_league`).
  def report_license_data_defect(cache_key, message)
    return unless Rails.cache.write("license_scope_defect/#{cache_key}", true,
                                    unless_exist: true, expires_in: 1.day)

    Rails.logger.error("license scope: #{message}")
    Sentry.capture_message("license scope data defect: #{message}") if defined?(Sentry)
  end
end
