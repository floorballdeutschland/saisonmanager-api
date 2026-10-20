# Freitext zum Einspruch gegen den Spieltagsbericht, gemeinsam für Gastteam
# (TeamGameDayConfirmationsController) und Schiedsrichter
# (RefereeGameDayConfirmationsController).
#
# Der Text ist freiwillig und gehört nur zum Einspruch: Wer den Spieltag als
# ordnungsgemäß bestätigt, hat nichts zu begründen, ein mitgeschickter Text
# wird dann verworfen statt still gespeichert. Sonst stünde bei der SBK ein
# Kommentar an einer Bestätigung, die gar nicht in ihrer Liste auftaucht.
module GameDayConfirmationComment
  extend ActiveSupport::Concern

  COMMENT_MAX_LENGTH = 2000

  private

  # [kommentar, fehlermeldung]; leere Eingabe wird zu nil.
  def confirmation_comment(properly)
    return [nil, nil] if properly

    comment = params[:comment].to_s.strip.presence
    if comment && comment.length > COMMENT_MAX_LENGTH
      return [nil, "Die Anmerkung darf höchstens #{COMMENT_MAX_LENGTH} Zeichen lang sein."]
    end

    [comment, nil]
  end
end
