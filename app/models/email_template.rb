# Admin-pflegbare E-Mail-Vorlage pro Mailer-Action (Betreff, Absender, Reply-To).
#
# Ein Datensatz ist optional: existiert keiner, verwenden die Mailer ihre
# Code-Defaults (Betreff-Literal + Default-From/Reply-To). Der Body bleibt in
# dieser Ausbaustufe stets das ERB-View; die `body`-Spalte ist für eine spätere
# Body-Pflege reserviert.
class EmailTemplate < ApplicationRecord
  DEFAULT_LOCALE = 'de'.freeze

  validates :mailer_class, presence: true
  validates :action_name, presence: true
  validates :locale, presence: true
  validates :action_name, uniqueness: { scope: %i[mailer_class locale] }

  # Findet die Vorlage für (Mailer, Action, Sprache). Fällt auf die Default-
  # Sprache zurück, wenn für die angefragte Sprache nichts gepflegt ist.
  def self.resolve(mailer_class, action_name, locale = DEFAULT_LOCALE)
    by_locale = find_by(mailer_class: mailer_class.to_s, action_name: action_name.to_s, locale: locale.to_s)
    return by_locale if by_locale || locale.to_s == DEFAULT_LOCALE

    find_by(mailer_class: mailer_class.to_s, action_name: action_name.to_s, locale: DEFAULT_LOCALE)
  end

  def key
    "#{mailer_class}##{action_name}"
  end
end
