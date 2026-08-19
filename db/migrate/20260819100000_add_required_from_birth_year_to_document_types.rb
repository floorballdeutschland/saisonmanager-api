# Zweite Form der Altersregel einer Dokumentart. `required_below_age` ist
# tagesgenau und rechnet gegen das Datum der Lizenzbeantragung: Wer im Sommer
# noch 15 ist, braucht das sportaerztliche Attest nicht, wird aber in derselben
# Saison 16. `required_from_birth_year` greift stattdessen fuer einen ganzen
# Jahrgang ("ab 2012"), unabhaengig von Geburtstag und Antragsdatum.
#
# Zwei Spalten statt eines age_rule-Enums: Der Bestand bleibt so unberuehrt und
# jeder Leser von required_below_age behaelt seine Bedeutung. Dass nur eine der
# beiden gesetzt sein darf, sichert DocumentType (Modellvalidierung, kein
# Constraint — die Regel ist fachlich und soll eine lesbare Meldung erzeugen).
class AddRequiredFromBirthYearToDocumentTypes < ActiveRecord::Migration[7.1]
  def change
    add_column :document_types, :required_from_birth_year, :integer
  end
end
