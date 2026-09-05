# frozen_string_literal: true

# Verbands-Scope je Lizenz fuer die Anzeige im Spielerprofil.
#
# Zwei Knoepfe haengen an einem flachen Recht (`player_set_gf_role`,
# `player_delete_license`), waehrend die Endpunkte dahinter zusaetzlich auf den
# Spielbetrieb der Liga scopen. Ohne diese Stelle verspraeche die Maske etwas,
# das der Schreibweg mit 403 abweist: Eine Landes-SBK saehe den roten
# Loeschknopf auch an der Bundesliga-Lizenz eines ihrer Heimatspieler.
#
# Ausgelagert aus PlayersController, weil die Klasse an ihrer
# Metrics/ClassLength-Grenze liegt (Max 1000, .rubocop_todo.yml).
module LicenseScopeAnnotation
  extend ActiveSupport::Concern

  private

  # Der Spielbetrieb kommt aus dem bereits aufgeloesten Liga-Hash und nicht ueber
  # sbk_can_access_license?: Das Ergebnis ist dasselbe (Team -> Liga ->
  # game_operation_id), aber ohne eine weitere Team-Abfrage je Lizenz und ohne
  # die Datenfehler-Meldung jener Methode. Ein Profil mit vierzig Altlizenzen
  # loeste sonst fuer jedes geloeschte Team eine Sentry-Meldung aus, obwohl hier
  # nichts entschieden, sondern nur angezeigt wird.
  #
  # Ohne aufloesbare Liga bleibt es bei false: Wer nicht weiss, welcher Verband
  # zustaendig ist, ordnet nichts zu und loescht nichts. Fuer VM und TM sind
  # beide Werte immer false, denn beides ist Verbandssache.
  def annotate_license_scopes!(hash)
    ph = current_user.permission_hash
    admin = ph[:admin].present?
    sbk_global = ph[:sbk].present? && ph[:sbk].include?(0)

    Array(hash[:licenses]).each do |lic|
      next unless lic.is_a?(Hash)

      go_id = lic[:league].is_a?(Hash) ? lic[:league][:game_operation_id] : nil
      # `go_id.present?` steht bewusst VOR den Rollen und nicht nur im
      # SBK-Zweig: Sonst kuerzen `admin` und `sbk_global` ab, und eine Lizenz
      # ohne aufloesbare Liga (geloeschtes Team, Team ohne league_id) waere fuer
      # sie als zuordenbar gemeldet. Genau die weist der Schreibweg danach mit
      # 422 ab.
      im_scope = go_id.present? && (admin || sbk_global || ph[:sbk].to_a.include?(go_id))
      lic[:gf_role_editable] = im_scope
      # Nur einschraenken, nie ausweiten: Was die Saison- und Statusregel in
      # Player#delete_allowed bereits ablehnt, bleibt abgelehnt.
      lic[:delete_allowed] &&= im_scope
    end
  end
end
