class AlignRefereeLicenseValidityYearsWithPractice < ActiveRecord::Migration[7.1]
  # Die FD-Praxis (Schiedsrichterliste 2025) vergibt Lizenzen durchgängig für
  # 1 Jahr (Kurs 2025 → gültig bis 31.07.2026). Alle Stufen stehen auf Prod
  # noch auf dem unveränderten Default von 2 Jahren — das würde künftige
  # Kurs-Imports fachlich falsch (+2 statt +1) rechnen. Default und Bestand
  # daher auf 1 Jahr; abweichende Stufen können Admins danach bewusst
  # konfigurieren.
  def change
    change_column_default :referee_license_levels, :validity_years, from: 2, to: 1

    reversible do |dir|
      dir.up do
        execute 'UPDATE referee_license_levels SET validity_years = 1 WHERE validity_years = 2'
      end
    end
  end
end
