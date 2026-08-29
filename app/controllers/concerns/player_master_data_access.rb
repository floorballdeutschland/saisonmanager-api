# frozen_string_literal: true

# Wer darf Geburtsdatum, Geschlecht und Nationalitaet eines Profils nachtragen?
#
# Die Regel hat zwei Leser: die Bearbeitungsmaske (#admin_player_update) und den
# CSV-Nachtrag (#vm_import). Zwei Fassungen derselben Rechteregel laufen
# auseinander, und genau so entstand die Luecke, die der CSV-Import zuerst hatte:
#
# (a) Eine Zweitmitgliedschaft im importierenden Verein, mit Heimatverein in
#     einem fremden Verband, waere ueber die CSV beschreibbar gewesen, ueber die
#     Maske daneben nicht (403). Genau die Luecke, die dort mit „sonst ist jede
#     Freigabe ein Generalschluessel" geschlossen ist.
# (b) Eine Doppelrolle SBK + Vereinsmanager (seit api#561 real) kommt ueber den
#     VM-Zweig von #resolve_vm_club in jeden eigenen Verein -- auch in einen, fuer
#     dessen Spielbetrieb die SBK-Rolle nicht gilt. `ph[:sbk].present?` ist
#     trotzdem wahr und haette dort Stammdaten geschrieben.
#
# Deshalb beide Bedingungen zusammen: die GO-Zustaendigkeit ueber
# `Club#user_permissions` UND die Heimatzugehoerigkeit in genau diesem Verein.
module PlayerMasterDataAccess
  extend ActiveSupport::Concern

  private

  # Die IDs, deren Stammdaten dieses Konto ueber DIESEN Verein nachtragen darf.
  # Bewusst je Spieler und nicht einmal fuer den ganzen Lauf.
  def master_data_writable_ids(club, players)
    return [] unless club.user_permissions(current_user).include?(:update_player)

    players.select { |p| home_club_membership?(p, club.id) }.map(&:id)
  end

  # Ist dieser Verein der HEIMATverein des Spielers? Die Gueltigkeit der
  # Zugehoerigkeit wird bewusst nicht mitgeprueft: Ein Profil, dessen
  # Heimatzugehoerigkeit abgelaufen ist, soll von seinem Verein weiter
  # korrigierbar bleiben.
  def home_club_membership?(player, club_id)
    (player.clubs || []).any? do |c|
      c.is_a?(Hash) &&
        ActiveModel::Type::Boolean.new.cast(c['home_club']) &&
        c['club_id'].to_i == club_id.to_i
    end
  end
end
