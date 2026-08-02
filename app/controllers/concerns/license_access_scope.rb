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
  def sbk_can_access_team?(ph, team)
    return false if ph[:sbk].blank?
    return true if sbk_global?(ph)

    go_id = team&.league&.game_operation_id
    go_id.present? && ph[:sbk].include?(go_id)
  end

  # Die Lizenz hängt über ihr Team an dessen Liga und damit an einer
  # game_operation_id – exakt die GO, nach der auch die Anzeige
  # (Admin::LicensesController#index) filtert.
  def sbk_can_access_license?(ph, license)
    return false if ph[:sbk].blank?
    return true if sbk_global?(ph)
    return false if license.blank?

    sbk_can_access_team?(ph, Team.find_by(id: license['team_id']))
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
  # SG-/Syndikats-Teams in einem der beteiligten Vereine). Deckungsgleich mit der
  # Spielerliste, die `Club#players` fürs Frontend liefert – die player_id kommt
  # aus der URL und war bisher ungeprüft.
  def player_in_team_clubs?(player, team)
    club_ids = team.all_club_ids
    Array(player.clubs).any? do |entry|
      next false unless club_ids.include?(entry['club_id'].to_i)

      valid_until = entry['valid_until']
      valid_until.blank? || valid_until.to_date >= Date.current
    rescue ArgumentError, TypeError
      # Unparsbares valid_until nicht als Freibrief werten.
      false
    end
  end
end
