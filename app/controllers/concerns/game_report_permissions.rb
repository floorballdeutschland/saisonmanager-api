# frozen_string_literal: true

# Wer den Spielbericht eines Spiels schreiben darf. Geteilt zwischen den
# Ereignis- und Kaderwegen in GamesController und den Schüssen des Tabletmodus
# in GameShotsController (api#816), damit beide Wege dieselbe Regel lesen.
#
# Setzt SecretaryTokenAuthenticatable voraus (`secretary_token_permits_game?`).
module GameReportPermissions
  extend ActiveSupport::Concern

  # Rolle und Token sind additiv, nicht alternativ (#428). Vorher entschied ein
  # gesetzter `@secretary_link` allein: Ein Vereinsmanager mit einem gültigen
  # Hallen-Token in der Registerkarte verlor damit seine normalen Rechte an jedem
  # Spiel AUSSERHALB der vom Link abgedeckten Spieltage. Weil `show` es umgekehrt
  # hielt (dort gewann der Login), zeigte die Oberfläche die Bedienelemente der
  # eigenen Rolle, und der Schreibweg dahinter sagte nein.
  def can_edit_game?(game)
    return true if secretary_token_permits_game?(game)
    return false unless current_user

    game.can_edit_lineup?(current_user)
  end

  # Admin oder SBK *des Spielbetriebs dieses Spiels*. Entscheidet, wer die
  # Sperre bei abgeschlossenem Spielbericht übergehen und ihn wieder öffnen
  # darf. Bewusst auf den Spielbetrieb gescopt (#214): sonst hebelt eine
  # fachfremde SBK-Rolle die Sperre aus, sobald der Nutzer über eine andere
  # Rolle (VM/TM einer beteiligten Mannschaft) ohnehin Zugriff auf das Spiel
  # hat. Muster übernommen aus reopen_game, das das bereits richtig machte.
  def admin_or_scoped_sbk?(game)
    ph = current_user&.permission_hash || {}
    gos = [ph[:admin], ph[:sbk]].flatten.compact.map(&:to_i)
    return true if gos.include?(0)

    go_id = game.game_day&.league&.game_operation_id
    go_id.present? && gos.include?(go_id.to_i)
  end

  # Ereignisse (add_event, update_event, remove_event) und Schüsse: nach dem
  # Abschluss des Spielberichts nur noch Admin und SBK des Spielbetriebs.
  def can_write_events?(game)
    return false if game.match_record_closed? && !admin_or_scoped_sbk?(game)

    can_edit_game?(game)
  end
end
