# Eine Freigabe (Zweitspielrecht), die ueber das Spielerprofil erteilt wird, bekommt
# hier ihre Vorgangszeile in `transfer_requests` -- dieselbe, die der Antragsweg
# ueber `TransferRequest#execute_release!` mitfuehrt.
#
# Warum ueberhaupt: Fachlich ist beides dieselbe Freigabe, und `execute_release!`
# schreibt genau denselben clubs-Eintrag. Ohne Vorgang blieb die im Profil erteilte
# Freigabe unsichtbar -- in der Uebersicht „Transferantraege", in deren CSV-Export
# und in der Spalte „Freigabedatum" der Lizenzliste, die ueber
# `League.license_release_dates` ebenfalls die Vorgaenge liest.
#
# Eigenes Concern und nicht im Controller: Der PlayersController liegt an der
# Zeilengrenze (Metrics/ClassLength), und die Regeln hier gehoeren zum Freigabewesen,
# nicht zur Spielerverwaltung.
module PlayerReleaseRecording
  extend ActiveSupport::Concern

  private

  # Kein `player.lock!` wie in `TransferRequest#execute_release!`, und das ist
  # kein Versehen: `lock!` laedt den Datensatz neu und wuerfe damit den gerade
  # angehaengten clubs-Eintrag weg, der hier bereits im Speicher steht. Ein Lock
  # muesste an den Anfang der Aktion, das waere ein Umbau des Bestandscodes.
  # Zwei zeitgleiche Freigaben desselben Profils koennen deshalb zwei
  # Vorgangszeilen erzeugen -- derselbe Wettlauf, den der clubs-Hash hier schon
  # immer hatte.
  def save_with_release_record(player, club, former_club_id)
    ActiveRecord::Base.transaction do
      raise ActiveRecord::Rollback unless player.save

      record_direct_release!(player, club, former_club_id)
      true
    end
  end

  # Der abgebende Verein ist Pflichtspalte des Vorgangs. Ohne gültige
  # Heimat-Zugehörigkeit (Altbestand) oder ohne den Verein dazu bleibt die
  # Freigabe ohne Vorgangszeile, statt abgewiesen zu werden: Der Antragsweg
  # weist genau diese Profile bereits ab (`no_home_club_response`), die Freigabe
  # über das Profil ist für sie der einzige verbliebene Weg.
  def record_direct_release!(player, club, former_club_id)
    if former_club_id.blank? || !Club.exists?(id: former_club_id)
      return _release_ohne_vorgang(player, club, "kein ermittelbarer abgebender Verein (#{former_club_id.inspect})")
    end

    # `transfer_requests.season_id` ist NOT NULL ohne Validierung: Ein fehlender
    # Wert kaeme als NotNullViolation heraus, also als 500 -- und wuerde die
    # Freigabe mit zurueckrollen, die vor dieser Aenderung funktioniert haette.
    # Die Vorgangszeile ist die Zugabe, nicht der Zweck; sie darf den Vorgang
    # nicht verhindern.
    season_id = Setting.current_season_id
    return _release_ohne_vorgang(player, club, 'keine laufende Saison gesetzt') if season_id.blank?

    tr = TransferRequest.create!(
      player_id: player.id,
      requesting_club_id: club.id,
      former_club_id: former_club_id,
      status: 'approved',
      request_type: 'release',
      direct: true,
      created_by: current_user.id,
      approved_by_lv_user_id: current_user.id,
      lv_approved_at: Time.current,
      season_id: season_id
    )
    # `before_create` erzeugt den Bestätigungslink des Spielers unbedingt. Der
    # gehört zu einem laufenden Antrag; auf jedem anderen Weg nach `approved`
    # wird er beim Abschluss geleert.
    tr.update!(player_confirmation_token: nil)
  end

  # Gegenstück zu #save_with_release_record: Wird eine Freigabe im Spielerprofil
  # beendet, gehört der Vorgang auf `revoked`. Sonst stünde in der Übersicht
  # weiter eine erteilte Freigabe, die es nicht mehr gibt. Gilt auch für
  # Freigaben aus dem Antragsweg -- deren Vorgang blieb hier schon immer
  # unberührt.
  #
  # Nicht über `TransferRequest#revoke_release!`: Der Widerruf dort entwertet
  # zusätzlich die Lizenzen des aufnehmenden Vereins. Was dieser Knopf tut,
  # bleibt unverändert; mitgeschrieben wird nur, was er tut.
  def save_with_release_revocation(player, club, beendete)
    ActiveRecord::Base.transaction do
      raise ActiveRecord::Rollback unless player.save

      beendete.each { |erteilt_am| revoke_release_record!(player, club, erteilt_am) }
      true
    end
  end

  # Widerruft den Vorgang, der GENAU DIESE Freigabe geschrieben hat.
  #
  # Der Bezug laeuft ueber den Zeitpunkt und nicht ueber „der neueste Vorgang zu
  # Spieler und Verein": Eine regulaer am Stichtag ausgelaufene Freigabe bleibt
  # bewusst auf `approved` stehen (Auslaufen ist kein Widerruf), es liegen also
  # dauerhaft aeltere genehmigte Zeilen herum. Wurde derselbe Verein in einer
  # frueheren Saison schon einmal freigegeben und traegt die aktuelle Freigabe
  # keinen Vorgang -- weil sie vor api#572 erteilt und vom Datenlauf
  # uebersprungen wurde --, dann haette der neueste Treffer die Zeile der ALTEN
  # Saison widerrufen. Das faellt niemandem auf und ist nicht bloss Anzeige:
  # `League.license_release_dates` liest genau `release`+`approved` und speist
  # damit die Spalte „Freigabedatum" der Lizenzliste, die nach Saison der Liga
  # aufschluesselt. Der Lizenzliste von damals fehlte danach eine
  # fristenrelevante Angabe.
  #
  # Dasselbe Ein-Tages-Fenster wie im Datenlauf: Der Antragsweg legt den Vorgang
  # beim Stellen an und schreibt den clubs-Eintrag erst beim Vollzug, massgeblich
  # ist deshalb `lv_approved_at`. Zwei Freigaben desselben Profils an denselben
  # Verein innerhalb eines Tages gibt es nicht.
  #
  # Findet sich keine passende Zeile, wird nichts widerrufen und die Auslassung
  # protokolliert: Das ist der Zustand von vor api#572 und damit harmlos, ein
  # falsch getroffener Vorgang waere es nicht.
  def revoke_release_record!(player, club, erteilt_am)
    zeitpunkt = begin
      Time.zone.parse(erteilt_am.to_s)
    rescue StandardError
      nil
    end

    tr = if zeitpunkt
           TransferRequest.where(player_id: player.id, requesting_club_id: club.id,
                                 request_type: 'release', status: 'approved')
                          .where.not(lv_approved_at: nil)
                          .order(:lv_approved_at, :id)
                          .find { |k| (k.lv_approved_at - zeitpunkt).abs <= 1.day }
         end

    unless tr
      return Rails.logger.warn("Freigabe beendet ohne Widerruf: Spieler #{player.id} → Verein #{club.id}, " \
                               "kein Vorgang zur Erteilung vom #{erteilt_am.inspect}")
    end

    tr.update!(status: 'revoked', revoked_by: current_user.id, revoked_at: Time.current,
               revocation_reason: 'Freigabe im Spielerprofil beendet',
               player_confirmation_token: nil)
  end

  # Die Freigabe steht, die Vorgangszeile nicht. Bewusst kein Abbruch (siehe die
  # Aufrufstellen), aber auch nicht stumm: Sonst ist die Antwort byteweise die
  # des Erfolgsfalls, und niemand kann sagen, wie oft der Fall eintritt oder ob
  # der Restbestand nach dem Datenlauf wieder anwaechst.
  def _release_ohne_vorgang(player, club, grund)
    Rails.logger.warn("Freigabe ohne Vorgang: Spieler #{player.id} → Verein #{club.id}, #{grund}")
    nil
  end
end
