# Fassung der Nutzungsvereinbarung für die Saisonmanager-API.
#
# Der Volltext liegt im Frontend (öffentliche Seite /api-zugang/nutzungsbedingungen),
# hier steht nur die Kennung der gültigen Fassung. Der Antrag speichert, welcher
# Fassung zugestimmt wurde; das Formular schickt sie mit und der Antrag wird
# abgelehnt, wenn sie nicht mehr aktuell ist (offener Tab über eine Änderung
# hinweg). Bei jeder inhaltlichen Änderung des Textes ist diese Konstante
# mitzuziehen, sonst dokumentiert der Antrag die falsche Fassung.
module ApiTerms
  VERSION = '2026-08-05'.freeze
end
