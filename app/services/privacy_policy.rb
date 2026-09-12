# Die Angaben, die eine kurze Datenschutzinformation nennen muss und die nicht
# am einzelnen Vorgang haengen: der Verantwortliche und die Fundstelle der
# ausfuehrlichen Datenschutzerklaerung.
#
# Ueber ENV ueberschreibbar (`PRIVACY_POLICY_URL`, `PRIVACY_RESPONSIBLE_BODY`):
# Zieht die Erklaerung um oder benennt sich der Verband um, laesst sich die
# Angabe richtigstellen, ohne auf den naechsten Code-Release zu warten -- bis
# dahin stuende sie in jeder Nachricht falsch, die noch rausgeht. Gesetzt ist
# heute keine der beiden; das hiesse einen Commit im saisonmanager-docker-Repo
# und ein Neuerzeugen des Containers. Anders als bei `FrontendUrl`, wo die
# Variable die Umgebungen trennt, ist es hier also nur ein Notausgang.
#
# Die URL zeigt auf den Anker des Kapitels "Saisonmanager" und nicht auf den
# Seitenanfang: Das Kapitel steht am Ende einer langen Erklaerung, die mit
# Website, Cookies und Newsletter beginnt. Ohne Anker landet die Person oben
# und sucht. Faellt der Anker weg, bleibt der Link gueltig und oeffnet die
# Seite von oben -- ein unbekanntes Fragment ignoriert der Browser.
#
# Verantwortlicher ist der Betreiber des Saisonmanagers. Wer ueber den
# einzelnen Vorgang entscheidet, ist eine andere Frage und steht nicht hier: Das
# ist der zustaendige Landesverband, und den kennt erst der Vorgang selbst
# (Club#responsible_state_association, siehe die Datenschutz-Partial).
module PrivacyPolicy
  DEFAULT_URL = 'https://floorball.de/datenschutz/#saisonmanager'.freeze
  DEFAULT_RESPONSIBLE_BODY = 'Floorball-Verband Deutschland e.V.'.freeze

  def self.url
    ENV['PRIVACY_POLICY_URL'].presence || DEFAULT_URL
  end

  def self.responsible_body
    ENV['PRIVACY_RESPONSIBLE_BODY'].presence || DEFAULT_RESPONSIBLE_BODY
  end
end
