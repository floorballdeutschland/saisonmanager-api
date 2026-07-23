# Zuordnung eines Themen-Tags zu einer einzelnen Feedback-Rückmeldung (#182).
# RSK/Ansetzer taggen die Freitextkommentare einer Rückmeldung händisch, wodurch
# Themen zählbar und über die Zeit vergleichbar werden. tagged_by_user_id hält
# fest, wer getaggt hat.
class FeedbackThemeTagging < ApplicationRecord
  belongs_to :referee_feedback
  belongs_to :feedback_theme
  belongs_to :tagged_by, class_name: 'User', foreign_key: :tagged_by_user_id, optional: true

  validates :referee_feedback_id, uniqueness: { scope: :feedback_theme_id,
                                                 message: 'ist bereits mit diesem Thema getaggt' }
end
