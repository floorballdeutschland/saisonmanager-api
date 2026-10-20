# Spielbetriebe, deren Spielberichte jemand in der SBK-Arbeitsansicht
# „Spielberichte" sieht und als erledigt markieren darf. Gemeinsam für die
# Übersicht (Admin::GameDaysController#report_overview) und den
# Erledigt-Vermerk (Admin::GameReportReviewsController), damit beide dieselbe
# Grenze ziehen: Wer eine Zeile sieht, darf sie abhaken, und umgekehrt.
module GameReportReviewScope
  extend ActiveSupport::Concern

  private

  # nil = global (Admin oder SBK mit Spielbetrieb 0) -> kein Spielbetriebs-Filter.
  #
  # Einmal je Request: report_overview fragt das für bis zu 2000 Zeilen ab, und
  # permission_hash wird bei jedem Aufruf neu aufgelöst.
  def scope_go_ids
    return @scope_go_ids if defined?(@scope_go_ids)

    ph = current_user.permission_hash
    @scope_go_ids = if ph[:admin]&.include?(0) || ph[:sbk]&.include?(0)
                      nil
                    else
                      [ph[:admin], ph[:sbk]].compact.flatten.map(&:to_i)
                    end
  end

  def game_operation_in_scope?(go_id)
    go_ids = scope_go_ids
    go_ids.nil? || (go_id.present? && go_ids.include?(go_id.to_i))
  end
end
