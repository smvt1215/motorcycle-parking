# Pure decisions are separated from store/network operations for retry tests.
module ReleasePolicy
  SUBMITTED_STATES = %w[
    WAITING_FOR_REVIEW IN_REVIEW PENDING_DEVELOPER_RELEASE
    PENDING_APPLE_RELEASE PROCESSING_FOR_APP_STORE READY_FOR_SALE
    READY_FOR_DISTRIBUTION PREORDER_READY_FOR_SALE
  ].freeze

  def self.range(base)
    ((base + 1)..(base + 9))
  end

  def self.play_candidate(tracks, base)
    production = tracks.to_h.fetch("production", []).map(&:to_i).select { |code| range(base).cover?(code) }
    return production.max unless production.empty?

    candidates = tracks.flat_map { |_, codes| codes }.map(&:to_i).select { |code| range(base).cover?(code) }
    candidates.max
  end

  def self.valid_build(builds, base)
    builds.select { |build| range(base).cover?(build.version.to_i) && build.processing_state == "VALID" }
          .max_by { |build| build.version.to_i }
  end

  def self.processing?(builds, base)
    builds.any? { |build| range(base).cover?(build.version.to_i) && build.processing_state == "PROCESSING" }
  end

  def self.submitted?(state)
    SUBMITTED_STATES.include?(state)
  end
end
