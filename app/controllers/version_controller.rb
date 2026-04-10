class VersionController < ApplicationController
  skip_before_action :authenticate_user

  CHANGELOG_PATH = Rails.root.join('CHANGELOG.md')

  def show
    render json: {
      version: SAISONMANAGER_VERSION,
      changelog: parsed_changelog
    }
  end

  private

  def parsed_changelog
    return [] unless CHANGELOG_PATH.exist?

    entries = []
    current = nil

    CHANGELOG_PATH.readlines.each do |line|
      if (match = line.match(/^## \[(\d+\.\d+\.\d+)\] - (\d{4}-\d{2}-\d{2})/))
        entries << current if current
        current = { version: match[1], date: match[2], changes: {} }
      elsif current && (section = line.match(/^### (.+)/))
        current[:changes][section[1]] = []
      elsif current && (item = line.match(/^- (.+)/))
        current[:changes].values.last&.append(item[1].strip)
      end
    end

    entries << current if current
    entries
  end
end
