# Hochladen, Auflisten und Entfernen der Partnerlogos für die Overlays.
#
# Einmal geschrieben und von Liga wie Verein benutzt: Beide Ebenen sollen sich
# genau gleich verhalten. Ohne den gemeinsamen Weg lägen dieselben
# Prüfungen zweimal da, und die zweite Fassung wäre die, die beim nächsten
# Nachschärfen vergessen wird.
#
# Der einbindende Controller liefert `sponsor_logo_owner` (das Objekt) und
# `sponsor_logo_permitted?` (die Rechteprüfung dieser Ebene).
module SponsorLogoManagement
  extend ActiveSupport::Concern

  # Ein Partnerlogo ist ein Schriftzug und selten quadratisch, deshalb ohne die
  # Quadrat-Prüfung der Vereinslogos. Die übrigen Prüfungen bleiben: Formatangabe
  # (PNG, JPG, WebP), Größe, und ob die Datei überhaupt als Bild lesbar ist.
  #
  # ACHTUNG, die Formatprüfung ist schwächer als sie klingt: `logo_upload_error`
  # vergleicht `file.content_type`, also die Angabe des hochladenden Browsers, und
  # nicht den Inhalt. Eine als image/png deklarierte SVG kommt durch, libvips liest
  # sie anstandslos. Das sitzt im gemeinsamen Helfer und betrifft alle
  # Upload-Pfade, siehe #373. Hier ist die Zielgruppe allerdings die größte: über
  # die Vereinsebene erreicht diese Strecke als erste auch Vereinsmanager.
  SPONSOR_LOGO_MAX_SIZE = 1.megabyte

  def sponsor_logos_index
    return unless sponsor_logo_guard

    render json: { sponsor_logos: sponsor_logo_owner.sponsor_logo_hashes }
  end

  def sponsor_logos_create
    return unless sponsor_logo_guard

    file = params[:sponsor_logo]
    return render json: { message: 'Kein Bild angefügt' }, status: :unprocessable_entity if file.blank?

    if sponsor_logo_owner.sponsor_logo_limit_reached?
      return render json: { message: "Es sind höchstens #{SponsorLogos::MAX_SPONSOR_LOGOS} Partnerlogos möglich." },
                    status: :unprocessable_entity
    end

    if (error = logo_upload_error(file, square: false, max_size: SPONSOR_LOGO_MAX_SIZE))
      return render json: { message: error }, status: :unprocessable_entity
    end

    sponsor_logo_owner.sponsor_logos.attach(file)
    render json: { sponsor_logos: sponsor_logo_owner.reload.sponsor_logo_hashes }, status: :created
  end

  def sponsor_logos_destroy
    return unless sponsor_logo_guard

    # Über die Anhänge DIESES Objekts suchen und nicht global über
    # ActiveStorage::Attachment.find: Sonst löschte eine fremde attachment_id
    # das Logo eines anderen Vereins, und die Rechteprüfung oben liefe ins
    # Leere, weil sie nur den Besitzer aus der URL kennt.
    attachment = sponsor_logo_owner.sponsor_logos.find_by(id: params[:attachment_id])
    return render json: { message: 'Partnerlogo nicht gefunden.' }, status: :not_found unless attachment

    # `purge` und nicht `purge_later`: In Produktion ist
    # `config.active_job.queue_adapter` nicht gesetzt, es greift also der
    # Rails-Standard :async, ein Thread-Pool im Prozess ohne Persistenz.
    # `purge_later` entfernt die Verknüpfung sofort, verschiebt aber das
    # Wegräumen des Blobs. Fällt der Prozess in diesem Moment (Deploy, Neustart),
    # bleiben Blob-Zeile und Datei für immer liegen, von nichts referenziert und
    # von nichts mehr aufgeräumt. Bei höchstens einem Megabyte gibt es kein
    # Laufzeitargument fürs Verschieben, und alle anderen Löschstellen im Code
    # sind synchron.
    attachment.purge
    render json: { sponsor_logos: sponsor_logo_owner.reload.sponsor_logo_hashes }
  end

  private

  # Gibt true zurück, wenn weitergearbeitet werden darf, und rendert sonst bereits
  # die Absage.
  #
  # Der `current_user`-Riegel sieht doppelt aus, weil `authenticate_user` ihn heute
  # schon abfängt. Er ist es aber nicht: Nimmt man die drei Liga-Aktionen aus
  # `COOKIE_ONLY_ACTIONS` heraus, wird `authenticate_user` übersprungen und
  # stattdessen `authenticate_public_request` ausgeführt — ein gültiger X-Api-Key
  # käme dann durch, ohne dass ein Benutzer angemeldet ist. Genau hier endet das.
  # Nachgestellt: ohne diesen Riegel wäre es ein 500er in `user_permissions`,
  # mit ihm ein sauberer 401. Die Prüfreihenfolge (Besitzer VOR Berechtigung) ist
  # aus demselben Grund kein Zufall, `sponsor_logo_permitted?` würde auf einem
  # nil-Besitzer laufen.
  def sponsor_logo_guard
    unless current_user
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
      return false
    end

    unless sponsor_logo_owner
      render json: { message: 'Nicht gefunden.' }, status: :not_found
      return false
    end

    unless sponsor_logo_permitted?
      render json: { message: 'Keine Berechtigung' }, status: :forbidden
      return false
    end

    true
  end
end
