# frozen_string_literal: true

# Wer darf einen Beobachtungsbogen schreiben, und wer darf ihn lesen.
#
# Eine Klasse statt eines Concerns, weil dieselbe Frage an drei Stellen gestellt
# wird (Selfservice-Abgabe, Selfservice-Lesesicht, Schiriverwaltung). Das
# Vereins-Feedback hat dieselbe Prüfung an vier Stellen dupliziert; das soll sich
# hier nicht wiederholen.
class RefereeObservationPolicy
  # Spieltagsdatum ist ein lokales Datum ohne Zeitzone, die Anwendung läuft in
  # UTC. Dieselbe Zone wie RefereeFeedbackWindow, damit „heute" überall dasselbe
  # heißt.
  ZONE = RefereeFeedbackWindow::ZONE

  def initialize(user)
    @user = user
  end

  # Das eigene Schiedsrichterprofil des angemeldeten Kontos, oder nil.
  def referee
    return @referee if defined?(@referee)

    @referee = @user&.referee
  end

  # Ist die angemeldete Person am Stichtag als Schiedsrichtercoach qualifiziert
  # (gültige Zusatzqualifikation „B…")? Ohne Stichtag gilt heute – so entscheidet
  # sich auch der Menüpunkt.
  #
  # Je Stichtag gemerkt: Die Spielauswahl fragt fuer jedes Spiel einzeln, und die
  # Stichtage wiederholen sich (ein Spieltag, viele Spiele).
  def coach_qualified?(date = Date.current)
    return false if referee.nil?

    @coach_qualified ||= {}
    return @coach_qualified[date] if @coach_qualified.key?(date)

    @coach_qualified[date] = Referee.coach_qualified(date).exists?(id: referee.id)
  end

  # Darf zu diesem Spiel ein Bogen abgegeben werden? Zwei Wege, beide setzen die
  # gültige B-Qualifikation am Spieltag voraus:
  #
  #   1. Der Coach war für das Spiel angesetzt (referee_assignments.coach_id).
  #   2. Der Spielbetrieb setzt nicht personenscharf an – dort gibt es gar keinen
  #      Coach-Slot, den man belegen könnte – und das Spiel gehört zum eigenen
  #      Spielbetrieb.
  #
  # Der zweite Weg ist bewusst an den Modus gebunden und nicht generell offen:
  # Wo personenscharf angesetzt wird, ist die Ansetzung die Entscheidung darüber,
  # wer wen beobachtet.
  def can_observe?(game)
    return false if referee.nil?
    return false if game.nil?

    date = game_date(game)
    # Zukünftige Spiele: Beobachtet wird, was gespielt wurde.
    return false if date.nil? || date > ZONE.today
    return false unless coach_qualified?(date)
    return true if game.referee_assignment&.coach_id == referee.id

    free_choice_allowed?(game)
  end

  # Bögen, die die VERWALTUNGSSICHT dieses Kontos zeigen darf – die Rollensicht
  # am Schiri-Profil. Ausschließlich über den Spielbetrieb der Rolle.
  #
  # Die eigene Betroffenheit gehört bewusst NICHT hinein: Wer selbst beobachtet
  # oder beobachtet wurde, liest seinen Bogen im Selfservice, und dort ohne die
  # Einzelnoten des Gespannpartners (RefereeObservationSerializer). Stünde die
  # persönliche Sicht auch hier, könnte jede Person mit irgendeiner RSK- oder
  # Ansetzer-Rolle den gemeinsamen Bogen über das Profil ihres Partners
  # aufrufen und dessen Noten mitlesen – über jede Verbandsgrenze hinweg, weil
  # die Verwaltung den vollständigen Bogen serialisiert.
  def admin_scope
    return RefereeObservation.all if global_reader?
    return RefereeObservation.where(game_operation_id: scoped_game_operation_ids) if scoped_reader?

    RefereeObservation.none
  end

  # Bögen, deren Status dieses Konto ändern darf. Enger als admin_scope: Die
  # Ansetzung liest nur, und die eigene Betroffenheit begründet erst recht kein
  # Schreibrecht – sonst nähme die beobachtete Person die Kritik an sich selbst
  # aus der Welt, im fremden Spielbetrieb und ohne dass es jemand sieht.
  def moderation_scope
    return RefereeObservation.none unless can_moderate?
    return RefereeObservation.all if ph[:admin].present? || Array(ph[:rsk]).include?(0)

    RefereeObservation.where(game_operation_id: Array(ph[:rsk]).reject(&:zero?))
  end

  # Zurücknehmen und Wiederherstellen eines Bogens (status). Kein Schritt im
  # Normalfluss – die beobachtete Person sieht den Text sofort –, sondern der
  # Notausgang für eine entgleiste Rückmeldung.
  #
  # Nur die Rollenfrage; welchen Bogen diese Rolle erreicht, entscheidet
  # moderation_scope.
  def can_moderate?
    ph[:admin].present? || ph[:rsk].present?
  end

  # Darf die Verwaltungssicht (Schiri-Profil) Bögen anzeigen? Anders als beim
  # Vereins-Feedback auch für verbandsgebundene RSK/Ansetzer – begrenzt wird
  # nicht die Rolle, sondern über admin_scope der Spielbetrieb.
  def can_view_admin?
    global_reader? || scoped_reader?
  end

  # Spielbetriebe, in denen dieses Konto ein Spiel frei wählen darf: die eigenen,
  # soweit dort nicht personenscharf angesetzt wird. Öffentlich, damit die
  # Vorauswahl der Spiele dieselbe Regel schon in SQL anwendet, statt hinterher
  # jedes Spiel des Verbands einzeln zu verwerfen – und damit der Modus einmal
  # geladen wird und nicht je Spiel.
  def free_choice_game_operation_ids
    return [] if referee.nil?

    @free_choice_game_operation_ids ||=
      GameOperation.includes(:state_association)
                   .where(id: coach_game_operation_ids)
                   .reject { |go| go.referee_assignment_mode == :person }
                   .map(&:id)
  end

  private

  def ph
    @ph ||= @user ? @user.permission_hash : {}
  end

  def global_reader?
    return true if ph[:admin].present?
    return true if ph[:rsk].present? && ph[:rsk].include?(0)

    ph[:ansetzer].present? && ph[:ansetzer].include?(0)
  end

  def scoped_reader?
    scoped_game_operation_ids.any?
  end

  # Spielbetriebe der RSK-/Ansetzer-Rollen. Die 0 (global) ist hier schon durch
  # global_reader? abgefangen und wird verworfen, damit sie nicht als
  # Spielbetrieb 0 in die Query gerät.
  def scoped_game_operation_ids
    @scoped_game_operation_ids ||=
      ((ph[:rsk] || []) + (ph[:ansetzer] || [])).reject(&:zero?).uniq
  end

  # Spielbetrieb des Coaches: der zuständige Spielbetrieb seines Vereins, dazu
  # ein am Schiedsrichter direkt hinterlegter. Beides, weil Gastschiedsrichter
  # und Altbestand ohne Verein nur die zweite Angabe haben.
  def coach_game_operation_ids
    @coach_game_operation_ids ||=
      [referee.club&.main_game_operation_id, referee.game_operation_id].compact.uniq
  end

  # Der Ansetzungsmodus hängt am Spielbetrieb, nicht an der einzelnen Liga
  # (GameOperation#referee_assignment_mode). Deshalb genügt hier die Liste der
  # freigewählten Spielbetriebe; über die Liga danach noch einmal nachzufragen
  # würde je Spiel den Landesverband nachladen.
  def free_choice_allowed?(game)
    go_id = game.league&.game_operation_id
    return false if go_id.blank?

    free_choice_game_operation_ids.include?(go_id)
  end

  # game_days.date ist eine Textspalte; strikt im Spaltenformat lesen, damit
  # unbrauchbarer Inhalt nicht stillschweigend als heute durchgeht.
  def game_date(game)
    raw = game.game_day&.date
    return nil if raw.blank?

    Date.strptime(raw.to_s, '%Y-%m-%d')
  rescue ArgumentError, TypeError
    nil
  end
end
